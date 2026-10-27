import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'

const carriers = new WeakMap()
const methods = new Set(['native.scheduleWakeup.begin', 'native.scheduleWakeup.update'])
const fields = ['version', 'generation', 'revision', 'state', 'nextDueAtMs', 'activeCount', 'reason'].sort()
const keys = (value, expected) => {
  assert.ok(value !== null && typeof value === 'object' && !Array.isArray(value), 'Wake fixture requires an object')
  assert.deepEqual(Object.keys(value).sort(), expected, 'Wake fixture accepts only protocol fields')
}

/** Protocol acknowledgment only: this fixture never registers an OS alarm or grants wake permission. */
export function createScheduleWakeupNativeFixture() {
  const generation = randomUUID(), updates = []
  let beginCalls = 0, revision = 0
  return Object.freeze({
    handles: method => methods.has(method),
    request(method, params) {
      assert.ok(methods.has(method), 'Unsupported wake fixture method')
      if (method === 'native.scheduleWakeup.begin') {
        keys(params, [])
        beginCalls++
        return { version: 1, generation }
      }
      keys(params, fields)
      assert.ok(beginCalls > 0, 'Wake fixture update preceded begin')
      assert.equal(params.version, 1)
      assert.equal(params.generation, generation, 'Wake fixture belongs to another carrier')
      assert.ok(Number.isSafeInteger(params.revision) && params.revision > revision, 'Wake revision must strictly increase')
      assert.ok(['ready', 'unavailable'].includes(params.state))
      if (params.state === 'ready') {
        assert.equal(params.reason, null)
        assert.ok(Number.isInteger(params.activeCount) && params.activeCount >= 0 && params.activeCount <= 0x7fffffff)
        if (params.activeCount === 0) assert.equal(params.nextDueAtMs, null)
        else assert.ok(Number.isSafeInteger(params.nextDueAtMs) && params.nextDueAtMs >= 0)
      } else {
        assert.equal(params.activeCount, null)
        assert.equal(params.nextDueAtMs, null)
        assert.ok(['catalog_read_failed', 'invalid_catalog'].includes(params.reason))
      }
      revision = params.revision
      updates.push(Object.freeze({ ...params }))
      return { version: 1, generation, revision, accepted: true }
    },
    snapshot: () => ({ kind: 'protocol-only', systemAlarmsRegistered: 0, generation, beginCalls,
      updates: updates.map(value => ({ ...value })) }),
  })
}

/** A sender identifies one live carrier; a restarted runtime must supply a new sender. */
export function scheduleWakeupFixtureFor(send) {
  assert.equal(typeof send, 'function')
  let fixture = carriers.get(send)
  if (!fixture) { fixture = createScheduleWakeupNativeFixture(); carriers.set(send, fixture) }
  return fixture
}

/** Handle only the two explicit native requests, leaving all other carrier assertions intact. */
export function replyScheduleWakeupFixture(frame, send) {
  if (!methods.has(frame.method)) return false
  assert.equal(typeof frame.id, 'string', 'Wake fixture requires a native RPC identity')
  const result = scheduleWakeupFixtureFor(send).request(frame.method, frame.params ?? {})
  send({ id: frame.id, result })
  return true
}
