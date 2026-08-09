import crypto from 'node:crypto'
import { apiHeaders, dockerExec, request, run, sql } from './common.mjs'

function parseComposeRows(output) {
  const trimmed = output.trim()
  if (!trimmed) return []
  try {
    const parsed = JSON.parse(trimmed)
    return Array.isArray(parsed) ? parsed : [parsed]
  } catch {
    return trimmed.split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line))
  }
}

export function verifyCompose(dockerDir, withLogs) {
  const result = run('docker', ['compose', 'ps', '--format', 'json'], { cwd: dockerDir })
  const rows = parseComposeRows(result.stdout)
  const expected = new Set([
    'studio', 'kong', 'auth', 'rest', 'realtime', 'storage', 'imgproxy',
    'meta', 'functions', 'db', 'supavisor',
    ...(withLogs ? ['analytics', 'vector'] : []),
  ])
  const byService = new Map(rows.map((row) => [row.Service, row]))
  for (const service of expected) {
    const row = byService.get(service)
    if (!row) throw new Error(`Docker Compose service is missing: ${service}`)
    if (String(row.State).toLowerCase() !== 'running') {
      throw new Error(`Service ${service} is not running: ${row.State ?? 'unknown'}`)
    }
    if (row.Health && String(row.Health).toLowerCase() !== 'healthy') {
      throw new Error(`Service ${service} is not healthy: ${row.Health}`)
    }
  }
  return {
    expected_services: expected.size,
    running_services: rows.length,
    additional_services: [...byService.keys()].filter((service) => !expected.has(service)),
  }
}

function inspectPorts(container) {
  const output = run('docker', ['inspect', '-f', '{{json .NetworkSettings.Ports}}', container]).stdout.trim()
  return JSON.parse(output)
}

export function verifyLoopbackBindings() {
  for (const [container, ports] of [
    ['supabase-kong', ['8000/tcp', '8443/tcp']],
    ['supabase-pooler', ['5432/tcp', '6543/tcp']],
  ]) {
    const bindings = inspectPorts(container)
    for (const port of ports) {
      const published = bindings[port]
      if (!Array.isArray(published) || published.length === 0) {
        throw new Error(`${container} does not publish ${port}`)
      }
      for (const binding of published) {
        if (binding.HostIp !== '127.0.0.1') {
          throw new Error(`${container} ${port} is exposed outside loopback: ${binding.HostIp}`)
        }
      }
    }
  }
}

export async function testRealtime({ baseUrl, publishableKey, accessToken, tableName, insertCallback, marker }) {
  const websocketBase = baseUrl.replace(/^http/u, 'ws')
  const websocket = new WebSocket(
    `${websocketBase}/realtime/v1/websocket?apikey=${encodeURIComponent(publishableKey)}&vsn=1.0.0`
  )
  const topic = `realtime:ultrabase-ci-${crypto.randomBytes(8).toString('hex')}`
  let joined = false
  let insertionStarted = false

  const eventPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Realtime did not deliver the inserted row')), 35_000)
    const fail = (error) => {
      clearTimeout(timeout)
      reject(error)
    }
    websocket.addEventListener('error', () => fail(new Error('Realtime WebSocket emitted an error')))
    websocket.addEventListener('message', (event) => {
      const text = typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString('utf8')
      let message
      try { message = JSON.parse(text) } catch { return }
      if (message.event === 'phx_reply' && message.ref === '1') {
        if (message.payload?.status !== 'ok') {
          fail(new Error(`Realtime channel join failed: ${message.payload?.response?.reason ?? 'unknown'}`))
          return
        }
        joined = true
        if (!insertionStarted) {
          insertionStarted = true
          insertCallback().catch(fail)
        }
        return
      }
      if (joined && message.event === 'postgres_changes' && text.includes(marker)) {
        clearTimeout(timeout)
        resolve()
      }
    })
  })

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Realtime WebSocket did not open')), 15_000)
    websocket.addEventListener('open', () => { clearTimeout(timeout); resolve() })
    websocket.addEventListener('error', () => { clearTimeout(timeout); reject(new Error('Realtime WebSocket failed to open')) })
  })

  websocket.send(JSON.stringify({
    topic,
    event: 'phx_join',
    payload: {
      config: {
        broadcast: { ack: false, self: false },
        presence: { enabled: false },
        postgres_changes: [{ event: 'INSERT', schema: 'public', table: tableName }],
      },
      access_token: accessToken,
    },
    ref: '1',
    join_ref: '1',
  }))

  try {
    await eventPromise
  } finally {
    websocket.close()
  }
}

export async function verifyStorage({ baseUrl, secretKey, userOne, userTwo, runId }) {
  const bucket = `ultrabase-ci-${runId}`
  const objectPath = `${userOne.id}/proof/runtime.txt`
  const contents = Buffer.from(`Ultrabase real storage proof ${runId}\n`, 'utf8')
  const adminHeaders = apiHeaders(secretKey, secretKey)
  const userHeaders = apiHeaders(userOne.publishableKey, userOne.accessToken)
  const otherHeaders = apiHeaders(userTwo.publishableKey, userTwo.accessToken)
  const policySuffix = runId.replace(/[^a-z0-9]/gu, '').slice(0, 20)
  const policies = [
    `ultrabase_ci_storage_insert_${policySuffix}`,
    `ultrabase_ci_storage_select_${policySuffix}`,
    `ultrabase_ci_storage_delete_${policySuffix}`,
  ]
  let bucketCreated = false

  sql(`
    begin;
    create policy ${policies[0]} on storage.objects
      for insert to authenticated
      with check (bucket_id = '${bucket}' and (storage.foldername(name))[1] = (select auth.uid()::text));
    create policy ${policies[1]} on storage.objects
      for select to authenticated
      using (bucket_id = '${bucket}' and (storage.foldername(name))[1] = (select auth.uid()::text));
    create policy ${policies[2]} on storage.objects
      for delete to authenticated
      using (bucket_id = '${bucket}' and (storage.foldername(name))[1] = (select auth.uid()::text));
    commit;
  `)

  try {
    await request(`${baseUrl}/storage/v1/bucket`, {
      method: 'POST',
      headers: { ...adminHeaders, 'content-type': 'application/json' },
      body: JSON.stringify({ id: bucket, name: bucket, public: false }),
    }, [200])
    bucketCreated = true

    await request(`${baseUrl}/storage/v1/object/${bucket}/${objectPath}`, {
      method: 'POST',
      headers: { ...userHeaders, 'content-type': 'text/plain', 'cache-control': 'max-age=60', 'x-upsert': 'false' },
      body: contents,
    }, [200, 201])

    const downloaded = await request(`${baseUrl}/storage/v1/object/${bucket}/${objectPath}`, { headers: userHeaders }, [200])
    if (!downloaded.body.equals(contents)) throw new Error('Storage download bytes differ from upload bytes')

    await request(`${baseUrl}/storage/v1/object/${bucket}/${objectPath}`, { headers: otherHeaders }, [400, 401, 403, 404])

    await request(`${baseUrl}/storage/v1/object/${bucket}`, {
      method: 'DELETE',
      headers: { ...userHeaders, 'content-type': 'application/json' },
      body: JSON.stringify({ prefixes: [objectPath] }),
    }, [200])
  } finally {
    if (bucketCreated) {
      await request(`${baseUrl}/storage/v1/bucket/${bucket}`, { method: 'DELETE', headers: adminHeaders }, [200]).catch(() => {})
    }
    sql(policies.map((policy) => `drop policy if exists ${policy} on storage.objects;`).join('\n'))
  }
}

export function verifyBackupRestore(runId, tableName) {
  const dumpPath = `/tmp/ultrabase-${runId}.dump`
  const restoreDatabase = `ultrabase_restore_${runId.replace(/[^a-z0-9]/gu, '').slice(0, 20)}`
  dockerExec(['supabase-db', 'pg_dump', '-U', 'postgres', '-d', 'postgres', '--format=custom', `--file=${dumpPath}`])
  try {
    dockerExec(['supabase-db', 'pg_restore', '--list', dumpPath])
    dockerExec(['supabase-db', 'dropdb', '-U', 'postgres', '--if-exists', '--force', restoreDatabase])
    dockerExec(['supabase-db', 'createdb', '-U', 'postgres', '-T', 'template0', restoreDatabase])
    try {
      dockerExec([
        'supabase-db', 'pg_restore', '-U', 'postgres', '-d', restoreDatabase,
        '--no-owner', '--no-privileges', '--exit-on-error', dumpPath,
      ])
      const restoredRows = sql(`select count(*) from public.${tableName};`, restoreDatabase)
      if (!/^\d+$/u.test(restoredRows) || Number(restoredRows) < 2) {
        throw new Error(`Restored database does not contain the expected RLS rows: ${restoredRows}`)
      }
    } finally {
      dockerExec(['supabase-db', 'dropdb', '-U', 'postgres', '--if-exists', '--force', restoreDatabase], { allowFailure: true })
    }
  } finally {
    dockerExec(['supabase-db', 'rm', '-f', dumpPath], { allowFailure: true })
  }
}
