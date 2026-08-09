#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { generateValues, parseEnv, renderEnv, validateEnv, writeAtomic } from './lib/env-core.mjs'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const opt = {
  env: path.join(root, 'docker', '.env'),
  template: path.join(root, 'docker', '.env.example'),
  force: false,
  check: false,
  json: false,
}

for (let i = 2; i < process.argv.length; i++) {
  const argument = process.argv[i]
  if (argument === '--env') opt.env = path.resolve(process.argv[++i])
  else if (argument === '--template') opt.template = path.resolve(process.argv[++i])
  else if (argument === '--force') opt.force = true
  else if (argument === '--check') opt.check = true
  else if (argument === '--json') opt.json = true
  else throw new Error(`Unknown argument: ${argument}`)
}

const output = (status) => console.log(
  opt.json
    ? JSON.stringify({ status, path: opt.env, secrets_printed: false })
    : `Ultrabase environment ${status}: ${opt.env}`
)

try {
  if (opt.check) {
    if (!fs.existsSync(opt.env)) throw new Error(`Environment file not found: ${opt.env}`)
    const errors = validateEnv(parseEnv(fs.readFileSync(opt.env, 'utf8')))
    if (errors.length) throw new Error(errors.join('\n- '))
    output('valid')
    process.exit(0)
  }

  if (fs.existsSync(opt.env) && !opt.force) {
    const errors = validateEnv(parseEnv(fs.readFileSync(opt.env, 'utf8')))
    if (!errors.length) {
      output('valid')
      process.exit(0)
    }
    throw new Error(`Existing environment is invalid and was not changed:\n- ${errors.join('\n- ')}\nUse --force only before database initialization.`)
  }

  if (!fs.existsSync(opt.template)) throw new Error(`Template not found: ${opt.template}`)
  const text = renderEnv(fs.readFileSync(opt.template, 'utf8'), generateValues())
  const errors = validateEnv(parseEnv(text))
  if (errors.length) throw new Error(`Generated environment failed validation:\n- ${errors.join('\n- ')}`)

  writeAtomic(opt.env, text)
  output('generated securely')
} catch (error) {
  console.error(`ERROR: ${error.message}`)
  process.exit(1)
}
