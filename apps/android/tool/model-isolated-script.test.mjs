import test from 'node:test'
import assert from 'node:assert/strict'
import {
  prepareModelIsolatedScript,
  projectModelIsolatedScriptReceipt,
  runModelIsolatedScript,
} from '../runtime/model-isolated-script.mjs'
import { projectIsolatedSandboxPolicy } from '../runtime/isolated-sandbox-policy.mjs'

const sessionId = 'd7ad4e91-2825-48be-9d82-d964e31c9f19'
const scope = () => ({
  ownerId: 'app-model-script', sessionId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [],
  fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 30_000,
})
const host = () => ({ sessionId,
  sandboxPolicy: projectIsolatedSandboxPolicy({ approvedScope: scope() }),
  deadlineMillis: 5000 })
const input = () => ({
  language: 'typescript-function-body',
  code: 'const value: number = await Promise.resolve(7); return { value }',
  description: 'Compute a value in isolation',
})
const prepare = (model = input(), trusted = host()) =>
  prepareModelIsolatedScript(model, trusted)

test('App policy alone owns run identity, session and default file/network scope', () => {
  const first = prepare()
  const second = prepare()
  assert.notEqual(first.execution.runId, second.execution.runId)
  assert.equal(first.execution.sessionId, sessionId)
  assert.equal(first.execution.scope.sessionId, sessionId)
  assert.deepEqual(first.execution.scope.readablePaths, [])
  assert.deepEqual(first.execution.scope.exactHosts, [])
  assert.equal(first.language, 'typescript-function-body')
  assert.equal(first.source, input().code)
  assert.equal(first.execution.program, first.compiled.javaScript)
  assert.notEqual(first.execution.program, first.source)
  assert.ok(Object.isFrozen(first.execution))
  assert.ok(Object.isFrozen(first.execution.scope))
})

test('model cannot forge authority, session, run ID, paths or hosts', () => {
  for (const forged of [
    { runId: 'f7e2d201-613a-459a-962c-c62417b8d422' },
    { sessionId },
    { scope: scope() },
    { readablePaths: ['account.sqlite'] },
    { writablePaths: ['output.txt'] },
    { exactHosts: ['example.com'] },
    { sandbox_permissions: 'danger-full-access' },
    { timeoutMs: 60_000 },
    { args: { file: 'secret' } },
  ]) assert.throws(() => prepare({ ...input(), ...forged }),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => prepare(Object.defineProperty({ ...input() }, 'scope',
    { enumerable: true, get() { throw new Error('must not run') } })),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => prepare(input(), { ...host(), sandboxPolicy: {
    mode: 'workspace-write', networkMode: 'deny', scope: scope(),
  } }), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
})

test('trusted projected policy bounds future model draft without opening execution', () => {
  const approvedScope = { ...scope(), workspaceId: sessionId,
    readablePaths: ['src/'], writablePaths: ['src/result.txt'],
    exactHosts: ['api.example.com'], fileCallLimit: 4, networkCallLimit: 2 }
  const policy = projectIsolatedSandboxPolicy({ approvedScope,
    mode: 'workspace-write', networkMode: 'allow-listed-https' })
  const draft = prepare(input(), { ...host(), sandboxPolicy: policy })
  assert.deepEqual(draft.execution.scope.writablePaths, ['src/result.txt'])
  assert.deepEqual(draft.execution.scope.exactHosts, ['api.example.com'])
  approvedScope.writablePaths.push('src/other.txt')
  assert.deepEqual(draft.execution.scope.writablePaths, ['src/result.txt'])
  assert.throws(() => runModelIsolatedScript(draft, {}),
    { code: 'ANDROID_PTC_UNAVAILABLE' })
})

test('missing own model and host fields cannot run inherited accessors', () => {
  const names = ['code', 'sessionId', 'sandboxPolicy']
  const originals = new Map(names.map(name =>
    [name, Object.getOwnPropertyDescriptor(Object.prototype, name)]))
  let invoked = 0
  try {
    for (const name of names) Object.defineProperty(Object.prototype, name, {
      configurable: true,
      get() { invoked++; throw new Error('inherited accessor must not run') },
    })
    const { code: _code, ...missingCode } = input()
    const { sessionId: _session, ...missingSession } = host()
    const { sandboxPolicy: _policy, ...missingPolicy } = host()
    for (const run of [
      () => prepare(missingCode),
      () => prepare(input(), missingSession),
      () => prepare(input(), missingPolicy),
    ]) {
      let error
      try { run() } catch (caught) { error = caught }
      assert.equal(Object.getOwnPropertyDescriptor(error, 'code')?.value,
        'ANDROID_MODEL_SCRIPT_INVALID')
    }
    assert.equal(invoked, 0)
  } finally {
    for (const name of names) {
      const previous = originals.get(name)
      if (previous) Object.defineProperty(Object.prototype, name, previous)
      else delete Object.prototype[name]
    }
  }
})

test('only erasable TypeScript function bodies enter the sealed draft', () => {
  assert.throws(() => prepare({ ...input(), language: 'typescript' }),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => prepare({ ...input(), language: 'javascript-expression' }),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => prepare({ ...input(), code: 'enum X { A } return X.A' }),
    { code: 'ANDROID_PTC_TYPESCRIPT_INVALID' })
  assert.throws(() => prepare({ ...input(), description: '  ' }),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
  assert.throws(() => prepare({ ...input(), code: '' }),
    { code: 'ANDROID_MODEL_SCRIPT_INVALID' })
})

test('closed product gate never admits, executes or replays an untrusted draft', () => {
  const draft = prepare()
  const calls = []
  const bridge = Object.fromEntries(['admit', 'execute', 'settle', 'cancel', 'release']
    .map(name => [name, () => { calls.push(name); throw new Error('unexpected native call') }]))
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.throws(() => runModelIsolatedScript(draft, bridge), {
      code: 'ANDROID_PTC_UNAVAILABLE',
    })
  }
  assert.deepEqual(calls, [])
})

test('only matching durable completion exposes output; failure and uncertainty do not', () => {
  const runId = prepare().execution.runId
  const completed = projectModelIsolatedScriptReceipt({
    runId, state: 'COMPLETED', outputJson: '{"value":7}', guestUid: 90001,
  }, runId)
  assert.equal(completed.runId, runId)
  assert.equal(completed.state, 'completed')
  assert.equal(completed.value.value, 7)
  assert.deepEqual(completed.logs, [])
  assert.equal(Object.getPrototypeOf(completed.value), null)
  for (const state of ['CANCELLED', 'TIMED_OUT', 'INTERRUPTED_UNCONFIRMED']) {
    const outcome = projectModelIsolatedScriptReceipt({
      runId, state, outputJson: null, detail: 'not completed',
    }, runId)
    assert.equal(outcome.state, 'failed')
    assert.equal(Object.hasOwn(outcome, 'value'), false)
    assert.equal(outcome.requiresReview, state === 'INTERRUPTED_UNCONFIRMED')
  }
  assert.throws(() => projectModelIsolatedScriptReceipt({
    runId, state: 'CANCELLED', outputJson: '{"leaked":true}',
  }, runId), { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => projectModelIsolatedScriptReceipt({
    runId: 'a8f610f2-e665-47d4-b8e9-bdbfdc0324ac',
    state: 'COMPLETED', outputJson: '{"value":7}', guestUid: 90001,
  }, runId), { code: 'ANDROID_EXECUTION_INVALID' })
})
