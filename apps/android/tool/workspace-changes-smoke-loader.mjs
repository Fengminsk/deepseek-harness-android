import assert from 'node:assert/strict'
import { registerHooks } from 'node:module'
import { readFileSync } from 'node:fs'
import { readdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
const sourceDirectory = new URL('../runtime/', import.meta.url)
const recorder = new URL('../../../.cache/android/runtime-bundle/node_modules/@deepseek-ai/dsh-workspace-changes/lib/index.js', import.meta.url).href
let fixture, barrier = false, barrierCount = 0
const notify = (method, params) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n')

globalThis.fetch = async () => { notify('fixture.unexpectedNetwork'); throw new Error('Changes fixture forbids network access') }

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL === carrier && ['./workspace-changes.mjs', './reference-discovery.mjs'].includes(specifier)) {
      return { url: new URL(specifier, sourceDirectory).href, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    const result = nextLoad(url, context)
    if (url === recorder) {
      // A deterministic cancellation barrier after original record lookup. No
      // source, diff, recording, permission, or availability result is replaced.
      const marker = 'const combined = AbortSignal.any([signal, this.lifetime.signal]);'
      assert.ok(result.source.toString().includes(marker), 'Original recorder timing seam changed')
      return { ...result, source: result.source.toString().replace(marker,
        marker + '\nawait changesReadBarrier(path, combined);') + `\nimport { changesReadBarrier } from ${JSON.stringify(import.meta.url)}\n` }
    }
    if (url !== carrier) return result
    let source = readFileSync(new URL('index.mjs', sourceDirectory), 'utf8')
    assert.ok(source.includes('workspaceChanges.call('), 'Latest Android changes wiring is required')
    const entry = 'export function apply(ctx, config)', dispatch = 'transport.onRequest(async (method, params) => {'
    assert.ok(source.includes(entry) && source.includes(dispatch), 'Android fixture entry changed')
    source = source.replace(entry, 'function applyRuntime(ctx, config)').replace(dispatch,
      dispatch + "\nif (method.startsWith('fixture.')) return changesFixtureCall(method, params);")
    return { ...result, source: source + `
import { prepareChangesFixture, changesFixtureCall } from ${JSON.stringify(import.meta.url)}
export function apply(ctx, config) {
  applyRuntime(ctx, config)
  ctx.inject(['workspaceChanges', 'connection', 'sessionPersistence', 'sessionQuery', 'fs'], scope => prepareChangesFixture(scope))
}
` }
  },
})

export async function changesReadBarrier(path, signal) {
  if (!barrier || path !== 'cancel.txt') return
  barrier = false
  signal.throwIfAborted()
  notify('fixture.readEntered', { number: ++barrierCount })
  await new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }))
}

export async function prepareChangesFixture(ctx) {
  try {
    fixture = { ctx, sessions: [], entries: [] }
    if (process.env.POCKET_CHANGES_SEED === '1') await seed(ctx)
    notify('fixture.changesReady', { entries: fixture.entries })
  } catch (error) { notify('fixture.failed', { message: error.stack }); throw error }
}

async function seed(ctx) {
  const { SessionId } = await import('@deepseek-ai/dsh-session')
  const { ToolCallId, createAssistantMessage, createToolResultMessage } = await import('@deepseek-ai/dsh-llm')
  let serial = 0
  const settled = session => ctx.waterfall('tools/pre-execute', { agent: { session } }, () => undefined)
  const toolResult = session => {
    const callId = ToolCallId(`changes-fixture-${++serial}`)
    session.append('assistant/message', { turn: 1, step: 1, stream: [], message: createAssistantMessage({
      content: [{ type: 'tool-call', id: callId, name: 'write', arguments: '{}' }],
      source: { provider: 'synthetic', model: 'fixture' },
    }) }, { surfaceOp: 'append' })
    const call = session.append('tool/call', { turn: 1, step: 1, callId, name: 'write', arguments: '{}' })
    session.append('tool/result', { turn: 1, step: 1,
      message: createToolResultMessage({ callId, content: [{ type: 'text', text: 'Synthetic mutation complete.' }], isError: false }) },
    { surfaceOp: 'append', sourceEventSeqs: [call.seq] })
  }
  const mutate = async (session, path, bytes) => {
    const actor = { agent: { session }, name: 'write', arguments: { file_path: path } }
    await ctx.waterfall('tools/pre-execute', actor, () => undefined)
    const target = await ctx.fs.resolve(path, { cwd: session.header.cwd })
    await ctx.waterfall('fs/write-intent', target, actor, () => undefined)
    await writeFile(join(session.header.cwd, path), bytes)
    toolResult(session)
  }
  for (const name of ['repo', 'plain']) {
    const session = ctx.sessions.prepare(SessionId(`changes-fixture-${name}`), { meta: { cwd: join(process.cwd(), name), agentPreset: 'android' } })
    const detach = ctx.sessions.enter(session)
    fixture.sessions.push({ session, detach })
    ctx.effect(() => detach)
    ctx.sessions.announce(session)
    session.append('turn/start', { turn: 1 })
    session.append('step/start', { turn: 1, step: 1 })
    await settled(session)
    if (name === 'repo') {
      // A Shell-style write with no fs intent must still be captured by real Git snapshots.
      await writeFile(join(session.header.cwd, 'tracked.txt'), 'first\nmodel edit\nlast\nadded\n')
      toolResult(session)
    } else {
      await writeFile(join(session.header.cwd, 'shell-only.txt'), 'Shell edit without an intent\n')
      toolResult(session)
    }
    await mutate(session, 'captured.txt', 'after\nextra\n')
    await mutate(session, 'cancel.txt', 'after\n')
    await mutate(session, 'binary.dat', Buffer.from([0, 1, 2, 3]))
    await mutate(session, 'oversized.txt', 'a'.repeat(257))
    await ctx.serial('agent/turn-stopping', { agent: { session }, turn: 1 })
    session.append('step/end', { turn: 1, step: 1 })
    session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })
    await settled(session)
    const event = session.snapshotEvents().findLast(item => item.type === 'workspace/changes')
    assert.ok(event, `Original ${name} recorder must publish a workspace/changes event`)
    const summary = ctx.workspaceChanges.summary(session.id, event.seq)
    assert.ok(summary)
    fixture.entries.push({ sessionId: session.id, seq: event.seq, gitSnapshot: !!summary.snapshot })
    const handle = await ctx.sessionPersistence.create(session.header)
    try { await handle.append(session.snapshotEvents()); await handle.flush() } finally { await handle.close() }
  }
  // A distinct cold Session is used by the original Agent-scoped @ providers.
  const { SESSION_FORMAT_VERSION } = await import('@deepseek-ai/dsh-session')
  for (const id of ['reference-fixture', 'reference-candidate']) {
    const handle = await ctx.sessionPersistence.create({ version: SESSION_FORMAT_VERSION, id: SessionId(id),
      cwd: join(process.cwd(), 'repo'), createdAt: Date.now(), isSeeded: false, agentPreset: 'android' })
    try { await handle.flush() } finally { await handle.close() }
  }
}

export async function changesFixtureCall(method, params) {
  assert.ok(fixture, 'Fixture must be ready')
  const { ctx } = fixture
  if (method === 'fixture.arm') { barrier = true; return { next: barrierCount + 1 } }
  if (method === 'fixture.permission') {
    const peer = ctx.connection.createPeer({ principal: { kind: 'agent', sessionId: 'untrusted-fixture' }, interactions: 'none' })
    try {
      const response = await ctx.connection.createSharedFetchHandler('/api').fetch(new Request(
        `http://pocket-harness.invalid/api/changes.summary?${new URLSearchParams({ sessionId: params.sessionId, seq: String(params.seq) })}`), peer)
      return { status: response.status, body: await response.text() }
    } finally { await peer.dispose() }
  }
  if (method === 'fixture.dispose') {
    for (const entry of fixture.sessions) entry.detach()
    const deadline = Date.now() + 5000
    for (;;) {
      const remaining = (await readdir(process.env.TMP)).filter(name => name.startsWith('dsh-workspace-changes-'))
      if (!remaining.length) return { remaining, live: fixture.sessions.some(entry => ctx.sessions.get(entry.session.id) !== undefined) }
      assert.ok(Date.now() < deadline, 'Original recorder temporary directories must be removed after disposal')
      await delay(10)
    }
  }
  if (method === 'fixture.history') {
    const data = await ctx.sessionQuery.readSession(params.sessionId)
    return { events: data.events.filter(event => event.type === 'workspace/changes') }
  }
  throw new Error(`Unknown fixture operation ${method}`)
}
