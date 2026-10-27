import test from 'node:test'
import assert from 'node:assert/strict'
import { randomBytes, randomUUID } from 'node:crypto'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import * as DeepSeek from '@deepseek-ai/dsh-llm-deepseek-api-key'
import * as Retry from '@deepseek-ai/dsh-llm-retry'
import * as TimeContext from '@deepseek-ai/dsh-time-context'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { SessionId } from '@deepseek-ai/dsh-session'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { startTransportRecoveryModel } from './device-runtime-acceptance/model-transport-recovery-model.mjs'
import { requireTransportRecoveryEvidence, requireTransportRequestContinuation, transportRequestShape, transportRequestDifference } from './device-runtime-acceptance/model-transport-recovery-evidence.mjs'

async function fixture(t, mode = 'reset') {
  const caseId = randomUUID(), modelKey = randomBytes(32).toString('base64url'), closeToken = randomBytes(32).toString('base64url')
  const persisted = []
  const model = await startTransportRecoveryModel({ caseId, modelKey, closeToken, mode,
    persist: async value => { persisted.push(value) } })
  const control = async (path, body) => {
    const response = await fetch(`${model.url}/acceptance/${path}`, { method: 'POST', headers: {
      authorization: `Bearer ${closeToken}`, 'x-dsh-acceptance-case': caseId },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    assert.equal(response.status, 200)
    return response.json()
  }
  t.after(() => model.close())
  return { ...model, caseId, modelKey, closeToken, persisted, control }
}

async function realAgent(t, mode = 'reset', { cancel = false, refreshContext = false } = {}) {
  const f = await fixture(t, mode)
  const oldKey = process.env.DEEPSEEK_API_KEY
  process.env.DEEPSEEK_API_KEY = f.modelKey
  const ctx = new Context()
  t.after(async () => {
    try { await ctx.fiber.dispose() } finally {
      if (oldKey === undefined) delete process.env.DEEPSEEK_API_KEY
      else process.env.DEEPSEEK_API_KEY = oldKey
    }
  })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(DeepSeek, { baseURL: f.url })
  await ctx.plugin(Retry)
  await ctx.plugin(TimeContext, { timeZone: 'UTC' })
  let context = 'Before transport reset.'
  if (refreshContext) ctx.systemPrompt.context({ name: 'transport-context', order: 0, text: () => context })
  ctx.tools.register(defineTool({ name: 'transport_unused', description: 'Never called by the transport fixture', parameters: {},
    output: { schema: { type: 'json' } }, execute: async () => { assert.fail('Recovery must not invoke tools') } }))
  await ctx.plugin(AgentLoop, { agents: [] })
  const agent = await ctx.agentLoop.create(SessionId(`android-acceptance-transport-${f.caseId}`), {
    provider: 'deepseek-official', model: 'deepseek-flash',
  })
  let consumed = false, disconnect
  ctx.on('agent/assistant-stream', ({ agent: sender, frame }) => {
    if (sender === agent && frame.type === 'chunk' && frame.chunk.type === 'text-delta'
      && frame.chunk.text === `transport-partial-${f.caseId}`) {
      assert.equal(consumed, false)
      consumed = true
      disconnect = f.control('disconnect')
    }
  })
  if (cancel) ctx.on('session/event', (session, event) => {
    if (session === agent.session && event.type === 'llm/retry') agent.cancel({ kind: 'user' })
  })
  if (refreshContext) ctx.on('session/event', (session, event) => {
    if (session === agent.session && event.type === 'llm/retry') context = 'After transport reset.'
  })
  const idle = agent.whenIdle()
  agent.followup(createUserMessage({ content: [{ type: 'text', text: `Return transport-recovered-${f.caseId}.` }], source: { kind: 'user' } }))
  await idle
  await disconnect
  assert.equal(consumed, true)
  return { ...f, events: agent.session.snapshotEvents() }
}

test('real HTTP/SSE reset recovers through the original adapter, AgentLoop and unchanged retry policy', { timeout: 15000 }, async t => {
  const f = await realAgent(t)
  const evidence = requireTransportRecoveryEvidence({ caseId: f.caseId, events: f.events, durableEvents: f.events, proof: f.snapshot() })
  assert.equal(evidence.reconnected, true)
  assert.equal(evidence.modelCalls, 2)
  assert.equal(evidence.requestBodyUnchanged, true)
  assert.equal(evidence.runtimeContextUpdates, 0)
  const checked = await f.control('verify', { events: f.events, durableEvents: f.events })
  assert.deepEqual(checked, evidence)
  await f.control('close')
  await f.close()
  assert.equal(f.snapshot().closed, true)
  await assert.rejects(fetch(f.url))
  // Mutated negative evidence must not pass as an Android or persistent retry.
  for (const mutate of [
    rows => rows.filter(row => row.type !== 'assistant/attempt'),
    rows => rows.concat(rows.find(row => row.type === 'user/message' && row.data.source.kind === 'user')),
    rows => rows.map(row => row.type === 'llm/retry' ? { ...row, data: { ...row.data, failure: { code: 'STREAM_CLOSED' } } } : row),
    rows => rows.map(row => row.type === 'llm/retry-started' ? { ...row, data: { ...row.data, retryId: 'wrong' } } : row),
    rows => rows.map(row => row.type === 'turn/end' ? { ...row, data: { ...row.data, reason: { kind: 'error' } } } : row),
  ]) assert.throws(() => requireTransportRecoveryEvidence({ caseId: f.caseId, events: mutate(f.events), durableEvents: mutate(f.events), proof: f.snapshot() }))
  assert.throws(() => requireTransportRecoveryEvidence({ caseId: f.caseId, events: f.events, durableEvents: f.events.slice(0, -1), proof: f.snapshot() }))
})

test('real retry refreshes original runtime context without resending the user or changing request settings', { timeout: 15000 }, async t => {
  const f = await realAgent(t, 'reset', { refreshContext: true })
  assert.notEqual(f.snapshot().requestHashes[0], f.snapshot().requestHashes[1], 'Old raw-body equality rejects the original retry')
  const evidence = requireTransportRecoveryEvidence({ caseId: f.caseId, events: f.events, durableEvents: f.events, proof: f.snapshot() })
  assert.equal(evidence.requestBodyUnchanged, false)
  assert.equal(evidence.requestChangesAccountedFor, true)
  assert.equal(evidence.runtimeContextUpdates, 1)
  assert.deepEqual(await f.control('verify', { events: f.events, durableEvents: f.events }), evidence)
  const retrySeq = f.events.find(row => row.type === 'llm/retry-started').seq
  for (const mutate of [
    rows => rows.filter(row => !(row.type === 'user/message' && row.data.source.kind === 'runtime-context' && row.seq > retrySeq)),
    rows => rows.map(row => row.type === 'user/message' && row.data.source.kind === 'runtime-context' && row.seq > retrySeq
      ? { ...row, data: { ...row.data, source: { kind: 'user' } } } : row),
    rows => rows.map(row => row.type === 'user/message' && row.data.source.kind === 'runtime-context' && row.seq > retrySeq
      ? { ...row, data: { ...row.data, content: [{ type: 'text', text: 'Unrelated update' }] } } : row),
  ]) assert.throws(() => requireTransportRecoveryEvidence({ caseId: f.caseId, events: mutate(f.events),
    durableEvents: mutate(f.events), proof: f.snapshot() }))
  assert.throws(() => requireTransportRecoveryEvidence({ caseId: f.caseId, events: f.events,
    durableEvents: f.events.filter(row => !(row.type === 'user/message' && row.seq > retrySeq && row.data.source.kind === 'runtime-context')),
    proof: f.snapshot() }))
})

test('request continuation rejects changed input, existing history, model, tools and non-context additions', () => {
  const body = { model: 'fixture', stream: true, tools: [{ name: 'unused' }], messages: [
    { role: 'user', content: [{ type: 'text', text: 'Original context' }, { type: 'text', text: 'Original user' }] }] }
  const first = transportRequestShape(body)
  for (const mutate of [
    value => { value.messages[0].content[1].text = 'Changed user' },
    value => { value.messages[0].content[0].text = 'Changed history' },
    value => { value.messages[0].content.shift() },
    value => { value.model = 'different' },
    value => { value.tools.push({ name: 'new-tool' }) },
    value => { value.thinking = { type: 'enabled' } },
    value => { value.system = 'Changed system instruction' },
    value => { value.unknown_extension = { changed: true } },
    value => { value.messages.push({ role: 'assistant', content: [{ type: 'text', text: 'Replayed partial' }] }) },
    value => { value.messages[0].content.push({ type: 'tool_result', content: [] }) },
  ]) {
    const changed = structuredClone(body); mutate(changed)
    assert.throws(() => requireTransportRequestContinuation(first, transportRequestShape(changed)))
  }
})

test('difference diagnostics record every changed top-level shape without exposing unknown names or values', () => {
  const secret = 'PRIVATE_UNKNOWN_FIELD_OR_CONTENT'
  const first = transportRequestShape({ model: 'original', messages: [], metadata: { a: 1, b: 2 }, [secret]: secret })
  const second = transportRequestShape({ model: 'changed', messages: [], metadata: { b: 2, a: 1 }, [secret]: secret + '!' })
  const changed = transportRequestDifference(first, second)
  assert.equal(changed.length, 3)
  assert.deepEqual(changed.map(field => field.name).sort(), ['metadata', 'model', 'other'])
  assert.equal(changed.find(field => field.name === 'metadata').semanticChanged, false)
  assert.equal(changed.find(field => field.name === 'other').semanticChanged, true)
  assert.equal(JSON.stringify(changed).includes(secret), false)
  for (const field of changed) for (const side of [field.before, field.after]) {
    assert.match(side.sha256, /^[0-9a-f]{64}$/u)
    assert.ok(side.bytes > 0)
  }
})

test('real HTTP retry with changed model settings fails with bounded stage and difference diagnostics', async t => {
  const f = await fixture(t)
  const body = { model: 'fixture', stream: true, tools: [{ name: 'unused' }], messages: [
    { role: 'user', content: [{ type: 'text', text: `Return transport-recovered-${f.caseId}.` }] }] }
  const headers = { 'x-api-key': f.modelKey, 'x-deepseek-harness-session-id': `android-acceptance-transport-${f.caseId}` }
  const first = await fetch(`${f.url}/v1/messages`, { method: 'POST', headers, body: JSON.stringify(body) })
  const reader = first.body.getReader()
  await reader.read()
  const drained = (async () => { try { while (!(await reader.read()).done) {} } catch {} })()
  await f.control('disconnect'); await drained
  const changed = await fetch(`${f.url}/v1/messages`, { method: 'POST', headers, body: JSON.stringify({ ...body, model: 'different' }) })
  assert.equal(changed.status, 400)
  const proof = f.snapshot()
  assert.equal(proof.modelCalls, 2)
  assert.equal(proof.failureStage, 'retry-continuation')
  assert.equal(proof.failureReason, 'request-continuation')
  assert.equal(proof.requestDifference.nonMessageFieldsEqual, false)
  assert.equal(proof.requestDifference.existingBlocksEqual, true)
  for (const secret of [f.modelKey, f.closeToken, `Return transport-recovered-${f.caseId}.`]) {
    assert.equal(JSON.stringify(proof).includes(secret), false)
  }
})

test('clean partial EOF is STREAM_CLOSED and never becomes the positive recovery proof', { timeout: 15000 }, async t => {
  const f = await realAgent(t, 'eof')
  assert.equal(f.snapshot().modelCalls, 1)
  assert.equal(f.events.filter(row => row.type === 'llm/retry').length, 0)
  assert.equal(f.events.filter(row => row.type === 'assistant/message').length, 0)
  const end = f.events.find(row => row.type === 'turn/end')
  assert.equal(end.data.reason.kind, 'error')
  assert.equal(end.data.reason.error.code, 'STREAM_CLOSED')
  assert.throws(() => requireTransportRecoveryEvidence({ caseId: f.caseId, events: f.events, durableEvents: f.events, proof: f.snapshot() }))
})

test('cancellation during real backoff prevents reconnection and final success', { timeout: 15000 }, async t => {
  const f = await realAgent(t, 'reset', { cancel: true })
  assert.equal(f.snapshot().modelCalls, 1)
  assert.equal(f.events.filter(row => row.type === 'llm/retry').length, 1)
  assert.equal(f.events.filter(row => row.type === 'llm/retry-started').length, 0)
  assert.equal(f.events.filter(row => row.type === 'assistant/message').length, 0)
  assert.notEqual(f.events.find(row => row.type === 'turn/end').data.reason.kind, 'completed')
})

test('control credentials cannot be substituted by the model key', async t => {
  const f = await fixture(t)
  const response = await fetch(`${f.url}/acceptance/disconnect`, { method: 'POST', headers: {
    authorization: `Bearer ${f.modelKey}`, 'x-dsh-acceptance-case': f.caseId } })
  assert.equal(response.status, 401)
  assert.equal(f.snapshot().disconnects, 0)
  assert.equal(f.snapshot().failure, null)
  assert.equal(f.snapshot().unauthenticatedRequests, 1)
  assert.equal(JSON.stringify(f.snapshot()).includes(f.modelKey), false)
})

test('an authenticated control with the wrong case fails the owned fixture', async t => {
  const f = await fixture(t)
  const response = await fetch(`${f.url}/acceptance/disconnect`, { method: 'POST', headers: {
    authorization: `Bearer ${f.closeToken}`, 'x-dsh-acceptance-case': randomUUID() } })
  assert.equal(response.status, 400)
  assert.notEqual(f.snapshot().failure, null)
  assert.equal(f.snapshot().failureStage, 'control-authentication')
  assert.equal(f.snapshot().failureReason, 'control-case')
  assert.equal(f.snapshot().disconnects, 0)
})

test('an unauthenticated probe cannot change an admitted request or its final evidence', async t => {
  const f = await realAgent(t)
  const original = f.snapshot()
  const response = await fetch(`${f.url}/foreign-probe?private=ignored`, { method: 'GET' })
  assert.equal(response.status, 401)
  assert.equal(f.snapshot().failure, null)
  assert.deepEqual(f.snapshot().requestHashes, original.requestHashes)
  assert.equal(requireTransportRecoveryEvidence({ caseId: f.caseId, events: f.events, durableEvents: f.events, proof: f.snapshot() }).modelCalls, 2)
})
