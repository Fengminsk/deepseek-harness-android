import assert from 'node:assert/strict'
import test from 'node:test'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { scheduleWakeInstrumentationArguments, parseScheduleWakePhase, naturalWakeServiceEvidence,
  runNaturalWakeAcceptance, scheduleWakeInstrumentationIdle, runScheduleWakePhaseAcceptance,
  scheduleWakeFailureDiagnostics, scheduleWakeFailureReport, parseScheduleWakeProgress,
  parseScheduleWakeArguments, runProtectedScheduleWakeAcceptance } from './acceptance-schedule-wakeup-device.mjs'
import { withScreenProtection } from './device-screen-protection.mjs'

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
const progress = (phase, stage, elapsedMs, extra = {}) => `INSTRUMENTATION_STATUS: scheduleWakeProgress=${JSON.stringify({
  schema: 1, phase, caseId, stage, elapsedMs, ...extra })}\n`
const dump = pid => `ACTIVITY MANAGER SERVICES\n  * ServiceRecord{abc u0 com.minnnng.dsh_android/.AgentService}\n    intent={act=com.minnnng.dsh_android.SCHEDULE_WAKE cmp=com.minnnng.dsh_android/.AgentService}\n    app=ProcessRecord{123 ${pid}:com.minnnng.dsh_android:agent/u0a496}\n`

test('CLI requires an explicit true value to retain display power overrides', () => {
  const args = ['--adb', 'adb.exe', '--serial', 'DEVICE', '--report', 'report.json', '--case-id', caseId]
  assert.equal(parseScheduleWakeArguments(args).keepDisplayOff, false)
  assert.equal(parseScheduleWakeArguments([...args, '--keep-display-off', 'true']).keepDisplayOff, true)
  for (const invalid of ['false', '1', 'TRUE', '--mode'])
    assert.throws(() => parseScheduleWakeArguments([...args, '--keep-display-off', invalid]), /INVALID_KEEP_DISPLAY_OFF/)
  assert.throws(() => parseScheduleWakeArguments([...args, '--keep-display-off']), /INVALID_ARGUMENTS/)
  assert.throws(() => parseScheduleWakeArguments([...args, '--keep-display-off', 'true', '--keep-display-off', 'true']), /INVALID_ARGUMENTS/)
})

test('protected status resets by default and keeps panel overrides only when requested', async () => {
  for (const keepDisplayOff of [undefined, true]) {
    const { io } = fixture()
    let resets = 0
    Object.assign(io, { inspect: async () => [{ id: '0', physicalId: '1', powerMode: 'Off' }],
      powerOff: async () => {}, powerReset: async () => { resets++ },
      sleep: async () => {}, nonInteractive: async () => true,
      delay: () => new Promise(resolve => setImmediate(resolve)) })
    const result = await runProtectedScheduleWakeAcceptance(io,
      { mode: 'status', caseId, keepDisplayOff, signal: new AbortController().signal })
    assert.equal(result.result.passed, true)
    assert.equal(result.result.retirement.mainPreserved, true)
    assert.equal(result.result.retirement.wholeAppRetired, false)
    assert.equal(resets, keepDisplayOff ? 0 : 1)
    assert.equal(result.protection.restoredWhileNonInteractive, !keepDisplayOff)
    if (keepDisplayOff) {
      assert.equal(result.protection.retainedWhileNonInteractive, true)
      assert.equal(result.protection.finalDisplayState, 'off')
    }
  }
})

test('retaining display overrides does not hide native status failure after scoped retirement', async () => {
  const { io } = fixture({ phase: async () => output({ ...value('status'), passed: false, failureCode: 'DEVICE_NOT_LOCKED' }) })
  Object.assign(io, { inspect: async () => [{ id: '0', physicalId: '1', powerMode: 'Off' }],
    powerOff: async () => {}, powerReset: async () => { assert.fail('Panel override must remain applied') },
    sleep: async () => {}, nonInteractive: async () => true,
    delay: () => new Promise(resolve => setImmediate(resolve)) })
  await assert.rejects(runProtectedScheduleWakeAcceptance(io,
    { mode: 'status', caseId, keepDisplayOff: true, signal: new AbortController().signal }), error => {
    assert.equal(error.result.passed, false)
    assert.equal(error.result.nativeFailureCode, 'DEVICE_NOT_LOCKED')
    assert.equal(error.retirement.confirmed, true)
    assert.equal(error.retirement.mainPreserved, true)
    assert.equal(error.protection.retainedWhileNonInteractive, true)
    assert.equal(error.protection.restoredWhileNonInteractive, false)
    return true
  })
})

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

test('status success retires only its instrumentation and clients, never claims natural delivery', async () => {
  const { io, calls } = fixture()
  const result = await runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal })
  assert.equal(result.passed, true)
  assert.equal(result.naturalWakeAccepted, false)
  assert.deepEqual(result.retirement, { confirmed: true, fixtureInstrumentationRetired: true,
    hostClientsClosed: true, mainPreserved: true, wholeAppRetired: false })
  assert.deepEqual(calls.map(item => item.phase), ['status'])
})

test('a failed native status keeps its failure after independent fixture retirement', async () => {
  const { io } = fixture({ phase: async () => output({ ...value('status'), passed: false, failureCode: 'DEVICE_NOT_LOCKED' }) })
  await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal }), error => {
    assert.equal(error.result.passed, false)
    assert.equal(error.result.naturalWakeAccepted, false)
    assert.equal(error.result.failureCode, 'NATIVE_PHASE_FAILED')
    assert.equal(error.result.nativeFailureCode, 'DEVICE_NOT_LOCKED')
    assert.equal(error.retirement.confirmed, true)
    assert.equal(error.retirement.wholeAppRetired, false)
    return true
  })
})

test('unlocked state cannot become a successful status after fixture retirement', async () => {
  const status = value('status'); status.deviceStateBefore.locked = false
  const { io } = fixture({ phase: async () => output(status) })
  await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal }),
    error => error.result.failureCode === 'DEVICE_NOT_LOCKED' && error.result.passed === false && error.retirement.confirmed === true)
})

test('cancelled status verifies retirement with an independent signal without another native phase', async () => {
  const controller = new AbortController(), { io } = fixture()
  let dispatched = false, cleanInspections = 0
  io.phase = async () => {
    dispatched = true
    controller.abort(Object.assign(new Error('private cancellation text'), { code: 'HOST_INTERRUPTED' }))
    throw controller.signal.reason
  }
  io.instrumentationIdle = async signal => {
    if (dispatched) { assert.notEqual(signal, controller.signal); assert.equal(signal.aborted, false); cleanInspections++ }
    return true
  }
  await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: controller.signal }),
    error => error.result.failureCode === 'HOST_INTERRUPTED' && error.retirement.confirmed === true)
  assert.equal(cleanInspections, 1)
})

test('active instrumentation, open host clients and a replaced main cannot establish retirement', async () => {
  for (const condition of ['instrumentation', 'client', 'main', 'unknown']) {
    let dispatched = false
    const { io } = fixture({ phase: async () => {
      dispatched = true
      return output({ ...value('status'), passed: false, failureCode: 'DEVICE_NOT_LOCKED' })
    } })
    io.instrumentationIdle = async () => {
      if (dispatched && condition === 'unknown') throw Object.assign(new Error('private dump'), { code: 'INSTRUMENTATION_STATE_UNKNOWN' })
      return !dispatched || condition !== 'instrumentation'
    }
    io.childrenClosed = () => condition !== 'client'
    io.processes = async () => [{ name: 'com.minnnng.dsh_android', pid: dispatched && condition === 'main' ? 999 : mainPid }]
    await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal }), error => {
      assert.equal(error.result.failureCode, 'NATIVE_PHASE_FAILED')
      assert.equal(error.result.nativeFailureCode, 'DEVICE_NOT_LOCKED')
      assert.equal(error.retirement.confirmed, false)
      assert.equal(error.retirement.wholeAppRetired, false)
      assert.match(error.result.cleanupFailureCode, /UNCONFIRMED|PREEXISTING_MAIN_REQUIRED|INSTRUMENTATION_STATE_UNKNOWN/u)
      return true
    })
  }
})

test('failed explicit task cleanup cannot claim retirement from instrumentation absence alone', async () => {
  const { io } = fixture({ phase: async () => output({ ...value('cleanup'), passed: false, failureCode: 'OWN_TASK_NOT_SETTLED' }) })
  await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'cleanup', caseId, signal: new AbortController().signal }), error => {
    assert.equal(error.result.nativeFailureCode, 'OWN_TASK_NOT_SETTLED')
    assert.equal(error.retirement.fixtureInstrumentationRetired, true)
    assert.equal(error.retirement.hostClientsClosed, true)
    assert.equal(error.retirement.mainPreserved, true)
    assert.equal(error.retirement.ownedTaskSettled, false)
    assert.equal(error.retirement.confirmed, false)
    return true
  })
})

test('actual screen-cleanup aggregation retains native status failure and scoped retirement', async () => {
  const { io } = fixture({ phase: async () => progress('status', 'existing-service-bind', 12, { privateText: 'not copied' }) +
    output({ ...value('status'), passed: false, failureCode: 'DEVICE_NOT_LOCKED' }) })
  Object.assign(io, { inspect: async () => [{ id: '0', physicalId: '1', powerMode: 'Off' }],
    powerOff: async () => {}, powerReset: async () => { throw new Error('private screen cleanup output') },
    sleep: async () => {}, nonInteractive: async () => true,
    delay: () => new Promise(resolve => setImmediate(resolve)) })
  await assert.rejects(withScreenProtection(io,
    signal => runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal }),
    { timeoutMs: 1000, pollMs: 10, signal: new AbortController().signal }), error => {
    assert.ok(error instanceof AggregateError)
    const diagnostic = scheduleWakeFailureDiagnostics(error)
    assert.equal(diagnostic.failureCode, 'NATIVE_PHASE_FAILED')
    assert.equal(diagnostic.nativeFailureCode, 'DEVICE_NOT_LOCKED')
    assert.equal(diagnostic.hostStage, 'instrument')
    assert.deepEqual(diagnostic.lastProgress, { phase: 'status', stage: 'existing-service-bind', elapsedMs: 12 })
    assert.equal(error.retirement.confirmed, true)
    assert.equal(error.retirement.wholeAppRetired, false)
    assert.equal(error.protection.restoredWhileNonInteractive, false)
    assert.doesNotMatch(JSON.stringify(diagnostic), /private|stack|message/u)
    const report = scheduleWakeFailureReport(error)
    assert.equal(report.result.passed, false)
    assert.equal(report.result.nativeFailureCode, 'DEVICE_NOT_LOCKED')
    assert.equal(report.result.hostStage, 'instrument')
    assert.equal(report.result.retirement.confirmed, true)
    assert.equal(report.protection.restoredWhileNonInteractive, false)
    return true
  })
})

test('the same ADB deadline identifies main query, idle preflight or native instrumentation separately', async () => {
  for (const stage of ['main-query', 'idle-preflight', 'instrument']) {
    const { io, calls } = fixture()
    let queried = false, inspected = false
    const deadline = () => Object.assign(new Error('private adb output'), { code: 'HOST_CLIENT_DEADLINE' })
    const processes = io.processes, idle = io.instrumentationIdle
    io.processes = async signal => {
      if (!queried) { queried = true; if (stage === 'main-query') throw deadline() }
      return processes(signal)
    }
    io.instrumentationIdle = async signal => {
      if (!inspected) { inspected = true; if (stage === 'idle-preflight') throw deadline() }
      return idle(signal)
    }
    io.phase = async options => { calls.push({ phase: options.phase }); throw deadline() }
    await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal }), error => {
      const report = scheduleWakeFailureReport(new AggregateError([error, new Error('private screen output')], 'private aggregate'))
      assert.equal(report.failureCode, 'HOST_CLIENT_DEADLINE')
      assert.equal(report.hostStage, stage)
      assert.equal(report.result.hostStage, stage)
      assert.equal(report.result.passed, false)
      assert.equal(report.result.naturalWakeAccepted, false)
      assert.equal(report.retirement.wholeAppRetired, false)
      assert.equal(calls.length, stage === 'instrument' ? 1 : 0)
      assert.doesNotMatch(JSON.stringify(report), /private/u)
      return true
    })
  }
})

test('screen aggregate retains the primary native failure and independent cleanup code and stage', async () => {
  let dispatched = false
  const { io } = fixture({ phase: async () => {
    dispatched = true
    return output({ ...value('status'), passed: false, failureCode: 'DEVICE_NOT_LOCKED' })
  }, instrumentationIdle: async () => {
    if (dispatched) throw Object.assign(new Error('private cleanup dump'), { code: 'COMMAND_DEADLINE' })
    return true
  } })
  Object.assign(io, { inspect: async () => [{ id: '0', physicalId: '1', powerMode: 'Off' }],
    powerOff: async () => {}, powerReset: async () => { assert.fail('Unknown retirement must prevent power reset') },
    sleep: async () => {}, nonInteractive: async () => true,
    delay: () => new Promise(resolve => setImmediate(resolve)) })
  await assert.rejects(withScreenProtection(io,
    signal => runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal }),
    { timeoutMs: 1000, pollMs: 10, signal: new AbortController().signal }), error => {
    assert.ok(error instanceof AggregateError)
    const report = scheduleWakeFailureReport(error)
    assert.equal(report.failureCode, 'NATIVE_PHASE_FAILED')
    assert.equal(report.nativeFailureCode, 'DEVICE_NOT_LOCKED')
    assert.equal(report.hostStage, 'instrument')
    assert.equal(report.cleanupFailureCode, 'COMMAND_DEADLINE')
    assert.equal(report.cleanupHostStage, 'idle-cleanup')
    assert.equal(report.result.cleanupFailureCode, report.cleanupFailureCode)
    assert.equal(report.result.cleanupHostStage, report.cleanupHostStage)
    assert.equal(report.retirement.confirmed, false)
    assert.equal(report.result.retirement.confirmed, false)
    assert.doesNotMatch(JSON.stringify(report), /private/u)
    return true
  })
})

test('foreign exception result objects and non-enumerated host stages are not serialized', () => {
  const foreign = Object.assign(new Error('private message'), { result: { account: 'private account',
    cleanupFailureCode: 'PRIVATE_ACCOUNT', hostStage: 'private host stage' }, hostStage: 'unbounded text' })
  const report = scheduleWakeFailureReport(new AggregateError([foreign], 'private aggregate'))
  assert.equal(report.result, undefined)
  assert.equal(report.hostStage, undefined)
  assert.equal(report.cleanupFailureCode, undefined)
  assert.doesNotMatch(JSON.stringify(report), /private|PRIVATE/u)
})

test('progress selects only matching bounded case and phase records with fixed stage names', () => {
  const options = { phase: 'prepare', caseId }
  const text = progress('prepare', 'existing-service-bind', 5) +
    progress('prepare', 'schedule-create-request', 10, { privateText: 'not copied' }) +
    progress('prepare', 'waiting-without-carrier', 15, { caseId: 'aaaaaaaa-1234-4567-8abc-123456789012' }) +
    progress('observe', 'natural-delivery-wait', 20) +
    progress('prepare', 'not-a-fixed-stage', 25) +
    progress('prepare', 'waiting-without-carrier', 700_000) +
    progress('prepare', 'existing-service-bind', -1) +
    progress('prepare', 'existing-service-bind', 3) +
    'INSTRUMENTATION_STATUS: scheduleWakeProgress={invalid private data}\n'
  assert.deepEqual(parseScheduleWakeProgress(text, options), { phase: 'prepare', stage: 'schedule-create-request', elapsedMs: 10 })
  assert.equal(parseScheduleWakeProgress('private output', options), undefined)
  assert.equal(parseScheduleWakeProgress(progress('prepare', 'schedule-create-request', 10, { schema: 2 }), options), undefined)
  assert.equal(parseScheduleWakeProgress(progress('prepare', 'schedule-create-request', 10, { privateText: 'x'.repeat(2048) }), options), undefined)
  assert.equal(parseScheduleWakeProgress('x'.repeat(2 * 1024 * 1024 + 1), options), undefined)
})

test('valid progress without a final receipt remains failed and exposes no raw output', async () => {
  const { io } = fixture({ phase: async () => 'private startup text\n' + progress('status', 'existing-service-bind', 450) })
  await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal }), error => {
    assert.equal(error.result.failureCode, 'PHASE_NOT_FINISHED')
    assert.equal(error.result.passed, false)
    assert.equal(error.retirement.confirmed, true)
    assert.deepEqual(error.result.lastProgress, { phase: 'status', stage: 'existing-service-bind', elapsedMs: 450 })
    assert.doesNotMatch(JSON.stringify(error.result), /private startup text/u)
    return true
  })
})

test('phase deadline preserves only sanitized captured progress through nested failure', async () => {
  const { io } = fixture({ phase: async () => { throw Object.assign(new Error('private captured output'), {
    code: 'COMMAND_DEADLINE', lastProgress: { phase: 'status', stage: 'existing-service-bind', elapsedMs: 59_999, output: 'secret' } }) } })
  await assert.rejects(runScheduleWakePhaseAcceptance(io, { phase: 'status', caseId, signal: new AbortController().signal }), error => {
    const diagnostic = scheduleWakeFailureDiagnostics(new AggregateError([error], 'private aggregate'))
    assert.equal(diagnostic.failureCode, 'COMMAND_DEADLINE')
    assert.deepEqual(diagnostic.lastProgress, { phase: 'status', stage: 'existing-service-bind', elapsedMs: 59_999 })
    assert.doesNotMatch(JSON.stringify(diagnostic), /private|secret|output/u)
    return true
  })
})

test('diagnostics reject prose and bound aggregate width, depth and cycles', () => {
  const secret = new Error('private account or session text')
  Object.assign(secret, { code: 'private invalid code', nativeFailureCode: 'sensitive/url?token=secret', result: { prompt: 'secret' } })
  secret.cause = secret
  const diagnostic = scheduleWakeFailureDiagnostics(secret)
  assert.equal(diagnostic.failureCode, 'ACCEPTANCE_FAILED')
  assert.equal(diagnostic.nativeFailureCode, undefined)
  assert.deepEqual(diagnostic.failures, [])
  assert.doesNotMatch(JSON.stringify(diagnostic), /private|sensitive|secret/u)
  const many = Array.from({ length: 100 }, () => Object.assign(new Error('not copied'), { code: 'COMMAND_FAILED' }))
  const wide = scheduleWakeFailureDiagnostics(new AggregateError(many, 'not copied'))
  assert.ok(wide.failures.length <= 16)
  assert.equal(wide.diagnosticsTruncated, true)
  let deep = Object.assign(new Error('not copied'), { code: 'NATIVE_PHASE_FAILED', nativeFailureCode: 'DEVICE_NOT_LOCKED' })
  for (let index = 0; index < 10; index++) deep = new Error('not copied', { cause: deep })
  const limited = scheduleWakeFailureDiagnostics(deep)
  assert.equal(limited.failureCode, 'ACCEPTANCE_FAILED')
  assert.equal(limited.nativeFailureCode, undefined)
  assert.equal(limited.diagnosticsTruncated, true)
})
test('native fixture has no auto-create, service-start or wake-lock call and main target is explicit', async () => {
  const native = await readFile(new URL('../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/ScheduleWakeupAcceptanceInstrumentation.kt', import.meta.url), 'utf8')
  assert.doesNotMatch(native, /BIND_AUTO_CREATE|startForegroundService\(|startService\(|newWakeLock\(|startActivity\(/u)
  const manifest = await readFile(new URL('../android/app/src/androidTest/AndroidManifest.xml', import.meta.url), 'utf8')
  assert.match(manifest, /ScheduleWakeupAcceptanceInstrumentation"\s+android:targetPackage="com\.minnnng\.dsh_android"\s+android:targetProcesses="com\.minnnng\.dsh_android"/u)
})
