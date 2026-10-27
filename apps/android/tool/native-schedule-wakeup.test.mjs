import assert from 'node:assert/strict'
import test from 'node:test'
import { setImmediate as turn } from 'node:timers/promises'
import { NativeScheduleWakeup } from '../runtime/native-schedule-wakeup.mjs'

const generation = '98b29a48-7c8d-4dc1-b751-63af56ad0349'
const anotherGeneration = 'fcd7cb19-4daf-4994-b978-5ab147ba97eb'
const due = '2026-10-29T12:00:00.000Z'
const later = '2026-10-30T12:00:00.000Z'
const row = (scheduledAt = due, status = 'active') => ({ id: 'private-task', sessionId: 'private-session',
  title: 'private-title', prompt: 'private-prompt', kind: 'at', scheduledAt, status })
const acknowledgment = request => ({ version: 1, generation: request.generation, revision: request.revision, accepted: true })
const deferred = () => Promise.withResolvers()

function fixture({ catalog = async () => [], native, requestTimeoutMs = 1000, closeTimeoutMs = 1000, subscribe, onLimits } = {}) {
  let listener, subscribed = 0, reads = 0
  const requests = [], warnings = [], trace = []
  const owner = new NativeScheduleWakeup({
    invoke: (namespace, method, args, signal) => {
      assert.equal(namespace, 'schedule')
      assert.equal(method, 'catalog')
      assert.deepEqual(args, {})
      assert.equal(subscribed, 1)
      assert.ok(signal instanceof AbortSignal)
      trace.push('read')
      reads++
      return catalog(signal, reads)
    },
    transport: { async request(method, request, signal) {
      assert.ok(signal instanceof AbortSignal)
      requests.push({ method, request })
      trace.push(method)
      if (native) return native(method, request, signal)
      return method.endsWith('.begin') ? { version: 1, generation } : acknowledgment(request)
    } },
    subscribe: callback => {
      if (subscribe) return subscribe(callback)
      subscribed++
      trace.push('subscribe')
      listener = callback
      return () => { subscribed--; listener = undefined; trace.push('unsubscribe') }
    },
    warn: message => warnings.push(message),
    limits: () => { onLimits?.(); return { requestTimeoutMs, closeTimeoutMs } },
  })
  return { owner, requests, warnings, trace, changes: () => listener?.(), reads: () => reads,
    updates: () => requests.filter(item => item.method === 'native.scheduleWakeup.update').map(item => item.request) }
}

async function until(condition) {
  for (let attempt = 0; attempt < 100 && !condition(); attempt++) await turn()
  assert.ok(condition(), 'Expected local asynchronous checkpoint was not reached')
}

test('startup reads the original API after subscribing and sends only the nearest active projection', async () => {
  const f = fixture({ catalog: async () => [row(later), row('2020-01-01T00:00:00.000Z', 'inactive'), row()] })
  const first = f.owner.start()
  assert.equal(f.owner.start(), first)
  await first
  assert.deepEqual(f.trace.slice(0, 3), ['subscribe', 'native.scheduleWakeup.begin', 'read'])
  assert.deepEqual(f.updates(), [{ version: 1, generation, revision: 1, state: 'ready',
    nextDueAtMs: Date.parse(due), activeCount: 2, reason: null }])
  assert.ok(!JSON.stringify(f.requests).includes('private-'))
  await f.owner.close()
  assert.equal(f.updates().length, 1, 'Shutdown must preserve future alarms rather than publish an empty catalog')
})

test('empty and inactive-only catalogs explicitly cancel the projection without rearming ended reminders', async () => {
  let rows = [row()]
  const f = fixture({ catalog: async () => rows })
  await f.owner.start()
  rows = [row(due, 'inactive')]
  f.changes()
  await until(() => f.updates().length === 2)
  rows = []
  f.changes()
  await until(() => f.updates().length === 3)
  assert.deepEqual(f.updates().slice(1).map(value => [value.nextDueAtMs, value.activeCount, value.state]),
    [[null, 0, 'ready'], [null, 0, 'ready']])
  assert.deepEqual(f.updates().map(value => value.revision), [1, 2, 3])
  await f.owner.close()
})

test('past targets remain due, including valid pre-epoch retained tasks', async () => {
  const f = fixture({ catalog: async () => [row('1969-12-31T23:59:59.000Z'), row()] })
  await f.owner.start()
  assert.equal(f.updates()[0].nextDueAtMs, 0)
  assert.equal(f.updates()[0].activeCount, 2)
  await f.owner.close()
})

test('a committed change during a baseline read discards the stale result and coalesces read work', async () => {
  const first = deferred()
  const f = fixture({ catalog: async (_signal, count) => count === 1 ? first.promise : [row(later)] })
  const started = f.owner.start()
  await until(() => f.reads() === 1)
  for (let count = 0; count < 5; count++) f.changes()
  await turn()
  assert.equal(f.reads(), 1)
  first.resolve([row()])
  await started
  assert.equal(f.reads(), 2)
  assert.deepEqual(f.updates().map(value => value.nextDueAtMs), [Date.parse(later)])
  await f.owner.close()
})

test('a stale failed read does not cancel a newer valid catalog', async () => {
  const first = deferred()
  const f = fixture({ catalog: async (_signal, count) => count === 1 ? first.promise : [row()] })
  const started = f.owner.start()
  await until(() => f.reads() === 1)
  f.changes()
  first.reject(new Error('private-prompt'))
  await started
  assert.equal(f.updates().length, 1)
  assert.equal(f.updates()[0].state, 'ready')
  assert.deepEqual(f.warnings, [])
  await f.owner.close()
})

test('a commit queued after the read check but before native send still discards the old target', async () => {
  let limits = 0
  const f = fixture({ catalog: async (_signal, count) => [row(count === 1 ? due : later)],
    onLimits: () => { if (++limits === 3) queueMicrotask(() => f.changes()) } })
  await f.owner.start()
  assert.equal(f.reads(), 2)
  assert.deepEqual(f.updates().map(value => value.nextDueAtMs), [Date.parse(later)])
  assert.equal(f.updates()[0].revision, 2, 'Unsent revisions may be skipped; no native mutation is retried')
  await f.owner.close()
})

test('a change while a native update is pending waits for acknowledgment before reading again', async () => {
  const ack = deferred()
  const f = fixture({ catalog: async () => [row()], native: async (method, request) => {
    if (method.endsWith('.begin')) return { version: 1, generation }
    return request.revision === 1 ? ack.promise : acknowledgment(request)
  } })
  const started = f.owner.start()
  await until(() => f.updates().length === 1)
  f.changes()
  await turn()
  assert.equal(f.reads(), 1)
  ack.resolve(acknowledgment(f.updates()[0]))
  await started
  assert.equal(f.reads(), 2)
  assert.deepEqual(f.updates().map(value => value.revision), [1, 2])
  await f.owner.close()
})

test('catalog failure publishes unavailable, exposes no error content, and recovers only after a new change', async () => {
  let unavailable = true
  const f = fixture({ catalog: async () => {
    if (unavailable) throw Object.assign(new Error('private-prompt'), { code: 'private-session' })
    return [row()]
  } })
  await f.owner.start()
  assert.deepEqual(f.updates()[0], { version: 1, generation, revision: 1, state: 'unavailable',
    nextDueAtMs: null, activeCount: null, reason: 'catalog_read_failed' })
  await turn()
  assert.equal(f.reads(), 1, 'No generic retry loop is introduced')
  unavailable = false
  f.changes()
  await until(() => f.updates().length === 2)
  assert.equal(f.updates()[1].state, 'ready')
  assert.ok(!JSON.stringify(f.warnings).includes('private-'))
  await f.owner.close()
})

for (const [label, catalog] of [
  ['non-array', {}], ['missing state', [{ scheduledAt: due }]], ['unknown state', [row(due, 'paused')]],
  ['invalid calendar day', [row('2026-02-30T12:00:00.000Z')]], ['non-UTC target', [row('2026-10-29T12:00:00+08:00')]],
  ['invalid target type', [row(123)]],
]) test(`malformed catalog (${label}) never masquerades as an empty schedule list`, async () => {
  const f = fixture({ catalog: async () => catalog })
  await f.owner.start()
  assert.deepEqual(f.updates()[0], { version: 1, generation, revision: 1, state: 'unavailable',
    nextDueAtMs: null, activeCount: null, reason: 'invalid_catalog' })
  await f.owner.close()
})

for (const [label, begin] of [
  ['other version', { version: 2, generation }], ['invalid generation', { version: 1, generation: 'not-a-generation' }],
  ['extra fields', { version: 1, generation, prompt: 'private-prompt' }],
]) test(`native generation handshake is strict (${label})`, async () => {
  const f = fixture({ native: async () => begin })
  await assert.rejects(f.owner.start(), { code: 'schedule-wakeup/invalid-begin' })
  f.changes()
  await turn()
  assert.equal(f.reads(), 0)
  assert.equal(f.updates().length, 0)
  assert.ok(!JSON.stringify(f.warnings).includes('private-'))
  await f.owner.close()
})

for (const [label, update] of [
  ['old generation', request => ({ ...acknowledgment(request), generation: anotherGeneration })],
  ['old revision', request => ({ ...acknowledgment(request), revision: request.revision - 1 })],
  ['not accepted', request => ({ ...acknowledgment(request), accepted: false })],
  ['extra fields', request => ({ ...acknowledgment(request), prompt: 'private-prompt' })],
]) test(`unconfirmed update (${label}) blocks subsequent projection and remains uncertain during close`, async () => {
  const f = fixture({ catalog: async () => [row()], native: async (method, request) =>
    method.endsWith('.begin') ? { version: 1, generation } : update(request) })
  await assert.rejects(f.owner.start(), { code: 'schedule-wakeup/update-uncertain' })
  for (let count = 0; count < 3; count++) f.changes()
  await turn()
  assert.equal(f.reads(), 1)
  assert.equal(f.updates().length, 1)
  await assert.rejects(f.owner.close(), { code: 'schedule-wakeup/update-uncertain' })
  assert.ok(!JSON.stringify(f.warnings).includes('private-'))
})

test('native update rejection stops event-driven refreshes even after startup already completed', async () => {
  const f = fixture({ catalog: async () => [row()], native: async (method, request) => {
    if (method.endsWith('.begin')) return { version: 1, generation }
    if (request.revision === 2) throw new Error('private-prompt')
    return acknowledgment(request)
  } })
  await f.owner.start()
  f.changes()
  await until(() => f.warnings.length > 0)
  f.changes()
  await turn()
  assert.equal(f.reads(), 2)
  await assert.rejects(f.owner.close(), { code: 'schedule-wakeup/update-uncertain' })
})

test('close fences a late catalog result and awaits actual read settlement', async () => {
  const read = deferred()
  const f = fixture({ catalog: async () => read.promise })
  const started = f.owner.start()
  await until(() => f.reads() === 1)
  let closed = false
  const closing = f.owner.close().then(() => { closed = true })
  await turn()
  assert.equal(closed, false)
  read.resolve([row()])
  await Promise.all([started, closing])
  assert.equal(f.updates().length, 0)
  f.changes()
  await turn()
  assert.equal(f.reads(), 1)
  await assert.rejects(f.owner.start(), { code: 'schedule-wakeup/closed' })
})

test('close waits for an already sent update acknowledgment and does not cancel it locally', async () => {
  const ack = deferred()
  let writeSignal
  const f = fixture({ catalog: async () => [row()], native: async (method, request, signal) => {
    if (method.endsWith('.begin')) return { version: 1, generation }
    writeSignal = signal
    return ack.promise
  } })
  const started = f.owner.start()
  await until(() => f.updates().length === 1)
  let closed = false
  const closing = f.owner.close().then(() => { closed = true })
  await turn()
  assert.equal(writeSignal.aborted, false)
  assert.equal(closed, false)
  ack.resolve(acknowledgment(f.updates()[0]))
  await Promise.all([started, closing])
  assert.equal(f.updates().length, 1)
})

test('close cannot claim a pending write retired when its bounded budget expires', async () => {
  const ack = deferred()
  const f = fixture({ catalog: async () => [row()], closeTimeoutMs: 10,
    native: async method => method.endsWith('.begin') ? { version: 1, generation } : ack.promise })
  const started = assert.rejects(f.owner.start(), { code: 'schedule-wakeup/update-uncertain' })
  await until(() => f.updates().length === 1)
  await assert.rejects(f.owner.close(), { code: 'schedule-wakeup/close-unsettled' })
  ack.resolve(acknowledgment(f.updates()[0]))
  await started
  assert.equal(f.updates().length, 1)
})

test('catalog timeout publishes unavailable once and never overlaps a still running provider', async () => {
  const read = deferred()
  const f = fixture({ catalog: async () => read.promise, requestTimeoutMs: 10 })
  await f.owner.start()
  assert.equal(f.updates()[0].state, 'unavailable')
  assert.equal(f.updates()[0].reason, 'catalog_read_failed')
  f.changes()
  await turn()
  assert.equal(f.reads(), 1)
  read.resolve([row()])
  await f.owner.close()
  assert.equal(f.updates().length, 1)
})

test('native write timeout is not treated as permission to retry the same mutation', async () => {
  const ack = deferred()
  const f = fixture({ catalog: async () => [row()], requestTimeoutMs: 10,
    native: async method => method.endsWith('.begin') ? { version: 1, generation } : ack.promise })
  await assert.rejects(f.owner.start(), { code: 'schedule-wakeup/update-uncertain' })
  f.changes()
  ack.resolve(acknowledgment(f.updates()[0]))
  await assert.rejects(f.owner.close(), { code: 'schedule-wakeup/update-uncertain' })
  assert.equal(f.updates().length, 1)
})

test('unexpected subscription failures cannot inject their error code into diagnostics', async () => {
  const f = fixture({ subscribe: () => { throw Object.assign(new Error('private-prompt'), { code: 'private-session' }) } })
  await assert.rejects(f.owner.start())
  assert.ok(!JSON.stringify(f.warnings).includes('private-'))
  assert.equal(f.requests.length, 0)
  await f.owner.close()
})

test('closing before startup does not subscribe or send native requests', async () => {
  const f = fixture()
  const started = assert.rejects(f.owner.start(), { code: 'schedule-wakeup/closed' })
  await f.owner.close()
  await started
  assert.deepEqual(f.trace, [])
})
