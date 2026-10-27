import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { Context } from '@deepseek-ai/cordis'
import { SessionId } from '@deepseek-ai/dsh-session'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import FileSystem from '@deepseek-ai/dsh-fs-local'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import LocalSubprocess from '@deepseek-ai/dsh-subprocess-local'
import Web from '@deepseek-ai/dsh-web'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import * as SearchTools from '@deepseek-ai/dsh-tool-fs-search'
import * as WebTools from '@deepseek-ai/dsh-tool-web'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedReadOnlyPtcOwner } from '../runtime/model-ptc-readonly-owner.mjs'
import { allowsReadOnlyPtcArguments, reviewReadOnlyToolsForModelPtc } from '../runtime/model-ptc-readonly-review.mjs'
import { projectReadOnlyPtcResult, READONLY_PTC_RESULT_BYTES } from '../runtime/model-ptc-readonly-projection.mjs'
import { registerModelFileReadGuard } from '../runtime/model-file-read-guard.mjs'
import { createAndroidReadOnlyPtcToolDefinition, modelReadOnlyPtcCapability,
  registerAndroidReadOnlyPtcTool } from '../runtime/tool-readonly-ptc.mjs'

const AsyncFunction = (async () => {}).constructor
const size = value => Buffer.byteLength(JSON.stringify(value))

test('read-only model entry rejects forged owners and reports its tool-mediated limits', () => {
  const options = { owner: { start() { throw new Error('forged owner ran') } }, available: () => true }
  assert.throws(() => createAndroidReadOnlyPtcToolDefinition(options), /App-owned read-only PTC owner required/u)
  assert.throws(() => registerAndroidReadOnlyPtcTool({ effect() { throw new Error('must not register') } }, options),
    /App-owned read-only PTC owner required/u)
  const capability = modelReadOnlyPtcCapability(false)
  assert.equal(capability.available, false)
  assert.equal(capability.nativeFilesystem, 'none')
  assert.equal(capability.nativeNetwork, 'off')
  assert.deepEqual(capability.reviewedTools, ['list_agents', 'read', 'glob', 'grep', 'web_search', 'web_fetch',
    'android_files', 'android_attachments'])
  assert.equal(capability.wallDeadlineMillis, 120000)
  assert.equal(capability.executionThreadCpuMillis, 5000)
})

test('read-only action review excludes mutation, image delivery and forged arguments', () => {
  for (const action of ['roots', 'list', 'read', 'search']) assert.equal(allowsReadOnlyPtcArguments('android_files', { action }), true)
  for (const action of ['list', 'read', 'inspect_archive']) assert.equal(allowsReadOnlyPtcArguments('android_attachments', { action }), true)
  for (const action of ['read_image', 'materialize', 'write', 'edit']) {
    assert.equal(allowsReadOnlyPtcArguments('android_files', { action }), false)
    assert.equal(allowsReadOnlyPtcArguments('android_attachments', { action }), false)
  }
  assert.equal(allowsReadOnlyPtcArguments('write', {}), false)
  assert.equal(allowsReadOnlyPtcArguments('read', { get file_path() { throw new Error('must not read accessor') } }), false)
})

test('large UTF-8 SAF and attachment pages retain exact advancing byte offsets', () => {
  const text = '中文😀"\\'.repeat(30000), offset = 10
  const value = { text, offset, nextOffset: offset + Buffer.byteLength(text), version: 'a'.repeat(64), truncated: false }
  const saf = projectReadOnlyPtcResult('android_files', { action: 'read' }, value)
  assert.ok(size(saf) <= READONLY_PTC_RESULT_BYTES)
  assert.equal(saf.nextOffset, offset + Buffer.byteLength(saf.text))
  assert.equal(saf.version, value.version)
  assert.equal(saf.truncated, true)
  assert.equal(Buffer.from(saf.text).toString(), saf.text)
  const hex = projectReadOnlyPtcResult('android_attachments', { action: 'read' }, {
    content: 'abcdef'.repeat(30000), offset, nextOffset: 100000, encoding: 'hex', verified: true,
  })
  assert.equal(hex.content.length % 2, 0)
  assert.equal(hex.nextOffset, offset + hex.content.length / 2)
  assert.ok(size(hex) <= READONLY_PTC_RESULT_BYTES)
})

test('workspace line pages and web/search excerpts report truncation without inventing continuation', () => {
  const read = projectReadOnlyPtcResult('read', {}, { path: '/workspace/log.txt', offset: 1,
    lines: Array.from({ length: 100 }, (_, i) => ({ number: i + 1, text: '文'.repeat(2000) })), totalLines: 100 })
  assert.equal(read.nextOffset, read.lines.at(-1).number + 1)
  assert.ok(size(read) <= READONLY_PTC_RESULT_BYTES)
  const fetch = projectReadOnlyPtcResult('web_fetch', {}, { url: 'https://example.test', statusCode: 200,
    body: { kind: 'text', content: 'x'.repeat(300000) }, truncated: false })
  assert.equal(fetch.truncated, true)
  assert.equal(fetch.nextOffset, undefined)
  assert.ok(size(fetch) <= READONLY_PTC_RESULT_BYTES)
  const search = projectReadOnlyPtcResult('web_search', {}, { sources: Array.from({ length: 100 }, () => ({
    url: 'https://example.test', snippet: 'x'.repeat(1000) })), content: 'a'.repeat(100000), truncated: false })
  assert.ok(search.sources.length > 0 && search.sources.length < 100)
  assert.ok(size(search) <= READONLY_PTC_RESULT_BYTES)
  assert.throws(() => projectReadOnlyPtcResult('read', {}, { path: '/a', offset: 1,
    lines: [{ number: 1, text: 'x'.repeat(100000) }], totalLines: 1 }), /entry exceeds/u)
})

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-readonly-ptc-'))
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(FileSystem, { cwd: root })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: root })
  await ctx.plugin(LocalSubprocess)
  await ctx.plugin(Web, { fetchProvider: 'fixture', searchProvider: 'fixture' })
  ctx.web.registerFetchProvider({ id: 'fixture', available: () => true,
    fetch: async request => ({ url: request.url, statusCode: 200,
      body: { kind: 'text', content: 'page-data '.repeat(30000) }, truncated: false }) })
  ctx.web.registerSearchProvider({ id: 'fixture', available: () => true,
    search: async () => ({ sources: [{ url: 'https://example.test/page' }], truncated: false }) })
  const fileFiber = await ctx.plugin(FsTools, { readImage: false, write: false, edit: false })
  const searchFiber = await ctx.plugin(SearchTools, { sampleOverCapGlobResults: false })
  const webFiber = await ctx.plugin(WebTools)
  await writeFile(join(root, 'input.txt'), 'alpha\nbeta\n')
  const agent = await ctx.agentLoop.create(SessionId(`android-${randomUUID()}`))
  registerModelFileReadGuard(ctx, root)
  return { ctx, root, agent, fileFiber, searchFiber, webFiber }
}

test('original definitions attest exact scoped registrations and retire on plugin disposal', async t => {
  const { ctx, agent, fileFiber, searchFiber, webFiber } = await fixture(t)
  const entries = [
    ['read', FsTools.isFirstPartyReadDefinition, fileFiber],
    ['glob', SearchTools.isFirstPartyGlobDefinition, searchFiber],
    ['grep', SearchTools.isFirstPartyGrepDefinition, searchFiber],
    ['web_search', WebTools.isFirstPartyWebSearchDefinition, webFiber],
    ['web_fetch', WebTools.isFirstPartyWebFetchDefinition, webFiber],
  ]
  const definitions = entries.map(([name, check]) => {
    const definition = ctx.tools.get(name, agent)
    assert.equal(check(definition, agent), true)
    assert.equal(check({ ...definition }, agent), false)
    assert.throws(() => { definition.execute = async () => ({ forged: true }) }, TypeError)
    return definition
  })
  for (const fiber of new Set(entries.map(row => row[2]))) await fiber.dispose()
  entries.forEach(([, check], i) => assert.equal(check(definitions[i], agent), false))
})

test('real parent ToolRuntime dispatches file, search and webpage subcalls with bounded durable results', async t => {
  const { ctx, root, agent } = await fixture(t)
  let callbacks, program, input, output, runId
  const delivered = []
  const transport = { async request(method, params) {
    if (method === 'native.isolated.admit') {
      assert.equal(params.kind, 'ptc')
      assert.equal(params.deadlineMillis, 120000)
      assert.deepEqual(params.scope.readablePaths, [])
      assert.deepEqual(params.scope.exactHosts, [])
      program = params.program; input = params.inputJson; runId = params.runId
      return { runId, token: 'fixture-token' }
    }
    if (method === 'native.isolated.bindTools') return true
    if (method === 'native.isolated.execute') {
      // Only the native process is a fixture; host ToolRuntime and first-party tools are real.
      const fn = new AsyncFunction('input', 'host', program)
      output = JSON.stringify(await fn(JSON.parse(input), { callAsync: async request => {
        assert.equal(request.action, 'TOOL_CALL')
        assert.deepEqual(Object.keys(request).sort(), ['action', 'arguments', 'callId', 'name'])
        const { action, ...nativeForwarded } = request
        const { runId: _, callId: __, ...reply } = await callbacks.call({ ...nativeForwarded, runId, token: 'fixture-token' })
        delivered.push(reply)
        return reply
      } }))
      return true
    }
    if (method === 'native.isolated.settle') return { runId, state: 'COMPLETED', outputJson: output, detail: null, guestUid: 99001 }
    if (method === 'native.isolated.release' || method === 'native.isolated.cancel') return true
    throw new Error(method)
  } }
  callbacks = new NativeIsolatedToolCallbacks(transport, new IsolatedToolCallJournal(join(root, 'journal')))
  const owner = createAppOwnedReadOnlyPtcOwner({ bridge: createNativeIsolatedExecutionBridge(transport),
    callbacks, runtime: ctx.tools, services: { agents: ctx.agents } })
  t.after(async () => { await owner.close(); await callbacks.dispose() })
  const reviews = reviewReadOnlyToolsForModelPtc({ runtime: ctx.tools, agent, services: { agents: ctx.agents } })
  assert.deepEqual(reviews.map(row => row.name), ['read', 'glob', 'grep', 'web_search', 'web_fetch'])
  let available = false
  assert.equal(registerAndroidReadOnlyPtcTool(ctx, { owner, available: () => available }), false)
  assert.equal(ctx.tools.get('android_ptc', agent), undefined)
  available = true
  assert.equal(registerAndroidReadOnlyPtcTool(ctx, { owner, available: () => available }), true)
  const outcome = await ctx.tools.execute({ name: 'android_ptc', callId: 'readonly-parent',
    arguments: { description: 'Aggregate file and web data', code:
      'const r=await tools.read({file_path:"input.txt",limit:2}); const g=await tools.glob({pattern:"*.txt"}); const w=await tools.web_fetch({url:"https://example.test/page"}); return {line:r.lines[0].text,paths:g.paths,web:w.body.content.slice(0,9),truncated:w.truncated}' },
    agent, signal: new AbortController().signal })
  assert.equal(outcome.isError, false, JSON.stringify(outcome))
  assert.deepEqual(outcome.value, { logs: [], result: { line: 'alpha', paths: ['input.txt'], web: 'page-data', truncated: true } })
  const audits = agent.session.snapshotEvents().filter(event => event.type === 'tool/ptc-dispatch')
  assert.equal(audits.length, 3)
  assert.equal(audits.at(-1).data.isError, false)
  assert.match(audits.at(-1).data.content[0].text, /"truncated":true/u)
  audits.forEach((event, index) => assert.equal(event.data.content[0].text, JSON.stringify(delivered[index].value)))
  const transcript = {
    events: agent.session.snapshotEvents().filter(event => event.type.startsWith('tool/ptc-dispatch'))
      .map(event => ({ type: event.type, name: event.data.name,
        parentCallId: event.data.parentCallId, arguments: event.data.arguments,
        ...(event.type === 'tool/ptc-dispatch' ? { isError: event.data.isError } : {}) })),
    result: outcome.value.result,
  }
  assert.deepEqual(JSON.parse(JSON.stringify(transcript)), JSON.parse(await readFile(
    new URL('./expected/model-ptc-readonly.expected.json', import.meta.url), 'utf8')))
  available = false
  const denied = await ctx.tools.execute({ name: 'android_ptc', callId: 'closed-parent',
    arguments: { description: 'Must stay closed', code: 'return 1' }, agent, signal: new AbortController().signal })
  assert.equal(denied.isError, true)
  assert.equal(delivered.length, 3)
})
