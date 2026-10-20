import assert from 'node:assert/strict'
import test from 'node:test'

const staged = new URL('../../../.cache/android/runtime-bundle/node_modules/', import.meta.url)
const { AppSessions } = await import(new URL('@minnnng/dsh-android-runtime/sessions.mjs', staged))
const { AndroidCredentials } = await import(new URL('@minnnng/dsh-android-runtime/credentials.mjs', staged))
const { Context } = await import(new URL('@deepseek-ai/cordis/lib/index.js', staged))
const { AppLiveState } = await import(new URL('@minnnng/dsh-android-runtime/live-state.mjs', staged))

test('reconnecting App receives the in-flight text and live status, then drops settled stream text', () => {
  const handlers = new Map(), notifications = []
  const agent = { session: { id: 'running' }, status: 'running' }
  const live = new AppLiveState({
    on(name, callback) { handlers.set(name, callback) },
    agents: { list: () => [agent] },
  }, { notify(method, data) { notifications.push({ method, data }) } })
  const stream = handlers.get('agent/assistant-stream')
  stream({ agent, frame: { type: 'start' } })
  stream({ agent, frame: { type: 'chunk', chunk: { type: 'text-delta', text: 'hello' } } })
  assert.deepEqual(live.snapshot(), { revision: 2, statuses: { running: 'running' }, streaming: { running: 'hello' } })
  stream({ agent, frame: { type: 'end' } })
  assert.deepEqual(live.snapshot().streaming, {})
  assert.deepEqual(notifications.map(item => item.data.revision), [1, 2, 3])
})

test('App submissions use the live Web-owned Agent and do not reset its selected model', async () => {
  const calls = []
  const agent = { id: 'shared-session' }
  const sessions = new AppSessions({
    sessionController: { resolveAgent: async () => ({ agent }) },
  }, async (method, params) => { calls.push({ method, params }); return { accepted: true } })
  const receipt = await sessions.send({ sessionId: agent.id, requestId: 'request-one', text: 'hello',
    provider: 'unused-default-provider', model: 'unused-default-model', selectModel: false })
  assert.equal(receipt.accepted, true)
  assert.deepEqual(calls.map(call => call.method), ['prompt'])
  assert.equal(calls[0].params.requestId, 'request-one')
})

test('two App admissions for one Session wait for the shared controller in arrival order', async () => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  const order = []
  const sessions = new AppSessions({
    sessionController: { resolveAgent: async () => ({ agent: {} }) },
  }, async (method, params) => {
    assert.equal(method, 'prompt')
    order.push(params.requestId)
    if (params.requestId === 'one') { entered.resolve(); await release.promise }
    return { accepted: true }
  })
  const params = { sessionId: 'shared', text: 'hello', provider: 'p', model: 'm' }
  const first = sessions.send({ ...params, requestId: 'one' })
  await entered.promise
  const second = sessions.send({ ...params, requestId: 'two' })
  assert.deepEqual(order, ['one'])
  release.resolve()
  await Promise.all([first, second])
  assert.deepEqual(order, ['one', 'two'])
})

test('deleting a credential waits for an in-flight refresh and cannot resurrect its record', async () => {
  const ctx = new Context()
  const records = new Map([['records/account', JSON.stringify({ kind: 'initial' })]])
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  let provider
  const fiber = ctx.plugin({ apply(scope) {
    provider = new AndroidCredentials(scope, { async request(method, { name, value }) {
      if (method === 'native.credentials.get') return records.get(name) ?? null
      if (method === 'native.credentials.set') records.set(name, value)
      if (method === 'native.credentials.remove') records.delete(name)
      return true
    } })
  } })
  await fiber
  try {
    const update = provider.modifyRecord('account', async current => {
      assert.equal(current.kind, 'initial')
      entered.resolve()
      await release.promise
      return { kind: 'refreshed' }
    })
    await entered.promise
    const deletion = provider.deleteRecord('account')
    release.resolve()
    await Promise.all([update, deletion])
    assert.equal(records.has('records/account'), false)
  } finally {
    release.resolve()
    await fiber.dispose()
  }
})
