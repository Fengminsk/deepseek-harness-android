import { createHash, randomBytes } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { createReadStream, existsSync } from 'node:fs'
import { readdir, stat } from 'node:fs/promises'
import { basename, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.UpgradePersistenceInstrumentation`
const DIGEST = /^[0-9a-f]{64}$/
const TOKEN = /^[0-9a-f]{32}$/

function argument(args, flag) {
  const index = args.indexOf(flag)
  if (index < 0 || index + 1 >= args.length || args[index + 1].startsWith('--')) {
    throw new Error(`Missing ${flag}`)
  }
  return args[index + 1]
}

async function fingerprint(file) {
  const path = resolve(file)
  const info = await stat(path)
  if (!info.isFile() || info.size < 1 || info.size > 1024 * 1024 * 1024 || !path.endsWith('.apk')) {
    throw new Error(`Invalid APK: ${path}`)
  }
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

async function run(file, args, timeout = 120_000) {
  const { stdout, stderr } = await exec(file, args, {
    timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

function versionParts(value) { return value.split('.').map(Number) }

export async function sdkTools() {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT
  if (!sdk) throw new Error('ANDROID_HOME or ANDROID_SDK_ROOT is required')
  const builds = join(resolve(sdk), 'build-tools')
  const versions = (await readdir(builds, { withFileTypes: true }))
    .filter(entry => entry.isDirectory() && /^\d+\.\d+\.\d+$/.test(entry.name))
    .map(entry => entry.name)
    .sort((left, right) => {
      const a = versionParts(left), b = versionParts(right)
      return b[0] - a[0] || b[1] - a[1] || b[2] - a[2]
    })
  const suffix = process.platform === 'win32' ? '.exe' : ''
  for (const version of versions) {
    const root = join(builds, version)
    const aapt2 = join(root, `aapt2${suffix}`)
    const apksigner = join(root, 'lib', 'apksigner.jar')
    if (existsSync(aapt2) && existsSync(apksigner)) {
      const adb = join(resolve(sdk), 'platform-tools', `adb${suffix}`)
      if (!existsSync(adb)) throw new Error('Android SDK adb is unavailable')
      return { aapt2, apksigner, adb }
    }
  }
  throw new Error('Android SDK aapt2 and apksigner.jar are unavailable')
}

export function parseBadging(output) {
  const line = /^package: name='([^']+)' versionCode='(\d*)' versionName='([^']*)'/m.exec(output)
  if (!line) throw new Error('APK manifest package/version could not be read')
  const versionCode = line[2] ? Number(line[2]) : null
  if (versionCode !== null && (!Number.isSafeInteger(versionCode) || versionCode < 0)) {
    throw new Error('APK versionCode is invalid')
  }
  return { packageName: line[1], versionCode, versionName: line[3] }
}

export function parseCertificate(output) {
  const matches = [...output.matchAll(/^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$/gm)]
  if (matches.length !== 1) throw new Error('Exactly one APK signing certificate is required')
  return matches[0][1].toLowerCase()
}

export function validateArtifacts(old, next, test) {
  if (old.packageName !== PACKAGE || next.packageName !== PACKAGE ||
      test.packageName !== `${PACKAGE}.test`) throw new Error('APK package identity differs')
  if (!Number.isSafeInteger(old.versionCode) || !Number.isSafeInteger(next.versionCode) ||
      next.versionCode <= old.versionCode) throw new Error('The new APK must increase versionCode')
  if (!DIGEST.test(old.certificate) || old.certificate !== next.certificate ||
      old.certificate !== test.certificate) throw new Error('APK signing certificates differ')
  return { oldVersionCode: old.versionCode, newVersionCode: next.versionCode,
    certificate: old.certificate }
}

export function requireUpgradeInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter(block => {
    const name = /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const target = /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const process = /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    return name === `${PACKAGE}.UpgradePersistenceInstrumentation` &&
      target === PACKAGE && process === `${PACKAGE}:agent`
  })
  if (matches.length !== 1) {
    throw new Error('AndroidTest APK lacks the one expected upgrade instrumentation in the Agent process')
  }
}

export function connectedDevice(output, requested) {
  const lines = output.split(/\r?\n/).slice(1)
  const devices = lines.map(line => /^([^\s]+)\s+(device|unauthorized|offline)(?:\s|$)/.exec(line))
    .filter(Boolean).map(match => ({ serial: match[1], state: match[2] }))
  const authorized = devices.filter(device => device.state === 'device').map(device => device.serial)
  if (requested) {
    if (!authorized.includes(requested)) throw new Error(`ADB device ${requested} is not connected and authorized`)
    return requested
  }
  if (authorized.length !== 1) throw new Error(`Expected one authorized ADB device, found ${authorized.length}`)
  return authorized[0]
}

export function parseInstalledPath(output) {
  const text = output.trim()
  if (!text) return false
  if (text.split(/\r?\n/).some(line => !/^package:\/[^\r\n]+$/.test(line))) {
    throw new Error(`Unexpected pm path result: ${text.slice(0, 300)}`)
  }
  return true
}

export function parseInstalledVersion(output, packageName = PACKAGE) {
  const escaped = packageName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const header = new RegExp(`^\\s*Package \\[${escaped}\\] \\([^\\r\\n]+\\):`, 'm').exec(output)
  if (!header) throw new Error('Installed package entry is unavailable')
  const remainder = output.slice(header.index + header[0].length)
  const next = /^\s*Package \[/m.exec(remainder)?.index ?? remainder.length
  const match = /^\s*versionCode=(\d+)(?:\s|$)/m.exec(remainder.slice(0, next))
  if (!match) throw new Error('Installed package versionCode is unavailable')
  const code = Number(match[1])
  if (!Number.isSafeInteger(code)) throw new Error('Installed package versionCode is invalid')
  return code
}

export function parseInstrumentation(output, expectedPhase, token, expected = null,
  { requireSafGrant = false, requireOffline = false, requireSafReadable = false, requireSessionFiles = false } = {}) {
  if (!TOKEN.test(token)) throw new Error('Invalid upgrade test token')
  const values = new Map()
  for (const match of output.matchAll(/^INSTRUMENTATION_RESULT: ([A-Za-z][A-Za-z0-9]*)=(.*)$/gm)) {
    if (values.has(match[1])) throw new Error(`Duplicate instrumentation field ${match[1]}`)
    values.set(match[1], match[2].trim())
  }
  const code = /^INSTRUMENTATION_CODE: (-?\d+)\s*$/m.exec(output)?.[1]
  const versionCode = Number(values.get('versionCode'))
  const canarySha256 = values.get('canarySha256')
  const credentialSha256 = values.get('credentialSha256')
  const safGrantSha256 = values.get('safGrantSha256')
  const safRootSha256 = values.get('safRootSha256')
  const safDocumentIdSha256 = values.get('safDocumentIdSha256')
  const safDocumentSha256 = values.get('safDocumentSha256')
  const safDocumentBytesText = values.get('safDocumentBytes')
  const safDocumentBytes = /^(0|[1-9]\d*)$/.test(safDocumentBytesText ?? '')
    ? Number(safDocumentBytesText) : NaN
  const sessionFilesSha256 = values.get('sessionFilesSha256')
  const sessionFileCount = Number(values.get('sessionFileCount'))
  const sessionFileBytes = Number(values.get('sessionFileBytes'))
  const grantCountText = values.get('safGrantCount')
  const safGrantCount = /^(0|[1-9]\d*)$/.test(grantCountText ?? '') ? Number(grantCountText) : NaN
  const pidText = values.get('processPid')
  const processPid = /^[1-9]\d*$/.test(pidText ?? '') ? Number(pidText) : NaN
  const networkCountText = values.get('internetNetworkCount')
  const internetNetworkCount = /^(0|[1-9]\d*)$/.test(networkCountText ?? '')
    ? Number(networkCountText) : NaN
  if (code !== '-1' || values.get('passed') !== 'true' ||
      values.get('phase') !== expectedPhase || values.get('token') !== token ||
      !Number.isSafeInteger(versionCode) || versionCode < 1 ||
      !Number.isSafeInteger(processPid) || processPid < 1 ||
      !Number.isSafeInteger(safGrantCount) ||
      (requireSafGrant && safGrantCount < 1) ||
      !Number.isSafeInteger(internetNetworkCount) ||
      (requireOffline && internetNetworkCount !== 0) ||
      !DIGEST.test(canarySha256 ?? '') || !DIGEST.test(credentialSha256 ?? '') ||
      !DIGEST.test(safGrantSha256 ?? '') ||
      (requireSessionFiles && (!DIGEST.test(sessionFilesSha256 ?? '') ||
        !Number.isSafeInteger(sessionFileCount) || sessionFileCount < 1 || sessionFileCount > 20000 ||
        !Number.isSafeInteger(sessionFileBytes) || sessionFileBytes < 1 || sessionFileBytes > 512 * 1024 * 1024 ||
        (expected && (sessionFilesSha256 !== expected.sessionFilesSha256 ||
          sessionFileCount !== expected.sessionFileCount || sessionFileBytes !== expected.sessionFileBytes)))) ||
      (requireSafReadable && (!DIGEST.test(safRootSha256 ?? '') ||
        !DIGEST.test(safDocumentIdSha256 ?? '') ||
        !DIGEST.test(safDocumentSha256 ?? '') ||
        !Number.isSafeInteger(safDocumentBytes) || safDocumentBytes > 16 * 1024 * 1024)) ||
      (expected && (canarySha256 !== expected.canarySha256 ||
        credentialSha256 !== expected.credentialSha256 ||
        safGrantCount !== expected.safGrantCount ||
        safGrantSha256 !== expected.safGrantSha256 ||
        (requireSafReadable && (safRootSha256 !== expected.safRootSha256 ||
          safDocumentIdSha256 !== expected.safDocumentIdSha256 ||
          safDocumentSha256 !== expected.safDocumentSha256 ||
          safDocumentBytes !== expected.safDocumentBytes)))) ||
      (expectedPhase === 'cleanup' && values.get('cleaned') !== 'true')) {
    throw new Error(`Android ${expectedPhase} upgrade acceptance failed: ${output.slice(-4000)}`)
  }
  return { phase: expectedPhase, token, versionCode, processPid, canarySha256,
    credentialSha256, safGrantCount, safGrantSha256, internetNetworkCount,
    ...(requireSessionFiles ? { sessionFilesSha256, sessionFileCount, sessionFileBytes } : {}),
    ...(requireSafReadable ? { safRootSha256, safDocumentIdSha256, safDocumentSha256,
      safDocumentBytes } : {}),
    ...(expectedPhase === 'cleanup' ? { cleaned: true } : {}) }
}

export function validateSafReadableOption(path, existed, allowExisting) {
  if (path === undefined) return false
  if (typeof path !== 'string' || path.length < 1 || path.length > 1024 ||
      /[\p{Cc}\p{Cf}]/u.test(path) ||
      path.startsWith('/') || path.endsWith('/') ||
      path.split('/').length > 16 ||
      path.split('/').some(segment => !segment || segment === '.' || segment === '..' ||
        segment.length > 255 || segment.includes('\\') || segment.includes('\0'))) {
    throw new Error('Invalid --saf-readable-path: use a relative path inside an existing SAF tree grant')
  }
  if (!existed || !allowExisting) {
    throw new Error('SAF document readability verification requires the existing old App and --allow-existing')
  }
  return true
}

export function encodeSafReadablePath(path) {
  return Buffer.from(path, 'utf8').toString('base64url')
}

export function parseAgentPids(output) {
  const value = output.trim()
  if (!value) return []
  const parts = value.split(/\s+/)
  if (parts.some(part => !/^[1-9]\d*$/.test(part) || !Number.isSafeInteger(Number(part)))) {
    throw new Error(`Unexpected Agent PID result: ${value.slice(0, 300)}`)
  }
  return parts.map(Number)
}

export function parseHoldStatus(output, token) {
  const block = output.split(/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m)[0]
  if (block === output) return null
  const values = new Map()
  for (const match of block.matchAll(/^INSTRUMENTATION_STATUS: ([A-Za-z][A-Za-z0-9]*)=(.*)$/gm)) {
    if (values.has(match[1])) throw new Error(`Duplicate hold status field ${match[1]}`)
    values.set(match[1], match[2].trim())
  }
  const pid = values.get('processPid')
  if (values.get('holdReady') !== 'true' || values.get('token') !== token ||
      !/^[1-9]\d*$/.test(pid ?? '') || !Number.isSafeInteger(Number(pid))) {
    throw new Error('Agent hold status does not match this acceptance run')
  }
  return Number(pid)
}

function startHold(adb, serial, extras, token) {
  const child = spawn(adb, ['-s', serial, 'shell', 'am', 'instrument', '-w', '-r', ...extras, RUNNER], {
    windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  })
  let output = ''
  let closed = false
  let resolveDone
  const done = new Promise(resolve => { resolveDone = resolve })
  let resolveReady, rejectReady
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const timeout = setTimeout(() => rejectReady(new Error('Agent hold did not become ready')), 30_000)
  const accept = chunk => {
    output += chunk.toString('utf8')
    if (output.length > 2 * 1024 * 1024) {
      rejectReady(new Error('Agent hold instrumentation output exceeded 2 MiB'))
      child.kill()
      return
    }
    try {
      const pid = parseHoldStatus(output, token)
      if (pid !== null) { clearTimeout(timeout); resolveReady(pid) }
    } catch (error) { clearTimeout(timeout); rejectReady(error) }
  }
  child.stdout.on('data', accept)
  child.stderr.on('data', accept)
  child.on('error', error => { clearTimeout(timeout); rejectReady(error) })
  child.on('close', (code, signal) => {
    closed = true
    clearTimeout(timeout)
    rejectReady(new Error(`Agent hold exited before force-stop: ${output.slice(-1200)}`))
    resolveDone({ code, signal, output })
  })
  return { ready, done, get closed() { return closed }, stopClient: () => child.kill() }
}

async function main(args) {
  const oldApk = await fingerprint(argument(args, '--old-apk'))
  const newApk = await fingerprint(argument(args, '--new-apk'))
  const testApk = await fingerprint(argument(args, '--test-apk'))
  const oldTestApk = args.includes('--old-test-apk')
    ? await fingerprint(argument(args, '--old-test-apk')) : testApk
  if (new Set([oldApk.path, newApk.path, testApk.path]).size !== 3) {
    throw new Error('Old, new and AndroidTest APKs must be distinct')
  }
  const tools = await sdkTools()
  const inspect = async artifact => ({
    ...parseBadging(await run(tools.aapt2, ['dump', 'badging', artifact.path], 30_000)),
    certificate: parseCertificate(await run('java', ['-jar', tools.apksigner,
      'verify', '--print-certs', artifact.path], 30_000)),
  })
  const [old, next, test] = await Promise.all([inspect(oldApk), inspect(newApk), inspect(testApk)])
  const identity = validateArtifacts(old, next, test)
  requireUpgradeInstrumentation(await run(tools.aapt2,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30_000))
  if (oldTestApk !== testApk) {
    const oldTest = await inspect(oldTestApk)
    if (oldTest.packageName !== `${PACKAGE}.test` || oldTest.certificate !== identity.certificate) {
      throw new Error('Old instrumentation package or signer differs')
    }
    requireUpgradeInstrumentation(await run(tools.aapt2,
      ['dump', 'xmltree', '--file', 'AndroidManifest.xml', oldTestApk.path], 30_000))
  }
  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15_000),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  const existed = parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15_000))
  const safReadablePath = args.includes('--saf-readable-path')
    ? argument(args, '--saf-readable-path') : undefined
  const requireSafReadable = validateSafReadableOption(safReadablePath, existed,
    args.includes('--allow-existing'))
  const requireSafGrant = args.includes('--require-saf-grant') || requireSafReadable
  const requireOffline = args.includes('--require-device-offline')
  const requireSessionFiles = args.includes('--require-session-files')
  if (requireSessionFiles && (!existed || !args.includes('--allow-existing'))) {
    throw new Error('Session file verification requires the existing old App and --allow-existing')
  }
  if (requireSafGrant && (!existed || !args.includes('--allow-existing'))) {
    throw new Error('SAF grant verification requires the existing old App and --allow-existing')
  }
  if (existed && !args.includes('--allow-existing')) {
    throw new Error('App already installed; --allow-existing is required to preserve and use this existing installation')
  }
  if (existed && parseInstalledVersion(await device(['shell', 'dumpsys', 'package', PACKAGE], 15_000)) !== old.versionCode) {
    throw new Error('Installed App version differs from the old APK; refusing a downgrade or unreviewed replacement')
  }
  const install = async artifact => {
    const output = await device(['install', '-r', artifact.path], 300_000)
    if (!/^Success\s*$/m.test(output)) throw new Error(`ADB install failed for ${basename(artifact.path)}: ${output.slice(-1200)}`)
  }
  const installedVersion = async () => parseInstalledVersion(
    await device(['shell', 'dumpsys', 'package', PACKAGE], 15_000))
  await install(oldApk)
  if (await installedVersion() !== old.versionCode) throw new Error('Old APK installation version differs')
  await install(oldTestApk)
  const token = randomBytes(16).toString('hex')
  const phaseExtras = (name, expected) => {
    const extras = ['-e', 'phase', name, '-e', 'token', token]
    if (requireSafGrant) extras.push('-e', 'requireSafGrant', 'true')
    if (requireSafReadable) extras.push('-e', 'safReadablePathBase64',
      encodeSafReadablePath(safReadablePath))
    if (requireOffline) extras.push('-e', 'requireOffline', 'true')
    if (requireSessionFiles) extras.push('-e', 'requireSessionFiles', 'true')
    if (expected) extras.push('-e', 'canarySha256', expected.canarySha256,
      '-e', 'credentialSha256', expected.credentialSha256,
      '-e', 'safGrantCount', String(expected.safGrantCount),
      '-e', 'safGrantSha256', expected.safGrantSha256)
    if (expected && requireSessionFiles) extras.push('-e', 'sessionFilesSha256', expected.sessionFilesSha256,
      '-e', 'sessionFileCount', String(expected.sessionFileCount), '-e', 'sessionFileBytes', String(expected.sessionFileBytes))
    if (expected && requireSafReadable) extras.push('-e', 'safRootSha256', expected.safRootSha256,
      '-e', 'safDocumentIdSha256', expected.safDocumentIdSha256,
      '-e', 'safDocumentSha256', expected.safDocumentSha256,
      '-e', 'safDocumentBytes', String(expected.safDocumentBytes))
    return extras
  }
  const phase = async (name, expected) => {
    return parseInstrumentation(await device(['shell', 'am', 'instrument', '-w', '-r',
      ...phaseExtras(name, expected), RUNNER], 120_000), name, token, expected,
      { requireSafGrant, requireOffline, requireSafReadable, requireSessionFiles })
  }
  process.stderr.write(`Upgrade acceptance token=${token}; a failed run may retain its synthetic canary.\n`)
  const seeded = await phase('seed')
  if (seeded.versionCode !== identity.oldVersionCode) throw new Error('Canary was seeded under a different App version')
  let observedProcessDeath = false
  if (args.includes('--force-stop')) {
    const pids = async () => {
      try { return parseAgentPids(await device(['shell', 'pidof', `${PACKAGE}:agent`], 15_000)) }
      catch (error) {
        if (error.code === 1 && !error.stdout?.trim() && !error.stderr?.trim()) return []
        throw error
      }
    }
    const hold = startHold(adb, serial, phaseExtras('hold', seeded), token)
    try {
      const heldPid = await hold.ready
      const before = await pids()
      if (hold.closed || !before.includes(heldPid)) {
        throw new Error('Held Agent process is not alive before force-stop')
      }
      await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
      const after = await pids()
      if (after.includes(heldPid) || after.length > 0) {
        throw new Error('Agent process remains after force-stop')
      }
      let exitTimer
      const settled = await Promise.race([
        hold.done, new Promise((_, reject) => { exitTimer = setTimeout(() =>
          reject(new Error('Agent hold did not exit after force-stop')), 30_000) }),
      ]).finally(() => clearTimeout(exitTimer))
      if (/^INSTRUMENTATION_RESULT: passed=true$/m.test(settled.output)) {
        throw new Error('Agent hold completed normally instead of being killed')
      }
      observedProcessDeath = true
    } finally {
      if (!hold.closed) {
        await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
        hold.stopClient()
      }
    }
  }
  await install(newApk)
  if (await installedVersion() !== next.versionCode) throw new Error('New APK installation version differs')
  if (oldTestApk !== testApk) await install(testApk)
  const verified = await phase('verify', seeded)
  if (verified.versionCode !== identity.newVersionCode) throw new Error('Verification ran under a different App version')
  const cleaned = await phase('cleanup', seeded)
  if (cleaned.versionCode !== identity.newVersionCode) throw new Error('Cleanup ran under a different App version')
  process.stdout.write(`${JSON.stringify({ package: PACKAGE, serial, oldApk, newApk, oldTestApk, testApk,
    certificateSha256: identity.certificate, seeded, verified, cleaned,
    androidPackageManagerUpgradeTested: true, keystoreTested: true,
    privateNoBackupDataTested: true, realSessionTested: false,
    realSessionFilesRetained: requireSessionFiles,
    safGrantMetadataRetained: requireSafGrant, safDocumentReadableTested: requireSafReadable,
    androidProcessDeathTested: observedProcessDeath,
    noInternetCapableNetworkAtCheckpoints: requireOffline,
    offlineSessionBehaviorTested: false })}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`Android upgrade device acceptance: ${error.message}\n`)
    process.exitCode = 1
  })
}
