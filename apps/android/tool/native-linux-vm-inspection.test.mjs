import assert from 'node:assert/strict'
import test from 'node:test'
import { NativeLinuxVm } from '../runtime/native-linux-vm.mjs'
import { prepareLinuxVmInspection, parseLinuxVmInspection } from '../runtime/native-linux-vm-inspection.mjs'

const sessionId = 'android-inspection-test'
const id = 'd9ee88e9-038d-4078-bd3a-4b575a8bf760'
const signal = () => new AbortController().signal
const absent = () => ({ version: 1, sessionId, status: 'absent', blocked: false, needsReview: false,
  requestedRunFound: null, truncated: false, automaticReplay: false, records: [] })
const uncertain = () => ({ ...absent(), status: 'blocked', blocked: true, needsReview: true,
  requestedRunFound: true, records: [{ runId: id, operation: 'import', state: 'outcome_uncertain',
    retirementConfirmed: null, diskCommitted: null, filePublished: null, exitCode: null,
    reason: 'retirement_unconfirmed', needsReview: true }] })

test('inspection arguments contain only an optional canonical run identity', () => {
  assert.deepEqual(prepareLinuxVmInspection({}), {})
  assert.deepEqual(prepareLinuxVmInspection({ runId: id }), { id })
  for (const args of [null, [], { sessionId }, { runId: id.toUpperCase() }, { runId: `${id}\n` },
    { runId: '../outside' }, { runId: undefined }, { retry: true },
    { get runId() { throw new Error('must not execute getter') } }]) {
    assert.throws(() => prepareLinuxVmInspection(args), TypeError)
  }
})

test('same-session unknown facts remain null in a bounded immutable observation', () => {
  const result = parseLinuxVmInspection(uncertain(), { sessionId, id })
  assert.equal(result.records[0].diskCommitted, null)
  assert.equal(result.records[0].retirementConfirmed, null)
  assert.equal(result.automaticReplay, false)
  assert.throws(() => { result.records[0].diskCommitted = false }, TypeError)
  assert.throws(() => result.records.push({}), TypeError)
  assert.deepEqual(parseLinuxVmInspection(absent(), { sessionId }), absent())
  const notFound = { ...absent(), requestedRunFound: false }
  assert.deepEqual(parseLinuxVmInspection(notFound, { sessionId, id }), notFound)
})

test('cross-session, contradictory, unbounded and unsafe recovery observations are rejected', () => {
  const changes = [
    value => { value.sessionId = 'another-session' },
    value => { value.records[0].runId = 'ebee88e9-038d-4078-bd3a-4b575a8bf760' },
    value => { value.blocked = false },
    value => { value.needsReview = false },
    value => { value.automaticReplay = true },
    value => { value.requestedRunFound = false },
    value => { value.records.push({ ...value.records[0] }) },
    value => { value.records[0].diskCommitted = 'false' },
    value => { value.records[0].state = 'recovered_committed' },
    value => { value.records[0].state = 'completed' },
    value => { value.records[0].filePublished = true },
    value => { value.records[0].operation = 'export'; value.records[0].diskCommitted = true },
    value => { value.records[0].reason = 'unexpected_fallback' },
    value => { value.records[0].exitCode = 256 },
    value => { value.status = 'absent' },
    value => { value.androidPath = '/data/user/0/private' },
  ]
  for (const change of changes) {
    const value = uncertain(); change(value)
    assert.throws(() => parseLinuxVmInspection(value, { sessionId, id }), TypeError)
  }
  assert.throws(() => parseLinuxVmInspection({ ...absent(), records: Array(33).fill(uncertain().records[0]) }, { sessionId }))
})

test('a committed-pointer observation keeps review facts without pretending exit success', () => {
  const value = uncertain()
  Object.assign(value, { status: 'ready', blocked: false })
  Object.assign(value.records[0], { state: 'recovered_committed', retirementConfirmed: true,
    diskCommitted: true, reason: 'pointer_committed' })
  const result = parseLinuxVmInspection(value, { sessionId, id })
  assert.equal(result.records[0].exitCode, null)
  assert.equal(result.needsReview, true)
  assert.equal(result.blocked, false)
})

test('an unreadable journal cannot establish whether a requested run exists', () => {
  const value = uncertain()
  Object.assign(value, { status: 'unknown', requestedRunFound: null })
  Object.assign(value.records[0], { state: 'unknown', operation: 'unknown', reason: 'scan_incomplete' })
  assert.equal(parseLinuxVmInspection(value, { sessionId, id }).requestedRunFound, null)
  value.records = []
  assert.equal(parseLinuxVmInspection(value, { sessionId, id }).requestedRunFound, null)
  value.status = 'blocked'
  assert.throws(() => parseLinuxVmInspection(value, { sessionId, id }), TypeError)
})

test('an uncertain execution owner can inspect but inspection never reopens commands', async () => {
  const methods = []
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    methods.push(method)
    if (method.endsWith('.inspect') && !params.id) return absent()
    if (method.endsWith('.inspect')) { assert.deepEqual(params, { sessionId, id }); return uncertain() }
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: false }
    throw new Error('receipt lost after dispatch')
  } })
  await assert.rejects(owner.execute(sessionId, { command: 'printf data > state' }, signal(), { persistChanges: true }),
    { code: 'linux-vm/outcome-uncertain' })
  assert.deepEqual(await owner.inspect(sessionId, { runId: id }, signal()), uncertain())
  await assert.rejects(owner.execute(sessionId, { command: 'retry' }, signal(), { persistChanges: true }), /owner is closed/)
  assert.deepEqual(methods, ['native.linuxVm.inspect', 'native.linuxVm.execute', 'native.linuxVm.cancel', 'native.linuxVm.inspect'])
  await owner.dispose()
  await assert.rejects(owner.inspect(sessionId, {}, signal()), /owner is disposed/)
})

test('a malformed native observation stops subsequent writes without execution or cancellation', async () => {
  const methods = []
  const owner = new NativeLinuxVm({ request: async method => { methods.push(method); return { ...absent(), sessionId: 'other' } } })
  await assert.rejects(owner.inspect(sessionId, {}, signal()), { code: 'linux-vm/inspection-unavailable' })
  await assert.rejects(owner.execute(sessionId, { command: 'id' }, signal(), { persistChanges: true }), /owner is closed/)
  assert.deepEqual(methods, ['native.linuxVm.inspect'])
  await owner.dispose()
})

test('cancelled inspection sends no VM cancellation and cannot authorize a replay', async () => {
  const abort = new AbortController(), methods = []
  const owner = new NativeLinuxVm({ request: (method, _params, requestSignal) => {
    methods.push(method)
    return new Promise((_resolve, reject) => requestSignal.addEventListener('abort', () => reject(requestSignal.reason), { once: true }))
  } })
  const pending = owner.inspect(sessionId, {}, abort.signal)
  abort.abort(new Error('stop reading'))
  await assert.rejects(pending, /stop reading/)
  assert.deepEqual(methods, ['native.linuxVm.inspect'])
  await owner.dispose()
})

test('first execution presents committed recovery facts and refuses replay even after a manual query', async () => {
  const methods = [], recovered = uncertain()
  Object.assign(recovered, { status: 'ready', blocked: false, requestedRunFound: null })
  Object.assign(recovered.records[0], { state: 'recovered_committed', retirementConfirmed: true,
    diskCommitted: true, reason: 'pointer_committed' })
  const owner = new NativeLinuxVm({ request: async method => { methods.push(method); return recovered } })
  for (let attempt = 0; attempt < 2; attempt++) {
    await assert.rejects(owner.execute(sessionId, { command: 'echo duplicate >> data' }, signal(), { persistChanges: true }),
      error => error.code === 'linux-vm/recovery-required'
        && error.inspection.records[0].diskCommitted === true
        && error.inspection.records[0].exitCode === null)
    assert.equal((await owner.inspect(sessionId, {}, signal())).needsReview, true)
  }
  assert.deepEqual(methods, Array(4).fill('native.linuxVm.inspect'))
  await owner.dispose()
})

test('first-session inspection reserves capacity and cancellation prevents native dispatch', async () => {
  const abort = new AbortController(), methods = []
  let entered
  const inspecting = new Promise(resolve => { entered = resolve })
  const owner = new NativeLinuxVm({ request: (method, _params, requestSignal) => {
    methods.push(method); entered()
    return new Promise((_resolve, reject) => requestSignal.addEventListener('abort', () => reject(requestSignal.reason), { once: true }))
  } })
  const first = owner.execute(sessionId, { command: 'echo once >> data' }, abort.signal, { persistChanges: true })
  await inspecting
  await assert.rejects(owner.execute(sessionId, { command: 'echo twice >> data' }, signal(), { persistChanges: true }),
    /正在执行其他命令/u)
  abort.abort(new Error('cancel before admission'))
  await assert.rejects(first, /cancel before admission/)
  assert.deepEqual(methods, ['native.linuxVm.inspect'])
  await owner.dispose()
})

test('disposal during inspection prevents dispatch and does not fabricate an uncertain new execution', async () => {
  let finishInspection
  const methods = []
  const owner = new NativeLinuxVm({ request: method => {
    methods.push(method)
    return new Promise(resolve => { finishInspection = resolve })
  } })
  const command = owner.execute(sessionId, { command: 'echo must-not-run' }, signal(), { persistChanges: true })
  const rejected = assert.rejects(command, /owner is closed/)
  const closed = owner.dispose()
  finishInspection(absent())
  await rejected
  await closed
  assert.deepEqual(methods, ['native.linuxVm.inspect'])
})

test('publication uncertainty retains a confirmed disk commit instead of degrading it to unknown', async () => {
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    if (method.endsWith('.inspect')) return absent()
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: true }
    return { id: params.id, sessionId, status: 'outcome_uncertain', output: '', exitCode: 0,
      guestUid: 99001, timedOut: false, cancelled: false, truncated: false,
      retirementConfirmed: true, diskCommitted: true, detail: 'terminal record write failed' }
  } })
  await assert.rejects(owner.execute(sessionId, { command: 'echo retained >> state' }, signal(), { persistChanges: true }),
    error => error.code === 'linux-vm/outcome-uncertain' && error.receipt.diskCommitted === true
      && error.receipt.retirementConfirmed === true && error.receipt.nativeStatus === 'outcome_uncertain')
  await owner.dispose()
})
