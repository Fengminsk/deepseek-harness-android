import assert from 'node:assert/strict'
import test from 'node:test'
import { projectIsolatedSandboxPolicy } from '../runtime/isolated-sandbox-policy.mjs'
import {
  prepareModelWorkflow,
  projectModelWorkflowReceipt,
  runModelWorkflow,
} from '../runtime/tool-workflow-preflight.mjs'

const sessionId = 'e7a435f1-1145-4d71-b2cb-0d99f8b72c7a'
const emptyScope = () => ({
  ownerId: 'app-session', sessionId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [],
  fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
})
const host = () => ({
  sessionId,
  sandboxPolicy: projectIsolatedSandboxPolicy({ approvedScope: emptyScope() }),
  deadlineMillis: 5000,
  maxTotalAgents: 3,
  maxConcurrentAgents: 2,
})
const model = () => ({
  script: 'phase("Inspect"); const result = await agent("Review the evidence"); return result',
  meta: { name: 'inspect', description: 'Review one set of evidence' },
  args: { inputs: ['a.md'] },
})

test('the original workflow-shaped model call gets only host-owned authority', () => {
  const source = model()
  const draft = prepareModelWorkflow(source, host())
  assert.equal(draft.execution.kind, 'workflow')
  assert.equal(draft.execution.sessionId, sessionId)
  assert.match(draft.execution.runId, /^[a-f0-9]{8}-/)
  assert.equal(draft.execution.maxTotalAgents, 3)
  assert.equal(draft.execution.maxConcurrentAgents, 2)
  assert.deepEqual(draft.execution.scope.readablePaths, [])
  assert.deepEqual(JSON.parse(JSON.stringify(draft.execution.args)), { inputs: ['a.md'] })
  source.args.inputs.push('b.md')
  assert.deepEqual(JSON.parse(JSON.stringify(draft.execution.args)), { inputs: ['a.md'] })
  assert.equal(Object.isFrozen(draft.execution), true)
})

test('model arguments cannot choose authority, code mode or an unowned background run', () => {
  for (const extra of [
    { sessionId }, { runId: '00000000-0000-4000-8000-000000000001' },
    { maxConcurrentAgents: 8 }, { scope: emptyScope() },
    { language: 'typescript' },
  ]) assert.throws(() => prepareModelWorkflow({ ...model(), ...extra }, host()),
    { code: 'ANDROID_WORKFLOW_MODEL_INVALID' })
  assert.throws(() => prepareModelWorkflow({ ...model(), run_in_background: true }, host()),
    { code: 'ANDROID_WORKFLOW_BACKGROUND_UNAVAILABLE' })
  for (const args of [null, ['a'], 'a']) {
    assert.throws(() => prepareModelWorkflow({ ...model(), args }, host()),
      { code: 'ANDROID_WORKFLOW_MODEL_INVALID' })
  }
  assert.throws(() => prepareModelWorkflow({ ...model(), script: 'const = ;' }, host()),
    { code: 'ANDROID_WORKFLOW_MODEL_INVALID' })
  assert.throws(() => prepareModelWorkflow({ ...model(), script: 'const x: number = 1; return x' }, host()),
    { code: 'ANDROID_WORKFLOW_MODEL_INVALID' })
  const accessor = Object.defineProperty(model(), 'scope', {
    get() { throw new Error('must not run') }, enumerable: true,
  })
  assert.throws(() => prepareModelWorkflow(accessor, host()),
    { code: 'ANDROID_WORKFLOW_MODEL_INVALID' })
  assert.throws(() => prepareModelWorkflow(model(), { ...host(), deadlineMillis: 30_000 }),
    { code: 'ANDROID_EXECUTION_INVALID' })
  const longer = {
    ...host(),
    sandboxPolicy: projectIsolatedSandboxPolicy({ approvedScope: {
      ...emptyScope(), leaseMillis: 120_000,
    } }),
    deadlineMillis: 120_000,
  }
  assert.equal(prepareModelWorkflow(model(), longer).execution.deadlineMillis, 120_000)
  assert.throws(() => prepareModelWorkflow(model(), { ...longer, deadlineMillis: 120_001 }),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('an unissued policy or nonempty file/network scope cannot become a workflow draft', () => {
  assert.throws(() => prepareModelWorkflow(model(), {
    ...host(), sandboxPolicy: { ...host().sandboxPolicy },
  }), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
  const selected = { ...emptyScope(), workspaceId: 'dab03f15-55f7-470f-8d28-e475cb9db9db',
    readablePaths: ['docs/'], fileCallLimit: 1 }
  assert.throws(() => prepareModelWorkflow(model(), {
    ...host(), sandboxPolicy: projectIsolatedSandboxPolicy({ approvedScope: selected }),
  }), { code: 'ANDROID_WORKFLOW_SCOPE_UNAVAILABLE' })
})

test('only explicit App background policy permits an owned background draft', () => {
  const draft = prepareModelWorkflow({ ...model(), run_in_background: true },
    { ...host(), allowBackground: true })
  assert.equal(draft.background, true)
  assert.equal(draft.execution.sessionId, sessionId)
  for (const run_in_background of ['true', 1, null]) {
    assert.throws(() => prepareModelWorkflow({ ...model(), run_in_background },
      { ...host(), allowBackground: true }), { code: 'ANDROID_WORKFLOW_MODEL_INVALID' })
  }
})

test('execution gate stays closed and uncertain or failed output is withheld', () => {
  const draft = prepareModelWorkflow(model(), host())
  let called = false
  assert.throws(() => runModelWorkflow(draft, { start() { called = true } }, new AbortController().signal),
    { code: 'ANDROID_PTC_UNAVAILABLE' })
  assert.equal(called, false)
  const failed = projectModelWorkflowReceipt({ runId: draft.execution.runId,
    state: 'INTERRUPTED_UNCONFIRMED', outputJson: null, detail: 'App process stopped', guestUid: null },
  draft.execution.runId)
  assert.deepEqual(failed, { runId: draft.execution.runId, state: 'failed',
    failure: 'INTERRUPTED_UNCONFIRMED', requiresReview: true, detail: 'App process stopped' })
  assert.throws(() => projectModelWorkflowReceipt({ runId: draft.execution.runId,
    state: 'WORKER_DIED', outputJson: '"late result"', detail: null, guestUid: null },
  draft.execution.runId), { code: 'ANDROID_EXECUTION_INVALID' })
})
