// Built-artifact boundary: real DSH FileUploads + local attachment store, no HTTP listener.
import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { test } from 'node:test'
import { AppAttachments } from '../runtime/attachments.mjs'

const require = createRequire(new URL('../../../packages/api/session-controller/package.json', import.meta.url))
const load = name => import(pathToFileURL(require.resolve(name)).href)
const { Context } = await load('@deepseek-ai/cordis')
const { default: FileUploads } = await load('@deepseek-ai/dsh-client-file-upload')
const { default: LocalAttachmentStore } = await import('../../../packages/attachment/attachment-local/lib/index.js')

async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'pocket-attachment-test-'))
  const ctx = new Context()
  const agents = new Map()
  ctx.provide('agents', { get: id => agents.get(id) })
  ctx.provide('commands', { registerFileReceiptResolver: () => () => {} })
  ctx.provide('connection', { fetch: { register: () => () => {} } })
  const store = new LocalAttachmentStore(ctx, { dshHome: join(root, 'home') })
  const uploads = new FileUploads(ctx)
  const ensureSession = async id => {
    if (!agents.has(id)) agents.set(id, { id, session: { header: {} } })
  }
  const bridge = new AppAttachments(ctx, { directory: async () => root, ensureSession })
  const selected = async (data, { name = '测试.txt', mediaType = 'text/plain' } = {}) => {
    const id = randomUUID()
    await writeFile(join(root, `${id}.bin`), data)
    await writeFile(join(root, `${id}.json`), JSON.stringify({ id, name, mediaType, bytes: data.length }))
    return id
  }
  try { await run({ bridge, root, selected, agents, store, uploads, ctx }) }
  finally {
    await bridge.close()
    await ctx.fiber.dispose()
    // Fresh mkdtemp root, containing only fixtures allocated by this test.
    await rm(root, { recursive: true, maxRetries: 3, retryDelay: 30 })
  }
}

test('native selected bytes produce a real DSH receipt and unchanged persistent object without Web', async () => {
  await fixture(async ({ bridge, selected, store, uploads, agents, root }) => {
    const bytes = Buffer.from('中文🙂\nattachment\u0000bytes')
    const id = await selected(bytes)
    const receipt = await bridge.prepare({ sessionId: 'one', id })
    assert.equal(receipt.file.attachmentId, `sha256:${createHash('sha256').update(bytes).digest('hex')}`)
    assert.deepEqual(uploads.resolve(agents.get('one'), receipt.receiptId), receipt.file)
    assert.deepEqual(await readFile(store.fileHostPath(receipt.file)), bytes)
    assert.deepEqual(bridge.content('one', [id]), [{ type: 'file', receiptId: receipt.receiptId }])
    assert.deepEqual(bridge.commandContent('one', [id]), bridge.content('one', [id]))
    assert.throws(() => bridge.content('two', [id]), /未就绪/)
    assert.throws(() => bridge.prepare({ sessionId: 'two', id }), /another conversation/)
    await bridge.release({ sessionId: 'one', id })
    await assert.rejects(readFile(join(root, `${id}.bin`)), { code: 'ENOENT' })
    assert.deepEqual(await readFile(store.fileHostPath(receipt.file)), bytes, 'release never deletes committed objects')
    assert.deepEqual(await bridge.release({ sessionId: 'one', id }), { released: true })
  })
})

test('storage failures log stable cause codes without selected names, paths or error payloads', async t => {
  const diagnostics = []
  t.mock.method(console, 'error', (...args) => diagnostics.push(args.join(' ')))
  await fixture(async ({ bridge, selected, uploads, root }) => {
    const id = await selected(Buffer.from('synthetic private content'), { name: 'private-fixture.txt' })
    const cause = Object.assign(new Error('PRIVATE_ERROR_PAYLOAD'), { code: 'EACCES', path: '/private/fixture' })
    const failure = Object.assign(new Error('PRIVATE_OUTER_MESSAGE', { cause }), { code: 'ATTACHMENT_WRITE_FAILED' })
    uploads.uploadStream = async () => { throw failure }
    await assert.rejects(bridge.prepare({ sessionId: 'diagnostics', id }), error => error === failure)
    assert.deepEqual(diagnostics, ['Pocket attachment storage failure: ATTACHMENT_WRITE_FAILED > EACCES'])
    assert.ok((await readFile(join(root, `${id}.bin`))).length > 0)
  })
})

test('concurrent prepare deduplicates; failed upload preserves selection and retries real receipt creation', async () => {
  await fixture(async ({ bridge, selected, uploads, root }) => {
    const id = await selected(Buffer.from('retry'))
    const original = uploads.uploadStream.bind(uploads)
    let calls = 0
    uploads.uploadStream = async request => {
      calls++
      if (calls === 1) throw new Error('disk unavailable')
      return original(request)
    }
    const one = bridge.prepare({ sessionId: 'one', id })
    const two = bridge.prepare({ sessionId: 'one', id })
    assert.equal(one, two)
    await assert.rejects(one, /disk unavailable/)
    assert.equal((await readFile(join(root, `${id}.bin`))).toString(), 'retry')
    const receipt = await bridge.prepare({ sessionId: 'one', id })
    assert.ok(receipt.receiptId)
    assert.equal(calls, 2)
  })
})

test('retired Session receipt refuses send and re-uploads from selected cache on retry', async () => {
  await fixture(async ({ bridge, selected, agents }) => {
    const id = await selected(Buffer.from('restart'))
    const before = await bridge.prepare({ sessionId: 'one', id })
    agents.set('one', { id: 'one', session: { header: {} } })
    assert.throws(() => bridge.content('one', [id]), /凭据已失效/)
    const after = await bridge.prepare({ sessionId: 'one', id })
    assert.notEqual(after.receiptId, before.receiptId)
    assert.deepEqual(after.file, before.file)
  })
})

test('unsupported image processing keeps image selection and never calls generic file upload', async () => {
  await fixture(async ({ bridge, selected, uploads, root }) => {
    const id = await selected(Buffer.from('image fixture'), { mediaType: 'image/png', name: 'photo.png' })
    uploads.uploadStream = async () => { assert.fail('image silently fell back to a generic file') }
    await assert.rejects(bridge.prepare({ sessionId: 'one', id }), { code: 'IMAGE_RUNTIME_UNAVAILABLE' })
    assert.equal((await readFile(join(root, `${id}.bin`))).toString(), 'image fixture')
    assert.throws(() => bridge.content('one', [id]), /未就绪/)
  })
})

test('arbitrary URI and path identities cannot select native cache files', async () => {
  await fixture(async ({ bridge }) => {
    for (const id of ['content://provider/private', '../foreign', '/private/key', 'not-a-uuid']) {
      assert.throws(() => bridge.prepare({ sessionId: 'one', id }), /identity/)
      await assert.rejects(bridge.release({ sessionId: 'one', id }), /identity/)
    }
  })
})

test('remove aborts an active stream and does not leave a sendable receipt', async () => {
  await fixture(async ({ bridge, selected, uploads, root }) => {
    const id = await selected(Buffer.alloc(1024))
    let started
    const entered = new Promise(resolve => { started = resolve })
    uploads.uploadStream = async ({ signal }) => {
      started()
      await new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason), { once: true })
      })
    }
    const pending = bridge.prepare({ sessionId: 'one', id })
    const failed = assert.rejects(pending, /removed/)
    await entered
    await bridge.release({ sessionId: 'one', id })
    await failed
    assert.throws(() => bridge.content('one', [id]), /未就绪/)
    await assert.rejects(readFile(join(root, `${id}.bin`)), { code: 'ENOENT' })
  })
})
