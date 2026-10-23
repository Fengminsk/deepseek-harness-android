import assert from 'node:assert/strict'
import test from 'node:test'
import { AppTaskCompletion } from '../runtime/task-completion.mjs'

function fixture(t) {
  const handlers = new Map(), notices = [], values = new Map(), goals = new Map()
  const ctx = {
    on(name, callback) {
      handlers.set(name, callback)
      return () => handlers.delete(name)
    },
    sessionProjections: { snapshot(session) { return { values: { pocketTasks: values.get(session.id) } } } },
    get(name) { return name === 'goals' ? { get: agent => goals.get(agent.session.id) } : undefined },
  }
  const completion = new AppTaskCompletion(ctx, { notify: (method, params) => notices.push({ method, params }) })
  t.after(() => completion.close())
  const agent = (id = 'session', origin = 'user') => ({
    session: { id, header: { origin } }, inbox: { nextTurn: [], nextStep: [] },
  })
  const status = (agent, status) => handlers.get('agent/status')?.({ agent, status })
  const event = (agent, type, data, seq = 0) => handlers.get('session/event')?.(agent.session, { type, data, seq })
  function turn(agent, { number = 1, startSeq = 0, reason = 'completed', step = true, message } = {}) {
    event(agent, 'turn/start', { turn: number }, startSeq)
    if (step) event(agent, 'step/start', { turn: number, step: 1 }, startSeq + 1)
    if (message) event(agent, 'assistant/message', { turn: number, message: { content: [{ type: 'text', text: message }] } }, startSeq + 2)
    values.set(agent.session.id, { turns: [{ turn: number, seq: startSeq, endSeq: startSeq + 4, reason: { kind: reason } }] })
    event(agent, 'turn/end', { turn: number, reason: { kind: reason } }, startSeq + 4)
  }
  return { ctx, completion, handlers, notices, values, goals, agent, status, turn, event }
}

test('completion preview uses only the current committed assistant text and stays one short line', t => {
  const f = fixture(t), a = f.agent()
  f.status(a, 'running')
  f.turn(a, { number: 1, startSeq: 0, message: 'old result' })
  f.turn(a, { number: 2, startSeq: 5, message: '## 已修复后台任务。\n详情在会话中。' })
  f.status(a, 'idle')
  assert.deepEqual(f.notices, [{ method: 'task.completed', params: {
    sessionId: 'session', turn: 2, endSeq: 9, preview: '已修复后台任务。',
  } }])
})

test('tool-only completion has no invented preview and failed turns reveal no text', t => {
  const f = fixture(t), a = f.agent()
  f.status(a, 'running')
  f.turn(a, { reason: 'error', message: 'private failure text' })
  f.status(a, 'idle')
  f.status(a, 'running')
  f.turn(a, { number: 2, startSeq: 5 })
  f.event(a, 'assistant/message', { turn: 1, message: { content: [{ type: 'text', text: 'stale' }] } }, 10)
  f.status(a, 'idle')
  assert.deepEqual(f.notices, [{ method: 'task.completed', params: { sessionId: 'session', turn: 2, endSeq: 9 } }])
})

test('successful whole driver emits one metadata-only notice after idle, not each completed turn', t => {
  const f = fixture(t), a = f.agent()
  f.status(a, 'running')
  f.turn(a)
  assert.deepEqual(f.notices, [])
  f.turn(a, { number: 2, startSeq: 5 })
  f.status(a, 'idle')
  f.status(a, 'idle')
  assert.deepEqual(f.notices, [{ method: 'task.completed', params: { sessionId: 'session', turn: 2, endSeq: 9 } }])
})

test('history/reconnect idle, no-step turns and incomplete state never claim completion', t => {
  const f = fixture(t), a = f.agent()
  f.turn(a)
  f.status(a, 'idle')
  f.status(a, 'running')
  f.status(a, 'idle')
  f.status(a, 'running')
  f.turn(a, { step: false })
  f.status(a, 'idle')
  f.status(a, 'running')
  f.event(a, 'turn/start', { turn: 2 }, 9)
  f.event(a, 'step/start', { turn: 2, step: 1 }, 10)
  f.status(a, 'idle')
  assert.deepEqual(f.notices, [])
})

test('failed, aborted, unknown, limited and cold-recovered endings stay silent', t => {
  const f = fixture(t), a = f.agent()
  for (const reason of ['error', 'aborted', 'interrupted', 'forked', 'max-tokens', 'blocked', 'plugin-exit']) {
    f.status(a, 'running')
    f.turn(a, { reason })
    f.status(a, 'idle')
  }
  assert.deepEqual(f.notices, [])
})

test('queued messages, subagents and unfinished goals cannot become successful task notices', t => {
  const f = fixture(t), a = f.agent(), sub = f.agent('child', 'subagent')
  f.status(sub, 'running'); f.turn(sub); f.status(sub, 'idle')
  for (const phase of ['active', 'blocked', 'paused']) {
    f.goals.set('session', { phase })
    f.status(a, 'running'); f.turn(a); f.status(a, 'idle')
  }
  f.goals.set('session', { phase: 'complete' })
  a.inbox.nextTurn.push({ id: 'pending' })
  f.status(a, 'running'); f.turn(a); f.status(a, 'idle')
  a.inbox.nextTurn.length = 0
  a.inbox.nextStep.push({ id: 'steering' })
  f.status(a, 'running'); f.turn(a); f.status(a, 'idle')
  assert.deepEqual(f.notices, [])
  a.inbox.nextStep.length = 0
  f.status(a, 'running'); f.turn(a); f.status(a, 'idle')
  assert.equal(f.notices.length, 1)
})

test('concurrent sessions remain separate and old Agent disposal cannot remove its replacement', t => {
  const f = fixture(t), old = f.agent(), next = f.agent(), other = f.agent('other')
  f.status(old, 'running'); f.turn(old)
  f.status(next, 'running'); f.turn(next, { number: 2, startSeq: 5 })
  f.status(other, 'running'); f.turn(other)
  f.handlers.get('agent/disposed')({ agent: old })
  f.status(old, 'idle')
  f.status(other, 'idle'); f.status(next, 'idle')
  assert.deepEqual(f.notices.map(value => value.params.sessionId), ['other', 'session'])
})

test('error/disposal/close and untrusted projection failures do not report success', t => {
  const f = fixture(t), a = f.agent()
  for (const type of ['agent/error', 'agent/disposed']) {
    f.status(a, 'running'); f.turn(a)
    f.handlers.get(type)({ agent: a })
    f.status(a, 'idle')
  }
  f.ctx.sessionProjections.snapshot = () => { throw new Error('private diagnostic') }
  f.status(a, 'running'); f.turn(a); f.status(a, 'idle')
  assert.equal(f.notices.length, 1)
  assert.equal(f.notices[0].method, 'notifications.error')
  assert.ok(!JSON.stringify(f.notices).includes('private diagnostic'))
  f.completion.close()
  assert.equal(f.handlers.size, 0)
})

test('notification transport failure is contained and cannot stop the Agent driver', t => {
  const f = fixture(t), a = f.agent()
  const warnings = []
  t.mock.method(console, 'warn', text => warnings.push(text))
  f.completion.transport.notify = () => { throw new Error('private transport detail') }
  f.status(a, 'running'); f.turn(a)
  assert.doesNotThrow(() => f.status(a, 'idle'))
  assert.deepEqual(warnings, ['Task completion notification transport is unavailable'])
  assert.deepEqual(f.notices, [])
})
