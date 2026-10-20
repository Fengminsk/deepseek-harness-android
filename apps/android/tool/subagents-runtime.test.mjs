import assert from 'node:assert/strict'
import test from 'node:test'
import { AppSubagents, subagentAddressFromHeader } from '../runtime/subagents.mjs'

const address = { parentSessionId: 'parent', childSessionId: 'child', mode: 'continuable' }
const message = (id, rpcId) => ({ id, source: { kind: 'user', rpcId }, content: [{ type: 'text', text: id }] })
const snapshot = (overrides = {}) => ({
  type: 'snapshot', header: { id: 'child', parentSession: 'parent', origin: 'subagent' },
  cursor: 10, hasMore: true, records: [],
  projections: { asOfSeq: 10, values: { subagent: { mode: 'continuable', seq: 0 }, inbox: { 'next-turn': [], 'next-step': [] } } },
  ...overrides,
})

function fixture(t, options = {}) {
  const agents = new Map(options.agents ?? [['parent', { status: 'idle' }]])
  const calls = [], follows = [], tasks = [], catalogReads = []
  let returns = 0
  const state = new AppSubagents({
    agents: { get: id => agents.get(id) },
    subagents: { listChildren: async (id, signal) => {
      catalogReads.push({ id, signal })
      return options.catalog ?? []
    } },
  }, {
    invoke: async (...args) => {
      calls.push(args)
      if (options.invoke) return options.invoke(...args)
      if (args[0] === 'session') return { records: [], hasMore: false }
      return args[1] === 'prompt' ? { messageId: 'accepted' } : { accepted: true }
    },
    follow: (request, signal) => {
      follows.push({ request, signal })
      return options.follow?.(request, signal) ?? {
        async *[Symbol.asyncIterator]() {
          try { yield options.snapshot ?? snapshot() } finally { returns++ }
          throw new Error('inspect must not consume the follow tail')
        },
      }
    },
    taskSession: async params => { tasks.push(params); return { sessionId: params.sessionId, history: [], pending: [] } },
    presentEvent: event => ({ ...event, presented: true }),
  })
  t.after(() => state.close())
  return { state, agents, calls, follows, tasks, catalogReads, returns: () => returns }
}

test('header navigation never upgrades an unvalidated descriptor into write authority', () => {
  assert.deepEqual(subagentAddressFromHeader({ id: 'c', parentSession: 'p', origin: 'subagent' }),
    { parentSessionId: 'p', childSessionId: 'c', mode: 'unknown' })
  for (const header of [null, {}, { id: 'c', parentSession: 'p' },
    { id: 'c', origin: 'subagent' }, { id: '', parentSession: 'p', origin: 'subagent' }]) {
    assert.equal(subagentAddressFromHeader(header), null)
  }
})

test('catalog preserves original order, direct-child identity and external non-session entries', async t => {
  const catalog = [
    { id: 'child', mode: 'continuable', createdAt: 1, label: 'child' },
    { id: 'external', mode: 'external', createdAt: 2 },
    { id: 'old', mode: 'unknown', createdAt: 3 },
  ]
  const h = fixture(t, { catalog, agents: [['child', { status: 'running' }]] })
  const first = await h.state.call('catalog', { parentSessionId: 'parent', limit: 2 })
  assert.equal(first.parentAvailable, false)
  assert.equal(first.nextOffset, 2)
  assert.deepEqual(first.entries, [
    { ...catalog[0], address, attached: true, running: true },
    { ...catalog[1], address: null, attached: false, running: false },
  ])
  const second = await h.state.call('catalog', { parentSessionId: 'parent', offset: first.nextOffset, limit: 2 })
  assert.equal(second.nextOffset, null)
  assert.equal(second.entries[0].address.mode, 'unknown')
  await h.state.call('catalog', { parentSessionId: 'child' })
  assert.deepEqual(h.catalogReads.map(read => read.id), ['parent', 'parent', 'child'])
  assert.ok(h.catalogReads.every(read => read.signal.aborted), 'completed reads release their signal lifetime')
  assert.deepEqual(h.calls, [])
  assert.deepEqual(h.follows, [])
})

test('inspect opens only an addressed read, closes its iterator and uses the validated descriptor', async t => {
  const original = snapshot({ records: [{ type: 'event', event: { type: 'assistant/attempt', seq: 10, data: {} } }] })
  const h = fixture(t, { snapshot: original })
  const result = await h.state.call('inspect', { address: { ...address, mode: 'unknown' }, maxMessages: 3 })
  assert.deepEqual(result.address, address)
  assert.deepEqual(h.follows[0].request, { address: { kind: 'subagent', ...address, mode: 'unknown' }, maxMessages: 3 })
  assert.equal(h.returns(), 1)
  assert.equal(h.follows[0].signal.aborted, true)
  assert.deepEqual(h.tasks, [{ sessionId: 'child' }])
  assert.deepEqual(result.capabilities, {
    parentAvailable: true, attached: false, running: false,
    canPrompt: true, canInterrupt: false, readOnlyReason: null,
  })
  assert.equal(result.snapshot.records[0].event.presented, true)
  assert.equal(original.records[0].event.presented, undefined)
  assert.equal(result.submission, null)
  assert.deepEqual(h.calls, [], 'history never invokes session.send or continuation')
})

test('one-shot is read-only and a detached parent does not remove interruption of a running child', async t => {
  const h = fixture(t, { agents: [['child', { status: 'running' }]] })
  const result = await h.state.call('inspect', { address })
  assert.deepEqual(result.capabilities, {
    parentAvailable: false, attached: true, running: true,
    canPrompt: false, canInterrupt: true, readOnlyReason: 'parent-unavailable',
  })
  const oneShot = snapshot()
  oneShot.projections.values.subagent.mode = 'one-shot'
  const one = fixture(t, { snapshot: oneShot })
  assert.equal((await one.state.call('inspect', { address: { ...address, mode: 'one-shot' } }))
    .capabilities.readOnlyReason, 'one-shot')
})

test('failed original parent/child validation does not fall back to ordinary session/task history', async t => {
  const h = fixture(t, { follow: () => ({
    [Symbol.asyncIterator]() {
      return { async next() {
        throw Object.assign(new Error('wrong parent'), { code: 'subagent/unauthorized', details: { childSessionId: 'child' } })
      } }
    },
  }) })
  assert.deepEqual(await h.state.call('inspect', { address }), {
    _pocket_error: { code: 'subagent/unauthorized', message: 'wrong parent', details: { childSessionId: 'child' } },
  })
  assert.deepEqual(h.tasks, [])
  assert.deepEqual(h.calls, [])
})

test('page preserves the fixed inclusive cut and exclusive beforeSeq without off-by-one edits', async t => {
  const h = fixture(t, { invoke: async () => ({
    hasMore: true, records: [{ type: 'event', event: { type: 'assistant/attempt', seq: 8, data: {} } }],
  }) })
  const result = await h.state.call('page', { address, throughSeq: 10, beforeSeq: 9, maxMessages: 2 })
  assert.deepEqual(h.calls[0].slice(0, 3), ['session', 'page', { request: {
    address: { kind: 'subagent', ...address }, throughSeq: 10, beforeSeq: 9, maxMessages: 2,
  } }])
  assert.equal(h.calls[0][3].aborted, true)
  assert.equal(result.records[0].event.seq, 8)
  assert.equal(result.records[0].event.presented, true)
  assert.equal(result.hasMore, true)
})

test('submission observation accepts inbox, splice and user-message proof but never invents a negative receipt', async t => {
  for (const source of ['inbox', 'splice', 'message', 'absent', 'different-source']) {
    const value = snapshot()
    const input = message('accepted-id', 'pending-id')
    if (source === 'inbox') value.projections.values.inbox['next-turn'].push(input)
    if (source === 'splice') value.records.push({ type: 'event', event: { type: 'agent/inbox/spliced', data: { inserted: [input] } } })
    if (source === 'message' || source === 'different-source') {
      if (source === 'different-source') input.source.kind = 'system'
      value.records.push({ type: 'event', event: { type: 'user/message', data: input } })
    }
    const h = fixture(t, { snapshot: value })
    const result = await h.state.call('inspect', { address, requestId: 'pending-id' })
    assert.deepEqual(result.submission, source === 'absent' || source === 'different-source'
      ? { requestId: 'pending-id', state: 'not-observed' }
      : { requestId: 'pending-id', state: 'observed', messageId: 'accepted-id' })
    assert.deepEqual(h.calls, [], 'reconciliation only observes')
  }
})

test('queue and steer use only the original subagent prompt with exact request attribution and draft', async t => {
  const h = fixture(t)
  for (const delivery of ['queue', 'steer']) {
    assert.deepEqual(await h.state.call('send', { address, requestId: delivery, text: '  explicit draft\n', delivery }),
      { messageId: 'accepted' })
    assert.deepEqual(h.calls.at(-1), ['subagents', 'prompt', { request: {
      ...address, requestId: delivery, delivery, content: [{ type: 'text', text: '  explicit draft\n' }],
    } }])
  }
  assert.deepEqual(h.tasks, [])
  assert.deepEqual(h.follows, [])
})

test('unknown submission failure forwards its original code exactly once without replay or probing', async t => {
  const h = fixture(t, { invoke: async () => { throw Object.assign(new Error('disconnected after acceptance'), { code: 'gateway/cancelled' }) } })
  const result = await h.state.call('send', { address, requestId: 'uncertain', text: 'draft', delivery: 'queue' })
  assert.equal(result._pocket_error.code, 'gateway/cancelled')
  assert.equal(h.calls.length, 1)
  assert.deepEqual(h.follows, [])
  assert.deepEqual(h.tasks, [])
})

test('interrupt uses original parent authority without requiring a live parent or ordinary cancel', async t => {
  const h = fixture(t, { agents: [] })
  assert.deepEqual(await h.state.call('interrupt', { address }), { accepted: true })
  assert.deepEqual(h.calls, [['subagents', 'interruptByParent', address]])
  assert.deepEqual(h.follows, [])
})

test('malformed boundaries and read-only mode writes fail before any original operation', async t => {
  const h = fixture(t)
  for (const [method, params] of [
    ['catalog', { parentSessionId: '', limit: 10 }],
    ['catalog', { parentSessionId: 'parent', offset: -1 }],
    ['catalog', { parentSessionId: 'parent', limit: 101 }],
    ['inspect', { address: { ...address, mode: 'external' } }],
    ['inspect', { address, maxMessages: 0 }],
    ['inspect', { address, requestId: '' }],
    ['page', { address, throughSeq: -2 }],
    ['page', { address, throughSeq: 0, beforeSeq: -1 }],
    ['send', { address, requestId: 'x', text: '  ', delivery: 'queue' }],
    ['send', { address, requestId: '', text: 'draft', delivery: 'queue' }],
    ['send', { address, requestId: 'x', text: 'draft', delivery: 'replace' }],
    ['send', { address: { ...address, mode: 'unknown' }, requestId: 'x', text: 'draft', delivery: 'queue' }],
    ['interrupt', { address: { ...address, mode: 'one-shot' } }],
    ['constructor', {}],
  ]) assert.equal((await h.state.call(method, params))._pocket_error.code, 'gateway/bad-request', method)
  assert.deepEqual(h.calls, [])
  assert.deepEqual(h.follows, [])
  assert.deepEqual(h.catalogReads, [])
})

test('shutdown aborts and awaits an in-flight opening and closes its original iterator', async t => {
  const opened = Promise.withResolvers()
  let released = false
  const h = fixture(t, { follow: (_request, signal) => ({
    async *[Symbol.asyncIterator]() {
      try {
        opened.resolve()
        await new Promise((_, reject) => signal.addEventListener('abort', () => {
          reject(Object.assign(new Error('cancelled'), { code: 'gateway/cancelled' }))
        }, { once: true }))
        yield snapshot()
      } finally {
        await new Promise(resolve => setImmediate(resolve))
        released = true
      }
    },
  }) })
  const pending = h.state.call('inspect', { address })
  await opened.promise
  await h.state.close()
  assert.equal(released, true)
  assert.equal((await pending)._pocket_error.code, 'gateway/cancelled')
  assert.equal(h.state.reads.size, 0)
  assert.equal((await h.state.call('catalog', { parentSessionId: 'parent' }))._pocket_error.code, 'gateway/cancelled')
})
