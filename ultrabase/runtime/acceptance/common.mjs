import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'

export function required(values, key) {
  const value = values.get(key)
  if (!value) throw new Error(`Required environment value is missing: ${key}`)
  return value
}

export function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    input: options.input,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, ...(options.env ?? {}) },
  })
  if (result.error) throw result.error
  if (result.status !== 0 && !options.allowFailure) {
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`.trim()
    throw new Error(`${command} ${args.join(' ')} failed with exit ${result.status}${output ? `:\n${output}` : ''}`)
  }
  return result
}

export function sql(statement, database = 'postgres') {
  return run(
    'docker',
    ['exec', '-i', 'supabase-db', 'psql', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1', '-Atq'],
    { input: statement }
  ).stdout.trim()
}

export function dockerExec(args, options = {}) {
  return run('docker', ['exec', ...args], options)
}

function safeUrl(url) {
  try {
    const parsed = new URL(url)
    parsed.search = ''
    return parsed.toString()
  } catch {
    return String(url).split('?')[0]
  }
}

export async function request(url, options = {}, expectedStatuses = [200]) {
  const response = await fetch(url, {
    ...options,
    signal: AbortSignal.timeout(options.timeoutMs ?? 20_000),
  })
  const body = Buffer.from(await response.arrayBuffer())
  if (!expectedStatuses.includes(response.status)) {
    throw new Error(`${options.method ?? 'GET'} ${safeUrl(url)} returned HTTP ${response.status}`)
  }
  return { response, body }
}

export function jsonBody(result) {
  const text = result.body.toString('utf8')
  try {
    return JSON.parse(text)
  } catch (error) {
    throw new Error(`Expected JSON response (${error.message})`)
  }
}

export function apiHeaders(apiKey, bearer = apiKey, extra = {}) {
  return {
    apikey: apiKey,
    Authorization: `Bearer ${bearer}`,
    ...extra,
  }
}

export function writeReport(reportPath, report) {
  if (!reportPath) return
  fs.mkdirSync(path.dirname(reportPath), { recursive: true })
  const temporaryPath = `${reportPath}.${process.pid}.tmp`
  fs.writeFileSync(temporaryPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8')
  fs.renameSync(temporaryPath, reportPath)
}

export function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
