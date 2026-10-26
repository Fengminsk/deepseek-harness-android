import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.GuestStorageProbeInstrumentation`
const SERVICE = `${PACKAGE}.DebugGuestStorageProbeService`
const REQUIRED = {
  privateRead: 'denied', privateWrite: 'denied', fdRead: 'allowed',
  fdWrite: 'denied', directoryChildRead: 'denied', directoryChildWrite: 'denied',
  memoryRead: 'allowed', memoryWrite: 'denied',
}
const TEMP = ['tempWrite', 'tempRead', 'tempExec', 'tempExecMap']
const STATES = new Set(['allowed', 'denied', 'untested'])

function argument(args, flag) {
  const at = args.indexOf(flag)
  if (at < 0 || at + 1 >= args.length || args[at + 1].startsWith('--')) {
    throw new Error(`Missing ${flag}`)
  }
  return args[at + 1]
}

async function run(binary, args, timeout = 120_000) {
  const { stdout, stderr } = await exec(binary, args, {
    timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

async function fingerprint(input) {
  const path = resolve(input)
  const info = await stat(path)
  if (!path.endsWith('.apk') || !info.isFile() || info.size < 1) {
    throw new Error(`Invalid APK: ${path}`)
  }
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

function declarations(xml, element) {
  const lines = xml.split(/\r?\n/)
  const found = []
  for (let index = 0; index < lines.length; index++) {
    const start = new RegExp(`^(\\s*)E: ${element}(?:\\s|$)`).exec(lines[index])
    if (!start) continue
    const block = []
    while (++index < lines.length) {
      const next = /^(\s*)E: /.exec(lines[index])
      if (next && next[1].length <= start[1].length) break
      block.push(lines[index])
    }
    found.push(block.join('\n'))
    index--
  }
  return found
}

function attribute(block, name) {
  const match = new RegExp(`android:${name}[^\\r\\n]*=(?:"([^"]+)"|(true|false))`).exec(block)
  return match?.[1] ?? match?.[2]
}

/** Preflight requires a debug-only isolated Service and its Agent-process test entry. */
export function requireStorageProbeDeclarations(appXml, testXml) {
  const services = declarations(appXml, 'service').filter(block =>
    attribute(block, 'name') === SERVICE &&
    attribute(block, 'process') === ':guest_storage_probe' &&
    attribute(block, 'isolatedProcess') === 'true' &&
    attribute(block, 'exported') === 'false')
  const runners = declarations(testXml, 'instrumentation').filter(block =>
    attribute(block, 'name') === `${PACKAGE}.GuestStorageProbeInstrumentation` &&
    attribute(block, 'targetPackage') === PACKAGE &&
    attribute(block, 'targetProcesses') === `${PACKAGE}:agent`)
  if (services.length !== 1 || runners.length !== 1) {
    throw new Error('APKs lack the exact private isolated guest storage probe declarations')
  }
}

/** Debug native syscall probe must be in the signed app, once and for ARM64. */
export function requireStorageProbeLibrary(entries) {
  const found = entries.split(/\r?\n/).filter(entry =>
    entry === 'lib/arm64-v8a/libpocket_guest_storage_probe.so')
  if (found.length !== 1) throw new Error('App APK lacks the exact debug guest storage probe library')
}

/** Only a complete read-only FD result is a pass; temp observations are data. */
export function parseStorageProbeResult(output) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const field = name => {
    const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${name}=(.*)$`, 'gm'))]
    if (matches.length !== 1) throw new Error(`Missing or duplicate ${name} storage observation`)
    return matches[0][1].trim()
  }
  if (codes.length !== 1 || codes[0][1] !== '-1' ||
      field('result') !== 'guest-storage-probe-pass' ||
      field('state') !== 'observed' || field('isolated') !== 'true' ||
      !/^\d+$/.test(field('uid')) || Number(field('uid')) < 1) {
    throw new Error('Guest storage device probe did not complete in an isolated UID')
  }
  const required = Object.fromEntries(Object.entries(REQUIRED).map(([key, expected]) => {
    const actual = field(key)
    if (actual !== expected) throw new Error(`Guest storage ${key} was ${actual}, expected ${expected}`)
    return [key, actual]
  }))
  const temp = Object.fromEntries(TEMP.map(key => {
    const value = field(key)
    if (!STATES.has(value)) throw new Error(`Guest storage ${key} is not an observation`)
    return [key, value]
  }))
  return { required, temp }
}

async function main(args) {
  const [app, testApk] = await Promise.all([
    fingerprint(argument(args, '--apk')), fingerprint(argument(args, '--test-apk')),
  ])
  if (app.path === testApk.path) throw new Error('App and AndroidTest APK must differ')
  const tools = await sdkTools()
  const inspect = async artifact => ({
    ...parseBadging(await run(tools.aapt2, ['dump', 'badging', artifact.path], 30_000)),
    certificate: parseCertificate(await run('java', ['-jar', tools.apksigner,
      'verify', '--print-certs', artifact.path], 30_000)),
  })
  const [appIdentity, testIdentity] = await Promise.all([inspect(app), inspect(testApk)])
  if (appIdentity.packageName !== PACKAGE || testIdentity.packageName !== `${PACKAGE}.test` ||
      appIdentity.certificate !== testIdentity.certificate) {
    throw new Error('App and AndroidTest APK package or signing identity differs')
  }
  const [appXml, testXml] = await Promise.all([app.path, testApk.path].map(path =>
    run(tools.aapt2, ['dump', 'xmltree', '--file', 'AndroidManifest.xml', path], 30_000)))
  requireStorageProbeDeclarations(appXml, testXml)
  requireStorageProbeLibrary(await run('jar', ['tf', app.path], 30_000))
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass',
      app: { ...app, ...appIdentity }, testApk: { ...testApk, ...testIdentity } }, null, 2) + '\n')
    return
  }
  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15_000),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  const existed = parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15_000))
  if (existed && !args.includes('--allow-existing')) {
    throw new Error('App already installed; pass --allow-existing only after authorizing this test on that installation')
  }
  for (const artifact of [app, testApk]) {
    const installed = await device(['install', '-r', artifact.path], 120_000)
    if (!/^Success\s*$/m.test(installed)) throw new Error(`ADB install failed: ${installed}`)
  }
  const result = parseStorageProbeResult(await device(['shell', 'am', 'instrument', '-w', '-r', RUNNER], 90_000))
  process.stdout.write(JSON.stringify({ result: 'pass', serial, app: { ...app, ...appIdentity },
    testApk: { ...testApk, ...testIdentity }, ...result }, null, 2) + '\n')
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  })
}
