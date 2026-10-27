import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { createNativeLinuxNetworkBridge, armLinuxNetworkGrant, consumeLinuxNetworkGrant,
  discardLinuxNetworkGrant, linuxNetworkGrantIdentity, requireNativeLinuxNetworkBridge } from '../runtime/native-linux-network.mjs'
import { NativeLinuxVm } from '../runtime/native-linux-vm.mjs'

const plan = () => ({ sessionId: 'linux-network-test', callId: 'network-test', approvalAuditId: randomUUID(),
  command: 'dsh-fetch https://example.com/', timeoutMs: 10000, persistChanges: false,
  exactHosts: ['example.com'], networkCallLimit: 2 })
const approved = input => ({ id: input.id, sessionId: input.sessionId, outcome: 'allowed-once',
  token: randomUUID(), approvalId: randomUUID(), route: '系统网络 / VPN' })
const execution = (ticket, input) => ({ ...linuxNetworkGrantIdentity(ticket), command: input.command,
  timeoutMs: input.timeoutMs, persistChanges: input.persistChanges })

test('grant tokens are inaccessible to model JSON and consumed only once for an unchanged command', async () => {
  const bridge = createNativeLinuxNetworkBridge({ request: async (_method, input) => approved(input) })
  const input = plan(), review = await bridge.review(input, new AbortController().signal)
  assert.deepEqual(JSON.parse(JSON.stringify(review.ticket)), {})
  assert.throws(() => requireNativeLinuxNetworkBridge({ review: bridge.review }))
  assert.throws(() => linuxNetworkGrantIdentity(review.ticket), /flushed/)
  let checks = 0
  armLinuxNetworkGrant(review.ticket, () => checks++)
  const command = execution(review.ticket, input)
  for (const changed of [{ command: 'echo another' }, { sessionId: 'another' },
    { timeoutMs: 1001 }, { persistChanges: true }, { id: randomUUID() }]) {
    assert.throws(() => consumeLinuxNetworkGrant(review.ticket, { ...command, ...changed }), /differs/)
  }
  assert.throws(() => consumeLinuxNetworkGrant({}, command))
  const wire = consumeLinuxNetworkGrant(review.ticket, command)
  assert.equal(wire.approvalAuditId, input.approvalAuditId)
  assert.equal(typeof wire.approvalToken, 'string')
  assert.equal(checks, 2)
  assert.throws(() => consumeLinuxNetworkGrant(review.ticket, command))
  await discardLinuxNetworkGrant(review.ticket)
  await bridge.dispose()
})

test('unconfirmed revocation closes network approval and never permits another review', async () => {
  let calls = 0
  const bridge = createNativeLinuxNetworkBridge({ request: async (method, input) => {
    calls++
    return method.endsWith('.review') ? approved(input) : { ...input, revoked: false }
  } })
  const review = await bridge.review(plan(), new AbortController().signal)
  await assert.rejects(discardLinuxNetworkGrant(review.ticket), { code: 'linux-vm/network-revocation-uncertain' })
  assert.throws(() => armLinuxNetworkGrant(review.ticket, () => {}))
  await assert.rejects(bridge.review(plan(), new AbortController().signal), /停止/)
  assert.equal(calls, 2)
  await bridge.dispose()
})

test('disposing an unused native grant revokes it and prevents later consumption', async () => {
  const methods = []
  const bridge = createNativeLinuxNetworkBridge({ request: async (method, input) => {
    methods.push(method)
    return method.endsWith('.review') ? approved(input) : { ...input, revoked: true }
  } })
  const review = await bridge.review(plan(), new AbortController().signal)
  armLinuxNetworkGrant(review.ticket, () => {})
  await bridge.dispose()
  assert.throws(() => linuxNetworkGrantIdentity(review.ticket))
  assert.deepEqual(methods, ['native.linuxVm.network.review', 'native.linuxVm.network.cancelReview'])
})

test('policy is checked again after recovery inspection before the native token is consumed', async () => {
  const methods = [], input = plan()
  let valid = true
  const transport = { request: async (method, p) => {
    methods.push(method)
    if (method.endsWith('.review')) return approved(p)
    if (method.endsWith('.cancelReview')) return { ...p, revoked: true }
    if (method.endsWith('.inspect')) {
      valid = false
      return { version: 1, sessionId: p.sessionId, status: 'absent', blocked: false, needsReview: false,
        requestedRunFound: null, truncated: false, automaticReplay: false, records: [] }
    }
    throw new Error('Unexpected command dispatch')
  } }
  const bridge = createNativeLinuxNetworkBridge(transport), owner = new NativeLinuxVm(transport)
  const review = await bridge.review(input, new AbortController().signal)
  armLinuxNetworkGrant(review.ticket, () => { if (!valid) throw new Error('policy withdrawn') })
  await assert.rejects(owner.executeApprovedNetwork(input.sessionId,
    { command: input.command, timeoutMs: input.timeoutMs }, new AbortController().signal,
    { persistChanges: false }, review.ticket), /policy withdrawn/)
  assert.deepEqual(methods, ['native.linuxVm.network.review', 'native.linuxVm.inspect', 'native.linuxVm.network.cancelReview'])
  await bridge.dispose(); await owner.dispose()
})

test('review cancellation waits for revocation and never exposes a late token', async () => {
  const abort = new AbortController(), started = Promise.withResolvers(), finish = Promise.withResolvers()
  const revoked = Promise.withResolvers(), methods = []
  let input
  const bridge = createNativeLinuxNetworkBridge({ request: (method, params) => {
    methods.push(method)
    if (method.endsWith('.review')) { input = params; started.resolve(); return finish.promise }
    return revoked.promise.then(() => ({ ...params, revoked: true }))
  } })
  let settled = false
  const pending = bridge.review(plan(), abort.signal).finally(() => { settled = true })
  await started.promise
  abort.abort()
  finish.resolve(approved(input))
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(settled, false)
  revoked.resolve()
  await assert.rejects(pending, { name: 'AbortError' })
  assert.deepEqual(methods, ['native.linuxVm.network.review', 'native.linuxVm.network.cancelReview'])
  await bridge.dispose()
})
