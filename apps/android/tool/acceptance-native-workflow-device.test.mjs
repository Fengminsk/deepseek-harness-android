import assert from 'node:assert/strict'
import { test } from 'node:test'
import { randomUUID } from 'node:crypto'
import { parseWorkflowResult, requireWorkflowInstrumentation, retireWorkflowProcesses,
  runWorkflowPhases } from './acceptance-native-workflow-device.mjs'

const app = 'com.minnnng.dsh_android'
const names = [
  'isolated-callbacks-and-durable-result',
  'isolated-guest-reported-error-is-durable-failure',
  'isolated-malformed-dsl-outcome-needs-review',
  'isolated-child-reservation-result-and-retirement',
  'isolated-route-denial-requires-confirmed-retirement',
  'admitted-workflow-pre-execution-cancel',
  'bounded-extended-workflow-and-upper-limit',
  'in-flight-child-cancel-retirement-and-cold-owner',
].join(',')
const leaseId = '00000000-0000-4000-8000-000000000201'
const passed = `INSTRUMENTATION_RESULT: passed=${names}\n` +
  'INSTRUMENTATION_RESULT: failed=\n' +
  'INSTRUMENTATION_RESULT: passedCount=8\n' +
  'INSTRUMENTATION_RESULT: failedCount=0\n' +
  `INSTRUMENTATION_RESULT: phase=baseline\nINSTRUMENTATION_RESULT: pid=120\n` +
  `INSTRUMENTATION_RESULT: processName=${app}:agent\nINSTRUMENTATION_RESULT: leaseId=${leaseId}\n` +
  'INSTRUMENTATION_CODE: -1\n'

test('requires the exact workflow runner in the Agent process', () => {
  const declaration = `E: instrumentation (line=30)\n` +
    `  A: android:name(0x01010003)="${app}.NativeWorkflowAcceptanceInstrumentation"\n` +
    `  A: android:targetPackage(0x01010021)="${app}"\n` +
    `  A: android:targetProcesses(0x01010541)="${app}:agent"\n`
  assert.doesNotThrow(() => requireWorkflowInstrumentation(declaration))
  assert.throws(() => requireWorkflowInstrumentation(declaration.replace(':agent', ':main')), /lacks/)
  assert.throws(() => requireWorkflowInstrumentation(declaration + declaration), /lacks/)
})

test('requires every private workflow device assertion exactly once', () => {
  assert.deepEqual(parseWorkflowResult(passed), { phase: 'baseline', pid: 120, leaseId, passed: names.split(',') })
  assert.throws(() => parseWorkflowResult(passed.replace('CODE: -1', 'CODE: 0')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('failedCount=0', 'failedCount=1')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('pre-execution-cancel', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('bounded-extended-workflow-and-upper-limit', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('in-flight-child-cancel-retirement-and-cold-owner', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed + 'INSTRUMENTATION_CODE: -1\n'), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('passedCount=8', 'passedCount=1')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('isolated-route-denial-requires-confirmed-retirement', 'other')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('in-flight-child-cancel-retirement-and-cold-owner',
    'bounded-extended-workflow-and-upper-limit')), /failed/)
  assert.throws(() => parseWorkflowResult(passed.replace('passedCount=8', 'passedCount=9')
    .replace(`passed=${names}`, `passed=${names},extra`)), /failed/)
})

function phaseOutput(phase, { runId, lease = randomUUID(), recoveries } = {}) {
  if (phase === 'baseline') return passed.replace(leaseId, lease)
  const fields = { phase, pid: 121, processName: `${app}:agent`, leaseId: lease,
    passed: phase === 'cold-recovery' ? 'isolated-route-denial-cold-recovery-retains-unknown'
      : `isolated-route-denial-${phase}-remains-unconfirmed`,
    passedCount: 1, failed: '', failedCount: 0,
    ...(phase === 'cold-recovery' ? { recoveries: JSON.stringify(recoveries) } : {
      runId, negativeObservation: JSON.stringify({ runId, state: 'INTERRUPTED_UNCONFIRMED', requiresReview: true,
        children: 2, allChildrenRetired: phase !== 'close-failure', releaseAcknowledged: false }),
    }),
  }
  return Object.entries(fields).map(([key, value]) => `INSTRUMENTATION_RESULT: ${key}=${value}\n`).join('')
    + 'INSTRUMENTATION_CODE: -1\n'
}

test('phase parsing requires exact process identity and explicit unknown outcomes', () => {
  const runId = randomUUID()
  assert.throws(() => parseWorkflowResult(passed.replace('phase=baseline', 'phase=close-failure')), /identity/)
  assert.throws(() => parseWorkflowResult(passed.replace('pid=120', 'pid=0')), /identity/)
  assert.throws(() => parseWorkflowResult(passed.replace(leaseId, 'unknown')), /identity/)
  const output = phaseOutput('close-failure', { runId })
  assert.equal(parseWorkflowResult(output, 'close-failure').observation.allChildrenRetired, false)
  assert.throws(() => parseWorkflowResult(output, 'bad-reservation'), /failed|identity/)
  assert.throws(() => parseWorkflowResult(output.replace('INTERRUPTED_UNCONFIRMED', 'FAILED'), 'close-failure'), /unconfirmed/)
  assert.throws(() => parseWorkflowResult(output.replace('"allChildrenRetired":false', '"allChildrenRetired":true'), 'close-failure'), /unconfirmed/)
  assert.throws(() => parseWorkflowResult(output.replace('"releaseAcknowledged":false', '"releaseAcknowledged":true'), 'close-failure'), /unconfirmed/)
})

function fakeDriver({ stuckAfterFirst = false, reuseLease = false, changePriorLease = false } = {}) {
  const calls = [], stages = [], prior = [], lease = randomUUID()
  let clock = 0, emptySincePhase = 0
  const device = async command => {
    calls.push(command)
    if (command.includes('force-stop')) return ''
    if (command.includes('ps')) {
      if (stuckAfterFirst && stages.length === 1) return `PID ARGS\n125 ${app}:agent\n`
      emptySincePhase++
      return 'PID ARGS\n1 init\n'
    }
    assert.ok(command.includes('instrument'))
    assert.ok(emptySincePhase >= 2, 'A phase cannot begin before two empty full process observations')
    emptySincePhase = 0
    const phase = command[command.indexOf('phase') + 1]
    stages.push(phase)
    const currentLease = reuseLease ? lease : randomUUID()
    const runId = command.includes('runId') ? command[command.indexOf('runId') + 1] : undefined
    if (runId) prior.push({ runId, state: 'INTERRUPTED_UNCONFIRMED', previousLeaseId: currentLease,
      previousProcess: 'STOPPED', children: 2, allChildrenRetired: true })
    if (phase === 'cold-recovery') {
      assert.equal(command[command.indexOf('priorRunIds') + 1], prior.map(row => row.runId).join(','))
      if (changePriorLease) prior[0].previousLeaseId = randomUUID()
    }
    return phaseOutput(phase, { runId, lease: currentLease, recoveries: prior })
  }
  return { device, calls, stages, timing: { now: () => clock, pause: async ms => { clock += ms } } }
}

test('all phases require a different live lease and observed retirement before the next unknown case', async () => {
  const f = fakeDriver()
  const result = await runWorkflowPhases(f.device, f.timing)
  assert.deepEqual(f.stages, ['baseline', 'bad-reservation', 'rpc-failure', 'close-failure', 'cold-recovery'])
  assert.equal(result.complete, true)
  assert.equal(result.passed.length, 12)
  assert.equal(result.retired.length, 6)
  assert.ok(result.retired.every(row => row.confirmed && row.emptySamples === 2))
  assert.ok(!f.calls.some(command => command.includes('input') || command.includes('clear')))
  assert.ok(result.phases.at(-1).recoveries.every(row => row.state === 'INTERRUPTED_UNCONFIRMED'))
})

test('force-stop acknowledgement while the Agent stays alive cannot start any later phase', async () => {
  const f = fakeDriver({ stuckAfterFirst: true })
  await assert.rejects(runWorkflowPhases(f.device, f.timing), error => {
    assert.equal(error.phaseEvidence.complete, false)
    assert.equal(error.phaseEvidence.phases.length, 1)
    return /retirement failed/.test(error.message)
  })
  assert.deepEqual(f.stages, ['baseline'])
})

test('a reused process lease or changed cold receipt owner blocks completion', async () => {
  for (const options of [{ reuseLease: true }, { changePriorLease: true }]) {
    const f = fakeDriver(options)
    await assert.rejects(runWorkflowPhases(f.device, f.timing), /reused a live process lease|changed a prior workflow owner/)
  }
})

test('malformed process lists, disconnected ADB and failed stop requests do not become retirement proof', async () => {
  for (const kind of ['malformed', 'disconnected', 'stop-failed']) {
    const device = async command => {
      if (command.includes('force-stop')) {
        if (kind === 'stop-failed') throw Error('ADB stop failed')
        return ''
      }
      if (kind === 'disconnected') throw Error('device offline')
      return kind === 'malformed' ? 'PID NAME\n' : 'PID ARGS\n'
    }
    await assert.rejects(retireWorkflowProcesses(device, { pause: async () => {} }),
      /listing is unavailable|device offline|force-stop request failed/)
  }
})
