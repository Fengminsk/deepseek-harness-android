import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'

const grant = '7'.repeat(64)
const expectedLimits = { fileBytes: 8388608, totalBytes: 67108864, maxEntries: 2000,
  maxFiles: 1000, maxDepth: 32, maxMatches: 200, previewChars: 600, maxDurationMs: 30000 }

/** Native RPC fixture only; actual SAF traversal is exercised by the native scanner tests. */
export class SearchNativeFixture {
  constructor(send) {
    this.send = send
    this.jobs = new Map()
    this.runs = []
    this.waiters = []
  }

  accept(frame) {
    if (!frame.method?.startsWith('native.documents.search.')) return false
    const { id } = frame.params
    if (frame.method === 'native.documents.search.prepare') {
      assert.equal(this.jobs.has(id), false)
      this.jobs.set(id, {})
      this.send({ id: frame.id, result: { prepared: true } })
    } else if (frame.method === 'native.documents.search.run') {
      const job = this.jobs.get(id)
      assert.ok(job)
      assert.equal(frame.params.root, grant)
      assert.deepEqual(frame.params.limits, expectedLimits)
      const result = { matches: [{ path: 'fixture.txt', lineNumber: 2, line: 'literal fixture output', previewTruncated: false }],
        complete: true, scannedFiles: 1, skipped: [], skippedCount: 0, skippedTruncated: false,
        bytesRead: 42, limits: frame.params.limits }
      job.result = result
      job.frame = frame
      this.runs.push(frame.params)
      if (!frame.params.query.startsWith('hold-')) this.send({ id: frame.id, result })
      for (const waiter of [...this.waiters]) if (waiter.query === frame.params.query) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1)
        waiter.resolve(frame.params)
      }
    } else if (frame.method === 'native.documents.search.cancel') {
      const job = this.jobs.get(id)
      // Exercise a late successful scan reply: the cancelled caller must not publish it.
      if (job?.frame?.params.query.startsWith('hold-')) this.send({ id: job.frame.id, result: job.result })
      this.jobs.delete(id)
      this.send({ id: frame.id, result: { cancelled: true } })
    } else throw new Error(`Unexpected native search operation ${frame.method}`)
    return true
  }

  started(query) {
    return this.runs.find(run => run.query === query)
      ?? new Promise(resolve => this.waiters.push({ query, resolve }))
  }
}

/** Validate actual Android profile routing and original tool logging with a native RPC fixture. */
export async function verifyDocumentSearch({ request, send, finish, modelSteps, nativeSearch }) {
  const params = query => ({ requestId: randomUUID(), root: grant, path: '', query, caseSensitive: false })
  const app = await request('documents.search', { ...params('literal'), owner: 'fixture-app' })
  assert.equal(app.matches[0].line, 'literal fixture output')
  assert.equal(nativeSearch.jobs.size, 0)
  await assert.rejects(request('documents.search', params('literal')), /owner/)
  const pendingParams = { ...params('hold-app'), owner: 'fixture-app' }
  const appPending = request('documents.search', pendingParams)
  const appStopped = assert.rejects(appPending, /取消/)
  const started = await nativeSearch.started('hold-app')
  await request('documents.search.cancel', { requestId: pendingParams.requestId, owner: 'another-app' })
  assert.equal(nativeSearch.jobs.has(started.id), true)
  await request('documents.search.cancel', pendingParams)
  await appStopped
  assert.equal(nativeSearch.jobs.has(started.id), false)

  modelSteps.push({ id: 'file-search', tool: 'android_files',
    args: { action: 'search', root: grant, path: '', query: 'literal', caseSensitive: true } })
  await request('session.send', { sessionId: 'file-search', requestId: 'file-search',
    text: 'Search the fixture grant.', provider: 'deepseek-official', model: 'deepseek-flash' })
  await finish('file-search')
  const history = (await request('session.read', { sessionId: 'file-search' })).events
  assert.ok(history.some(event => event.type === 'tool/call'
    && JSON.stringify(event.data).includes('android_files')))
  assert.ok(history.some(event => event.type === 'tool/result'
    && JSON.stringify(event.data).includes('literal fixture output')))
  assert.equal(nativeSearch.runs.at(-1).caseSensitive, true)

  modelSteps.push({ id: 'cancel-file-search', tool: 'android_files',
    args: { action: 'search', root: grant, path: '', query: 'hold-tool' } })
  await request('session.send', { sessionId: 'file-search-cancel', requestId: 'file-search-cancel',
    text: 'Search the fixture grant.', provider: 'deepseek-official', model: 'deepseek-flash' })
  const toolStarted = await nativeSearch.started('hold-tool')
  const disconnectParams = { ...params('hold-disconnect'), owner: 'disconnecting-app' }
  const disconnectPending = request('documents.search', disconnectParams)
  const disconnected = assert.rejects(disconnectPending, /取消/)
  await nativeSearch.started('hold-disconnect')
  send({ method: 'native.appDisconnected', params: { owner: 'disconnecting-app' } })
  await disconnected
  assert.equal(nativeSearch.jobs.has(toolStarted.id), true)
  await assert.rejects(request('documents.search', { ...params('literal'), owner: 'disconnecting-app' }), /disconnected/)
  await request('session.cancel', { sessionId: 'file-search-cancel' })
  await finish('file-search-cancel')
  assert.equal(nativeSearch.jobs.size, 0)
  const cancelledHistory = (await request('session.read', { sessionId: 'file-search-cancel' })).events
  assert.equal(cancelledHistory.some(event => event.type === 'tool/result'
    && JSON.stringify(event.data).includes('literal fixture output')), false)
  console.log(JSON.stringify({ appSearchRouted: true, appOwnerIsolation: true, modelSearchToolLogged: true,
    searchBoundsForwarded: true, appDisconnectPreservesTool: true, toolCancelDiscardsLateResult: true,
    nativeCarrier: 'fixture', androidSafDeviceTraversal: false }))
}
