#!/usr/bin/env node
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { parseEnv } from './lib/env-core.mjs'
import {
  apiHeaders, jsonBody, request, required, sleep, sql, writeReport,
} from './acceptance/common.mjs'
import {
  testRealtime, verifyBackupRestore, verifyCompose, verifyLoopbackBindings, verifyStorage,
} from './acceptance/service-tests.mjs'

const currentDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(currentDir, '..', '..')

function parseArgs(argv) {
  const options = {
    envPath: path.join(repoRoot, 'docker', '.env'),
    dockerDir: path.join(repoRoot, 'docker'),
    baseUrl: undefined,
    reportPath: undefined,
    json: false,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--env') options.envPath = path.resolve(argv[++index] ?? '')
    else if (argument === '--docker-dir') options.dockerDir = path.resolve(argv[++index] ?? '')
    else if (argument === '--base-url') options.baseUrl = argv[++index]
    else if (argument === '--report') options.reportPath = path.resolve(argv[++index] ?? '')
    else if (argument === '--json') options.json = true
    else if (argument === '--help' || argument === '-h') options.help = true
    else throw new Error(`Unknown argument: ${argument}`)
  }
  return options
}

function usage() {
  console.log('Usage: node verify-ultrabase-real.mjs [--env PATH] [--docker-dir PATH] [--base-url URL] [--report PATH] [--json]')
}

function decodeJwtHeader(token) {
  const [header] = token.split('.')
  if (!header) throw new Error('Auth access token is not a JWT')
  return JSON.parse(Buffer.from(header, 'base64url').toString('utf8'))
}

async function createUser(baseUrl, publishableKey, runId, suffix) {
  const email = `ultrabase-ci-${runId}-${suffix}@example.invalid`
  const password = `Ubase!${crypto.randomBytes(24).toString('base64url')}`
  const payload = jsonBody(await request(`${baseUrl}/auth/v1/signup`, {
    method: 'POST',
    headers: apiHeaders(publishableKey, publishableKey, { 'content-type': 'application/json' }),
    body: JSON.stringify({ email, password }),
  }, [200]))
  const accessToken = payload.access_token ?? payload.session?.access_token
  const user = payload.user ?? payload.session?.user
  if (!accessToken || !user?.id) throw new Error('Auth signup did not return an autoconfirmed session and user id')
  const header = decodeJwtHeader(accessToken)
  if (header.alg !== 'ES256') throw new Error(`Auth issued ${header.alg ?? 'unknown'} instead of ES256`)
  return { id: user.id, accessToken, publishableKey }
}

async function deleteUser(baseUrl, secretKey, userId) {
  await request(`${baseUrl}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    method: 'DELETE', headers: apiHeaders(secretKey, secretKey),
  }, [200, 204])
}

async function waitForRestTable(baseUrl, publishableKey, accessToken, tableName) {
  const url = `${baseUrl}/rest/v1/${tableName}?select=id&limit=1`
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    const response = await fetch(url, {
      headers: apiHeaders(publishableKey, accessToken),
      signal: AbortSignal.timeout(5_000),
    }).catch(() => null)
    if (response?.status === 200) return
    await sleep(1_000)
  }
  throw new Error(`PostgREST did not expose ${tableName} after schema reload`)
}

async function insertRow(baseUrl, tableName, publishableKey, accessToken, note, ownerId) {
  const body = { note }
  if (ownerId) body.owner_id = ownerId
  const result = await request(`${baseUrl}/rest/v1/${tableName}`, {
    method: 'POST',
    headers: apiHeaders(publishableKey, accessToken, {
      'content-type': 'application/json', Prefer: 'return=representation',
    }),
    body: JSON.stringify(body),
  }, ownerId ? [401, 403] : [201])
  if (ownerId) return null
  const rows = jsonBody(result)
  if (!Array.isArray(rows) || rows.length !== 1 || rows[0].note !== note) {
    throw new Error('REST insert did not return the inserted RLS row')
  }
  return rows[0]
}

async function selectRows(baseUrl, tableName, publishableKey, accessToken) {
  const rows = jsonBody(await request(
    `${baseUrl}/rest/v1/${tableName}?select=id,owner_id,note&order=note.asc`,
    { headers: apiHeaders(publishableKey, accessToken) },
    [200]
  ))
  if (!Array.isArray(rows)) throw new Error('REST select did not return an array')
  return rows
}

async function proveRls({ baseUrl, tableName, publishableKey, users, runId }) {
  const noteOne = `private-one-${runId}`
  const noteTwo = `private-two-${runId}`
  const rowOne = await insertRow(baseUrl, tableName, publishableKey, users[0].accessToken, noteOne)

  const invisibleToUserTwo = await selectRows(baseUrl, tableName, publishableKey, users[1].accessToken)
  if (invisibleToUserTwo.length !== 0) throw new Error('RLS leak: user two can see user one data')

  await request(`${baseUrl}/rest/v1/${tableName}?id=eq.${encodeURIComponent(rowOne.id)}`, {
    method: 'PATCH',
    headers: apiHeaders(publishableKey, users[1].accessToken, {
      'content-type': 'application/json', Prefer: 'return=representation',
    }),
    body: JSON.stringify({ note: `forged-${runId}` }),
  }, [200]).then((result) => {
    const rows = jsonBody(result)
    if (!Array.isArray(rows) || rows.length !== 0) throw new Error('RLS allowed a cross-user update')
  })

  await insertRow(baseUrl, tableName, publishableKey, users[1].accessToken, noteTwo)
  await insertRow(baseUrl, tableName, publishableKey, users[1].accessToken, `forged-insert-${runId}`, users[0].id)

  const visibleToUserOne = await selectRows(baseUrl, tableName, publishableKey, users[0].accessToken)
  const visibleToUserTwo = await selectRows(baseUrl, tableName, publishableKey, users[1].accessToken)
  if (visibleToUserOne.length !== 1 || visibleToUserOne[0].note !== noteOne) throw new Error('RLS failed to isolate user one')
  if (visibleToUserTwo.length !== 1 || visibleToUserTwo[0].note !== noteTwo) throw new Error('RLS failed to isolate user two')

  await request(`${baseUrl}/rest/v1/${tableName}?select=id`, {
    headers: apiHeaders(publishableKey, publishableKey),
  }, [401, 403])
}

async function verifyGraphql(baseUrl, publishableKey, accessToken) {
  const payload = jsonBody(await request(`${baseUrl}/graphql/v1`, {
    method: 'POST',
    headers: apiHeaders(publishableKey, accessToken, { 'content-type': 'application/json' }),
    body: JSON.stringify({ query: 'query UltrabaseAcceptance { __typename }' }),
  }, [200]))
  if (payload.errors?.length || payload.data?.__typename !== 'Query') {
    throw new Error('GraphQL endpoint did not execute a real query')
  }
}

const startedAt = Date.now()
const steps = []
let users = []
let tableName
let options
let baseUrl
let secretKey

function passed(name, started) {
  steps.push({ name, status: 'passed', duration_ms: Date.now() - started })
  if (!process.env.CI) console.log(`PASS ${name}`)
}

try {
  options = parseArgs(process.argv.slice(2))
  if (options.help) { usage(); process.exit(0) }
  if (!fs.existsSync(options.envPath)) throw new Error(`Environment file not found: ${options.envPath}`)

  const values = parseEnv(fs.readFileSync(options.envPath, 'utf8'))
  baseUrl = (options.baseUrl ?? required(values, 'SUPABASE_PUBLIC_URL')).replace(/\/$/u, '')
  const publishableKey = required(values, 'SUPABASE_PUBLISHABLE_KEY')
  secretKey = required(values, 'SUPABASE_SECRET_KEY')
  const runId = `${Date.now().toString(36)}${crypto.randomBytes(4).toString('hex')}`.toLowerCase()
  tableName = `ultrabase_ci_${runId.replace(/[^a-z0-9]/gu, '').slice(0, 24)}`
  const withLogs = (values.get('COMPOSE_FILE') ?? '').includes('docker-compose.logs.yml')

  let stepStart = Date.now()
  const compose = verifyCompose(options.dockerDir, withLogs)
  verifyLoopbackBindings()
  passed('docker-compose-health-and-loopback-bindings', stepStart)

  stepStart = Date.now()
  const studio = await request(`${baseUrl}/`, {}, [200])
  if (studio.response.headers.get('www-authenticate')) throw new Error('Local loopback Studio unexpectedly requires Basic Auth')
  if (!studio.body.toString('utf8').includes('Ultrabase')) throw new Error('Studio HTML does not contain Ultrabase')
  const logoText = (await request(`${baseUrl}/img/supabase-logo.svg`, {}, [200])).body.toString('utf8')
  if (!logoText.includes('#7C3AED') || !logoText.includes('#D946EF')) throw new Error('Studio logo is not the Ultrabase asset')
  passed('studio-brand-and-http', stepStart)

  stepStart = Date.now()
  await request(`${baseUrl}/auth/v1/health`, { headers: { apikey: publishableKey } }, [200])
  const jwks = jsonBody(await request(`${baseUrl}/auth/v1/.well-known/jwks.json`, {}, [200]))
  if (!Array.isArray(jwks.keys) || !jwks.keys.some((key) => key.kty === 'EC' && key.alg === 'ES256')) {
    throw new Error('Auth JWKS does not expose an ES256 public key')
  }
  users = [
    await createUser(baseUrl, publishableKey, runId, 'one'),
    await createUser(baseUrl, publishableKey, runId, 'two'),
  ]
  passed('auth-real-users-and-es256-tokens', stepStart)

  stepStart = Date.now()
  sql(`
    create table public.${tableName} (
      id uuid primary key default gen_random_uuid(),
      owner_id uuid not null default auth.uid(),
      note text not null,
      created_at timestamptz not null default now()
    );
    alter table public.${tableName} enable row level security;
    grant select, insert, update, delete on public.${tableName} to authenticated;
    create policy ${tableName}_select on public.${tableName}
      for select to authenticated using ((select auth.uid()) = owner_id);
    create policy ${tableName}_insert on public.${tableName}
      for insert to authenticated with check ((select auth.uid()) = owner_id);
    create policy ${tableName}_update on public.${tableName}
      for update to authenticated using ((select auth.uid()) = owner_id)
      with check ((select auth.uid()) = owner_id);
    create policy ${tableName}_delete on public.${tableName}
      for delete to authenticated using ((select auth.uid()) = owner_id);
    alter publication supabase_realtime add table public.${tableName};
    notify pgrst, 'reload schema';
  `)
  await waitForRestTable(baseUrl, publishableKey, users[0].accessToken, tableName)
  await proveRls({ baseUrl, tableName, publishableKey, users, runId })
  passed('rest-crud-and-negative-rls-isolation', stepStart)

  stepStart = Date.now()
  await verifyGraphql(baseUrl, publishableKey, users[0].accessToken)
  passed('graphql-real-query', stepStart)

  stepStart = Date.now()
  const realtimeMarker = `realtime-${runId}`
  await testRealtime({
    baseUrl, publishableKey, accessToken: users[0].accessToken, tableName, marker: realtimeMarker,
    insertCallback: () => insertRow(baseUrl, tableName, publishableKey, users[0].accessToken, realtimeMarker),
  })
  passed('realtime-postgres-change-delivery', stepStart)

  stepStart = Date.now()
  await verifyStorage({ baseUrl, secretKey, userOne: users[0], userTwo: users[1], runId })
  passed('storage-private-rls-byte-roundtrip', stepStart)

  stepStart = Date.now()
  await request(`${baseUrl}/functions/v1/hello`, {}, [401, 403])
  const functionPayload = jsonBody(await request(`${baseUrl}/functions/v1/hello`, {
    headers: apiHeaders(publishableKey, publishableKey),
  }, [200]))
  if (functionPayload !== 'Hello from Edge Functions!') throw new Error('Edge Function returned an unexpected body')
  passed('edge-function-jwt-enforcement-and-invocation', stepStart)

  stepStart = Date.now()
  verifyBackupRestore(runId, tableName)
  passed('postgres-custom-backup-full-restore', stepStart)

  const report = {
    status: 'passed', generated_at: new Date().toISOString(), duration_ms: Date.now() - startedAt,
    secrets_printed: false, compose, steps,
  }
  writeReport(options.reportPath, report)
  if (options.json) console.log(JSON.stringify(report))
  else console.log(`ULTRABASE REAL ACCEPTANCE: PASS (${steps.length}/${steps.length})`)
} catch (error) {
  const report = {
    status: 'failed', generated_at: new Date().toISOString(), duration_ms: Date.now() - startedAt,
    secrets_printed: false, steps, error: error.message,
  }
  try { writeReport(options?.reportPath, report) } catch {}
  console.error(`ULTRABASE REAL ACCEPTANCE: FAIL\n${error.stack ?? error.message}`)
  process.exitCode = 1
} finally {
  try { if (tableName) sql(`drop table if exists public.${tableName} cascade; notify pgrst, 'reload schema';`) } catch {}
  if (baseUrl && secretKey) {
    for (const user of users) {
      try { await deleteUser(baseUrl, secretKey, user.id) } catch {}
    }
  }
}
