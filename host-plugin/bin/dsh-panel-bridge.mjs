#!/usr/bin/env node
/**
 * dsh-panel-bridge CLI.
 *
 *   dsh-panel-bridge enable     mount the plugin in a profile (idempotent)
 *   dsh-panel-bridge disable    remove the mount stanza
 *   dsh-panel-bridge status     print the plugin's loopback diag
 *   dsh-panel-bridge qr         print the pairing deep link (+ SVG when asked)
 *
 * Installing is plain npm (`dsh plugin --profile web add dsh-panel-bridge`); the
 * only thing DSH still needs is a loader entry, which `enable` writes and
 * validates. No file copying, no manual YAML editing.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const MARK = '# DS-Harness-HM companion bridge'
const ID = 'panel-bridge'
const PACKAGE = 'dsh-panel-bridge'
const PORT = Number(process.env.PANEL_PORT ?? 3080)

const args = process.argv.slice(2)
const command = args[0] ?? 'help'
const option = (name, fallback) => {
  const i = args.indexOf(`--${name}`)
  const value = i >= 0 && args[i + 1] !== undefined ? args[i + 1].trim() : undefined
  return value !== undefined && value !== '' ? value : fallback
}

const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh')
const profile = option('profile', process.env.PROFILE ?? 'web')
const patchPath = join(dshHome, 'profiles', profile, 'cordis.patch.yml')

function stripBlock(text) {
  const idx = text.indexOf(MARK)
  if (idx !== -1) return text.slice(0, idx).replace(/\s+$/, '') + '\n'
  return text.replace(/\n- insert:\n(?:[ \t].*\n)*?[ \t]+- id: panel-bridge[^\n]*\n(?:[ \t].*\n)*/g, '\n')
}

function mountBlock(publicUrl, inject) {
  const urlLine = publicUrl === '' ? '' : `        publicUrl: '${publicUrl}'\n`
  return `${MARK} (panel-bridge)
# Managed by \`${PACKAGE}\` — npm install + this stanza is all it needs.
- insert:
    - id: ${ID}
      name: ${PACKAGE}
      config:
${urlLine}        approvalTimeoutMs: 120000
        takeOverApprovals: true
        injectBridge: ${inject ? 'true' : 'false'}
`
}

function validate() {
  const dump = spawnSync('dsh', ['--profile', profile, '--dump-config'], { encoding: 'utf8' })
  if (dump.error) return { ok: false, message: `dsh not runnable: ${dump.error.message}` }
  if (dump.status !== 0) {
    const lines = `${dump.stderr || dump.stdout}`.trim().split('\n')
    return { ok: false, message: lines[lines.length - 1] ?? 'unknown error' }
  }
  return { ok: true, lines: dump.stdout.trim().split('\n').length }
}

function enable() {
  if (!existsSync(patchPath)) throw new Error(`profile patch not found: ${patchPath}`)
  const publicUrl = option('public-url', '').replace(/\/+$/, '')
  const inject = args.includes('--inject')
  const next = stripBlock(readFileSync(patchPath, 'utf8')) + '\n' + mountBlock(publicUrl, inject)
  writeFileSync(patchPath, next)
  console.log(`mounted ${PACKAGE} in profile "${profile}"`)
  const check = validate()
  if (!check.ok) throw new Error(`config invalid after enable: ${check.message}`)
  console.log(`config OK (${check.lines} lines)`)
  console.log('restart DSH to load it: dsh web')
}

function disable() {
  writeFileSync(patchPath, stripBlock(readFileSync(patchPath, 'utf8')))
  console.log(`unmounted ${PACKAGE} from profile "${profile}"`)
}

async function status() {
  const res = await fetch(`http://127.0.0.1:${PORT}/api/panel/diag`)
  const body = await res.json()
  console.log(JSON.stringify(body, null, 2))
}

/** Termux hosts keep the log outside the proot home, so try the usual places. */
function findLogFile() {
  const explicit = option('log', process.env.LOG_FILE ?? '')
  const candidates = [
    explicit,
    join(homedir(), 'dsh.log'),
    '/data/data/com.termux/files/home/dsh.log',
    '/var/log/dsh.log'
  ].filter((file) => file !== '')
  for (const file of candidates) {
    if (existsSync(file)) return file
  }
  return ''
}

function tokenFromLog() {
  const logFile = findLogFile()
  if (logFile === '') return ''
  const text = readFileSync(logFile, 'utf8')
  const matches = [...text.matchAll(/token=([A-Za-z0-9_-]{8,})/g)]
  return matches.length > 0 ? matches[matches.length - 1][1] : ''
}

async function qr() {
  const endpoint = option('url', `http://127.0.0.1:${PORT}`)
  const token = option('token', tokenFromLog())
  const data = option('data', token === '' ? '' : `dsh://connect?endpoint=${encodeURIComponent(endpoint)}&token=${encodeURIComponent(token)}`)
  if (data === '') throw new Error('no startup token found; pass --token or --data')
  console.log(`deep link: ${data}`)
  const svg = option('svg', '')
  if (svg !== '') {
    const res = await fetch(`http://127.0.0.1:${PORT}/api/panel/qr?format=svg&data=${encodeURIComponent(data)}`)
    writeFileSync(svg, await res.text())
    console.log(`wrote ${svg}`)
    return
  }
  console.log(`browser QR: http://127.0.0.1:${PORT}/api/panel/qr?data=${encodeURIComponent(data)}`)
}

function help() {
  console.log(`dsh-panel-bridge — DSH host plugin for the HarmonyOS panel client

  dsh-panel-bridge enable [--profile web] [--public-url https://host] [--inject]   mount + validate
  dsh-panel-bridge disable [--profile web]    remove the mount stanza
  dsh-panel-bridge status [--port 3080]       print the loopback diag
  dsh-panel-bridge qr [--url …] [--svg out.svg]   pairing deep link + QR

Install:
  dsh plugin --profile web add ${PACKAGE}
  dsh-panel-bridge enable
  dsh web`)
}

try {
  switch (command) {
    case 'enable': enable(); break
    case 'disable': disable(); break
    case 'status': await status(); break
    case 'qr': await qr(); break
    default: help()
  }
} catch (error) {
  console.error(`dsh-panel-bridge: ${error.message}`)
  process.exit(1)
}
