import { createHash, randomUUID } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { mkdir, stat, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath,
  parseInstalledVersion, sdkTools, validateArtifacts } from './acceptance-upgrade-device.mjs'
import { acceptanceCarrier, carrierEvidence, requireAcceptanceCarrier } from './acceptance-carrier.mjs'

const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.LinuxVmAcceptanceInstrumentation`
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const HASH = /^[0-9a-f]{64}$/
const exec = promisify(execFile)
const assert = (condition, message) => { if (!condition) throw new Error(message) }
const validPid = value => Number.isSafeInteger(value) && value > 0

export function requireLinuxLifecycleInstrumentation(output) {
  const matches = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1).filter(block =>
    /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1] === `${PACKAGE}.LinuxVmAcceptanceInstrumentation` &&
    /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1] === PACKAGE &&
    /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1] === `${PACKAGE}:agent`)
  assert(matches.length === 1, 'The test APK needs exactly one Linux acceptance runner in :agent')
}

export function validateLifecycleArtifacts(app, test, next, nextTest) {
  assert(app.packageName === PACKAGE && test.packageName === `${PACKAGE}.test` &&
    Number.isSafeInteger(app.versionCode) && app.versionCode > 0 && HASH.test(app.certificate) &&
    app.certificate === test.certificate, 'Linux acceptance APK identities differ')
  if (next || nextTest) {
    assert(next && nextTest, 'Ordinary upgrade requires both next App and next test APK')
    validateArtifacts(app, next, nextTest)
  }
}

function exactJson(output, prefix, name) {
  const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_${prefix}: ${name}=(.*)$`, 'gm'))]
  assert(matches.length === 1, `Missing or duplicate Linux ${name} evidence`)
  return JSON.parse(matches[0][1].trim())
}

function identity(value, token) {
  assert(UUID.test(token) && value.schema === 1 && value.token === token &&
    value.sessionId === `linux-lifecycle-${token}` && validPid(value.pid) && validPid(value.appUid) &&
    Number.isSafeInteger(value.versionCode) && value.versionCode > 0 && UUID.test(value.runId),
  'Linux lifecycle evidence has an invalid or foreign identity')
}

function record(inspection, sessionId, id) {
  assert(inspection?.version === 1 && inspection.sessionId === sessionId &&
    inspection.requestedRunFound === true && inspection.automaticReplay === false &&
    inspection.truncated === false && Array.isArray(inspection.records) && inspection.records.length === 1 &&
    inspection.records[0].runId === id, 'Linux inspection does not identify the exact durable run')
  return inspection.records[0]
}

function completed(receipt, sessionId, committed, appUid) {
  assert(receipt?.sessionId === sessionId && UUID.test(receipt.id) && receipt.status === 'completed' &&
    receipt.exitCode === 0 && receipt.retirementConfirmed === true && receipt.diskCommitted === committed &&
    validPid(receipt.guestUid) && receipt.guestUid !== appUid,
  'Linux completed receipt is missing isolated identity, retirement or disk evidence')
}

export function parseLinuxDeathReady(output, token) {
  const value = exactJson(output, 'STATUS', 'linuxDeathReady')
  identity(value, token)
  assert(/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m.test(output) &&
    value.kind === 'import-retired-before-publication' && value.retirementConfirmed === true &&
    value.diskCommitted === false && HASH.test(value.sha256) && validPid(value.guestUid) &&
    value.guestUid !== value.appUid &&
    value.source === `linux-lifecycle-acceptance/${token}.txt`, 'Linux import death marker is incomplete')
  return value
}

export function parseLinuxLifecycleResult(output, phase, token, before = null) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  assert(codes.length === 1 && codes[0][1] === '-1', 'Linux lifecycle instrumentation did not pass')
  const value = exactJson(output, 'RESULT', 'lifecycle')
  identity(value, token)
  assert(value.phase === phase && value.passed === true, 'Linux lifecycle phase did not pass')
  if (phase === 'cancel') {
    const active = record(value.activeInspection, value.sessionId, value.runId)
    const settled = record(value.inspection, value.sessionId, value.runId)
    assert(validPid(value.liveGuestPid) && value.workerCpuObserved === true && value.activeInspection.status === 'active' &&
      value.activeInspection.blocked === true && active.state === 'running' &&
      value.receipt?.id === value.runId && value.receipt.sessionId === value.sessionId &&
      value.receipt.status === 'cancelled' && value.receipt.cancelled === true &&
      value.receipt.retirementConfirmed === true && value.receipt.diskCommitted === false &&
      validPid(value.receipt.guestUid) && value.receipt.guestUid !== value.appUid &&
      settled.retirementConfirmed === true && settled.diskCommitted === false &&
      value.inspection.blocked === false && value.inspection.needsReview === false,
    'Cancellation lacks an actual live dispatch and confirmed non-committing retirement')
  } else if (phase === 'death-recover') {
    const recovered = record(value.inspection, value.sessionId, value.runId)
    assert(before && value.runId === before.runId && value.oldPid === before.pid && value.pid !== before.pid &&
      value.appUid === before.appUid &&
      value.sha256 === before.sha256 && value.window === 'import-retired-before-publication' &&
      value.inspection.status === 'ready' && value.inspection.needsReview === true &&
      value.inspection.blocked === false && recovered.state === 'interrupted' && recovered.operation === 'import' &&
      recovered.retirementConfirmed === true && recovered.diskCommitted === false && value.journalUnchanged === true &&
      value.successor?.status === 'outcome_uncertain' && value.successor.guestUid === null,
    'Linux recovery did not preserve the retired import and refuse replay in a different process')
  } else if (phase === 'upgrade-seed') {
    completed(value.receipt, value.sessionId, true, value.appUid)
    assert(value.receipt.id === value.runId && HASH.test(value.sha256) && HASH.test(value.baseImage),
      'Linux upgrade seed lacks a committed disk hash')
  } else if (phase === 'upgrade-verify') {
    completed(value.receipt, value.sessionId, false, value.appUid)
    const original = record(value.inspection, value.sessionId, value.runId)
    assert(before && value.versionCode > before.versionCode && value.beforeVersionCode === before.versionCode &&
      value.appUid === before.appUid &&
      value.runId === before.runId && value.sha256 === before.sha256 && value.beforeBaseImage === before.baseImage &&
      HASH.test(value.baseImage) && original.diskCommitted === true && original.retirementConfirmed === true &&
      value.inspection.blocked === false && value.inspection.needsReview === false,
    'Linux workspace was not verified across an ordinary version-increasing upgrade')
  } else throw new Error('Unknown Linux lifecycle result phase')
  return value
}

/** The adapter owns actual ADB execution. No host fixture result is a device acceptance result. */
export async function runLifecyclePlan(io, { mode, app, test, next, nextTest, token = randomUUID(), foregroundCarrier = 'activity' }) {
  requireAcceptanceCarrier(foregroundCarrier)
  assert(['cancel', 'death', 'upgrade'].includes(mode) && UUID.test(token), 'Invalid lifecycle mode or token')
  validateLifecycleArtifacts(app, test, next, nextTest)
  assert(mode !== 'upgrade' || (next && nextTest), 'Upgrade needs the next artifact pair')
  const installed = await io.installedVersion()
  assert(installed === null || installed === app.versionCode, 'Installed App differs from the supplied initial version')
  await io.install(app)
  await io.install(test)
  const evidence = []
  const phase = async (name, previous) => {
    const raw = await io.instrument(name, token, { foregroundCarrier })
    const value = parseLinuxLifecycleResult(raw, name, token, previous)
    value.carrier = carrierEvidence(raw, foregroundCarrier)
    assert(value.versionCode === (name === 'upgrade-verify' ? next.versionCode : app.versionCode),
      'Instrumentation App version does not match the artifact')
    evidence.push(value)
    return value
  }
  if (mode === 'cancel') await phase('cancel')
  if (mode === 'death') {
    const raw = await io.instrument('death-prepare', token, { expectProcessDeath: true, foregroundCarrier })
    const ready = parseLinuxDeathReady(raw, token)
    ready.carrier = carrierEvidence(raw, foregroundCarrier, { prefix: 'STATUS', closed: false })
    assert(ready.versionCode === app.versionCode, 'Import preparation App version differs from the artifact')
    assert(!await io.isAgentPidLive(ready.pid), 'The original Android process has not stopped')
    evidence.push(ready)
    await phase('death-recover', ready)
  }
  if (mode === 'upgrade') {
    const seed = await phase('upgrade-seed')
    assert(seed.versionCode === app.versionCode, 'Seed App version does not match the supplied APK')
    await io.install(next)
    await io.install(nextTest)
    assert(await io.installedVersion() === next.versionCode, 'PackageManager did not install the new version')
    const verified = await phase('upgrade-verify', seed)
    assert(verified.versionCode === next.versionCode, 'Verified App version does not match the upgrade APK')
  }
  return { schema: 1, result: 'device-pass', mode, token, foregroundCarrier, evidence }
}

async function command(binary, args, timeout = 180_000, allowExit = false) {
  try {
    const { stdout, stderr } = await exec(binary, args, { timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true })
    return stdout + stderr
  } catch (failure) {
    if (allowExit && !failure.killed && Number.isInteger(failure.code)) return String(failure.stdout) + String(failure.stderr)
    throw failure
  }
}
function arg(args, name) {
  const at = args.indexOf(name)
  assert(at >= 0 && args[at + 1] && !args[at + 1].startsWith('--'), `Missing ${name}`)
  return args[at + 1]
}
async function artifact(path, tools) {
  path = resolve(path)
  const info = await stat(path)
  assert(path.endsWith('.apk') && info.isFile() && info.size > 0, 'Invalid APK path')
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex'),
    ...parseBadging(await command(tools.aapt2, ['dump', 'badging', path], 30_000)),
    certificate: parseCertificate(await command('java', ['-jar', tools.apksigner, 'verify', '--print-certs', path], 30_000)) }
}

async function main(args) {
  const foregroundCarrier = acceptanceCarrier(args)
  const mode = arg(args, '--mode')
  assert(['cancel', 'death', 'upgrade'].includes(mode), 'Choose cancel, death or upgrade')
  const tools = await sdkTools()
  const app = await artifact(arg(args, '--apk'), tools)
  const test = await artifact(arg(args, '--test-apk'), tools)
  const next = mode === 'upgrade' ? await artifact(arg(args, '--new-apk'), tools) : undefined
  const nextTest = mode === 'upgrade' ? await artifact(arg(args, '--new-test-apk'), tools) : undefined
  validateLifecycleArtifacts(app, test, next, nextTest)
  for (const testApk of [test, nextTest].filter(Boolean)) {
    requireLinuxLifecycleInstrumentation(await command(tools.aapt2,
      ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30_000))
  }
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass', foregroundCarrier, mode, app, test, next, nextTest }, null, 2) + '\n')
    return
  }
  assert(args.includes('--accept-agent-interruption'), 'Instrumentation replaces the Agent process; pass --accept-agent-interruption')
  const adb = args.includes('--adb') ? resolve(arg(args, '--adb')) : tools.adb
  const serial = connectedDevice(await command(adb, ['devices']), args.includes('--serial') ? arg(args, '--serial') : undefined)
  const shell = (...values) => command(adb, ['-s', serial, 'shell', ...values])
  const existed = parseInstalledPath(await shell('pm', 'path', PACKAGE))
  assert(!existed || args.includes('--allow-existing'), 'An installed App requires --allow-existing for data-preserving replacement')
  const output = resolve(arg(args, '--output'))
  await mkdir(output, { recursive: false })
  const token = randomUUID()
  const metadata = { mode, token, serial, app, test, next, nextTest, foregroundCarrier }
  await writeFile(resolve(output, 'artifacts.json'), JSON.stringify(metadata, null, 2) + '\n', { flag: 'wx' })
  const io = {
    installedVersion: async () => parseInstalledPath(await shell('pm', 'path', PACKAGE))
      ? parseInstalledVersion(await shell('dumpsys', 'package', PACKAGE)) : null,
    install: async value => {
      const raw = await command(adb, ['-s', serial, 'install', '-r', value.path])
      assert(/^Success\s*$/m.test(raw), `Data-preserving APK install failed: ${raw.slice(-1200)}`)
    },
    instrument: async (phase, runToken, options = {}) => {
      let raw
      try {
        raw = await command(adb, ['-s', serial, 'shell', 'am', 'instrument', '-w', '-r',
          '-e', 'suite', `lifecycle-${phase}`, '-e', 'token', runToken,
          '-e', 'foregroundCarrier', requireAcceptanceCarrier(options.foregroundCarrier), RUNNER], 180_000, options.expectProcessDeath)
        return raw
      } catch (failure) {
        raw = String(failure.stdout ?? '') + String(failure.stderr ?? '')
        throw failure
      } finally {
        if (raw !== undefined) await writeFile(resolve(output, `${phase}.txt`), raw, { flag: 'wx' })
      }
    },
    isAgentPidLive: async pid => {
      const raw = await command(adb, ['-s', serial, 'shell', 'pidof', `${PACKAGE}:agent`], 10_000, true)
      const values = raw.trim() ? raw.trim().split(/\s+/).map(Number) : []
      assert(values.every(validPid), 'Invalid Agent PID observation')
      return values.includes(pid)
    },
  }
  try {
    const report = { ...await runLifecyclePlan(io, { ...metadata }), serial }
    await writeFile(resolve(output, 'report.json'), JSON.stringify(report, null, 2) + '\n', { flag: 'wx' })
    process.stdout.write(JSON.stringify(report, null, 2) + '\n')
  } catch (failure) {
    await writeFile(resolve(output, 'failure.json'), JSON.stringify({ ...metadata, result: 'failed',
      message: String(failure), deviceStateRetained: true }, null, 2) + '\n', { flag: 'wx' })
    throw failure
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(failure => { console.error(failure); process.exitCode = 1 })
}
