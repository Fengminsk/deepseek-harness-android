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

test('native turn window uses original projection cursor and cold-safe page, never full inspect', async () => {
  const calls = []
  const events = Array.from({ length: 600 }, (_, seq) => ({ seq, type: 'session/title', data: { title: `${seq}` } }))
  const history = new AppSessionHistory({
    inspect() { assert.fail('bounded navigation must not inspect the complete history') },
    async projections(request) {
      calls.push(['projections', request.sessionId])
      return { kind: 'sequenced', asOfSeq: 599, values: { turnOutline: [
        { turn: 1, seq: 0, prompt: 'first', response: 'done' },
        { turn: 2, seq: 300, prompt: 'second', response: '' },
      ] } }
    },
    async page(request) {
      calls.push(['page', request])
      const end = request.beforeSeq ?? 600
      const first = Math.max(0, end - 300)
      return { records: events.slice(first, end).map(event => ({ type: 'event', event })), hasMore: first > 0 }
    },
  })
  try {
    const latest = await history.readWindow({ sessionId: 's' })
    assert.equal(latest.throughSeq, 599)
    assert.deepEqual(latest.events.map(event => event.seq), Array.from({ length: 300 }, (_, at) => at + 300))
    assert.deepEqual(latest.turns.map(turn => turn.turn), [1, 2])
    assert.equal(latest.hasMore, true)
    const older = await history.readWindow({ sessionId: 's', throughSeq: latest.throughSeq, beforeSeq: latest.firstSeq })
    assert.equal(older.firstSeq, 0)
    assert.equal(older.hasMore, false)
    assert.equal('turns' in older, false)
    assert.deepEqual(calls.map(call => call[0]), ['projections', 'page', 'page'])
    assert.equal(calls[1][1].turnWindow.minTurns, 2)
  } finally { history.close() }
})

test('native window truncates dense tool-only history by event and byte budgets without skipping a cursor', async () => {
  const events = Array.from({ length: 1100 }, (_, seq) => ({ seq, type: 'tool/result', data: { text: 'x'.repeat(100) } }))
  const history = new AppSessionHistory({
    async projections() { return { kind: 'sequenced', asOfSeq: 1099, values: {} } },
    async page({ beforeSeq }) {
      const end = beforeSeq ?? events.length
      return { records: events.slice(0, end).map(event => ({ type: 'event', event })), hasMore: false }
    },
  })
  try {
    const first = await history.readWindow({ sessionId: 's' })
    assert.equal(first.events.length, 500)
    assert.equal(first.firstSeq, 600)
    assert.equal(first.hasMore, true)
    const second = await history.readWindow({ sessionId: 's', throughSeq: first.throughSeq, beforeSeq: first.firstSeq })
    assert.equal(second.events.length, 500)
    assert.equal(second.firstSeq, 100)
    assert.equal(second.hasMore, true)
    const third = await history.readWindow({ sessionId: 's', throughSeq: first.throughSeq, beforeSeq: second.firstSeq })
    assert.equal(third.firstSeq, 0)
    assert.equal(third.events.length, 100)
    assert.equal(third.hasMore, false)
  } finally { history.close() }
})

test('malformed projection and stalled older page fail without an invented navigation item', async () => {
  const history = new AppSessionHistory({
    async projections() { return { kind: 'sequenced', asOfSeq: 20, values: { turnOutline: [
      { turn: 2, seq: 10, prompt: 'ok', response: '' },
      { turn: 1, seq: 0, prompt: 'out of order', response: '' },
    ] } } },
    async page() { return { records: [{ type: 'event', event: { seq: 10, type: 'turn/start', data: { turn: 2 } } }], hasMore: true } },
  })
  try {
    assert.deepEqual((await history.turnOutline({ sessionId: 's' })).turns, [])
    await assert.rejects(history.readWindow({ sessionId: 's', throughSeq: 20, beforeSeq: 10 }),
      error => error.code === 'SESSION_HISTORY_INVALID_PAGE')
    await assert.rejects(history.readWindow({ sessionId: 's', beforeSeq: 10 }), TypeError)
  } finally { history.close() }
})
