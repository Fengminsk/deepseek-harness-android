import assert from 'node:assert/strict'
import test from 'node:test'
import { WorkflowGuestHostPort } from '../runtime/workflow-guest-host-port.mjs'

function prepared() {
  return {
    kind: 'workflow', runId: '00000000-0000-4000-8000-000000000001',
    program: 'return 1', args: { input: 1 }, deadlineMillis: 5000,
    meta: { name: 'review', description: 'Review files' },
    maxTotalAgents: 3, maxConcurrentAgents: 2,
  }
}

function port({ onProgress = async () => {}, activateChild, authorizeChild = async () => true } = {}) {
  const released = []
  let next = 0
  const host = new WorkflowGuestHostPort({
    prepared: prepared(), authorizeChild,
    activateChild: activateChild ?? (async () => {
      const childId = `child-${++next}`
      return { childId, result: Promise.resolve({ output: [{ type: 'text', text: childId }],
        stopReason: 'completed' }), dispose: async () => { released.push(childId) } }
    }),
    onProgress,
  })
  return { host, released }
}

test('guest host exposes copied initialization and paired ordered progress', async () => {
  const events = []
  const { host, released } = port({ onProgress: async event => { events.push(event) } })
  assert.deepEqual(JSON.parse(JSON.stringify(host.begin({}))), {
    meta: { name: 'review', description: 'Review files' }, args: { input: 1 },
    limits: { maxTotalAgents: 3, maxConcurrentAgents: 2, maxItemsPerCall: 32, syncTimeoutMs: 5000 },
  })
  await assert.rejects(Promise.resolve().then(() => host.begin({})),
    { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
  const child = await host.startChild({ prompt: 'Inspect file' })
  assert.deepEqual(child, { callId: 1, childId: 'child-1' })
  assert.deepEqual(JSON.parse(JSON.stringify(await host.childResult({ callId: 1 }))), {
    output: [{ type: 'text', text: 'child-1' }], stopReason: 'completed',
  })
  await host.progress([
    { type: 'phase', title: 'Inspect' },
    { type: 'agent-start', info: { seq: 1, label: 'Read', phase: 'Inspect', childId: 'child-1' } },
    { type: 'agent-end', info: { seq: 1, label: 'Read', phase: 'Inspect', childId: 'child-1', outcome: 'completed' } },
    { type: 'log', message: 'Done' },
  ])
  assert.equal(events.length, 4)
  await host.disposeChild({ callId: 1 })
  await host.close()
  assert.deepEqual(released, ['child-1'])
})

test('entire invalid batch is refused before any observer event', async () => {
  const events = []
  const { host } = port({ onProgress: async event => { events.push(event) } })
  host.begin({})
  await assert.rejects(host.progress([
    { type: 'log', message: 'first' },
    { type: 'agent-end', info: { seq: 1, label: 'Never started', childId: 'unowned', outcome: 'completed' } },
  ]), { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
  assert.deepEqual(events, [])
  await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
})

test('oversized or malformed progress cancels children before retirement', async () => {
  for (const invalidBatch of [{ unexpected: true }, [{ type: 'log', message: 'x'.repeat(65 * 1024) }]]) {
    const { host, released } = port()
    host.begin({})
    await host.startChild({ prompt: 'Long task' })
    assert.throws(() => host.progress(invalidBatch))
    await assert.rejects(host.startChild({ prompt: 'No new child' }))
    await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
    assert.deepEqual(released, ['child-1'])
  }
})

test('one published child cannot appear as two separate agent starts', async () => {
  const events = []
  const { host, released } = port({ onProgress: async event => { events.push(event) } })
  host.begin({})
  await host.startChild({ prompt: 'One child' })
  await assert.rejects(host.progress([
    { type: 'agent-start', info: { seq: 1, label: 'First', childId: 'child-1' } },
    { type: 'agent-start', info: { seq: 2, label: 'Duplicate', childId: 'child-1' } },
  ]), { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
  assert.deepEqual(events, [])
  await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
  assert.deepEqual(released, ['child-1'])
})

test('a completed child cannot be replayed in a later progress batch', async () => {
  const events = []
  const { host } = port({ onProgress: async event => { events.push(event) } })
  host.begin({})
  await host.startChild({ prompt: 'One child' })
  await host.progress([
    { type: 'agent-start', info: { seq: 1, label: 'First', childId: 'child-1' } },
    { type: 'agent-end', info: { seq: 1, label: 'First', childId: 'child-1', outcome: 'completed' } },
  ])
  await assert.rejects(host.progress([
    { type: 'agent-start', info: { seq: 2, label: 'Replay', childId: 'child-1' } },
  ]), { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
  assert.equal(events.length, 2)
  await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
})

test('malformed progress stops an already delivering batch before its next event', async () => {
  const entered = Promise.withResolvers()
  const release = Promise.withResolvers()
  const events = []
  const { host } = port({ onProgress: async event => {
    events.push(event)
    entered.resolve()
    await release.promise
  } })
  host.begin({})
  const delivering = host.progress([
    { type: 'log', message: 'first' },
    { type: 'log', message: 'must not be delivered' },
  ])
  await entered.promise
  assert.throws(() => host.progress({ unexpected: true }))
  release.resolve()
  await assert.rejects(delivering, { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
  assert.deepEqual(events, [{ type: 'log', message: 'first' }])
  await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
})

test('live agent is ended as cancelled after child retirement', async () => {
  const events = []
  const { host, released } = port({ onProgress: async event => { events.push(event) } })
  host.begin({})
  await host.startChild({ prompt: 'Long task' })
  await host.progress([{ type: 'agent-start', info: { seq: 1, label: 'One', childId: 'child-1' } }])
  await host.close()
  assert.deepEqual(released, ['child-1'])
  assert.deepEqual(events.at(-1), {
    type: 'agent-end', info: { seq: 1, label: 'One', childId: 'child-1', outcome: 'cancelled' },
  })
})

test('failed observer and failed child retirement both block clean close', async () => {
  const { host } = port({
    onProgress: async () => { throw new Error('journal failed') },
    activateChild: async () => ({ childId: 'child', result: Promise.resolve({ output: [], stopReason: 'completed' }),
      dispose: async () => { throw new Error('child still running') } }),
  })
  host.begin({})
  await host.startChild({ prompt: 'Run' })
  await assert.rejects(host.progress([{ type: 'log', message: 'Running' }]), /journal failed/)
  await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
})

test('unowned and duplicate child progress cannot be presented', async () => {
  const { host } = port()
  host.begin({})
  await host.startChild({ prompt: 'Run' })
  await assert.rejects(host.progress([{ type: 'agent-start', info: { seq: 1, label: 'Fake', childId: 'other' } }]),
    { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
  await assert.rejects(host.close(), { code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED' })
})
