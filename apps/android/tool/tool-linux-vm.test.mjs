import assert from 'node:assert/strict'
import test from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { TOOL_ABORTED } from '@deepseek-ai/dsh-tools'
import FileSystem from '@deepseek-ai/dsh-fs-local'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import { mkdtemp, writeFile, readFile, mkdir, rm, symlink, truncate } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { registerLinuxVmTool, registerLinuxImportTool, registerLinuxExportTool, registerLinuxInspectTool } from '../runtime/tool-linux-vm.mjs'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { NativeLinuxVm } from '../runtime/native-linux-vm.mjs'
import { MockAdapter, textResponse, toolCallResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'

const expected = JSON.parse(await readFile(new URL('./expected/linux-vm-tools.expected.json', import.meta.url), 'utf8'))
function checkRenderedResult(result, name) {
  assert.deepEqual(result.value, expected[name])
  assert.deepEqual(result.content, [{ type: 'text', text: JSON.stringify(expected[name]) }])
}

async function setup(t, { mode = 'workspace-write', policy = true, android = false, adapter } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-linux-tools-'))
  const workspace = join(root, 'agent')
  await mkdir(workspace)
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  if (policy) await ctx.plugin(SandboxPolicy, { mode, workspaceRoot: root })
  await ctx.plugin(android ? AndroidFileSystem : FileSystem, { cwd: root })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  if (adapter) ctx.llm.registerAdapter(['linux-receipt-test'], adapter)
  const agent = await ctx.agentLoop.create(SessionId('android-linux-tool-test'),
    adapter ? { provider: 'linux-receipt-test', model: 'test' } : {}, { cwd: workspace })
  const calls = []
  const owner = {
    async execute(sessionId, args, signal, hostPolicy) {
      calls.push({ method: 'execute', sessionId, args, signal, hostPolicy })
      return { status: 'completed', output: 'Linux riscv64\n', exitCode: 0, diskCommitted: hostPolicy.persistChanges }
    },
    async importFile(sessionId, args, signal, hostPolicy) {
      calls.push({ method: 'import', sessionId, args, signal, hostPolicy })
      return { status: 'completed', source: args.source, destination: args.destination,
        bytes: 3, sha256: 'a'.repeat(64), diskCommitted: true }
    },
    async exportFile(sessionId, args, signal, hostPolicy) {
      calls.push({ method: 'export', sessionId, args, signal, hostPolicy })
      return { status: 'completed', exitCode: 0, source: args.source, destination: args.destination,
        bytes: 3, sha256: 'a'.repeat(64), diskCommitted: false, filePublished: true }
    },
  }
  const execute = (name, args, target = agent) => ctx.tools.execute({ agent: target,
    signal: new AbortController().signal, callId: `linux-${calls.length}`, name, arguments: args })
  return { ctx, agent, owner, calls, root, workspace, execute }
}

function nativeReceipt(params, extra = {}) {
  return { id: params.id, sessionId: params.sessionId, status: 'completed', output: '', exitCode: 0,
    guestUid: 99001, timedOut: false, cancelled: false, truncated: false,
    diskCommitted: true, retirementConfirmed: true, detail: null, ...extra }
}

function contextReceipt(result) {
  const context = result.additionalContexts?.find(item => item.source.kind === 'android-linux-receipt')
  assert.ok(context, JSON.stringify(result))
  return JSON.parse(context.content[0].text).linuxVmReceipt
}

function inspection(sessionId, requestedRunFound = null) {
  return { version: 1, sessionId, status: 'absent', blocked: false, needsReview: false,
    requestedRunFound, truncated: false, automaticReplay: false, records: [] }
}

test('read-only Linux inspection pins the live Agent Session and rejects caller-selected sessions', async t => {
  const { ctx, agent, execute } = await setup(t, { mode: 'read-only' })
  const requests = []
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    requests.push({ method, params }); return inspection(params.sessionId)
  } })
  t.after(() => owner.dispose())
  registerLinuxInspectTool(ctx, owner, true)
  const result = await execute('linux_inspect', {})
  assert.equal(result.isError, false)
  assert.deepEqual(result.value, inspection(String(agent.session.id)))
  assert.deepEqual(result.content, [{ type: 'text', text: JSON.stringify(result.value) }])
  const context = result.additionalContexts.find(item => item.source.kind === 'android-linux-inspection')
  assert.deepEqual(JSON.parse(context.content[0].text).linuxVmInspection, result.value)
  for (const args of [{ sessionId: 'other' }, { runId: '../outside' }, { retry: true }]) {
    assert.equal((await execute('linux_inspect', args)).isError, true)
  }
  assert.deepEqual(requests, [{ method: 'native.linuxVm.inspect', params: { sessionId: String(agent.session.id) } }])
})

test('cancelled inspection persists its observation into the next AgentLoop turn without replay', async t => {
  const adapter = new MockAdapter([
    toolCallResponse('inspect-recovery', 'linux_inspect', {}), textResponse('observation retained'),
  ])
  const { ctx, agent } = await setup(t, { adapter })
  let calls = 0
  const observation = { ...inspection(String(agent.session.id)), status: 'blocked', blocked: true,
    needsReview: true, records: [{ runId: 'd9ee88e9-038d-4078-bd3a-4b575a8bf760', operation: 'import',
      state: 'outcome_uncertain', retirementConfirmed: null, diskCommitted: null, filePublished: null,
      exitCode: null, reason: 'retirement_unconfirmed', needsReview: true }] }
  // Native returned the bounded observation before caller cancellation. The
  // real ToolRuntime and Session must retain it when the canonical call aborts.
  const owner = { async inspect(sessionId) {
    assert.equal(sessionId, String(agent.session.id)); calls++
    agent.cancel({ kind: 'user' }); return observation
  } }
  registerLinuxInspectTool(ctx, owner, true)
  agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'inspect pending work' }] }))
  await agent.whenIdle()
  const events = agent.session.snapshotEvents()
  const recorded = events.flatMap(event => event.type === 'agent/inbox/spliced' ? event.data.inserted : [])
    .find(message => message.source.kind === 'android-linux-inspection')
  assert.ok(recorded)
  assert.deepEqual(JSON.parse(recorded.content[0].text).linuxVmInspection, observation)
  assert.equal(events.find(event => event.type === 'tool/result').data.error.code, TOOL_ABORTED)
  agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'report status only' }] }))
  await agent.whenIdle()
  assert.equal(calls, 1)
  assert.match(JSON.stringify(adapter.requests[1].messages), /retirement_unconfirmed/)
})

test('AgentLoop retains a recovered commit from first-Session inspection without dispatching a new command', async t => {
  const adapter = new MockAdapter([
    toolCallResponse('recover-before-exec', 'linux_exec', { command: 'echo duplicate > state' }),
    textResponse('Previous committed work requires review; no command was started.'),
  ])
  const { ctx, agent } = await setup(t, { adapter })
  const observation = { ...inspection(String(agent.session.id)), status: 'ready', needsReview: true,
    records: [{ runId: 'd9ee88e9-038d-4078-bd3a-4b575a8bf760', operation: 'execute',
      state: 'recovered_committed', retirementConfirmed: true, diskCommitted: true, filePublished: null,
      exitCode: null, reason: 'pointer_committed', needsReview: true }] }
  const requests = []
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    requests.push({ method, params })
    assert.equal(method, 'native.linuxVm.inspect')
    return observation
  } })
  t.after(() => owner.dispose())
  registerLinuxVmTool(ctx, owner, true)
  agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'continue analysis' }] }))
  await agent.whenIdle()
  assert.deepEqual(requests, [{ method: 'native.linuxVm.inspect', params: { sessionId: String(agent.session.id) } }])
  const events = agent.session.snapshotEvents()
  const result = events.find(event => event.type === 'tool/result')
  assert.equal(result.data.error.code, 'linux-vm/recovery-required')
  const observations = events.flatMap(event => event.type === 'agent/inbox/spliced' ? event.data.inserted : [])
    .filter(message => message.source.kind === 'android-linux-inspection')
  assert.equal(observations.length, 1)
  assert.deepEqual(JSON.parse(observations[0].content[0].text).linuxVmInspection, observation)
  assert.equal(events.some(event => event.type === 'agent/inbox/spliced'
    && event.data.inserted.some(message => message.source.kind === 'android-linux-receipt')), false)
  assert.equal(adapter.requests.length, 2)
  const delivered = events.find(event => event.type === 'user/message'
    && event.data.source.kind === 'android-linux-inspection')
  assert.ok(delivered)
  assert.deepEqual(JSON.parse(delivered.data.content[0].text).linuxVmInspection, observation)
  assert.ok(JSON.stringify(adapter.requests[1].messages).includes(JSON.stringify(observations[0].content[0].text)))
})

test('cancelled ToolRuntime execution retains a completed disk commit and native run identity', async t => {
  const { ctx, agent } = await setup(t)
  const abort = new AbortController()
  let request
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    if (method === 'native.linuxVm.inspect') return inspection(params.sessionId)
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: true }
    request = params
    abort.abort(new DOMException('cancel after commit', 'AbortError'))
    return nativeReceipt(params)
  } })
  t.after(() => owner.dispose())
  registerLinuxVmTool(ctx, owner, true)
  const result = await ctx.tools.execute({ agent, signal: abort.signal, callId: 'commit-wins', name: 'linux_exec',
    arguments: { command: 'echo persisted > state' } })
  assert.equal(result.error.info.code, TOOL_ABORTED)
  assert.deepEqual(contextReceipt(result), { version: 1, tool: 'linux_exec', callId: 'commit-wins',
    sessionId: String(agent.session.id), runId: request.id, status: 'completed', diskCommitted: true,
    cancelRequested: true, retirementConfirmed: true, exitCode: 0 })
})

test('cancelled export retains host publication without claiming a guest disk commit', async t => {
  const { ctx, agent, root } = await setup(t, { android: true })
  const abort = new AbortController()
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    if (method === 'native.linuxVm.inspect') return inspection(params.sessionId)
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: true }
    abort.abort(new DOMException('cancel after publication', 'AbortError'))
    return nativeReceipt(params, { source: params.source, destination: params.destination,
      diskCommitted: false, filePublished: true, bytes: 3, sha256: 'a'.repeat(64) })
  } })
  t.after(() => owner.dispose())
  registerLinuxExportTool(ctx, owner, true, root)
  const result = await ctx.tools.execute({ agent, signal: abort.signal, callId: 'export-wins', name: 'linux_export',
    arguments: { source: 'report', destination: 'report' } })
  assert.equal(result.error.info.code, TOOL_ABORTED)
  const audit = contextReceipt(result)
  assert.equal(audit.filePublished, true)
  assert.equal(audit.diskCommitted, false)
  assert.equal(audit.cancelRequested, true)
  assert.equal(audit.sha256, 'a'.repeat(64))
})

test('uncertain publication is a structured ToolRuntime error, keeps true or unknown facts and closes its owner', async t => {
  for (const filePublished of [true, null]) {
    const { ctx, root, execute } = await setup(t, { android: true })
    let nativeCalls = 0
    const owner = new NativeLinuxVm({ request: async (method, params) => {
      if (method === 'native.linuxVm.inspect') return inspection(params.sessionId)
      if (method.endsWith('.cancel')) return { cancelRequested: false, settled: true }
      nativeCalls++
      return nativeReceipt(params, { status: 'outcome_uncertain', diskCommitted: false, filePublished })
    } })
    t.after(() => owner.dispose())
    registerLinuxExportTool(ctx, owner, true, root)
    const result = await execute('linux_export', { source: 'report', destination: 'report' })
    assert.deepEqual(result.error.info, { name: 'LinuxVmOutcomeUncertainError', code: 'linux-vm/outcome-uncertain' })
    const audit = contextReceipt(result)
    assert.equal(audit.status, 'outcome_uncertain')
    assert.equal(audit.filePublished, filePublished)
    assert.equal(audit.diskCommitted, false)
    assert.equal(audit.retirementConfirmed, true)
    const second = await execute('linux_export', { source: 'report', destination: 'report' })
    assert.equal(second.isError, true)
    assert.match(second.error.message, /owner is closed/)
    assert.equal(nativeCalls, 1)
  }
})

test('lost final receipt after caller cancellation remains unknown despite settled cancel acknowledgement', async t => {
  const { ctx, agent } = await setup(t)
  const abort = new AbortController()
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    if (method === 'native.linuxVm.inspect') return inspection(params.sessionId)
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: true }
    abort.abort(new DOMException('cancel', 'AbortError'))
    throw new Error('receipt transport lost')
  } })
  t.after(() => owner.dispose())
  registerLinuxVmTool(ctx, owner, true)
  const result = await ctx.tools.execute({ agent, signal: abort.signal, callId: 'receipt-lost', name: 'linux_exec',
    arguments: { command: 'echo data > state' } })
  assert.equal(result.error.info.code, 'linux-vm/outcome-uncertain')
  const audit = contextReceipt(result)
  assert.equal(audit.status, 'outcome_uncertain')
  assert.equal(audit.diskCommitted, null)
  assert.equal(audit.retirementConfirmed, null)
  assert.equal(audit.cancelRequested, true)
  await assert.rejects(owner.execute(String(agent.session.id), { command: 'id' },
    new AbortController().signal, { persistChanges: true }), /owner is closed/)
})

test('AgentLoop records the cancelled Linux receipt in Session inbox events and delivers it on the next turn', async t => {
  const adapter = new MockAdapter([
    toolCallResponse('linux-session-receipt', 'linux_exec', { command: 'echo retained > state' }),
    textResponse('receipt observed'),
  ])
  const { ctx, agent } = await setup(t, { adapter })
  let request
  const owner = new NativeLinuxVm({ request: async (method, params) => {
    if (method === 'native.linuxVm.inspect') return inspection(params.sessionId)
    if (method.endsWith('.cancel')) return { cancelRequested: true, settled: true }
    request = params
    agent.cancel({ kind: 'user' })
    return nativeReceipt(params)
  } })
  t.after(() => owner.dispose())
  registerLinuxVmTool(ctx, owner, true)
  agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'run fixture' }] }))
  await agent.whenIdle()
  const events = JSON.parse(JSON.stringify(agent.session.snapshotEvents()))
  const recorded = events.flatMap(event => event.type === 'agent/inbox/spliced' ? event.data.inserted : [])
    .find(message => message.source.kind === 'android-linux-receipt')
  assert.ok(recorded, JSON.stringify(events))
  assert.deepEqual(JSON.parse(recorded.content[0].text).linuxVmReceipt,
    { version: 1, tool: 'linux_exec', callId: 'linux-session-receipt', sessionId: String(agent.session.id),
      runId: request.id, status: 'completed', diskCommitted: true, cancelRequested: true,
      retirementConfirmed: true, exitCode: 0 })
  assert.equal(events.find(event => event.type === 'tool/result').data.error.code, TOOL_ABORTED)
  assert.equal(adapter.requests.length, 1)
  agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'continue' }] }))
  await agent.whenIdle()
  assert.ok(agent.session.snapshotEvents().some(event => event.type === 'user/message'
    && event.data.source.kind === 'android-linux-receipt'))
  assert.match(JSON.stringify(adapter.requests[1].messages), new RegExp(request.id))
})

test('Linux VM remains unavailable to models until its device and image checks are accepted', async t => {
  const { ctx, owner, calls } = await setup(t)
  registerLinuxVmTool(ctx, owner, false)
  registerLinuxImportTool(ctx, owner, false)
  registerLinuxExportTool(ctx, owner, false)
  registerLinuxInspectTool(ctx, owner, false)
  assert.equal(ctx.tools.get('linux_exec'), undefined)
  assert.equal(ctx.tools.get('linux_import'), undefined)
  assert.equal(ctx.tools.get('linux_export'), undefined)
  assert.equal(ctx.tools.get('linux_inspect'), undefined)
  assert.deepEqual(calls, [])
})

test('real ToolRuntime executes a guest script with its registered Agent identity', async t => {
  const { ctx, agent, owner, calls } = await setup(t)
  registerLinuxVmTool(ctx, owner, true)
  const signal = new AbortController().signal
  const result = await ctx.tools.execute({ agent, signal, callId: 'linux-1', name: 'linux_exec',
    arguments: { command: 'uname -sm', timeoutMs: 30000 } })
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.equal(calls.length, 1)
  assert.equal(calls[0].sessionId, String(agent.session.id))
  assert.deepEqual(calls[0].args, { command: 'uname -sm', timeoutMs: 30000 })
  assert.deepEqual(calls[0].hostPolicy, { persistChanges: true })
  assert.deepEqual(result.value, { status: 'completed', output: 'Linux riscv64\n', exitCode: 0, diskCommitted: true })
})

test('tool validation rejects a model-selected session or Android working directory before native dispatch', async t => {
  const { ctx, agent, owner, calls } = await setup(t)
  registerLinuxVmTool(ctx, owner, true)
  for (const extra of [{ sessionId: 'another-conversation' }, { cwd: '/data/user/0/com.minnnng.dsh_android' }, { persistChanges: true }]) {
    const result = await ctx.tools.execute({ agent, signal: new AbortController().signal,
      callId: 'linux-reject', name: 'linux_exec', arguments: { command: 'id', ...extra } })
    assert.equal(result.isError, true)
  }
  assert.deepEqual(calls, [])
})

test('read-only session commands use discard mode, and a session policy change is observed on the next call', async t => {
  const { ctx, agent, owner, calls, execute } = await setup(t, { mode: 'read-only' })
  registerLinuxVmTool(ctx, owner, true)
  const first = await execute('linux_exec', { command: 'echo temporary > state' })
  assert.equal(first.isError, false, JSON.stringify(first))
  assert.equal(first.value.diskCommitted, false)
  checkRenderedResult(first, 'readOnlyExecution')
  assert.deepEqual(calls[0].hostPolicy, { persistChanges: false })
  setSandboxMode(agent.session, 'workspace-write')
  const second = await execute('linux_exec', { command: 'echo persisted > state' })
  assert.equal(second.isError, false, JSON.stringify(second))
  assert.equal(second.value.diskCommitted, true)
  assert.deepEqual(calls[1].hostPolicy, { persistChanges: true })
})

test('absent policy and forged execution identity fail before dispatch', async t => {
  const { ctx, agent, owner, calls, execute } = await setup(t, { policy: false })
  registerLinuxVmTool(ctx, owner, true)
  assert.equal((await execute('linux_exec', { command: 'id' })).isError, true)
  await assert.rejects(ctx.tools.get('linux_exec').execute({ command: 'id' }, {
    agent, signal: new AbortController().signal,
  }), /current registered Agent execution/)
  assert.deepEqual(calls, [])
})

test('import uses the current Agent directory and emits only a canonical App-relative source', async t => {
  const { ctx, agent, owner, root, workspace, calls, execute } = await setup(t)
  await writeFile(join(workspace, 'app.apk'), 'apk')
  registerLinuxImportTool(ctx, owner, true, root)
  const result = await execute('linux_import', { source: 'app.apk', destination: 'analysis/app.apk' })
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.equal(calls[0].sessionId, String(agent.session.id))
  assert.deepEqual(calls[0].args, { source: 'agent/app.apk', destination: 'analysis/app.apk', timeoutMs: 120000 })
  assert.deepEqual(calls[0].hostPolicy, { persistChanges: true })
  checkRenderedResult(result, 'import')
})

test('read-only import is rejected even when the requested file is valid', async t => {
  const { ctx, owner, root, workspace, calls, execute } = await setup(t, { mode: 'read-only' })
  await writeFile(join(workspace, 'app.apk'), 'apk')
  registerLinuxImportTool(ctx, owner, true, root)
  const result = await execute('linux_import', { source: 'app.apk', destination: 'app.apk' })
  assert.equal(result.isError, true)
  assert.match(JSON.stringify(result), /writable session policy/)
  assert.deepEqual(calls, [])
})

test('import rejects native path, session and persistence overrides before touching the provider', async t => {
  const { ctx, owner, root, calls, execute } = await setup(t)
  registerLinuxImportTool(ctx, owner, true, root)
  for (const args of [
    { source: '../other.apk', destination: 'app.apk' },
    { source: 'content://grant/file', destination: 'app.apk' },
    { source: '/data/app.apk', destination: 'app.apk' },
    { source: 'app.apk', destination: '../app.apk' },
    { source: 'app.apk', destination: '/workspace/app.apk' },
    { source: 'app.apk', destination: 'app.apk', sessionId: 'other-agent' },
    { source: 'app.apk', destination: 'app.apk', persistChanges: true },
  ]) assert.equal((await execute('linux_import', args)).isError, true, JSON.stringify(args))
  assert.deepEqual(calls, [])
})

test('directories and files over 64 MiB are refused without native dispatch', async t => {
  const { ctx, owner, root, workspace, calls, execute } = await setup(t)
  await mkdir(join(workspace, 'folder'))
  const large = join(workspace, 'large.apk')
  await writeFile(large, '')
  await truncate(large, 64 * 1024 * 1024 + 1)
  registerLinuxImportTool(ctx, owner, true, root)
  for (const source of ['folder', 'large.apk']) {
    assert.equal((await execute('linux_import', { source, destination: 'app.apk' })).isError, true)
  }
  assert.deepEqual(calls, [])
})

test('a workspace symlink cannot import another Agent directory', async t => {
  const { ctx, owner, root, workspace, calls, execute } = await setup(t)
  const sibling = join(root, 'sibling')
  await mkdir(sibling)
  await writeFile(join(sibling, 'other.apk'), 'apk')
  await symlink(sibling, join(workspace, 'redirect'), process.platform === 'win32' ? 'junction' : 'dir')
  registerLinuxImportTool(ctx, owner, true, root)
  const result = await execute('linux_import', { source: 'redirect/other.apk', destination: 'app.apk' })
  assert.equal(result.isError, true)
  assert.deepEqual(calls, [])
})

test('permission revocation during file resolution is rechecked before native import', async t => {
  const { ctx, agent, owner, root, workspace, calls, execute } = await setup(t)
  await writeFile(join(workspace, 'app.apk'), 'apk')
  const stat = ctx.fs.stat.bind(ctx.fs)
  ctx.fs.stat = async (...args) => {
    const info = await stat(...args)
    setSandboxMode(agent.session, 'read-only')
    return info
  }
  registerLinuxImportTool(ctx, owner, true, root)
  const result = await execute('linux_import', { source: 'app.apk', destination: 'app.apk' })
  assert.equal(result.isError, true)
  assert.deepEqual(calls, [])
})

test('export uses the real Android write policy and publishes into the current Agent workspace', async t => {
  const { ctx, agent, owner, root, workspace, calls, execute } = await setup(t, { android: true })
  registerLinuxExportTool(ctx, owner, true, root)
  const result = await execute('linux_export', { source: 'report.txt', destination: 'reports/report.txt' })
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.deepEqual(calls[0].args, { source: 'report.txt', destination: 'agent/reports/report.txt', timeoutMs: 120000 })
  assert.equal(calls[0].sessionId, String(agent.session.id))
  assert.deepEqual(calls[0].hostPolicy, { persistChanges: true })
  assert.equal(result.value.file_path, join(workspace, 'reports/report.txt'))
  assert.equal(result.value.filePublished, true)
  assert.equal(result.value.diskCommitted, false)
  const { file_path, ...published } = result.value
  assert.deepEqual(published, expected.export)
  assert.deepEqual(result.content, [{ type: 'text', text: JSON.stringify({ ...expected.export, file_path }) }])
})

test('export rejects protected metadata, existing files and model-selected host identities', async t => {
  const { ctx, owner, root, workspace, calls, execute } = await setup(t, { android: true })
  await writeFile(join(workspace, 'existing.txt'), 'keep')
  registerLinuxExportTool(ctx, owner, true, root)
  for (const destination of ['existing.txt', '.git/config', '.agents/instructions.md', '.codex/auth.json', '.aws/credentials',
    '../outside.txt', '/data/private.txt', 'content://document/output']) {
    const result = await execute('linux_export', { source: 'report.txt', destination })
    assert.equal(result.isError, true, destination)
  }
  assert.equal((await execute('linux_export', { source: 'report.txt', destination: 'report.txt', sessionId: 'other' })).isError, true)
  assert.equal(await readFile(join(workspace, 'existing.txt'), 'utf8'), 'keep')
  assert.deepEqual(calls, [])
})

test('export refuses read-only policy and missing Android write authorization', async t => {
  const f = await setup(t, { mode: 'read-only', android: true })
  registerLinuxExportTool(f.ctx, f.owner, true, f.root)
  assert.equal((await f.execute('linux_export', { source: 'report.txt', destination: 'report.txt' })).isError, true)
  assert.deepEqual(f.calls, [])
  const other = await setup(t)
  registerLinuxExportTool(other.ctx, other.owner, true, other.root)
  assert.equal((await other.execute('linux_export', { source: 'report.txt', destination: 'report.txt' })).isError, true)
  assert.deepEqual(other.calls, [])
})

test('export rejects a destination alias outside the current session workspace', async t => {
  const { ctx, owner, root, workspace, calls, execute } = await setup(t, { android: true })
  const sibling = join(root, 'sibling'); await mkdir(sibling)
  await symlink(sibling, join(workspace, 'redirect'), process.platform === 'win32' ? 'junction' : 'dir')
  registerLinuxExportTool(ctx, owner, true, root)
  assert.equal((await execute('linux_export', { source: 'report.txt', destination: 'redirect/report.txt' })).isError, true)
  assert.deepEqual(calls, [])
})
