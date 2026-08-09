import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const b64u = (value) => Buffer.from(value).toString('base64url')
const hex = (bytes) => crypto.randomBytes(bytes).toString('hex')
const b64 = (bytes) => crypto.randomBytes(bytes).toString('base64')

function signHs(payload, secret) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const p = b64u(JSON.stringify(payload))
  const data = `${h}.${p}`
  return `${data}.${crypto.createHmac('sha256', secret).update(data).digest('base64url')}`
}

function signEs(payload, key, kid) {
  const h = b64u(JSON.stringify({ alg: 'ES256', typ: 'JWT', kid }))
  const p = b64u(JSON.stringify(payload))
  const data = `${h}.${p}`
  const sig = crypto.sign('SHA256', Buffer.from(data), {
    key,
    dsaEncoding: 'ieee-p1363',
  }).toString('base64url')
  return `${data}.${sig}`
}

function opaque(prefix) {
  const random = crypto.randomBytes(17).toString('base64url').slice(0, 22)
  const value = `${prefix}${random}`
  const sum = crypto.createHash('sha256')
    .update(`supabase-self-hosted|${value}`)
    .digest('base64url').slice(0, 8)
  return `${value}_${sum}`
}

export function generateValues() {
  const iat = Math.floor(Date.now() / 1000)
  const exp = iat + 5 * 365 * 86400
  const secret = b64(30)
  const anon = { role: 'anon', iss: 'supabase', iat, exp }
  const service = { role: 'service_role', iss: 'supabase', iat, exp }
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const jwk = privateKey.export({ format: 'jwk' })
  const kid = crypto.randomUUID()
  const oct = { kty: 'oct', k: Buffer.from(secret).toString('base64url'), alg: 'HS256' }
  const common = { kty: 'EC', kid, use: 'sig', alg: 'ES256', ext: true, crv: jwk.crv, x: jwk.x, y: jwk.y }
  const privateJwk = { ...common, key_ops: ['sign', 'verify'], d: jwk.d }
  const publicJwk = { ...common, key_ops: ['verify'] }
  return {
    COMPOSE_FILE: 'docker-compose.yml:docker-compose.ultrabase-local.yml:docker-compose.logs.yml',
    COMPOSE_PATH_SEPARATOR: ':',
    POSTGRES_PASSWORD: hex(24), JWT_SECRET: secret,
    ANON_KEY: signHs(anon, secret), SERVICE_ROLE_KEY: signHs(service, secret),
    SUPABASE_PUBLISHABLE_KEY: opaque('sb_publishable_'),
    SUPABASE_SECRET_KEY: opaque('sb_secret_'),
    ANON_KEY_ASYMMETRIC: signEs(anon, privateKey, kid),
    SERVICE_ROLE_KEY_ASYMMETRIC: signEs(service, privateKey, kid),
    JWT_KEYS: JSON.stringify([privateJwk, oct]),
    JWT_JWKS: JSON.stringify({ keys: [publicJwk, oct] }),
    DASHBOARD_USERNAME: 'admin@ultrabase.local', DASHBOARD_PASSWORD: hex(24),
    SECRET_KEY_BASE: b64(48), REALTIME_DB_ENC_KEY: hex(8), VAULT_ENC_KEY: hex(16),
    PG_META_CRYPTO_KEY: b64(24), LOGFLARE_PUBLIC_ACCESS_TOKEN: b64(24),
    LOGFLARE_PRIVATE_ACCESS_TOKEN: b64(24), S3_PROTOCOL_ACCESS_KEY_ID: hex(16),
    S3_PROTOCOL_ACCESS_KEY_SECRET: hex(32), MINIO_ROOT_PASSWORD: hex(16),
    SUPABASE_PUBLIC_URL: 'http://127.0.0.1:8000',
    API_EXTERNAL_URL: 'http://127.0.0.1:8000/auth/v1', SITE_URL: 'http://127.0.0.1:3000',
    ADDITIONAL_REDIRECT_URLS: 'http://127.0.0.1:3000/**,http://localhost:3000/**,http://127.0.0.1:5173/**,http://localhost:5173/**',
    POOLER_TENANT_ID: `ultrabase-${hex(8)}`,
    STUDIO_DEFAULT_ORGANIZATION: 'Ultrabase', STUDIO_DEFAULT_PROJECT: 'Ultrabase Local',
    OPENAI_API_KEY: '', ENABLE_EMAIL_SIGNUP: 'true', ENABLE_EMAIL_AUTOCONFIRM: 'true',
    ENABLE_ANONYMOUS_USERS: 'false', ENABLE_PHONE_SIGNUP: 'false',
    ENABLE_PHONE_AUTOCONFIRM: 'false', FUNCTIONS_VERIFY_JWT: 'true',
    SMTP_ADMIN_EMAIL: 'admin@ultrabase.local', SMTP_HOST: 'disabled.local', SMTP_PORT: '2500',
    SMTP_USER: 'disabled', SMTP_PASS: hex(16), SMTP_SENDER_NAME: 'Ultrabase',
    GLOBAL_S3_BUCKET: 'ultrabase-local', REGION: 'local', STORAGE_TENANT_ID: 'ultrabase-local',
    MINIO_ROOT_USER: 'ultrabase-storage', GOOGLE_PROJECT_ID: 'ultrabase-local',
    GOOGLE_PROJECT_NUMBER: '0', PROXY_DOMAIN: 'localhost', CERTBOT_EMAIL: 'admin@ultrabase.local',
  }
}

export function parseEnv(text) {
  const map = new Map()
  for (const line of text.split(/\r?\n/u)) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/u)
    if (!match) continue
    let value = match[2].trim()
    if (value.length > 1 && ((value[0] === '"' && value.at(-1) === '"') || (value[0] === "'" && value.at(-1) === "'"))) value = value.slice(1, -1)
    map.set(match[1], value)
  }
  return map
}

export function renderEnv(template, updates) {
  const seen = new Set()
  const lines = template.split(/\r?\n/u).map((line) => {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=/u)
    if (!match || !Object.hasOwn(updates, match[1])) return line
    seen.add(match[1]); return `${match[1]}=${updates[match[1]]}`
  })
  const missing = Object.keys(updates).filter((key) => !seen.has(key))
  if (missing.length) lines.push('', '############', '# Ultrabase secure local settings', '############', ...missing.map((key) => `${key}=${updates[key]}`))
  return `${lines.join('\n').replace(/\n+$/u, '')}\n`
}

function jwtParts(token) {
  const parts = token.split('.')
  if (parts.length !== 3) throw new Error('JWT must contain three segments')
  return parts
}

export function validateEnv(values) {
  const errors = []
  const need = ['POSTGRES_PASSWORD','JWT_SECRET','ANON_KEY','SERVICE_ROLE_KEY','SUPABASE_PUBLISHABLE_KEY','SUPABASE_SECRET_KEY','ANON_KEY_ASYMMETRIC','SERVICE_ROLE_KEY_ASYMMETRIC','JWT_KEYS','JWT_JWKS','DASHBOARD_USERNAME','DASHBOARD_PASSWORD','SECRET_KEY_BASE','REALTIME_DB_ENC_KEY','VAULT_ENC_KEY','PG_META_CRYPTO_KEY','SUPABASE_PUBLIC_URL','API_EXTERNAL_URL','POOLER_TENANT_ID']
  for (const key of need) if (!values.get(key)) errors.push(`${key} is missing`)
  const bad = ['your-super-secret','this_password_is_insecure','your-32-character','your-encryption-key','your-tenant-id','supabase-demo','secret1234','sk-proj-xxxxxxxx']
  for (const [key, value] of values) if (bad.some((part) => value.toLowerCase().includes(part))) errors.push(`${key} contains an insecure default`)
  for (const key of ['POSTGRES_PASSWORD','JWT_SECRET','DASHBOARD_PASSWORD']) if ((values.get(key) ?? '').length < 32) errors.push(`${key} is shorter than 32 characters`)
  if ((values.get('REALTIME_DB_ENC_KEY') ?? '').length !== 16) errors.push('REALTIME_DB_ENC_KEY must be 16 characters')
  if ((values.get('VAULT_ENC_KEY') ?? '').length !== 32) errors.push('VAULT_ENC_KEY must be 32 characters')
  if (!values.get('SUPABASE_PUBLISHABLE_KEY')?.startsWith('sb_publishable_')) errors.push('publishable key prefix is invalid')
  if (!values.get('SUPABASE_SECRET_KEY')?.startsWith('sb_secret_')) errors.push('secret key prefix is invalid')
  const roles = [['ANON_KEY','anon'],['SERVICE_ROLE_KEY','service_role'],['ANON_KEY_ASYMMETRIC','anon'],['SERVICE_ROLE_KEY_ASYMMETRIC','service_role']]
  for (const [key, role] of roles) try { const p = JSON.parse(Buffer.from(jwtParts(values.get(key) ?? '')[1], 'base64url')); if (p.role !== role || p.exp <= Date.now()/1000) errors.push(`${key} role/expiry is invalid`) } catch (e) { errors.push(`${key} is invalid: ${e.message}`) }
  try {
    const secret = values.get('JWT_SECRET') ?? ''
    for (const key of ['ANON_KEY','SERVICE_ROLE_KEY']) { const p = jwtParts(values.get(key) ?? ''); const expected = crypto.createHmac('sha256', secret).update(`${p[0]}.${p[1]}`).digest(); const actual = Buffer.from(p[2], 'base64url'); if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) errors.push(`${key} failed HS256 verification`) }
    const jwks = JSON.parse(values.get('JWT_JWKS') ?? '{}'); const pub = jwks.keys?.find((key) => key.kty === 'EC' && !key.d)
    if (!pub) errors.push('JWT_JWKS lacks an EC public key')
    else for (const key of ['ANON_KEY_ASYMMETRIC','SERVICE_ROLE_KEY_ASYMMETRIC']) { const p = jwtParts(values.get(key) ?? ''); if (!crypto.verify('SHA256', Buffer.from(`${p[0]}.${p[1]}`), { key: crypto.createPublicKey({ key: pub, format: 'jwk' }), dsaEncoding: 'ieee-p1363' }, Buffer.from(p[2], 'base64url'))) errors.push(`${key} failed ES256 verification`) }
    const privateKeys = JSON.parse(values.get('JWT_KEYS') ?? '[]'); if (!privateKeys.some((key) => key.kty === 'EC' && key.d)) errors.push('JWT_KEYS lacks an EC private key')
  } catch (e) { errors.push(`JWT/JWKS verification failed: ${e.message}`) }
  if (!(values.get('COMPOSE_FILE') ?? '').split(/[:;]/u).includes('docker-compose.ultrabase-local.yml')) errors.push('COMPOSE_FILE lacks the Ultrabase local overlay')
  if (values.get('SUPABASE_PUBLIC_URL') !== 'http://127.0.0.1:8000' || values.get('API_EXTERNAL_URL') !== 'http://127.0.0.1:8000/auth/v1') errors.push('local endpoints are not loopback-only')
  if (values.get('ENABLE_ANONYMOUS_USERS') !== 'false' || values.get('ENABLE_PHONE_SIGNUP') !== 'false' || values.get('FUNCTIONS_VERIFY_JWT') !== 'true') errors.push('secure local auth defaults are disabled')
  return errors
}

export function writeAtomic(target, content) {
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const temp = `${target}.${process.pid}.tmp`; fs.writeFileSync(temp, content, { encoding: 'utf8', mode: 0o600 }); fs.renameSync(temp, target)
  try { fs.chmodSync(target, 0o600) } catch {}
}
