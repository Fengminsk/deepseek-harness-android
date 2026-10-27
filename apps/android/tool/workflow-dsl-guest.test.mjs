import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import vm from 'node:vm'
import { NativeWorkflowGuestCallbacks } from '../runtime/native-workflow-guest-callbacks.mjs'
import { WORKFLOW_DSL_GUEST_PROGRAM, workflowDslNativeProgram } from '../runtime/workflow-dsl-guest.mjs'

const runId = '00000000-0000-4000-8000-000000000001'
const token = 'app-owned-token'
const scope = { workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
  fileCallLimit: 0, networkCallLimit: 0 }

function prepared(body, limits = {}) {
  return { kind: 'workflow', runId, sessionId: 'android-1793060921975320-627842147', program: body, args: { task: 'review' },
    meta: { name: 'Review', description: 'Review task' }, deadlineMillis: 5000,
    maxTotalAgents: limits.total ?? 3, maxConcurrentAgents: limits.concurrent ?? 2, scope }
}

async function run(body, options = {}) {
  const source = prepared(body, options.limits)
  const events = []
  const disposed = []
  const activated = []
  const reservations = []
  let callbackCount = 0
  const controller = new AbortController()
  const callbacks = new NativeWorkflowGuestCallbacks({ request: async (name) => {
    assert.equal(name, 'native.workflow.bindCallbacks')
    return true
  } })
  const bound = await callbacks.bind({ prepared: source, admission: { runId, token },
    authorizeChild: async (_request, _signal, childId) => {
      assert.equal(childId, reservations.at(-1))
      return true
    },
    activateChild: async request => {
      const childId = reservations.shift()
      activated.push(request)
      return { childId, result: options.childResult ?? Promise.resolve({
        output: [{ type: 'text', text: `answer: ${request.prompt}` }], stopReason: 'completed',
      }), dispose: async () => { disposed.push(childId) } }
    }, onProgress: async event => {
      events.push(event)
      if (options.abortOnStart && event.type === 'agent-start') controller.abort()
    }, signal: controller.signal })
  const realm = vm.createContext({})
  const parse = vm.runInContext('JSON.parse', realm)
  const guest = vm.runInContext(`(${WORKFLOW_DSL_GUEST_PROGRAM})`, realm)
  const host = { callAsync: async frame => {
    const parsed = JSON.parse(JSON.stringify(frame))
    callbackCount++
    const childId = parsed.action === 'WORKFLOW_START_CHILD' ? randomUUID() : undefined
    if (childId) reservations.push(childId)
    const reply = await callbacks.call({ ...parsed, runId, token,
      ...(childId ? { childId } : {}) })
    return parse(JSON.stringify(reply))
  } }
  try {
    const result = JSON.parse(JSON.stringify(await guest(parse('{}'), host)))
    await bound.close()
    return { result, events, disposed, activated, callbackCount }
  } finally {
    await callbacks.dispose()
  }
}

test('native admission receives a fixed guest function and no model source in input', () => {
  const admission = workflowDslNativeProgram(prepared('return args.task'))
  assert.equal(admission.program, WORKFLOW_DSL_GUEST_PROGRAM)
  assert.equal(admission.inputJson, '{}')
  assert.doesNotMatch(admission.program, /return args\.task/)
  assert.ok(Buffer.byteLength(admission.program) < 64 * 1024)
  assert.equal(workflowDslNativeProgram({ ...prepared('return 1'), deadlineMillis: 120_000 })
    .deadlineMillis, 120_000)
  assert.throws(() => workflowDslNativeProgram({ ...prepared('return 1'), deadlineMillis: 120_001 }),
    /requires an admitted, ungranted workflow/)
  assert.throws(() => workflowDslNativeProgram({ ...prepared('return 1'),
    scope: { ...scope, exactHosts: ['example.org'] } }), /ungranted/)
})

test('DSL executes args, phases, children and per-item pipeline with ordered progress', async () => {
  const { result, events, disposed, activated, callbackCount } = await run(`
    phase('Inspect'); log(args.task);
    const replies = await pipeline(['one', 'two'], item => item.toUpperCase(),
      async value => agent(value));
    return { replies, task: args.task };
  `)
  assert.deepEqual(result, { value: { replies: ['answer: ONE', 'answer: TWO'], task: 'review' },
    stopReason: 'completed', agentsStarted: 2 })
  assert.deepEqual(events.map(event => event.type), [
    'phase', 'log', 'agent-start', 'agent-start', 'agent-end', 'agent-end',
  ])
  assert.equal(activated.length, 2)
  assert.equal(disposed.length, 2)
  assert.equal(callbackCount, 13)
})

test('parallel converts ordinary task failure to null and keeps successful child output', async () => {
  const { result } = await run(`return await parallel([
    () => { throw new Error('ordinary'); },
    () => agent('safe'),
  ]);`)
  assert.deepEqual(result, { value: [null, 'answer: safe'], stopReason: 'completed', agentsStarted: 1 })
})

test('structured child result flows through agent() without parsing model text', async () => {
  const schema = { type: 'object', properties: { finding: { type: 'string' } },
    required: ['finding'], additionalProperties: false }
  const complete = await run(`return await agent('x', {schema:${JSON.stringify(schema)}});`, {
    childResult: Promise.resolve({ stopReason: 'completed',
      output: [{ type: 'text', text: '{"finding":"fake"}' }],
      structured: { finding: 'authoritative' } }),
  })
  assert.deepEqual(JSON.parse(JSON.stringify(complete.activated[0].schema)), schema)
  assert.deepEqual(complete.result.value, { finding: 'authoritative' })
  assert.equal(complete.events.at(-1)?.info.outcome, 'completed')
  const missing = await run(`return await agent('x', {schema:${JSON.stringify(schema)}});`, {
    childResult: Promise.resolve({ stopReason: 'completed',
      output: [{ type: 'text', text: '{"finding":"fake"}' }] }),
  })
  assert.equal(missing.result.value, null)
  assert.equal(missing.events.at(-1)?.info.outcome, 'failed')
})

test('invalid schema and total-child overrun fail closed even when the script catches them', async () => {
  const schema = await run(`try { await agent('x', {schema:{type:'string'}}) } catch {} return 'ignored';`)
  assert.equal(schema.result.stopReason, 'error')
  assert.equal(schema.result.error.code, 'UNSUPPORTED_SCHEMA')
  assert.equal(schema.activated.length, 0)
  const cap = await run(`await agent('first'); try { await agent('second') } catch {} return 1;`,
    { limits: { total: 1, concurrent: 1 } })
  assert.equal(cap.result.stopReason, 'error')
  assert.equal(cap.result.error.code, 'AGENT_CAP')
  assert.equal(cap.activated.length, 1)
})

test('item cap, unsupported option, result cycles and unjoined work fail closed', async () => {
  const cap = await run(`try { await parallel(Array(33).fill(() => 1)) } catch {} return 1;`)
  assert.equal(cap.result.error.code, 'ITEM_CAP')
  const unsupported = await run(`await agent('x', {isolation:'workspace-write'})`)
  assert.equal(unsupported.result.error.code, 'UNSUPPORTED_OPTION')
  const cycle = await run(`const a={}; a.self=a; return a;`)
  assert.equal(cycle.result.error.code, 'INVALID_JSON')
  const dropped = await run(`agent('unjoined'); return 1;`)
  assert.equal(dropped.result.error.code, 'UNJOINED_WORK')
  assert.equal(dropped.disposed.length, 1)
})

test('shared plain values materialize in each result branch while cycles still fail', async () => {
  const shared = await run(`
    const item = { finding: 'checked' };
    const values = await pipeline([item, item], value => value);
    return { first: item, second: item, values };
  `)
  assert.deepEqual(shared.result, { value: {
    first: { finding: 'checked' }, second: { finding: 'checked' },
    values: [{ finding: 'checked' }, { finding: 'checked' }],
  }, stopReason: 'completed', agentsStarted: 0 })
  const cycle = await run(`const item = { finding: 'checked' }; item.self = item; return item;`)
  assert.equal(cycle.result.stopReason, 'error')
  assert.equal(cycle.result.error.code, 'INVALID_JSON')
})

test('model body cannot access Node or the private host callback', async () => {
  const { result } = await run(`return {
    process: typeof process, require: typeof require, host: typeof host,
    callAsync: typeof globalThis.callAsync, args: args.task
  };`)
  assert.deepEqual(result.value, { process: 'undefined', require: 'undefined',
    host: 'undefined', callAsync: 'undefined', args: 'review' })
})

test('callback limit and unsupported TypeScript syntax produce errors without extra host calls', async () => {
  const many = await run(`for (let i = 0; i < 130; i++) log('entry ' + i); return 1;`)
  assert.equal(many.result.stopReason, 'error')
  assert.equal(many.result.error.code, 'CALL_CAP')
  assert.equal(many.callbackCount, 128)
  const ts = await run(`const value: number = 1; return value;`)
  assert.equal(ts.result.stopReason, 'error')
  assert.equal(ts.result.error.code, 'SCRIPT_ERROR')
  assert.equal(ts.activated.length, 0)
})

test('cancellation retires the active child and does not publish a completed result', async () => {
  const cancelled = await run(`return await agent('long work');`, {
    abortOnStart: true,
    childResult: new Promise(() => {}),
  })
  assert.equal(cancelled.result.stopReason, 'error')
  assert.equal(cancelled.disposed.length, 1)
  assert.equal(cancelled.events.filter(event => event.type === 'agent-start').length, 1)
  assert.equal(cancelled.events.filter(event => event.type === 'agent-end'
    && event.info.outcome === 'completed').length, 0)
})

test('native callback sequencing and App reservation are still enforced below DSL', async () => {
  const source = prepared('return 1')
  const callbacks = new NativeWorkflowGuestCallbacks({ request: async () => true })
  const bound = await callbacks.bind({ prepared: source, admission: { runId, token },
    authorizeChild: async () => true,
    activateChild: async () => ({ childId: randomUUID(), result: Promise.resolve({ output: [],
      stopReason: 'completed' }), dispose: async () => {} }), onProgress: async () => {} })
  try {
    await assert.rejects(callbacks.call({ runId, token, callId: 2,
      action: 'WORKFLOW_BEGIN', value: {} }), /sequence/)
    await callbacks.call({ runId, token, callId: 1, action: 'WORKFLOW_BEGIN', value: {} })
    await assert.rejects(callbacks.call({ runId, token, callId: 2,
      action: 'WORKFLOW_START_CHILD', value: { prompt: 'x' }, childId: 'invented' }), /reservation/)
    await assert.rejects(callbacks.call({ runId, token, callId: 2,
      action: 'WORKFLOW_START_CHILD', value: { prompt: 'x' }, childId: randomUUID() }),
    /durable App reservation/)
  } finally { await bound.close(); await callbacks.dispose() }
})
