import assert from 'node:assert/strict'
import test from 'node:test'
import { registerHooks } from 'node:module'

const source = new URL('../runtime/sessions.mjs', import.meta.url).href
const staged = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/sessions.mjs', import.meta.url).href
registerHooks({
  resolve(specifier, context, nextResolve) {
    return nextResolve(specifier, context.parentURL === source && specifier === '@deepseek-ai/dsh-session'
      ? { ...context, parentURL: staged } : context)
  },
})
const { AppSessions } = await import(source)

function fixture({ exists = false, invoke, select, resolve } = {}) {
  const calls = []
  const sessions = new AppSessions({
    sessionController: { resolveAgent: async id => resolve ? resolve(id)
      : exists ? { agent: { id } } : { error: { code: 'session/not-found' } } },
  }, async (method, params) => {
    calls.push({ method, params })
    if (invoke) return invoke(method, params)
    if (method === 'create') { exists = true; return { sessionId: params.sessionId, agentPreset: params.agentPreset ?? 'android' } }
    return { accepted: true }
  }, async () => [], undefined, async (sessionId, agentPreset) => {
    calls.push({ method: 'selectPreset', params: { sessionId, agentPreset } })
    return select ? select(sessionId, agentPreset) : agentPreset
  })
  return { sessions, calls }
}
const message = { sessionId: 'draft', requestId: 'first', text: 'hello', provider: 'p', model: 'm' }

test('ensure and first message pass an explicit preset only to original creation', async () => {
  for (const method of ['ensure', 'send']) {
    const h = fixture()
    await h.sessions[method]({ ...message, agentPreset: 'custom' })
    assert.deepEqual(h.calls[0], { method: 'create', params: { sessionId: 'draft', cwd: process.cwd(), agentPreset: 'custom' } })
    assert.equal(h.calls.some(call => call.method === 'selectPreset'), false)
    if (method === 'ensure') assert.equal(h.calls.length, 1, 'ensure does not select a model or send input')
  }
  const h = fixture()
  await h.sessions.ensure('draft')
  assert.equal(Object.hasOwn(h.calls[0].params, 'agentPreset'), false, 'omission leaves the original default in control')
})

test('later ensure and messages keep an existing Web-owned composition', async () => {
  const h = fixture({ exists: true })
  await h.sessions.ensure({ sessionId: 'draft', agentPreset: 'new-default' })
  await h.sessions.send({ ...message, agentPreset: 'new-default' })
  assert.deepEqual(h.calls.map(call => call.method), ['prompt'])
})

test('preset selection prepares a new conversation and returns the original receipt unchanged', async () => {
  const h = fixture({ select: () => 'original-receipt' })
  assert.equal(await h.sessions.selectPreset({ sessionId: 'draft', agentPreset: 'custom' }), 'original-receipt')
  assert.deepEqual(h.calls.map(call => call.method), ['create', 'selectPreset'])
  assert.equal(h.calls[0].params.agentPreset, 'custom')
})

test('first send waits until an earlier preset selection settles', async () => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  const h = fixture({ exists: true, select: async () => { entered.resolve(); await release.promise; return 'custom' } })
  const selection = h.sessions.selectPreset({ sessionId: 'draft', agentPreset: 'custom' })
  await entered.promise
  const sent = h.sessions.send(message)
  assert.deepEqual(h.calls.map(call => call.method), ['selectPreset'])
  release.resolve()
  await Promise.all([selection, sent])
  assert.deepEqual(h.calls.map(call => call.method), ['selectPreset', 'prompt'])
})

test('selection after first admission preserves the original started-session refusal without replay', async () => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  const refusal = Object.assign(new Error('This session has already started'), {
    code: 'agent-preset/locked', details: { sessionId: 'draft', agentPreset: 'custom' },
  })
  const h = fixture({ exists: true, invoke: async () => { entered.resolve(); await release.promise; return { accepted: true } },
    select: () => { throw refusal } })
  const sent = h.sessions.send(message)
  await entered.promise
  const selection = h.sessions.selectPreset({ sessionId: 'draft', agentPreset: 'custom' })
  const rejected = assert.rejects(selection, error => error === refusal)
  assert.deepEqual(h.calls.map(call => call.method), ['prompt'])
  release.resolve()
  await Promise.all([sent, rejected])
  assert.deepEqual(h.calls.map(call => call.method), ['prompt', 'selectPreset'])
})

test('unknown, broken and unconfirmed selections keep their original failures and do not poison later explicit operations', async () => {
  for (const code of ['agent-preset/not-found', 'agent-preset/invalid', 'transport/closed']) {
    const refusal = Object.assign(new Error(code), { code, details: { reason: code } })
    let attempts = 0
    const h = fixture({ exists: true, select: () => { if (++attempts === 1) throw refusal; return 'android' } })
    await assert.rejects(h.sessions.selectPreset({ sessionId: 'draft', agentPreset: 'custom' }), error => error === refusal)
    assert.equal(attempts, 1)
    await h.sessions.ensure('draft')
    assert.equal(attempts, 1, 'read/reconnect preparation must not replay a write')
    assert.equal(await h.sessions.selectPreset({ sessionId: 'draft', agentPreset: 'android' }), 'android')
    assert.equal(attempts, 2)
  }
})

test('malformed optional preset values are refused before session activation or mutation', () => {
  const h = fixture({ resolve: () => { assert.fail('invalid request must not resolve an Agent') } })
  for (const agentPreset of [null, false, 10, {}, [], '', '  ']) {
    for (const method of ['ensure', 'send', 'selectPreset']) {
      assert.throws(() => h.sessions[method]({ ...message, agentPreset }), /agentPreset/)
    }
  }
  assert.throws(() => h.sessions.selectPreset({ sessionId: 'draft' }), /agentPreset/)
  assert.deepEqual(h.calls, [])
})

test('a changed original creation identity cannot select or send against the old requested session', async () => {
  const h = fixture({ invoke: () => ({ sessionId: 'different-original-id' }) })
  await assert.rejects(h.sessions.selectPreset({ sessionId: 'draft', agentPreset: 'custom' }), /Session identity changed/)
  assert.deepEqual(h.calls.map(call => call.method), ['create'])
})
