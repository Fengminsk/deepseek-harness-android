import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import { AppPackageOperations } from '../runtime/package-operations.mjs'

function harness(t, manager = { packageOperationsSnapshot: () => [] }) {
  const listeners = new Set()
  const ctx = {
    get: name => name === 'pluginManager' ? manager : undefined,
    on(name, callback) {
      assert.equal(name, 'plugin-manager/before-package-operation')
      listeners.add(callback)
      return () => listeners.delete(callback)
    },
  }
  const gate = new AppPackageOperations(ctx)
  t.after(() => gate.close())
  return { gate, before: kind => { for (const listener of listeners) listener({ id: randomUUID(), kind }) } }
}

test('every original package operation blocks maintenance without changing Agent or job state', t => {
  const operations = []
  const { gate, before } = harness(t, { packageOperationsSnapshot: () => operations })
  for (const kind of ['inspect', 'registries', 'install', 'remove']) {
    const operation = { id: randomUUID(), kind }
    before(kind)
    operations.push(operation)
    assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/package-busy')
    assert.deepEqual(operations, [operation])
    operations.pop()
  }
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, true)
})

test('reservation synchronously rejects App, Web and direct package admission until released', t => {
  const { gate, before } = harness(t)
  const token = randomUUID()
  const reserved = gate.reserve({ token })
  assert.equal(reserved.state, 'reserved')
  for (const kind of ['inspect', 'registries', 'install', 'remove']) {
    assert.throws(() => before(kind), { code: 'ANDROID_RUNTIME_TRANSITION' })
  }
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, false)
  gate.release({ token: randomUUID(), epoch: reserved.epoch })
  assert.throws(() => before('install'), { code: 'ANDROID_RUNTIME_TRANSITION' })
  gate.release({ token, epoch: reserved.epoch })
  assert.doesNotThrow(() => before('install'))
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).accepted, false)
})

test('expiration releases an uncommitted reservation and cannot later authorize termination', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { gate, before } = harness(t)
  const token = randomUUID(), reserved = gate.reserve({ token })
  t.mock.timers.tick(15_000)
  assert.doesNotThrow(() => before('remove'))
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).accepted, false)
})

test('committed admission remains sealed after the reservation deadline until explicit release or exit', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { gate, before } = harness(t)
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).state, 'committed')
  t.mock.timers.tick(60_000)
  assert.throws(() => before('registries'), { code: 'ANDROID_RUNTIME_TRANSITION' })
  gate.release({ token, epoch: reserved.epoch })
  assert.doesNotThrow(() => before('registries'))
})

test('mode-save failure and a lost reserve acknowledgment can both release the Node reservation', t => {
  const { gate, before } = harness(t)
  const savedFailure = randomUUID(), reserved = gate.reserve({ token: savedFailure })
  gate.release({ token: savedFailure, epoch: reserved.epoch })
  const lostReply = randomUUID()
  gate.reserve({ token: lostReply })
  gate.release({ token: lostReply })
  assert.doesNotThrow(() => before('inspect'))
})

test('unknown package provider, failed snapshots and disposed runtime never authorize maintenance', t => {
  const missing = harness(t, {}).gate
  assert.equal(missing.reserve({ token: randomUUID() }).code, 'runtime/package-state-unknown')
  const failed = harness(t, { packageOperationsSnapshot() { throw new Error('provider unavailable') } }).gate
  assert.throws(() => failed.reserve({ token: randomUUID() }), /provider unavailable/)
  missing.close()
  assert.equal(missing.reserve({ token: randomUUID() }).accepted, false)
})

test('old epochs cannot commit or release reservations in a replacement runtime', t => {
  const old = harness(t).gate
  const token = randomUUID(), previous = old.reserve({ token })
  old.close()
  const { gate, before } = harness(t)
  const replacement = gate.reserve({ token })
  assert.notEqual(previous.epoch, replacement.epoch)
  assert.equal(gate.commit({ token, epoch: previous.epoch }).accepted, false)
  gate.release({ token, epoch: previous.epoch })
  assert.throws(() => before('install'), { code: 'ANDROID_RUNTIME_TRANSITION' })
  assert.equal(gate.commit({ token, epoch: replacement.epoch }).accepted, true)
})
