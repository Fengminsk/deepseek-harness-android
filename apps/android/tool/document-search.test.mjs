import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import { AppDocumentSearch } from '../runtime/document-search.mjs'

const limits = () => ({ fileBytes: 8388608, totalBytes: 67108864, maxEntries: 2000, maxFiles: 1000,
  maxDepth: 32, maxMatches: 200, previewChars: 600, maxDurationMs: 30000 })
const input = () => ({ requestId: randomUUID(), root: 'a'.repeat(64), path: '', query: '文字', caseSensitive: true })
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }

function fake() {
  const calls = []
  const gates = { prepare: null, run: null, cancel: null }
  const transport = {
    async request(method, params) {
      calls.push({ method, params })
      const kind = method.split('.').at(-1)
      if (gates[kind]) return gates[kind].promise
      return kind === 'run' ? { matches: [], complete: true } : kind === 'prepare' ? { prepared: true } : { cancelled: true }
    },
  }
  return { calls, gates, search: new AppDocumentSearch(transport, { limits, maxRequests: () => 4 }) }
}

test('shared native preparation receives only approved root/path and deployment bounds', async () => {
  const { search, calls } = fake()
  const params = input()
  const result = await search.run(params, { owner: 'app-one' })
  assert.equal(result.complete, true)
  assert.deepEqual(calls.map(call => call.method), [
    'native.documents.search.prepare', 'native.documents.search.run', 'native.documents.search.cancel',
  ])
  assert.deepEqual(calls[1].params.limits, limits())
  assert.equal(calls[1].params.root, params.root)
  assert.notEqual(calls[1].params.id, params.requestId)
  assert.equal(search.active.size, 0)
})

test('cancel before prepare completes never starts scanning', async () => {
  const { search, calls, gates } = fake()
  gates.prepare = deferred()
  const params = input()
  const run = search.run(params, { owner: 'app-one' })
  const rejected = assert.rejects(run, { name: 'AbortError' })
  const cancel = search.cancel({ requestId: params.requestId }, { owner: 'app-one' })
  gates.prepare.resolve({ prepared: true })
  assert.deepEqual(await cancel, { cancelled: true })
  await rejected
  assert.equal(calls.filter(call => call.method.endsWith('.run')).length, 0)
})

test('an unrelated App owner cannot cancel another search', async () => {
  const { search, calls, gates } = fake()
  gates.run = deferred()
  const params = input()
  const run = search.run(params, { owner: 'app-one' })
  await Promise.resolve()
  await search.cancel(params, { owner: 'app-two' })
  assert.equal(calls.filter(call => call.method.endsWith('.cancel')).length, 0)
  gates.run.resolve({ complete: true, matches: [] })
  await run
})

test('tool abort closes the native job and rejects a late successful result', async () => {
  const { search, gates } = fake()
  gates.run = deferred()
  const controller = new AbortController()
  const run = search.run(input(), { owner: 'tool:session:call', signal: controller.signal })
  const rejected = assert.rejects(run, { name: 'AbortError' })
  await Promise.resolve()
  controller.abort()
  gates.run.resolve({ complete: true, matches: [{ line: 'late' }] })
  await rejected
  assert.equal(search.active.size, 0)
})

test('disconnect cancels the App search but leaves Agent-owned work running', async () => {
  const { search, gates } = fake()
  gates.run = deferred()
  const app = search.run(input(), { owner: 'app-one' })
  const rejected = assert.rejects(app, { name: 'AbortError' })
  const agent = search.run(input(), { owner: 'tool:session:call' })
  await Promise.resolve()
  await search.closeOwner('app-one')
  gates.run.resolve({ complete: true, matches: [] })
  await rejected
  assert.equal((await agent).complete, true)
  await assert.rejects(search.run(input(), { owner: 'app-one' }), /disconnected/)
})

test('unconfirmed stop remains owned until a later confirmed cancellation', async () => {
  const { search, gates } = fake()
  gates.cancel = deferred()
  const params = input()
  const run = search.run(params, { owner: 'app-one' })
  gates.cancel.resolve({ cancelled: false, stopping: true })
  await assert.rejects(run, /尚未确认取消完成/)
  assert.equal(search.active.size, 1)
  gates.cancel = null
  await search.cancel(params, { owner: 'app-one' })
  assert.equal(search.active.size, 0)
})

test('invalid URI roots, parent segments and multiline patterns never reach native code', async () => {
  const { search, calls } = fake()
  for (const change of [{ root: 'content://any/file' }, { path: '../secret' }, { path: 'a//b' },
    { query: 'line\nline' }, { query: '\ud800' }, { requestId: '../arbitrary' }]) {
    await assert.rejects(search.run({ ...input(), ...change }, { owner: 'app-one' }), TypeError)
  }
  assert.equal(calls.length, 0)
})

test('duplicate in-flight request is rejected and shutdown prevents new work', async () => {
  const { search, gates } = fake()
  gates.run = deferred()
  const params = input()
  const first = search.run(params, { owner: 'app-one' })
  const rejected = assert.rejects(first, { name: 'AbortError' })
  await assert.rejects(search.run(params, { owner: 'app-one' }), /already running/)
  await search.close()
  gates.run.resolve({ complete: true, matches: [] })
  await rejected
  await assert.rejects(search.run(input(), { owner: 'app-one' }), /closed/)
})

test('prepare rejection still retires the native id and releases its concurrency slot', async () => {
  const { search, calls, gates } = fake()
  search.maxRequests = () => 1
  gates.prepare = deferred()
  const params = input()
  const run = search.run(params, { owner: 'app-one' })
  gates.prepare.reject(new Error('native registration failed'))
  await assert.rejects(run, /native registration failed/)
  assert.equal(search.active.size, 0)
  assert.equal(calls.filter(call => call.method.endsWith('.cancel')).length, 1)
  gates.prepare = null
  assert.equal((await search.run(input(), { owner: 'app-one' })).complete, true)
})

test('lost prepare response keeps unknown native work cancellable on retry', async () => {
  const { search, gates } = fake()
  gates.prepare = deferred()
  gates.cancel = deferred()
  const params = input()
  const run = search.run(params, { owner: 'app-one' })
  gates.prepare.reject(new Error('response lost after registration'))
  gates.cancel.reject(new Error('native connection interrupted'))
  await assert.rejects(run, /native connection interrupted/)
  assert.equal(search.active.size, 1)
  gates.cancel = null
  await search.cancel(params, { owner: 'app-one' })
  assert.equal(search.active.size, 0)
})

test('synchronous abort while prepare is sent is retired after preparation', async () => {
  const controller = new AbortController()
  const calls = []
  const search = new AppDocumentSearch({
    async request(method) {
      calls.push(method)
      if (method.endsWith('.prepare')) controller.abort()
      return { prepared: true, cancelled: true }
    },
  }, { limits, maxRequests: () => 1 })
  await assert.rejects(search.run(input(), { owner: 'tool:session:call', signal: controller.signal }), { name: 'AbortError' })
  assert.deepEqual(calls, ['native.documents.search.prepare', 'native.documents.search.cancel'])
  assert.equal(search.active.size, 0)
})
