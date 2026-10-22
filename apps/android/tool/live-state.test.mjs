import assert from 'node:assert/strict'
import test from 'node:test'
const modules = new URL('../../../.cache/android/runtime-bundle/node_modules/', import.meta.url)
const { AppLiveState, presentSessionEvent } = await import(new URL('@minnnng/dsh-android-runtime/live-state.mjs', modules))

function harness(t) {
  const handlers = new Map(), notices = []
  const agent = { session: { id: 'fixture' }, status: 'running' }
  const attached = [agent]
  const state = new AppLiveState({
    on: (name, callback) => handlers.set(name, callback),
    agents: { list: () => attached },
  }, { notify: (method, data) => notices.push({ method, data }) })
  t.after(() => state.close())
  return { agent, state, notices, handlers, send: frame => state.receive(agent, frame),
    disposeAgent() {
      attached.splice(attached.indexOf(agent), 1)
      handlers.get('agent/disposed')({ agent })
    } }
}

test('normal idle remains attached, while disposal notification and reconnect both remove Agent membership', t => {
  const { agent, state, handlers, notices, disposeAgent } = harness(t)
  agent.status = 'idle'
  handlers.get('agent/status')({ agent, status: 'idle' })
  assert.deepEqual(notices.at(-1), {
    method: 'session.status', data: { sessionId: 'fixture', status: 'idle', revision: 1 },
  })
  assert.deepEqual(state.snapshot().statuses, { fixture: 'idle' })
  disposeAgent()
  assert.deepEqual(notices.at(-1), {
    method: 'session.status', data: { sessionId: 'fixture', status: 'idle', attached: false, revision: 2 },
  })
  assert.deepEqual(state.snapshot().statuses, {})
})

test('many deltas publish one canonical reasoning/text prefix while a reconnect sees the latest prefix', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { state, send, notices } = harness(t)
  send({ type: 'start', attemptId: 'one', revision: 1, turn: 1, step: 2 })
  send({ type: 'chunk', attemptId: 'one', revision: 2, index: 0,
    chunk: { type: 'reasoning-delta', index: 0, text: 'plan' } })
  send({ type: 'chunk', attemptId: 'one', revision: 3, index: 1,
    chunk: { type: 'text-delta', index: 1, text: 'hello' } })
  send({ type: 'chunk', attemptId: 'one', revision: 4, index: 2,
    chunk: { type: 'text-delta', index: 1, text: ' world' } })
  send({ type: 'chunk', attemptId: 'one', revision: 5, index: 3,
    chunk: { type: 'tool-call-delta', index: 2, id: 'call', name: 'shell', argumentsDelta: '{"command":' } })
  assert.equal(notices.length, 1)
  const content = [{ type: 'reasoning', text: 'plan' }, { type: 'text', text: 'hello world' }]
  assert.deepEqual(state.snapshot().liveMessages.fixture.content, content)
  t.mock.timers.tick(49)
  assert.equal(notices.length, 1)
  t.mock.timers.tick(1)
  assert.equal(notices.length, 2)
  assert.deepEqual(notices[1].data.value.content, content)
  assert.equal(notices[1].method, 'session.live')
})

test('abandoned attempts preserve partial text and late frames cannot finish a replacement attempt', t => {
  const { state, send } = harness(t)
  send({ type: 'start', attemptId: 'one', revision: 1, turn: 1, step: 1 })
  send({ type: 'chunk', attemptId: 'one', revision: 2, index: 0,
    chunk: { type: 'text-delta', index: 0, text: 'partial' } })
  send({ type: 'end', attemptId: 'one', revision: 3, index: 1, outcome: { kind: 'abandoned' } })
  assert.equal(state.snapshot().liveMessages.fixture.interrupted, true)
  send({ type: 'start', attemptId: 'two', revision: 4, turn: 1, step: 1 })
  send({ type: 'chunk', attemptId: 'two', revision: 5, index: 0,
    chunk: { type: 'text-delta', index: 0, text: 'replacement' } })
  send({ type: 'end', attemptId: 'one', revision: 6, index: 1,
    outcome: { kind: 'committed', eventType: 'assistant/message', seq: 9 } })
  send({ type: 'chunk', attemptId: 'two', revision: 5, index: 0,
    chunk: { type: 'text-delta', index: 0, text: 'duplicate' } })
  assert.deepEqual(state.snapshot().liveMessages.fixture.content, [{ type: 'text', text: 'replacement' }])
  send({ type: 'end', attemptId: 'two', revision: 7, index: 1,
    outcome: { kind: 'committed', eventType: 'assistant/message', seq: 10 } })
  assert.deepEqual(state.snapshot().liveMessages, {})
})

test('Agent disposal exposes interrupted partial text, and close cancels any pending publication', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { state, send, notices, handlers, agent, disposeAgent } = harness(t)
  send({ type: 'start', attemptId: 'one', revision: 1, turn: 1, step: 1 })
  send({ type: 'chunk', attemptId: 'one', revision: 2, index: 0,
    chunk: { type: 'text-delta', index: 0, text: 'partial' } })
  disposeAgent()
  assert.equal(state.snapshot().liveMessages.fixture.interrupted, true)
  assert.deepEqual(state.snapshot().statuses, {})
  assert.equal(notices.at(-1).data.attached, false)
  const count = notices.length
  state.close()
  t.mock.timers.tick(100)
  handlers.get('agent/status')({ agent, status: 'running' })
  handlers.get('api-session/error')('fixture', 'after close')
  handlers.get('agent/disposed')({ agent })
  assert.equal(notices.length, count)
  assert.deepEqual(state.snapshot().liveMessages, {})
})

test('durable canceled attempts use the same canonical safe-prefix assembler without changing log data', () => {
  const event = { seq: 9, type: 'assistant/attempt', data: { turn: 1, step: 2, stream: [
    { type: 'reasoning-chunks', time0: 1, index: 0, dt: [], texts: ['thinking'] },
    { type: 'text-chunks', time0: 2, index: 1, dt: [1], texts: ['partial', ' reply'] },
    { type: 'tool-call-chunks', time0: 4, index: 2, dt: [], id: 'call', name: 'shell', args: ['{"command":'] },
  ] } }
  const before = structuredClone(event)
  assert.deepEqual(presentSessionEvent(event).assistantContent, [
    { type: 'reasoning', text: 'thinking' }, { type: 'text', text: 'partial reply' },
  ])
  assert.deepEqual(event, before)
})
