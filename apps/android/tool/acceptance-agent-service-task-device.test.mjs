import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { parseAgentServiceTaskResult, runAgentServiceTaskAcceptance } from './acceptance-agent-service-task-device.mjs'

const caseId = 'd5d6d3b3-6af8-498b-932a-bfc339cb32f6'
const result = () => ({ schema: 1, passed: true, kind: 'production-account-task', caseId,
  sessionId: `android-account-acceptance-${caseId}`, requestId: `account-${caseId}`,
  provider: 'deepseek-account', model: 'deepseek-flash', markerSha256: 'a'.repeat(64),
  generation: 'one-service-generation', agentPid: 1234, submittedCount: 1, userMessageCount: 1,
  assistantMarkerMatches: 1, toolCalls: 0, turnEndCount: 1, completionKind: 'completed',
  historySha256: 'b'.repeat(64), eventCount: 12, elapsedMs: 1400, archived: true,
  deviceStateBefore: { locked: true, interactive: false }, deviceStateAfter: { locked: true, interactive: false },
  ownTaskRunningObserved: true, foregroundBefore: true, foregroundDuring: true, foregroundAfter: true,
  backgroundDuring: { fresh: true, running: 1 },
  cleanup: { taskSettled: true, archived: true, exportReleased: true, disconnected: true, cancelRequested: false } })
const output = (value = result()) => `INSTRUMENTATION_RESULT: result=${JSON.stringify(value)}\nINSTRUMENTATION_CODE: -1\n`

test('completed account task preserves separate physical-screen and whole-process evidence obligations', () => {
  const proof = parseAgentServiceTaskResult(output())
  assert.equal(proof.provider, 'deepseek-account')
  assert.equal(proof.physicalPanelEvidence, 'requires-outer-owner')
  assert.equal(proof.processRetirement, 'requires-outer-owner')
  assert.equal(proof.radioRecoveryTested, false)
  assert.equal(proof.originalConversationRenderingTested, false)
})

test('duplicate, incomplete, foreign-session and prompt-only matches cannot certify an account task', () => {
  for (const patch of [{ schema: 2 }, { passed: false }, { caseId: 'wrong' }, { sessionId: 'existing-user-session' },
    { provider: 'deepseek-official' }, { model: '' }, { generation: '' }, { agentPid: 0 },
    { submittedCount: 2 }, { userMessageCount: 0 }, { assistantMarkerMatches: 0 },
    { assistantMarkerMatches: 2 }, { toolCalls: 1 }, { turnEndCount: 2 },
    { completionKind: 'cancelled' }, { markerSha256: '' }, { historySha256: '' },
    { eventCount: 0 }, { elapsedMs: -1 }, { archived: false },
    { deviceStateBefore: { locked: false, interactive: false } },
    { deviceStateAfter: { locked: true, interactive: true } }, { foregroundDuring: false }, { ownTaskRunningObserved: false },
    { backgroundDuring: { fresh: false, running: 1 } }, { backgroundDuring: { fresh: true, running: 0 } },
    { cleanup: { ...result().cleanup, taskSettled: false } }, { cleanup: { ...result().cleanup, cancelRequested: true } },
    { cleanup: { ...result().cleanup, exportReleased: false } }, { cleanup: { ...result().cleanup, disconnected: false } }]) {
    assert.throws(() => parseAgentServiceTaskResult(output({ ...result(), ...patch })), JSON.stringify(patch))
  }
  for (const text of ['', output() + output(), output().replace('CODE: -1', 'CODE: 0'),
    output().replace('result={', 'result=malformed{')]) assert.throws(() => parseAgentServiceTaskResult(text))
})

test('real-account admission is explicit and invokes only the production-service runner', async () => {
  let calls = 0
  const invoke = async argv => {
    calls++
    assert.deepEqual(argv, ['shell', 'am', 'instrument', '-w', '-r', '-e', 'acceptRealAccountRequest', 'true',
      'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'])
    return output()
  }
  for (const acceptRealAccountRequest of [undefined, false, 'true']) {
    await assert.rejects(runAgentServiceTaskAcceptance({ invoke, acceptRealAccountRequest }), /admission/)
  }
  assert.equal(calls, 0)
  assert.equal((await runAgentServiceTaskAcceptance({ invoke, acceptRealAccountRequest: true })).result.archived, true)
  assert.equal(calls, 1)
})

test('cancellation cannot authorize a request or convert a completed command into success', async () => {
  const before = new AbortController()
  before.abort(new Error('before request'))
  await assert.rejects(runAgentServiceTaskAcceptance({ acceptRealAccountRequest: true, signal: before.signal,
    invoke: () => assert.fail('Already cancelled request') }), /before request/)
  const during = new AbortController()
  await assert.rejects(runAgentServiceTaskAcceptance({ acceptRealAccountRequest: true, signal: during.signal,
    invoke: async () => { during.abort(new Error('during request')); return output() } }), /during request/)
})

function noticeResult() {
  const value = result(), hash = text => createHash('sha256').update(text).digest('hex')
  value.markerSha256 = hash(`account-acceptance-${caseId}`)
  value.requireCompletionNotice = true
  value.completionNotice = { schema: 1, observed: true, matchingCount: 1, notificationId: 3, channelId: 'task-completed',
    tagSha256: hash(`pocket-completed:${value.sessionId}`), previewSha256: value.markerSha256,
    visibilityPrivate: true, autoCancel: true, contentIntentPresent: true, contentIntentCreatorMatches: true }
  value.cleanup.completionNoticeCancelled = true
  return value
}

test('system completion notice evidence requires explicit admission and never certifies a notification tap', async () => {
  const evidence = output(noticeResult())
  assert.throws(() => parseAgentServiceTaskResult(evidence), /not explicitly requested/)
  assert.throws(() => parseAgentServiceTaskResult(output(), { requireCompletionNotice: true }), /evidence is missing/)
  const verified = parseAgentServiceTaskResult(evidence, { requireCompletionNotice: true })
  assert.equal(verified.completionNoticeTested, true)
  assert.equal(verified.notificationTapTested, false)
  assert.equal(verified.processRetirement, 'requires-outer-owner')
  assert.equal(parseAgentServiceTaskResult(output()).completionNoticeTested, false)
  const run = await runAgentServiceTaskAcceptance({ acceptRealAccountRequest: true, requireCompletionNotice: true,
    invoke: async argv => {
      assert.deepEqual(argv.slice(-4), ['-e', 'requireCompletionNotice', 'true',
        'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'])
      return evidence
    } })
  assert.equal(run.result.completionNoticeTested, true)
  for (const invalid of ['true', 1, null]) await assert.rejects(runAgentServiceTaskAcceptance({ acceptRealAccountRequest: true,
    requireCompletionNotice: invalid, invoke: () => assert.fail('Invalid notice option must not submit') }), /boolean/)
})

test('wrong-session, private-message, disabled-format, invalid intent and incomplete cleanup cannot certify a system notice', () => {
  for (const [key, bad] of Object.entries({ schema: 2, observed: false, matchingCount: 0, notificationId: 4, channelId: 'other',
    tagSha256: 'a'.repeat(64), previewSha256: 'a'.repeat(64), visibilityPrivate: false, autoCancel: false,
    contentIntentPresent: false, contentIntentCreatorMatches: false })) {
    const value = noticeResult(); value.completionNotice[key] = bad
    assert.throws(() => parseAgentServiceTaskResult(output(value), { requireCompletionNotice: true }), key)
  }
  const duplicate = noticeResult(); duplicate.completionNotice.matchingCount = 2
  assert.throws(() => parseAgentServiceTaskResult(output(duplicate), { requireCompletionNotice: true }))
  const unknown = noticeResult(); unknown.completionNotice.preview = 'PRIVATE NOTIFICATION TEXT'
  assert.throws(() => parseAgentServiceTaskResult(output(unknown), { requireCompletionNotice: true }), /evidence is missing/)
  const cleanup = noticeResult(); cleanup.cleanup.completionNoticeCancelled = false
  assert.throws(() => parseAgentServiceTaskResult(output(cleanup), { requireCompletionNotice: true }), /cleanup is unconfirmed/)
  const explicit = noticeResult(); explicit.requireCompletionNotice = false
  assert.throws(() => parseAgentServiceTaskResult(output(explicit), { requireCompletionNotice: true }))
  const failure = noticeResult(); failure.notificationCleanupFailureCode = 'NOTICE_CLEANUP_UNCONFIRMED'
  assert.throws(() => parseAgentServiceTaskResult(output(failure), { requireCompletionNotice: true }), /cleanup is unconfirmed/)
})
