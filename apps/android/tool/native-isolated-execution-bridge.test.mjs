import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { startIsolatedExecutionRun } from '../runtime/isolated-execution-run.mjs'

const runId = '5c0686d1-45b8-4f41-a4ee-7ad258b1460b'
const sessionId = '62dc508d-7f30-42a8-ad12-3f1cecd99cca'
const request = { kind: 'script', runId, sessionId, program: '(input) => input', args: 7, deadlineMillis: 1000 }
const scope = { ownerId: 'app', sessionId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [], fileCallLimit: 0,
  networkCallLimit: 0, leaseMillis: 1000 }

test('native adapter keeps exactly one App-owned receipt path with an opaque token', async () => {
  const calls = []
  const bridge = createNativeIsolatedExecutionBridge({ async request(method, params, signal) {
    assert.ok(signal instanceof AbortSignal)
    calls.push(method)
    if (method === 'native.isolated.admit') {
      assert.equal(params.inputJson, '7')
      assert.equal(params.scope.workspaceId, null)
      return { runId, token: 'opaque-token' }
    }
    assert.deepEqual(params, { runId, token: 'opaque-token' })
    if (method === 'native.isolated.settle') return {
      runId, state: 'COMPLETED', outputJson: '7', guestUid: 10234, detail: null,
    }
    return true
  } })
  assert.deepEqual(await startIsolatedExecutionRun({ request, scope, bridge }).result,
    { runId, state: 'completed', value: 7, logs: [], guestUid: 10234 })
  assert.deepEqual(calls, ['native.isolated.admit', 'native.isolated.execute',
    'native.isolated.settle', 'native.isolated.release'])
})

test('granted and workflow requests never reach native admission', async () => {
  const calls = []
  const bridge = createNativeIsolatedExecutionBridge({ async request(method) { calls.push(method) } })
  const granted = { ...scope, workspaceId: 'a546758f-a7b0-4de9-bd47-b655a8ba4d02',
    readablePaths: ['work.txt'], fileCallLimit: 1 }
  await assert.rejects(startIsolatedExecutionRun({ request, scope: granted, bridge }).result,
    { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  const workflow = { ...request, kind: 'workflow', meta: { name: 'test', description: 'test' },
    maxTotalAgents: 1, maxConcurrentAgents: 1 }
  await assert.rejects(startIsolatedExecutionRun({ request: workflow, scope, bridge }).result,
    { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.deepEqual(calls, [])
})

test('model-supplied approval hints cannot open any granted script scope', async () => {
  const calls = []
  const bridge = createNativeIsolatedExecutionBridge({ async request(method) { calls.push(method) } })
  const workspaceId = 'a546758f-a7b0-4de9-bd47-b655a8ba4d02'
  const grants = [
    { workspaceId, readablePaths: ['work.txt'], fileCallLimit: 1 },
    { workspaceId, readablePaths: ['work.txt'], writablePaths: ['work.txt'], fileCallLimit: 1 },
    { exactHosts: ['example.org'], networkCallLimit: 1 },
    { workspaceId },
    { fileCallLimit: 1 },
  ]
  for (const grant of grants) {
    const prepared = {
      ...request, scope: { ...scope, ...grant },
      // This hint is deliberately untrusted; the native App has no model
      // route that installs an approved plan for this run ID.
      approvedPlan: { runId, approvalId: 'invented' },
    }
    await assert.rejects(bridge.admit(prepared), { code: 'ANDROID_PTC_UNAVAILABLE' })
  }
  assert.deepEqual(calls, [])
})

test('admission timeout is an unknown result and never executes or retries the run', async () => {
  const calls = []
  const bridge = createNativeIsolatedExecutionBridge({ request(method, params, signal) {
    calls.push(method)
    return new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true })
    })
  } })
  const result = startIsolatedExecutionRun({ request, scope, bridge }).result
  // Admission abandonment is an unknown native outcome and must not start or retry.
  await assert.rejects(result, { code: 'ANDROID_EXECUTION_UNCONFIRMED' })
  assert.deepEqual(calls, ['native.isolated.admit'])
}, { timeout: 12_000 })
