import assert from 'node:assert/strict'
import test from 'node:test'
import {
  normalizeExecutionScope, prepareIsolatedExecution, projectIsolatedReceipt,
  requireModelFacingIsolatedExecution, snapshotIsolatedJson,
} from '../runtime/isolated-execution-contract.mjs'

const runId = '00000000-0000-4000-8000-000000000001'
const sessionId = '00000000-0000-4000-8000-000000000002'
const workspaceId = '00000000-0000-4000-8000-000000000003'
const base = () => ({
  ownerId: 'session-owner', sessionId, version: 1, workspaceId,
  readablePaths: ['src/main.js', 'readme.md'], writablePaths: ['src/main.js'],
  exactHosts: ['api.example.com', 'docs.example.org'],
  fileCallLimit: 20, networkCallLimit: 5, leaseMillis: 5000,
})
const script = () => ({ kind: 'script', runId, sessionId,
  program: 'function(input) { return input }', args: { question: 'hello' }, deadlineMillis: 4500 })
const workflow = () => ({ ...script(), kind: 'workflow',
  meta: { name: 'Review', description: 'Inspect files', phases: [{ title: 'Read' }] },
  maxTotalAgents: 3, maxConcurrentAgents: 2 })

test('script admission copies and freezes App scope and JSON without claiming execution', () => {
  const selected = base()
  const request = script()
  const prepared = prepareIsolatedExecution(request, selected)
  assert.equal(prepared.kind, 'script')
  assert.equal(prepared.scope.workspaceId, workspaceId)
  assert.deepEqual(prepared.scope.readablePaths, ['readme.md', 'src/main.js'])
  assert.equal(Object.isFrozen(prepared.scope.readablePaths), true)
  assert.equal(Object.isFrozen(prepared.args), true)
  selected.readablePaths.push('private/secret.txt')
  request.args.question = 'changed'
  assert.deepEqual(prepared.scope.readablePaths, ['readme.md', 'src/main.js'])
  assert.equal(prepared.args.question, 'hello')
  assert.throws(requireModelFacingIsolatedExecution, { code: 'ANDROID_PTC_UNAVAILABLE' })
})

test('workflow request retains the original meta and child budget vocabulary', () => {
  const prepared = prepareIsolatedExecution(workflow(), base())
  assert.deepEqual(prepared.meta.phases, [{ title: 'Read' }])
  assert.equal(prepared.maxTotalAgents, 3)
  assert.equal(prepared.maxConcurrentAgents, 2)
  assert.equal(Object.isFrozen(prepared.meta.phases[0]), true)
  assert.throws(() => prepareIsolatedExecution({ ...workflow(), maxConcurrentAgents: 4 }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('private workflow has a bounded longer lifetime while ordinary scripts stay at five seconds', () => {
  const scope = { ...base(), leaseMillis: 120_000 }
  assert.equal(prepareIsolatedExecution({ ...workflow(), deadlineMillis: 120_000 }, scope)
    .deadlineMillis, 120_000)
  assert.throws(() => prepareIsolatedExecution({ ...workflow(), deadlineMillis: 120_001 }, scope),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), deadlineMillis: 5_001 }, scope),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...workflow(), deadlineMillis: 120_000 }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('policy is an App argument, never accepted from the model request', () => {
  assert.throws(() => prepareIsolatedExecution({ ...script(), scope: base() }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution(script(), { ...base(), sessionId: runId }),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), sandboxPolicy: { mode: 'danger-full-access' } }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('child scope may only lose file, host, call and time authority', () => {
  const parent = base()
  const child = { ...base(), readablePaths: ['src/main.js'], writablePaths: [],
    exactHosts: ['api.example.com'], fileCallLimit: 1, networkCallLimit: 1, leaseMillis: 4500 }
  assert.equal(normalizeExecutionScope(child, parent).fileCallLimit, 1)
  for (const widened of [
    { ...child, readablePaths: ['src/main.js', 'new.txt'] },
    { ...child, exactHosts: ['other.example.com'] },
    { ...child, fileCallLimit: 21 },
    { ...child, networkCallLimit: 6 },
    { ...child, leaseMillis: 5001 },
    { ...child, sessionId: runId },
    { ...child, workspaceId: runId },
    { ...child, version: 2 },
  ]) {
    assert.throws(() => normalizeExecutionScope(widened, parent),
      { code: 'ANDROID_POLICY_WIDENED' })
  }
  assert.throws(() => normalizeExecutionScope({ ...child, writablePaths: ['src/main.js'] }, child),
    { code: 'ANDROID_POLICY_WIDENED' })
})

test('directory scope can narrow to descendants but never a similar prefix or a wider write root', () => {
  const parent = { ...base(), readablePaths: ['src/', 'docs/'], writablePaths: ['src/'] }
  const child = { ...base(), readablePaths: ['src/lib/', 'docs/guide.md'],
    writablePaths: ['src/lib/main.js'], exactHosts: [], networkCallLimit: 0 }
  assert.deepEqual(normalizeExecutionScope(child, parent).writablePaths, ['src/lib/main.js'])
  assert.deepEqual(normalizeExecutionScope(parent).writablePaths, ['src/'])
  for (const widened of [
    { ...child, readablePaths: [...child.readablePaths, 'src-extra/private.txt'] },
    { ...child, writablePaths: ['docs/guide.md'] },
    { ...child, readablePaths: [...child.readablePaths, 'src-extra/'], writablePaths: ['src-extra/'] },
    { ...child, readablePaths: ['src'], writablePaths: [] },
  ]) {
    assert.throws(() => normalizeExecutionScope(widened, parent),
      { code: 'ANDROID_POLICY_WIDENED' })
  }
  assert.throws(() => normalizeExecutionScope({ ...parent, readablePaths: ['docs/'],
    writablePaths: ['src/file.txt'] }), { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => normalizeExecutionScope({ ...base(), readablePaths: ['src'],
    writablePaths: ['src/file.txt'] }), { code: 'ANDROID_EXECUTION_INVALID' })
})

test('grant targets and network hosts reject traversal, aliases and local endpoints', () => {
  for (const pathname of ['/absolute', '../secret', 'a/../../secret', 'a\\b', 'a:b',
    'a//b', 'a/./b', 'a/\u0000b', '/', 'a//', 'a/../', 'a/./']) {
    assert.throws(() => normalizeExecutionScope({ ...base(), readablePaths: [pathname], writablePaths: [] }),
      { code: 'ANDROID_EXECUTION_INVALID' })
  }
  for (const name of ['localhost', 'api.local', '127.0.0.1', 'api.123', '*.example.com',
    'api.example.com:443', 'api.example.com.', 'API.EXAMPLE.COM', 'bad..example.com', 'foo.test']) {
    assert.throws(() => normalizeExecutionScope({ ...base(), exactHosts: [name] }),
      { code: 'ANDROID_EXECUTION_INVALID' })
  }
  assert.throws(() => normalizeExecutionScope({ ...base(), writablePaths: ['other.txt'] }),
    { code: 'ANDROID_EXECUTION_INVALID' })
  for (const protectedPath of ['.git/config', 'src/.agents/run.md',
    'src/.codex/', '.aws/credentials']) {
    assert.throws(() => normalizeExecutionScope({ ...base(),
      readablePaths: [protectedPath], writablePaths: [protectedPath] }),
    { code: 'ANDROID_EXECUTION_INVALID' })
  }
  assert.throws(() => normalizeExecutionScope({ ...base(), readablePaths: ['a.txt', 'a.txt'], writablePaths: [] }),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('empty scope is read-only, offline and cannot carry hidden budgets', () => {
  const empty = { ...base(), workspaceId: null, readablePaths: [], writablePaths: [],
    exactHosts: [], fileCallLimit: 0, networkCallLimit: 0 }
  assert.deepEqual(normalizeExecutionScope(empty).exactHosts, [])
  assert.equal(prepareIsolatedExecution(script(), empty).scope.workspaceId, null)
  assert.throws(() => normalizeExecutionScope({ ...empty, networkCallLimit: 1 }),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => normalizeExecutionScope({ ...empty, writablePaths: ['a.txt'] }),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => normalizeExecutionScope({ ...base(), leaseMillis: 999 }),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('request and argument limits match the current isolated V8 wire', () => {
  assert.throws(() => prepareIsolatedExecution({ ...script(), deadlineMillis: 5001 }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), program: 'x'.repeat(65_537) }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), args: 'x'.repeat(65_537) }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), args: { n: Infinity } }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), args: { n: -0 } }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  const cycle = {}; cycle.self = cycle
  assert.throws(() => prepareIsolatedExecution({ ...script(), args: cycle }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
  const accessor = Object.defineProperty({}, 'secret', { enumerable: true, get: () => 'secret' })
  assert.throws(() => prepareIsolatedExecution({ ...script(), args: accessor }, base()),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('native terminal receipts never release uncertain or failed output', () => {
  const clean = projectIsolatedReceipt({ runId, state: 'COMPLETED', outputJson: '{"answer":42}', guestUid: 20000 }, runId)
  assert.equal(clean.state, 'completed')
  assert.equal(clean.value.answer, 42)
  assert.deepEqual(clean.logs, [])
  assert.equal(Object.isFrozen(clean.value), true)
  const logged = projectIsolatedReceipt({ runId, state: 'COMPLETED',
    outputJson: '{"answer":42}', logsJson: '["first 6","second"]', guestUid: 20000 }, runId)
  assert.deepEqual(logged.logs, ['first 6', 'second'])
  assert.equal(Object.isFrozen(logged.logs), true)
  for (const logsJson of ['{"forged":true}', '[7]', '["x",null]', '[bad',
    JSON.stringify(['x'.repeat(17_000)])]) {
    assert.throws(() => projectIsolatedReceipt({ runId, state: 'COMPLETED',
      outputJson: '1', logsJson, guestUid: 20000 }, runId),
    { code: 'ANDROID_EXECUTION_INVALID' })
  }
  for (const state of ['CANCELLED', 'TIMED_OUT', 'WORKER_DIED', 'ERROR',
    'RETIRE_UNCONFIRMED', 'INTERRUPTED_UNCONFIRMED']) {
    const result = projectIsolatedReceipt({ runId, state, outputJson: null, guestUid: null }, runId)
    assert.equal(result.state, 'failed')
    assert.equal(Object.hasOwn(result, 'value'), false)
    assert.equal(result.requiresReview, state.endsWith('_UNCONFIRMED'))
    assert.throws(() => projectIsolatedReceipt({ runId, state, outputJson: '"late"' }, runId),
      { code: 'ANDROID_EXECUTION_INVALID' })
    assert.throws(() => projectIsolatedReceipt({ runId, state, outputJson: null,
      logsJson: '["late"]' }, runId), { code: 'ANDROID_EXECUTION_INVALID' })
  }
  assert.throws(() => projectIsolatedReceipt({ runId, state: 'COMPLETED', outputJson: '{bad' }, runId),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => projectIsolatedReceipt({ runId, state: 'ADMITTED', outputJson: null }, runId),
    { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => projectIsolatedReceipt({ runId, state: 'COMPLETED', outputJson: '1', guestUid: 20000 }, sessionId),
    { code: 'ANDROID_EXECUTION_INVALID' })
})

test('workflow host JSON snapshots reject getters and detach mutable inputs', () => {
  const source = { output: [{ type: 'text', text: 'ready' }] }
  const snapshot = snapshotIsolatedJson(source)
  source.output[0].text = 'changed'
  assert.equal(snapshot.output[0].text, 'ready')
  assert.equal(Object.isFrozen(snapshot.output[0]), true)
  const accessor = Object.defineProperty({}, 'output', { enumerable: true, get: () => 'secret' })
  assert.throws(() => snapshotIsolatedJson(accessor), { code: 'ANDROID_EXECUTION_INVALID' })
  assert.throws(() => snapshotIsolatedJson('x'.repeat(128), 'child output', 32),
    { code: 'ANDROID_EXECUTION_INVALID' })
})
