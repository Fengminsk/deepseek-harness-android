import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'
import { readAuthorizedImage, renderAuthorizedImage } from '../runtime/authorized-image.mjs'

const png = Buffer.from('89504e470d0a1a0a', 'hex')
const imageLimits = { maxImageBytes: 1024, maxMessageImageBytes: 512, mediaTypes: ['image/png'] }
const ref = { attachmentId: 'img_1', mediaType: 'image/png', bytes: png.length, width: 1, height: 1 }

function harness(overrides = {}) {
  const calls = []
  const saved = []
  const controller = new AbortController()
  const attachments = { imageLimits, async saveImage(value) { saved.push(value); return ref } }
  const llm = { async resolveModelInfo() { return { inputModalities: ['text', 'image'] } } }
  const ctx = { get(key) { return key === 'attachments' ? attachments : llm } }
  const result = { data: png.toString('base64'), bytes: png.length,
    sha256: createHash('sha256').update(png).digest('hex'), version: 'a'.repeat(64), name: 'pic.png' }
  const transport = { async request(method, params) {
    calls.push({ method, params })
    if (method === 'native.documents.image.cancel') return { cancelled: true }
    return result
  } }
  const execution = { signal: controller.signal, agent: { session: { requestHeader: () =>
    ({ config: { provider: 'test', model: 'vision' } }) }, options: {} } }
  Object.assign(attachments, overrides.attachments)
  Object.assign(llm, overrides.llm)
  Object.assign(transport, overrides.transport)
  return { calls, saved, controller, attachments, llm, ctx, transport, execution, result }
}

test('SAF image becomes a durable image content block, not raw base64 text', async () => {
  const h = harness()
  const value = await readAuthorizedImage(h.ctx, h.transport, { root: 'grant', path: 'pic.png' }, h.execution)
  assert.equal(h.calls.length, 1)
  assert.equal(h.calls[0].method, 'native.documents.image.read')
  assert.equal(h.calls[0].params.maxBytes, 512)
  assert.equal(h.saved.length, 1)
  assert.deepEqual(h.saved[0].data, png)
  const content = renderAuthorizedImage({ action: 'read_image' }, value)
  assert.equal(content.length, 2)
  assert.equal(content[1].type, 'image')
  assert.deepEqual(content[1].attachment, ref)
  assert.ok(!JSON.stringify(content).includes(h.result.data))
  assert.deepEqual(renderAuthorizedImage({ action: 'roots' }, { roots: [] }),
    [{ type: 'text', text: '{"roots":[]}' }])
})

test('route and storage gates reject before native provider access', async () => {
  const h = harness({ llm: { resolveModelInfo: async () => ({ inputModalities: ['text'] }) } })
  await assert.rejects(readAuthorizedImage(h.ctx, h.transport,
    { root: 'grant', path: 'pic.png' }, h.execution), /图片输入能力/)
  assert.equal(h.calls.length, 0)
  await assert.rejects(readAuthorizedImage(h.ctx, h.transport,
    { root: 'grant', path: 'note.txt' }, h.execution), /扩展名/)
  assert.equal(h.calls.length, 0)
  const disallowed = harness({ attachments: { imageLimits: { ...imageLimits, mediaTypes: ['image/jpeg'] } } })
  await assert.rejects(readAuthorizedImage(disallowed.ctx, disallowed.transport,
    { root: 'grant', path: 'pic.png' }, disallowed.execution), /不接受/)
  assert.equal(disallowed.calls.length, 0)
})

test('single-file grant and extensionless image are content-sniffed', async () => {
  const h = harness()
  const value = await readAuthorizedImage(h.ctx, h.transport,
    { root: 'one-file', path: '' }, h.execution)
  assert.equal(value.image.mediaType, 'image/png')
  assert.equal(h.calls[0].params.path, '')
})

test('malformed native bytes, changed digest and mislabeled image never save', async () => {
  for (const mutation of [
    result => { result.data = '***' },
    result => { result.sha256 = 'b'.repeat(64) },
    result => { result.bytes++ },
    result => { result.version = 'invalid' },
  ]) {
    const h = harness()
    mutation(h.result)
    await assert.rejects(readAuthorizedImage(h.ctx, h.transport,
      { root: 'grant', path: 'pic.png' }, h.execution))
    assert.equal(h.saved.length, 0)
  }
  const h = harness({ attachments: { imageLimits: { ...imageLimits,
    mediaTypes: ['image/png', 'image/jpeg'] } } })
  await assert.rejects(readAuthorizedImage(h.ctx, h.transport,
    { root: 'grant', path: 'pic.jpeg' }, h.execution), /格式不符/)
  assert.equal(h.saved.length, 0)
})

test('abort sends explicit native cancellation and prevents attachment write', async () => {
  const h = harness()
  let started
  const waiting = new Promise(resolve => { started = resolve })
  h.transport.request = async (method, params, signal) => {
    h.calls.push({ method, params })
    if (method === 'native.documents.image.read') {
      started()
      return new Promise((_, reject) => signal.addEventListener('abort',
        () => reject(signal.reason), { once: true }))
    }
    return { cancelled: true }
  }
  const reading = readAuthorizedImage(h.ctx, h.transport,
    { root: 'grant', path: 'pic.png' }, h.execution)
  await waiting
  h.controller.abort(new Error('cancel'))
  await assert.rejects(reading, /cancel/)
  assert.equal(h.calls.at(-1).method, 'native.documents.image.cancel')
  assert.equal(h.saved.length, 0)
})
