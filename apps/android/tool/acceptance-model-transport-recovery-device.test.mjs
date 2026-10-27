import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { parseModelTransportRecoveryResult, runModelTransportRecoveryAcceptance } from './acceptance-model-transport-recovery-device.mjs'

function fixture() {
  const caseId = randomUUID(), sessionId = `android-acceptance-transport-${caseId}`
  const evidence = { turn: 1, step: 1, modelCalls: 2, retryCount: 1, failureCode: 'TRANSPORT', retryId: randomUUID(),
    partialConsumed: true, requestBodyUnchanged: true, requestChangesAccountedFor: true, runtimeContextUpdates: 0,
    sessionLogContinuationChecked: true, sessionLogSnapshots: [
      { afterSeq: -1, throughSeq: 3, eventCount: 4, headerSha256: 'f'.repeat(64), eventsSha256: 'a'.repeat(64) },
      { afterSeq: 3, throughSeq: 7, eventCount: 4, headerSha256: 'f'.repeat(64), eventsSha256: 'b'.repeat(64) }],
    reconnected: true, durableRetryMatched: true, failedAttemptSeq: 5, retrySeq: 6, retryStartedSeq: 7,
    finalMessageSeq: 8, turnEndSeq: 10, requestSha256: 'a'.repeat(64), retryRequestSha256: 'a'.repeat(64) }
  const check = { name: 'shipped-android-profile-active-model-transport-recovery', status: 'passed', profile: 'android', caseId, sessionId,
    sendCount: 1, modelServerClosed: true, appUid: 10496, elapsedMs: 1000, evidence,
    runtimeInputs: { 'bootstrap.mjs': 'b'.repeat(64), 'node_modules/@minnnng/dsh-android-runtime/index.mjs': 'c'.repeat(64) },
    sessionFiles: [{ path: `sessions/local/${sessionId}/session.v4.jsonl`, bytes: 10000, sha256: 'd'.repeat(64) }] }
  const state = { interactive: false, keyguardLocked: true, deviceLocked: true, displays: [{ id: 0, state: 1 }] }
  const result = { passed: true, complete: true, foregroundCarrier: 'service', reports: [{ suite: 'model-transport-recovery', checks: [check] }] }
  const output = () => 'INSTRUMENTATION_STATUS: stage=foreground-ready\nINSTRUMENTATION_STATUS: foregroundCarrier=service\nINSTRUMENTATION_STATUS_CODE: 1\n'
    + ['deviceStateBefore', 'deviceStateReady', 'deviceStateAfter'].map(key => `INSTRUMENTATION_RESULT: ${key}=${JSON.stringify(state)}\n`).join('')
    + `INSTRUMENTATION_RESULT: foregroundCarrier=service\nINSTRUMENTATION_RESULT: foregroundClosed=true\nINSTRUMENTATION_RESULT: nativeOwnersClosed=true\nINSTRUMENTATION_RESULT: result=${JSON.stringify(result)}\nINSTRUMENTATION_CODE: -1\n`
  return { check, evidence, state, result, output }
}

test('parser distinguishes genuine task transport recovery from radio/service and cleanup proof', () => {
  const result = parseModelTransportRecoveryResult(fixture().output())
  assert.equal(result.productionAgentServiceRadioRecovery, 'not-tested')
  assert.equal(result.nodeProcessRetirement, 'requires-outer-owner')
  assert.equal(result.physicalPanelEvidence, 'requires-outer-owner')
})
test('parser retains changed raw hashes only with accounted-for runtime context evidence', () => {
  const f = fixture()
  f.evidence.requestBodyUnchanged = false
  f.evidence.retryRequestSha256 = 'e'.repeat(64)
  f.evidence.runtimeContextUpdates = 1
  assert.equal(parseModelTransportRecoveryResult(f.output()).evidence.requestBodyUnchanged, false)
})
for (const [label, mutate] of [
  ['incomplete', f => { f.result.complete = false }],
  ['wrong session', f => { f.check.sessionId = 'other' }],
  ['resubmission', f => { f.check.sendCount = 2 }],
  ['new turn', f => { f.evidence.turn = 2 }],
  ['no retry', f => { f.evidence.modelCalls = 1 }],
  ['clean EOF', f => { f.evidence.failureCode = 'STREAM_CLOSED' }],
  ['partial not consumed', f => { f.evidence.partialConsumed = false }],
  ['changed request', f => { f.evidence.requestBodyUnchanged = false }],
  ['unaccounted request', f => { f.evidence.requestChangesAccountedFor = false }],
  ['missing retry hash', f => { delete f.evidence.retryRequestSha256 }],
  ['invalid context count', f => { f.evidence.runtimeContextUpdates = -1 }],
  ['malformed log observation', f => { f.evidence.sessionLogSnapshots[1].eventsSha256 = 'invalid' }],
  ['regressed log observation', f => { f.evidence.sessionLogSnapshots[1].afterSeq = 2; f.evidence.sessionLogSnapshots[1].eventCount = 5 }],
  ['no reconnect', f => { f.evidence.reconnected = false }],
  ['no durable retry', f => { f.evidence.durableRetryMatched = false }],
  ['bad event order', f => { f.evidence.finalMessageSeq = f.evidence.retrySeq }],
  ['open listener', f => { f.check.modelServerClosed = false }],
  ['wrong durable log', f => { f.check.sessionFiles[0].path = 'sessions/user/session.v4.jsonl' }],
  ['missing runtime hash', f => { delete f.check.runtimeInputs['bootstrap.mjs'] }],
  ['awake device', f => { f.state.interactive = true }],
]) test(`rejects ${label}`, () => { const f = fixture(); mutate(f); assert.throws(() => parseModelTransportRecoveryResult(f.output())) })

test('runner uses only a service carrier and propagates cancellation/unknown child exit', async () => {
  const signal = new AbortController().signal
  const value = await runModelTransportRecoveryAcceptance({ signal, invoke: async (args, passed) => {
    assert.equal(passed, signal)
    assert.equal(args[args.indexOf('suite') + 1], 'model-transport-recovery')
    assert.equal(args[args.indexOf('foregroundCarrier') + 1], 'service')
    return fixture().output()
  } })
  assert.equal(value.result.evidence.retryCount, 1)
  await assert.rejects(runModelTransportRecoveryAcceptance({ invoke: async () => { throw new Error('child exit unknown') } }), /child exit unknown/u)
  const abort = new AbortController(); abort.abort(new Error('cancelled'))
  await assert.rejects(runModelTransportRecoveryAcceptance({ signal: abort.signal, invoke: () => assert.fail('must not start') }), /cancelled/u)
})
