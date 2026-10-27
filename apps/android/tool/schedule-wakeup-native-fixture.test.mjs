import assert from 'node:assert/strict'
import test from 'node:test'
import { createScheduleWakeupNativeFixture, replyScheduleWakeupFixture, scheduleWakeupFixtureFor } from './schedule-wakeup-native-fixture.mjs'

const begin = owner => owner.request('native.scheduleWakeup.begin', {})
const empty = generation => ({ version: 1, generation, revision: 1, state: 'ready', nextDueAtMs: null, activeCount: 0, reason: null })

test('each carrier owns one UUID, strict monotonic acknowledgments and no system alarm claims', () => {
  const a = createScheduleWakeupNativeFixture(), b = createScheduleWakeupNativeFixture()
  const { generation } = begin(a)
  assert.notEqual(begin(b).generation, generation)
  assert.equal(begin(a).generation, generation)
  a.request('native.scheduleWakeup.update', empty(generation))
  a.request('native.scheduleWakeup.update', { ...empty(generation), revision: 3, activeCount: 1, nextDueAtMs: 1234 })
  assert.equal(a.snapshot().systemAlarmsRegistered, 0)
  assert.deepEqual(a.snapshot().updates.map(row => row.revision), [1, 3])
  const copy = a.snapshot(); copy.updates[0].prompt = 'must not be retained'
  assert.equal(a.snapshot().updates[0].prompt, undefined)
})

test('the adapter handles exactly two request methods and leaves unrelated native failures visible', () => {
  const replies = [], send = frame => replies.push(frame)
  assert.equal(replyScheduleWakeupFixture({ id: 'x', method: 'native.storage.root' }, send), false)
  assert.equal(replyScheduleWakeupFixture({ id: 'b', method: 'native.scheduleWakeup.begin', params: {} }, send), true)
  const generation = replies[0].result.generation
  assert.equal(replyScheduleWakeupFixture({ id: 'u', method: 'native.scheduleWakeup.update', params: empty(generation) }, send), true)
  assert.equal(scheduleWakeupFixtureFor(send).snapshot().updates.length, 1)
  assert.notEqual(scheduleWakeupFixtureFor(() => {}).snapshot().generation, generation)
  assert.throws(() => replyScheduleWakeupFixture({ method: 'native.scheduleWakeup.begin' }, send))
})

test('wrong generation, old revision and private fields are rejected without poisoning the next valid update', () => {
  const f = createScheduleWakeupNativeFixture(), { generation } = begin(f)
  const valid = empty(generation)
  for (const mutation of [
    { generation: begin(createScheduleWakeupNativeFixture()).generation }, { revision: 0 }, { revision: 1.5 },
    { version: 2 }, { prompt: 'private-prompt' }, { activeCount: -1 }, { activeCount: 1 },
    { nextDueAtMs: 10 }, { state: 'unknown' }, { reason: 'private-error' },
  ]) assert.throws(() => f.request('native.scheduleWakeup.update', { ...valid, ...mutation }))
  assert.equal(f.snapshot().updates.length, 0)
  f.request('native.scheduleWakeup.update', valid)
  assert.throws(() => f.request('native.scheduleWakeup.update', valid))
})

test('unavailable stays distinct from an empty catalog', () => {
  const f = createScheduleWakeupNativeFixture(), { generation } = begin(f)
  const update = { ...empty(generation), state: 'unavailable', activeCount: null, reason: 'catalog_read_failed' }
  f.request('native.scheduleWakeup.update', update)
  assert.deepEqual(f.snapshot().updates, [update])
  assert.throws(() => f.request('native.scheduleWakeup.update', { ...update, revision: 2, activeCount: 0 }))
})

test('an update cannot arrive before begin or smuggle fields in the handshake', () => {
  const f = createScheduleWakeupNativeFixture()
  assert.throws(() => f.request('native.scheduleWakeup.update', empty(f.snapshot().generation)))
  assert.throws(() => f.request('native.scheduleWakeup.begin', { prompt: 'private-prompt' }))
  assert.throws(() => f.request('native.scheduleWakeup.other', {}))
  assert.equal(f.snapshot().beginCalls, 0)
})
