import assert from 'node:assert/strict'
import test from 'node:test'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { scheduleWakeInstrumentationArguments, parseScheduleWakePhase, naturalWakeServiceEvidence,
  runNaturalWakeAcceptance, scheduleWakeInstrumentationIdle } from './acceptance-schedule-wakeup-device.mjs'

const caseId = '42b1d2e3-1234-4567-8abc-123456789012', mainPid = 101, oldPid = 102, newPid = 103
const hash = value => createHash('sha256').update(value).digest('hex')
function value(phase) {
  return { schema: 1, kind: 'natural-schedule-wake', phase, caseId, mainPid, passed: true,
    agentPid: phase === 'observe' || phase === 'cleanup' ? newPid : oldPid,
    generation: phase === 'observe' || phase === 'cleanup' ? 'new' : 'old',
    testCpuLease: false, serviceStartedByFixture: false, bindingAutoCreate: false, bindingReleased: true,
    deviceWallMs: 1000, deviceStateBefore: { locked: true, interactive: false }, deviceStateAfter: { locked: true, interactive: false },
    ...(phase === 'status' ? { needsUserAction: false, wake: { enabled: true, exactAlarmsAllowed: true } } : {}),
    ...(phase === 'prepare' ? { sessionId: `android-schedule-acceptance-${caseId}`, oldAgentRetired: true,
      bindingReleasedBeforeKill: true, oldAgentPid: oldPid, dueAtMs: 61_000, armedAtMs: 61_000,
      recordSha256: hash('record'), reminderIdSha256: hash('reminder') } : {}),
    ...(phase === 'observe' ? { sessionId: `android-schedule-acceptance-${caseId}`, oldAgentPid: oldPid, dueAtMs: 61_000,
      delivery: { deliveryCount: 1, humanSubmissions: 1, toolCalls: 1, completedTurns: 2, assistantMarkerMatches: 1,
        markerSha256: hash(`schedule-delivered-${caseId}`), historySha256: hash('history'), eventCount: 24,
        deliveryInputSeq: 15, finalSeq: 20, endSeq: 22 } } : {}),
    ...(phase === 'cleanup' ? { ownTaskSettled: true, ownReminderDeleted: true, ownSessionArchived: true,
      preferencesChanged: false, permissionsChanged: false } : {}) }
}
const output = value => `INSTRUMENTATION_RESULT: result=${JSON.stringify(value)}\nINSTRUMENTATION_CODE: -1\n`
const dump = pid => `ACTIVITY MANAGER SERVICES\n  * ServiceRecord{abc u0 com.minnnng.dsh_android/.AgentService}\n    intent={act=com.minnnng.dsh_android.SCHEDULE_WAKE cmp=com.minnnng.dsh_android/.AgentService}\n    app=ProcessRecord{123 ${pid}:com.minnnng.dsh_android:agent/u0a496}\n`

test('all four entry phases use no-restart and never create an Activity or force-stop', () => {
  for (const phase of ['status', 'prepare', 'observe', 'cleanup']) {
    const args = scheduleWakeInstrumentationArguments({ phase, caseId, mainPid, acceptRealAccountRequest: true })
    assert.ok(args.includes('--no-restart'))
    assert.equal(args.includes('force-stop'), false)
    assert.deepEqual(args.slice(0, 4), ['shell', 'am', 'instrument', '--no-restart'])
  }
  assert.throws(() => scheduleWakeInstrumentationArguments({ phase: 'prepare', caseId, mainPid }), /REAL_ACCOUNT/)
})

test('missing permission remains needs-user-action and is not natural delivery success', () => {
  const status = value('status'); status.needsUserAction = true; status.wake.enabled = false
  assert.equal(parseScheduleWakePhase(output(status), { phase: 'status', caseId, mainPid }).needsUserAction, true)
})

test('phase parser rejects changed identity, create bindings, unlocked state and forged marker receipt', () => {
  for (const mutate of [v => { v.mainPid++ }, v => { v.bindingAutoCreate = true },
    v => { v.deviceStateAfter.interactive = true }, v => { v.delivery.markerSha256 = hash('prompt only') },
    v => { v.delivery.completedTurns = 1 }, v => { v.delivery.toolCalls = 2 }]) {
    const observation = value('observe'); mutate(observation)
    assert.throws(() => parseScheduleWakePhase(output(observation), { phase: 'observe', caseId, mainPid }))
  }
})

test('wake evidence belongs to the current exact service PID, not a prior history line', () => {
  assert.equal(naturalWakeServiceEvidence(dump(newPid), newPid).actionWakeObserved, true)
  assert.throws(() => naturalWakeServiceEvidence(dump(oldPid), newPid), /PROCESS/)
  assert.throws(() => naturalWakeServiceEvidence(dump(newPid).replace('intent={act=', 'oldIntent={act='), newPid), /INTENT/)
  assert.throws(() => naturalWakeServiceEvidence(dump(newPid) + dump(oldPid), newPid), /UNIQUE/)
  assert.throws(() => naturalWakeServiceEvidence(dump(newPid).replace('act=com.minnnng.dsh_android.SCHEDULE_WAKE', 'act=OTHER'), newPid), /INTENT/)
})

test('instrumentation retirement requires a recognized current process dump', () => {
  const header = 'ACTIVITY MANAGER RUNNING PROCESSES (dumpsys activity processes)\n'
  assert.equal(scheduleWakeInstrumentationIdle(header + '  All known processes:\n'), true)
  assert.equal(scheduleWakeInstrumentationIdle(header + '  Active instrumentation:\n'), false)
  for (const invalid of ['', 'Unknown command: instrumentation', 'Permission Denial'])
    assert.throws(() => scheduleWakeInstrumentationIdle(invalid), /UNKNOWN/)
})

function fixture(change = {}) {
  let time = 0, prepared = false
  const calls = []
  const io = {
    now: () => time, delay: async ms => { time += ms }, childrenClosed: () => true,
    instrumentationIdle: async () => true,
    processes: async () => [{ name: 'com.minnnng.dsh_android', pid: mainPid },
      ...(!prepared ? [{ name: 'com.minnnng.dsh_android:agent', pid: oldPid }]
        : time >= 60_000 ? [{ name: 'com.minnnng.dsh_android:agent', pid: newPid }] : [])],
    services: async () => dump(newPid),
    phase: async options => { calls.push({ phase: options.phase, time }); if (options.phase === 'prepare') prepared = true
      return output(value(options.phase)) },
    ...change,
  }
  return { io, calls }
}
test('natural waiting uses only passive inspection until the new alarm-bound Agent exists', async () => {
  const { io, calls } = fixture()
  const result = await runNaturalWakeAcceptance(io, { caseId, signal: new AbortController().signal, acceptRealAccountRequest: true })
  assert.equal(result.passed, true)
  assert.deepEqual(calls.map(item => item.phase), ['status', 'prepare', 'observe', 'cleanup'])
  assert.equal(calls[2].time, 60_000)
  assert.equal(result.retirement.mainPreserved, true)
  assert.equal(result.retirement.wholeAppRetired, false)
  assert.equal(result.samples.filter(item => item.agentPid === null).length, 60)
})
test('an early Agent or missing wake intent fails and still attempts only owned cleanup', async () => {
  for (const changed of [
    { processes: async () => [{ name: 'com.minnnng.dsh_android', pid: mainPid }, { name: 'com.minnnng.dsh_android:agent', pid: newPid }] },
    { services: async () => dump(newPid).replace('SCHEDULE_WAKE', 'OTHER') },
  ]) {
    const { io, calls } = fixture(changed)
    await assert.rejects(runNaturalWakeAcceptance(io, { caseId, signal: new AbortController().signal, acceptRealAccountRequest: true }))
    assert.equal(calls.at(-1).phase, 'cleanup')
    assert.equal(calls.some(item => item.phase === 'observe'), false)
  }
})
test('unconfirmed cleanup keeps retirement false so the outer guard cannot reset display overrides', async () => {
  const { io } = fixture({ childrenClosed: () => false })
  await assert.rejects(runNaturalWakeAcceptance(io, { caseId, signal: new AbortController().signal, acceptRealAccountRequest: true }),
    error => error.retirement.confirmed === false)
})
test('cancelled work uses a fresh cleanup signal and never restarts the absent service', async () => {
  const controller = new AbortController(), { io, calls } = fixture()
  io.delay = async () => { controller.abort(new Error('cancelled')); controller.signal.throwIfAborted() }
  const originalPhase = io.phase
  io.phase = async (options, signal) => {
    if (options.phase === 'cleanup') assert.equal(signal.aborted, false)
    return originalPhase(options, signal)
  }
  await assert.rejects(runNaturalWakeAcceptance(io, { caseId, signal: controller.signal, acceptRealAccountRequest: true }))
  assert.equal(calls.at(-1).phase, 'cleanup')
})
test('native fixture has no auto-create, service-start or wake-lock call and main target is explicit', async () => {
  const native = await readFile(new URL('../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/ScheduleWakeupAcceptanceInstrumentation.kt', import.meta.url), 'utf8')
  assert.doesNotMatch(native, /BIND_AUTO_CREATE|startForegroundService\(|startService\(|newWakeLock\(|startActivity\(/u)
  const manifest = await readFile(new URL('../android/app/src/androidTest/AndroidManifest.xml', import.meta.url), 'utf8')
  assert.match(manifest, /ScheduleWakeupAcceptanceInstrumentation"\s+android:targetPackage="com\.minnnng\.dsh_android"\s+android:targetProcesses="com\.minnnng\.dsh_android"/u)
})
