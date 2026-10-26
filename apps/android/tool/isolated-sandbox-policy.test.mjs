import assert from 'node:assert/strict'
import test from 'node:test'
import { projectIsolatedSandboxPolicy } from '../runtime/isolated-sandbox-policy.mjs'

const sessionId = 'e7a435f1-1145-4d71-b2cb-0d99f8b72c7a'
const workspaceId = 'dab03f15-55f7-470f-8d28-e475cb9db9db'
const emptyScope = () => ({
  ownerId: 'app-session', sessionId, version: 1, workspaceId: null,
  readablePaths: [], writablePaths: [], exactHosts: [],
  fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
})
const approvedScope = () => ({
  ...emptyScope(), workspaceId, readablePaths: ['docs/', 'src/'],
  writablePaths: ['src/'], exactHosts: ['api.example.com'],
  fileCallLimit: 12, networkCallLimit: 3,
})

test('omitted modes deny writes and network, including hidden budgets', () => {
  const policy = projectIsolatedSandboxPolicy({ approvedScope: emptyScope() })
  assert.equal(policy.mode, 'read-only')
  assert.equal(policy.networkMode, 'deny')
  assert.deepEqual(policy.scope.writablePaths, [])
  assert.deepEqual(policy.scope.exactHosts, [])
  assert.equal(Object.isFrozen(policy), true)
  assert.equal(Object.isFrozen(policy.scope), true)
  assert.throws(() => projectIsolatedSandboxPolicy({ approvedScope: {
    ...emptyScope(), networkCallLimit: 1,
  } }), { code: 'ANDROID_EXECUTION_INVALID' })
})

test('read-only can retain explicitly selected reads but rejects selected writes', () => {
  const scope = { ...approvedScope(), writablePaths: [], exactHosts: [], networkCallLimit: 0 }
  const policy = projectIsolatedSandboxPolicy({ approvedScope: scope })
  assert.deepEqual(policy.scope.readablePaths, ['docs/', 'src/'])
  assert.deepEqual(policy.scope.writablePaths, [])
  assert.throws(() => projectIsolatedSandboxPolicy({ approvedScope: {
    ...scope, writablePaths: ['src/'],
  } }), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
})

test('workspace writes and exact HTTPS hosts require separate selected modes', () => {
  const selection = approvedScope()
  assert.throws(() => projectIsolatedSandboxPolicy({ mode: 'workspace-write',
    approvedScope: selection }), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
  assert.throws(() => projectIsolatedSandboxPolicy({ networkMode: 'allow-listed-https',
    approvedScope: selection }), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
  const policy = projectIsolatedSandboxPolicy({ mode: 'workspace-write',
    networkMode: 'allow-listed-https', approvedScope: selection })
  assert.deepEqual(policy.scope.writablePaths, ['src/'])
  assert.deepEqual(policy.scope.exactHosts, ['api.example.com'])
  selection.writablePaths.push('docs/')
  selection.exactHosts.push('other.example.com')
  assert.deepEqual(policy.scope.writablePaths, ['src/'])
  assert.deepEqual(policy.scope.exactHosts, ['api.example.com'])
  assert.throws(() => projectIsolatedSandboxPolicy({ mode: 'workspace-write',
    approvedScope: { ...selection, exactHosts: [], networkCallLimit: 0,
      writablePaths: ['secrets/'] } }), { code: 'ANDROID_EXECUTION_INVALID' })
})

test('a child can narrow App-approved paths, hosts, budgets and modes', () => {
  const parent = projectIsolatedSandboxPolicy({ mode: 'workspace-write',
    networkMode: 'allow-listed-https', approvedScope: approvedScope() })
  const childScope = { ...approvedScope(), readablePaths: ['docs/guide.md', 'src/lib/'],
    writablePaths: [], exactHosts: [], fileCallLimit: 3, networkCallLimit: 0,
    leaseMillis: 4000 }
  const child = projectIsolatedSandboxPolicy({ mode: 'read-only', networkMode: 'deny',
    approvedScope: childScope }, parent)
  assert.equal(child.mode, 'read-only')
  assert.equal(child.networkMode, 'deny')
  assert.deepEqual(child.scope.writablePaths, [])
  for (const widened of [
    { ...childScope, readablePaths: ['src-other/'] },
    { ...childScope, writablePaths: ['docs/guide.md'] },
    { ...childScope, exactHosts: ['other.example.com'], networkCallLimit: 1 },
    { ...childScope, fileCallLimit: 13 },
    { ...childScope, leaseMillis: 5001 },
  ]) assert.throws(() => projectIsolatedSandboxPolicy({ mode: 'workspace-write',
    networkMode: 'allow-listed-https', approvedScope: widened }, parent),
    { code: 'ANDROID_POLICY_WIDENED' })
  assert.throws(() => projectIsolatedSandboxPolicy({ mode: 'workspace-write',
    approvedScope: childScope }, child), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
  assert.throws(() => projectIsolatedSandboxPolicy({ networkMode: 'allow-listed-https',
    approvedScope: childScope }, child), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
})

test('untrusted and forged policy objects cannot override the projection', () => {
  for (const extra of [
    { mode: 'danger-full-access' },
    { mode: null },
    { networkMode: 'unrestricted' },
    { networkMode: null },
    { workspaceRoot: '/data/data/private' },
    { sandboxPolicy: { mode: 'danger-full-access' } },
  ]) assert.throws(() => projectIsolatedSandboxPolicy({ approvedScope: emptyScope(), ...extra }),
    { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
  const accessor = Object.defineProperty({}, 'approvedScope', {
    enumerable: true, get() { throw new Error('accessor must not run') },
  })
  assert.throws(() => projectIsolatedSandboxPolicy(accessor),
    { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
  const original = Object.getOwnPropertyDescriptor(Object.prototype, 'approvedScope')
  let inheritedReads = 0
  try {
    Object.defineProperty(Object.prototype, 'approvedScope', {
      configurable: true, get() { inheritedReads++; throw new Error('inherited accessor') },
    })
    assert.throws(() => projectIsolatedSandboxPolicy({}),
      { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
    assert.equal(inheritedReads, 0)
  } finally {
    if (original) Object.defineProperty(Object.prototype, 'approvedScope', original)
    else delete Object.prototype.approvedScope
  }
  const parent = projectIsolatedSandboxPolicy({ approvedScope: emptyScope() })
  assert.throws(() => projectIsolatedSandboxPolicy({ approvedScope: emptyScope() },
    { ...parent }), { code: 'ANDROID_SANDBOX_POLICY_INVALID' })
})
