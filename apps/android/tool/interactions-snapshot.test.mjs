import assert from 'node:assert/strict'
import test from 'node:test'
import { registerHooks } from 'node:module'
import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { InteractionReceipts } from '../runtime/interaction-receipts.mjs'

// The carrier dependency is generated from the original DSH question implementation.
// Read the existing generated module, but always test this checkout's interactions source.
const source = new URL('../runtime/interactions.mjs', import.meta.url)
const generated = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/question-carrier.mjs', import.meta.url)
const hook = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL === source.href && specifier === './question-carrier.mjs') {
      return { url: generated.href, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
})
let AppInteractions
let PendingQuestion, createWaterfallRequest
try {
  const module = await import(source)
  AppInteractions = module.AppInteractions
  const carrier = await import(generated)
  PendingQuestion = carrier.PendingQuestion
  createWaterfallRequest = carrier.createWaterfallRequest
} finally { hook.deregister() }

function fixture(request, events = []) {
  const record = { id: 'approval-id', version: 4, sessionId: 'session', kind: 'approval',
    callId: request.callId, request }
  const agent = { id: 'session', session: {
    seq: events.length, header: { cwd: '/a-session-header-is-not-the-shell-cwd' }, eventAt: seq => events[seq],
  } }
  const carrier = Object.create(AppInteractions.prototype)
  Object.assign(carrier, {
    ctx: { agents: { list: () => [agent] } },
    records: new Map([[record.id, record]]), revision: 7, error: null,
    shellContext: (sessionId, callId) => sessionId === 'session' && callId === 'shell-call'
      ? { cwd: '/actual/prepared/session-workspace' } : undefined,
  })
  return carrier
}

test('shell approval includes its prepared cwd and exact matching original tool call without rewriting the DSH request', () => {
  const request = Object.freeze({
    toolName: 'android_shell', callId: 'shell-call', reason: 'original reason',
    displayReason: Object.freeze({ zh: '原审批说明', en: 'Original explanation' }),
  })
  const toolCall = Object.freeze({
    turn: 2, step: 1, callId: 'shell-call', name: 'android_shell',
    arguments: '{"command":"printf \'%s\\\\n\' \'hello\'\\nls -la"}',
  })
  const carrier = fixture(request, [
    { type: 'tool/call', data: toolCall },
    { type: 'tool/call', data: { callId: 'unrelated', name: 'other', arguments: '{}' } },
  ])
  const result = carrier.snapshot()
  assert.equal(result.revision, 7)
  assert.equal(result.error, null)
  const value = result.requests[0]
  assert.equal(value.id, 'approval-id')
  assert.equal(value.version, 4)
  assert.equal(value.toolCall, toolCall)
  assert.equal(value.toolCall.arguments, toolCall.arguments)
  assert.deepEqual(value.executionContext, { cwd: '/actual/prepared/session-workspace' })
  assert.equal(value.reason, request.reason)
  assert.equal(value.displayReason, request.displayReason)
  assert.equal(Object.hasOwn(request, 'executionContext'), false)
  assert.equal(Object.hasOwn(request, 'toolCall'), false)
})

test('other tools preserve raw arguments and never infer an Android shell execution directory', () => {
  const toolCall = { callId: 'file-call', name: 'file_write', arguments: '{ broken JSON' }
  const carrier = fixture({ toolName: 'file_write', callId: 'file-call' }, [{ type: 'tool/call', data: toolCall }])
  const value = carrier.snapshot().requests[0]
  assert.equal(value.toolCall.arguments, '{ broken JSON')
  assert.equal(Object.hasOwn(value, 'executionContext'), false)
})

test('cold Host reconciliation closes a logged approval without replaying its started answer', async t => {
  const root = await mkdtemp(join(fileURLToPath(new URL('../../../.cache/android/', import.meta.url)), 'dsh-reconcile-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const receipts = new InteractionReceipts()
  await receipts.initialize(root)
  const identity = ['approval', 'session', 'audit-1']
  assert.equal(await receipts.begin(identity), true)
  const events = [
    { type: 'approval/asked', data: { id: 'audit-1' } },
    { type: 'approval/decided', data: { id: 'audit-1', outcome: 'unavailable' } },
  ]
  const agent = { id: 'session', session: { seq: events.length, eventAt: seq => events[seq] },
    inbox: { nextStep: [], nextTurn: [] } }
  const record = { id: 'event-1', version: 1, sessionId: 'session', kind: 'approval',
    approvalAuditId: 'audit-1', life: new AbortController(), request: {}, sending: true }
  const notices = []
  const carrier = Object.create(AppInteractions.prototype)
  Object.assign(carrier, {
    ctx: { agents: { roots: () => [agent], list: () => [agent] }, get: () => ({ stateOf: () => ({ questions: { active: [], settled: [] } }) }) },
    receipts, receiptSettlements: new Map(), records: new Map([[record.id, record]]), events: new Map(),
    transport: { notify: (...args) => notices.push(args) }, revision: 0, error: null,
  })
  carrier.reconcile()
  assert.equal(carrier.records.size, 1, 'an in-flight answer keeps its carrier until its own acknowledgement')
  assert.equal(receipts.phase(identity), 'started')
  record.sending = false
  carrier.reconcile()
  await Promise.allSettled([...carrier.receiptSettlements.values()])
  assert.equal(carrier.records.size, 0)
  assert.equal(receipts.phase(identity), 'settled')
  assert.equal(notices.at(-1)[1].requests.length, 0)
  assert.equal(await receipts.begin(identity), false)
})

test('cold Host keeps a still-continued question blocked after an unknown answer write', async t => {
  const root = await mkdtemp(join(fileURLToPath(new URL('../../../.cache/android/', import.meta.url)), 'dsh-reconcile-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const receipts = new InteractionReceipts()
  await receipts.initialize(root)
  const identity = ['question', 'session', 'call-1']
  await receipts.begin(identity)
  const question = { callId: 'call-1', state: 'continued', questions: [{ id: 'choice', question: 'Choose' }] }
  const agent = { id: 'session', session: { seq: 0, eventAt: () => undefined },
    inbox: { nextStep: [], nextTurn: [] } }
  const carrier = Object.create(AppInteractions.prototype)
  Object.assign(carrier, {
    ctx: { agents: { roots: () => [agent], list: () => [agent] },
      get: () => ({ stateOf: () => ({ questions: { active: [question], settled: [] } }) }),
      typertGateway: { invoke: () => { throw new Error('A read-only reconciliation must not answer') } } },
    peer: {}, receipts, receiptSettlements: new Map(), records: new Map(), events: new Map(),
    transport: { notify() {} }, revision: 0, version: 0, error: null,
  })
  carrier.reconcile()
  assert.equal(receipts.phase(identity), 'started')
  assert.equal(carrier.snapshot().requests[0].submission, 'started')
  assert.equal(await receipts.begin(identity), false)
  for (const record of carrier.records.values()) carrier.remove(record)
})

test('missing call details remain missing instead of borrowing another command or session directory', () => {
  const carrier = fixture({ toolName: 'android_shell', callId: 'missing' }, [
    { type: 'tool/call', data: { callId: 'another', name: 'android_shell', arguments: '{"command":"unrelated"}' } },
  ])
  const value = carrier.snapshot().requests[0]
  assert.equal(value.toolCall, undefined)
  assert.equal(Object.hasOwn(value, 'executionContext'), false)
})

test('question snapshots retain original questions and state without shell presentation fields', () => {
  const carrier = fixture({})
  carrier.records.set('approval-id', {
    id: 'question', version: 9, sessionId: 'session', kind: 'question', callId: 'question-call',
    request: { questions: [{ id: 'one', question: '原问题？' }] },
    card: { snapshot: () => ({ state: 'continued', waitState: 'continued', countdown: 12 }) },
  })
  assert.deepEqual(carrier.snapshot().requests[0], {
    id: 'question', version: 9, sessionId: 'session', kind: 'question', callId: 'question-call',
    questions: [{ id: 'one', question: '原问题？' }], state: 'continued', waitState: 'continued', countdown: 12,
  })
})

test('shared credential, preset and goal activation changes reach native observers without account records', async () => {
  const lifetime = new AbortController()
  const delivered = []
  const ready = Promise.withResolvers()
  const carrier = Object.create(AppInteractions.prototype)
  Object.assign(carrier, {
    lifetime, peer: {}, reconcile() {},
    transport: { notify: (method, params) => delivered.push({ method, params }) },
    ctx: { typertGateway: { wireStream: { async open() {
      return (async function* () {
        yield { type: 'ready', clientId: 'test-client' }
        yield { type: 'emit', event: 'credentials/reference-updated', args: ['SEARCH_API_KEY'] }
        yield { type: 'emit', event: 'agent-preset/selected', args: ['session', 'android'] }
        yield { type: 'emit', event: 'goal/activation-changed', args: [{ sessionId: 'session', goal: { id: 'goal-1', revision: 7, activation: 'disarmed' } }] }
        yield { type: 'emit', event: 'credentials/record-updated', args: ['account/record'] }
        lifetime.abort()
      })()
    } } } },
  })
  await carrier.consume(ready)
  await ready.promise
  assert.deepEqual(delivered, [{ method: 'api.event', params: {
    event: 'credentials/reference-updated', args: ['SEARCH_API_KEY'],
  } }, { method: 'api.event', params: {
    event: 'agent-preset/selected', args: ['session', 'android'],
  } }, { method: 'api.event', params: {
    event: 'goal/activation-changed', args: [{ sessionId: 'session', goal: { id: 'goal-1', revision: 7, activation: 'disarmed' } }],
  } }])
})

test('dismissing a named question preserves its answerable request', async () => {
  const carrier = Object.create(AppInteractions.prototype)
  const record = { id: 'named', version: 1, kind: 'question', callId: 'call-1', sending: false,
    card: { async dismiss() {} } }
  Object.assign(carrier, { records: new Map([[record.id, record]]), error: null })
  assert.deepEqual(await carrier.dismiss({ id: 'named', version: 1 }),
    { accepted: true, requestStillPending: true })
  assert.equal(record.sending, false)
  assert.equal(carrier.records.get(record.id), record)
})

test('dismissing an unnamed question waits for cancellation delivery', async () => {
  const carrier = Object.create(AppInteractions.prototype)
  const card = new PendingQuestion('session', [{ id: 'one', question: 'Continue?' }])
  const waterfall = createWaterfallRequest(undefined, undefined,
    channel => card.detachWaterfall(channel))
  card.attachWaterfall(waterfall.channel)
  let rejection
  const delivery = waterfall.result.then(() => false, error => {
    rejection = error
    return true
  })
  const record = { id: 'unnamed', version: 2, kind: 'question', sending: false,
    card, delivery }
  Object.assign(carrier, { records: new Map([[record.id, record]]), error: null })
  assert.deepEqual(await carrier.dismiss({ id: 'unnamed', version: 2 }),
    { accepted: true, requestStillPending: false })
  assert.equal(rejection.code, 'ASK_CANCELLED')
  assert.deepEqual(await carrier.dismiss({ id: 'unnamed', version: 3 }),
    { accepted: false, requestStillPending: false, message: '该提问已处理或失效' })
})

test('dismissal failure remains uncertain and cannot be replayed', async () => {
  const carrier = Object.create(AppInteractions.prototype)
  const record = { id: 'unnamed', version: 2, kind: 'question', sending: false,
    card: { async dismiss() { throw new Error('ack lost') } } }
  let published = 0
  Object.assign(carrier, { records: new Map([[record.id, record]]), error: null, publish() { published++ } })
  await assert.rejects(carrier.dismiss({ id: 'unnamed', version: 2 }), /ack lost/)
  assert.equal(record.sending, true)
  assert.match(carrier.error, /结果未确认/)
  assert.equal(published, 1)
  await assert.rejects(carrier.dismiss({ id: 'unnamed', version: 2 }), /勿重复提交/)
})

test('a restarted Host cannot repeat a previously accepted named question answer', async t => {
  const home = fileURLToPath(new URL('../../../.cache/android/', import.meta.url))
  await mkdir(home, { recursive: true })
  const root = await mkdtemp(join(home, 'dsh-interaction-submit-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const firstReceipts = new InteractionReceipts()
  await firstReceipts.initialize(root)
  let deliveries = 0
  const makeCarrier = receipts => {
    const carrier = Object.create(AppInteractions.prototype)
    const record = { id: 'question:session:call-1', version: 2, sessionId: 'session', kind: 'question',
      callId: 'call-1', request: { questions: [{ id: 'choice', options: [{ label: 'Yes' }] }] }, sending: false,
      card: { snapshot: () => ({ state: 'continued' }), async answer() { deliveries++ } } }
    Object.assign(carrier, { receipts, records: new Map([[record.id, record]]),
      publish() {}, remove(item) { this.records.delete(item.id) }, error: null })
    return carrier
  }
  const params = { id: 'question:session:call-1', version: 2,
    response: { answers: [{ id: 'choice', selected: ['Yes'] }] } }
  assert.deepEqual(await makeCarrier(firstReceipts).reply(params), { accepted: true, requestStillPending: false })
  const restoredReceipts = new InteractionReceipts()
  await restoredReceipts.initialize(root)
  const restarted = makeCarrier(restoredReceipts)
  assert.equal(restarted.snapshot().requests[0].submission, 'accepted')
  await assert.rejects(restarted.reply(params), /不能重复答复/)
  assert.equal(deliveries, 1)
})

test('a lost Host answer acknowledgement remains blocked after a process restart', async t => {
  const home = fileURLToPath(new URL('../../../.cache/android/', import.meta.url))
  await mkdir(home, { recursive: true })
  const root = await mkdtemp(join(home, 'dsh-interaction-submit-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const firstReceipts = new InteractionReceipts()
  await firstReceipts.initialize(root)
  let deliveries = 0
  const makeCarrier = (receipts, failed) => {
    const carrier = Object.create(AppInteractions.prototype)
    const record = { id: 'question:session:call-1', version: 8, sessionId: 'session', kind: 'question',
      callId: 'call-1', request: { questions: [{ id: 'choice', options: [] }] }, sending: false,
      card: { snapshot: () => ({ state: 'continued' }),
        async answer() { deliveries++; if (failed) throw new Error('ack lost') } } }
    Object.assign(carrier, { receipts, records: new Map([[record.id, record]]), publish() {}, error: null })
    return carrier
  }
  const params = { id: 'question:session:call-1', version: 8,
    response: { answers: [{ id: 'choice', selected: [], custom: 'Because' }] } }
  await assert.rejects(makeCarrier(firstReceipts, true).reply(params), /ack lost/)
  const restoredReceipts = new InteractionReceipts()
  await restoredReceipts.initialize(root)
  const restarted = makeCarrier(restoredReceipts, false)
  assert.equal(restarted.snapshot().requests[0].submission, 'started')
  await assert.rejects(restarted.reply(params), /不能重复答复/)
  assert.equal(deliveries, 1)
})

test('an audited approval cannot be granted twice across Host processes', async t => {
  const home = fileURLToPath(new URL('../../../.cache/android/', import.meta.url))
  await mkdir(home, { recursive: true })
  const root = await mkdtemp(join(home, 'dsh-interaction-submit-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const firstReceipts = new InteractionReceipts()
  await firstReceipts.initialize(root)
  let carrierDeliveries = 0
  const makeCarrier = receipts => {
    const carrier = Object.create(AppInteractions.prototype)
    const record = { id: 'event-1', version: 1, sessionId: 'session', kind: 'approval',
      approvalAuditId: 'asked-1', request: { toolName: 'android_shell', callId: 'call-1' }, sending: false }
    Object.assign(carrier, { receipts, records: new Map([[record.id, record]]),
      ctx: { agents: { list: () => [] } }, shellContext: () => undefined,
      async complete() { carrierDeliveries++; return true }, publish() {}, error: null })
    return carrier
  }
  const params = { id: 'event-1', version: 1, response: 'allowed-once' }
  assert.deepEqual(await makeCarrier(firstReceipts).reply(params), { accepted: true, requestStillPending: false })
  const restartedReceipts = new InteractionReceipts()
  await restartedReceipts.initialize(root)
  const restarted = makeCarrier(restartedReceipts)
  assert.equal(restarted.snapshot().requests[0].submission, 'accepted')
  await assert.rejects(restarted.reply(params), /不能重复答复/)
  assert.equal(carrierDeliveries, 1)
})
