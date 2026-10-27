import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { spawn } from 'node:child_process'
import { resolve } from 'node:path'
import { describeRecoveryFailure, parseRecoveryKeyguard, parseRecoveryResult, runRecoveryAcceptance, validateRecoveryNetworks } from './agent-service-recovery-driver.mjs'
import { parseRecoveryArguments, startRecoveryAdb } from './acceptance-agent-service-recovery-device.mjs'

const token = 'a'.repeat(32)
const ready = { token, generation: 'generation-1', sessionId: `android-recovery-${token}`, eventsSha256: 'b'.repeat(64), eventCount: 1 }
const policy = 'PhoneWindowManager\n  KeyguardServiceDelegate\n    showing=true\n    inputRestricted=true\n    occluded=false\n    trusted=false\n    dreaming=true\n    systemReady=true\n  OtherDelegate\n    showing=false\n'
const budgets = { ready: 1000, stage: 1000, observation: 1000, restore: 1000, retirement: 20 }

const fact = (handle, options = {}) => ({ handle, capabilitiesKnown: true, internet: true, validated: true,
  vpn: false, notSuspended: true, appDefault: false, transportTypes: [1], ...options })
const vpn = fact('20', { vpn: true, appDefault: true, transportTypes: [4] })
const ims = fact('30', { internet: false, transportTypes: [0] })
function evidence(networks, { validated, internet, vpn = 1, underlying, unvalidated = 0, unknown = 0 }) {
  return { schema: 2, appDefaultNetworkHandle: '20', networks, validatedNetworks: validated,
    validatedInternetNetworks: internet, validatedVpnInternetNetworks: vpn,
    usableUnderlyingInternetNetworks: underlying, unvalidatedUnderlyingInternetNetworks: unvalidated,
    unknownCapabilityNetworks: unknown }
}
const onlineEvidence = () => evidence([fact('10'), vpn, ims], { validated: 3, internet: 2, underlying: 1 })
const offlineEvidence = () => evidence([vpn, ims], { validated: 2, internet: 1, underlying: 0 })

function fixture(options = {}) {
  const events = [], completion = Promise.withResolvers()
  let text = '', remainder = '', clock = 0, pidCalls = 0
  const network = { wifi: '1', data: '0', ...options.network }
  const checkpoint = stage => ({ ...ready, stage, networkEvidence: network.wifi === '1' || network.data === '1'
    ? onlineEvidence() : (options.offlineEvidence ?? offlineEvidence()),
    interactive: false, locked: true, ...(stage === 'offline' ? options.offline : {}) })
  const emit = (category, field, value) => { text += `INSTRUMENTATION_${category}: ${field}=${JSON.stringify(value)}\n` }
  const io = {
    events, network, completion, now: () => clock,
    delay: async ms => { clock += ms; if (remainder) { text += remainder; remainder = '' } },
    command: async (args, signal) => {
      signal.throwIfAborted()
      events.push([...args]); clock++
      if (io.hook) await io.hook(args, signal)
      if (args.join(' ') === 'dumpsys power') return options.power ?? '  mWakefulness=Dozing\nmWakefulness=3\n'
      if (args.join(' ') === 'dumpsys window policy') return options.policy ?? policy
      if (args[0] === 'settings') return network[args[3] === 'wifi_on' ? 'wifi' : 'data']
      if (args[0] === 'svc') { network[args[1]] = args[2] === 'enable' ? '1' : '0'; return '' }
      if (args[0] === 'pidof') return options.changedPid && ++pidCalls > 1 ? '43' : '42'
      if (args[0] === 'ps') return options.liveProcess ? 'PID ARGS\n42 com.minnnng.dsh_android:agent\n' : 'PID ARGS\n'
      if (args[0] === 'am' && args[1] === 'force-stop') return ''
      if (args[0] === 'am' && args[1] === 'broadcast') {
        const stage = args.at(-1)
        if (stage === 'observe') emit('STATUS', 'observation', checkpoint('observe'))
        if (stage === 'offline') {
          if (options.nativeFailure) {
            emit('RESULT', 'lastObservation', checkpoint('offline'))
            emit('RESULT', 'failureCauses', [{ type: 'ExecutionException', message: 'checkpoint failed' },
              { type: 'IllegalStateException', message: 'network changed during checkpoint' }])
            text += 'INSTRUMENTATION_RESULT: failure=ExecutionException: checkpoint failed\nINSTRUMENTATION_RESULT: passed=false\nINSTRUMENTATION_CODE: 0\n'
            completion.resolve({ code: 0, signal: null })
          } else emit('STATUS', 'checkpoint', checkpoint('offline'))
        }
        if (stage === 'restored') {
          emit('RESULT', 'result', checkpoint('restored'))
          text += 'INSTRUMENTATION_RESULT: passed=true\nINSTRUMENTATION_CODE: -1\n'
          if (!options.neverClose) completion.resolve({ code: 0, signal: null })
        }
        return ''
      }
      assert.fail(`Unexpected command: ${args.join(' ')}`)
    },
    instrument: actualToken => {
      assert.equal(actualToken, token); events.push(['instrument'])
      emit('STATUS', 'ready', { ...ready, ...options.ready })
      if (options.partialReady) { remainder = text.slice(-5); text = text.slice(0, -5) }
      return { pid: 1234, closed: completion.promise, output: () => text, transcript: () => text,
        stop: async () => { events.push(['stop-child']); if (!options.neverClose) completion.resolve({ code: -9, signal: 'SIGKILL' }) },
        unref: () => events.push(['unref']) }
    },
  }
  return io
}

const run = (io, options = {}) => runRecoveryAcceptance(io, { token, signal: new AbortController().signal, budgets, ...options })

test('keyguard parsing is scoped and rejects ambiguous or unknown lock state', () => {
  assert.equal(parseRecoveryKeyguard(policy), true)
  for (const value of ['', policy.replace('showing=true', 'showing=false'), policy.replace('systemReady=true', 'systemReady=unknown'),
    policy.replace('    showing=true', '>   showing=true'), policy + policy,
    policy.replace('    inputRestricted=true', 'OtherDelegate\n    inputRestricted=true'),
    policy.replace('    showing=true', '    showing=true\n    showing=false'),
    policy.replace('    showing=true', '    showing=true\n    showing=unknown')]) assert.equal(parseRecoveryKeyguard(value), false)
})

test('entry requires explicit matching target, consent and a report; no wake option exists', () => {
  const args = ['--adb', 'adb.exe', '--serial', 'phone', '--report', 'report.json', '--accept-network-toggle-and-lock', '--no-wake']
  assert.deepEqual(parseRecoveryArguments(args), { adb: resolve('adb.exe'), serial: 'phone', report: resolve('report.json') })
  for (const bad of [args.concat('--serial', 'other'), args.concat('--wake'), args.slice(0, -2),
    args.filter(value => value !== '--adb'), args.concat('--adb=other')]) assert.throws(() => parseRecoveryArguments(bad))
})

test('all three original network combinations are restored exactly without wake commands', async () => {
  for (const network of [{ wifi: '1', data: '0' }, { wifi: '0', data: '1' }, { wifi: '1', data: '1' }]) {
    const io = fixture({ network })
    const result = await run(io, { onSnapshot: async snapshot => { assert.deepEqual(snapshot.original, network); io.events.push(['snapshot']) } })
    assert.equal(result.result, 'pass')
    assert.equal(result.retirement.confirmed, true)
    assert.equal(result.offline.networkEvidence.validatedNetworks, 2, 'IMS and persistent VPN remain visible')
    assert.equal(result.offline.networkEvidence.usableUnderlyingInternetNetworks, 0)
    assert.deepEqual(io.network, network)
    assert.equal(result.modelRequestRetryTested, false)
    assert.equal(result.activeAgentTaskSurvivalTested, false)
    assert.ok(io.events.findIndex(e => e[0] === 'snapshot') < io.events.findIndex(e => e[0] === 'instrument'))
    assert.ok(io.events.every(e => e[0] !== 'input'))
  }
})

test('interactive, unlocked, unreadable flags and no initial network fail before instrumentation', async () => {
  for (const options of [{ power: 'mWakefulness=Awake\n' }, { policy: policy.replace('showing=true', 'showing=false') },
    { network: { wifi: 'null' } }, { network: { wifi: '0', data: '0' } }]) {
    const io = fixture(options)
    await assert.rejects(run(io), error => error.recovery.result === 'unknown')
    assert.ok(io.events.every(e => !['instrument', 'svc'].includes(e[0])))
  }
})

test('snapshot persistence failure prevents instrumentation and network mutation', async () => {
  const io = fixture()
  await assert.rejects(run(io, { onSnapshot: async () => { throw new Error('disk full') } }))
  assert.ok(io.events.every(e => !['instrument', 'svc'].includes(e[0])))
})

test('an incomplete instrumentation JSON line waits for its terminating newline', async () => {
  const result = await run(fixture({ partialReady: true }))
  assert.equal(result.result, 'pass')
})

test('wrong ready identity and changed offline Session, digest, generation or PID cannot pass', async () => {
  for (const options of [{ ready: { token: 'wrong' } }, { offline: { sessionId: 'wrong' } },
    { offline: { generation: 'new' } }, { offline: { eventsSha256: 'c'.repeat(64) } },
    { offline: { eventCount: 2 } }, { offline: { interactive: true } }, { changedPid: true }]) {
    const io = fixture(options)
    await assert.rejects(run(io), error => error.recovery.result === 'unknown' && error.retirement.networkRestored)
    assert.deepEqual(io.network, { wifi: '1', data: '0' })
  }
})

test('cancellation joins the dispatched mutation then restores with an independent signal before retiring', async () => {
  const io = fixture(), controller = new AbortController(), dispatched = Promise.withResolvers(), settled = Promise.withResolvers()
  io.hook = async (args, signal) => {
    if (args.join(' ') === 'svc wifi disable') { dispatched.resolve(); await settled.promise }
    if (args.join(' ') === 'svc wifi enable') assert.equal(signal.aborted, false)
  }
  const running = run(io, { signal: controller.signal })
  await dispatched.promise
  controller.abort(new Error('guard deadline'))
  assert.ok(!io.events.some(e => e[0] === 'am' && e[1] === 'force-stop'))
  settled.resolve()
  await assert.rejects(running, error => error.retirement.networkRestored && error.retirement.confirmed)
  assert.deepEqual(io.network, { wifi: '1', data: '0' })
  assert.ok(io.events.findIndex(e => e.join(' ') === 'svc wifi enable') < io.events.findIndex(e => e[1] === 'force-stop'))
})

test('partial mutation failure still attempts both original network settings', async () => {
  const io = fixture()
  let once = false
  io.hook = async args => { if (args.join(' ') === 'svc data disable' && !once) { once = true; throw new Error('dispatch refused') } }
  await assert.rejects(run(io), error => error.retirement.networkRestored)
  assert.deepEqual(io.network, { wifi: '1', data: '0' })
  assert.ok(io.events.some(e => e.join(' ') === 'svc wifi enable'))
})

test('USB restoration failure or ambiguous mutation receipt remains unknown even after later matching flags', async () => {
  for (const ambiguous of [false, true]) {
    const io = fixture()
    let once = false
    io.hook = async args => {
      if (args.join(' ') === (ambiguous ? 'svc wifi disable' : 'svc wifi enable') && !once) {
        once = true; throw Object.assign(new Error('USB lost'), { commandOutcomeUnknown: true })
      }
    }
    await assert.rejects(run(io), error => !error.retirement.networkRestored && !error.retirement.confirmed && error.recovery.networkCommandOutcomeUnknown)
  }
})

test('successful result text cannot replace actual host close or device retirement', async () => {
  for (const options of [{ neverClose: true }, { liveProcess: true }]) {
    const io = fixture(options)
    await assert.rejects(run(io), error => error.retirement.networkRestored && !error.retirement.confirmed)
    if (options.neverClose) assert.ok(io.events.some(e => e[0] === 'unref'))
  }
})

test('result parser rejects duplicate final codes and wrong restored state', () => {
  const result = { ...ready, stage: 'restored', networkEvidence: onlineEvidence(), interactive: false, locked: true }
  const output = `INSTRUMENTATION_RESULT: result=${JSON.stringify(result)}\nINSTRUMENTATION_RESULT: passed=true\nINSTRUMENTATION_CODE: -1\n`
  assert.equal(parseRecoveryResult(output, ready).sessionId, ready.sessionId)
  for (const bad of [output + 'INSTRUMENTATION_CODE: -1\n', output.replace('passed=true', 'passed=false'),
    output.replace('"locked":true', '"locked":false'), output.replace('"usableUnderlyingInternetNetworks":1', '"usableUnderlyingInternetNetworks":0')]) {
    assert.throws(() => parseRecoveryResult(bad, ready))
  }
})

test('capability facts retain VPN/default evidence but exclude IMS and VPN from usable underlay', () => {
  assert.equal(validateRecoveryNetworks(offlineEvidence()).usableUnderlyingInternetNetworks, 0)
  assert.equal(offlineEvidence().appDefaultNetworkHandle, '20')
  for (const transport of [0, 1, 2, 3, 8, 99]) {
    const value = evidence([fact('10', { transportTypes: [transport] }), vpn, ims], { validated: 3, internet: 2, underlying: 1 })
    assert.equal(validateRecoveryNetworks(value).usableUnderlyingInternetNetworks, 1)
  }
  for (const malformed of [undefined, { ...offlineEvidence(), schema: 1 },
    { ...offlineEvidence(), usableUnderlyingInternetNetworks: 1 },
    { ...offlineEvidence(), appDefaultNetworkHandle: null },
    { ...offlineEvidence(), networks: [vpn, { ...ims, handle: '20' }] },
    { ...offlineEvidence(), networks: [{ ...vpn, transportTypes: [1] }, ims] }]) assert.throws(() => validateRecoveryNetworks(malformed))
})

test('remaining Ethernet, other internet, unvalidated internet or unknown capabilities cannot pass offline', async () => {
  const remaining = [
    ...[3, 8, 99].map(type => evidence([fact('10', { transportTypes: [type] }), vpn, ims], { validated: 3, internet: 2, underlying: 1 })),
    evidence([fact('10', { validated: false }), vpn, ims], { validated: 2, internet: 1, underlying: 0, unvalidated: 1 }),
    evidence([fact('10', { capabilitiesKnown: false, internet: false, validated: false, notSuspended: false, transportTypes: [] }), vpn, ims],
      { validated: 2, internet: 1, underlying: 0, unknown: 1 }),
  ]
  for (const offlineEvidence of remaining) {
    const io = fixture({ offlineEvidence })
    await assert.rejects(run(io), error => {
      assert.equal(error.recovery.phase, 'offline-observation')
      assert.deepEqual(error.recovery.lastObservation.networkEvidence, offlineEvidence)
      assert.match(error.recovery.failures.execution.message, /timed out.*offline/)
      assert.equal(error.retirement.networkRestored, true)
      return true
    })
  }
})

test('nested failures preserve command causes without unlimited recursion or raw properties', () => {
  const cause = new Error('USB disconnected')
  const error = new AggregateError([new Error('restore wifi failed', { cause })], 'restoration unconfirmed')
  error.privateDetails = 'must not be serialized'
  const result = describeRecoveryFailure(error)
  assert.equal(result.causes[0].causes[0].message, 'USB disconnected')
  assert.equal(JSON.stringify(result).includes('privateDetails'), false)
  cause.cause = cause
  assert.equal(describeRecoveryFailure(cause).causes[0].type, 'truncated')
})

test('native checkpoint failures retain their last network observation and nested cause details', async () => {
  await assert.rejects(run(fixture({ nativeFailure: true })), error => {
    assert.equal(error.recovery.phase, 'offline-checkpoint')
    assert.equal(error.recovery.lastObservation.stage, 'offline')
    assert.deepEqual(error.recovery.lastObservation.networkEvidence, offlineEvidence())
    assert.equal(error.recovery.nativeFailure.causes[1].message, 'network changed during checkpoint')
    assert.match(error.recovery.failures.execution.message, /closed before offline/)
    return true
  })
})

test('ADB adapter binds serial and mutation cancellation waits for actual command close', async () => {
  const controller = new AbortController(), child = new EventEmitter(), killed = []
  Object.assign(child, { pid: 7, stdout: new PassThrough(), stderr: new PassThrough(), unref() {}, kill: signal => killed.push(signal) })
  const owner = startRecoveryAdb('exact-adb', 'exact-phone', ['shell', 'svc', 'wifi', 'disable'], {
    timeoutMs: 1000, signal: controller.signal, mutation: true,
    launch: (binary, args, options) => { assert.equal(binary, 'exact-adb'); assert.deepEqual(args.slice(0, 2), ['-s', 'exact-phone']); assert.equal(options.windowsHide, true); return child },
  })
  const running = owner.result()
  controller.abort(new Error('cancelled'))
  assert.deepEqual(killed, [])
  child.stdout.write('done')
  child.emit('close', 0, null)
  assert.equal(await running, 'done')
})

test('cancelled ADB reads still await close and cannot turn exit zero into success', async () => {
  const controller = new AbortController(), child = new EventEmitter(), killed = []
  Object.assign(child, { pid: 7, stdout: new PassThrough(), stderr: new PassThrough(), unref() {}, kill: signal => killed.push(signal) })
  const owner = startRecoveryAdb('adb', 'phone', ['shell', 'dumpsys', 'power'],
    { timeoutMs: 1000, signal: controller.signal, launch: () => child })
  let settled = false
  const running = owner.result().finally(() => { settled = true })
  controller.abort(new Error('cancelled'))
  await Promise.resolve()
  assert.deepEqual(killed, ['SIGKILL'])
  assert.equal(settled, false)
  child.emit('close', 0, null)
  await assert.rejects(running, error => error.commandOutcomeUnknown === false)
})

test('a network command deadline remains unknown even if process kill is acknowledged', async () => {
  const child = new EventEmitter()
  Object.assign(child, { pid: 7, stdout: new PassThrough(), stderr: new PassThrough(), unref() {},
    kill: () => { queueMicrotask(() => child.emit('close', -9, 'SIGKILL')); return true } })
  const owner = startRecoveryAdb('adb', 'phone', ['shell', 'svc', 'wifi', 'disable'],
    { timeoutMs: 10, mutation: true, launch: () => child })
  await assert.rejects(owner.result(), error => error.commandOutcomeUnknown === true)
})

test('the command owner joins a real host process close after cancellation without ADB', async () => {
  const controller = new AbortController(), ready = Promise.withResolvers()
  let processClosed = false, observedFailure
  const owner = startRecoveryAdb('unused-adb', 'unused-phone', ['host-test'], {
    timeoutMs: 3000, signal: controller.signal,
    launch: (_binary, _args, options) => {
      const child = spawn(process.execPath, ['-e', "process.stdout.write('ready'); setInterval(() => {}, 1000)"], options)
      child.stdout.once('data', ready.resolve)
      child.once('error', ready.reject)
      child.once('close', () => { processClosed = true; ready.reject(new Error('Host smoke closed before startup')) })
      return child
    },
  })
  const pending = owner.result()
  pending.catch(error => { observedFailure = error })
  await ready.promise
  controller.abort(new Error('host smoke cancelled'))
  await assert.rejects(pending)
  assert.ok(observedFailure instanceof Error)
  assert.equal(processClosed, true)
  assert.ok((await owner.closed).code !== 0)
})
