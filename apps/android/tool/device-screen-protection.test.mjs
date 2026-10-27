import test from 'node:test'
import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import { bindAcceptanceArguments, parseAcceptanceProcesses, parseNonInteractivePowerState,
  parseInternalDisplays, resolveScreenProtectionTiming, runAcceptanceChild,
  runScreenOnlyProbe, runProtectedAcceptance, withScreenProtection } from './device-screen-protection.mjs'

const ids = '0\n2\n'
const mapping = 'LogicalDisplayMapper:\n  Display 0:\n    mPrimaryDisplayDevice=outer(local:4630946165954792596)\n  Display 2:\n    mPrimaryDisplayDevice=inner(local:4630946317637160339)\nOther:\n'
const surface = 'Displays (2 entries)\nDisplay 4630946165954792596\n    connectionType=Internal\n    powerMode=Off\nDisplay 4630946317637160339\n    connectionType=Internal\n    powerMode=Off\nOther:\n'
const panels = parseInternalDisplays(ids, mapping, surface)

test('workflow lifecycle driver binds the protected ADB executable and serial', () => {
  const entry = 'apps/android/tool/acceptance-workflow-lifecycle-device.mjs'
  const target = { adb: resolve('adb.exe'), serial: 'locked-phone' }
  assert.deepEqual(bindAcceptanceArguments([entry, '--foreground-carrier', 'service'], target),
    [resolve(entry), '--foreground-carrier', 'service', '--adb', target.adb, '--serial', target.serial])
  assert.throws(() => bindAcceptanceArguments([entry, '--serial', 'other-phone'], target))
})

test('foldable inventory keeps exact physical IDs and includes the disabled inner panel', () => {
  assert.deepEqual(panels, [
    { id: '0', physicalId: '4630946165954792596', powerMode: 'Off' },
    { id: '2', physicalId: '4630946317637160339', powerMode: 'Off' },
  ])
})

test('missing, duplicate, external or unmapped panels cannot establish protection', () => {
  for (const [i, d, s] of [
    ['', mapping, surface], ['0\n0', mapping, surface], ['0', mapping, surface],
    [ids, mapping.replace('local:4630946317637160339', 'unknown'), surface],
    [ids, mapping, surface.replace('connectionType=Internal', 'connectionType=External')],
    [ids, mapping, surface.replace('    powerMode=Off', '')],
    [ids, mapping, surface.replace('    powerMode=Off', '    powerMode=Off\n    powerMode=On')],
  ]) assert.throws(() => parseInternalDisplays(i, d, s))
})

function fixture() {
  const events = []
  let lit = false
  return {
    events,
    illuminate: () => { lit = true },
    inspect: async () => { events.push('inspect'); return panels.map(p => ({ ...p, powerMode: lit ? 'On' : 'Off' })) },
    powerOff: async id => { events.push(`off:${id}`); lit = false },
    powerReset: async id => { events.push(`reset:${id}`) },
    sleep: async () => { events.push('sleep'); lit = false },
    nonInteractive: async () => { events.push('asleep'); return true },
    delay: ms => new Promise(resolve => setTimeout(resolve, ms)),
  }
}

test('both panels are off before work and controls restore only after sleep', async () => {
  const io = fixture()
  const evidence = await withScreenProtection(io, async () => {
    io.events.push('run')
    return 7
  }, { timeoutMs: 1000, pollMs: 10 })
  assert.equal(evidence.result, 7)
  assert.equal(evidence.protection.samples.length, 2)
  assert.deepEqual(io.events, ['inspect', 'off:0', 'off:2', 'inspect', 'run', 'inspect', 'sleep', 'asleep',
    'asleep', 'reset:0', 'asleep', 'reset:2', 'inspect', 'asleep'])
})

test('a lit panel cancels actual work and waits for retirement before resetting power', async () => {
  const io = fixture()
  await assert.rejects(withScreenProtection(io, signal => new Promise(resolve => {
    io.illuminate()
    signal.addEventListener('abort', () => setTimeout(() => {
      assert.equal(io.events.filter(event => event === 'off:0').length, 2,
        'Reapply panel protection before waiting for the child to retire')
      io.events.push('retired')
      resolve()
    }, 15), { once: true })
  }), { timeoutMs: 1000, pollMs: 10 }), /panel is not Off/)
  assert.ok(io.events.indexOf('retired') < io.events.indexOf('sleep'))
})

test('failed sleep leaves the power-off overrides in place', async () => {
  const io = fixture()
  io.nonInteractive = async () => false
  await assert.rejects(withScreenProtection(io, async () => 0,
    { timeoutMs: 1000, pollMs: 10 }), error => error.errors.some(cause => /did not sleep/.test(cause.message)))
  assert.ok(!io.events.some(e => e.startsWith('reset:')))
})

test('cleanup inspection failure still re-applies every previously known panel override', async () => {
  const io = fixture(), inspect = io.inspect
  let calls = 0
  io.inspect = async () => {
    if (++calls === 4) throw new Error('SurfaceFlinger unreadable after reset')
    return inspect()
  }
  io.powerReset = async id => { io.events.push(`reset:${id}`); io.illuminate() }
  await assert.rejects(withScreenProtection(io, async () => 0, { timeoutMs: 1000, pollMs: 10 }), error => {
    assert.equal(error.protection.restoredWhileNonInteractive, false)
    assert.equal(error.protection.finalDisplayState, 'unknown')
    return true
  })
  assert.deepEqual(io.events.slice(-2), ['off:0', 'off:2'])
  assert.ok((await inspect()).every(panel => panel.powerMode === 'Off'))
})

test('partial reset failure and USB loss cannot claim restored display state', async () => {
  const io = fixture()
  io.powerReset = async id => { io.events.push(`reset:${id}`); if (id === '2') throw new Error('USB lost') }
  let attempts = 0
  io.powerOff = async id => {
    attempts++
    io.events.push(`off:${id}`)
    if (attempts > 2) throw new Error('USB unavailable')
  }
  await assert.rejects(withScreenProtection(io, async () => 0, { timeoutMs: 1000, pollMs: 10 }), error => {
    assert.equal(error.protection.finalDisplayState, 'unknown')
    assert.equal(error.protection.restoredWhileNonInteractive, false)
    return true
  })
  assert.equal(attempts, 4)
})

test('changed topology blackens both the old and newly observed panel IDs', async () => {
  const io = fixture(), inspect = io.inspect
  let calls = 0
  io.inspect = async () => ++calls === 3
    ? [{ id: '3', physicalId: '4630946317637160339', powerMode: 'On' }] : inspect()
  await assert.rejects(withScreenProtection(io, async () => 0, { timeoutMs: 1000, pollMs: 10 }), /panel is not Off/)
  assert.ok(io.events.includes('off:3'))
  assert.ok(io.events.indexOf('off:3') < io.events.indexOf('sleep'))
})

test('deadline cancels work and waits for its acknowledgement before display reset', async () => {
  const io = fixture()
  await assert.rejects(withScreenProtection(io, signal => new Promise(resolve => {
    signal.addEventListener('abort', () => { io.events.push('deadline-retired'); resolve() }, { once: true })
  }), { timeoutMs: 1000, pollMs: 10 }), /deadline exceeded/)
  assert.ok(io.events.indexOf('deadline-retired') < io.events.indexOf('reset:0'))
  assert.equal(io.events.filter(event => event === 'off:0').length, 2)
})

test('handled host interruption re-applies off and waits for work before cleanup', async () => {
  const io = fixture(), controller = new AbortController()
  await assert.rejects(withScreenProtection(io, signal => new Promise(resolve => {
    signal.addEventListener('abort', () => { io.events.push('interrupt-retired'); resolve() }, { once: true })
    controller.abort(new Error('SIGTERM'))
  }), { timeoutMs: 1000, pollMs: 10, signal: controller.signal }), /SIGTERM/)
  assert.ok(io.events.indexOf('interrupt-retired') < io.events.indexOf('reset:0'))
  assert.equal(io.events.filter(event => event === 'off:0').length, 2)
})

test('unconfirmed retirement leaves overrides active even after a separate emergency-off failure', async () => {
  const io = fixture()
  let calls = 0
  io.powerOff = async id => {
    io.events.push(`off:${id}`)
    if (++calls > 2) throw new Error('power-off unavailable')
  }
  const failure = Object.assign(new Error('child kill failed'), {
    retirement: { hostProcessClosed: false, deviceProcessesGone: false, confirmed: false },
  })
  await assert.rejects(withScreenProtection(io, async () => { throw failure },
    { timeoutMs: 1000, pollMs: 10 }), error => {
    assert.equal(error.retirement.confirmed, false)
    assert.equal(error.protection.restoredWhileNonInteractive, false)
    return true
  })
  assert.equal(io.events.some(event => event.startsWith('reset:')), false)
})

test('only Asleep or Dozing power groups qualify as noninteractive', () => {
  for (const text of ['  mWakefulness=Asleep\n', '  mWakefulness=Dozing\n',
    '  mWakefulness=Asleep\n  mWakefulness=Dozing\n']) assert.equal(parseNonInteractivePowerState(text), true)
  for (const text of ['  mWakefulness=Awake\n', '', '  mWakefulness=Unknown\n',
    '  mWakefulness=Asleep\n  mWakefulness=Awake\n']) assert.equal(parseNonInteractivePowerState(text), false)
})

test('vendor numeric mirrors must match the named wakefulness state', () => {
  for (const text of ['  mWakefulness=Dozing\nmWakefulness=3\n',
    '  mWakefulness=Asleep\nmWakefulness=0\n', 'mWakefulness=0\n', 'mWakefulness=3\n']) {
    assert.equal(parseNonInteractivePowerState(text), true)
  }
  for (const text of ['  mWakefulness=Dozing\nmWakefulness=0\n',
    '  mWakefulness=Asleep\nmWakefulness=3\n', '  mWakefulness=Dozing\nmWakefulness=1\n',
    '  mWakefulness=Dozing\nmWakefulness=2\n', '  mWakefulness=Dozing\nmWakefulness=4\n',
    '  mWakefulness=Dozing\nmWakefulness=unknown\n', '  mWakefulness=Dozing\nmWakefulness=\n',
    '  mWakefulness=Dozing\nmWakefulness=3 (stale)\n', 'mWakefulness=0\nmWakefulness=3\n']) {
    assert.equal(parseNonInteractivePowerState(text), false, text)
  }
})

test('screen-only observation receives bounded preparation time while acceptance retains its full deadline', () => {
  assert.deepEqual(resolveScreenProtectionTiming(12, true), { observationMs: 12000, timeoutMs: 72000 })
  assert.deepEqual(resolveScreenProtectionTiming(12, false), { observationMs: null, timeoutMs: 12000 })
  assert.deepEqual(resolveScreenProtectionTiming(3600, true), { observationMs: 3600000, timeoutMs: 3660000 })
  for (const invalid of [0, -1, 0.5, NaN, Infinity, 3601]) {
    for (const screenOnly of [true, false]) assert.throws(() => resolveScreenProtectionTiming(invalid, screenOnly))
  }
})

test('screen-only duration starts after preflight and observes the full requested second', async () => {
  const io = fixture(), inspect = io.inspect, timing = resolveScreenProtectionTiming(1, true)
  let calls = 0
  io.inspect = async () => {
    if (++calls === 1) await io.delay(150)
    return inspect()
  }
  const started = performance.now()
  const report = await withScreenProtection(io, signal => runScreenOnlyProbe(signal, timing.observationMs),
    { timeoutMs: timing.timeoutMs, pollMs: 10 })
  assert.equal(report.result.requestedObservationMs, 1000)
  assert.ok(report.result.observedMs >= 1000)
  assert.ok(performance.now() - started >= 1100)
  assert.equal(report.result.appTestsRun, false)
  assert.equal(report.protection.restoredWhileNonInteractive, true)
})

test('a running observation still stops on cancellation despite its preparation allowance', async () => {
  const controller = new AbortController()
  const run = runScreenOnlyProbe(controller.signal, 1000)
  controller.abort(new Error('observation cancelled'))
  await assert.rejects(run, /observation cancelled/)
})

test('Dozing reset requires retirement and a physical Off result', async () => {
  for (const state of ['retired', 'unretired', 'lit-after-reset']) {
    const io = fixture()
    io.nonInteractive = async () => parseNonInteractivePowerState('  mWakefulness=Dozing\n')
    if (state === 'lit-after-reset') io.powerReset = async id => { io.events.push(`reset:${id}`); io.illuminate() }
    const run = withScreenProtection(io, async () => ({ retirement: { confirmed: state !== 'unretired' } }),
      { timeoutMs: 1000, pollMs: 10 })
    if (state === 'retired') assert.equal((await run).protection.restoredWhileNonInteractive, true)
    else await assert.rejects(run, error => error.protection.finalDisplayState === 'unknown')
    if (state === 'unretired') assert.equal(io.events.some(event => event.startsWith('reset:')), false)
    if (state === 'lit-after-reset') assert.deepEqual(io.events.slice(-2), ['off:0', 'off:2'])
  }
})

test('only reviewed entries accept the exact protected device and ADB path', () => {
  const entry = 'apps/android/tool/acceptance-upgrade-device.mjs'
  const target = { adb: resolve('local-adb.exe'), serial: 'phone-A' }
  assert.deepEqual(bindAcceptanceArguments([entry, '--force-stop'], target),
    [resolve(entry), '--force-stop', '--adb', target.adb, '--serial', 'phone-A'])
  assert.deepEqual(bindAcceptanceArguments([entry, '--adb', target.adb, '--serial', 'phone-A'], target),
    [resolve(entry), '--adb', target.adb, '--serial', 'phone-A'])
  for (const args of [
    [entry, '--serial', 'phone-B'], [entry, '--adb', 'different-adb.exe'],
    [entry, '--serial', 'phone-A', '--serial', 'phone-A'], [entry, '--serial=phone-A'],
    [entry, '--adb'], [entry, '--'],
    ['apps/android/tool/acceptance-unreviewed-device.mjs'],
  ]) assert.throws(() => bindAcceptanceArguments(args, target))
})

test('recovery binds the same device but cannot enter the killable child path', async () => {
  const entry = 'apps/android/tool/acceptance-agent-service-recovery-device.mjs'
  const args = bindAcceptanceArguments([entry, '--accept-network-toggle-and-lock', '--report', 'recovery.json'],
    { adb: resolve('local-adb.exe'), serial: 'phone-A' })
  assert.ok(args.includes('phone-A'))
  await assert.rejects(runAcceptanceChild(args, new AbortController().signal,
    { startChild: () => assert.fail('Recovery must not spawn Node') }), /network owner/)
})

test('screen cancellation awaits in-process recovery restoration before resetting panels', async () => {
  const io = fixture(), controller = new AbortController(), cleanup = Promise.withResolvers(), started = Promise.withResolvers()
  io.startChild = () => assert.fail('Recovery must not spawn Node')
  const entry = [resolve('apps/android/tool/acceptance-agent-service-recovery-device.mjs'), '--serial', 'phone']
  const run = withScreenProtection(io, signal => runProtectedAcceptance(entry, signal, io, async () => ({
    runRecoveryEntry: async (args, options) => {
      assert.deepEqual(args, ['--serial', 'phone']); assert.equal(options.signal, signal)
      started.resolve()
      await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }))
      await cleanup.promise
      io.events.push('network-restored-and-retired')
      const error = Object.assign(new Error('cancelled'), { retirement: { confirmed: true }, recovery: { result: 'unknown', networkRestored: true } })
      throw error
    },
  })), { timeoutMs: 1000, pollMs: 10, signal: controller.signal })
  await started.promise
  controller.abort(new Error('guard interrupted'))
  await new Promise(resolve => setImmediate(resolve))
  assert.ok(!io.events.some(event => event.startsWith('reset:')))
  cleanup.resolve()
  await assert.rejects(run, error => error.recovery.networkRestored && error.retirement.confirmed)
  assert.ok(io.events.indexOf('network-restored-and-retired') < io.events.indexOf('reset:0'))
})

test('full process inventory retains App, test and isolated services and rejects truncated input', () => {
  const names = ['com.minnnng.dsh_android', 'com.minnnng.dsh_android:agent',
    'com.minnnng.dsh_android.test', 'com.minnnng.dsh_android.test:worker',
    'com.minnnng.dsh_android:linux_vm:com.minnnng.dsh_android.IsolatedLinuxVmService:run_abcdef']
  const output = 'PID ARGS\n' + names.map((name, i) => `${i + 100} ${name}`).join('\n')
    + '\n200 com.minnnng.dsh_android_other\n201 adbd\n'
  assert.deepEqual(parseAcceptanceProcesses(output).map(value => value.name), names)
  assert.deepEqual(parseAcceptanceProcesses('PID ARGS\n'), [])
  for (const text of ['', 'PID NAME\n100 com.minnnng.dsh', 'PID ARGS\n100 com.minnnng.dsh',
    'PID ARGS\nbad', 'PID ARGS\n100 adbd\n100 adbd']) assert.throws(() => parseAcceptanceProcesses(text))
})

function processFixture({ kill = 'close', surviving = false, unreadable = false } = {}) {
  const completion = Promise.withResolvers(), events = []
  return { events, completion,
    startChild: args => {
      events.push(['start', args])
      return { closed: completion.promise, pid: 12345, unref: () => events.push(['unref']), stop: async () => {
        events.push(['kill'])
        if (kill === 'fail') throw new Error('taskkill denied')
        if (kill === 'close') completion.resolve(-1)
      } }
    },
    stopAcceptance: async () => { events.push(['force-stop']) },
    acceptanceProcesses: async () => {
      events.push(['ps'])
      if (unreadable) throw new Error('USB lost before retirement check')
      return surviving ? [{ pid: 12, name: 'com.minnnng.dsh_android:agent' }] : []
    },
    delay: ms => new Promise(resolve => setTimeout(resolve, ms)),
  }
}

test('successful child exit still force-stops and verifies all acceptance processes are absent', async () => {
  const io = processFixture()
  const run = runAcceptanceChild(['entry'], new AbortController().signal, io, { cleanupMs: 100 })
  io.completion.resolve(0)
  assert.deepEqual(await run, { exitCode: 0, retirement: {
    hostPid: 12345, hostProcessClosed: true, hostStopAcknowledged: null, hostHandleReleased: false,
    deviceProcessesGone: true, confirmed: true,
  } })
  assert.deepEqual(io.events.map(value => value[0]), ['start', 'force-stop', 'ps'])
})

test('cancellation waits for actual host close before accepting device retirement', async () => {
  const io = processFixture({ kill: 'wait' }), controller = new AbortController()
  const run = runAcceptanceChild(['entry'], controller.signal, io, { cleanupMs: 100 })
  controller.abort(new Error('cancelled'))
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(io.events.map(value => value[0]), ['start', 'kill'])
  io.completion.resolve(-1)
  await assert.rejects(run, error => error.retirement.confirmed === true)
  assert.deepEqual(io.events.map(value => value[0]), ['start', 'kill', 'force-stop', 'ps'])
})

test('kill failure and a child that never closes return bounded unknown retirement', async () => {
  const io = processFixture({ kill: 'fail' }), controller = new AbortController()
  const run = runAcceptanceChild(['entry'], controller.signal, io, { cleanupMs: 20 })
  controller.abort(new Error('cancelled'))
  await assert.rejects(run, error => {
    assert.deepEqual(error.retirement, { hostPid: 12345, hostProcessClosed: false, hostStopAcknowledged: false,
      hostHandleReleased: true, deviceProcessesGone: false, confirmed: false })
    assert.match(error.message, /host PID 12345; retirement unconfirmed/)
    return true
  })
  assert.deepEqual(io.events.map(value => value[0]), ['start', 'kill', 'force-stop', 'unref'])
})

test('failed process-tree kill stays unconfirmed even if the parent closes later', async () => {
  const io = processFixture({ kill: 'fail' }), controller = new AbortController()
  const run = runAcceptanceChild(['entry'], controller.signal, io, { cleanupMs: 100 })
  controller.abort(new Error('cancelled'))
  setImmediate(() => io.completion.resolve(-1))
  await assert.rejects(run, error => {
    assert.equal(error.retirement.hostProcessClosed, true)
    assert.equal(error.retirement.hostStopAcknowledged, false)
    assert.equal(error.retirement.deviceProcessesGone, true)
    assert.equal(error.retirement.confirmed, false)
    return true
  })
})

test('force-stop acknowledgement alone cannot prove device processes retired', async () => {
  for (const options of [{ surviving: true }, { unreadable: true }]) {
    const io = processFixture(options)
    const run = runAcceptanceChild(['entry'], new AbortController().signal, io, { cleanupMs: 20 })
    io.completion.resolve(0)
    await assert.rejects(run, error => {
      assert.equal(error.retirement.hostProcessClosed, true)
      assert.equal(error.retirement.deviceProcessesGone, false)
      assert.equal(error.retirement.confirmed, false)
      return true
    })
  }
})

test('stalled force-stop has its own bounded failure and never claims retirement', async () => {
  const io = processFixture()
  io.stopAcceptance = () => new Promise(() => {})
  const run = runAcceptanceChild(['entry'], new AbortController().signal, io, { cleanupMs: 20 })
  io.completion.resolve(0)
  await assert.rejects(run, error => !error.retirement.confirmed)
})

test('lost USB fails before work; app test failure still performs screen cleanup', async () => {
  const lost = fixture()
  lost.inspect = async () => { throw new Error('USB unavailable') }
  await assert.rejects(withScreenProtection(lost, async () => assert.fail('must not run'),
    { timeoutMs: 1000, pollMs: 10 }), /USB unavailable/)
  const failed = fixture()
  await assert.rejects(withScreenProtection(failed, async () => { throw new Error('test failed') },
    { timeoutMs: 1000, pollMs: 10 }), /test failed/)
  assert.ok(failed.events.includes('reset:2'))
})

test('a pre-aborted run does not touch the phone', async () => {
  const io = fixture()
  const controller = new AbortController()
  controller.abort(new Error('cancelled'))
  await assert.rejects(withScreenProtection(io, async () => assert.fail('must not run'),
    { timeoutMs: 1000, pollMs: 10, signal: controller.signal }), /cancelled/)
  assert.deepEqual(io.events, [])
})
