import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { parseAgentServiceTaskResult, runAgentServiceTaskAcceptance,
  parseAgentServiceTaskCleanupResult, runAgentServiceTaskCleanup } from './acceptance-agent-service-task-device.mjs'

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

function programmaticResult(exercise) {
  const value = result()
  Object.assign(value, { exercise, requestId: `account-request-${caseId}`, toolCalls: 1, callId: 'program-call',
    argumentsSha256: 'd'.repeat(64), toolStartSeq: 6, toolEndSeq: exercise === 'ptc' ? 9 : 11,
    endSeq: exercise === 'ptc' ? 11 : 13, markerSha256: createHash('sha256').update(`account-acceptance-${caseId}`).digest('hex') })
  value.programmatic = { exercise, tool: exercise === 'ptc' ? 'android_ptc' : 'workflow', callId: value.callId,
    argumentsSha256: value.argumentsSha256, resultSha256: 'e'.repeat(64) }
  if (exercise === 'ptc') Object.assign(value.programmatic, { reviewedCallbacks: 1, callbackName: 'list_agents',
    callbackStartSeq: 7, callbackEndSeq: 8, children: 0 })
  else {
    const runId = 'b0000000-0000-4000-8000-000000000002', childSessionId = 'c0000000-0000-4000-8000-000000000003'
    Object.assign(value.programmatic, { runId, childSessionId, memberCount: 1, runEndCount: 1, runStartSeq: 7, runEndSeq: 10,
      inspection: { runId, state: 'completed', requiresReview: false },
      child: { sessionId: childSessionId, eventCount: 12, toolCalls: 0, assistantMarkerMatches: 1,
        turnEndCount: 1, completionKind: 'completed', historySha256: 'f'.repeat(64) } })
    value.cleanup.childArchived = true
  }
  return value
}

function cleanupResult() {
  const value = programmaticResult('workflow')
  Object.assign(value, { kind: 'production-account-task-cleanup', exercise: 'workflow-cleanup', submittedCount: 0, archived: false })
  delete value.ownTaskRunningObserved
  delete value.backgroundDuring
  delete value.foregroundDuring
  value.cleanup.archived = false
  for (const when of ['Before', 'After']) value[`background${when}`] = {
    fresh: true, running: 0, queued: 0, waiting: 0, backgroundJobs: 0, packageOperations: 0 }
  return value
}

test('previous workflow cleanup explicitly selects its original case without a new account request', async () => {
  const evidence = output(cleanupResult())
  const parsed = parseAgentServiceTaskCleanupResult(evidence, { caseId })
  assert.equal(parsed.newTaskSubmitted, false)
  assert.equal(parsed.cleanup.childArchived, true)
  assert.equal(parsed.processRetirement, 'requires-outer-owner')
  assert.throws(() => parseAgentServiceTaskResult(evidence, { exercise: 'workflow' }))
  let calls = 0
  const invoke = async argv => {
    calls++
    assert.deepEqual(argv, ['shell', 'am', 'instrument', '-w', '-r', '-e', 'acceptRealAccountRequest', 'false',
      '-e', 'exercise', 'workflow-cleanup', '-e', 'cleanupCaseId', caseId,
      'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'])
    return evidence
  }
  for (const options of [{}, { caseId: 'foreign' }, { caseId, acceptRealAccountRequest: true }]) {
    await assert.rejects(runAgentServiceTaskCleanup({ invoke, ...options }), /cleanup identity/)
  }
  assert.equal(calls, 0)
  assert.equal((await runAgentServiceTaskCleanup({ invoke, caseId })).result.submittedCount, 0)
  assert.equal(calls, 1)
})

test('cleanup cannot certify a new task, altered ownership, unconfirmed archive or a busy service', () => {
  for (const patch of [{ kind: 'production-account-task' }, { caseId: 'b0000000-0000-4000-8000-000000000002' },
    { sessionId: 'unrelated' }, { requestId: 'unrelated' }, { submittedCount: 1 }, { archived: true }, { ownTaskRunningObserved: true },
    { backgroundDuring: { running: 1 } }, { requireCompletionNotice: false }, { toolCalls: 0 }, { generation: '' }, { agentPid: 0 },
    { historySha256: '' }, { eventCount: 0 }, { childCleanupFailureCode: 'FAILED' }, { completionKind: 'cancelled' }]) {
    assert.throws(() => parseAgentServiceTaskCleanupResult(output({ ...cleanupResult(), ...patch }), { caseId }))
  }
  for (const key of ['childArchived', 'taskSettled', 'exportReleased', 'disconnected']) {
    const value = cleanupResult(); value.cleanup[key] = false
    assert.throws(() => parseAgentServiceTaskCleanupResult(output(value), { caseId }))
  }
  for (const key of ['archived', 'cancelRequested']) {
    const value = cleanupResult(); value.cleanup[key] = true
    assert.throws(() => parseAgentServiceTaskCleanupResult(output(value), { caseId }))
  }
  for (const when of ['Before', 'After']) {
    const value = cleanupResult(); value[`background${when}`].running = 1
    assert.throws(() => parseAgentServiceTaskCleanupResult(output(value), { caseId }))
  }
  const value = cleanupResult(); value.programmatic.child.sessionId = 'foreign'
  assert.throws(() => parseAgentServiceTaskCleanupResult(output(value), { caseId }))
})

test('cleanup cancellation cannot dispatch or turn an interrupted acknowledgement into success', async () => {
  const before = new AbortController(); before.abort(new Error('before cleanup'))
  await assert.rejects(runAgentServiceTaskCleanup({ caseId, signal: before.signal,
    invoke: () => assert.fail('No cancelled cleanup dispatch') }), /before cleanup/)
  const during = new AbortController()
  await assert.rejects(runAgentServiceTaskCleanup({ caseId, signal: during.signal,
    invoke: async () => { during.abort(new Error('during cleanup')); return output(cleanupResult()) } }), /during cleanup/)
})

test('PTC and workflow task exercises require separate explicit selection and retain outer retirement obligations', async () => {
  for (const exercise of ['ptc', 'workflow']) {
    const value = programmaticResult(exercise)
    assert.throws(() => parseAgentServiceTaskResult(output(value)), /exercise/)
    assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: exercise === 'ptc' ? 'workflow' : 'ptc' }), /exercise/)
    const parsed = parseAgentServiceTaskResult(output(value), { exercise })
    assert.equal(parsed.programmaticExercise, exercise)
    assert.equal(parsed.processRetirement, 'requires-outer-owner')
    const run = await runAgentServiceTaskAcceptance({ acceptRealAccountRequest: true, exercise, invoke: async argv => {
      assert.deepEqual(argv.slice(-4), ['-e', 'exercise', exercise,
        'com.minnnng.dsh_android.test/com.minnnng.dsh_android.AgentServiceTaskAcceptanceInstrumentation'])
      return output(value)
    } })
    assert.equal(run.result.programmaticExercise, exercise)
  }
  for (const exercise of ['radio-linux', 'unknown', null, true]) await assert.rejects(runAgentServiceTaskAcceptance({
    acceptRealAccountRequest: true, exercise, invoke: () => assert.fail('Unsupported exercise was invoked'),
  }), /exercise/)
  await assert.rejects(runAgentServiceTaskAcceptance({ acceptRealAccountRequest: true, exercise: 'workflow', requireCompletionNotice: true,
    invoke: () => assert.fail('Combined exercise was invoked') }), /completion notice/)
})

test('PTC acceptance rejects missing, foreign, failed and extra callback evidence', () => {
  for (const patch of [{ reviewedCallbacks: 0 }, { reviewedCallbacks: 2 }, { callbackName: 'read' }, { children: 1 },
    { callbackStartSeq: 6 }, { callbackEndSeq: 9 }, { callId: 'foreign' }, { argumentsSha256: 'c'.repeat(64) },
    { tool: 'linux_exec' }, { resultSha256: '' }, { unknown: 'private content' }]) {
    const value = programmaticResult('ptc'); Object.assign(value.programmatic, patch)
    assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: 'ptc' }))
  }
  for (const patch of [{ requestId: 'foreign' }, { markerSha256: 'a'.repeat(64) }, { toolCalls: 0 }, { toolEndSeq: 5 },
    { endSeq: 8 }, { programmatic: null }, { childCleanupFailureCode: 'FAILED' }]) {
    const value = Object.assign(programmaticResult('ptc'), patch)
    assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: 'ptc' }))
  }
  const extraCleanup = programmaticResult('ptc'); extraCleanup.cleanup.childArchived = true
  assert.throws(() => parseAgentServiceTaskResult(output(extraCleanup), { exercise: 'ptc' }))
})

test('workflow acceptance requires one completed workflow observation and an independent durable child', () => {
  for (const patch of [{ state: 'running' }, { requiresReview: true }, { runId: 'foreign' }, { extra: true }]) {
    const value = programmaticResult('workflow'); Object.assign(value.programmatic.inspection, patch)
    assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: 'workflow' }))
  }
  for (const patch of [{ sessionId: `android-account-acceptance-${caseId}` }, { eventCount: 0 }, { eventCount: 512 },
    { toolCalls: 1 }, { assistantMarkerMatches: 0 }, { completionKind: 'cancelled' }, { historySha256: '' }, { prompt: 'private' }]) {
    const value = programmaticResult('workflow'); Object.assign(value.programmatic.child, patch)
    assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: 'workflow' }))
  }
  for (const patch of [{ memberCount: 2 }, { runEndCount: 0 }, { runStartSeq: 6 }, { runEndSeq: 11 }, { childSessionId: 'foreign' }]) {
    const value = programmaticResult('workflow'); Object.assign(value.programmatic, patch)
    assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: 'workflow' }))
  }
  const cleanup = programmaticResult('workflow'); cleanup.cleanup.childArchived = false
  assert.throws(() => parseAgentServiceTaskResult(output(cleanup), { exercise: 'workflow' }))
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
