import { test } from 'node:test'
import assert from 'node:assert/strict'
import { AppReferenceDiscovery } from '../runtime/reference-discovery.mjs'

const limits = () => ({ maxRequests: 4, requestTimeoutMs: 10000, closeTimeoutMs: 1000 })
const query = { owner: 'native-a', requestId: 'query-a', sessionId: 'session-a', query: 'src/', quoted: false }

test('both original Gateway namespaces receive the captured Agent and unmodified path query', async () => {
  const calls = []
  const carrier = new AppReferenceDiscovery({ limits, invoke: async (namespace, method, args, signal) => {
    calls.push({ namespace, method, args, signal })
    return namespace === 'fileReferences' ? [{ kind: 'file', path: 'src/资料.md' }] : [{ sessionId: 's2', mention: '@[other](dsh-session:InMyIg)' }]
  } })
  const result = await carrier.call('list', query)
  assert.deepEqual(calls.map(c => [c.namespace, c.method, c.args]), [
    ['fileReferences', 'list', { agentId: 'session-a', query: 'src/' }],
    ['sessionReferenceResolver', 'candidates', { agentId: 'session-a', query: 'src/' }],
  ])
  assert.equal(calls[0].signal, calls[1].signal)
  assert.equal(result.files.value[0].path, 'src/资料.md')
  assert.equal(result.sessions.value[0].sessionId, 's2')
  await carrier.close()
  assert.equal(carrier.active.size, 0)
})

test('quoted paths suppress sessions; one failed domain keeps the other original result', async () => {
  const called = []
  const carrier = new AppReferenceDiscovery({ limits, invoke: async namespace => {
    called.push(namespace)
    if (namespace === 'fileReferences') throw Object.assign(new Error('denied'), { code: 'gateway/forbidden' })
    return [{ sessionId: 'other' }]
  } })
  assert.deepEqual((await carrier.call('list', { ...query, quoted: true })).sessions, { ok: true, value: [] })
  assert.deepEqual(called, ['fileReferences'])
  const result = await carrier.call('list', query)
  assert.equal(result.files.error.code, 'gateway/forbidden')
  assert.deepEqual(result.sessions.value, [{ sessionId: 'other' }])
  await carrier.close()
})

test('cancellation belongs to Binder owner and drains both original providers', async () => {
  const started = Promise.withResolvers()
  const gates = []
  const carrier = new AppReferenceDiscovery({ limits, invoke: (_ns, _method, _args, signal) => {
    const gate = Promise.withResolvers()
    gates.push({ ...gate, signal })
    if (gates.length === 2) started.resolve()
    return gate.promise
  } })
  const pending = carrier.call('list', query)
  const rejected = assert.rejects(pending, { code: 'gateway/cancelled' })
  await started.promise
  await carrier.call('cancel', { owner: 'native-b', requestId: query.requestId })
  assert.equal(gates[0].signal.aborted, false)
  let drained = false
  const stopping = carrier.call('cancel', query).then(() => { drained = true })
  assert.equal(gates[0].signal.aborted, true)
  gates[0].resolve([])
  await Promise.resolve()
  assert.equal(drained, false)
  gates[1].resolve([])
  await Promise.all([rejected, stopping])
  assert.equal(carrier.active.size, 0)
  await carrier.close()
})

test('disconnect denies future queries and rejects late success without cancelling another owner', async () => {
  const called = Promise.withResolvers()
  const gates = []
  const carrier = new AppReferenceDiscovery({ limits, invoke: (_ns, _method, _args, signal) => {
    const gate = Promise.withResolvers()
    gates.push({ ...gate, signal })
    if (gates.length === 2) called.resolve()
    return gate.promise
  } })
  const pending = carrier.call('list', { ...query, quoted: true })
  const rejected = assert.rejects(pending, { code: 'gateway/cancelled' })
  const other = carrier.call('list', { ...query, owner: 'native-b', quoted: true })
  await called.promise
  const close = carrier.closeOwner('native-a')
  assert.equal(gates[1].signal.aborted, false)
  gates.forEach(gate => gate.resolve([]))
  await Promise.all([rejected, other, close])
  await assert.rejects(carrier.call('list', query), { code: 'gateway/cancelled' })
  await carrier.close()
})

test('bounded slots remain occupied until aborted provider completion', async () => {
  const gate = Promise.withResolvers()
  const started = Promise.withResolvers()
  const carrier = new AppReferenceDiscovery({ limits: () => ({ ...limits(), maxRequests: 1 }), invoke: (_ns, _method, _args, signal) => {
    started.resolve(signal)
    return gate.promise
  } })
  const pending = carrier.call('list', { ...query, quoted: true })
  const rejected = assert.rejects(pending, { code: 'gateway/cancelled' })
  await started.promise
  const stop = carrier.call('cancel', query)
  await assert.rejects(carrier.call('list', { ...query, requestId: 'next' }), { code: 'gateway/unavailable' })
  gate.resolve([])
  await Promise.all([stop, rejected])
  assert.equal(carrier.active.size, 0)
  await carrier.close()
})

test('bad identities and malformed requests never reach a provider', async () => {
  let calls = 0
  const carrier = new AppReferenceDiscovery({ limits, invoke: () => { calls++; return [] } })
  for (const patch of [{ owner: '' }, { requestId: '' }, { sessionId: '' }, { query: '\0' }, { quoted: 'true' }]) {
    await assert.rejects(carrier.call('list', { ...query, ...patch }), { code: 'gateway/bad-request' })
  }
  assert.equal(calls, 0)
  await carrier.close()
})

test('deadline answers before a stubborn provider exits, retaining capacity until real settlement', async () => {
  const gate = Promise.withResolvers()
  const carrier = new AppReferenceDiscovery({
    limits: () => ({ maxRequests: 1, requestTimeoutMs: 10, closeTimeoutMs: 10 }),
    invoke: () => gate.promise,
  })
  await assert.rejects(carrier.call('list', { ...query, quoted: true }), { code: 'gateway/timeout' })
  assert.equal(carrier.active.size, 1)
  await assert.rejects(carrier.call('list', { ...query, requestId: 'next' }), { code: 'gateway/unavailable' })
  await assert.rejects(carrier.closeOwner(query.owner), { code: 'gateway/timeout' })
  assert.equal(carrier.active.size, 1)
  gate.resolve([])
  await carrier.close()
  assert.equal(carrier.active.size, 0)
})
