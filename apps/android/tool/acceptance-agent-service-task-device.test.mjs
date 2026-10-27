import test from 'node:test'
import assert from 'node:assert/strict'
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
