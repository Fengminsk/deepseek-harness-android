import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { fork, spawn } from 'node:child_process'
import { EventEmitter, once } from 'node:events'
import { mkdtemp, mkdir, rm, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ownPtcPreparationProcess, parsePtcDeathReady, parsePtcDeathRecovery, requirePtcDeathInstrumentation } from './acceptance-ptc-process-death-device.mjs'

const caseId = '1c8494ee-ad62-4118-9acc-41a10648c19a', runId = 'e015fdf0-25c8-4c7c-a254-9d25f0630d94'
const ready = { schema: 1, caseId, runId, agentPid: 12345, fileSha256: 'a'.repeat(64) }
const frame = value => `INSTRUMENTATION_STATUS: ready=${JSON.stringify(value)}\nINSTRUMENTATION_STATUS_CODE: 1\n`
const check = { ...ready, name: 'ptc-killed-dispatch-no-replay', status: 'passed', oldAgentPid: ready.agentPid,
  newAgentPid: 23456, journalState: 'dispatch-unconfirmed', nativeRebindRequests: 0, replayedExecutions: 0 }
const nativeObservation = { nativeReceiptState: 'ADMITTED', nativeOutputAbsent: true }
const result = (value, native = nativeObservation) => `INSTRUMENTATION_RESULT: result=${JSON.stringify({ passed: true, complete: true, ...native,
  reports: [{ suite: 'ptc-process-death', checks: [value] }] })}\nINSTRUMENTATION_CODE: -1\n`

test('PTC process-death result requires the exact unconfirmed write, fresh process and no replay', () => {
  assert.deepEqual(parsePtcDeathReady(frame(ready), caseId), ready)
  assert.equal(parsePtcDeathReady(frame(ready).split('INSTRUMENTATION_STATUS_CODE')[0], caseId), null)
  assert.deepEqual(parsePtcDeathRecovery(result(check), ready), { ...check, ...nativeObservation,
    nativeReceiptInspection: 'read-only-unconfirmed' })
  for (const patch of [{ caseId: runId }, { runId: 'invalid' }, { agentPid: -1 }, { schema: 2 }, { extra: true }])
    assert.throws(() => parsePtcDeathReady(frame({ ...ready, ...patch }), caseId))
  assert.throws(() => parsePtcDeathReady(frame(ready) + frame(ready), caseId))
  for (const patch of [{ newAgentPid: ready.agentPid }, { replayedExecutions: 1 }, { nativeRebindRequests: 1 },
    { journalState: 'confirmed' }, { fileSha256: 'b'.repeat(64) }, { status: 'failed' }])
    assert.throws(() => parsePtcDeathRecovery(result({ ...check, ...patch }), ready))
  assert.throws(() => parsePtcDeathRecovery(result(check).replace('CODE: -1', 'CODE: 0'), ready))
  assert.throws(() => parsePtcDeathRecovery(result(check).replace('"complete":true', '"complete":false'), ready))
  assert.throws(() => parsePtcDeathRecovery(result(check) + result(check), ready))
})

test('native receipt inspection requires explicit unconfirmed state and no output without claiming native recovery', () => {
  for (const state of ['ADMITTED', 'INTERRUPTED_UNCONFIRMED']) {
    const observation = { nativeReceiptState: state, nativeOutputAbsent: true }
    const parsed = parsePtcDeathRecovery(result(check, observation), ready)
    assert.equal(parsed.nativeReceiptState, state)
    assert.equal(parsed.nativeOutputAbsent, true)
    assert.equal(parsed.nativeReceiptInspection, 'read-only-unconfirmed')
  }
  for (const state of [undefined, null, '', 'COMPLETED', 'CANCELLED', 'RETIRE_UNCONFIRMED', 'ERROR'])
    assert.throws(() => parsePtcDeathRecovery(result(check, { nativeReceiptState: state, nativeOutputAbsent: true }), ready), /native receipt/)
  for (const absent of [undefined, null, false, 'true', 1])
    assert.throws(() => parsePtcDeathRecovery(result(check, { nativeReceiptState: 'ADMITTED', nativeOutputAbsent: absent }), ready), /native receipt/)
})

test('PTC death runner requires the actual Node carrier in the Agent process', () => {
  const prefix = 'com.minnnng.dsh_android'
  const declaration = `E: instrumentation (line=30)\n A: android:name="${prefix}.NativeRuntimeToolsAcceptanceInstrumentation"\n A: android:targetPackage="${prefix}"\n A: android:targetProcesses="${prefix}:agent"\n`
  requirePtcDeathInstrumentation(declaration)
  assert.throws(() => requirePtcDeathInstrumentation(declaration + declaration))
  assert.throws(() => requirePtcDeathInstrumentation(declaration.replace(':agent', ':main')))
})

test('PTC service recovery keeps receipt requirements and rejects missing carrier or cleanup evidence', () => {
  const state = JSON.stringify({ interactive: false, keyguardLocked: true, deviceLocked: true, displays: [{ id: 0, state: 1 }] })
  const fields = Object.entries({ foregroundCarrier: 'service', foregroundClosed: 'true', nativeOwnersClosed: 'true',
    deviceStateBefore: state, deviceStateReady: state, deviceStateAfter: state })
    .map(([name, value]) => `INSTRUMENTATION_RESULT: ${name}=${value}\n`).join('')
  const value = result(check, { ...nativeObservation, foregroundCarrier: 'service' })
  const parsed = parsePtcDeathRecovery(fields + value, ready, 'service')
  assert.equal(parsed.nativeReceiptInspection, 'read-only-unconfirmed')
  assert.equal(parsed.deviceStateReady.deviceLocked, true)
  for (const invalid of [value, fields.replace('foregroundClosed=true', 'foregroundClosed=false') + value,
    fields + value.replace('"ADMITTED"', '"COMPLETED"'), fields + value.replace('"foregroundCarrier":"service"', '"foregroundCarrier":"activity"')])
    assert.throws(() => parsePtcDeathRecovery(invalid, ready, 'service'))
})

test('owned preparation cleanup waits for close, is idempotent and rejects a missing close', async () => {
  const child = new EventEmitter()
  child.pid = 1
  child.stdout = new EventEmitter(); child.stderr = new EventEmitter()
  let kills = 0, published = false
  child.kill = () => { kills++; return true }
  const owned = ownPtcPreparationProcess(child, 1000)
  const disposal = owned.dispose()
  assert.equal(disposal, owned.dispose())
  const publish = disposal.then(() => { published = true })
  await Promise.resolve()
  assert.equal(published, false); assert.equal(kills, 1)
  child.emit('close', 0, null)
  await publish
  assert.equal(published, true); assert.equal(owned.status().ended, true)
  assert.equal(child.stdout.listenerCount('data'), 0); assert.equal(child.stderr.listenerCount('data'), 0)
  const stuck = new EventEmitter()
  stuck.pid = 1
  stuck.kill = () => true
  const unclosed = ownPtcPreparationProcess(stuck, 10)
  await assert.rejects(unclosed.dispose(), /cleanup is unconfirmed/)
  assert.equal(unclosed.status().ended, false)
  stuck.emit('close', 0, null)
})

test('owned preparation cleanup observes actual child close after termination and normal exit', async t => {
  const running = spawn(process.execPath, ['-e', "process.stdout.write('ready');setInterval(()=>{},1000)"], { windowsHide: true })
  const owned = ownPtcPreparationProcess(running)
  t.after(() => owned.dispose())
  await once(running.stdout, 'data')
  await owned.dispose()
  assert.equal(owned.status().ended, true)
  const exited = spawn(process.execPath, ['-e', 'process.exit(0)'], { windowsHide: true })
  const normal = ownPtcPreparationProcess(exited)
  t.after(() => normal.dispose())
  await once(exited, 'close')
  assert.deepEqual(await normal.dispose(), { code: 0, signal: null })
})

test('owned preparation cleanup waits for failed-spawn close and never converts it into success', async () => {
  const missing = spawn(`${process.execPath}.missing-${randomUUID()}`, [], { windowsHide: true })
  const owned = ownPtcPreparationProcess(missing)
  await assert.rejects(owned.dispose(), { code: 'ENOENT' })
  assert.equal(owned.status().ended, true)
  assert.equal(owned.status().error.code, 'ENOENT')
})

function start(phase, id, home, workspace) {
  const child = fork(fileURLToPath(new URL('./device-runtime-acceptance/ptc-death-host-fixture.mjs', import.meta.url)),
    [phase, id, workspace], { execArgv: ['--import', 'tsx/esm'], env: { ...process.env, DSH_HOME: home },
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'], windowsHide: true })
  const ownership = ownPtcPreparationProcess(child)
  let diagnostics = ''
  child.stderr.on('data', part => { diagnostics = (diagnostics + part).slice(-10000) })
  const exited = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })))
  const message = new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`Child timed out: ${diagnostics}`)) }, 25000)
    child.once('message', value => { clearTimeout(timer); value.kind === 'error' ? reject(new Error(`${value.error}\n${diagnostics}`)) : resolve(value) })
    child.once('error', error => { clearTimeout(timer); reject(error) })
    child.once('exit', code => { clearTimeout(timer); reject(new Error(`Child exited (${code}) before message: ${diagnostics}`)) })
  })
  return { child, exited, message, dispose: () => ownership.dispose() }
}

test('a killed real ToolRuntime write keeps its durable PTC dispatch and a fresh process refuses replay', { timeout: 60000 }, async t => {
  const temp = await mkdtemp(join(tmpdir(), 'dsh-ptc-death-')), id = randomUUID()
  const home = join(temp, id), workspace = join(temp, `.ptc-death-${id}`)
  await mkdir(home); await mkdir(workspace)
  const children = []
  t.after(async () => {
    await Promise.all(children.map(child => child.dispose()))
    await rm(temp, { recursive: true, force: true })
  })
  const prepared = start('prepare', id, home, workspace)
  children.push(prepared)
  const marker = await prepared.message
  assert.equal(marker.kind, 'ready'); assert.equal(marker.agentPid, prepared.child.pid)
  const original = await readFile(join(workspace, 'unconfirmed-write.txt'))
  prepared.child.kill('SIGKILL'); await prepared.exited
  const recovered = start('recover', id, home, workspace)
  children.push(recovered)
  const report = await recovered.message
  assert.equal(report.kind, 'result')
  assert.equal((await recovered.exited).code, 0)
  assert.equal(report.result.checks[0].journalState, 'dispatch-unconfirmed')
  assert.equal(report.result.checks[0].oldAgentPid, prepared.child.pid)
  assert.equal(report.result.checks[0].newAgentPid, recovered.child.pid)
  assert.deepEqual(await readFile(join(workspace, 'unconfirmed-write.txt')), original)
  const corrupt = JSON.parse(await readFile(join(home, 'ptc-death-ready.json'), 'utf8'))
  corrupt.fileSha256 = 'b'.repeat(64)
  await writeFile(join(home, 'ptc-death-ready.json'), JSON.stringify(corrupt))
  const refused = start('recover', id, home, workspace)
  children.push(refused)
  await assert.rejects(refused.message, /strictly equal|Expected values/)
  assert.notEqual((await refused.exited).code, 0)
})

test('PTC SAF fixture uses native search lifecycle and refuses revoked roots without hiding incomplete results', { timeout: 60000 }, async t => {
  const temp = await mkdtemp(join(tmpdir(), 'dsh-ptc-saf-host-'))
  const children = []
  t.after(async () => {
    await Promise.all(children.map(child => child.dispose()))
    await rm(temp, { recursive: true, force: true })
  })
  for (const phase of ['saf', 'saf-incomplete']) {
    const id = randomUUID(), home = join(temp, id), workspace = join(temp, `.ptc-death-${id}`)
    await mkdir(home); await mkdir(workspace)
    const worker = start(phase, id, home, workspace)
    children.push(worker)
    if (phase === 'saf') {
      const report = await worker.message
      assert.equal(report.result.checks[0].status, 'passed')
      assert.equal(report.result.checks[0].callbackCount, 4)
      assert.equal((await worker.exited).code, 0)
    } else {
      await assert.rejects(worker.message, /strictly equal|Expected values/)
      assert.notEqual((await worker.exited).code, 0)
    }
  }
})
