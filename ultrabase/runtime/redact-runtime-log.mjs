#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const [envArgument, inputArgument, outputArgument] = process.argv.slice(2)
if (!envArgument || !inputArgument || !outputArgument) {
  console.error('Usage: node redact-runtime-log.mjs <env-file> <input-log> <output-log>')
  process.exit(2)
}

const envPath = resolve(envArgument)
const inputPath = resolve(inputArgument)
const outputPath = resolve(outputArgument)
const values = []
for (const sourceLine of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
  const line = sourceLine.trim()
  if (!line || line.startsWith('#')) continue
  const separator = line.indexOf('=')
  if (separator <= 0) continue
  const value = line.slice(separator + 1).trim().replace(/^(['"])(.*)\1$/, '$2')
  if (value.length >= 8 && !/^https?:\/\//.test(value) && !/^(true|false|null)$/i.test(value)) values.push(value)
}

values.sort((left, right) => right.length - left.length)
let output = readFileSync(inputPath, 'utf8')
for (const value of values) output = output.split(value).join('[REDACTED]')
output = output
  .replace(/(password|secret|token|apikey|authorization)(\s*[=:]\s*)([^\s,;]+)/gi, '$1$2[REDACTED]')
  .replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, 'Bearer [REDACTED]')
writeFileSync(outputPath, output, 'utf8')
console.log(JSON.stringify({ status: 'redacted', input_bytes: readFileSync(inputPath).length, output_bytes: Buffer.byteLength(output) }))
