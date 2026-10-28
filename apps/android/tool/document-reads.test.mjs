import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import { AppDocumentReads } from '../runtime/document-reads.mjs'

const page = { text: 'fixture', offset: 0, nextOffset: 7, truncated: false, version: 'a'.repeat(64) }
const input = () => ({ requestId: randomUUID(), root: 'b'.repeat(64), path: 'alpha.txt', offset: 0 })
function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
function fixture() {
  const requests = [], gates = {}, started = deferred()
  const transport = { async request(method, params) {
    requests.push({ method, params })
    const operation = method.split('.').at(-1)
    if (operation === 'run') started.resolve()
    if (gates[operation]) return gates[operation].promise
    return operation === 'run' ? page : operation === 'prepare' ? { prepared: true } : { cancelled: true }
  } }
  return { requests, gates, started, reads: new AppDocumentReads(transport,
    { maxRequests: () => 2, timeoutMs: () => 30000 }) }
}

test('text pages use one root-bound request and confirmed retirement before returning', async () => {
  const f = fixture(), params = input()
  assert.deepEqual(await f.reads.run(params, { owner: 'app' }), page)
  assert.deepEqual(f.requests.map(entry => entry.method), [
    'native.documents.read.prepare', 'native.documents.read.run', 'native.documents.read.cancel',
  ])
  const id = f.requests[0].params.id
  assert.notEqual(id, params.requestId)
  assert.deepEqual(f.requests[0].params, { id, root: params.root, timeoutMs: 30000 })
  assert.equal(f.reads.active.size, 0)
  await f.reads.close()
})

test('model abort rejects a late page and cannot cancel an unrelated App read', async () => {
  const f = fixture(), params = input(), abort = new AbortController()
  f.gates.run = deferred()
  const pending = f.reads.run(params, { owner: 'tool:session:call', signal: abort.signal })
  const rejected = assert.rejects(pending, { name: 'AbortError' })
  try {
    await f.started.promise
    await f.reads.cancel(params, { owner: 'another-app' })
    assert.equal(f.requests.filter(entry => entry.method.endsWith('.cancel')).length, 0)
    abort.abort()
    f.gates.run.resolve(page)
    await rejected
    assert.equal(f.reads.active.size, 0)
  } finally { f.gates.run.resolve(page); await f.reads.close(); await rejected }
})

test('a prepared request cancelled during acknowledgement never reads provider bytes', async () => {
  const f = fixture(), params = input()
  f.gates.prepare = deferred()
  const pending = f.reads.run(params, { owner: 'app' })
  const rejected = assert.rejects(pending, { name: 'AbortError' })
  const cancel = f.reads.cancel(params, { owner: 'app' })
  f.gates.prepare.resolve({ prepared: true })
  await cancel; await rejected
  assert.equal(f.requests.some(entry => entry.method.endsWith('.run')), false)
  await f.reads.close()
})

test('provider failure and unknown cleanup remain visible and owned until an explicit retry', async () => {
  const f = fixture(), params = input()
  f.gates.run = deferred(); f.gates.cancel = deferred()
  const pending = f.reads.run(params, { owner: 'app' })
  const rejected = assert.rejects(pending, error => error instanceof AggregateError
    && /grant revoked/.test(error.message) && /尚未确认取消完成/.test(error.message))
  await f.started.promise
  f.gates.run.reject(new Error('grant revoked; choose the directory again'))
  f.gates.cancel.resolve({ cancelled: false })
  await rejected
  assert.equal(f.reads.active.size, 1)
  delete f.gates.cancel
  assert.deepEqual(await f.reads.cancel(params, { owner: 'app' }), { cancelled: true })
  assert.equal(f.reads.active.size, 0)
  await f.reads.close()
})

test('a continuation without its observed version never starts native reading and retires preparation', async () => {
  const f = fixture()
  await assert.rejects(f.reads.run({ ...input(), offset: 7 }, { owner: 'app' }), /version/)
  assert.equal(f.requests.some(entry => entry.method.endsWith('.run')), false)
  assert.equal(f.requests.at(-1).method, 'native.documents.read.cancel')
  await f.reads.close()
})

test('abort while retirement acknowledgement is pending rejects the already-read page', async () => {
  const entered = deferred(), retired = deferred(), abort = new AbortController()
  const reads = new AppDocumentReads({ async request(method) {
    if (method.endsWith('.prepare')) return { prepared: true }
    if (method.endsWith('.run')) return page
    entered.resolve()
    return retired.promise
  } }, { maxRequests: () => 2, timeoutMs: () => 30000 })
  const outcome = reads.run(input(), { owner: 'tool:session:call', signal: abort.signal })
    .then(value => ({ value }), error => ({ error }))
  try {
    await entered.promise
    abort.abort()
    retired.resolve({ cancelled: true })
    const result = await outcome
    assert.equal(result.error?.name, 'AbortError', 'A page must not escape after cancellation during retirement')
    assert.equal(reads.active.size, 0)
  } finally { retired.resolve({ cancelled: true }); await outcome; await reads.close() }
})

test('abort during retirement preserves an earlier actionable provider failure', async () => {
  const entered = deferred(), retired = deferred(), abort = new AbortController()
  const original = new Error('The grant was revoked; select the directory again')
  const reads = new AppDocumentReads({ async request(method) {
    if (method.endsWith('.prepare')) return { prepared: true }
    if (method.endsWith('.run')) throw original
    entered.resolve()
    return retired.promise
  } }, { maxRequests: () => 2, timeoutMs: () => 30000 })
  const outcome = reads.run(input(), { owner: 'app', signal: abort.signal })
    .then(value => ({ value }), error => ({ error }))
  try {
    await entered.promise
    abort.abort()
    retired.resolve({ cancelled: true })
    assert.equal((await outcome).error, original)
  } finally { retired.resolve({ cancelled: true }); await outcome; await reads.close() }
})
