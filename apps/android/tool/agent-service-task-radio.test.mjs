import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { radioTaskProtocol as protocol } from './agent-service-task-radio.mjs'
import { parseAgentServiceTaskResult } from './acceptance-agent-service-task-device.mjs'

const token = 'a'.repeat(32), caseId = '62f1a152-6775-4e3d-a4a7-c9fd9cf9a123'
const sessionId = `android-account-acceptance-${caseId}`
const sha = text => createHash('sha256').update(text).digest('hex')
const marker = `account-acceptance-${caseId}`
// Literal wire command, deliberately not built by the validator under test.
const command = `python3 - <<'PY'
import hashlib,json,time
marker='account-acceptance-62f1a152-6775-4e3d-a4a7-c9fd9cf9a123'
started=time.monotonic()
time.sleep(40)
print(json.dumps({'marker':marker,'sha256':hashlib.sha256(marker.encode()).hexdigest(),'waitMs':int((time.monotonic()-started)*1000)}))
PY`
const background = (running = 1) => ({ keepAwakeWhileWorking: true, wakeLockHeld: running > 0, fresh: true,
  running, queued: 0, waiting: 0, failed: 0, backgroundJobs: 0, packageOperations: 0, taskState: running ? 'running' : 'idle',
  powerErrorPresent: false, notificationErrorPresent: false })
const fact = (handle, options = {}) => ({ handle, capabilitiesKnown: true, internet: true, validated: true, vpn: false,
  notSuspended: true, appDefault: false, transportTypes: [1], ...options })
function networks(online = true) {
  const vpn = fact('20', { vpn: true, appDefault: true, transportTypes: [4] })
  const ims = fact('30', { internet: false, transportTypes: [0] })
  return { schema: 2, appDefaultNetworkHandle: '20', networks: [...(online ? [fact('10')] : []), vpn, ims],
    validatedNetworks: online ? 3 : 2, validatedInternetNetworks: online ? 2 : 1, validatedVpnInternetNetworks: 1,
    usableUnderlyingInternetNetworks: online ? 1 : 0, unvalidatedUnderlyingInternetNetworks: 0, unknownCapabilityNetworks: 0 }
}
function checkpoint(stage = 'ready', online = stage !== 'offline') {
  return { schema: 1, token, caseId, sessionId, generation: 'run-generation-1', agentPid: 42, stage,
    locked: true, interactive: false, networkEvidence: networks(online), ownTaskRunning: true, toolPending: true,
    toolStartSeq: 6, callId: 'call-1', commandSha256: sha(command), background: background(), elapsedMs: stage === 'ready' ? 1000 : 2000 }
}
function result() {
  const initial = checkpoint()
  return { ...Object.fromEntries(['token', 'caseId', 'sessionId', 'generation', 'agentPid', 'callId', 'toolStartSeq', 'commandSha256']
    .map(key => [key, initial[key]])), schema: 1, kind: 'production-account-task', exercise: 'radio-linux', passed: true,
  requestId: `account-request-${caseId}`, provider: 'deepseek-account', model: 'deepseek-flash',
  submittedCount: 1, userMessageCount: 1, assistantMarkerMatches: 1, toolCalls: 1, turnEndCount: 1, completionKind: 'completed',
  markerSha256: sha(marker), historySha256: 'f'.repeat(64), eventCount: 20, endSeq: 19, toolEndSeq: 13, elapsedMs: 52000,
  archived: true, deviceStateBefore: { locked: true, interactive: false }, deviceStateAfter: { locked: true, interactive: false },
  foregroundBefore: true, foregroundDuring: true, foregroundAfter: true, ownTaskRunningObserved: true,
  backgroundBefore: background(0), backgroundDuring: background(), backgroundAfter: background(0),
  cleanup: { cancelRequested: false, taskSettled: true, archived: true, exportReleased: true, disconnected: true },
  radioRestoredObserved: true, offlineCheckpointElapsedMs: 4000, restoredCheckpointElapsedMs: 20000, retryEventCount: 0,
  linuxReceipt: { id: 'fe9d1e5a-f21b-4a93-ab13-1eea999681bc', status: 'completed', exitCode: 0, retirementConfirmed: true,
    cancelled: false, timedOut: false, truncated: false, cancelRequested: false, diskCommitted: true, guestUid: 99450,
    waitMs: 40003, outputSha256: sha(JSON.stringify({ marker, sha256: sha(marker), waitMs: 40003 })) } }
}
const line = (field, value) => `INSTRUMENTATION_STATUS: ${field}=${JSON.stringify(value)}\n`
const output = (value = result()) => `INSTRUMENTATION_RESULT: result=${JSON.stringify(value)}\nINSTRUMENTATION_RESULT: passed=true\nINSTRUMENTATION_CODE: -1\n`
function progress(sequence = 1) {
  return { schema: 1, kind: 'production-account-task', token, caseId, stage: 'submitted', lastStage: 'submitted', pulse: sequence > 1,
    sequence, pid: 11, elapsedMs: sequence * 1000, uptimeMs: sequence * 900, runtimeObservedAtMs: 500,
    runtime: { phase: 'ready', bootStage: 'ready', nodeStarted: true } }
}

test('accepts exact call across VPN/IMS-preserving offline checkpoints and projects no raw network details', () => {
  const initial = protocol.ready(checkpoint(), token)
  const offline = checkpoint('offline')
  offline.networkEvidence.networks[0].ssid = 'PRIVATE NETWORK'
  offline.secret = 'PRIVATE TEXT'
  const verified = protocol.checkpoint(offline, initial, 'offline')
  assert.equal(verified.networkEvidence.validatedVpnInternetNetworks, 1)
  assert.equal(verified.networkEvidence.usableUnderlyingInternetNetworks, 0)
  assert.equal(JSON.stringify(verified).includes('PRIVATE'), false)
  assert.equal(protocol.checkpoint(checkpoint('observe', false), initial, 'observe').toolPending, true)
  assert.equal(protocol.checkpoint(checkpoint('observe', true), initial, 'observe').toolPending, true)
  assert.equal(protocol.checkpoint(checkpoint('restored'), initial, 'restored').stage, 'restored')
})

test('identity/call/command and running/lock facts fail closed before radio operations', async t => {
  for (const [field, bad] of Object.entries({ token: 'b'.repeat(32), caseId: 'invalid', sessionId: 'user-session', generation: '',
    agentPid: 0, callId: '', toolStartSeq: -1, commandSha256: sha(`${command}\n`), locked: false, interactive: true,
    ownTaskRunning: false, toolPending: false, elapsedMs: NaN })) {
    await t.test(field, () => assert.throws(() => protocol.ready({ ...checkpoint(), [field]: bad }, token), /Radio task/))
  }
  for (const [field, bad] of Object.entries({ caseId: '62f1a152-6775-4e3d-a4a7-c9fd9cf9a124', generation: 'next-generation', agentPid: 43,
    callId: 'call-2', toolStartSeq: 7, elapsedMs: 999, stage: 'ready' })) {
    await t.test(`changed ${field}`, () => assert.throws(() => protocol.checkpoint({ ...checkpoint('offline'), [field]: bad }, checkpoint(), 'offline')))
  }
  for (const field of ['fresh', 'wakeLockHeld']) {
    const value = checkpoint(); value.background[field] = false
    assert.throws(() => protocol.ready(value, token), /background task/)
  }
})

test('does not call VPN/IMS a usable underlying network or overlook Ethernet, unvalidated internet or unknown capabilities', () => {
  assert.throws(() => protocol.ready({ ...checkpoint(), networkEvidence: networks(false) }, token), /underlying internet/)
  assert.throws(() => protocol.checkpoint(checkpoint('offline', true), checkpoint(), 'offline'), /underlying internet/)
  const ethernet = checkpoint('offline')
  ethernet.networkEvidence.networks.push(fact('40', { transportTypes: [3] }))
  ethernet.networkEvidence.validatedNetworks++; ethernet.networkEvidence.validatedInternetNetworks++
  ethernet.networkEvidence.usableUnderlyingInternetNetworks++
  assert.throws(() => protocol.checkpoint(ethernet, checkpoint(), 'offline'), /underlying internet/)
  const unvalidated = checkpoint('offline')
  unvalidated.networkEvidence.networks.push(fact('40', { validated: false }))
  unvalidated.networkEvidence.unvalidatedUnderlyingInternetNetworks++
  assert.throws(() => protocol.checkpoint(unvalidated, checkpoint(), 'offline'), /underlying internet/)
  const unknown = checkpoint('offline')
  unknown.networkEvidence.networks.push(fact('40', { capabilitiesKnown: false, internet: false, validated: false, notSuspended: false, transportTypes: [] }))
  unknown.networkEvidence.unknownCapabilityNetworks++
  assert.throws(() => protocol.checkpoint(unknown, checkpoint(), 'offline'), /unknown/)
  const fabricated = checkpoint('offline'); fabricated.networkEvidence.validatedNetworks = 0
  assert.throws(() => protocol.checkpoint(fabricated, checkpoint(), 'offline'), /count differs/)
})

test('accepts durable single-submission Linux completion without inventing radio retry or outer retirement evidence', () => {
  const value = result(); value.untrustedText = 'PRIVATE MODEL TEXT'
  const verified = protocol.result(output(value), checkpoint())
  assert.equal(verified.linuxReceipt.diskCommitted, true)
  assert.equal(verified.modelRequestRetryTested, false)
  assert.equal(verified.physicalPanelEvidence, 'requires-outer-owner')
  assert.equal(verified.processRetirement, 'requires-outer-owner')
  assert.equal(JSON.stringify(verified).includes('PRIVATE'), false)
  value.linuxReceipt.diskCommitted = false
  value.retryEventCount = 2
  assert.equal(protocol.result(output(value), checkpoint()).retryEventCount, 2)
  assert.throws(() => parseAgentServiceTaskResult(output(value), { exercise: 'radio-linux' }),
    /invoked a tool|exact result evidence/)
})

test('final durable identity, counts, hashes, ordering and restoration are required', async t => {
  for (const [key, bad] of Object.entries({ token: 'b'.repeat(32), generation: 'different', agentPid: 43, requestId: 'another-request',
    callId: 'second-call', toolStartSeq: 7, commandSha256: '0'.repeat(64), markerSha256: sha(`wrong-${marker}`),
    passed: false, exercise: 'echo', kind: 'another-test', provider: 'another-provider', model: 'private title with spaces',
    submittedCount: 2, userMessageCount: 2, assistantMarkerMatches: 0, toolCalls: 2, turnEndCount: 2, completionKind: 'interrupted',
    historySha256: '', eventCount: 512, toolEndSeq: 6, endSeq: 13, retryEventCount: -1, radioRestoredObserved: false,
    offlineCheckpointElapsedMs: 999, restoredCheckpointElapsedMs: 18999, elapsedMs: 19999, archived: false,
    ownTaskRunningObserved: false, foregroundBefore: false, foregroundDuring: false, foregroundAfter: false })) {
    await t.test(key, () => assert.throws(() => protocol.result(output({ ...result(), [key]: bad }), checkpoint()), /Radio task/))
  }
})

test('no success on incomplete guest retirement, failed native execution or incomplete cleanup', async t => {
  for (const [key, bad] of Object.entries({ id: 'not-a-uuid', status: 'outcome_uncertain', exitCode: 1, retirementConfirmed: false,
    cancelled: true, timedOut: true, truncated: true, cancelRequested: true, diskCommitted: null, guestUid: 0,
    waitMs: 38999, outputSha256: 'bad' })) {
    await t.test(`receipt ${key}`, () => {
      const value = result(); value.linuxReceipt[key] = bad
      assert.throws(() => protocol.result(output(value), checkpoint()), /Linux execution/)
    })
  }
  for (const key of ['cancelRequested', 'taskSettled', 'archived', 'exportReleased', 'disconnected']) {
    await t.test(`cleanup ${key}`, () => {
      const value = result(); value.cleanup[key] = key === 'cancelRequested'
      assert.throws(() => protocol.result(output(value), checkpoint()), /cleanup/)
    })
  }
  const active = result(); active.backgroundDuring.wakeLockHeld = false
  assert.throws(() => protocol.result(output(active), checkpoint()), /background task/)
  const unlocked = result(); unlocked.deviceStateAfter.locked = false
  assert.throws(() => protocol.result(output(unlocked), checkpoint()), /noninteractive/)
})

test('terminal output must have exactly one matching result, pass flag and completion code', () => {
  for (const invalid of [output() + output(), output().replace('CODE: -1', 'CODE: 0'), output().replace('passed=true', 'passed=false'),
    output().replace('INSTRUMENTATION_RESULT: passed=true\n', ''), output() + 'INSTRUMENTATION_CODE: -1\n']) {
    assert.throws(() => protocol.result(invalid, checkpoint()))
  }
  const failure = result(); failure.failureCode = 'RPC_FAILED'; failure.failureCodeType = 'EvidenceRejected'
  assert.throws(() => protocol.result(output(failure), checkpoint()), /contains a failure/)
  assert.throws(() => protocol.result('x'.repeat(2 * 1024 * 1024 + 1), checkpoint()), /bound/)
  const coerced = result(); coerced.linuxReceipt.id = [coerced.linuxReceipt.id]
  assert.throws(() => protocol.result(output(coerced), checkpoint()), /Linux execution/)
  const premature = result(); premature.elapsedMs = 30000
  assert.throws(() => protocol.result(output(premature), checkpoint()), /Linux execution/)
  assert.throws(() => protocol.ready({ ...checkpoint(), caseId: [caseId] }, token), /identity/)
})

test('progress accepts ordered pulses and complete lines only, without a fabricated stage ordering', () => {
  const first = progress(), second = progress(2)
  second.stage = second.lastStage = 'connected' // Callback can follow another stage.
  assert.deepEqual(protocol.progress(line('progress', first) + line('progress', second), token), second)
  assert.equal(protocol.progress(line('progress', first).slice(0, -1), token), undefined)
  const empty = progress(); empty.runtime = null; empty.runtimeObservedAtMs = null
  assert.equal(protocol.progress(line('progress', empty), token).runtime, null)
  const unknown = progress(); unknown.runtime = { phase: 'unknown', bootStage: 'unknown', nodeStarted: null }
  assert.equal(protocol.progress(line('progress', unknown), token).runtime.nodeStarted, null)
})

test('progress rejects foreign tokens/identities, replayed sequence, backwards clocks and arbitrary properties', async t => {
  for (const [key, bad] of Object.entries({ token: 'b'.repeat(32), caseId: 'other', kind: 'other', stage: 'model-private-text', lastStage: 'other',
    pulse: 'yes', sequence: 0, pid: 0, elapsedMs: -1, uptimeMs: -1, runtimeObservedAtMs: 1001 })) {
    await t.test(key, () => assert.throws(() => protocol.progress(line('progress', { ...progress(), [key]: bad }), token), /Radio task/))
  }
  for (const [key, bad] of Object.entries({ sequence: 1, pid: 12, caseId: '62f1a152-6775-4e3d-a4a7-c9fd9cf9a124', elapsedMs: 999, uptimeMs: 899 })) {
    assert.throws(() => protocol.progress(line('progress', progress()) + line('progress', { ...progress(2), [key]: bad }), token), /Radio task/)
  }
  const leaked = progress(); leaked.raw = 'PRIVATE TEXT'
  assert.throws(() => protocol.progress(line('progress', leaked), token), /unsupported/)
  assert.throws(() => protocol.progress(line('progress', { ...progress(), raw: 'x'.repeat(1024) }), token), /bound/)
  assert.throws(() => protocol.progress('INSTRUMENTATION_STATUS: progress={bad}\n', token), error => !error.message.includes('{bad}'))
})

test('failure diagnostic exposes only this run fixed codes and types, never arbitrary model or Java text', () => {
  const value = { schema: 1, kind: 'production-account-task', exercise: 'radio-linux', token, caseId, sessionId, passed: false,
    failureCode: 'RADIO_TOOL_FINISHED_EARLY', failureCodeType: 'EvidenceRejected', cleanupFailureCode: 'TASK_NOT_SETTLED',
    cleanupFailureCodeType: 'EvidenceRejected', failure: 'PRIVATE MODEL TEXT', stack: 'PRIVATE STACK' }
  const verified = protocol.failure(output(value), token)
  assert.equal(verified.failureCode, 'RADIO_TOOL_FINISHED_EARLY')
  assert.equal(JSON.stringify(verified).includes('PRIVATE'), false)
  assert.equal(protocol.failure('', token), undefined)
  assert.equal(protocol.failure(output(), token), undefined)
  assert.throws(() => protocol.failure(output({ ...value, token: 'b'.repeat(32) }), token), /different task/)
  assert.throws(() => protocol.failure(output({ ...value, failureCode: 'PRIVATE_TEXT' }), token), /unsupported/)
  assert.throws(() => protocol.failure(output({ ...value, failureCodeType: 'PRIVATE_TEXT' }), token), /unsupported/)
  assert.throws(() => protocol.failure(output(value) + output(value), token), /duplicate/)
})
