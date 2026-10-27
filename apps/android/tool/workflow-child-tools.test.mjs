import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, readFile, rm, glob } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import Include from '@deepseek-ai/cordis-plugin-include'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentPresets from '@deepseek-ai/dsh-agent-preset-registry'
import { SessionId } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as Spawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import Subprocess from '@deepseek-ai/dsh-subprocess-local'
import Web from '@deepseek-ai/dsh-web'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import { MockAdapter, textResponse, toolCallResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'
import { TestSessionQuery } from '../../../packages/subagent/subagent/tests/test-session-query.ts'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { registerModelFileReadGuard } from '../runtime/model-file-read-guard.mjs'
import { createWorkflowSubagentBackend, installWorkflowSubagentPreset } from '../runtime/workflow-subagent-backend.mjs'
import { WorkflowGuestHostPort } from '../runtime/workflow-guest-host-port.mjs'

const NAMES = ['edit', 'glob', 'grep', 'read', 'web_fetch', 'web_search', 'write']
const schemaNames = request => (request.tools ?? []).map(tool => tool.name).sort()

async function fixture(t, script, { mode = 'workspace-write', web = true, fetch, projectDirectory = '.' } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'workflow-working-child-'))
  const workspace = join(root, 'workspace')
  const sessions = join(root, 'sessions')
  await mkdir(workspace)
  const project = join(workspace, projectDirectory)
  await mkdir(project, { recursive: true })
  await writeFile(join(project, 'input.txt'), 'alpha\nbeta\n')
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await ctx.plugin(Loader)
  ctx.loader.builtins.include = Include
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode, workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: project })
  await ctx.plugin(Subprocess)
  await ctx.plugin(Web, { fetchProvider: 'fixture', searchProvider: 'fixture' })
  const webCalls = []
  ctx.web.registerFetchProvider({ id: 'fixture', available: () => true,
    fetch: async (request, signal) => { webCalls.push(['fetch', request]); if (fetch) return fetch(request, signal); return {
      url: request.url, statusCode: 200, body: { kind: 'text', content: 'verified fixture page' }, truncated: false,
    } } })
  ctx.web.registerSearchProvider({ id: 'fixture', available: () => true,
    search: async request => { webCalls.push(['search', request]); return {
      sources: [{ title: 'fixture', url: 'https://example.test/page', snippet: 'page summary' }], truncated: false,
    } } })
  await ctx.plugin(JsonlSessionPersistence, { root: sessions, compression: 'none' })
  await ctx.plugin(TestSessionQuery)
  await ctx.plugin(SubagentRuntime)
  await ctx.plugin(Spawn, { providerName: 'spawn' })
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(AgentPresets, { default: 'parent' })
  // The real Loader mounts these original tools in a parent-only preset. The
  // child must receive exact definitions through its grant, not global access.
  const unregisterParent = await ctx.agentPresets.register({ id: 'parent', plugins: [
    { name: '@deepseek-ai/dsh-tool-fs', config: { readImage: false } },
    { name: '@deepseek-ai/dsh-tool-fs-search', config: { sampleOverCapGlobResults: false } },
    ...(web ? [{ name: '@deepseek-ai/dsh-tool-web' }] : []),
  ] })
  // Observation state belongs to each Session, including delegated children.
  const ObservationPolicy = await import('@deepseek-ai/dsh-fs-observation-policy')
  await ctx.plugin(ObservationPolicy)
  registerModelFileReadGuard(ctx, workspace)
  const adapter = new MockAdapter(script)
  ctx.llm.registerAdapter(['mock'], adapter)
  const handle = await ctx.agents.create({
    sessionId: SessionId(`parent-${randomUUID()}`), meta: { cwd: project },
    agentOptions: { provider: 'mock', model: 'mock' },
    setup: async childCtx => void await ctx.agentPresets.mount(childCtx, 'parent'),
  })
  const parent = handle.agent
  const uninstall = await installWorkflowSubagentPreset(ctx)
  const runId = randomUUID()
  const backend = createWorkflowSubagentBackend({ ctx, parent, runId,
    authorize: async (_request, _signal, _parent, _runId, childId) => ({ runId, parentId: parent.id, childId }) })
  const guest = new WorkflowGuestHostPort({
    prepared: { kind: 'workflow', runId, program: 'return 1', args: {}, deadlineMillis: 10000,
      meta: { name: 'work', description: 'Use authorized tools' }, maxTotalAgents: 2, maxConcurrentAgents: 1 },
    authorizeChild: backend.authorizeChild, activateChild: backend.activateChild, onProgress: async () => {},
  })
  guest.begin({})
  t.after(async () => { await guest.close(); backend.close(); await uninstall() })
  let child
  ctx.on('subagent/start', info => { child = ctx.agents.get(info.id) })
  return { ctx, root, workspace, sessions, parent, adapter, webCalls, guest, backend,
    unregisterParent, handle, get child() { return child },
    async start(request = {}) {
      const published = await guest.startChild({ prompt: 'Complete the requested work', ...request }, randomUUID())
      return { published, child, result: () => guest.childResult({ callId: published.callId }) }
    } }
}

const toolRows = child => child.session.snapshotEvents().filter(event => event.type === 'tool/result')
const resultText = row => JSON.stringify(row.data)

test('real workflow child reads, searches, writes, edits and browses through original tools and durable Session', async t => {
  const call = (id, name, args) => toolCallResponse(id, name, args)
  const f = await fixture(t, [
    call('r', 'read', { file_path: 'input.txt' }),
    call('g', 'glob', { pattern: '*.txt' }),
    call('s', 'grep', { pattern: 'alpha', path: '.' }),
    call('w', 'write', { file_path: 'output.txt', content: 'created alpha\n' }),
    call('e', 'edit', { file_path: 'input.txt', old_string: 'alpha', new_string: 'changed' }),
    call('ws', 'web_search', { queries: ['example'] }),
    call('wf', 'web_fetch', { url: 'https://example.test/page' }),
    textResponse('completed work'),
  ])
  const run = await f.start()
  assert.equal(f.ctx.tools.get('read', run.child), f.ctx.tools.get('read', f.parent))
  assert.notEqual(f.ctx.tools.registrationIdentity('read', run.child), f.ctx.tools.registrationIdentity('read', f.parent))
  assert.equal((await run.result()).stopReason, 'completed')
  assert.deepEqual(schemaNames(f.adapter.requests[0]), NAMES)
  for (const row of toolRows(run.child)) assert.notEqual(row.data.message.isError, true, resultText(row))
  assert.equal(await readFile(join(f.workspace, 'output.txt'), 'utf8'), 'created alpha\n')
  assert.equal(await readFile(join(f.workspace, 'input.txt'), 'utf8'), 'changed\nbeta\n')
  const rows = toolRows(run.child)
  assert.equal(rows.length, 7)
  for (const row of rows) assert.equal(row.data.message.isError, false, resultText(row))
  assert.match(resultText(rows[0]), /alpha/)
  assert.match(resultText(rows[1]), /input.txt/)
  assert.match(resultText(rows[2]), /alpha/)
  assert.match(resultText(rows[5]), /page summary/)
  assert.match(resultText(rows[6]), /verified fixture page/)
  assert.deepEqual(f.webCalls.map(row => row[0]), ['search', 'fetch'])
  await f.guest.disposeChild({ callId: run.published.callId })
  const paths = await Array.fromAsync(glob('**/*.jsonl', { cwd: f.sessions }))
  const records = await Promise.all(paths.map(path => readFile(join(f.sessions, path), 'utf8')))
  const saved = records.find(text => text.split('\n').some(line => line && JSON.parse(line).id === run.child.id))
  assert.ok(saved)
  assert.equal(saved.split('\n').filter(line => line && JSON.parse(line).type === 'tool/result').length, 7)
})

test('child receives only available parent capabilities and cannot acquire writes after a read-only start', async t => {
  let f
  f = await fixture(t, [toolCallResponse('r', 'read', { file_path: 'input.txt' }),
    () => { setSandboxMode(f.parent.session, 'workspace-write')
      setSandboxMode(f.child.session, 'workspace-write')
      return toolCallResponse('w', 'write', { file_path: 'denied.txt', content: 'denied' }) }, textResponse('done')],
  { mode: 'read-only', web: false })
  const run = await f.start()
  await run.result()
  assert.deepEqual(schemaNames(f.adapter.requests[0]), ['glob', 'grep', 'read'])
  assert.equal(f.ctx.tools.get('write', run.child), undefined)
  assert.equal(f.ctx.tools.get('web_fetch', run.child), undefined)
  assert.match(resultText(toolRows(run.child)[1]), /not authorized/iu)
  await assert.rejects(readFile(join(f.workspace, 'denied.txt')), { code: 'ENOENT' })
})

test('live parent and child read-only downgrades block new writes while reads continue', async t => {
  for (const actor of ['parent', 'child']) {
    let f
    f = await fixture(t, [
      () => { setSandboxMode(actor === 'parent' ? f.parent.session : f.child.session, 'read-only')
        return toolCallResponse('w', 'write', { file_path: 'denied.txt', content: 'denied' }) },
      toolCallResponse('r', 'read', { file_path: 'input.txt' }), textResponse('done'),
    ])
    const run = await f.start()
    await run.result()
    assert.match(resultText(toolRows(run.child)[0]), /not authorized/)
    assert.match(resultText(toolRows(run.child)[1]), /alpha/)
    await assert.rejects(readFile(join(f.workspace, 'denied.txt')), { code: 'ENOENT' })
  }
})

test('original observed-version and protected metadata checks remain active in the child Session', async t => {
  const f = await fixture(t, [
    toolCallResponse('unread', 'edit', { file_path: 'input.txt', old_string: 'alpha', new_string: 'bad' }),
    toolCallResponse('metadata', 'write', { file_path: '.codex/config.json', content: '{}' }),
    toolCallResponse('outside', 'read', { file_path: '../secret.txt' }), textResponse('done'),
  ])
  await writeFile(join(f.root, 'secret.txt'), 'must stay private')
  const run = await f.start()
  await run.result()
  const rows = toolRows(run.child)
  assert.equal(rows.length, 3)
  for (const row of rows) assert.equal(row.data.message.isError, true)
  assert.match(resultText(rows[0]), /read|observ/iu)
  assert.equal(rows[1].data.error.code, 'FS_SANDBOX_DENIED')
  assert.doesNotMatch(resultText(rows[2]), /must stay private/)
  assert.equal(await readFile(join(f.workspace, 'input.txt'), 'utf8'), 'alpha\nbeta\n')
})

test('write and edit identities reject copies, replacement registrations and disposed owners', async t => {
  const f = await fixture(t, ['hang'])
  const run = await f.start()
  for (const [name, owns] of [['write', FsTools.isFirstPartyWriteDefinition], ['edit', FsTools.isFirstPartyEditDefinition]]) {
    const definition = f.ctx.tools.get(name, f.parent)
    assert.equal(owns(definition, f.parent), true)
    assert.equal(owns(definition, run.child), true)
    assert.equal(owns({ ...definition }, run.child), false)
    assert.throws(() => { definition.execute = async () => ({}) }, TypeError)
  }
  // A same-object parent re-registration is a new permission identity.
  const original = f.ctx.tools.get('write', f.parent)
  const remove = f.parent.ctx.tools.register(original)
  const result = await f.ctx.tools.execute({ name: 'write', callId: 'replaced',
    arguments: { file_path: 'replacement.txt', content: 'bad' }, agent: run.child, signal: new AbortController().signal })
  assert.equal(result.isError, true)
  assert.match(JSON.stringify(result), /not authorized/)
  remove()
  await f.guest.disposeChild({ callId: run.published.callId })
  await f.handle.dispose()
  await f.unregisterParent()
  assert.equal(FsTools.isFirstPartyWriteDefinition(original, run.child), false)
})

test('a retired or cold-resumed workflow child has no inherited file permissions', async t => {
  const f = await fixture(t, [toolCallResponse('r', 'read', { file_path: 'input.txt' }),
    textResponse('done'), textResponse('cold resumed')])
  const run = await f.start()
  await run.result()
  await f.guest.disposeChild({ callId: run.published.callId })
  f.backend.close()
  await f.ctx.subagents.sendMessage(f.parent, SessionId(run.child.id), [{ type: 'text', text: 'Continue' }],
    { signal: new AbortController().signal })
  await f.ctx.subagents.waitForChildren(f.parent)
  assert.deepEqual(schemaNames(f.adapter.requests.at(-1)), [])
  assert.match(JSON.stringify(f.adapter.requests.at(-1)), /alpha/)
})

test('structured child can read the workspace before submitting its own validated result', async t => {
  const f = await fixture(t, [toolCallResponse('r', 'read', { file_path: 'input.txt' }),
    request => { assert.match(JSON.stringify(request.messages), /alpha/)
      return toolCallResponse('result', 'structured_output', { answer: 'alpha' }) }, textResponse('done')])
  const run = await f.start({ schema: { type: 'object', properties: { answer: { type: 'string' } },
    required: ['answer'], additionalProperties: false } })
  const result = await run.result()
  assert.equal(result.structured.answer, 'alpha')
  assert.deepEqual(schemaNames(f.adapter.requests[0]), [...NAMES, 'structured_output'].sort())
  assert.equal(toolRows(run.child)[0].data.message.isError, false)
})

test('revocation, parent visibility and changed child directories deny new real ToolRuntime dispatches', async t => {
  const f = await fixture(t, ['hang'])
  const run = await f.start()
  const call = (name, args) => f.ctx.tools.execute({ name, arguments: args, agent: run.child,
    callId: randomUUID(), signal: new AbortController().signal })
  const remove = f.parent.ctx.tools.restrict({ deny: ['web_fetch'] })
  assert.equal((await call('web_fetch', { url: 'https://example.test/page' })).isError, true)
  assert.equal(f.webCalls.length, 0)
  remove()
  await f.ctx.workingDirectory.set(run.child, f.root)
  assert.equal((await call('read', { file_path: 'secret.txt' })).isError, true)
  await f.ctx.workingDirectory.set(run.child, f.workspace)
  assert.notEqual((await call('read', { file_path: 'input.txt' })).isError, true)
  f.backend.close()
  assert.equal((await call('read', { file_path: 'input.txt' })).isError, true)
  await f.guest.disposeChild({ callId: run.published.callId })
  assert.equal(f.ctx.agents.get(run.child.id), undefined)
})

test('cancelling a working child joins the original web tool before reporting retirement', async t => {
  const started = Promise.withResolvers()
  let aborted = false
  const f = await fixture(t, [toolCallResponse('fetch', 'web_fetch', { url: 'https://example.test/page' })], {
    fetch: async (_request, signal) => {
      started.resolve()
      await new Promise((_resolve, reject) => {
        const stop = () => { aborted = true; reject(signal.reason) }
        if (signal.aborted) stop()
        else signal.addEventListener('abort', stop, { once: true })
      })
    },
  })
  const run = await f.start()
  await started.promise
  await f.guest.disposeChild({ callId: run.published.callId })
  assert.equal(aborted, true)
  assert.equal(f.ctx.agents.get(run.child.id), undefined)
  assert.equal(f.ctx.tools.get('web_fetch', run.child), undefined)
})

test('spawning after a parent directory change cannot widen its immutable write root', async t => {
  const f = await fixture(t, [toolCallResponse('w', 'write', { file_path: 'denied.txt', content: 'bad' }),
    textResponse('done')], { projectDirectory: 'original-project' })
  const elsewhere = join(f.workspace, 'other-project')
  await mkdir(elsewhere)
  await f.ctx.workingDirectory.set(f.parent, elsewhere)
  const run = await f.start()
  await run.result()
  assert.equal(toolRows(run.child)[0].data.message.isError, true)
  assert.match(resultText(toolRows(run.child)[0]), /not authorized/)
  await assert.rejects(readFile(join(elsewhere, 'denied.txt')), { code: 'ENOENT' })
})

test('structured output rejects a later same-name registration before its executor runs', async t => {
  const f = await fixture(t, ['hang'])
  const tools = f.ctx.tools
  const descriptor = Object.getOwnPropertyDescriptor(tools, 'register')
  const register = tools.register
  let removeOriginal
  // Retain the public registration disposer at the original manager boundary;
  // the replacement still goes through the real scoped registry and executor.
  Object.defineProperty(tools, 'register', { configurable: true, writable: true, value: function (definition) {
    const remove = register.call(this, definition)
    if (definition.name === 'structured_output') removeOriginal = remove
    return remove
  } })
  let run
  try {
    run = await f.start({ schema: { type: 'object', properties: { answer: { type: 'string' } },
      required: ['answer'], additionalProperties: false } })
  } finally {
    if (descriptor) Object.defineProperty(tools, 'register', descriptor)
    else delete tools.register
  }
  assert.equal(typeof removeOriginal, 'function')
  const original = f.ctx.tools.get('structured_output', run.child)
  removeOriginal()
  let executed = false
  run.child.ctx.tools.register({ ...original, execute: async () => { executed = true; return { recorded: true } } })
  const result = await f.ctx.tools.execute({ name: 'structured_output', arguments: { answer: 'forged' },
    agent: run.child, callId: 'replaced-result', signal: new AbortController().signal })
  assert.equal(result.isError, true)
  assert.equal(executed, false)
  assert.match(JSON.stringify(result), /not authorized/)
  await f.guest.disposeChild({ callId: run.published.callId })
})
