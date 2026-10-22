import assert from 'node:assert/strict'
import { test } from 'node:test'
import { AppChatImages } from '../runtime/chat-images.mjs'

function fixture(bytes = Buffer.from('original-image')) {
  const calls = []
  const invoke = async (namespace, method, args, signal) => {
    calls.push({ namespace, method, args, signal })
    if (method === 'stat') return { absolutePath: '/workspace/image.png', version: 'v1', bytes: bytes.length }
    const { offset, length } = args.options.range
    return { absolutePath: '/workspace/image.png', version: 'v1', bytes: bytes.length,
      offset, data: bytes.subarray(offset, offset + length), eof: offset + length === bytes.length }
  }
  const reader = new AppChatImages({ invoke, mimeType: () => 'image/png',
    limits: () => ({ maxBytes: 8 * 1024 * 1024, maxRequests: 4, timeoutMs: 30000, closeTimeoutMs: 1000 }) })
  return { calls, reader }
}

test('settled image uses only original Session-scoped stat and bounded byte windows', async () => {
  const data = Buffer.alloc(1024 * 1024 + 5, 71)
  const { calls, reader } = fixture(data)
  const result = await reader.preview({ sessionId: 'viewed-session', path: 'image.png' })
  assert.deepEqual(result, { sessionId: 'viewed-session', path: 'image.png', mediaType: 'image/png',
    bytes: data.length, data: data.toString('base64') })
  assert.deepEqual(calls.map(call => [call.namespace, call.method, call.args]), [
    ['workspaceFiles', 'stat', { workspaceFileScopeId: 'viewed-session', path: 'image.png' }],
    ['workspaceFiles', 'readBytes', { workspaceFileScopeId: 'viewed-session', path: 'image.png',
      options: { range: { offset: 0, length: 1024 * 1024 } } }],
    ['workspaceFiles', 'readBytes', { workspaceFileScopeId: 'viewed-session', path: 'image.png',
      options: { range: { offset: 1024 * 1024, length: 5 } } }],
  ])
  await reader.close()
})

test('no unsupported URL or path shape reaches the Session file service', async () => {
  const { calls, reader } = fixture()
  for (const params of [
    { sessionId: '', path: 'image.png' }, { sessionId: 'a', path: '' },
    { sessionId: 'a', path: 'image\n.png' },
    { sessionId: 'a', path: 'https://example.test/image.png' },
  ]) await assert.rejects(reader.preview(params), { code: 'gateway/bad-request' })
  const unsupported = new AppChatImages({ invoke: (...args) => calls.push(args), mimeType: () => 'text/html',
    limits: () => ({ maxBytes: 8, maxRequests: 1, timeoutMs: 1000, closeTimeoutMs: 1000 }) })
  await assert.rejects(unsupported.preview({ sessionId: 'a', path: 'page.html' }), { code: 'chat-image/unsupported' })
  assert.equal(calls.length, 0)
  await reader.close()
  await unsupported.close()
})

test('oversize and changed files publish no partial image', async () => {
  const { reader, calls } = fixture(Buffer.from('abc'))
  reader.limits = () => ({ maxBytes: 2, maxRequests: 4, timeoutMs: 1000, closeTimeoutMs: 1000 })
  await assert.rejects(reader.preview({ sessionId: 's', path: 'image.png' }), { code: 'chat-image/too-large' })
  assert.deepEqual(calls.map(call => call.method), ['stat'])
  await reader.close()

  const changed = fixture(Buffer.from('abc'))
  changed.reader.invoke = async (namespace, method, args) => method === 'stat'
    ? { absolutePath: '/workspace/image.png', version: 'v1', bytes: 3 }
    : { absolutePath: '/workspace/image.png', version: 'v2', bytes: 3,
      offset: 0, data: Buffer.from('abc'), eof: true }
  await assert.rejects(changed.reader.preview({ sessionId: 's', path: 'image.png' }), { code: 'chat-image/changed' })
  await changed.reader.close()
})

test('missing original media policy fails before any file read', async () => {
  const { reader, calls } = fixture()
  reader.limits = () => ({ maxBytes: 0, maxRequests: 4, timeoutMs: 1000, closeTimeoutMs: 1000 })
  await assert.rejects(reader.preview({ sessionId: 's', path: 'image.png' }), { code: 'chat-image/unavailable' })
  assert.equal(calls.length, 0)
  await reader.close()
})

test('closing during an unresponsive read answers cancellation and holds its slot', async () => {
  let release
  const pending = new Promise(resolve => { release = resolve })
  const reader = new AppChatImages({
    invoke: async (_namespace, method) => method === 'stat' ? pending : null,
    mimeType: () => 'image/png',
    limits: () => ({ maxBytes: 8, maxRequests: 1, timeoutMs: 30000, closeTimeoutMs: 1000 }),
  })
  const first = reader.preview({ sessionId: 's', path: 'a.png' })
  await Promise.resolve()
  await assert.rejects(reader.preview({ sessionId: 's', path: 'b.png' }), { code: 'chat-image/busy' })
  const closing = reader.close()
  await assert.rejects(first, { code: 'gateway/cancelled' })
  release({ absolutePath: '/a.png', version: 'v1', bytes: 1 })
  await closing
  await assert.rejects(reader.preview({ sessionId: 's', path: 'a.png' }), { code: 'gateway/cancelled' })
})
