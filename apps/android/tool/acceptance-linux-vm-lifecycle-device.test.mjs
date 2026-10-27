import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseLinuxDeathReady, parseLinuxLifecycleResult, requireLinuxLifecycleInstrumentation,
  runLifecyclePlan, validateLifecycleArtifacts } from './acceptance-linux-vm-lifecycle-device.mjs'

const token = '12345678-1234-1234-1234-123456789abc'
const runId = '22345678-1234-1234-1234-123456789abc'
const successor = '32345678-1234-1234-1234-123456789abc'
const sessionId = `linux-lifecycle-${token}`
const hash = 'a'.repeat(64)
const baseImage = 'b'.repeat(64)
const certificate = 'c'.repeat(64)
const app = { packageName: 'com.minnnng.dsh_android', versionCode: 115, certificate, path: 'old.apk' }
const next = { ...app, versionCode: 116, path: 'new.apk' }
const testApk = { packageName: `${app.packageName}.test`, certificate, path: 'old-test.apk' }
const nextTest = { ...testApk, path: 'new-test.apk' }
const identity = { schema: 1, token, sessionId, pid: 1234, appUid: 10123, versionCode: 115, runId }

function inspection(state = 'completed', overrides = {}) {
  return { version: 1, sessionId, status: 'ready', blocked: false, needsReview: false,
    requestedRunFound: true, automaticReplay: false, truncated: false,
    records: [{ runId, operation: 'execute', state, retirementConfirmed: true, diskCommitted: true }], ...overrides }
}
function receipt(committed = true) {
  return { id: runId, sessionId, status: 'completed', exitCode: 0, retirementConfirmed: true,
    diskCommitted: committed, guestUid: 99001 }
}
const ready = { ...identity, kind: 'import-retired-before-publication', source: `linux-lifecycle-acceptance/${token}.txt`,
  sha256: hash, guestUid: 99001, retirementConfirmed: true, diskCommitted: false }
const seed = { ...identity, phase: 'upgrade-seed', passed: true, sha256: hash, baseImage, receipt: receipt() }
const verified = { ...identity, phase: 'upgrade-verify', versionCode: 116, pid: 4321, passed: true,
  sha256: hash, beforeVersionCode: 115, beforeBaseImage: baseImage, baseImage,
  receipt: { ...receipt(false), id: successor }, inspection: inspection() }
const recovered = { ...identity, phase: 'death-recover', pid: 4321, oldPid: 1234, passed: true,
  sha256: hash, window: ready.kind, journalUnchanged: true,
  inspection: inspection('interrupted', { needsReview: true, records: [{ runId, operation: 'import',
    state: 'interrupted', retirementConfirmed: true, diskCommitted: false }] }),
  successor: { status: 'outcome_uncertain', guestUid: null } }
const cancelled = { ...identity, phase: 'cancel', passed: true, liveGuestPid: 7777, workerCpuObserved: true,
  activeInspection: inspection('running', { status: 'active', blocked: true }),
  inspection: inspection('completed', { records: [{ runId, operation: 'execute', state: 'completed',
    retirementConfirmed: true, diskCommitted: false }] }),
  receipt: { ...receipt(false), status: 'cancelled', cancelled: true, exitCode: null } }
const result = value => `INSTRUMENTATION_RESULT: lifecycle=${JSON.stringify(value)}\nINSTRUMENTATION_CODE: -1\n`
const readyOutput = value => `INSTRUMENTATION_STATUS: linuxDeathReady=${JSON.stringify(value)}\n` +
  'INSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_RESULT: shortMsg=Process crashed.\nINSTRUMENTATION_CODE: 0\n'
const clone = value => structuredClone(value)

test('lifecycle artifacts require exact target/test signer and an increasing ordinary-upgrade version', () => {
  validateLifecycleArtifacts(app, testApk, next, nextTest)
  assert.throws(() => validateLifecycleArtifacts(app, { ...testApk, certificate: 'd'.repeat(64) }))
  assert.throws(() => validateLifecycleArtifacts(app, testApk, app, nextTest), /increase/)
  assert.throws(() => validateLifecycleArtifacts(app, testApk, next), /both/)
})

test('APK instrumentation must target the Agent process exactly once', () => {
  const declaration = `E: instrumentation (line=1)\n A: android:name="${app.packageName}.LinuxVmAcceptanceInstrumentation"\n` +
    ` A: android:targetPackage="${app.packageName}"\n A: android:targetProcesses="${app.packageName}:agent"\n`
  requireLinuxLifecycleInstrumentation(declaration)
  assert.throws(() => requireLinuxLifecycleInstrumentation(declaration + declaration))
  assert.throws(() => requireLinuxLifecycleInstrumentation(declaration.replace(':agent', ':main')))
})

test('cancel evidence requires a live running worker, CPU observation and confirmed uncommitted retirement', () => {
  assert.equal(parseLinuxLifecycleResult(result(cancelled), 'cancel', token).receipt.status, 'cancelled')
  for (const mutation of [value => { value.workerCpuObserved = false },
    value => { value.activeInspection.records[0].state = 'admitted' },
    value => { value.receipt.retirementConfirmed = false },
    value => { value.receipt.guestUid = identity.appUid },
    value => { value.receipt.diskCommitted = true }, value => { value.inspection.blocked = true }]) {
    const invalid = clone(cancelled); mutation(invalid)
    assert.throws(() => parseLinuxLifecycleResult(result(invalid), 'cancel', token))
  }
})

test('self-kill ready status identifies only the synced retired-before-publication import', () => {
  assert.deepEqual(parseLinuxDeathReady(readyOutput(ready), token), ready)
  assert.throws(() => parseLinuxDeathReady(readyOutput({ ...ready, kind: 'in-flight' }), token))
  assert.throws(() => parseLinuxDeathReady(readyOutput({ ...ready, token: runId }), token))
  assert.throws(() => parseLinuxDeathReady(readyOutput(ready) + readyOutput(ready), token))
})

test('recovery rejects same PID, replay, changed journal and falsely committed import', () => {
  assert.equal(parseLinuxLifecycleResult(result(recovered), 'death-recover', token, ready).oldPid, 1234)
  for (const mutation of [value => { value.pid = ready.pid }, value => { value.journalUnchanged = false },
    value => { value.inspection.automaticReplay = true }, value => { value.inspection.needsReview = false },
    value => { value.inspection.records[0].diskCommitted = true }, value => { value.successor.guestUid = 99001 }]) {
    const invalid = clone(recovered); mutation(invalid)
    assert.throws(() => parseLinuxLifecycleResult(result(invalid), 'death-recover', token, ready))
  }
})

test('upgrade verifies exact prior run, hash, image attribution, and a discard-only read after the upgrade', () => {
  assert.equal(parseLinuxLifecycleResult(result(seed), 'upgrade-seed', token).sha256, hash)
  assert.equal(parseLinuxLifecycleResult(result(verified), 'upgrade-verify', token, seed).versionCode, 116)
  for (const change of [{ sha256: 'f'.repeat(64) }, { versionCode: 115 }, { beforeVersionCode: 114 },
    { beforeBaseImage: 'f'.repeat(64) }, { receipt: receipt(true) }]) {
    assert.throws(() => parseLinuxLifecycleResult(result({ ...verified, ...change }), 'upgrade-verify', token, seed))
  }
})

test('truncated or duplicate instrumentation output is never a successful result', () => {
  assert.throws(() => parseLinuxLifecycleResult(result(seed).replace('CODE: -1', 'CODE: 0'), 'upgrade-seed', token))
  assert.throws(() => parseLinuxLifecycleResult(result(seed) + result(seed), 'upgrade-seed', token))
  assert.throws(() => parseLinuxLifecycleResult('INSTRUMENTATION_CODE: -1\n', 'upgrade-seed', token))
})

function adapter(outputs, installed = 115) {
  const calls = []
  let version = installed
  return { calls,
    installedVersion: async () => { calls.push('version'); return version },
    install: async value => { calls.push(`install:${value.path}`); if (value.packageName === app.packageName) version = value.versionCode },
    instrument: async phase => { calls.push(`instrument:${phase}`); assert.ok(outputs[phase]); return outputs[phase] },
    isAgentPidLive: async pid => { calls.push(`pid:${pid}`); return false },
  }
}

test('host upgrade plan checks version before replacement, seeds old pair, then verifies new pair', async () => {
  const io = adapter({ 'upgrade-seed': result(seed), 'upgrade-verify': result(verified) })
  const report = await runLifecyclePlan(io, { mode: 'upgrade', app, test: testApk, next, nextTest, token })
  assert.equal(report.evidence.length, 2)
  assert.deepEqual(io.calls, ['version', 'install:old.apk', 'install:old-test.apk', 'instrument:upgrade-seed',
    'install:new.apk', 'install:new-test.apk', 'version', 'instrument:upgrade-verify'])
})

test('host death plan observes actual old PID disappearance before requesting recovery', async () => {
  const io = adapter({ 'death-prepare': readyOutput(ready), 'death-recover': result(recovered) })
  await runLifecyclePlan(io, { mode: 'death', app, test: testApk, token })
  assert.deepEqual(io.calls.slice(-3), ['instrument:death-prepare', 'pid:1234', 'instrument:death-recover'])
  const live = adapter({ 'death-prepare': readyOutput(ready) })
  live.isAgentPidLive = async () => true
  await assert.rejects(runLifecyclePlan(live, { mode: 'death', app, test: testApk, token }), /has not stopped/)
  assert.equal(live.calls.includes('instrument:death-recover'), false)
})

test('wrong installed version and downgrade request fail before any replacement or instrumentation', async () => {
  const io = adapter({}, 117)
  await assert.rejects(runLifecyclePlan(io, { mode: 'cancel', app, test: testApk, token }), /differs/)
  assert.deepEqual(io.calls, ['version'])
  const untouched = adapter({})
  await assert.rejects(runLifecyclePlan(untouched, { mode: 'upgrade', app, test: testApk, next: app, nextTest, token }), /increase/)
  assert.deepEqual(untouched.calls, [])
})

test('failed or absent old seed cannot install the next APK', async () => {
  const io = adapter({ 'upgrade-seed': result({ ...seed, passed: false }) })
  await assert.rejects(runLifecyclePlan(io, { mode: 'upgrade', app, test: testApk, next, nextTest, token }))
  assert.equal(io.calls.includes('install:new.apk'), false)
})
