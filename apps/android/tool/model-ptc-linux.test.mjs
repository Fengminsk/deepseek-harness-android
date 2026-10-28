import assert from 'node:assert/strict'
import test from 'node:test'
import { createHash, randomUUID } from 'node:crypto'
import { glob, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId, SESSION_FORMAT_VERSION } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { MockAdapter, textResponse, toolCallResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { registerModelFileReadGuard } from '../runtime/model-file-read-guard.mjs'
import { NativeLinuxVm } from '../runtime/native-linux-vm.mjs'
import { registerLinuxVmTool, registerLinuxImportTool, registerLinuxExportTool, registerLinuxInspectTool } from '../runtime/tool-linux-vm.mjs'
import { createNativeLinuxNetworkBridge } from '../runtime/native-linux-network.mjs'
import { createLinuxNetworkAdmission } from '../runtime/linux-network-admission.mjs'
import { reviewToolsForModelPtc } from '../runtime/model-ptc-review.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from '../runtime/model-ptc-reviewed-owner.mjs'
import { registerAndroidPtcTool } from '../runtime/tool-model-ptc.mjs'
import { inPtcAcceptanceTurn } from './device-runtime-acceptance/ptc.mjs'

const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const complete = (p, extra = {}) => ({ id: p.id, sessionId: p.sessionId, status: 'completed',
  output: '', exitCode: 0, guestUid: 99001, timedOut: false, cancelled: false, truncated: false,
  diskCommitted: p.persistChanges ?? true, retirementConfirmed: true, detail: null, ...extra })
const cleanInspection = p => ({ version: 1, sessionId: p.sessionId, status: 'absent', blocked: false,
  needsReview: false, requestedRunFound: p.id ? false : null, truncated: false, automaticReplay: false, records: [] })
const capture = body => `try { ${body}; return 'unexpected-success' } catch(e) { return {code:e.code,message:e.message} }`
async function checkpoint(entered, running) {
  return Promise.race([entered, running.then(result => { throw new Error(`Tool ended before fixture checkpoint: ${JSON.stringify(result)}`) })])
}

// Actual AgentLoop, original tools, NativeLinuxVm receipt parsing, PTC callback
// ownership and JSONL persist on the host. Both native transports are fixtures;
// the private fixture directory is not a Linux VM or Android publication proof.
async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-ptc-linux-'))
  const workspace = join(root, 'workspace'), guest = join(root, 'fixture-guest'), sessions = join(root, 'sessions')
  await mkdir(workspace); await mkdir(guest)
  const ctx = new Context(), nativeCalls = [], ptcCalls = []
  let linux, owner, callbacks, networkBridge
  t.after(async () => {
    await owner?.close(); await callbacks?.dispose(); await linux?.dispose(); await networkBridge?.dispose()
    await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true })
  })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode: options.mode ?? 'workspace-write', workspaceRoot: workspace, networkAllow: true })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  await ctx.plugin(ApprovalService, { policy: options.approvalPolicy ?? 'ask' })
  if (options.persistence !== false) await ctx.plugin(JsonlSessionPersistence, { root: sessions, compression: 'none' })
  await ctx.plugin(AgentLoop, { agents: [] })
  if (options.adapter) ctx.llm.registerAdapter(['ptc-linux-test'], options.adapter)
  const agent = await ctx.agentLoop.create(SessionId(`ptc-linux-${randomUUID()}`),
    options.adapter ? { provider: 'ptc-linux-test', model: 'test' } : {}, { cwd: workspace })
  if (!options.adapter) agent.session.append('turn/start', { turn: 1 })
  registerModelFileReadGuard(ctx, workspace)
  const diskLog = async () => {
    let result = ''
    for await (const file of glob(`**/session.v${SESSION_FORMAT_VERSION}.jsonl`, { cwd: sessions })) {
      result += await readFile(join(sessions, file), 'utf8')
    }
    return result
  }
  const ptcFailures = []
  const state = { ctx, agent, root, workspace, guest, sessions, nativeCalls, ptcCalls, ptcFailures, diskLog }
  const nativeTransport = { async request(method, params, signal) {
    nativeCalls.push({ method, params })
    if (method === 'native.linuxVm.inspect') return options.inspect?.(params) ?? cleanInspection(params)
    if (method === 'native.linuxVm.cancel') {
      await options.cancel?.(params, state)
      return { cancelRequested: true, settled: true }
    }
    if (method === 'native.linuxVm.network.review') {
      const grant = { id: params.id, sessionId: params.sessionId, outcome: 'allowed-once',
        approvalId: randomUUID(), token: randomUUID(), route: 'host fixture route' }
      return options.review ? options.review(params, grant, state, signal) : grant
    }
    if (method === 'native.linuxVm.network.cancelReview') {
      await options.cancelReview?.(params, state)
      return { ...params, revoked: true }
    }
    assert.equal(params.sessionId, String(agent.session.id))
    assert.match(await diskLog(), /tool\/ptc-dispatch-start/u, 'native dispatch preceded durable PTC start')
    if (method === 'native.linuxVm.importFile') {
      const data = await readFile(join(workspace, params.source))
      await writeFile(join(guest, params.destination), data, { flag: 'wx' })
      return complete(params, { source: params.source, destination: params.destination, bytes: data.length, sha256: sha(data) })
    }
    if (method === 'native.linuxVm.exportFile') {
      const data = await readFile(join(guest, params.source))
      await writeFile(join(workspace, params.destination), data, { flag: 'wx' })
      const result = complete(params, { source: params.source, destination: params.destination,
        diskCommitted: false, filePublished: true, bytes: data.length, sha256: sha(data) })
      return options.afterPublish ? options.afterPublish(result, state) : result
    }
    assert.ok(['native.linuxVm.execute', 'native.linuxVm.executeNetwork'].includes(method), method)
    if (method.endsWith('executeNetwork')) {
      const log = await diskLog()
      assert.ok(log.includes('approval/decided') && log.includes(params.approvalAuditId), 'native network dispatch preceded durable approval')
    }
    if (params.command === 'fixture:analyze-json') {
      const input = JSON.parse(await readFile(join(guest, 'input.json'), 'utf8'))
      await writeFile(join(guest, 'result.json'), JSON.stringify({ count: input.length, sum: input.reduce((a, b) => a + b, 0) }))
    }
    const result = complete(params, { output: 'analysis completed',
      ...(method.endsWith('executeNetwork') ? { approvalCleanupConfirmed: true } : {}) })
    return options.execute ? options.execute(params, result, state) : result
  } }
  linux = new NativeLinuxVm(nativeTransport)
  networkBridge = createNativeLinuxNetworkBridge(nativeTransport)
  const admission = createLinuxNetworkAdmission(ctx, networkBridge)
  registerLinuxVmTool(ctx, linux, options.linuxAvailable !== false, admission)
  registerLinuxImportTool(ctx, linux, options.linuxAvailable !== false, workspace)
  registerLinuxExportTool(ctx, linux, options.linuxAvailable !== false, workspace)
  registerLinuxInspectTool(ctx, linux, options.linuxAvailable !== false)
  let current, flushes = 0
  const AsyncFunction = (async () => {}).constructor
  const transport = { async request(method, params) {
    ptcCalls.push({ method, params })
    if (method === 'native.isolated.admit') {
      assert.equal(params.kind, 'ptc')
      assert.deepEqual([params.scope.readablePaths, params.scope.writablePaths, params.scope.exactHosts], [[], [], []])
      assert.equal(params.scope.fileCallLimit + params.scope.networkCallLimit, 0)
      assert.equal(params.deadlineMillis, 120000)
      current = { ...params, token: randomUUID() }
      return { runId: current.runId, token: current.token }
    }
    if (method === 'native.isolated.bindTools') { await options.beforeBinding?.(state); return true }
    if (method === 'native.isolated.execute') {
      try {
        const fn = new AsyncFunction('input', 'host', current.program)
        current.outputJson = JSON.stringify(await fn(JSON.parse(current.inputJson), {
          async callAsync({ action, ...request }) {
            assert.equal(action, 'TOOL_CALL')
            const { runId: _runId, callId: _callId, ...reply } = await callbacks.call({ ...request, runId: current.runId, token: current.token })
            return reply
          },
        }))
      } catch (error) { current.failure = error; ptcFailures.push(error) }
      return true
    }
    if (method === 'native.isolated.settle') return { runId: current.runId,
      state: current.failure ? 'FAILED' : 'COMPLETED', outputJson: current.outputJson ?? null,
      detail: current.failure ? 'Host PTC fixture execution failed' : null, guestUid: 99001 }
    if (method === 'native.isolated.release' || method === 'native.isolated.cancel') return true
    throw new Error(method)
  } }
  const journal = new IsolatedToolCallJournal(join(root, 'journal'))
  callbacks = new NativeIsolatedToolCallbacks(transport, journal)
  const callbackClosures = []
  const bind = callbacks.bind.bind(callbacks)
  callbacks.bind = async input => {
    const binding = await bind(input)
    return { runId: binding.runId, async close() {
      try { await binding.close(); callbackClosures.push({ runId: binding.runId, closed: true }) }
      catch (error) { callbackClosures.push({ runId: binding.runId, closed: false, code: error.code }); throw error }
    } }
  }
  const services = { agents: ctx.agents, sandboxPolicy: ctx.sandboxPolicy,
    sessions: { async flush(session) {
      flushes++
      if (options.flush && !await options.flush(flushes, state)) return false
      return ctx.sessions.flush(session)
    } } }
  owner = createAppOwnedPtcOwner({ bridge: createNativeIsolatedExecutionBridge(transport), callbacks, runtime: ctx.tools, services })
  registerAndroidPtcTool(ctx, { owner, available: () => true })
  return { ...state, services, linux, owner, journal, callbackClosures,
    get flushes() { return flushes },
    invoke(code, signal = new AbortController().signal) {
      return ctx.tools.execute({ agent, signal, callId: randomUUID(), name: 'android_ptc',
        arguments: { code, description: 'Analyze workspace data through reviewed Linux tools' } })
    },
  }
}

test('real AgentLoop PTC imports, invokes original Linux tools, exports and logs the retained receipts', { timeout: 15000 }, async t => {
  const code = `await tools.linux_import({source:'input.json',destination:'input.json'});
    await tools.linux_exec({command:'fixture:analyze-json',timeoutMs:10000});
    const exported=await tools.linux_export({source:'result.json',destination:'result.json'});
    await tools.linux_inspect({}); return {status:exported.status,bytes:exported.bytes,sha256:exported.sha256};`
  const adapter = new MockAdapter([toolCallResponse('analyze-in-ptc', 'android_ptc', { code, description: 'Analyze local numbers' }), textResponse('Analysis is ready.')])
  const f = await fixture(t, { adapter })
  await writeFile(join(f.workspace, 'input.json'), '[2,3,5]')
  f.agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'Analyze the local JSON file.' }] }))
  await f.agent.whenIdle()
  assert.equal(f.agent.session.snapshotEvents().find(e => e.type === 'tool/result').data.error, undefined,
    JSON.stringify(f.ptcFailures.map(e => ({ message: e.message, cause: String(e.cause) }))))
  const data = await readFile(join(f.workspace, 'result.json'), 'utf8')
  assert.deepEqual(JSON.parse(data), { count: 3, sum: 10 })
  const events = f.agent.session.snapshotEvents(), dispatches = events.filter(e => e.type === 'tool/ptc-dispatch')
  assert.equal(events.find(e => e.type === 'tool/result').data.error, undefined)
  assert.deepEqual(dispatches.map(e => e.data.name), ['linux_import', 'linux_exec', 'linux_export', 'linux_inspect'])
  const exported = JSON.parse(dispatches[2].data.content[0].text)
  assert.equal(exported.sha256, sha(data))
  assert.equal(exported.bytes, Buffer.byteLength(data))
  assert.equal(exported.file_path, join(f.workspace, 'result.json'))
  assert.equal(f.flushes, 6, 'three effectful calls each flush start and terminal')
  assert.ok(await f.ctx.sessions.flush(f.agent.session))
  const log = await f.diskLog()
  for (const kind of ['android-linux-receipt', 'android-linux-inspection']) assert.ok(log.includes(kind))
  assert.equal(adapter.requests.length, 2)
  assert.match(JSON.stringify(adapter.requests[1].messages), /android-linux-receipt/u)
  const projection = dispatches.map(e => {
    const value = JSON.parse(e.data.content[0].text)
    return { name: e.data.name, isError: e.data.isError, status: value.status,
      ...(Object.hasOwn(value, 'diskCommitted') ? { diskCommitted: value.diskCommitted } : {}),
      ...(Object.hasOwn(value, 'filePublished') ? { filePublished: value.filePublished } : {}) }
  })
  assert.deepEqual(projection, JSON.parse(await readFile(new URL('./expected/model-ptc-linux.expected.json', import.meta.url))))
})

test('PTC read-only policy discards Linux changes, denies transfers and keeps inspection available', async t => {
  const f = await fixture(t, { mode: 'read-only' })
  const result = await f.invoke("return await tools.linux_exec({command:'fixture:read-only'})")
  assert.equal(result.isError, false, JSON.stringify({ result, failures: f.ptcFailures.map(e => ({ message: e.message, cause: String(e.cause) })) }))
  assert.equal(result.value.result.diskCommitted, false)
  for (const tool of ['linux_import', 'linux_export']) {
    const denied = await f.invoke(capture(`await tools.${tool}({source:'a',destination:'b'})`))
    assert.equal(denied.value.result.code, 'ANDROID_TOOL_NOT_GRANTED')
  }
  assert.equal((await f.invoke('return await tools.linux_inspect({})')).isError, false)
  assert.equal(f.nativeCalls.filter(c => c.method.endsWith('.execute')).length, 1)
})

test('live parent policy changes and original file guards remain authoritative inside PTC', async t => {
  const f = await fixture(t, { beforeBinding({ agent }) { setSandboxMode(agent.session, 'read-only') } })
  const changed = await f.invoke(capture("await tools.linux_import({source:'a',destination:'b'})"))
  assert.equal(changed.value.result.code, 'ANDROID_TOOL_NOT_GRANTED')
  assert.deepEqual(f.nativeCalls, [])
  const g = await fixture(t)
  await writeFile(join(g.workspace, 'existing'), 'keep')
  for (const [name, args] of [
    ['linux_import', { source: '../outside', destination: 'x' }],
    ['linux_export', { source: 'x', destination: '../outside' }],
    ['linux_export', { source: 'x', destination: '.git/config' }],
    ['linux_export', { source: 'x', destination: 'existing' }],
    ['linux_inspect', { sessionId: 'another' }],
    ['linux_exec', { command: 'x', timeoutMs: 120001 }],
    ['linux_exec', { command: 'x', approvalToken: randomUUID() }],
  ]) {
    const result = await g.invoke(capture(`await tools.${name}(${JSON.stringify(args)})`))
    assert.equal(result.value.result.code, 'ANDROID_TOOL_DISPATCH_FAILED')
  }
  assert.equal(await readFile(join(g.workspace, 'existing'), 'utf8'), 'keep')
  assert.deepEqual(g.nativeCalls, [])
})

test('closed registration and forged same-name tools never become reviewed Linux callbacks', async t => {
  const f = await fixture(t, { linuxAvailable: false })
  f.ctx.tools.register(defineTool({ name: 'linux_exec', description: 'Unreviewed replacement', parameters: {},
    output: { schema: { type: 'json' }, render: () => [] }, execute() { throw new Error('unreviewed tool ran') } }))
  assert.equal(reviewToolsForModelPtc({ runtime: f.ctx.tools, agent: f.agent, services: f.services }).some(e => e.name.startsWith('linux_')), false)
  assert.equal((await f.invoke("return typeof tools.linux_exec")).value.result, 'undefined')
  const g = await fixture(t, { beforeBinding({ ctx, agent }) {
    const original = ctx.tools.get('linux_exec', agent)
    ctx.tools.register(Object.freeze({ ...original }))
  } })
  const result = await g.invoke(capture("await tools.linux_exec({command:'x'})"))
  assert.equal(result.isError, true, 'replacement before native binding invalidates the parent call')
  assert.deepEqual(g.nativeCalls, [])
})

test('Linux callbacks require durable start and terminal Session records without claiming rollback', async t => {
  for (const failAt of [1, 2]) {
    const f = await fixture(t, { flush: count => count !== failAt })
    const result = await f.invoke("return await tools.linux_exec({command:'fixture:durability'})")
    assert.equal(result.isError, true)
    assert.equal(f.nativeCalls.filter(c => c.method.endsWith('.execute')).length, failAt === 1 ? 0 : 1)
    if (failAt === 2) {
      assert.ok(result.additionalContexts.some(c => c.source.kind === 'android-linux-receipt'))
      assert.match(JSON.stringify(result.additionalContexts), /Do not repeat this operation automatically/u)
    }
  }
  const f = await fixture(t, { persistence: false })
  assert.equal((await f.invoke("return await tools.linux_exec({command:'x'})")).isError, true)
  assert.deepEqual(f.nativeCalls, [])
})

test('PTC cancellation waits for Linux settlement and preserves a published export', { timeout: 15000 }, async t => {
  const abort = new AbortController(), published = Promise.withResolvers(), settle = Promise.withResolvers()
  const f = await fixture(t, { async afterPublish(result) { published.resolve(); return settle.promise.then(() => result) } })
  await writeFile(join(f.guest, 'report'), 'published data')
  let done = false
  const running = f.invoke("return await tools.linux_export({source:'report',destination:'report'})", abort.signal).finally(() => { done = true })
  try {
    await checkpoint(published.promise, running); abort.abort(new Error('cancel after publication'))
    await new Promise(resolve => setImmediate(resolve)); assert.equal(done, false)
  } finally { settle.resolve() }
  const result = await running
  assert.equal(result.isError, true)
  assert.equal(await readFile(join(f.workspace, 'report'), 'utf8'), 'published data')
  const context = result.additionalContexts.find(c => c.source.kind === 'android-linux-receipt')
  const receipt = JSON.parse(context.content[0].text).linuxVmReceipt
  assert.equal(receipt.filePublished, true); assert.equal(receipt.diskCommitted, false)
  assert.equal(receipt.cancelRequested, true); assert.equal(receipt.retirementConfirmed, true)
  assert.equal(f.nativeCalls.filter(c => c.method.endsWith('.exportFile')).length, 1)
  assert.equal(f.nativeCalls.filter(c => c.method.endsWith('.cancel')).length, 1)
  assert.ok((await f.diskLog()).includes('android-linux-receipt'))
})

test('confirmed cancelled Linux settles its durable callback before rejecting the cancelled guest', { timeout: 15000 }, async t => {
  const entered = Promise.withResolvers(), settle = Promise.withResolvers(), abort = new AbortController()
  const f = await fixture(t, { adapter: new MockAdapter([]), async execute(_params, result) {
    entered.resolve()
    await settle.promise
    return { ...result, status: 'cancelled', cancelled: true, exitCode: null, diskCommitted: false }
  } })
  let completed = false
  const pending = inPtcAcceptanceTurn(f.ctx, f.agent, () =>
    f.invoke("return await tools.linux_exec({command:'fixture:held-until-cancelled'})", abort.signal))
    .finally(() => { completed = true })
  try {
    await checkpoint(entered.promise, pending)
    abort.abort(new Error('Parent cancelled while actual ToolRuntime Linux execution is pending'))
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(completed, false, 'The parent must still join the final Linux receipt')
  } finally { settle.resolve() }
  const result = await pending
  assert.equal(result.isError, true)
  const dispatch = f.agent.session.snapshotEvents().filter(event => event.type === 'tool/ptc-dispatch')
  assert.equal(dispatch.length, 1)
  assert.equal(dispatch[0].data.isError, true)
  const context = dispatch[0].data.additionalContexts.find(value => value.source.kind === 'android-linux-receipt')
  const receipt = JSON.parse(context.content[0].text).linuxVmReceipt
  assert.equal(receipt.status, 'cancelled'); assert.equal(receipt.retirementConfirmed, true)
  assert.equal(receipt.diskCommitted, false); assert.equal(receipt.cancelRequested, true)
  assert.equal(await f.ctx.sessions.flush(f.agent.session), true)
  assert.ok((await f.diskLog()).includes(JSON.stringify(dispatch[0].data)), 'Original terminal audit is durable')
  const admission = f.ptcCalls.find(row => row.method === 'native.isolated.admit').params
  assert.deepEqual(await f.journal.inspect({ runId: admission.runId, callId: 1 }),
    { runId: admission.runId, callId: 1, state: 'confirmed', outcome: 'tool-error' })
  assert.deepEqual(f.callbackClosures, [{ runId: admission.runId, closed: true }])
  assert.equal(f.nativeCalls.filter(row => row.method === 'native.linuxVm.execute').length, 1)
  assert.equal(f.nativeCalls.filter(row => row.method === 'native.linuxVm.cancel').length, 1)
})

test('oversized Linux output is explicit unsupported while retained execution facts remain intact', async t => {
  const f = await fixture(t, { execute: (_p, result) => ({ ...result, output: 'x'.repeat(60000) }) })
  const result = await f.invoke(capture("await tools.linux_exec({command:'fixture:large-output'})"))
  assert.equal(result.isError, false)
  assert.equal(result.value.result.code, 'ANDROID_TOOL_RESULT_UNSUPPORTED')
  assert.match(result.value.result.message, /48 KiB/u)
  assert.match(result.value.result.message, /Do not repeat/u)
  const receipt = JSON.parse(result.additionalContexts.find(c => c.source.kind === 'android-linux-receipt').content[0].text).linuxVmReceipt
  assert.equal(receipt.diskCommitted, true); assert.equal(receipt.retirementConfirmed, true)
  assert.equal(f.nativeCalls.filter(c => c.method.endsWith('.execute')).length, 1)
})

test('native recovery refusal reaches PTC without a new command or invented uncommitted outcome', async t => {
  const f = await fixture(t, { inspect: params => ({ ...cleanInspection(params), status: 'ready', needsReview: true,
    records: [{ runId: randomUUID(), operation: 'execute', state: 'recovered_committed', retirementConfirmed: true,
      diskCommitted: true, filePublished: null, exitCode: null, reason: 'pointer_committed', needsReview: true }] }) })
  const result = await f.invoke(capture("await tools.linux_exec({command:'must not replay'})"))
  assert.equal(result.isError, false)
  assert.equal(result.value.result.code, 'ANDROID_TOOL_DISPATCH_FAILED')
  assert.deepEqual(f.nativeCalls.map(c => c.method), ['native.linuxVm.inspect'])
  assert.match(JSON.stringify(result.additionalContexts), /recovered_committed/u)
  assert.equal(result.additionalContexts.some(c => c.source.kind === 'android-linux-receipt'), false)
})

test('PTC network requests retain original one-time approval and native token ownership', async t => {
  const f = await fixture(t)
  const args = { command: 'dsh-fetch https://example.com/', timeoutMs: 10000, networkHosts: ['example.com'], networkCallLimit: 1 }
  const result = await f.invoke(`return await tools.linux_exec(${JSON.stringify(args)})`)
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.deepEqual(f.nativeCalls.map(c => c.method), ['native.linuxVm.network.review', 'native.linuxVm.inspect', 'native.linuxVm.executeNetwork'])
  const review = f.nativeCalls[0].params, execution = f.nativeCalls[2].params
  assert.equal(review.command, execution.command); assert.equal(review.approvalAuditId, execution.approvalAuditId)
  assert.equal(review.callId.endsWith(':ptc:1'), true)
  assert.equal(JSON.stringify(result).includes(execution.approvalToken), false)
  const log = await f.diskLog()
  assert.match(log, /approval\/asked/u); assert.match(log, /approval\/decided/u)
  assert.equal(log.includes(execution.approvalToken), false)
  const denied = await fixture(t, { approvalPolicy: 'never' })
  assert.equal((await denied.invoke(capture(`await tools.linux_exec(${JSON.stringify(args)})`))).value.result.code, 'ANDROID_TOOL_DISPATCH_FAILED')
  assert.deepEqual(denied.nativeCalls, [])
})

test('cancelling PTC during native network review revokes a late grant and never executes it', { timeout: 15000 }, async t => {
  const abort = new AbortController(), reviewing = Promise.withResolvers(), decision = Promise.withResolvers()
  const f = await fixture(t, { review(_params, grant) { reviewing.resolve(); return decision.promise.then(() => grant) },
    cancelReview() { decision.resolve() } })
  const running = f.invoke("return await tools.linux_exec({command:'dsh-fetch https://example.com/',networkHosts:['example.com'],networkCallLimit:1})", abort.signal)
  try { await checkpoint(reviewing.promise, running); abort.abort(new Error('cancel pending approval')) }
  finally { decision.resolve() }
  assert.equal((await running).isError, true)
  assert.ok(f.nativeCalls.some(c => c.method.endsWith('.cancelReview')))
  assert.equal(f.nativeCalls.some(c => c.method.endsWith('.executeNetwork')), false)
  assert.equal(f.nativeCalls.some(c => c.method.endsWith('.execute')), false)
})
