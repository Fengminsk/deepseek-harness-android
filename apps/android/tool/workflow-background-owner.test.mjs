import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeWorkflowPrivateOwner } from '../runtime/native-workflow-private-owner.mjs'

const runId = '00000000-0000-4000-8000-000000000001'
const sessionId = 'parent-session'
const prepared = () => ({ kind: 'workflow', runId, sessionId,
  program: 'return { ok: true }', deadlineMillis: 5000,
  meta: { name: 'Review', description: 'Review evidence' },
  scope: { workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
    fileCallLimit: 0, networkCallLimit: 0 } })

function fixture(native, overrides = {}) {
  const events = []
  const session = { id: sessionId, append(type, data) { events.push({ type, data }) } }
  const parent = { id: sessionId, session }
  const compositions = new Map()
  const jobs = new Map()
  const registry = { start(spec) {
    assert.equal(spec.owner, sessionId)
    const id = `workflow-${jobs.size + 1}`
    const job = { id, spec, status: 'running', progress: [], result: null }
    const hooks = spec.run({ id, append() {}, updateProgress(line) { job.progress.push(line) } })
    job.hooks = hooks
    jobs.set(id, job)
    job.done = hooks.done.then(outcome => {
      job.status = outcome.status
      job.result = outcome.result
      return outcome
    })
    return id
  } }
  const ctx = {
    agents: { get(id) { return id === parent.id ? parent : undefined } },
    sessions: { get(id) { return id === sessionId ? session : undefined }, async flush() { return true } },
    sessionPersistence: { async open() { return { async read() { return { events: [...events] } },
      async close() {} } } },
    agentPresets: { async register({ id, plugins }) {
      compositions.set(id, { id, modules: [{ moduleName: plugins[0].name }], leakedServices: [] })
      return async () => { compositions.delete(id) }
    }, inspectCompositions() { return [...compositions.values()] } },
    subagents: {}, tools: {},
    async plugin() { return { async dispose() {} } },
    get(name) { return name === 'jobs' ? registry
      : ['sessionPersistence', 'sessionQuery'].includes(name) ? {} : undefined },
  }
  const calls = []
  const transport = { async request(method, params) {
    calls.push(method)
    if (method === 'native.workflow.admit') return { runId, token: 'native-token' }
    if (method === 'native.workflow.bindCallbacks') return true
    if (method === 'native.workflow.execute') return native.execute(params)
    if (method === 'native.workflow.cancel') return native.cancel(params)
    if (method === 'native.workflow.settle') return native.settle(params)
    if (method === 'native.workflow.release') return true
    throw new Error(`unexpected native call: ${method}`)
  } }
  const callbacks = overrides.callbacks
    ?? { async bind() { return { runId, async close() {} } }, async dispose() {} }
  return { owner: createNativeWorkflowPrivateOwner(ctx, callbacks, transport),
    parent, ctx, jobs, events, calls }
}

test('background owner commits a session run and job result under the exact parent', async () => {
  const f = fixture({ async execute() { return true }, async cancel() { return true },
    async settle() { return { runId, sessionId, state: 'COMPLETED',
      outputJson: '{"value":{"ok":true},"stopReason":"completed","agentsStarted":0}',
      requiresReview: false } } })
  assert.throws(() => f.owner.startBackgroundDsl({ prepared: prepared(),
    parent: { ...f.parent } }), /exact live parent/)
  assert.equal(f.jobs.size, 0)
  const started = f.owner.startBackgroundDsl({ prepared: prepared(), parent: f.parent })
  assert.deepEqual(started, { kind: 'background', jobId: 'workflow-1', runId })
  const outcome = await f.jobs.get(started.jobId).done
  assert.equal(outcome.status, 'completed')
  assert.match(outcome.result, /"ok": true/)
  assert.deepEqual(f.events.map(event => event.type),
    ['tool-workflow/run-start', 'tool-workflow/run-end'])
  assert.deepEqual(f.calls, ['native.workflow.admit', 'native.workflow.execute',
    'native.workflow.settle', 'native.workflow.release'])
  await f.owner.dispose()
})

test('job kill waits for native cancellation before settling', async () => {
  let finishExecution, finishCancellation
  const execution = new Promise(resolve => { finishExecution = resolve })
  const cancellation = new Promise(resolve => { finishCancellation = resolve })
  const f = fixture({ execute: () => execution, cancel: () => cancellation,
    async settle() { return { runId, sessionId, state: 'CANCELLED',
      outputJson: null, requiresReview: false } } })
  const started = f.owner.startBackgroundDsl({ prepared: prepared(), parent: f.parent })
  const job = f.jobs.get(started.jobId)
  while (!f.calls.includes('native.workflow.execute')) await new Promise(resolve => setTimeout(resolve, 1))
  job.hooks.cancel('user cancelled')
  while (!f.calls.includes('native.workflow.cancel')) await new Promise(resolve => setTimeout(resolve, 1))
  finishExecution(true)
  let settled = false
  job.done.then(() => { settled = true })
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(settled, false)
  finishCancellation(true)
  const outcome = await job.done
  assert.equal(outcome.status, 'killed')
  assert.equal(job.result, undefined)
  assert.equal((await f.owner.inspectRun({ sessionId, runId })).state, 'cancelled')
  await f.owner.dispose()
})

test('owner disposal aborts a detached job and waits for native retirement', async () => {
  let finishExecution, finishCancellation
  const execution = new Promise(resolve => { finishExecution = resolve })
  const cancellation = new Promise(resolve => { finishCancellation = resolve })
  const f = fixture({ execute: () => execution, cancel: () => cancellation,
    async settle() { return { runId, sessionId, state: 'CANCELLED',
      outputJson: null, requiresReview: false } } })
  const started = f.owner.startBackgroundDsl({ prepared: prepared(), parent: f.parent })
  while (!f.calls.includes('native.workflow.execute')) await new Promise(resolve => setTimeout(resolve, 1))
  const closing = f.owner.dispose()
  while (!f.calls.includes('native.workflow.cancel')) await new Promise(resolve => setTimeout(resolve, 1))
  finishExecution(true)
  let disposed = false
  closing.then(() => { disposed = true })
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(disposed, false)
  finishCancellation(true)
  await closing
  assert.equal((await f.jobs.get(started.jobId).done).status, 'killed')
})

test('lost native retirement settles the job failed and leaves the run for cold review', async () => {
  const f = fixture({ async execute() { throw new Error('native lost') },
    async cancel() { throw new Error('native lost') },
    async settle() { throw new Error('native lost') } })
  const started = f.owner.startBackgroundDsl({ prepared: prepared(), parent: f.parent })
  const outcome = await f.jobs.get(started.jobId).done
  assert.equal(outcome.status, 'failed')
  assert.match(outcome.detail, /requires review/i)
  assert.equal(outcome.result, undefined)
  assert.equal(f.events.some(event => event.type === 'tool-workflow/run-end'), false)
  await f.owner.dispose()
})

test('an unanswered native execute ends the tool call at its deadline', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const f = fixture({ execute: () => new Promise(() => {}), async cancel() { return true },
    async settle() { return { runId, sessionId, state: 'CANCELLED',
      outputJson: null, requiresReview: false } } })
  const started = f.owner.startBackgroundDsl({ prepared: prepared(), parent: f.parent })
  await new Promise(resolve => setImmediate(resolve))
  t.mock.timers.tick(5_000 + 30_000)
  const outcome = await f.jobs.get(started.jobId).done
  assert.equal(outcome.status, 'failed')
  assert.match(outcome.detail, /native\.workflow\.execute did not answer within 35000 ms/)
  assert.deepEqual(f.calls.slice(0, 2), ['native.workflow.admit', 'native.workflow.execute'])
  assert.ok(f.calls.includes('native.workflow.cancel'))
  assert.ok(f.calls.includes('native.workflow.settle'))
  await f.owner.dispose()
})

test('an unanswered child retirement keeps the failure explicit and still settles', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const f = fixture({ async execute() { return true }, async cancel() { return true },
    async settle() { return { runId, sessionId, state: 'CANCELLED',
      outputJson: null, requiresReview: false } } },
  { callbacks: { async bind() { return { runId, async close() { return new Promise(() => {}) } } },
    async dispose() {} } })
  const started = f.owner.startBackgroundDsl({ prepared: prepared(), parent: f.parent })
  await new Promise(resolve => setImmediate(resolve))
  t.mock.timers.tick(30_000)
  const outcome = await f.jobs.get(started.jobId).done
  assert.equal(outcome.status, 'failed')
  assert.match(outcome.detail, /workflow child retirement did not answer within 30000 ms/)
  assert.ok(f.calls.includes('native.workflow.settle'))
  assert.equal(f.calls.includes('native.workflow.release'), false)
  await f.owner.dispose()
})

test('an aborted workflow stops waiting for native execute and settles cancelled', async () => {
  const controller = new AbortController()
  const f = fixture({ execute: () => new Promise(() => {}), async cancel() { return true },
    async settle() { return { runId, sessionId, state: 'CANCELLED',
      outputJson: null, requiresReview: false } } })
  const running = f.owner.runDsl({ prepared: prepared(), parent: f.parent, signal: controller.signal })
  await new Promise(resolve => setImmediate(resolve))
  controller.abort(new Error('user cancelled'))
  await assert.rejects(running, /user cancelled/)
  assert.ok(f.calls.includes('native.workflow.cancel'))
  assert.ok(f.calls.includes('native.workflow.settle'))
  await f.owner.dispose()
})
