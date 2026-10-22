import assert from 'node:assert/strict'
import { test } from 'node:test'
import { randomUUID } from 'node:crypto'
import { AppDocumentPreview } from '../runtime/document-preview.mjs'

const budgets = { maxRequests: 8, maxOwnerRequests: 4, maxLeaseBytes: 1024 * 1024,
  maxLeases: 8, leaseTimeoutMs: 2000, requestTimeoutMs: 1000, closeTimeoutMs: 100 }
const input = (extra = {}) => ({ owner: 'native-owner', requestId: randomUUID(), sessionId: 'cold-session',
  namespace: 'workspaceFiles', method: 'readBytes', args: { path: 'report.bin' }, ...extra })
const bytes = (data = Buffer.from([0, 255, 17]), extra = {}) => ({ absolutePath: '/workspace/report.bin',
  version: 'original-version', bytes: 500, offset: 123, eof: false, data, ...extra })
const value = result => { assert.equal(result.ok, true, JSON.stringify(result)); return result.value }
const rejected = (result, code) => { assert.equal(result.ok, false, JSON.stringify(result)); assert.equal(result.error.code, code) }
function fixture(t, invoke, overrides = {}) {
  const reports = []
  const bridge = new AppDocumentPreview({ invoke, limits: () => ({ ...budgets, ...overrides }), report: error => reports.push(error) })
  t.after(() => bridge.close())
  return { bridge, reports }
}

test('media policy follows live original limits without reading files and requires an owner', async t => {
  let maxBytes = 1234
  const seen = []
  const bridge = new AppDocumentPreview({
    invoke: () => { throw new Error('Policy must not read or open a Session') },
    limits: () => budgets,
    mediaPolicy: path => { seen.push(path); return { maxBytes, mimeType: 'image/svg+xml' } },
  })
  t.after(() => bridge.close())
  assert.deepEqual(value(await bridge.call('mediaPolicy', { owner: 'app', path: '/workspace/photo.svg' })),
    { maxBytes: 1234, mimeType: 'image/svg+xml' })
  maxBytes = 5678
  assert.equal(value(await bridge.call('mediaPolicy', { owner: 'app', path: '/workspace/photo.svg' })).maxBytes, 5678)
  for (const params of [{ path: '/workspace/photo.svg' }, { owner: 'app', path: 'photo.svg' },
    { owner: 'app', path: '/workspace/\0photo.svg' }]) {
    rejected(await bridge.call('mediaPolicy', params), 'gateway/bad-request')
  }
  assert.equal(seen.length, 2)
  maxBytes = undefined
  rejected(await bridge.call('mediaPolicy', { owner: 'app', path: '/photo.svg' }), 'gateway/invocation-unavailable')
  await bridge.closeOwner('app')
  rejected(await bridge.call('mediaPolicy', { owner: 'app', path: '/photo.svg' }), 'gateway/cancelled')
})

test('only original read-only methods enter Gateway with the selected Session scope', async t => {
  const seen = []
  const { bridge } = fixture(t, async (...args) => { seen.push(args); return { original: true } })
  for (const method of ['stat', 'read', 'list']) {
    assert.deepEqual(value(await bridge.call('call', input({ method }))), { original: true })
    assert.deepEqual(seen.at(-1).slice(0, 3), ['workspaceFiles', method,
      { path: 'report.bin', workspaceFileScopeId: 'cold-session', ...(method === 'read' ? { range: {} } : {}) }])
    assert.ok(seen.at(-1)[3] instanceof AbortSignal)
  }
  for (const request of [
    input({ namespace: 'session', method: 'ensure' }), input({ method: 'changes' }),
    input({ namespace: 'constructor', method: 'constructor' }), input({ method: '__proto__' }),
    input({ args: { path: 'report.bin', workspaceFileScopeId: 'other-session' } }),
    input({ args: { path: 'report.bin', sessionId: 'other-session' } }), input({ args: [] }),
    input({ sessionId: '' }), input({ owner: '' }), input({ requestId: '' }),
  ]) rejected(await bridge.call('call', request), 'gateway/bad-request')
  assert.equal(seen.length, 3, 'invalid requests must never enter Gateway')
})

test('binary lease preserves original metadata and exact bytes in bounded chunks', async t => {
  const source = Buffer.alloc(400000)
  for (let i = 0; i < source.length; i++) source[i] = i % 251
  let received
  const { bridge } = fixture(t, async (...args) => { received = args; return bytes(source) })
  const request = input({ args: { path: '../image.png', options: { range: { offset: 123, length: 400000 }, baseFile: 'document.md' } } })
  const result = value(await bridge.call('call', request))
  assert.deepEqual(received[2], { ...request.args, workspaceFileScopeId: request.sessionId })
  const { data: lease, ...metadata } = result
  assert.deepEqual(metadata, { absolutePath: '/workspace/report.bin', version: 'original-version', bytes: 500, offset: 123, eof: false })
  assert.equal(lease.encoding, 'android-byte-lease')
  assert.equal(lease.length, source.length)
  const first = value(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset: 0, length: 262144 }))
  const second = value(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset: 262144, length: 262144 }))
  assert.equal(first.eof, false)
  assert.equal(second.eof, true)
  assert.deepEqual(Buffer.concat([Buffer.from(first.data, 'base64'), Buffer.from(second.data, 'base64')]), source)
  assert.deepEqual(value(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset: source.length, length: 1 })),
    { offset: source.length, data: '', eof: true })
  for (const [offset, length] of [[-1, 1], [0, 262145], [0, 0], [source.length + 1, 1], [0.5, 1]]) {
    rejected(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset, length }), 'gateway/bad-request')
  }
})

test('leases reject foreign owners, release idempotently and do not retain backing storage', async t => {
  const source = Buffer.from([5, 6, 7, 8])
  const { bridge } = fixture(t, async () => bytes(source.subarray(1, 3)))
  const request = input()
  const lease = value(await bridge.call('call', request)).data
  source.fill(0)
  rejected(await bridge.call('bytes', { owner: 'other-owner', id: lease.id, offset: 0, length: 4 }), 'document-preview/lease-unavailable')
  rejected(await bridge.call('release', { owner: 'other-owner', id: lease.id }), 'document-preview/lease-unavailable')
  assert.deepEqual(value(await bridge.call('cancel', { owner: 'other-owner', requestId: request.requestId })), { cancelled: false })
  assert.equal(value(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset: 0, length: 4 })).data, 'Bgc=')
  assert.deepEqual(value(await bridge.call('release', { owner: request.owner, id: lease.id })), { released: true })
  assert.deepEqual(value(await bridge.call('release', { owner: request.owner, id: lease.id })), { released: false })
  rejected(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset: 0, length: 1 }), 'document-preview/lease-unavailable')
})

test('zero-byte leases preserve successful empty file semantics', async t => {
  const { bridge } = fixture(t, async () => bytes(Buffer.alloc(0), { bytes: 0, offset: 0, eof: true }))
  const lease = value(await bridge.call('call', input())).data
  assert.equal(lease.length, 0)
  assert.deepEqual(value(await bridge.call('bytes', { owner: 'native-owner', id: lease.id, offset: 0, length: 8 })),
    { offset: 0, data: '', eof: true })
})

test('Office render uses the same Session lookup and lease; generation alone is read-only', async t => {
  const calls = []
  const { bridge } = fixture(t, async (...args) => {
    calls.push(args)
    return args[1] === 'generation' ? 'engine-1' : bytes(Buffer.from('%PDF'), { missingFonts: ['Missing'], generation: 'engine-1' })
  })
  const rendered = value(await bridge.call('call', input({ namespace: 'officeToPdf', method: 'render', args: { path: 'a.docx' } })))
  assert.equal(rendered.data.encoding, 'android-byte-lease')
  assert.deepEqual(rendered.missingFonts, ['Missing'])
  assert.equal(rendered.generation, 'engine-1')
  assert.deepEqual(calls[0].slice(0, 3), ['officeToPdf', 'render',
    { path: 'a.docx', priority: 'foreground', workspaceFileScopeId: 'cold-session' }])
  assert.equal(value(await bridge.call('call', input({ namespace: 'officeToPdf', method: 'generation', args: {} }))), 'engine-1')
  assert.deepEqual(calls[1].slice(0, 3), ['officeToPdf', 'generation', {}])
  rejected(await bridge.call('call', input({ namespace: 'officeToPdf', method: 'convert' })), 'gateway/bad-request')
})

test('preserves original typed failure and reports unexpected errors without serializing internals', async t => {
  const original = Object.assign(new Error('Original denial'), { isDSHRemoteError: true,
    code: 'workspace-file/outside-workspace', details: { path: '..' } })
  const { bridge, reports } = fixture(t, async (_namespace, _method, args) => {
    if (args.path === 'bad') throw new Error('private implementation diagnostic')
    throw original
  })
  const result = await bridge.call('call', input())
  rejected(result, original.code)
  assert.deepEqual(result.error.details, original.details)
  assert.equal(result.error.message, original.message)
  const unexpected = await bridge.call('call', input({ args: { path: 'bad' } }))
  rejected(unexpected, 'gateway/internal')
  assert.equal(JSON.stringify(unexpected).includes('private'), false)
  assert.equal(reports.length, 1)
})

test('lease capacity and expiration free all retained-byte admission', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { bridge } = fixture(t, async () => bytes(Buffer.alloc(8)), { maxLeaseBytes: 8, maxLeases: 1 })
  const one = value(await bridge.call('call', input())).data
  rejected(await bridge.call('call', input()), 'document-preview/capacity')
  t.mock.timers.tick(budgets.leaseTimeoutMs)
  rejected(await bridge.call('bytes', { owner: 'native-owner', id: one.id, offset: 0, length: 1 }), 'document-preview/lease-unavailable')
  const two = value(await bridge.call('call', input())).data
  value(await bridge.call('release', { owner: 'native-owner', id: two.id }))
  assert.equal(value(await bridge.call('call', input())).data.length, 8)
})

test('duplicate ids cannot alias a pending request or a published lease', async t => {
  const entered = Promise.withResolvers(), finish = Promise.withResolvers()
  const { bridge } = fixture(t, async () => { entered.resolve(); await finish.promise; return bytes() })
  const request = input()
  const pending = bridge.call('call', request)
  await entered.promise
  rejected(await bridge.call('call', request), 'gateway/bad-request')
  finish.resolve()
  const lease = value(await pending).data
  rejected(await bridge.call('call', request), 'gateway/bad-request')
  value(await bridge.call('release', { owner: request.owner, id: lease.id }))
  value(await bridge.call('call', request))
})

test('cancellation reaches original signal and blocks late binary publication', async t => {
  const entered = Promise.withResolvers(), finish = Promise.withResolvers(), aborted = Promise.withResolvers()
  const { bridge } = fixture(t, async (_namespace, _method, _args, signal) => {
    signal.addEventListener('abort', () => aborted.resolve(), { once: true })
    entered.resolve()
    await finish.promise
    return bytes()
  }, { maxLeases: 1 })
  const request = input()
  const pending = bridge.call('call', request)
  await entered.promise
  const cancelled = bridge.call('cancel', request)
  await aborted.promise
  rejected(await pending, 'gateway/cancelled')
  finish.resolve()
  assert.deepEqual(value(await cancelled), { cancelled: true })
  value(await bridge.call('call', input()))
})

test('cancelling a completed request revokes its published lease', async t => {
  const { bridge } = fixture(t, async () => bytes())
  const request = input(), lease = value(await bridge.call('call', request)).data
  assert.deepEqual(value(await bridge.call('cancel', request)), { cancelled: true })
  rejected(await bridge.call('bytes', { owner: request.owner, id: lease.id, offset: 0, length: 8 }), 'document-preview/lease-unavailable')
})

test('owner and global concurrency limits remain occupied until provider completion', async t => {
  const entered = Promise.withResolvers(), finish = Promise.withResolvers()
  const { bridge } = fixture(t, async () => { entered.resolve(); await finish.promise; return bytes() },
    { maxRequests: 2, maxOwnerRequests: 1 })
  const first = bridge.call('call', input())
  await entered.promise
  rejected(await bridge.call('call', input()), 'document-preview/busy')
  const second = bridge.call('call', input({ owner: 'second-owner' }))
  rejected(await bridge.call('call', input({ owner: 'third-owner' })), 'document-preview/busy')
  finish.resolve()
  value(await first)
  value(await second)
})

test('deadline returns failure while retaining a non-cooperative provider slot until it settles', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const entered = Promise.withResolvers(), finish = Promise.withResolvers()
  const { bridge } = fixture(t, async () => { entered.resolve(); await finish.promise; return bytes() }, { maxRequests: 1 })
  const pending = bridge.call('call', input())
  await entered.promise
  t.mock.timers.tick(budgets.requestTimeoutMs)
  rejected(await pending, 'document-preview/timeout')
  rejected(await bridge.call('call', input()), 'document-preview/busy')
  const closing = bridge.close()
  finish.resolve()
  await closing
})

test('cleanup timeout reports pending work but can never publish its eventual bytes', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const entered = Promise.withResolvers(), finish = Promise.withResolvers()
  const { bridge } = fixture(t, async () => { entered.resolve(); await finish.promise; return bytes() })
  const request = input(), pending = bridge.call('call', request)
  await entered.promise
  const cancellation = bridge.call('cancel', request)
  t.mock.timers.tick(budgets.closeTimeoutMs)
  rejected(await pending, 'gateway/cancelled')
  rejected(await cancellation, 'document-preview/cleanup-timeout')
  const closing = bridge.close()
  finish.resolve()
  await closing
})

test('disconnect revokes leases, aborts in-flight work and rejects the same disconnected owner', async t => {
  const entered = Promise.withResolvers(), finish = Promise.withResolvers()
  let hold = false
  const { bridge } = fixture(t, async () => { if (hold) { entered.resolve(); await finish.promise } return bytes() })
  const lease = value(await bridge.call('call', input())).data
  hold = true
  const pending = bridge.call('call', input())
  await entered.promise
  const closing = bridge.closeOwner('native-owner')
  rejected(await pending, 'gateway/cancelled')
  rejected(await bridge.call('bytes', { owner: 'native-owner', id: lease.id, offset: 0, length: 1 }), 'gateway/cancelled')
  rejected(await bridge.call('call', input()), 'gateway/cancelled')
  finish.resolve()
  await closing
  value(await bridge.call('call', input({ owner: 'new-connection-owner' })))
})
