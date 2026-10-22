import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { test } from 'node:test'
import { AppWorkspaceChanges } from '../runtime/workspace-changes.mjs'

const summary = { turn: 1, files: [{ path: 'a.txt', display: 'a.txt', added: 1, deleted: 1 }], total: 1, added: 1, deleted: 1 }
const request = (extra = {}) => ({ owner: 'binder-a', requestId: randomUUID(), sessionId: 'session /?#', seq: 9, ...extra })
const limits = () => ({ maxRequests: 2, maxOwnerRequests: 1, requestTimeoutMs: 1000, closeTimeoutMs: 100 })
function fixture(overrides = {}) {
  const calls = [], reports = []
  const app = new AppWorkspaceChanges({ available: () => true, limits, report: error => reports.push(error),
    fetch: async input => { calls.push(input); return Response.json(summary) }, ...overrides })
  return { app, calls, reports }
}
const rejected = (result, code) => { assert.equal(result.ok, false); assert.equal(result.error.code, code); return result.error }

test('summary and indexed diff use only the original exact Fetch routes', async () => {
  const { app, calls } = fixture()
  assert.deepEqual(await app.call('summary', request()), { ok: true, value: summary })
  await app.call('diff', request({ index: 0 }))
  assert.equal(new URL(calls[0].url).pathname, '/api/changes.summary')
  assert.equal(new URL(calls[0].url).searchParams.get('sessionId'), 'session /?#')
  assert.equal(new URL(calls[1].url).pathname, '/api/changes.diff')
  assert.equal(new URL(calls[1].url).searchParams.get('index'), '0')
  assert.equal(calls.every(input => input.method === 'GET' && input.signal instanceof AbortSignal), true)
  await app.close()
})

test('text, binary, oversized and empty original results are not rewritten', async () => {
  for (const value of [summary, { ...summary, files: [], total: 0, added: 0, deleted: 0 },
    { kind: 'text', path: 'a', display: 'a', before: true, after: false, coarse: true,
      hunks: [{ oldStart: 1, oldLines: 1, newStart: 1, newLines: 0, lines: ['-before'] }] },
    { kind: 'binary', path: 'b', display: 'b' }, { kind: 'oversized', path: 'c', display: 'c' }]) {
    const { app } = fixture({ fetch: async () => Response.json(value) })
    assert.deepEqual(await app.call('diff', request({ index: 0 })), { ok: true, value })
    await app.close()
  }
})

test('invalid owner, IDs, coordinates and arbitrary route/path inputs never dispatch', async () => {
  const { app, calls } = fixture()
  for (const bad of [null, [], request({ owner: '' }), request({ requestId: 'not-uuid' }), request({ sessionId: '' }),
    request({ seq: -1 }), request({ seq: 1.5 }), request({ seq: Number.MAX_SAFE_INTEGER + 1 }),
    request({ path: '/secret' }), request({ method: 'open' }), request({ turnId: 1 })]) {
    rejected(await app.call('summary', bad), 'gateway/bad-request')
  }
  rejected(await app.call('diff', request()), 'gateway/bad-request')
  rejected(await app.call('open', request()), 'gateway/bad-request')
  assert.equal(calls.length, 0)
})

test('original missing, permission and read failures stay distinguishable without response-body leakage', async () => {
  for (const [status, code] of [[400, 'gateway/bad-request'], [403, 'remote-access/denied'],
    [404, 'workspace-changes/unavailable'], [500, 'workspace-changes/read-failed']]) {
    const { app } = fixture({ fetch: async () => new Response('/private/secret/snapshot', { status }) })
    const result = await app.call('summary', request())
    rejected(result, code)
    assert.equal(result.error.details.status, status)
    assert.doesNotMatch(JSON.stringify(result), /private|secret/)
  }
  const { app, calls } = fixture({ available: () => false })
  rejected(await app.call('summary', request()), 'gateway/invocation-unavailable')
  assert.equal(calls.length, 0)
})

test('unexpected route failures are reported and remain failures', async () => {
  const defect = new Error('/private/defect')
  const { app, reports } = fixture({ fetch: async () => { throw defect } })
  const result = await app.call('summary', request())
  rejected(result, 'workspace-changes/read-failed')
  assert.doesNotMatch(JSON.stringify(result), /private|defect/)
  assert.deepEqual(reports, [defect])
})

test('cancellation is owner-scoped and waits for original reads to stop', async () => {
  const entered = Promise.withResolvers(), stopped = Promise.withResolvers()
  const { app } = fixture({ fetch: async input => {
    entered.resolve(input.signal)
    await stopped.promise
    return Response.json(summary)
  } })
  const params = request({ index: 0 }), reading = app.call('diff', params)
  const signal = await entered.promise
  assert.deepEqual(await app.call('cancel', { owner: 'binder-b', requestId: params.requestId }), { ok: true, value: { cancelled: false } })
  assert.equal(signal.aborted, false)
  let acknowledged = false
  const cancelling = app.call('cancel', { owner: params.owner, requestId: params.requestId }).then(value => { acknowledged = true; return value })
  rejected(await reading, 'gateway/cancelled')
  assert.equal(signal.aborted, true)
  assert.equal(acknowledged, false)
  stopped.resolve()
  assert.deepEqual(await cancelling, { ok: true, value: { cancelled: true } })
  await app.close()
})

test('duplicate and capacity admissions remain occupied until non-cooperative reads settle', async () => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  const { app } = fixture({ fetch: async () => { entered.resolve(); await release.promise; return Response.json(summary) },
    limits: () => ({ ...limits(), maxRequests: 1, requestTimeoutMs: 15, closeTimeoutMs: 15 }) })
  const params = request(), reading = app.call('summary', params)
  await entered.promise
  rejected(await app.call('summary', params), 'gateway/bad-request')
  rejected(await reading, 'workspace-changes/timeout')
  rejected(await app.call('summary', request({ owner: 'binder-b' })), 'workspace-changes/busy')
  rejected(await app.call('cancel', { owner: params.owner, requestId: params.requestId }), 'workspace-changes/cleanup-timeout')
  release.resolve()
  assert.deepEqual(await app.call('cancel', { owner: params.owner, requestId: params.requestId }), { ok: true, value: { cancelled: true } })
  assert.equal((await app.call('summary', request())).ok, true)
})

test('per-owner capacity does not block another owner below the global budget', async () => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  const { app } = fixture({ fetch: async () => { entered.resolve(); await release.promise; return Response.json(summary) } })
  const reading = app.call('summary', request())
  await entered.promise
  rejected(await app.call('summary', request()), 'workspace-changes/busy')
  const second = app.call('summary', request({ owner: 'binder-b' }))
  release.resolve()
  assert.equal((await reading).ok, true)
  assert.equal((await second).ok, true)
})

test('owner disconnection aborts pending reads and rejects future requests without affecting other owners', async () => {
  const entered = Promise.withResolvers()
  const { app } = fixture({ fetch: input => {
    entered.resolve()
    return new Promise((resolve, reject) => input.signal.addEventListener('abort', () => reject(input.signal.reason), { once: true }))
  } })
  const reading = app.call('summary', request())
  await entered.promise
  await app.closeOwner('binder-a')
  rejected(await reading, 'gateway/cancelled')
  rejected(await app.call('summary', request()), 'gateway/cancelled')
  app.fetch = async () => Response.json(summary)
  assert.equal((await app.call('summary', request({ owner: 'binder-b' }))).ok, true)
  await app.close()
  rejected(await app.call('summary', request({ owner: 'binder-b' })), 'gateway/cancelled')
})

test('global close timeout can be retried and never publishes a late result', async () => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers()
  const { app } = fixture({ fetch: async () => { entered.resolve(); await release.promise; return Response.json(summary) },
    limits: () => ({ ...limits(), closeTimeoutMs: 15 }) })
  const reading = app.call('summary', request())
  await entered.promise
  await assert.rejects(app.close(), { code: 'workspace-changes/cleanup-timeout' })
  rejected(await reading, 'gateway/cancelled')
  release.resolve()
  await app.close()
  rejected(await app.call('summary', request()), 'gateway/cancelled')
})
