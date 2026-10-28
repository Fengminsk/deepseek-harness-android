import assert from 'node:assert/strict'
import test from 'node:test'
import { ptcLinuxLifecycleProgram, validatePtcLinuxLifecycle, ptcNativeRetirementDiagnostics } from './device-runtime-acceptance/ptc-linux-lifecycle.mjs'

const caseId = '11111111-1111-4111-8111-111111111111'
const runId = '22222222-2222-4222-8222-222222222222'
const linuxIds = ['33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444']

test('native retirement diagnostics preserve fixed failure facts and exact callback closure without guest text', () => {
  const secret = 'private-model-text-token-command', detail = 'Host callback or capability audit did not settle; inspect run effects'
  const value = ptcNativeRetirementDiagnostics({ runId, state: 'RETIRE_UNCONFIRMED', guestUid: 99001, detail, outputJson: secret },
    [{ method: 'native.isolated.release', params: { runId, token: secret }, completedAtMs: 10 }],
    [{ runId, status: 'returned', closed: true }, { runId: caseId, status: 'rejected', errorCode: secret }])
  assert.deepEqual(value.nativeReceipt, { runId, state: 'RETIRE_UNCONFIRMED', guestUid: 99001,
    detailCode: 'callback-audit-unconfirmed', detail })
  assert.deepEqual(value.callbackClosures, [{ runId, closed: true, status: 'returned', errorCode: null }])
  assert.equal(value.nativeRequests[0].acknowledged, false)
  assert.equal(JSON.stringify(value).includes(secret), false)
  const unknown = ptcNativeRetirementDiagnostics({ runId, state: 'RETIRE_UNCONFIRMED', detail: secret })
  assert.equal(unknown.nativeReceipt.detail, null)
  assert.equal(unknown.nativeReceipt.detailCode, 'unlisted-native-detail')
})

// Synthetic records test only the validator; actual device observations remain mandatory in the runner.
function evidence(mode = 'cancel') {
  const sessionId = 'android-lifecycle-fixture', program = ptcLinuxLifecycleProgram(mode, caseId)
  const completedAtMs = mode === 'cancel' ? 20000 : 120100
  const executions = (mode === 'cancel' ? [program.command] : [program.prelude, program.command]).map((command, index, commands) => {
    const cancelled = index === commands.length - 1
    return { params: { id: linuxIds[index], sessionId, command, timeoutMs: 120000, persistChanges: true },
      startedAtMs: 1000 + index * 6000, completedAtMs: cancelled ? completedAtMs : 6000,
      result: { id: linuxIds[index], sessionId, status: cancelled ? 'cancelled' : 'completed',
        exitCode: cancelled ? -1 : 0, cancelled, timedOut: false, diskCommitted: !cancelled,
        retirementConfirmed: true, guestUid: 99002 } }
  })
  const last = executions.at(-1)
  const contexts = executions.map((row, index) => ({ source: { kind: 'android-linux-receipt' },
    content: [{ type: 'text', text: JSON.stringify({ linuxVmReceipt: {
      tool: 'linux_exec', callId: `call:ptc:${index + 1}`, runId: row.params.id, sessionId,
      status: row.result.status, retirementConfirmed: true, diskCommitted: row.result.diskCommitted,
      cancelRequested: index === executions.length - 1,
    } }) }] }))
  const liveEvents = executions.flatMap((row, index) => [
    { seq: 10 + index * 2, type: 'tool/ptc-dispatch-start', data: { name: 'linux_exec', subCallId: `call:ptc:${index + 1}`, arguments: { command: row.params.command } } },
    { seq: 11 + index * 2, type: 'tool/ptc-dispatch', data: { name: 'linux_exec', subCallId: `call:ptc:${index + 1}`,
      isError: row.result.cancelled, additionalContexts: [contexts[index]] } },
  ])
  const processes = { schema: 1, ptcRunId: runId, linuxRunId: last.params.id, appPid: 100,
    ptcPid: 200, linuxPid: 300, workerCpuSeconds: 1, observedPair: true, observedPtcPid: 200,
    observedLinuxPid: 300, observedAtElapsedMs: 1000, previousPidsGone: false }
  return { mode, caseId, sessionId, appUid: 10000, abortRequested: mode === 'cancel',
    result: { isError: true, additionalContexts: contexts }, executions,
    ptc: { admit: { params: { runId, sessionId, kind: 'ptc', deadlineMillis: 120000 } },
      execute: { params: { runId }, startedAtMs: 0, completedAtMs },
      settle: { runId, state: mode === 'cancel' ? 'CANCELLED' : 'TIMED_OUT', guestUid: 99001 },
      release: { params: { runId }, acknowledged: true } },
    active: { processes, inspection: { sessionId, status: 'active', blocked: true,
      records: [{ runId: last.params.id, operation: 'execute', state: 'running' }] } },
    retired: [2000, 2100].map(observedAtElapsedMs => ({ ...processes, ptcPid: null, linuxPid: null,
      previousPidsGone: true, observedAtElapsedMs })),
    cancellations: [{ params: { id: last.params.id }, result: { settled: true, cancelRequested: true } }],
    liveEvents, durableEvents: structuredClone(liveEvents) }
}

for (const mode of ['cancel', 'deadline']) test(`${mode} requires both receipts, exact process disappearance and durable callbacks`, () => {
  const value = evidence(mode), proof = validatePtcLinuxLifecycle(value)
  assert.equal(proof.mode, mode); assert.equal(proof.diskCommitted, false)
  assert.equal(proof.durableDispatches, mode === 'cancel' ? 1 : 2)
  assert.match(proof.sessionEvidenceSha256, /^[0-9a-f]{64}$/u)
})

for (const [name, mutate] of [
  ['foreign parent Session', value => { value.ptc.admit.params.sessionId = 'other' }],
  ['parent uncertainty', value => { value.ptc.settle.state = 'INTERRUPTED_UNCONFIRMED' }],
  ['missing native release', value => { value.ptc.release.acknowledged = false }],
  ['shared UID', value => { value.executions.at(-1).result.guestUid = value.ptc.settle.guestUid }],
  ['zero worker CPU', value => { value.active.processes.workerCpuSeconds = 0 }],
  ['unobserved guest pair', value => { value.active.processes.observedPair = false }],
  ['guest still present', value => { value.retired[1].linuxPid = 300 }],
  ['same observation reused', value => { value.retired[1].observedAtElapsedMs = value.retired[0].observedAtElapsedMs }],
  ['foreign observed run', value => { value.active.processes.linuxRunId = runId }],
  ['inactive native run', value => { value.active.inspection.records[0].state = 'cancelled' }],
  ['unconfirmed Linux retirement', value => { value.executions.at(-1).result.retirementConfirmed = false }],
  ['committed cancelled disk', value => { value.executions.at(-1).result.diskCommitted = true }],
  ['Linux own timeout', value => { value.executions.at(-1).result.timedOut = true }],
  ['unconfirmed cancel RPC', value => { value.cancellations[0].result.settled = false }],
  ['missing durable terminal', value => { value.durableEvents.pop() }],
  ['lost parent deferred receipt', value => { value.result.additionalContexts = [] }],
  ['shortened Linux deadline', value => { value.executions.at(-1).params.timeoutMs = 10000 }],
  ['shortened PTC deadline', value => { value.ptc.admit.params.deadlineMillis = 10000 }],
]) test(`lifecycle evidence rejects ${name}`, () => {
  const value = evidence(); mutate(value); assert.throws(() => validatePtcLinuxLifecycle(value))
})

for (const [name, mutate] of [
  ['fixture abort', value => { value.abortRequested = true }],
  ['early parent termination', value => { value.ptc.execute.completedAtMs = 110000 }],
  ['child deadline not later', value => { value.executions.at(-1).startedAtMs = 1 }],
  ['failed real prelude', value => { value.executions[0].result.exitCode = 1 }],
]) test(`native deadline evidence rejects ${name}`, () => {
  const value = evidence('deadline'); mutate(value); assert.throws(() => validatePtcLinuxLifecycle(value))
})

test('deadline program awaits the original Linux prelude and does not continue an uncertain receipt', async () => {
  const program = ptcLinuxLifecycleProgram('deadline', caseId)
  const execute = new Function('tools', `return (async()=>{${program.code}})()`)
  const calls = []
  const result = await execute({ async linux_exec(args) {
    calls.push(args)
    return calls.length === 1 ? { status: 'completed', exitCode: 0, retirementConfirmed: true, diskCommitted: true } : { pendingCommand: true }
  } })
  assert.deepEqual(result, { pendingCommand: true })
  assert.deepEqual(calls.map(row => row.command), [program.prelude, program.command])
  assert.ok(calls.every(row => row.timeoutMs === 120000))
  let attempted = 0
  await assert.rejects(execute({ async linux_exec() { attempted++; return { status: 'outcome_uncertain' } } }), /Prelude did not settle/u)
  assert.equal(attempted, 1)
})
