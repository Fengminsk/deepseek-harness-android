import assert from 'node:assert/strict'
import test from 'node:test'
import { parseSafBootstrapReady, parseSafProcesses, runSafBootstrap, SAF_TEST_PACKAGE } from './acceptance-saf-bootstrap.mjs'

const token = 'ab893f0b-bcec-4d1a-9491-8f2699881673'
const leaseMillis = 60_000
const ready = { schema: 1, token, packageName: SAF_TEST_PACKAGE, pid: 1234, uid: 10234,
  appUid: 10233, serviceBound: true, leaseMillis }
const frame = value => `INSTRUMENTATION_STATUS: safBootstrapReady=${JSON.stringify(value)}\nINSTRUMENTATION_STATUS_CODE: 1\n`
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
const options = { token, leaseMillis, readyTimeoutMillis: 1000, cleanupTimeoutMillis: 1000 }

function fixture({ output = frame(ready), before = [], observed, after = [] } = {}) {
  const closed = deferred(), events = []
  let started = false, stopped = false, ended = false
  const current = observed ?? [{ pid: ready.pid, uid: ready.uid, name: SAF_TEST_PACKAGE }]
  const client = {
    status: () => ({ output, ended }), closed: closed.promise,
    dispose: async () => { events.push('client-dispose'); ended = true; closed.resolve(); await closed.promise },
  }
  const io = {
    processes: async () => { events.push('processes'); return !started ? before : stopped ? after : current },
    start: async () => { events.push('start'); started = true; return client },
    stopTestPackage: async () => { events.push('stop'); stopped = true },
  }
  return { io, client, events, exit() { ended = true; closed.resolve() } }
}

test('readiness waits for its complete status frame and rejects contradictory identities', () => {
  assert.equal(parseSafBootstrapReady('', token, leaseMillis), null)
  assert.equal(parseSafBootstrapReady(frame(ready).split('INSTRUMENTATION_STATUS_CODE')[0], token, leaseMillis), null)
  assert.deepEqual(parseSafBootstrapReady(frame(ready), token, leaseMillis), ready)
  for (const invalid of [{ ...ready, uid: ready.appUid }, { ...ready, token: 'wrong' },
    { ...ready, packageName: 'com.minnnng.dsh_android' }, { ...ready, serviceBound: false },
    { ...ready, leaseMillis: 1 }, { ...ready, pid: 0 }, { ...ready, extra: true }])
    assert.throws(() => parseSafBootstrapReady(frame(invalid), token, leaseMillis))
  assert.throws(() => parseSafBootstrapReady(frame(ready) + frame(ready), token, leaseMillis), /Duplicate/)
})

test('retirement observations require complete numeric process identity and unique PIDs', () => {
  assert.deepEqual(parseSafProcesses(` PID UID ARGS\n 1234 10234 ${SAF_TEST_PACKAGE}\n 2 0 init\n`),
    [{ pid: 1234, uid: 10234, name: SAF_TEST_PACKAGE }, { pid: 2, uid: 0, name: 'init' }])
  for (const text of ['', 'PID NAME\n1 init', 'PID UID ARGS\n1 u0_a1 app', 'PID UID ARGS\n1 1 app\n1 2 other'])
    assert.throws(() => parseSafProcesses(text))
})

test('a borrowed test-package process is neither started nor stopped', async () => {
  const f = fixture({ before: [{ pid: 44, uid: 44, name: `${SAF_TEST_PACKAGE}:another` }] })
  await assert.rejects(runSafBootstrap(f.io, () => assert.fail('must not run'), options), /not owned/)
  assert.deepEqual(f.events, ['processes'])
})

test('main starts after real ready PID/UID observation and returns only after all owners close', async () => {
  const f = fixture(), disposing = deferred(), allowClose = deferred()
  f.client.dispose = async () => { f.events.push('client-dispose'); disposing.resolve(); await allowClose.promise; f.exit() }
  let returned = false
  const result = runSafBootstrap(f.io, async signal => {
    assert.equal(signal.aborted, false)
    assert.deepEqual(f.events, ['processes', 'start', 'processes'])
    f.events.push('main-settled')
    return { assertions: 4 }
  }, options).then(value => { returned = true; return value })
  try {
    await disposing.promise
    assert.equal(returned, false)
    assert.deepEqual(f.events, ['processes', 'start', 'processes', 'main-settled', 'stop', 'processes', 'client-dispose'])
  } finally { allowClose.resolve() }
  const value = await result
  assert.deepEqual(value.value, { assertions: 4 })
  assert.equal(value.bootstrap.uidRetired, true)
  assert.equal(value.bootstrap.hostProcessClosed, true)
})

test('a ready PID carrying a different actual UID cannot run main acceptance', async () => {
  const f = fixture({ observed: [{ pid: ready.pid, uid: ready.appUid, name: SAF_TEST_PACKAGE }] })
  await assert.rejects(runSafBootstrap(f.io, () => assert.fail('must not run'), options), /not actually observed/)
  assert.ok(f.events.includes('stop'))
  assert.ok(f.events.includes('client-dispose'))
})

test('premature bootstrap exit aborts main and waits for its actual teardown barrier', async () => {
  const f = fixture(), running = deferred(), cancelled = deferred(), retired = deferred()
  const result = runSafBootstrap(f.io, async signal => {
    running.resolve()
    signal.addEventListener('abort', () => cancelled.resolve(), { once: true })
    await retired.promise
    f.events.push('main-settled')
  }, options)
  const rejection = assert.rejects(result, /exited before/)
  try {
    await running.promise
    f.exit()
    await cancelled.promise
    assert.equal(f.events.includes('stop'), false)
  } finally { retired.resolve() }
  await rejection
  assert.ok(f.events.indexOf('stop') > f.events.indexOf('main-settled'))
})

test('unsettled main cleanup cannot report success even if bootstrap was stopped', async () => {
  const f = fixture(), running = deferred(), retired = deferred()
  const result = runSafBootstrap(f.io, async () => { running.resolve(); await retired.promise },
    { ...options, cleanupTimeoutMillis: 10 })
  const rejection = assert.rejects(result, error => {
    assert.ok(error instanceof AggregateError)
    assert.ok(error.errors.some(value => /teardown is unconfirmed/.test(value.message)))
    return true
  })
  try { await running.promise; f.exit(); await rejection }
  finally { retired.resolve(); await result.catch(() => {}) }
})

test('a replacement process under the old test UID prevents retirement acceptance', async () => {
  const f = fixture({ after: [{ pid: 5678, uid: ready.uid, name: 'renamed-process' }] })
  await assert.rejects(runSafBootstrap(f.io, async () => 'main passed', { ...options, cleanupTimeoutMillis: 10 }),
    error => error instanceof AggregateError && error.errors.some(value => /PID\/UID retirement/.test(value.message)))
  assert.ok(f.events.includes('client-dispose'))
})

test('main failure survives successful bootstrap cleanup', async () => {
  const f = fixture()
  const failure = new Error('real SAF assertion failed')
  await assert.rejects(runSafBootstrap(f.io, async () => { throw failure }, options), error => error === failure)
  assert.ok(f.events.includes('stop'))
  assert.ok(f.events.includes('client-dispose'))
})

test('stop or host-client-close failure cannot turn a main result into success', async () => {
  for (const operation of ['stop', 'dispose']) {
    const f = fixture()
    if (operation === 'stop') f.io.stopTestPackage = async () => { throw new Error('stop refused') }
    else f.client.dispose = async () => { f.exit(); throw new Error('host close failed') }
    await assert.rejects(runSafBootstrap(f.io, async () => 'main passed', options), /cleanup failed/)
  }
})

test('spawn failure before ready still closes the owned client and never runs main', async () => {
  const f = fixture()
  f.client.status = () => ({ output: '', ended: false, error: new Error('spawn failed') })
  await assert.rejects(runSafBootstrap(f.io, () => assert.fail('must not run'), options), /spawn failed/)
  assert.ok(f.events.includes('client-dispose'))
})

test('partial readiness reaching its deadline still fails and closes the owned client', async () => {
  const f = fixture({ output: frame(ready).split('INSTRUMENTATION_STATUS_CODE')[0] })
  await assert.rejects(runSafBootstrap(f.io, () => assert.fail('must not run'),
    { ...options, readyTimeoutMillis: 10 }), /did not become ready/)
  assert.ok(f.events.includes('client-dispose'))
})

test('invalid host deadlines fail before acquiring any process', async () => {
  const f = fixture()
  await assert.rejects(runSafBootstrap(f.io, () => {}, { ...options, cleanupTimeoutMillis: 0 }), /host deadline/)
  assert.deepEqual(f.events, [])
})
