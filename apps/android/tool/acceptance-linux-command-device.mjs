import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream, existsSync } from 'node:fs'
import { stat } from 'node:fs/promises'
import { basename, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const RUNNER = 'com.minnnng.dsh_android.test/com.minnnng.dsh_android.LinuxCommandAcceptanceInstrumentation'
const IMAGE_RUNNER = 'com.minnnng.dsh_android.test/com.minnnng.dsh_android.LinuxImageGuestBridgeInstrumentation'
const IMAGE_INSTALL_RUNNER = 'com.minnnng.dsh_android.test/com.minnnng.dsh_android.LinuxImageInstallationInstrumentation'
const GUEST_STORAGE_RUNNER = 'com.minnnng.dsh_android.test/com.minnnng.dsh_android.GuestStorageProbeInstrumentation'
const PACKAGE = 'com.minnnng.dsh_android'
const PHASES = ['baseline', 'lifecycle']
const EXPECTED = {
  baseline: ['kernel-command-isolated', 'identity-command-matches-child-uid', 'pre-admission-cancel',
    'sha256-stdin', 'apk-packaged-core-boundaries', 'count-and-sort-stdin',
    'literal-filter-stdin', 'literal-filter-no-match',
    'app-rpc-fixed-sha256', 'app-rpc-rejects-test-command-and-cwd'],
  lifecycle: ['apk-packaged-fixed-utility', 'in-flight-cancel', 'guest-deadline',
    'output-limit', 'isolated-worker-death'],
}

function requireArg(args, flag) {
  const at = args.indexOf(flag)
  if (at < 0 || at + 1 >= args.length || args[at + 1].startsWith('--')) {
    throw new Error(`Missing ${flag}`)
  }
  return args[at + 1]
}

async function fingerprint(file) {
  const path = resolve(file)
  const info = await stat(path)
  if (!info.isFile() || info.size < 1) throw new Error(`Invalid APK: ${path}`)
  const digest = createHash('sha256')
  for await (const chunk of createReadStream(path)) digest.update(chunk)
  return { path, bytes: info.size, sha256: digest.digest('hex') }
}

async function adb(adbPath, serial, args, timeout = 120_000) {
  const prefix = serial ? ['-s', serial] : []
  const { stdout, stderr } = await exec(adbPath, [...prefix, ...args], {
    timeout, maxBuffer: 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

export function connectedDevice(output, requestedSerial) {
  const devices = output.split(/\r?\n/).map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state && serial !== 'List' && state !== 'of')
  const authorized = devices.filter(([, state]) => state === 'device').map(([serial]) => serial)
  if (requestedSerial) {
    if (!authorized.includes(requestedSerial)) throw new Error(`ADB device ${requestedSerial} is not connected and authorized`)
    return requestedSerial
  }
  if (authorized.length !== 1) throw new Error(`Expected exactly one authorized ADB device, found ${authorized.length}`)
  return authorized[0]
}

export function parseInstrumentation(output, phase) {
  const value = (key) => {
    const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${key}=(.*)$`, 'gm'))]
    return matches.at(-1)?.[1]?.trim()
  }
  const code = /^INSTRUMENTATION_CODE: (-?\d+)\s*$/m.exec(output)?.[1]
  const passedCount = Number(value('passedCount'))
  const failedCount = Number(value('failedCount'))
  const passed = value('passed') ?? ''
  const failed = value('failed') ?? ''
  const names = passed ? passed.split(',') : []
  const expected = EXPECTED[phase]
  if (code !== '-1' || !Number.isSafeInteger(passedCount) || passedCount < 1 ||
      failedCount !== 0 || failed.length !== 0 || passedCount !== names.length ||
      (expected && expected.some((name) => !names.includes(name)))) {
    throw new Error(`Android ${phase} acceptance failed: ${output.slice(-6000)}`)
  }
  return { phase, passedCount, passed: names }
}

export function parseImageInstrumentation(output) {
  const code = /^INSTRUMENTATION_CODE: (-?\d+)\s*$/m.exec(output)?.[1]
  const result = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)$/gm)].at(-1)?.[1]?.trim()
  if (code !== '-1' || result !== 'linux-image-guest-bridge-pass') {
    throw new Error(`Android image transport acceptance failed: ${output.slice(-6000)}`)
  }
  return { phase: 'image-transport', result }
}

export function parseImageInstallationInstrumentation(output) {
  const code = /^INSTRUMENTATION_CODE: (-?\d+)\s*$/m.exec(output)?.[1]
  const result = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)$/gm)].at(-1)?.[1]?.trim()
  if (code !== '-1' || result !== 'linux-image-install-data-only-pass') {
    throw new Error(`Android image installation acceptance failed: ${output.slice(-6000)}`)
  }
  return { phase: 'image-installation-data-only', result }
}

export function parseGuestStorageProbeInstrumentation(output) {
  const value = (key) => [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${key}=(.*)$`, 'gm'))]
    .at(-1)?.[1]?.trim()
  const code = /^INSTRUMENTATION_CODE: (-?\d+)\s*$/m.exec(output)?.[1]
  const expected = {
    privateRead: 'denied', privateWrite: 'denied', fdRead: 'allowed', fdWrite: 'denied',
    memoryRead: 'allowed', memoryWrite: 'denied',
  }
  const temporary = Object.fromEntries(['tempWrite', 'tempRead', 'tempExec'].map((key) => [key, value(key)]))
  if (code !== '-1' || value('result') !== 'guest-storage-probe-pass' ||
      Object.entries(expected).some(([key, state]) => value(key) !== state) ||
      Object.values(temporary).some((state) => !['allowed', 'denied', 'untested'].includes(state))) {
    throw new Error(`Android isolated guest storage probe failed: ${output.slice(-6000)}`)
  }
  return { phase: 'guest-storage-probe', ...expected, ...temporary }
}

/** The fixed 30-second test child is long enough to expose a missed kill after instrumentation returns. */
export function delayProcessIds(output) {
  const lines = output.split(/\r?\n/).filter(Boolean)
  if (!/^\s*PID\s+(?:ARGS|COMMAND)\s*$/.test(lines[0] ?? '')) {
    throw new Error(`ADB ps did not provide PID and argv columns: ${output.slice(0, 300)}`)
  }
  return new Set(lines.slice(1).flatMap((line) => {
    const match = /^\s*(\d+)\s+(.+?)\s*$/.exec(line)
    if (!match) throw new Error(`Malformed ADB ps row: ${line.slice(0, 300)}`)
    return /(?:^|\/)toybox\s+sleep\s+30(?:\s|$)|^sleep\s+30$/.test(match[2]) ? [Number(match[1])] : []
  }))
}

async function main(args) {
  const apk = await fingerprint(requireArg(args, '--apk'))
  const testApk = await fingerprint(requireArg(args, '--test-apk'))
  if (!apk.path.endsWith('.apk') || !testApk.path.endsWith('.apk') || apk.path === testApk.path) {
    throw new Error('Provide distinct APK and AndroidTest APK paths')
  }
  const sdkAdb = process.env.ANDROID_HOME
    ? resolve(process.env.ANDROID_HOME, 'platform-tools', process.platform === 'win32' ? 'adb.exe' : 'adb')
    : undefined
  const adbPath = args.includes('--adb') ? resolve(requireArg(args, '--adb')) : sdkAdb && existsSync(sdkAdb) ? sdkAdb : 'adb'
  const requestedSerial = args.includes('--serial') ? requireArg(args, '--serial') : undefined
  const serial = connectedDevice(await adb(adbPath, undefined, ['devices']), requestedSerial)
  for (const artifact of [apk, testApk]) {
    const installed = await adb(adbPath, serial, ['install', '-r', artifact.path])
    if (!/^Success\s*$/m.test(installed)) throw new Error(`ADB install failed for ${basename(artifact.path)}: ${installed}`)
  }
  const phases = []
  for (const phase of PHASES) {
    const before = phase === 'lifecycle'
      ? delayProcessIds(await adb(adbPath, serial, ['shell', 'ps', '-A', '-o', 'PID,ARGS'], 15_000))
      : null
    if (before?.size) {
      throw new Error(`Fixed test child existed before lifecycle acceptance: ${[...before].join(',')}`)
    }
    const startedAt = Date.now()
    const result = await adb(adbPath, serial, ['shell', 'am', 'instrument', '-w', '-r',
      '-e', 'phase', phase, RUNNER])
    phases.push(parseInstrumentation(result, phase))
    if (before) {
      if (Date.now() - startedAt >= 25_000) {
        throw new Error('Lifecycle acceptance took too long to exclude naturally exited test children')
      }
      const after = delayProcessIds(await adb(adbPath, serial, ['shell', 'ps', '-A', '-o', 'PID,ARGS'], 15_000))
      if (after.size) throw new Error(`Fixed test child survived cancellation or timeout: ${[...after].join(',')}`)
    }
  }
  if (args.includes('--image')) {
    const result = await adb(adbPath, serial, ['shell', 'am', 'instrument', '-w', '-r', IMAGE_RUNNER])
    phases.push(parseImageInstrumentation(result))
  }
  if (args.includes('--image-install-fixture')) {
    const result = await adb(adbPath, serial, ['shell', 'am', 'instrument', '-w', '-r', IMAGE_INSTALL_RUNNER])
    phases.push(parseImageInstallationInstrumentation(result))
  }
  if (args.includes('--guest-storage-probe')) {
    const result = await adb(adbPath, serial, ['shell', 'am', 'instrument', '-w', '-r', GUEST_STORAGE_RUNNER])
    phases.push(parseGuestStorageProbeInstrumentation(result))
  }
  process.stdout.write(`${JSON.stringify({ package: PACKAGE, serial, apk, testApk, phases })}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`Linux command device acceptance: ${error.message}\n`)
    process.exitCode = 1
  })
}
