#!/usr/bin/env node

import { createHash, randomBytes } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'

const repoRoot = resolve(new URL('../..', import.meta.url).pathname)
const dockerDir = join(repoRoot, 'docker')
const envPath = process.env.ULTRABASE_ENV_FILE ? resolve(process.env.ULTRABASE_ENV_FILE) : join(dockerDir, '.env')
const evidenceDir = process.env.ULTRABASE_EVIDENCE_DIR ? resolve(process.env.ULTRABASE_EVIDENCE_DIR) : join(repoRoot, 'ultrabase', 'runtime', 'evidence')
const reportPath = join(evidenceDir, 'live-verification.json')
const baseUrl = process.env.ULTRABASE_URL || 'http://127.0.0.1:8000'
const suffix = `${Date.now().toString(36)}${randomBytes(3).toString('hex')}`.replace(/[^a-z0-9]/g, '')
const table = `ultrabase_ci_${suffix}`
const restoreDatabase = `ultra_restore_${suffix}`
const bucket = `ultrabase-ci-${suffix}`
const objectPath = `proof/${suffix}.png`
const userPassword = `Ua!${randomBytes(18).toString('base64url')}`
const userEmails = [`ultra-ci-${suffix}-one@example.invalid`, `ultra-ci-${suffix}-two@example.invalid`]
const pngBytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2jTQAAAAASUVORK5CYII=', 'base64')
const startedAt = new Date().toISOString()
const completedChecks = []
const cleanupErrors = []
let users = []
let realtimeSocket = null
let storageCreated = false
let tableCreated = false
let restoreCreated = false

function parseEnv(content) {
  const result = {}
  for (const sourceLine of content.split(/\r?\n/)) {
    const line = sourceLine.trim()
    if (!line || line.startsWith('#')) continue
    const separator = line.indexOf('=')
    if (separator <= 0) throw new Error(`Invalid environment line: ${sourceLine}`)
    const name = line.slice(0, separator).trim()
    let value = line.slice(separator + 1).trim()
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1)
    result[name] = value
  }
  return result
}

if (!existsSync(envPath)) throw new Error(`Ultrabase environment not found: ${envPath}`)
const env = parseEnv(readFileSync(envPath, 'utf8'))
const requiredEnv = ['SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'POOLER_TENANT_ID', 'POSTGRES_PASSWORD']
for (const name of requiredEnv) if (!env[name]) throw new Error(`Required environment variable missing: ${name}`)

const publicHeaders = {
  apikey: env.SUPABASE_PUBLISHABLE_KEY,
}
const serviceHeaders = {
  apikey: env.SUPABASE_SECRET_KEY,
  Authorization: `Bearer ${env.SUPABASE_SECRET_KEY}`,
}

function check(name, detail = {}) {
  completedChecks.push({ name, status: 'passed', ...detail })
  console.log(`PASS ${name}`)
}

function command(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    cwd: options.cwd || repoRoot,
    env: { ...process.env, ...(options.env || {}) },
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
  if (result.error) throw result.error
  if (result.status !== 0 && !options.allowFailure) {
    const output = `${result.stdout || ''}\n${result.stderr || ''}`.trim()
    throw new Error(`${executable} ${args.join(' ')} failed with exit ${result.status}${output ? `: ${output.slice(-4000)}` : ''}`)
  }
  return result
}

function compose(args, options = {}) {
  return command('docker', ['compose', ...args], { cwd: dockerDir, ...options })
}

function psql(sql, database = 'postgres') {
  return compose(['exec', '-T', 'db', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', database, '-c', sql])
}

function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms))
}

async function retry(name, action, options = {}) {
  const attempts = options.attempts || 30
  const delay = options.delay || 2000
  let lastError
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await action(attempt)
    } catch (error) {
      lastError = error
      if (attempt < attempts) await sleep(delay)
    }
  }
  throw new Error(`${name} did not succeed after ${attempts} attempts: ${lastError instanceof Error ? lastError.message : String(lastError)}`)
}

async function http(path, options = {}) {
  const expected = options.expected || [200]
  const headers = { ...(options.headers || {}) }
  let body = options.body
  if (body !== undefined && body !== null && !Buffer.isBuffer(body) && typeof body !== 'string') {
    headers['content-type'] = headers['content-type'] || 'application/json'
    body = JSON.stringify(body)
  }
  const response = await fetch(`${baseUrl}${path}`, {
    method: options.method || 'GET',
    headers,
    body,
    signal: AbortSignal.timeout(options.timeout || 30000),
  })
  const responseBuffer = Buffer.from(await response.arrayBuffer())
  const contentType = response.headers.get('content-type') || ''
  let data = responseBuffer
  if (!options.binary) {
    const text = responseBuffer.toString('utf8')
    if (contentType.includes('json') && text) {
      try { data = JSON.parse(text) } catch { data = text }
    } else data = text
  }
  if (!expected.includes(response.status)) {
    const safeBody = typeof data === 'string' ? data.slice(0, 1000) : JSON.stringify(data).slice(0, 1000)
    throw new Error(`${options.method || 'GET'} ${path} returned ${response.status}: ${safeBody}`)
  }
  return { status: response.status, headers: response.headers, data }
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

function listFilesRecursively(root) {
  if (!existsSync(root)) return []
  const files = []
  for (const item of readdirSync(root, { withFileTypes: true })) {
    const fullPath = join(root, item.name)
    if (item.isDirectory()) files.push(...listFilesRecursively(fullPath))
    else files.push(fullPath)
  }
  return files
}

async function verifyServices() {
  const configured = compose(['config', '--services']).stdout.trim().split(/\r?\n/).filter(Boolean)
  const required = ['studio', 'kong', 'auth', 'rest', 'realtime', 'storage', 'imgproxy', 'meta', 'functions', 'db', 'supavisor', 'analytics', 'vector']
  for (const service of required) {
    if (!configured.includes(service)) throw new Error(`Required Compose service is missing: ${service}`)
  }

  const services = []
  for (const service of configured) {
    const containerId = compose(['ps', '-q', service]).stdout.trim()
    if (!containerId) throw new Error(`Compose service has no container: ${service}`)
    const state = command('docker', ['inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', containerId]).stdout.trim()
    if (!['healthy', 'running'].includes(state)) throw new Error(`Service ${service} is not ready: ${state}`)
    services.push({ service, state })
  }
  check('all configured Docker services are real and ready', { service_count: services.length, services })
  return services
}

async function verifyHttpSurfaces() {
  const studio = await retry('Studio', () => http('/', { expected: [200] }))
  if (!String(studio.data).toLowerCase().includes('<html')) throw new Error('Studio did not return an HTML application')
  const logo = await http('/img/ultrabase-logo.svg', { expected: [200] })
  if (!String(logo.data).includes('Ultrabase')) throw new Error('Ultrabase Studio branding asset is missing')
  check('Ultrabase Studio and native branding')

  await retry('Auth health', () => http('/auth/v1/health', { headers: publicHeaders, expected: [200] }))
  await retry('Storage health', () => http('/storage/v1/status', { headers: serviceHeaders, expected: [200] }))
  await retry('Postgres Meta health', () => http('/pg/health', { headers: serviceHeaders, expected: [200] }))
  await retry('PostgREST OpenAPI', () => http('/rest/v1/', { headers: serviceHeaders, expected: [200] }))
  check('Auth, Storage, Meta and PostgREST HTTP surfaces')

  const graphql = await http('/graphql/v1', {
    method: 'POST',
    headers: serviceHeaders,
    body: { query: 'query UltrabaseLive { __typename }' },
    expected: [200],
  })
  if (!graphql.data?.data || graphql.data.data.__typename !== 'Query') throw new Error(`GraphQL returned an invalid response: ${JSON.stringify(graphql.data)}`)
  check('real pg_graphql query through Kong')

  const edge = await http('/functions/v1/hello', {
    headers: { ...publicHeaders, Authorization: `Bearer ${env.ANON_KEY_ASYMMETRIC || env.ANON_KEY}` },
    expected: [200],
  })
  const edgeText = typeof edge.data === 'string' ? edge.data : JSON.stringify(edge.data)
  if (!/hello/i.test(edgeText)) throw new Error(`Edge Function response is unexpected: ${edgeText}`)
  check('real JWT-protected Edge Function invocation')
}

async function signupUsers() {
  for (const email of userEmails) {
    const result = await http('/auth/v1/signup', {
      method: 'POST',
      headers: publicHeaders,
      body: { email, password: userPassword },
      expected: [200],
    })
    const accessToken = result.data?.access_token
    const user = result.data?.user
    if (!accessToken || !user?.id) throw new Error(`Auth signup did not create a confirmed session for ${email}`)
    users.push({ id: user.id, accessToken })
  }
  check('two real isolated Auth users and sessions')
}

async function createRlsTable() {
  const sql = `
    create table public.${table} (
      id uuid primary key default gen_random_uuid(),
      owner uuid not null default auth.uid(),
      body text not null,
      created_at timestamptz not null default now()
    );
    alter table public.${table} enable row level security;
    create policy ${table}_select_own on public.${table} for select to authenticated using (owner = auth.uid());
    create policy ${table}_insert_own on public.${table} for insert to authenticated with check (owner = auth.uid());
    grant select, insert on public.${table} to authenticated;
    do $$
    begin
      if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        raise exception 'supabase_realtime publication is missing';
      end if;
      execute 'alter publication supabase_realtime add table public.${table}';
    end $$;
    notify pgrst, 'reload schema';
  `
  psql(sql)
  tableCreated = true
  await retry('PostgREST schema reload', () => http(`/rest/v1/${table}?select=id&limit=1`, {
    headers: { ...publicHeaders, Authorization: `Bearer ${users[0].accessToken}` },
    expected: [200],
  }), { attempts: 40, delay: 1500 })
  check('real PostgreSQL table, grants, publication and RLS policies')
}

async function verifyRls() {
  const marker = `owner-one-${suffix}`
  const inserted = await http(`/rest/v1/${table}?select=*`, {
    method: 'POST',
    headers: {
      ...publicHeaders,
      Authorization: `Bearer ${users[0].accessToken}`,
      Prefer: 'return=representation',
    },
    body: { body: marker },
    expected: [201],
  })
  const row = Array.isArray(inserted.data) ? inserted.data[0] : inserted.data
  if (!row?.id || row.owner !== users[0].id || row.body !== marker) throw new Error(`Inserted PostgREST row is invalid: ${JSON.stringify(inserted.data)}`)

  const ownerRead = await http(`/rest/v1/${table}?id=eq.${row.id}&select=*`, {
    headers: { ...publicHeaders, Authorization: `Bearer ${users[0].accessToken}` },
    expected: [200],
  })
  if (!Array.isArray(ownerRead.data) || ownerRead.data.length !== 1) throw new Error('Owner could not read its own RLS-protected row')

  const strangerRead = await http(`/rest/v1/${table}?id=eq.${row.id}&select=*`, {
    headers: { ...publicHeaders, Authorization: `Bearer ${users[1].accessToken}` },
    expected: [200],
  })
  if (!Array.isArray(strangerRead.data) || strangerRead.data.length !== 0) throw new Error('RLS leaked one user row to another user')

  await http(`/rest/v1/${table}`, {
    method: 'POST',
    headers: {
      ...publicHeaders,
      Authorization: `Bearer ${users[1].accessToken}`,
      Prefer: 'return=representation',
    },
    body: { owner: users[0].id, body: `forbidden-${suffix}` },
    expected: [401, 403],
  })
  check('positive and negative multi-user RLS through PostgREST')
  return row
}

async function openRealtimeSubscription() {
  if (typeof WebSocket === 'undefined') throw new Error('Node.js WebSocket support is required; use Node 22 or newer')
  const websocketUrl = `${baseUrl.replace(/^http/, 'ws')}/realtime/v1/websocket?apikey=${encodeURIComponent(env.SUPABASE_PUBLISHABLE_KEY)}&vsn=1.0.0`
  const socket = new WebSocket(websocketUrl)
  const topic = `realtime:ultrabase-ci-${suffix}`
  let resolveJoin
  let rejectJoin
  let resolveChange
  let rejectChange
  const joinPromise = new Promise((resolvePromise, rejectPromise) => { resolveJoin = resolvePromise; rejectJoin = rejectPromise })
  const changePromise = new Promise((resolvePromise, rejectPromise) => { resolveChange = resolvePromise; rejectChange = rejectPromise })
  const timeout = setTimeout(() => {
    rejectJoin(new Error('Realtime join timed out'))
    rejectChange(new Error('Realtime INSERT event timed out'))
    socket.close()
  }, 45000)

  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({
      topic,
      event: 'phx_join',
      payload: {
        config: {
          broadcast: { ack: false, self: false },
          presence: { key: '' },
          postgres_changes: [{ event: 'INSERT', schema: 'public', table }],
        },
        access_token: users[0].accessToken,
      },
      ref: '1',
    }))
  })
  socket.addEventListener('error', () => {
    rejectJoin(new Error('Realtime WebSocket connection failed'))
    rejectChange(new Error('Realtime WebSocket connection failed'))
  })
  socket.addEventListener('message', async (event) => {
    try {
      let raw
      if (typeof event.data === 'string') raw = event.data
      else if (event.data instanceof Blob) raw = Buffer.from(await event.data.arrayBuffer()).toString('utf8')
      else raw = Buffer.from(event.data).toString('utf8')
      const message = JSON.parse(raw)
      if (message.event === 'phx_reply' && String(message.ref) === '1') {
        if (message.payload?.status === 'ok') resolveJoin()
        else rejectJoin(new Error(`Realtime join rejected: ${raw}`))
      }
      if (message.event === 'postgres_changes' || message.event === 'INSERT') {
        resolveChange(message)
      }
    } catch (error) {
      rejectChange(error)
    }
  })

  await joinPromise
  realtimeSocket = socket
  return { socket, changePromise, timeout }
}

async function verifyRealtime() {
  const subscription = await openRealtimeSubscription()
  const marker = `realtime-${suffix}`
  await http(`/rest/v1/${table}`, {
    method: 'POST',
    headers: {
      ...publicHeaders,
      Authorization: `Bearer ${users[0].accessToken}`,
      Prefer: 'return=minimal',
    },
    body: { body: marker },
    expected: [201],
  })
  const message = await subscription.changePromise
  clearTimeout(subscription.timeout)
  const record = message.payload?.data?.record || message.payload?.record || message.payload?.new || {}
  if (record.body !== marker) throw new Error(`Realtime delivered the wrong payload: ${JSON.stringify(message).slice(0, 1500)}`)
  subscription.socket.close()
  realtimeSocket = null
  check('real PostgreSQL INSERT delivered over Realtime WebSocket')
}

async function verifyStorageAndImgproxy() {
  await http('/storage/v1/bucket', {
    method: 'POST',
    headers: serviceHeaders,
    body: { id: bucket, name: bucket, public: false, file_size_limit: 1048576 },
    expected: [200],
  })
  storageCreated = true

  await http(`/storage/v1/object/${bucket}/${objectPath}`, {
    method: 'POST',
    headers: { ...serviceHeaders, 'content-type': 'image/png', 'x-upsert': 'false' },
    body: pngBytes,
    expected: [200],
  })

  await http(`/storage/v1/object/public/${bucket}/${objectPath}`, {
    expected: [400, 401, 403, 404],
    binary: true,
  })

  const downloaded = await http(`/storage/v1/object/authenticated/${bucket}/${objectPath}`, {
    headers: serviceHeaders,
    expected: [200],
    binary: true,
  })
  if (!Buffer.isBuffer(downloaded.data) || !downloaded.data.equals(pngBytes)) throw new Error('Private Storage download did not match uploaded bytes')

  const rendered = await retry('imgproxy transform', () => http(`/storage/v1/render/image/authenticated/${bucket}/${objectPath}?width=2&height=2&resize=contain`, {
    headers: serviceHeaders,
    expected: [200],
    binary: true,
  }), { attempts: 20, delay: 1500 })
  if (!String(rendered.headers.get('content-type')).startsWith('image/')) throw new Error('imgproxy did not return an image')
  if (!Buffer.isBuffer(rendered.data) || rendered.data.length < 20) throw new Error('imgproxy returned an empty image')
  check('private Storage upload/download denial and real imgproxy transform')
}

async function verifyPooler() {
  for (const port of ['5432', '6543']) {
    const result = command('docker', [
      'run', '--rm', '--network', 'host',
      '-e', 'PGPASSWORD', '-e', 'PGHOST=127.0.0.1', '-e', `PGPORT=${port}`,
      '-e', `PGUSER=postgres.${env.POOLER_TENANT_ID}`, '-e', 'PGDATABASE=postgres',
      'postgres:17-alpine', 'psql', '-X', '-tA', '-c', 'select 42',
    ], { env: { PGPASSWORD: env.POSTGRES_PASSWORD } })
    if (result.stdout.trim() !== '42') throw new Error(`Supavisor port ${port} did not execute SQL`) 
  }
  check('real SQL through Supavisor session and transaction ports')
}

async function verifyBackupRestore() {
  const dumpFile = `/tmp/${table}.dump`
  const rolesFile = `/tmp/${table}-roles.sql`
  compose(['exec', '-T', 'db', 'pg_dump', '-U', 'postgres', '-d', 'postgres', '--format=custom', '--no-owner', '--no-privileges', `--file=${dumpFile}`])
  compose(['exec', '-T', 'db', 'pg_dumpall', '-U', 'postgres', '--roles-only', `--file=${rolesFile}`])
  const dumpSize = Number(compose(['exec', '-T', 'db', 'stat', '-c', '%s', dumpFile]).stdout.trim())
  const rolesSize = Number(compose(['exec', '-T', 'db', 'stat', '-c', '%s', rolesFile]).stdout.trim())
  if (!Number.isFinite(dumpSize) || dumpSize < 10000) throw new Error(`Database dump is unexpectedly small: ${dumpSize}`)
  if (!Number.isFinite(rolesSize) || rolesSize < 100) throw new Error(`Roles dump is unexpectedly small: ${rolesSize}`)

  compose(['exec', '-T', 'db', 'createdb', '-U', 'postgres', restoreDatabase])
  restoreCreated = true
  compose(['exec', '-T', 'db', 'pg_restore', '--exit-on-error', '--no-owner', '--no-privileges', '-U', 'postgres', '-d', restoreDatabase, dumpFile])
  const restoredCount = compose(['exec', '-T', 'db', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', restoreDatabase, '-tA', '-c', `select count(*) from public.${table};`]).stdout.trim()
  if (Number(restoredCount) < 2) throw new Error(`Restored database lost acceptance-test rows: ${restoredCount}`)

  const storageSource = join(dockerDir, 'volumes', 'storage')
  const archive = join(evidenceDir, `${table}-storage.tar.gz`)
  const extracted = join(evidenceDir, `${table}-storage-restored`)
  mkdirSync(evidenceDir, { recursive: true })
  mkdirSync(extracted, { recursive: true })
  command('tar', ['-czf', archive, '-C', storageSource, '.'])
  command('tar', ['-xzf', archive, '-C', extracted])
  const restoredFiles = listFilesRecursively(extracted).filter((path) => statSync(path).size > 0)
  if (restoredFiles.length === 0) throw new Error('Storage archive restored no non-empty files')
  const archiveHash = sha256(archive)
  rmSync(archive, { force: true })
  rmSync(extracted, { recursive: true, force: true })

  check('real pg_dump, role dump, full pg_restore and Storage archive extraction', {
    database_dump_bytes: dumpSize,
    roles_dump_bytes: rolesSize,
    storage_archive_sha256: archiveHash,
    restored_storage_files: restoredFiles.length,
  })
}

async function cleanup() {
  if (realtimeSocket) {
    try { realtimeSocket.close() } catch {}
    realtimeSocket = null
  }
  if (restoreCreated) {
    try {
      compose(['exec', '-T', 'db', 'dropdb', '--if-exists', '--force', '-U', 'postgres', restoreDatabase])
      restoreCreated = false
    } catch (error) { cleanupErrors.push(`restore database: ${error.message}`) }
  }
  if (storageCreated) {
    try {
      await http(`/storage/v1/object/${bucket}`, {
        method: 'DELETE', headers: serviceHeaders, body: { prefixes: [objectPath] }, expected: [200],
      })
      await http(`/storage/v1/bucket/${bucket}`, { method: 'DELETE', headers: serviceHeaders, expected: [200] })
      storageCreated = false
    } catch (error) { cleanupErrors.push(`storage: ${error.message}`) }
  }
  for (const user of users) {
    try {
      await http(`/auth/v1/admin/users/${user.id}`, { method: 'DELETE', headers: serviceHeaders, expected: [200] })
    } catch (error) { cleanupErrors.push(`auth user: ${error.message}`) }
  }
  users = []
  if (tableCreated) {
    try {
      psql(`drop table if exists public.${table} cascade; notify pgrst, 'reload schema';`)
      tableCreated = false
    } catch (error) { cleanupErrors.push(`table: ${error.message}`) }
  }
}

function writeReport(status, extra = {}) {
  mkdirSync(dirname(reportPath), { recursive: true })
  writeFileSync(reportPath, JSON.stringify({
    schema_version: 1,
    product: 'Ultrabase',
    status,
    mode: 'real_full_stack_no_mocks',
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    base_url: baseUrl,
    checks_passed: completedChecks.length,
    checks: completedChecks,
    cleanup_errors: cleanupErrors,
    ...extra,
  }, null, 2) + '\n', 'utf8')
}

async function main() {
  mkdirSync(evidenceDir, { recursive: true })
  const services = await verifyServices()
  await verifyHttpSurfaces()
  await signupUsers()
  await createRlsTable()
  await verifyRls()
  await verifyRealtime()
  await verifyStorageAndImgproxy()
  await verifyPooler()
  await verifyBackupRestore()
  await cleanup()
  if (cleanupErrors.length > 0) throw new Error(`Acceptance checks passed but cleanup failed: ${cleanupErrors.join('; ')}`)
  writeReport('passed', { service_count: services.length })
  console.log(`ULTRABASE LIVE VERIFICATION PASSED: ${completedChecks.length} real checks`)
}

try {
  await main()
} catch (error) {
  try { await cleanup() } catch {}
  writeReport('failed', { error: error instanceof Error ? error.message : String(error) })
  console.error(`ULTRABASE_LIVE_ERROR: ${error instanceof Error ? error.stack || error.message : String(error)}`)
  process.exit(1)
}
