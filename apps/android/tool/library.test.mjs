import assert from 'node:assert/strict'
import test from 'node:test'
import { setImmediate as nextTurn } from 'node:timers/promises'
import { AppLibrary } from '../runtime/library.mjs'

const root = { sessionId: 'root', cwd: '/private/workspace', running: false, agentAvailable: false,
  blank: false, updatedAt: 10, projections: { kind: 'cached', asOfSeq: 5, values: { title: 'Saved' } } }
const fork = { ...root, sessionId: 'fork', parentSessionId: 'root', updatedAt: 11 }
const child = { ...root, sessionId: 'child', parentSessionId: 'root', origin: 'subagent' }
const workspace = { workspaceId: 'workspace', path: '/private/workspace', title: 'Project',
  sessionIds: ['fork', 'root'], createdAt: 'created', updatedAt: 'updated' }

function fixture(t, options = {}) {
  const calls = [], follows = [], initializations = []
  let returns = 0
  const state = new AppLibrary({
    workspaceRegistry: { initializeDefault: async resolver => {
      initializations.push(await resolver())
      return options.initialize ? options.initialize() : options.initialized
    } },
    agents: options.agents,
  }, {
    closeTimeoutMs: options.closeTimeoutMs ?? (() => 5000),
    invoke: async (namespace, method, args, signal) => {
      calls.push({ namespace, method, args, signal })
      if (namespace === 'session' && method === 'list') return options.list?.(signal) ?? { items: options.sessions ?? [fork, child, root] }
      return options.invoke?.(namespace, method, args, signal) ?? { receipt: 'original' }
    },
    follow: async signal => {
      follows.push(signal)
      if (options.follow) return options.follow(signal)
      return { async *[Symbol.asyncIterator]() {
        try {
          yield { type: 'baseline', value: { items: [workspace], archivedSessionIds: ['root'], pinnedSessionIds: ['fork'] } }
          throw new Error('catalog must not consume increments')
        } finally { returns++ }
      } }
    },
  })
  t.after(() => state.close())
  return { state, calls, follows, initializations, returns: () => returns,
    writes: () => calls.filter(call => !(call.namespace === 'session' && call.method === 'list')) }
}

test('initialize delegates once per call to the original default gate and uses the actual private cwd', async t => {
  const first = fixture(t, { initialized: { id: 'default' } })
  assert.deepEqual(await first.state.initialize(), { workspaceId: 'default' })
  assert.deepEqual(first.initializations, [process.cwd()])
  assert.deepEqual(first.calls, [])
  const existing = fixture(t)
  assert.deepEqual(await existing.state.initialize(), { workspaceId: null })
})

test('catalog keeps original orders and cached projections, excludes children but includes ordinary forks without waking agents', async t => {
  const h = fixture(t)
  assert.deepEqual(await h.state.call('catalog'), {
    workspaces: [workspace], sessions: [fork, root], archivedSessionIds: ['root'], pinnedSessionIds: ['fork'],
    defaultDirectory: process.cwd(), capabilities: { crossWorkspaceMove: false },
  })
  assert.equal(h.returns(), 1)
  assert.deepEqual(h.calls.map(call => [call.namespace, call.method, call.args]), [['session', 'list', { _request: {} }]])
  assert.ok(h.calls[0].signal.aborted && h.follows[0].aborted)
  assert.equal(h.initializations.length, 0, 'catalog never initializes or writes')
  assert.equal(root.projections.kind, 'cached', 'no invented current projection')
})

test('sidebar omits archives, preserves original pin order and keeps ordinary fork identity and activity order', async t => {
  const summaries = [
    { ...root, sessionId: 'recent', updatedAt: 30 },
    fork, child, root,
    { ...root, sessionId: 'second-pin', projections: undefined },
    { ...root, sessionId: 'older', updatedAt: 1 },
  ]
  const h = fixture(t, { sessions: summaries, follow: () => ({ async *[Symbol.asyncIterator]() {
    yield { type: 'baseline', value: { items: [workspace], archivedSessionIds: ['root'],
      pinnedSessionIds: ['second-pin', 'fork', 'missing-pin'] } }
  } }) })
  const rows = await h.state.sidebar()
  assert.deepEqual(rows.map(row => row.header.id), ['second-pin', 'fork', 'recent', 'older'])
  assert.deepEqual(rows[1].header, { id: 'fork', cwd: fork.cwd, parentSessionId: 'root' })
  assert.equal(rows[1].title, 'Saved')
  assert.equal(rows[1].projections, fork.projections)
  assert.equal(rows[0].title, null)
  assert.deepEqual(rows.map(row => [row.pinned, row.archived]), [[true, false], [true, false], [false, false], [false, false]])
  assert.deepEqual(summaries.map(row => row.sessionId), ['recent', 'fork', 'child', 'root', 'second-pin', 'older'],
    'sorting must not mutate the original summary list')
  assert.equal(h.writes().length, 0)
})

test('failed and cancelled workspace openings release their stream and read lifetime', async t => {
  let returned = 0
  const bad = fixture(t, { follow: () => ({ async *[Symbol.asyncIterator]() {
    try { yield { type: 'upsert' } } finally { returned++ }
  } }) })
  assert.equal((await bad.state.call('catalog'))._pocket_error.code, 'gateway/internal')
  assert.equal(returned, 1)
  assert.ok(bad.follows[0].aborted)
  const started = Promise.withResolvers()
  const blocked = fixture(t, { follow: signal => new Promise((_, reject) => {
    started.resolve()
    signal.addEventListener('abort', () => reject(Object.assign(new Error('cancelled'), { code: 'gateway/cancelled' })), { once: true })
  }) })
  const reading = blocked.state.call('catalog')
  await started.promise
  await blocked.state.close()
  assert.equal((await reading)._pocket_error.code, 'gateway/cancelled')
  assert.equal((await blocked.state.call('workspaceCreate', { path: '/tmp' }))._pocket_error.code, 'gateway/cancelled')
  assert.equal(blocked.writes().length, 0)
})

test('directory creation and adoption remain separate original operations; default browsing starts at private cwd', async t => {
  const listing = { path: process.cwd(), home: '/home', crumbs: [], entries: [], truncated: true }
  const h = fixture(t, { invoke: (ns, method) => method === 'list' ? listing
    : method === 'createDirectory' ? '/private/workspace/project' : { workspace, created: false } })
  assert.equal(await h.state.call('directoryList'), listing)
  assert.equal(h.calls[0].args.path, process.cwd())
  assert.ok(h.calls[0].signal.aborted)
  assert.deepEqual(await h.state.call('directoryCreate', { path: '/private/workspace', name: 'project' }),
    { path: '/private/workspace/project' })
  assert.deepEqual(h.calls[1].args, { path: '/private/workspace', name: 'project' })
  assert.equal(h.calls.length, 2, 'mkdir must not silently register or retry')
  assert.deepEqual(await h.state.call('workspaceCreate', { path: '/private/workspace/project' }), { workspace, created: false })
  assert.deepEqual(h.calls[2].args, { request: { path: '/private/workspace/project' } })
})

test('workspace name and order route unchanged through original controllers', async t => {
  const h = fixture(t)
  await h.state.call('workspaceRename', { workspaceId: 'workspace', title: '  Renamed  ' })
  await h.state.call('workspaceReorder', { workspaceId: 'workspace', beforeWorkspaceId: 'other' })
  await h.state.call('workspaceReorder', { workspaceId: 'workspace' })
  assert.deepEqual(h.writes().map(({ namespace, method, args }) => [namespace, method, args]), [
    ['workspace', 'rename', { request: { workspaceId: 'workspace', title: '  Renamed  ' } }],
    ['workspace', 'insertBefore', { request: { workspaceId: 'workspace', beforeWorkspaceId: 'other' } }],
    ['workspace', 'insertBefore', { request: { workspaceId: 'workspace' } }],
  ])
})

test('session creation adopts the original returned identity and never mixes workspaceId with cwd', async t => {
  const h = fixture(t, { invoke: () => ({ sessionId: 'new-original-id', agentPreset: 'android' }) })
  assert.deepEqual(await h.state.call('sessionCreate', { workspaceId: 'workspace', sessionId: 'root', cwd: '/ignored' }),
    { sessionId: 'new-original-id', agentPreset: 'android' })
  assert.deepEqual(h.writes()[0].args, { request: { workspaceId: 'workspace', sessionId: 'root' } })
  assert.equal((await h.state.call('sessionCreate', { workspaceId: 'workspace', sessionId: 'absent' })).sessionId, 'new-original-id')
  assert.equal(h.writes().length, 2)
})

test('workspace creation carries an explicit preset and keeps original identities and preset refusals', async t => {
  const receipt = { sessionId: 'reused-by-original', agentPreset: 'custom' }
  const h = fixture(t, { invoke: () => receipt })
  assert.equal(await h.state.call('sessionCreate', { workspaceId: 'workspace', agentPreset: 'custom' }), receipt)
  assert.deepEqual(h.writes()[0].args, { request: { workspaceId: 'workspace', agentPreset: 'custom' } })
  for (const agentPreset of [null, 1, false, {}, [], '', ' ']) {
    assert.equal((await h.state.call('sessionCreate', { workspaceId: 'workspace', agentPreset }))._pocket_error.code,
      'gateway/bad-request')
  }
  assert.equal(h.writes().length, 1)
  for (const code of ['agent-preset/not-found', 'agent-preset/invalid']) {
    const refusal = fixture(t, { invoke: () => { throw Object.assign(new Error(code), { code, details: { agentPreset: 'bad' } }) } })
    assert.deepEqual((await refusal.state.call('sessionCreate', { workspaceId: 'workspace', agentPreset: 'bad' }))._pocket_error,
      { code, message: code, details: { agentPreset: 'bad' } })
    assert.equal(refusal.writes().length, 1)
  }
})

test('ordinary operations refuse children, including blank reuse and sort anchors, without activating or writing', async t => {
  const h = fixture(t)
  for (const [method, params] of [
    ['sessionCreate', { workspaceId: 'workspace', sessionId: 'child' }],
    ['sessionRename', { sessionId: 'child', title: 'x' }],
    ['sessionPin', { sessionId: 'child', pinned: true }],
    ['sessionArchive', { sessionId: 'child', archived: true, stopActivity: true }],
    ['sessionFork', { sessionId: 'child' }],
    ['sessionReorder', { workspaceId: 'workspace', sessionId: 'child' }],
    ['sessionReorder', { workspaceId: 'workspace', sessionId: 'root', beforeSessionId: 'child' }],
  ]) {
    assert.equal((await h.state.call(method, params))._pocket_error.code, 'session/agent-busy', method)
  }
  assert.deepEqual(h.writes(), [])
  assert.equal((await h.state.call('sessionPin', { sessionId: 'missing', pinned: true }))._pocket_error.code, 'session/not-found')
  const liveOwner = fixture(t, { agents: { get: () => ({}), isOwnedBy: () => true } })
  assert.equal((await liveOwner.state.call('sessionFork', { sessionId: 'fork' }))._pocket_error.code, 'session/agent-busy')
})

test('pin and archive keep original explicit state semantics and never escalate an activity refusal', async t => {
  const active = { code: 'workspace/session-active', message: 'active', details: {
    sessionId: 'root', activity: [{ kind: 'job', id: 'job' }],
  } }
  const h = fixture(t, { invoke: (ns, method, { request }) => {
    if (method === 'archiveSession' && !request.stopActivity) throw active
    return { original: true }
  } })
  assert.deepEqual(await h.state.call('sessionArchive', { sessionId: 'root', archived: true }), { _pocket_error: active })
  assert.equal(h.writes().length, 1, 'no automatic stop-and-retry')
  await h.state.call('sessionArchive', { sessionId: 'root', archived: true, stopActivity: true })
  await h.state.call('sessionArchive', { sessionId: 'root', archived: false })
  await h.state.call('sessionPin', { sessionId: 'fork', pinned: true })
  await h.state.call('sessionPin', { sessionId: 'fork', pinned: false })
  assert.deepEqual(h.writes().map(call => [call.method, call.args]), [
    ['archiveSession', { request: { sessionId: 'root' } }],
    ['archiveSession', { request: { sessionId: 'root', stopActivity: true } }],
    ['unarchiveSession', { request: { sessionId: 'root' } }],
    ['pinSession', { request: { sessionId: 'fork' } }],
    ['unpinSession', { request: { sessionId: 'fork' } }],
  ])
})

test('rename, within-workspace order and exact fork boundaries use original methods', async t => {
  const h = fixture(t)
  await h.state.call('sessionRename', { sessionId: 'fork', title: 'title' })
  await h.state.call('sessionReorder', { sessionId: 'root', workspaceId: 'workspace', beforeSessionId: 'fork' })
  await h.state.call('sessionFork', { sessionId: 'fork', atSeq: 0, allowMigration: false })
  await h.state.call('sessionFork', { sessionId: 'fork' })
  assert.deepEqual(h.writes().map(call => [call.namespace, call.method, call.args]), [
    ['session', 'rename', { request: { sessionId: 'fork', title: 'title' } }],
    ['workspace', 'insertSessionBefore', { request: { workspaceId: 'workspace', sessionId: 'root', beforeSessionId: 'fork' } }],
    ['session', 'fork', { request: { sessionId: 'fork', atSeq: 0, allowMigration: false } }],
    ['session', 'fork', { request: { sessionId: 'fork' } }],
  ])
})

test('partial creation and uncertain fork failures preserve evidence and never replay', async t => {
  const error = { code: 'session/workspace-attach-failed', message: 'created before attach failed',
    details: { sessionId: 'created', workspaceId: 'workspace' } }
  const h = fixture(t, { invoke: () => { throw error } })
  assert.deepEqual(await h.state.call('sessionCreate', { workspaceId: 'workspace' }), { _pocket_error: error })
  assert.deepEqual(await h.state.call('sessionFork', { sessionId: 'root' }), { _pocket_error: error })
  assert.equal(h.writes().length, 2, 'one original mutation for each explicitly requested operation')
})

test('invalid booleans/cursors and unsupported destructive/move operations cannot mutate', async t => {
  const h = fixture(t)
  for (const [method, params] of [
    ['sessionPin', { sessionId: 'root', pinned: 'true' }],
    ['sessionArchive', { sessionId: 'root', archived: true, stopActivity: 'true' }],
    ['sessionArchive', { sessionId: 'root', archived: false, stopActivity: true }],
    ['sessionFork', { sessionId: 'root', atSeq: -1 }],
    ['sessionFork', { sessionId: 'root', atSeq: 1.5 }],
    ['sessionFork', { sessionId: 'root', allowMigration: 'true' }],
    ['workspaceDelete', { workspaceId: 'workspace' }],
    ['sessionDelete', { sessionId: 'root' }],
    ['sessionMove', { workspaceId: 'other', sessionId: 'root' }],
    ['workspaceCreate', null],
  ]) assert.equal((await h.state.call(method, params))._pocket_error.code, 'gateway/bad-request', method)
  assert.deepEqual(h.writes(), [])
})

test('close drains an already-dispatched write and preserves its original receipt without cancelling or replaying', async t => {
  const started = Promise.withResolvers(), receipt = Promise.withResolvers()
  const h = fixture(t, { invoke: () => { started.resolve(); return receipt.promise } })
  const writing = h.state.call('workspaceCreate', { path: '/private/workspace/project' })
  await started.promise
  let closed = false
  const closing = h.state.close().then(() => { closed = true })
  await nextTurn()
  assert.equal(closed, false, 'close must not acknowledge while the original write is pending')
  assert.equal(h.writes()[0].signal, undefined, 'shutdown must not invent cancellation of an original unary write')
  assert.equal((await h.state.call('workspaceCreate', { path: '/other' }))._pocket_error.code, 'gateway/cancelled')
  receipt.resolve({ workspace, created: true })
  assert.deepEqual(await writing, { workspace, created: true })
  await closing
  assert.equal(closed, true)
  assert.equal(h.writes().length, 1)
})

test('close during session preflight prevents the write even if the original read finishes after abort', async t => {
  const started = Promise.withResolvers(), listed = Promise.withResolvers()
  const h = fixture(t, { list: () => { started.resolve(); return listed.promise } })
  const writing = h.state.call('sessionFork', { sessionId: 'root' })
  await started.promise
  const closing = h.state.close()
  assert.equal(h.calls[0].signal.aborted, true)
  listed.resolve({ items: [root] })
  assert.equal((await writing)._pocket_error.code, 'gateway/cancelled')
  await closing
  assert.deepEqual(h.writes(), [], 'a late successful preflight cannot begin a mutation after close')
})

test('close waits for original default initialization and rejects initialization after closure', async t => {
  const started = Promise.withResolvers(), initialized = Promise.withResolvers()
  const h = fixture(t, { initialize: () => { started.resolve(); return initialized.promise } })
  const initialization = h.state.initialize()
  await started.promise
  let closed = false
  const closing = h.state.close().then(() => { closed = true })
  await nextTurn()
  assert.equal(closed, false)
  initialized.resolve({ id: 'default' })
  assert.deepEqual(await initialization, { workspaceId: 'default' })
  await closing
  await assert.rejects(h.state.initialize(), { code: 'gateway/cancelled' })
  assert.equal(h.initializations.length, 1)
})

test('an original partial write failure remains intact while close waits for it', async t => {
  const started = Promise.withResolvers(), original = Promise.withResolvers()
  const partial = { code: 'session/workspace-attach-failed', message: 'created but attach failed',
    details: { sessionId: 'created', workspaceId: 'workspace' } }
  const h = fixture(t, { invoke: () => { started.resolve(); return original.promise } })
  const writing = h.state.call('sessionCreate', { workspaceId: 'workspace' })
  await started.promise
  let closed = false
  const closing = h.state.close().then(() => { closed = true })
  await nextTurn()
  assert.equal(closed, false)
  original.reject(partial)
  assert.deepEqual(await writing, { _pocket_error: partial })
  await closing
  assert.equal(h.writes().length, 1)
})

test('close timeout reports incomplete cleanup, retains the pending write and permits later close confirmation', async t => {
  const started = Promise.withResolvers(), original = Promise.withResolvers()
  const h = fixture(t, {
    closeTimeoutMs: () => 5,
    invoke: () => { started.resolve(); return original.promise },
  })
  let settled = false
  const writing = h.state.call('sessionCreate', { workspaceId: 'workspace' }).then(value => { settled = true; return value })
  await started.promise
  await assert.rejects(h.state.close(), { code: 'library/close-timeout' })
  assert.equal(settled, false, 'timeout cannot invent a definitive mutation outcome')
  assert.equal((await h.state.call('sessionCreate', { workspaceId: 'workspace' }))._pocket_error.code, 'gateway/cancelled')
  original.resolve({ sessionId: 'late-original-id' })
  assert.deepEqual(await writing, { sessionId: 'late-original-id' })
  await h.state.close()
  assert.equal(h.writes().length, 1)
})
