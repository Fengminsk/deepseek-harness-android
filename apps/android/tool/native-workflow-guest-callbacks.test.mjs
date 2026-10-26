import assert from 'node:assert/strict'
import test from 'node:test'
import { NativeWorkflowGuestCallbacks } from '../runtime/native-workflow-guest-callbacks.mjs'

const runId = '00000000-0000-4000-8000-000000000079'
const token = 'app-private-workflow-token'
const childId = '00000000-0000-4000-8000-00000000007a'
const prepared = { kind: 'workflow', runId, program: 'return 1', args: { input: 1 },
  deadlineMillis: 5000, meta: { name: 'review' }, maxTotalAgents: 2, maxConcurrentAgents: 1 }

function setup(options = {}) {
  const methods = []
  const events = []
  const disposed = []
  const transport = { async request(method, params, signal) {
    methods.push({ method, params, signal })
    return options.bindResult ?? true
  } }
  const callbacks = new NativeWorkflowGuestCallbacks(transport)
  const bind = () => callbacks.bind({ prepared, admission: { runId, token },
    authorizeChild: async () => true,
    activateChild: async () => {
      if (options.activateChild) return options.activateChild()
      return { childId, result: Promise.resolve({ output: [{ type: 'text', text: childId }],
        stopReason: 'completed' }), dispose: async () => {
          if (options.disposeFailure) throw new Error('child disposal failed')
          disposed.push(childId)
        } }
    },
    onProgress: async event => { events.push(event); await options.onProgress?.(event) },
  })
  const call = (callId, action, value) => ({ runId, token, callId, action, value,
    ...(action === 'WORKFLOW_START_CHILD' ? { childId } : {}) })
  return { callbacks, methods, events, disposed, bind, call }
}

test('native workflow callback frames invoke the bounded host and child ports', async () => {
  const owner = setup()
  await owner.bind()
  assert.equal(owner.methods[0].method, 'native.workflow.bindCallbacks')
  assert.deepEqual(owner.methods[0].params, { runId, token })
  assert.ok(owner.methods[0].signal instanceof AbortSignal)
  const init = await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  assert.equal(init.value.body, 'return 1')
  const start = await owner.callbacks.call(owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'Inspect' }))
  assert.deepEqual(start, { runId, callId: 2, value: { callId: 1, childId } })
  const result = await owner.callbacks.call(owner.call(3, 'WORKFLOW_CHILD_RESULT', { callId: 1 }))
  assert.equal(result.value.output[0].text, childId)
  const progress = [{ type: 'agent-start', info: { seq: 1, label: 'Inspect', childId } },
    { type: 'agent-end', info: { seq: 1, label: 'Inspect', childId, outcome: 'completed' } }]
  assert.deepEqual(await owner.callbacks.call(owner.call(4, 'WORKFLOW_PROGRESS', progress)),
    { runId, callId: 4, value: null })
  await owner.callbacks.call(owner.call(5, 'WORKFLOW_DISPOSE_CHILD', { callId: 1 }))
  assert.equal(owner.events.length, 2)
  assert.deepEqual(owner.disposed, [childId])
  assert.deepEqual(await owner.callbacks.close({ runId, token }), { closed: true })
})

test('native callback rejects unbound, forged, replayed and unknown frames', async () => {
  const owner = setup()
  await assert.rejects(owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {})), /no live admitted owner/)
  await owner.bind()
  await assert.rejects(owner.bind(), /already bound/)
  await assert.rejects(owner.callbacks.call({ ...owner.call(1, 'WORKFLOW_BEGIN', {}), token: 'guest' }),
    /no live admitted owner/)
  await assert.rejects(owner.callbacks.call({ ...owner.call(1, 'WORKFLOW_BEGIN', {}), extra: true }),
    /Invalid workflow callback frame/)
  await assert.rejects(owner.callbacks.call(Object.defineProperty({}, 'runId',
    { get() { throw Error('getter') } })), /Invalid workflow callback frame/)
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  await assert.rejects(owner.callbacks.call(owner.call(1, 'WORKFLOW_PROGRESS', [])), /sequence or action/)
  await assert.rejects(owner.callbacks.call(owner.call(2, 'WORKFLOW_FILE_READ', {})), /sequence or action/)
  await owner.callbacks.close({ runId, token })
  await assert.rejects(owner.callbacks.call(owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'late' })),
    /no live admitted owner/)
})

test('failed native binding retires its port, and close waits for child cleanup', async () => {
  const denied = setup({ bindResult: false })
  await assert.rejects(denied.bind(), /not confirmed/)
  await assert.rejects(denied.callbacks.call(denied.call(1, 'WORKFLOW_BEGIN', {})),
    /no live admitted owner/)
  const owner = setup()
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  await owner.callbacks.call(owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'Inspect' }))
  await owner.callbacks.close({ runId, token })
  assert.deepEqual(owner.disposed, [childId])
  await owner.callbacks.dispose()
})

test('App child reservation is required once and cannot be replayed', async () => {
  const owner = setup()
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  const unreserved = owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'missing' })
  delete unreserved.childId
  await assert.rejects(owner.callbacks.call(unreserved), /Invalid workflow callback frame/)
  await owner.callbacks.call(owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'first' }))
  await assert.rejects(owner.callbacks.call(owner.call(3, 'WORKFLOW_START_CHILD',
    { prompt: 'reuse' })), /already consumed/)
  await owner.callbacks.call(owner.call(3, 'WORKFLOW_DISPOSE_CHILD', { callId: 1 }))
  await owner.callbacks.close({ runId, token })
})

test('close joins a child published during START_CHILD cancellation', async () => {
  let release
  const held = new Promise(resolve => { release = resolve })
  const retired = []
  const owner = setup({ activateChild: async () => {
    await held
    return { childId, result: new Promise(() => {}),
      dispose: async () => { retired.push(childId) } }
  } })
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  const start = owner.callbacks.call(owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'race' }))
  await new Promise(resolve => setImmediate(resolve))
  const closing = owner.callbacks.close({ runId, token })
  release()
  await assert.rejects(start, /closed|cancelled/)
  assert.deepEqual(await closing, { closed: true })
  assert.deepEqual(retired, [childId])
})

test('failed child disposal prevents a clean native close', async () => {
  const owner = setup({ disposeFailure: true })
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  await owner.callbacks.call(owner.call(2, 'WORKFLOW_START_CHILD', { prompt: 'retire' }))
  await assert.rejects(owner.callbacks.close({ runId, token }), /unconfirmed/)
})

test('workflow callbacks dispatch in call-id order even when native sends async calls together', async () => {
  let release
  const hold = new Promise(resolve => { release = resolve })
  const delivered = []
  const owner = setup({ onProgress: async event => {
    delivered.push(`start:${event.title}`)
    if (event.title === 'first') await hold
    delivered.push(`end:${event.title}`)
  } })
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  const first = owner.callbacks.call(owner.call(2, 'WORKFLOW_PROGRESS',
    [{ type: 'phase', title: 'first' }]))
  const second = owner.callbacks.call(owner.call(3, 'WORKFLOW_PROGRESS',
    [{ type: 'phase', title: 'second' }]))
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(delivered, ['start:first'])
  release()
  await Promise.all([first, second])
  assert.deepEqual(delivered, ['start:first', 'end:first', 'start:second', 'end:second'])
  await owner.callbacks.close({ runId, token })
})

test('workflow callback request is immutable and bounded before reserving its sequence', async () => {
  const owner = setup()
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  await assert.rejects(owner.callbacks.call(owner.call(2, 'WORKFLOW_PROGRESS',
    [{ type: 'log', message: 'x'.repeat(65 * 1024) }])), /Invalid workflow callback request size/)
  const getter = { type: 'phase' }
  Object.defineProperty(getter, 'title', { enumerable: true, get() { throw Error('guest getter') } })
  await assert.rejects(owner.callbacks.call(owner.call(2, 'WORKFLOW_PROGRESS', [getter])),
    /Invalid workflow callback request/)
  const value = [{ type: 'phase', title: 'original' }]
  const accepted = owner.callbacks.call(owner.call(2, 'WORKFLOW_PROGRESS', value))
  value[0].title = 'mutated'
  await accepted
  assert.equal(owner.events[0].title, 'original')
  await owner.callbacks.close({ runId, token })
})

test('workflow callback queue is bounded and rejected saturation does not consume a call id', async () => {
  let release
  const hold = new Promise(resolve => { release = resolve })
  const owner = setup({ onProgress: async event => {
    if (event.title === 'phase-2') await hold
  } })
  await owner.bind()
  await owner.callbacks.call(owner.call(1, 'WORKFLOW_BEGIN', {}))
  const queued = Array.from({ length: 8 }, (_, index) => owner.callbacks.call(
    owner.call(index + 2, 'WORKFLOW_PROGRESS', [{ type: 'phase', title: `phase-${index + 2}` }])))
  await assert.rejects(owner.callbacks.call(owner.call(10, 'WORKFLOW_PROGRESS',
    [{ type: 'phase', title: 'overflow' }])), /queue is full/)
  release()
  await Promise.all(queued)
  await owner.callbacks.call(owner.call(10, 'WORKFLOW_PROGRESS', [{ type: 'phase', title: 'accepted' }]))
  assert.equal(owner.events.length, 9)
  await owner.callbacks.close({ runId, token })
})
