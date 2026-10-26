import assert from 'node:assert/strict'
import test from 'node:test'
import { WorkflowChildPort } from '../runtime/workflow-child-port.mjs'

function deferred() {
  let resolve
  let reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

function handle(childId, result = Promise.resolve({ output: [{ type: 'text', text: childId }], stopReason: 'completed' })) {
  let disposalCount = 0
  return {
    childId, result,
    dispose: async () => { disposalCount += 1 },
    get disposalCount() { return disposalCount },
  }
}

test('workflow child port owns published child result and exactly one disposal', async () => {
  const child = handle('child-a')
  const reviewed = []
  const port = new WorkflowChildPort({
    authorize: async (request) => { reviewed.push(request); return true },
    activate: async () => child, maxTotalAgents: 3, maxConcurrentAgents: 2,
  })
  const published = await port.start({ prompt: 'Inspect file', provider: 'fork' })
  assert.deepEqual(published, { callId: 1, childId: 'child-a' })
  assert.equal(reviewed[0].prompt, 'Inspect file')
  assert.deepEqual(JSON.parse(JSON.stringify(await port.result(1))), {
    output: [{ type: 'text', text: 'child-a' }], stopReason: 'completed',
  })
  await Promise.all([port.dispose(1), port.dispose(1)])
  assert.equal(child.disposalCount, 1)
  await port.close()
})

test('policy rejection blocks activation and invalid requests do not reach policy', async () => {
  let activations = 0
  let reviews = 0
  const port = new WorkflowChildPort({
    authorize: async () => { reviews += 1; return false },
    activate: async () => { activations += 1; return handle('unexpected') },
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  await assert.rejects(port.start({ prompt: 'Denied' }), { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
  await assert.rejects(port.start({ prompt: 'x', permission: 'danger-full-access' }),
    { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  await assert.rejects(port.start({ prompt: 'x', schema: {
    type: 'object', properties: { answer: { type: 'unsupported' } },
  } }), { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  assert.equal(reviews, 1)
  assert.equal(activations, 0)
  await port.close()
})

test('late child publication after cancellation is disposed and never returned', async () => {
  const beginning = deferred()
  const child = handle('late-child', Promise.resolve({ output: [{ type: 'text', text: 'secret' }], stopReason: 'completed' }))
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => beginning.promise,
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  const start = port.start({ prompt: 'Can race cancellation' })
  await new Promise(resolve => setImmediate(resolve))
  const closing = port.close()
  beginning.resolve(child)
  await assert.rejects(start, { code: 'ANDROID_WORKFLOW_CANCELLED' })
  await closing
  assert.equal(child.disposalCount, 1)
  await assert.rejects(port.result(1), { code: 'ANDROID_WORKFLOW_CANCELLED' })
})

test('child result awaiting aborts before a late result and cleanup drains', async () => {
  const completion = deferred()
  const child = handle('running-child', completion.promise)
  const abort = new AbortController()
  const port = new WorkflowChildPort({
    authorize: async () => true, activate: async () => child,
    maxTotalAgents: 1, maxConcurrentAgents: 1, signal: abort.signal,
  })
  await port.start({ prompt: 'Wait for result' })
  const result = port.result(1)
  abort.abort()
  await assert.rejects(result, { code: 'ANDROID_WORKFLOW_CANCELLED' })
  await port.close()
  completion.resolve({ output: [{ type: 'text', text: 'late' }], stopReason: 'completed' })
  assert.equal(child.disposalCount, 1)
})

test('disposing one child suppresses its already waiting result and late output', async () => {
  const completion = deferred()
  const child = handle('disposed-child', completion.promise)
  const port = new WorkflowChildPort({
    authorize: async () => true, activate: async () => child,
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  const started = await port.start({ prompt: 'Read file' })
  const awaiting = assert.rejects(port.result(started.callId), { code: 'ANDROID_WORKFLOW_CANCELLED' })
  await port.dispose(started.callId)
  completion.resolve({ output: [{ type: 'text', text: 'late private data' }], stopReason: 'completed' })
  await awaiting
  assert.equal(child.disposalCount, 1)
  await assert.rejects(port.result(started.callId), { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  await port.close()
})

test('concurrency waits for disposal and total cap counts starts', async () => {
  const children = [handle('one'), handle('two')]
  let index = 0
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => children[index++], maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  const first = await port.start({ prompt: 'First' })
  const secondStart = port.start({ prompt: 'Second' })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(index, 1)
  await port.dispose(first.callId)
  const second = await secondStart
  assert.deepEqual(second, { callId: 2, childId: 'two' })
  await assert.rejects(port.start({ prompt: 'Third' }), { code: 'ANDROID_WORKFLOW_CHILD_CAP' })
  await port.close()
  assert.equal(children[1].disposalCount, 1)
})

test('a released slot belongs to the queued waiter before a new starter', async () => {
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => handle('unused'),
    maxTotalAgents: 3, maxConcurrentAgents: 1,
  })
  await port.acquire()
  const waiting = port.acquire()
  port.release()
  const competing = port.acquire()
  await waiting
  assert.equal(port.slots, 1)
  port.release()
  await competing
  assert.equal(port.slots, 1)
  port.release()
  await port.close()
})

test('invalid and oversized child results cannot be published to the guest', async () => {
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => handle('bad', Promise.resolve({
      output: [{ type: 'text', text: 'x'.repeat(70_000) }], stopReason: 'completed',
    })), maxTotalAgents: 1, maxConcurrentAgents: 1,
  })
  await port.start({ prompt: 'Read' })
  await assert.rejects(port.result(1), { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  await port.close()
})

test('failed child retirement cannot be reported as a clean close', async () => {
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => ({
      childId: 'unretired',
      result: Promise.resolve({ output: [], stopReason: 'completed' }),
      dispose: async () => { throw new Error('backend did not confirm exit') },
    }),
    maxTotalAgents: 1, maxConcurrentAgents: 1,
  })
  const child = await port.start({ prompt: 'Run' })
  await assert.rejects(port.dispose(child.callId), /backend did not confirm exit/)
  await assert.rejects(port.close(), { code: 'ANDROID_WORKFLOW_CHILD_RETIRE_UNCONFIRMED' })
  await assert.rejects(port.close(), { code: 'ANDROID_WORKFLOW_CHILD_RETIRE_UNCONFIRMED' })
})

test('failed retirement never lends its occupied slot to a queued child', async () => {
  let activations = 0
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => {
      activations += 1
      return {
        childId: `child-${activations}`,
        result: new Promise(() => {}),
        dispose: async () => { throw new Error('termination not confirmed') },
      }
    },
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  const first = await port.start({ prompt: 'First' })
  const second = assert.rejects(port.start({ prompt: 'Second' }),
    { code: 'ANDROID_WORKFLOW_CANCELLED' })
  await assert.rejects(port.dispose(first.callId), /termination not confirmed/)
  await second
  assert.equal(activations, 1)
  assert.equal(port.slots, 1, 'the unconfirmed child still owns the concurrency slot')
  await assert.rejects(port.start({ prompt: 'Third' }), { code: 'ANDROID_WORKFLOW_CANCELLED' })
  await assert.rejects(port.close(), { code: 'ANDROID_WORKFLOW_CHILD_RETIRE_UNCONFIRMED' })
})

test('mismatched App reservation retires the returned handle before rejecting start', async () => {
  const child = handle('different-child')
  const port = new WorkflowChildPort({
    authorize: async () => true, activate: async () => child,
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  await assert.rejects(port.start({ prompt: 'Inspect' }, 'reserved-child'),
    { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  assert.equal(child.disposalCount, 1)
  assert.equal(port.slots, 0)
  await port.close()
})

test('failed retirement of mismatched App reservation remains owned and stops peers', async () => {
  let activations = 0
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => {
      activations += 1
      return { childId: 'different-child', result: new Promise(() => {}),
        dispose: async () => { throw Error('mismatched child remains live') } }
    },
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  await assert.rejects(port.start({ prompt: 'Inspect' }, 'reserved-child'),
    /mismatched child remains live/)
  assert.equal(port.slots, 1)
  assert.equal(activations, 1)
  await assert.rejects(port.start({ prompt: 'Another' }), { code: 'ANDROID_WORKFLOW_CANCELLED' })
  await assert.rejects(port.close(), { code: 'ANDROID_WORKFLOW_CHILD_RETIRE_UNCONFIRMED' })
})

test('a partial activation is disposed before its start fails', async () => {
  let disposed = 0
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => ({ childId: 'partial-child', dispose: async () => { disposed += 1 } }),
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  await assert.rejects(port.start({ prompt: 'Inspect' }), { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  assert.equal(disposed, 1)
  assert.equal(port.slots, 0)
  await port.close()
})

test('activation without a disposable handle leaves retirement unconfirmed', async () => {
  let activations = 0
  const port = new WorkflowChildPort({
    authorize: async () => true,
    activate: async () => {
      activations += 1
      return { childId: 'unowned-child', result: new Promise(() => {}) }
    },
    maxTotalAgents: 2, maxConcurrentAgents: 1,
  })
  await assert.rejects(port.start({ prompt: 'Inspect' }), { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
  assert.equal(port.slots, 1)
  await assert.rejects(port.start({ prompt: 'Another' }), { code: 'ANDROID_WORKFLOW_CANCELLED' })
  assert.equal(activations, 1)
  await assert.rejects(port.close(), { code: 'ANDROID_WORKFLOW_CHILD_RETIRE_UNCONFIRMED' })
})
