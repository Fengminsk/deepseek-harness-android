import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { parseWorkflowDeathReady, parseWorkflowLifecycleResult,
  runWorkflowLifecyclePhases, requireWorkflowLifecycleCarrier } from './acceptance-workflow-lifecycle-device.mjs'
import { validateWorkflowDeadline, validateWorkflowDeathMarker } from './device-runtime-acceptance/workflow-lifecycle-evidence.mjs'
import { WORKFLOW_DEADLINE_CHECK, WORKFLOW_DEATH_CHECK } from './device-runtime-acceptance/workflow-checks.mjs'

const PACKAGE = 'com.minnnng.dsh_android'
const marker = (caseId = randomUUID()) => ({ schema: 1, caseId, runId: randomUUID(), agentPid: 5123,
  sessionId: `workflow-death-${caseId}`, childId: randomUUID(), childSessionId: `child-${randomUUID()}`,
  processLeaseId: randomUUID(), parentHash: 'a'.repeat(64), parentEvents: 8, childHash: 'b'.repeat(64), childEvents: 6 })
const deadline = () => ({ name: WORKFLOW_DEADLINE_CHECK, status: 'passed', runId: randomUUID(), childId: randomUUID(),
  deadlineMillis: 120000, elapsedMs: 121000, outerAborted: false, scriptState: 'TIMED_OUT', nativeState: 'FAILED',
  outputAbsent: true, released: true, activeModels: 0, modelAborted: true, childRetired: true, terminalCount: 1 })
const recovered = ready => ({ name: WORKFLOW_DEATH_CHECK, status: 'passed', ...ready, oldAgentPid: ready.agentPid,
  newAgentPid: 6201, currentLeaseId: randomUUID(), nativeState: 'INTERRUPTED_UNCONFIRMED',
  sessionState: 'interrupted-unconfirmed', nativeOutputAbsent: true, oldLeaseStopped: true,
  childRetired: true, requiresReview: true, unchangedParentLog: true, unchangedChildLog: true,
  replayedModelCalls: 0, replayedCallbacks: 0, newAdmissions: 0 })
function output(suite, check) {
  const state = JSON.stringify({ interactive: false, keyguardLocked: true, deviceLocked: true,
    displays: [{ id: 0, state: 1 }] })
  const result = { passed: true, complete: true, foregroundCarrier: 'service', reports: [{ suite, checks: [check] }] }
  return `INSTRUMENTATION_RESULT: result=${JSON.stringify(result)}\n` +
    ['deviceStateBefore', 'deviceStateReady', 'deviceStateAfter'].map(name => `INSTRUMENTATION_RESULT: ${name}=${state}\n`).join('') +
    'INSTRUMENTATION_RESULT: foregroundCarrier=service\nINSTRUMENTATION_RESULT: foregroundClosed=true\n' +
    'INSTRUMENTATION_RESULT: nativeOwnersClosed=true\nINSTRUMENTATION_CODE: -1\n'
}
const readyOutput = value => 'INSTRUMENTATION_STATUS: stage=foreground-ready\n' +
  'INSTRUMENTATION_STATUS: foregroundCarrier=service\nINSTRUMENTATION_STATUS_CODE: 1\n' +
  `INSTRUMENTATION_STATUS: ready=${JSON.stringify(value)}\nINSTRUMENTATION_STATUS_CODE: 1\n`

test('lifecycle driver only accepts the noninteractive service carrier', () => {
  assert.equal(requireWorkflowLifecycleCarrier([]), 'service')
  assert.equal(requireWorkflowLifecycleCarrier(['--foreground-carrier', 'service']), 'service')
  assert.throws(() => requireWorkflowLifecycleCarrier(['--foreground-carrier', 'activity']))
  assert.throws(() => requireWorkflowLifecycleCarrier(['--foreground-carrier', 'service', '--foreground-carrier', 'service']))
})

test('native timeout requires its own receipt and confirmed child retirement, not the outer timeout', () => {
  assert.doesNotThrow(() => validateWorkflowDeadline(deadline()))
  for (const [key, value] of Object.entries({ outerAborted: true, deadlineMillis: 5000, elapsedMs: 5001,
    scriptState: 'CANCELLED', nativeState: 'INTERRUPTED_UNCONFIRMED', outputAbsent: false,
    released: false, activeModels: 1, modelAborted: false, childRetired: false, terminalCount: 0 })) {
    assert.throws(() => validateWorkflowDeadline({ ...deadline(), [key]: value }), key)
  }
})

test('death marker is complete and bound to the dedicated case, Session and native lease', () => {
  const ready = marker(), raw = readyOutput(ready)
  assert.deepEqual(parseWorkflowDeathReady(raw, ready.caseId), ready)
  assert.equal(parseWorkflowDeathReady(raw.slice(0, raw.lastIndexOf('INSTRUMENTATION_STATUS_CODE')), ready.caseId), null)
  assert.throws(() => parseWorkflowDeathReady(raw + raw, ready.caseId))
  for (const patch of [{ caseId: randomUUID() }, { sessionId: 'user-session' }, { processLeaseId: 'unknown' },
    { childSessionId: ready.sessionId }, { agentPid: 0 }, { childEvents: 0 }, { parentHash: 'invalid' }]) {
    assert.throws(() => validateWorkflowDeathMarker({ ...ready, ...patch }, ready.caseId))
  }
})

test('recovery retains unknown results, unchanged logs and zero native/model replay', () => {
  const ready = marker()
  assert.equal(parseWorkflowLifecycleResult(output('workflow-process-death', recovered(ready)),
    'workflow-process-death', ready).requiresReview, true)
  for (const patch of [{ newAgentPid: ready.agentPid }, { currentLeaseId: ready.processLeaseId },
    { nativeState: 'COMPLETED' }, { sessionState: 'completed' }, { nativeOutputAbsent: false },
    { oldLeaseStopped: false }, { childRetired: false }, { unchangedChildLog: false },
    { unchangedParentLog: false }, { replayedModelCalls: 1 }, { replayedCallbacks: 1 }, { newAdmissions: 1 }]) {
    assert.throws(() => parseWorkflowLifecycleResult(output('workflow-process-death', { ...recovered(ready), ...patch }),
      'workflow-process-death', ready))
  }
  assert.throws(() => parseWorkflowLifecycleResult(output('workflow-deadline', deadline()).replaceAll(
    '"interactive":false', '"interactive":true'), 'workflow-deadline'))
})

function fakeDriver(options = {}) {
  let clock = 0, active = false, preparationClosed = false, ready, empty = 0
  const commands = [], events = []
  const guestName = () => `${PACKAGE}:ptc_script:${PACKAGE}.IsolatedScriptService:script_${ready.runId.replaceAll('-', '')}`
  const io = {
    start(command) {
      commands.push(command); events.push('prepare'); active = true
      ready = marker(command[command.indexOf('caseId') + 1])
      return { status: () => ({ output: readyOutput(ready), ended: preparationClosed }), async dispose() {
        events.push('host-close')
        if (options.unclosedHost) throw new Error('host close not confirmed')
        preparationClosed = true
      } }
    },
    async device(command) {
      commands.push(command)
      if (command.includes('force-stop')) { if (!options.stuck || !ready) active = false; return '' }
      if (command.includes('ps')) {
        if (active) return `PID ARGS\n5123 ${PACKAGE}:agent\n8142 ${guestName()}\n`
        empty++; events.push('empty'); return 'PID ARGS\n'
      }
      if (command.includes('dumpsys')) return `  * ServiceRecord{abc u0 component}\n    processName=${guestName()}\n` +
        `    app=ProcessRecord{abc 8142:${guestName()}/u0a496i262}\n`
      assert.ok(command.includes('instrument'))
      assert.equal(command[command.indexOf('foregroundCarrier') + 1], 'service')
      assert.ok(empty >= 2); empty = 0
      if (command.includes('workflow-deadline')) { events.push('deadline'); return output('workflow-deadline', deadline()) }
      assert.ok(preparationClosed, 'Recovery cannot race the old ADB client')
      events.push('recover')
      assert.equal(command[command.indexOf('processStopConfirmed') + 1], 'true')
      return output('workflow-process-death', { ...recovered(ready), ...options.badRecovery })
    },
  }
  return { io, commands, events, timing: { now: () => clock, pause: async ms => { clock += ms } } }
}

test('both isolated suites use service, actual retirement barriers and joined old client before recovery', async () => {
  const f = fakeDriver()
  const result = await runWorkflowLifecyclePhases(f.io, f.timing)
  assert.equal(result.complete, true); assert.equal(result.checks.length, 2)
  assert.equal(result.retirements.length, 4)
  assert.ok(result.retirements.every(row => row.confirmed && row.emptySamples === 2))
  assert.ok(f.events.indexOf('host-close') < f.events.indexOf('recover'))
  assert.ok(!f.commands.some(row => row.includes('input') || row.includes('clear')))
})

test('a live old process or unjoined ADB client prevents recovery rather than being hidden by force-stop', async () => {
  for (const options of [{ stuck: true }, { unclosedHost: true }]) {
    const f = fakeDriver(options)
    await assert.rejects(runWorkflowLifecyclePhases(f.io, { ...f.timing, suite: 'process-death' }), error => {
      assert.equal(error.evidence.complete, false)
      assert.equal(f.events.includes('recover'), false)
      return true
    })
  }
})

test('failed recovery retains earlier deadline evidence but never reports suite completion', async () => {
  const f = fakeDriver({ badRecovery: { replayedCallbacks: 1 } })
  await assert.rejects(runWorkflowLifecyclePhases(f.io, f.timing), error => {
    assert.equal(error.evidence.checks.length, 1)
    assert.equal(error.evidence.complete, false)
    assert.ok(error.evidence.retirements.at(-1).confirmed)
    return true
  })
})
