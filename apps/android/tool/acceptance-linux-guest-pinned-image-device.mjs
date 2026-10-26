import { randomUUID, createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream, existsSync } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { verifyLockedAlpineRootfs } from './linux-userland-source-lock.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.LinuxGuestPinnedImageInstrumentation`

function argument(args, flag) {
  const index = args.indexOf(flag)
  if (index < 0 || !args[index + 1] || args[index + 1].startsWith('--')) {
    throw new Error(`Missing ${flag}`)
  }
  return args[index + 1]
}

async function apkIdentity(input) {
  const path = resolve(input)
  const info = await stat(path)
  if (!info.isFile() || !path.endsWith('.apk')) throw new Error(`Invalid APK: ${path}`)
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

function deviceSerial(output, requested) {
  const devices = output.split(/\r?\n/).map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state === 'device').map(([serial]) => serial)
  if (requested) {
    if (!devices.includes(requested)) throw new Error(`ADB device ${requested} is not authorized`)
    return requested
  }
  if (devices.length !== 1) throw new Error(`Expected one authorized ADB device, found ${devices.length}`)
  return devices[0]
}

export function parsePinnedImageResult(output) {
  const field = (key) => [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${key}=(.*)$`, 'gm'))]
    .at(-1)?.[1]?.trim()
  const code = /^INSTRUMENTATION_CODE: (-?\d+)\s*$/m.exec(output)?.[1]
  if (code !== '-1' || field('result') !== 'pinned-image-stage-and-retire-pass') {
    throw new Error(`Pinned image staging is unverified: ${output.slice(-4000)}`)
  }
  return { result: field('result'), sha256: field('sha256') }
}

async function main(args) {
  const apk = await apkIdentity(argument(args, '--apk'))
  const testApk = await apkIdentity(argument(args, '--test-apk'))
  if (apk.path === testApk.path) throw new Error('Main and AndroidTest APK must differ')
  const archivePath = resolve(argument(args, '--archive'))
  const archive = await verifyLockedAlpineRootfs(archivePath)
  const candidateAdb = process.env.ANDROID_HOME
    ? resolve(process.env.ANDROID_HOME, 'platform-tools', process.platform === 'win32' ? 'adb.exe' : 'adb')
    : null
  const adbPath = args.includes('--adb') ? resolve(argument(args, '--adb'))
    : candidateAdb && existsSync(candidateAdb) ? candidateAdb : 'adb'
  const invoke = async (serial, command, timeout = 120_000) => {
    const { stdout, stderr } = await exec(adbPath, [...(serial ? ['-s', serial] : []), ...command],
      { timeout, maxBuffer: 1024 * 1024, windowsHide: true })
    return `${stdout}${stderr}`
  }
  const serial = deviceSerial(await invoke(null, ['devices']),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  for (const artifact of [apk, testApk]) {
    const output = await invoke(serial, ['install', '-r', artifact.path])
    if (!/^Success\s*$/m.test(output)) throw new Error(`ADB APK install failed: ${output}`)
  }
  const name = `linux-guest-pinned-probe-${randomUUID()}.tar.gz`
  const deviceTemp = `/data/local/tmp/${name}`
  const appFixture = `cache/${name}`
  try {
    await invoke(serial, ['push', archivePath, deviceTemp])
    await invoke(serial, ['shell', 'run-as', PACKAGE, 'cp', deviceTemp, appFixture])
    await invoke(serial, ['shell', 'run-as', PACKAGE, 'chmod', '600', appFixture])
    const output = await invoke(serial, ['shell', 'am', 'instrument', '-w', '-r',
      '-e', 'fixture', name, RUNNER], 120_000)
    const receipt = parsePinnedImageResult(output)
    if (receipt.sha256 !== archive.sha256) throw new Error('Device receipt digest differs from source lock')
    process.stdout.write(`${JSON.stringify({ serial, apk, testApk, archive,
      device: receipt, claim: 'data-staging-only' })}\n`)
  } finally {
    // Exact unique fixture only. A failed cleanup is surfaced because a leaked copy matters.
    const results = await Promise.allSettled([
      invoke(serial, ['shell', 'run-as', PACKAGE, 'rm', '-f', appFixture]),
      invoke(serial, ['shell', 'rm', '-f', deviceTemp]),
    ])
    const failed = results.filter((result) => result.status === 'rejected')
    if (failed.length) throw new Error(`Pinned image device fixture cleanup failed: ${failed.length} path(s)`)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error.stack ?? error}\n`)
    process.exitCode = 1
  })
}
