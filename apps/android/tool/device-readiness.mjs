import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { closeSync, openSync, readSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const PACKAGE = 'com.minnnng.dsh_android'
const OVERLAY_TITLE = 'Pocket Harness task overlay'

export function parseDevices(output) {
  return output.split(/\r?\n/).map((line) => line.trim()).filter((line) => {
    return line && !line.startsWith('*') && !line.startsWith('List of devices attached')
  }).map((line) => {
    const [serial, state] = line.split(/\s+/, 3)
    return { serial, state }
  }).filter(({ serial, state }) => Boolean(serial && state))
}

export function parsePackageVersion(output) {
  const value = /\bversionCode=(\d+)\b/.exec(output)?.[1]
  return value === undefined ? null : Number(value)
}

export function parseOverlayPermission(output) {
  const value = /\bSYSTEM_ALERT_WINDOW:\s*(allow|deny|ignore|default|foreground)\b/i.exec(output)?.[1]
  return value?.toLowerCase() ?? 'not-reported'
}

function adbCall(adb, args) {
  return execFileSync(adb, args, {
    encoding: 'utf8', timeout: 8000, maxBuffer: 4 * 1024 * 1024,
    windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  }).trim()
}

function sha256File(path) {
  const hash = createHash('sha256')
  const buffer = Buffer.allocUnsafe(1024 * 1024)
  const fd = openSync(path, 'r')
  try {
    let count
    while ((count = readSync(fd, buffer, 0, buffer.length, null)) > 0) {
      hash.update(buffer.subarray(0, count))
    }
    return hash.digest('hex')
  } finally {
    closeSync(fd)
  }
}

/** Read-only device facts used to schedule a short acceptance run. */
export function inspectDevice({ adb = 'adb', apkPath, expectedSha256, run = adbCall }) {
  if (!apkPath || !/^[a-f0-9]{64}$/i.test(expectedSha256 ?? '')) {
    throw new Error('Pass --apk and a 64-character --sha256 for the prepared APK')
  }
  const absoluteApk = resolve(apkPath)
  const size = statSync(absoluteApk).size
  const actualSha256 = sha256File(absoluteApk)
  const report = {
    schemaVersion: 1,
    apk: { path: absoluteApk, bytes: size, sha256: actualSha256, matched: actualSha256 === expectedSha256.toLowerCase() },
    device: { state: 'unavailable' },
  }
  if (!report.apk.matched) return report

  let devices
  try {
    devices = parseDevices(run(adb, ['devices', '-l']))
  } catch {
    report.device = { state: 'adb-unavailable' }
    return report
  }
  if (devices.length === 0) {
    report.device = { state: 'not-connected' }
    return report
  }
  if (devices.length !== 1) {
    report.device = { state: 'ambiguous', count: devices.length }
    return report
  }
  const [{ serial, state }] = devices
  if (state !== 'device') {
    report.device = { state, serial }
    return report
  }

  // Every query is read-only. An unavailable probe stays unknown, never false.
  const call = (args, parse) => {
    try {
      return { ok: true, value: parse(run(adb, ['-s', serial, ...args])) }
    } catch {
      return { ok: false, error: 'unavailable' }
    }
  }
  report.device = {
    state: 'connected', serial,
    apiLevel: call(['shell', 'getprop', 'ro.build.version.sdk'], (s) => Number(s.trim()) || null),
    abi: call(['shell', 'getprop', 'ro.product.cpu.abilist'], (s) => s.trim().split(',').filter(Boolean)),
    installedPath: call(['shell', 'pm', 'path', PACKAGE], (s) => s.startsWith('package:')),
    installedVersionCode: call(['shell', 'dumpsys', 'package', PACKAGE], parsePackageVersion),
    overlayPermission: call(['shell', 'cmd', 'appops', 'get', PACKAGE, 'SYSTEM_ALERT_WINDOW'], parseOverlayPermission),
    overlayWindow: call(['shell', 'dumpsys', 'window', 'windows'], (s) => s.includes(OVERLAY_TITLE)),
    agentPid: call(['shell', 'pidof', `${PACKAGE}:agent`], (s) => s.trim() || null),
  }
  return report
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const values = new Map()
  for (let i = 2; i < process.argv.length; i += 2) values.set(process.argv[i], process.argv[i + 1])
  try {
    const result = inspectDevice({
      adb: values.get('--adb') ?? 'adb',
      apkPath: values.get('--apk'),
      expectedSha256: values.get('--sha256'),
    })
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
    if (!result.apk.matched || result.device.state !== 'connected') process.exitCode = 2
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : 'Device readiness failed'}\n`)
    process.exitCode = 1
  }
}
