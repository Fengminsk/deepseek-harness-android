import assert from 'node:assert/strict'
import test from 'node:test'
import { startIsolatedExecutionRun } from '../runtime/isolated-execution-run.mjs'

const runId = '2a43756d-e83e-4ce4-b112-8fa625ad6520'
const sessionId = 'e16d20b9-97c5-4a0b-acce-e75303331c45'
const request = Object.freeze({ kind: 'script', runId, sessionId, program: 'return 1', deadlineMillis: 1000 })
const scope = Object.freeze({ ownerId: 'app', sessionId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [], fileCallLimit: 0,
  networkCallLimit: 0, leaseMillis: 1000 })

function deferred() {
  let resolve
  let reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

function receipt(state = 'COMPLETED', outputJson = '1') {
  return { runId, state, outputJson: state === 'COMPLETED' ? outputJson : null,
    guestUid: state === 'COMPLETED' ? 10234 : null, detail: null }
}

function bridge(overrides = {}) {
  const calls = []
  return {
    calls,
    async admit() { calls.push('admit'); return { runId } },
    async execute() { calls.push('execute') },
    async cancel() { calls.push('cancel') },
    async settle() { calls.push('settle'); return receipt() },
    async release() { calls.push('release') },
    ...overrides,
  }
}

test('admission, execution, terminal receipt and retirement are ordered before output publication', async () => {
  const retirement = deferred()
  const native = bridge({
    async admit(prepared) {
      native.calls.push('admit')
      assert.deepEqual(prepared.scope.writablePaths, [])
      assert.deepEqual(prepared.scope.exactHosts, [])
      assert.ok(Object.isFrozen(prepared))
      return { runId }
    },
    async release() { native.calls.push('release'); await retirement.promise },
  })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  let published = false
  run.result.then(() => { published = true })
  await new Promise(setImmediate)
  assert.deepEqual(native.calls, ['admit', 'execute', 'settle', 'release'])
  assert.equal(published, false)
  retirement.resolve()
  assert.deepEqual(await run.result, { runId, state: 'completed', value: 1, logs: [], guestUid: 10234 })
  assert.equal(published, true)
  await run.dispose()
  assert.deepEqual(native.calls, ['admit', 'execute', 'settle', 'release'])
})

test('trusted tool callbacks bind after durable admission and retire before native release', async () => {
  const native = bridge()
  const toolBinding = { async bind(prepared, admission) {
    native.calls.push('bind-tools')
    assert.equal(prepared.runId, runId)
    assert.equal(admission.runId, runId)
    return { async close() { native.calls.push('close-tools') } }
  } }
  const result = await startIsolatedExecutionRun({ request, scope, bridge: native, toolBinding }).result
  assert.equal(result.state, 'completed')
  assert.deepEqual(native.calls, ['admit', 'bind-tools', 'execute', 'settle', 'close-tools', 'release'])
})

test('an unconfirmed callback bind cancels native admission and cannot start a guest', async () => {
  const native = bridge()
  const toolBinding = { async bind() { native.calls.push('bind-tools'); throw Error('binder refused') } }
  await assert.rejects(startIsolatedExecutionRun({ request, scope, bridge: native, toolBinding }).result,
    { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.deepEqual(native.calls, ['admit', 'bind-tools', 'cancel', 'release'])
})

test('App cancellation during admission retires the admitted run without starting guest code', async () => {
  const admission = deferred()
  const native = bridge({
    async admit() { native.calls.push('admit'); return admission.promise },
    async settle() { native.calls.push('settle'); return receipt('CANCELLED') },
  })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  await new Promise(setImmediate)
  run.cancel('user left')
  admission.resolve({ runId })
  assert.deepEqual(await run.result, { runId, state: 'failed', failure: 'CANCELLED',
    requiresReview: false, guestUid: null, detail: null })
  assert.deepEqual(native.calls, ['admit', 'cancel', 'settle', 'release'])
})

test('an already aborted caller never reaches native admission', async () => {
  const controller = new AbortController()
  controller.abort('left screen')
  const native = bridge()
  const run = startIsolatedExecutionRun({ request, scope, bridge: native, signal: controller.signal })
  await assert.rejects(run.result, { code: 'ANDROID_EXECUTION_CANCELLED' })
  assert.deepEqual(native.calls, [])
})

test('cancellation during execution suppresses a late native success and cancels once', async () => {
  const execution = deferred()
  const native = bridge({ async execute() { native.calls.push('execute'); await execution.promise } })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  await new Promise(setImmediate)
  run.cancel('stop')
  run.cancel('stop again')
  execution.resolve()
  await assert.rejects(run.result, { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.equal(native.calls.filter(call => call === 'cancel').length, 1)
  assert.equal(native.calls.at(-1), 'release')
})

test('cancellation while reading terminal state joins native cancellation before retirement', async () => {
  const terminal = deferred()
  const cancellation = deferred()
  const native = bridge({
    async cancel() { native.calls.push('cancel'); await cancellation.promise },
    async settle() { native.calls.push('settle'); return terminal.promise },
  })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  await new Promise(setImmediate)
  run.cancel('stop')
  terminal.resolve(receipt('CANCELLED'))
  await new Promise(setImmediate)
  assert.equal(native.calls.includes('release'), false)
  cancellation.resolve()
  assert.equal((await run.result).failure, 'CANCELLED')
  assert.equal(native.calls.at(-1), 'release')
})

test('mismatched native admission cannot start, cancel or release an unowned handle', async () => {
  const native = bridge({ async admit() { native.calls.push('admit'); return { runId: sessionId } } })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  await assert.rejects(run.result, { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.deepEqual(native.calls, ['admit'])
})

test('receipt ownership failure and retirement failure both withhold output', async () => {
  const wrongReceipt = bridge({
    async settle() { wrongReceipt.calls.push('settle'); return { ...receipt(), runId: sessionId } },
  })
  await assert.rejects(startIsolatedExecutionRun({ request, scope, bridge: wrongReceipt }).result,
    { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.equal(wrongReceipt.calls.at(-1), 'release')

  const badRelease = bridge({
    async release() { badRelease.calls.push('release'); throw new Error('binder died') },
  })
  await assert.rejects(startIsolatedExecutionRun({ request, scope, bridge: badRelease }).result,
    { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
})

test('execution bridge failure requests cancellation and does not retry admission', async () => {
  const native = bridge({
    async execute() { native.calls.push('execute'); throw new Error('worker disconnected') },
  })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  await assert.rejects(run.result, { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.deepEqual(native.calls, ['admit', 'execute', 'cancel', 'release'])
})

test('dispose waits for native release and a cancelled terminal record', async () => {
  const execution = deferred()
  const retirement = deferred()
  const native = bridge({
    async execute() { native.calls.push('execute'); await execution.promise },
    async settle() { native.calls.push('settle'); return receipt('CANCELLED') },
    async release() { native.calls.push('release'); await retirement.promise },
  })
  const run = startIsolatedExecutionRun({ request, scope, bridge: native })
  await new Promise(setImmediate)
  let disposed = false
  const closing = run.dispose().then(() => { disposed = true })
  execution.resolve()
  await new Promise(setImmediate)
  assert.equal(disposed, false)
  retirement.resolve()
  await closing
  assert.equal(disposed, true)
  assert.equal((await run.result).failure, 'CANCELLED')
  assert.deepEqual(native.calls, ['admit', 'execute', 'cancel', 'settle', 'release'])
})
