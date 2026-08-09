#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { parseEnv } from '../lib/env-core.mjs'

const [envPath, inputPath, outputPath] = process.argv.slice(2)
if (!envPath || !inputPath || !outputPath) {
  console.error('Usage: node redact-log.mjs ENV INPUT OUTPUT')
  process.exit(2)
}

let text = fs.readFileSync(inputPath, 'utf8')
const values = [...parseEnv(fs.readFileSync(envPath, 'utf8')).entries()]
  .filter(([, value]) => value.length >= 8)
  .sort((a, b) => b[1].length - a[1].length)

for (const [key, value] of values) {
  text = text.split(value).join(`[REDACTED:${key}]`)
}
fs.mkdirSync(path.dirname(outputPath), { recursive: true })
fs.writeFileSync(outputPath, text, 'utf8')
