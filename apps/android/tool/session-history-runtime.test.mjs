import assert from 'node:assert/strict'
import test from 'node:test'

const staged = new URL('../../../.cache/android/runtime-bundle/node_modules/', import.meta.url)
const { AppSessionHistory, readSessionHistory } = await import(new URL('@minnnng/dsh-android-runtime/session-history.mjs', staged))

test('history pages preserve original interrupted tool outcomes and turn closure', async () => {
  const events = [
    ...Array.from({ length: 200 }, (_, seq) => ({ seq, type: 'session/title', data: { title: 'fixture' } })),
    { seq: 200, type: 'tool/result', data: { message: { toolCallId: 'one', isError: true }, error: { code: 'TOOL_OUTCOME_UNKNOWN' } } },
    { seq: 201, type: 'turn/end', data: { turn: 1, reason: { kind: 'interrupted' } } },
  ]
  const calls = []
  const controller = { async inspect(id) { calls.push(id); return { events } } }
  const first = await readSessionHistory(controller, { sessionId: 'one' })
  const second = await readSessionHistory(controller, { sessionId: 'one', offset: 200 })
  assert.equal(first.events.length, 200)
  assert.deepEqual(second.events, events.slice(200))
  assert.deepEqual(calls, ['one', 'one'])
  assert.deepEqual((await readSessionHistory(controller, { sessionId: 'one', offset: 202 })).events, [])
})

test('invalid page addresses do not reach the original history reader', async () => {
  const controller = { inspect() { assert.fail('invalid input reached the controller') } }
  for (const params of [{}, { sessionId: ' ' }, { sessionId: 's', offset: -1 }, { sessionId: 's', offset: 0.5 }]) {
    await assert.rejects(readSessionHistory(controller, params), TypeError)
  }
})

test('an unavailable original observation stays a failure instead of reading a raw fallback', async () => {
  const failure = Object.assign(new Error('unavailable'), { code: 'session/projections-unavailable' })
  await assert.rejects(readSessionHistory({ inspect: async () => { throw failure } }, { sessionId: 'one' }),
    error => error === failure)
})

test('a long read inspects once, holds a stable prefix through concurrent append, and releases on final page', async () => {
  const events = Array.from({ length: 403 }, (_, seq) => ({ seq, type: 'session/title', data: { title: `event-${seq}` } }))
  let inspections = 0
  const history = new AppSessionHistory({ async inspect() {
    inspections++
    return { events }
  } })
  try {
    const first = await history.read({ sessionId: 'one' })
    assert.equal(first.events.length, 200)
    assert.equal(typeof first.snapshot, 'string')
    events.push({ seq: 403, type: 'session/title', data: { title: 'appended-later' } })
    const second = await history.read({ sessionId: 'one', offset: 200, snapshot: first.snapshot })
    assert.equal(second.events.length, 200)
    assert.equal(second.snapshot, first.snapshot)
    const last = await history.read({ sessionId: 'one', offset: 400, snapshot: first.snapshot })
    assert.equal(last.events.length, 3)
    assert.equal(last.events.at(-1).seq, 402)
    assert.equal(last.snapshot, undefined)
    assert.equal(inspections, 1, 'the original controller must not reread the entire log per page')
    await assert.rejects(history.read({ sessionId: 'one', offset: 403, snapshot: first.snapshot }),
      error => error.code === 'SESSION_HISTORY_SNAPSHOT_EXPIRED')
    assert.equal(events.length, 404, 'reading must not rewrite the original event log')
  } finally { history.close() }
})

test('concurrent readers keep independent cuts and cannot borrow another session token', async () => {
  const events = Array.from({ length: 201 }, (_, seq) => ({ seq, type: 'session/title', data: { title: `${seq}` } }))
  const history = new AppSessionHistory({ async inspect() { return { events } } })
  try {
    const first = await history.read({ sessionId: 'one' })
    events.push({ seq: 201, type: 'session/title', data: { title: 'new' } })
    const second = await history.read({ sessionId: 'one' })
    assert.notEqual(first.snapshot, second.snapshot)
    assert.deepEqual((await history.read({ sessionId: 'one', offset: 200, snapshot: first.snapshot })).events.map(e => e.seq), [200])
    assert.deepEqual((await history.read({ sessionId: 'one', offset: 200, snapshot: second.snapshot })).events.map(e => e.seq), [200, 201])
    await assert.rejects(history.read({ sessionId: 'two', offset: 200, snapshot: first.snapshot }),
      error => error.code === 'SESSION_HISTORY_SNAPSHOT_EXPIRED')
  } finally { history.close() }
})

test('abandoned leases expire, explicit release and disconnect cleanup drop retained pages', async () => {
  const events = Array.from({ length: 201 }, (_, seq) => ({ seq, type: 'session/title', data: { title: `${seq}` } }))
  let now = 0
  const history = new AppSessionHistory({ async inspect() { return { events } } }, { leaseMs: 1000, now: () => now })
  try {
    const first = await history.read({ sessionId: 'one' })
    assert.deepEqual(history.release({ sessionId: 'two', snapshot: first.snapshot }), { released: false })
    assert.deepEqual(history.release({ sessionId: 'one', snapshot: first.snapshot }), { released: true })
    await assert.rejects(history.read({ sessionId: 'one', offset: 200, snapshot: first.snapshot }),
      error => error.code === 'SESSION_HISTORY_SNAPSHOT_EXPIRED')
    const second = await history.read({ sessionId: 'one' })
    now += 1001
    await assert.rejects(history.read({ sessionId: 'one', offset: 200, snapshot: second.snapshot }),
      error => error.code === 'SESSION_HISTORY_SNAPSHOT_EXPIRED')
    const third = await history.read({ sessionId: 'one' })
    history.releaseAll()
    await assert.rejects(history.read({ sessionId: 'one', offset: 200, snapshot: third.snapshot }),
      error => error.code === 'SESSION_HISTORY_SNAPSHOT_EXPIRED')
  } finally { history.close() }
})

test('retention budget is bounded and fails visibly instead of silently changing snapshots', async () => {
  const events = Array.from({ length: 201 }, (_, seq) => ({ seq, type: 'session/title', data: { title: 'x'.repeat(100) } }))
  const history = new AppSessionHistory({ async inspect() { return { events } } }, { maxRetainedBytes: 1000 })
  try {
    await assert.rejects(history.read({ sessionId: 'one' }), error => error.code === 'SESSION_HISTORY_TOO_LARGE')
  } finally { history.close() }
})
