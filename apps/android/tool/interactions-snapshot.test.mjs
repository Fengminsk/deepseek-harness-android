import assert from 'node:assert/strict'
import test from 'node:test'
import { registerHooks } from 'node:module'

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
try {
  const module = await import(source)
  AppInteractions = module.AppInteractions
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
