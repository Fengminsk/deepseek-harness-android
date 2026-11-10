import assert from 'node:assert/strict'
import { executeToolCall } from './tool-batch-fixture.mjs'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { mkdtemp, rm, readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { MockAdapter, textResponse, toolCallResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'
import { createLinuxNetworkAdmission, prepareLinuxModelCommand } from '../runtime/linux-network-admission.mjs'
import { createNativeLinuxNetworkBridge } from '../runtime/native-linux-network.mjs'
import { NativeLinuxVm } from '../runtime/native-linux-vm.mjs'
import { registerLinuxVmTool } from '../runtime/tool-linux-vm.mjs'

const input = { command: 'dsh-fetch https://example.com/', timeoutMs: 10000,
  networkHosts: ['example.com'], networkCallLimit: 2 }
const completed = p => ({ id: p.id, sessionId: p.sessionId, status: 'completed', output: 'Example Domain', exitCode: 0,
  guestUid: 99001, timedOut: false, cancelled: false, truncated: false,
  diskCommitted: p.persistChanges, retirementConfirmed: true, detail: null })

async function fixture(t, { persistence = true, policy = 'ask', mode = 'workspace-write',
  reply, beforeExecute, executeReply, adapter } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-linux-network-'))
  const ctx = new Context(), requests = []
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(ApprovalService, { policy })
  await ctx.plugin(SandboxPolicy, { mode, workspaceRoot: root, networkAllow: true })
  if (persistence) await ctx.plugin(JsonlSessionPersistence, { root, compression: 'none' })
  await ctx.plugin(AgentLoop, { agents: [] })
  if (adapter) ctx.llm.registerAdapter(['network-test'], adapter)
  const agent = await ctx.agentLoop.create(SessionId(`linux-network-${randomUUID()}`),
    adapter ? { provider: 'network-test', model: 'test' } : {})
  if (!adapter) agent.session.append('turn/start', { turn: 1 })
  const transport = { async request(method, params, signal) {
    requests.push({ method, params, signal })
    if (method === 'native.linuxVm.network.review') {
      const result = { id: params.id, sessionId: params.sessionId, outcome: 'allowed-once',
        approvalId: randomUUID(), token: randomUUID(), route: '系统网络 / VPN' }
      return reply ? reply(params, result, { ctx, agent, signal }) : result
    }
    if (method === 'native.linuxVm.network.cancelReview') return { ...params, revoked: true }
    if (method === 'native.linuxVm.inspect') return { version: 1, sessionId: params.sessionId,
      status: 'absent', blocked: false, needsReview: false, requestedRunFound: null,
      truncated: false, automaticReplay: false, records: [] }
    if (method === 'native.linuxVm.executeNetwork' || method === 'native.linuxVm.execute') {
      await beforeExecute?.(params, { ctx, agent, root, requests })
      const result = { ...completed(params), ...(method.endsWith('executeNetwork') ? { approvalCleanupConfirmed: true } : {}) }
      return executeReply ? executeReply(result) : result
    }
    throw new Error(method)
  } }
  const bridge = createNativeLinuxNetworkBridge(transport)
  const admission = createLinuxNetworkAdmission(ctx, bridge)
  const owner = new NativeLinuxVm(transport)
  t.after(() => owner.dispose())
  registerLinuxVmTool(ctx, owner, true, admission)
  const invoke = (args = input, signal = new AbortController().signal) => executeToolCall(ctx.tools, {
    agent, name: 'linux_exec', arguments: args, callId: randomUUID(), signal })
  return { ctx, agent, root, requests, invoke, bridge, admission, owner }
}

test('model network fields describe exact public DNS hosts and explicit bounded request count', () => {
  assert.deepEqual(prepareLinuxModelCommand(input).network, { exactHosts: ['example.com'], networkCallLimit: 2 })
  for (const extra of [
    { networkHosts: [] }, { networkHosts: ['*.example.com'] }, { networkHosts: ['EXAMPLE.com'] },
    { networkHosts: ['127.0.0.1'] }, { networkHosts: ['localhost'] }, { networkHosts: ['device.local'] },
    { networkHosts: ['a.internal'] }, { networkHosts: ['a.test'] }, { networkHosts: ['home.arpa'] },
    { networkHosts: ['a.123'] }, { networkHosts: ['a..com'] }, { networkHosts: ['https://example.com'] },
    { networkHosts: ['example.com.'] }, { networkHosts: ['example.com', 'example.com'] },
    { networkHosts: ['例子.com'] }, { networkCallLimit: 0 }, { networkCallLimit: 65 },
    { approved: true }, { approvalToken: randomUUID() }, { persistChanges: true }, { sessionId: 'another' },
  ]) assert.throws(() => prepareLinuxModelCommand({ ...input, ...extra }))
  assert.throws(() => prepareLinuxModelCommand({ command: 'x', networkHosts: ['example.com'] }))
  assert.throws(() => prepareLinuxModelCommand({ command: 'x', networkCallLimit: 1 }))
  assert.throws(() => prepareLinuxModelCommand({ ...input, networkHosts: Array(1) }))
})

test('original approval audit is flushed before the native single-use command dispatch', async t => {
  const f = await fixture(t, { beforeExecute: async (params, { root, agent, requests }) => {
    const review = requests.find(row => row.method.endsWith('.review')).params
    assert.equal(params.id, review.id)
    assert.equal(params.sessionId, String(agent.session.id))
    assert.equal(params.command, input.command)
    assert.equal(params.approvalAuditId, review.approvalAuditId)
    assert.ok(params.approvalToken)
    assert.equal('exactHosts' in params, false)
    const files = await readdir(root, { recursive: true })
    const persisted = (await Promise.all(files.filter(file => file.endsWith('.jsonl'))
      .map(file => readFile(join(root, file), 'utf8')))).join('\n')
    assert.ok(persisted.includes('approval/asked'))
    assert.ok(persisted.includes('approval/decided'))
    assert.ok(persisted.includes(params.approvalAuditId))
  } })
  const result = await f.invoke()
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.deepEqual(f.requests.map(row => row.method), [
    'native.linuxVm.network.review', 'native.linuxVm.inspect', 'native.linuxVm.executeNetwork'])
  const projection = result.additionalContexts.find(value => value.source.kind === 'android-linux-network-approval')
  assert.ok(projection)
  assert.equal(JSON.stringify(projection).includes('approvalToken'), false)
  assert.equal(JSON.stringify(projection).includes(f.requests.at(-1).params.approvalToken), false)
})

test('omitted network request stays offline even when session networkAllow is true', async t => {
  const f = await fixture(t)
  assert.equal((await f.invoke({ command: 'echo offline' })).isError, false)
  assert.deepEqual(f.requests.map(row => row.method), ['native.linuxVm.inspect', 'native.linuxVm.execute'])
  assert.equal(f.agent.session.snapshotEvents().some(event => event.type === 'approval/asked'), false)
})

test('never rejects without invoking native UI or executing despite a generally approving answerer', async t => {
  const f = await fixture(t, { policy: 'never' })
  f.ctx.on('approval/request', async () => 'allowed-once', { prepend: true })
  const result = await f.invoke()
  assert.equal(result.isError, true)
  assert.equal(result.error.info.code, 'linux-vm/network-rejected')
  assert.deepEqual(f.requests, [])
  assert.equal(f.agent.session.snapshotEvents().find(event => event.type === 'approval/decided').data.outcome, 'rejected')
})

test('an unrelated approving answerer cannot create a native network grant', async t => {
  const f = await fixture(t)
  f.ctx.on('approval/request', async () => 'allowed-once', { prepend: true })
  assert.equal((await f.invoke()).isError, true)
  assert.deepEqual(f.requests, [])
})

test('native rejection, malformed decisions and absent Session durability revoke before dispatch', async t => {
  for (const options of [
    { reply: (_p, result) => ({ ...result, outcome: 'rejected', token: null, approvalId: null, route: null }) },
    { reply: (_p, result) => ({ ...result, sessionId: 'wrong' }) },
    { reply: (_p, result) => ({ ...result, token: 'not-a-token' }) },
    { reply: () => { throw new Error('UI unavailable') } }, { persistence: false },
  ]) {
    const f = await fixture(t, options)
    const result = await f.invoke()
    assert.equal(result.isError, true, JSON.stringify(result))
    assert.deepEqual(f.requests.map(row => row.method), ['native.linuxVm.network.review', 'native.linuxVm.network.cancelReview'])
  }
})

test('a policy change during native review revokes permission instead of dispatching a different command', async t => {
  const f = await fixture(t, { reply: (_p, reply, { agent }) => {
    setSandboxMode(agent.session, 'read-only'); return reply
  } })
  const result = await f.invoke()
  assert.equal(result.error.info.code, 'linux-vm/network-approval-stale')
  assert.deepEqual(f.requests.map(row => row.method), ['native.linuxVm.network.review', 'native.linuxVm.network.cancelReview'])
})

test('a replaced registration cannot consume a prior native permission', async t => {
  const f = await fixture(t, { reply: (_p, reply, { ctx }) => {
    ctx.tools.register(defineTool({ name: 'linux_exec', description: 'replacement', parameters: {},
      output: { schema: { type: 'json' }, render: () => [] }, execute: () => 'replacement' }))
    return reply
  } })
  assert.equal((await f.invoke()).isError, true)
  assert.equal(f.requests.at(-1).method, 'native.linuxVm.network.cancelReview')
  assert.equal(f.requests.some(row => row.method.endsWith('executeNetwork')), false)
})

test('caller cancellation during review revokes the native plan and ignores a late grant', async t => {
  const abort = new AbortController()
  const f = await fixture(t, { reply: (_p, reply) => { abort.abort(); return reply } })
  const result = await f.invoke(input, abort.signal)
  assert.equal(result.isError, true)
  assert.equal(f.requests.filter(row => row.method.endsWith('.cancelReview')).length, 1)
  assert.equal(f.requests.some(row => row.method.endsWith('executeNetwork')), false)
})

test('a cancelled ToolRuntime call joins its native approval answerer before returning', async t => {
  const began = Promise.withResolvers(), finish = Promise.withResolvers(), abort = new AbortController()
  let response, settled = false
  const f = await fixture(t, { reply: (_p, reply) => { response = reply; began.resolve(); return finish.promise } })
  const pending = f.invoke(input, abort.signal).finally(() => { settled = true })
  await began.promise
  abort.abort()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(settled, false)
  assert.equal(f.requests.at(-1).method, 'native.linuxVm.network.cancelReview')
  finish.resolve(response)
  assert.equal((await pending).isError, true)
  assert.equal(f.requests.some(row => row.method.endsWith('executeNetwork')), false)
})

test('read-only policy is approved and dispatched without disk persistence', async t => {
  const f = await fixture(t, { mode: 'read-only' })
  const result = await f.invoke()
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.equal(f.requests[0].params.persistChanges, false)
  assert.equal(f.requests.at(-1).params.persistChanges, false)
  assert.equal(result.value.diskCommitted, false)
})

test('unconfirmed approval cleanup retains the committed command receipt and blocks later execution', async t => {
  const f = await fixture(t, { executeReply: value => ({ ...value,
    approvalCleanupConfirmed: false, approvalCleanupError: 'durable-revocation-unconfirmed' }) })
  const result = await f.invoke()
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.equal(result.value.status, 'completed')
  assert.equal(result.value.diskCommitted, true)
  assert.equal(result.value.output, 'Example Domain')
  assert.equal(result.value.retirementConfirmed, true)
  assert.equal(result.value.needsReview, true)
  assert.match(result.value.approvalCleanupMessage, /停止后续命令/)
  const deferred = JSON.parse(result.additionalContexts.find(value =>
    value.source.kind === 'android-linux-receipt').content[0].text).linuxVmReceipt
  assert.equal(deferred.approvalCleanupConfirmed, false)
  assert.equal(deferred.needsReview, true)
  const again = await f.invoke({ command: 'echo should-not-run' })
  assert.equal(again.isError, true)
  assert.equal(f.requests.filter(row => row.method.endsWith('executeNetwork')).length, 1)
})

test('missing network cleanup evidence cannot be reported as a completed operation', async t => {
  const f = await fixture(t, { executeReply: value => {
    const { approvalCleanupConfirmed: _ignored, ...missing } = value
    return missing
  } })
  const result = await f.invoke()
  assert.equal(result.isError, true)
  assert.match(JSON.stringify(result), /outcome-uncertain/)
})

test('real AgentLoop records one approval pair and the native correlation without its token', async t => {
  const adapter = new MockAdapter([toolCallResponse('network-once', 'linux_exec', input), textResponse('read complete')])
  const f = await fixture(t, { adapter })
  f.agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: 'read example.com' }] }))
  await f.agent.whenIdle()
  const events = f.agent.session.snapshotEvents()
  assert.deepEqual(events.filter(event => event.type.startsWith('approval/')).map(event => event.type),
    ['approval/asked', 'approval/decided'])
  assert.equal(events.find(event => event.type === 'tool/result').data.error, undefined)
  assert.equal(events.find(event => event.type === 'approval/decided').data.outcome, 'allowed-once')
  const request = f.requests.find(row => row.method.endsWith('executeNetwork')).params
  assert.ok(JSON.stringify(events).includes(request.approvalAuditId))
  assert.equal(JSON.stringify(events).includes(request.approvalToken), false)
  assert.ok(JSON.stringify(adapter.requests[1].messages).includes('linuxNetworkApproval'))
  const approved = events.find(event => event.type === 'user/message'
    && event.data.source.kind === 'android-linux-network-approval').data
  const audit = JSON.parse(approved.content[0].text).linuxNetworkApproval
  const receipt = JSON.parse(events.find(event => event.type === 'tool/result').data.message.content[0].text)
  const projection = {
    asked: { ...events.find(event => event.type === 'approval/asked').data, id: '<approval-audit>' },
    decided: { ...events.find(event => event.type === 'approval/decided').data, id: '<approval-audit>' },
    receipt: { ...receipt, id: '<run>', sessionId: '<session>' },
    modelContext: { ...audit, runId: '<run>', approvalId: '<native-approval>', approvalAuditId: '<approval-audit>' },
  }
  assert.deepEqual(projection, JSON.parse(await readFile(new URL('./expected/linux-network-approval.expected.json', import.meta.url), 'utf8')))
})


