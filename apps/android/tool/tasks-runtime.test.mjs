import assert from 'node:assert/strict'
import test from 'node:test'
const modules = new URL('../../../.cache/android/runtime-bundle/node_modules/', import.meta.url)
const { Context } = await import(new URL('@deepseek-ai/cordis/lib/index.js', modules))
const { default: Sessions, SessionId } = await import(new URL('@deepseek-ai/dsh-session/lib/index.js', modules))
const { default: Projections } = await import(new URL('@deepseek-ai/dsh-session-projection/lib/index.js', modules))
const { default: Titles } = await import(new URL('@deepseek-ai/dsh-session-title/lib/index.js', modules))
const { AppTasks } = await import(new URL('@minnnng/dsh-android-runtime/tasks.mjs', modules))

async function harness(t, options = {}) {
  const ctx = new Context()
  await ctx.plugin(Sessions)
  await ctx.plugin(Projections)
  await ctx.plugin(Titles, { fallbackMaxWords: 8, fallbackMaxBytes: 64, maxTitleBytes: 256 })
  const agents = new Map(), notices = [], requests = [], calls = []
  const controller = {
    cancel(params) { calls.push(['cancel', params]); return { accepted: true } },
    updateQueue(params) { calls.push(['updateQueue', params]); return Promise.resolve({ accepted: true }) },
    async projections() { throw new Error('Unexpected exact read') },
  }
  const context = {
    sessionProjections: ctx.sessionProjections,
    sessions: ctx.sessions,
    agents: { list: () => [...agents.values()], get: id => agents.get(id) },
    sessionPersistence: { list: async () => [] },
    sessionController: controller,
    on: (event, callback) => ctx.on(event, callback),
    get: name => options[name],
  }
  const tasks = new AppTasks(context, { notify: (method, data) => notices.push({ method, data }) },
    { interactions: () => ({ requests }) })
  t.after(async () => { tasks.close(); await ctx.fiber.dispose() })
  return { ctx, tasks, agents, notices, requests, calls, controller, context }
}

function agent(session, status = 'running') {
  return { id: session.id, session, status, inbox: { nextTurn: [], nextStep: [] } }
}

test('task lists and details follow the original scalar title projection and live renames', async t => {
  const h = await harness(t)
  const session = h.ctx.sessions.create(SessionId('named-task'))
  h.agents.set(session.id, agent(session, 'idle'))
  const list = () => h.tasks.list()
  const snapshot = () => h.ctx.sessionProjections.snapshot(session, ['pocketTasks', 'inbox', 'title'])
  assert.equal((await list()).sessions[0].title, 'named-task', 'untitled sessions retain their identity')
  h.ctx.sessionTitle.rename(session, 'Background review')
  assert.equal(snapshot().values.title, 'Background review')
  assert.equal((await list()).sessions[0].title, 'Background review')
  const revision = h.notices.at(-1).data.revision
  h.ctx.sessionTitle.rename(session, 'Renamed background review')
  assert.ok(h.notices.at(-1).data.revision > revision)
  assert.equal((await list()).sessions[0].title, 'Renamed background review')
  assert.equal(h.tasks.project(String(session.id), snapshot(), 'live').title, 'Renamed background review')
  assert.deepEqual(h.calls, [])
})

test('cached and cold task titles preserve original checkpoints without activating or replaying an Agent', async t => {
  const first = await harness(t)
  const session = first.ctx.sessions.create(SessionId('cold-named-task'))
  first.ctx.sessionTitle.rename(session, 'Checkpoint title')
  session.append('turn/start', { turn: 1 })
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })
  const checkpoint = first.ctx.sessionProjections.checkpoint(session)
  const cachedThrough = session.seq - 1
  first.ctx.sessionTitle.rename(session, 'Later durable title')
  const restored = await harness(t)
  const replayed = restored.ctx.sessions.create(session.id, { seed: session.snapshotEvents() })
  const recovered = restored.ctx.sessionProjections.snapshot(replayed, ['pocketTasks', 'inbox', 'title'])
  const reader = await harness(t, { sessionProjectionCache: {
    cachedSnapshot(header, keys) {
      assert.equal(header.id, session.id)
      assert.ok(keys.includes('title'))
      return { asOfSeq: cachedThrough, values: reader.ctx.sessionProjections.viewCheckpoint(checkpoint) }
    },
  } })
  reader.context.sessionPersistence.list = async () => [{ header: session.header }]
  const list = await reader.tasks.list()
  assert.equal(list.sessions[0].observation, 'cached')
  assert.equal(list.sessions[0].title, 'Checkpoint title')
  reader.controller.projections = async ({ sessionId }) => {
    assert.equal(sessionId, session.id)
    return { kind: 'sequenced', ...recovered }
  }
  const exact = await reader.tasks.session({ sessionId: session.id })
  assert.equal(exact.observation, 'sequenced')
  assert.equal(exact.title, 'Later durable title')
  assert.equal(exact.history[0].status, 'completed')
  assert.equal(reader.ctx.sessions.get(session.id), undefined)
  assert.equal(reader.agents.size, 0)
  assert.deepEqual(reader.calls, [])
})

test('real Session projection retains distinct turn outcomes and failure facts across a reconstructed history', async t => {
  const first = await harness(t)
  const session = first.ctx.sessions.create(SessionId('history'))
  const reasons = [
    { kind: 'completed' }, { kind: 'error', error: { code: 'MODEL_FAILED', message: 'fixture failure' } },
    { kind: 'aborted', reason: { kind: 'user' } }, { kind: 'interrupted' }, { kind: 'max-tokens' },
  ]
  const events = []
  reasons.forEach((reason, index) => {
    events.push(session.append('turn/start', { turn: index + 1 }))
    events.push(session.append('turn/end', { turn: index + 1, reason }))
  })
  const before = first.ctx.sessionProjections.snapshot(session, ['pocketTasks'])
  const second = await harness(t)
  const restored = second.ctx.sessions.create(SessionId('history-restored'), { seed: events })
  const after = second.ctx.sessionProjections.snapshot(restored, ['pocketTasks'])
  assert.deepEqual(after.values.pocketTasks, before.values.pocketTasks)
  const projected = second.tasks.project(String(restored.id), after, 'sequenced')
  assert.deepEqual(projected.history.map(row => row.status), ['limited', 'interrupted', 'cancelled', 'failed', 'completed'])
  assert.equal(projected.history.find(row => row.status === 'failed').reason.error.message, 'fixture failure')
  assert.equal(second.tasks.summary().summary.running, 0)
})

test('only current agents and blocking requests count as running, queued or waiting', async t => {
  const h = await harness(t)
  const a = agent(h.ctx.sessions.create(SessionId('live')))
  a.inbox.nextTurn.push({ id: 'queued-one' })
  h.agents.set(a.id, a)
  assert.deepEqual(h.tasks.summary().summary, { running: 1, queued: 1, waiting: 0, failed: 0, backgroundJobs: null, packageOperations: null })
  h.requests.push({ id: 'q', sessionId: 'live', kind: 'question', state: 'open' })
  h.tasks.interactionsChanged()
  assert.equal(h.notices.at(-1).data.summary.waiting, 1)
  assert.equal(h.notices.at(-1).data.summary.running, 0)
  h.requests.push({ id: 'approval', sessionId: 'live', kind: 'approval' })
  assert.equal(h.tasks.summary().summary.waiting, 2)
  h.requests.pop()
  h.requests[0].state = 'continued'
  assert.equal(h.tasks.summary().summary.running, 1)
  h.agents.clear()
  assert.equal(h.tasks.summary().summary.queued, 0)
  assert.equal(h.tasks.summary().summary.waiting, 0)
})

test('cached open turns stay unverified and exact recovered records are interrupted without restoring an Agent', async t => {
  const h = await harness(t)
  const cached = { asOfSeq: 3, values: { pocketTasks: { turns: [{ turn: 1, seq: 0, time: 1 }], dropped: [], jobs: [] },
    inbox: { 'next-turn': [{ id: 'pending', content: [{ type: 'text', text: 'retained' }] }] } } }
  assert.equal(h.tasks.project('cold', cached, 'cached').history[0].status, 'unverified')
  assert.equal(h.tasks.project('cold', cached, 'cached').pending[0].status, 'suspended')
  h.controller.projections = async ({ sessionId }) => {
    assert.equal(sessionId, 'cold')
    return { kind: 'sequenced', ...cached, values: { ...cached.values,
      pocketTasks: { ...cached.values.pocketTasks, turns: [{ turn: 1, seq: 0, time: 1, reason: { kind: 'interrupted' } }] } } }
  }
  assert.equal((await h.tasks.session({ sessionId: 'cold' })).history[0].status, 'interrupted')
  assert.deepEqual(h.calls, [])
  assert.equal(h.agents.size, 0)
  assert.throws(() => h.tasks.removeQueued({ sessionId: 'cold', itemId: 'pending' }), /not attached/)
})

test('listing cache misses remain explicit and do not read histories or activate Agents', async t => {
  const h = await harness(t)
  h.context.sessionPersistence.list = async () => [{ header: { id: 'old', createdAt: 1 } }]
  const page = await h.tasks.list()
  assert.equal(page.sessions[0].observation, 'unavailable')
  assert.equal(page.sessions[0].historyAvailable, false)
  assert.equal(page.summary.running, 0)
})

test('child tasks retain their direct parent address without generic session routing or activation', async t => {
  const h = await harness(t)
  const header = { id: 'child', origin: 'subagent', parentSession: 'parent', createdAt: 2 }
  h.context.sessionPersistence.list = async () => [
    { header }, { header: { id: 'ordinary', createdAt: 1 } },
  ]
  const page = await h.tasks.list()
  assert.deepEqual(page.sessions[0].subagent,
    { parentSessionId: 'parent', childSessionId: 'child', mode: 'unknown' })
  assert.equal(Object.hasOwn(page.sessions[1], 'subagent'), false)
  const live = agent({ id: 'child', header })
  h.agents.set(live.id, live)
  assert.deepEqual(h.tasks.summary().active[0].subagent, page.sessions[0].subagent)
  assert.equal(h.tasks.summary().summary.running, 1)
  assert.deepEqual(h.calls, [])
})

test('cancellation and removal delegate separately to the original controller', async t => {
  const h = await harness(t)
  const a = agent(h.ctx.sessions.create(SessionId('queued')))
  a.inbox.nextTurn.push({ id: 'one' }, { id: 'two' })
  h.agents.set(a.id, a)
  h.tasks.cancel({ sessionId: 'queued' })
  await h.tasks.removeQueued({ sessionId: 'queued', itemId: 'two' })
  assert.deepEqual(h.calls, [['cancel', { sessionId: 'queued' }],
    ['updateQueue', { sessionId: 'queued', itemId: 'two', action: { kind: 'remove' } }]])
  assert.equal(a.inbox.nextTurn.length, 2)
})

test('durable queue cancellations are not inferred as completed turns', async t => {
  const h = await harness(t)
  const session = h.ctx.sessions.create(SessionId('discard'))
  session.append('agent/inbox/spliced', { target: 'next-turn', start: 0, removedCount: 2, inserted: [], outcome: 'canceled' })
  const snapshot = h.ctx.sessionProjections.snapshot(session, ['pocketTasks'])
  const rows = h.tasks.project('discard', snapshot, 'sequenced').history
  assert.equal(rows.length, 1)
  assert.equal(rows[0].kind, 'discarded')
  assert.equal(rows[0].status, 'cancelled')
  assert.equal(rows[0].count, 2)
})

test('job baseline includes jobs predating observation; stopping still requires background execution', async t => {
  let listener, closed = false
  const records = [{ id: 'first', status: 'running' }, { id: 'second', status: 'stopping' }, { id: 'ended', status: 'completed' }]
  const h = await harness(t, { jobs: { snapshot: () => records,
    events: { subscribe(filter, callback) { assert.deepEqual(filter, { owners: 'all' }); listener = callback; return () => { closed = true } } } } })
  assert.equal(h.tasks.summary().summary.backgroundJobs, 2)
  records[0].status = 'completed'
  listener({ type: 'settled' })
  assert.equal(h.notices.at(-1).data.summary.backgroundJobs, 1)
  h.tasks.close()
  assert.equal(closed, true)
})

test('unfinished historical job never claims to be alive after process loss', async t => {
  const h = await harness(t)
  const session = h.ctx.sessions.create(SessionId('job-history'))
  session.append('job/registered', { jobId: 'old-job', owner: 'job-history', kind: 'bash', label: 'fixture', startedAt: 1 })
  const snapshot = h.ctx.sessionProjections.snapshot(session, ['pocketTasks'])
  const row = h.tasks.project('job-history', snapshot, 'sequenced').history[0]
  assert.equal(row.status, 'unconfirmed')
  assert.equal(row.cancellable, false)
})

test('original plugin operation snapshots and events update an independent package count', async t => {
  const operations = []
  const h = await harness(t, { pluginManager: { packageOperationsSnapshot: () => operations } })
  const initial = h.tasks.summary()
  assert.equal(initial.summary.packageOperations, 0)
  const operation = { id: 'original-operation', kind: 'install' }
  operations.push(operation)
  await h.ctx.parallel('plugin-manager/package-operation', operation, 'started')
  const started = h.notices.at(-1).data
  assert.equal(started.epoch, initial.epoch)
  assert.ok(started.revision > initial.revision)
  assert.deepEqual(started.summary, { running: 0, queued: 0, waiting: 0, failed: 0, backgroundJobs: null, packageOperations: 1 })
  operations.pop()
  await h.ctx.parallel('plugin-manager/package-operation', operation, 'settled')
  assert.equal(h.notices.at(-1).data.summary.packageOperations, 0)
  assert.ok(h.notices.at(-1).data.revision > started.revision)
  assert.deepEqual(h.calls, [])
  const replacement = await harness(t, { pluginManager: { packageOperationsSnapshot: () => [] } })
  assert.notEqual(replacement.tasks.summary().epoch, started.epoch)
  assert.equal(replacement.tasks.summary().summary.packageOperations, 0)
})
