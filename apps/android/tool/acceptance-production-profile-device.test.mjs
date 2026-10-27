import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { parseProductionProfileResult, runProductionProfileAcceptance } from './acceptance-production-profile-device.mjs'

function fixture(workflow = false) {
  const caseId = randomUUID()
  const check = { name: 'shipped-android-profile-model-ptc-and-offline-linux', status: 'passed', profile: 'android', caseId,
    sessionId: `android-acceptance-production-${caseId}`, appUid: 10496, guestUid: 99002, modelCalls: workflow ? 4 : 3,
    ptcRead: true, linuxPython: true, networkSchemaAbsent: true, modelServerClosed: true, retirementConfirmed: true,
    expectWorkflow: workflow, workflowCompleted: workflow, childCalls: workflow ? 1 : 0, childSessionId: workflow ? randomUUID() : null,
    elapsedMs: 1234, toolSchemaSha256: 'b'.repeat(64), sessionFiles: [{ path: 'sessions/fixture/parent/session.v4.jsonl', bytes: 123, sha256: 'a'.repeat(64) }],
    runtimeInputs: { 'bootstrap.mjs': 'c'.repeat(64), 'node_modules/@minnnng/dsh-android-runtime/index.mjs': 'd'.repeat(64) } }
  const state = { interactive: false, keyguardLocked: true, deviceLocked: true, displays: [{ id: 0, state: 1 }] }
  const result = { passed: true, complete: true, foregroundCarrier: 'service', reports: [{ suite: 'production-profile', checks: [check] }] }
  const output = () => 'INSTRUMENTATION_STATUS: stage=foreground-ready\nINSTRUMENTATION_STATUS: foregroundCarrier=service\nINSTRUMENTATION_STATUS_CODE: 1\n'
    + ['deviceStateBefore', 'deviceStateReady', 'deviceStateAfter'].map(key => `INSTRUMENTATION_RESULT: ${key}=${JSON.stringify(state)}\n`).join('')
    + `INSTRUMENTATION_RESULT: foregroundCarrier=service\nINSTRUMENTATION_RESULT: foregroundClosed=true\nINSTRUMENTATION_RESULT: nativeOwnersClosed=true\nINSTRUMENTATION_RESULT: result=${JSON.stringify(result)}\nINSTRUMENTATION_CODE: -1\n`
  return { check, state, result, output }
}

test('validated production evidence retains explicit outer process/panel obligations', () => {
  const parsed = parseProductionProfileResult(fixture().output())
  assert.equal(parsed.profile, 'android')
  assert.equal(parsed.nodeProcessRetirement, 'requires-outer-owner')
  assert.equal(parsed.physicalPanelEvidence, 'requires-outer-owner')
})
for (const [label, mutate] of [
  ['native failure', f => { f.result.complete = false }],
  ['missing PTC', f => { f.check.ptcRead = false }],
  ['unretired VM', f => { f.check.retirementConfirmed = false }],
  ['App UID execution', f => { f.check.guestUid = f.check.appUid }],
  ['open model server', f => { f.check.modelServerClosed = false }],
  ['wrong profile', f => { f.check.profile = 'device-acceptance' }],
  ['no durable Session', f => { f.check.sessionFiles = [] }],
  ['escaped Session path', f => { f.check.sessionFiles[0].path = 'sessions/../../user.jsonl' }],
  ['unexpected workflow', f => { f.check.workflowCompleted = true }],
  ['missing artifact hash', f => { delete f.check.runtimeInputs['bootstrap.mjs'] }],
  ['awake device', f => { f.state.interactive = true }],
]) test(`rejects ${label}`, () => {
  const f = fixture(); mutate(f)
  assert.throws(() => parseProductionProfileResult(f.output()))
})
test('workflow expectations require one real child and the extra parent step', () => {
  const f = fixture(true)
  assert.equal(parseProductionProfileResult(f.output(), true).childCalls, 1)
  assert.throws(() => parseProductionProfileResult(f.output(), false))
  f.check.childCalls = 0
  assert.throws(() => parseProductionProfileResult(f.output(), true))
})
test('driver uses only the service suite and preserves invocation failures/aborts', async () => {
  const signal = new AbortController().signal
  const f = fixture()
  const value = await runProductionProfileAcceptance({ signal, invoke: async (args, received) => {
    assert.equal(received, signal)
    assert.ok(args.includes('production-profile'))
    assert.equal(args[args.indexOf('foregroundCarrier') + 1], 'service')
    assert.equal(args[args.indexOf('expectWorkflow') + 1], 'false')
    return f.output()
  } })
  assert.equal(value.result.ptcRead, true)
  await assert.rejects(runProductionProfileAcceptance({ invoke: async () => { throw new Error('child close failed') } }), /child close failed/u)
  const abort = new AbortController(); abort.abort(new Error('cancelled'))
  await assert.rejects(runProductionProfileAcceptance({ signal: abort.signal, invoke: () => assert.fail('must not start') }), /cancelled/u)
})
