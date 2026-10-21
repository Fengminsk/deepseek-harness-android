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
const imageRequire = createRequire(new URL('../../../packages/attachment/attachment-local/package.json', import.meta.url))
const sharp = imageRequire('sharp')

const image = async (format = 'png', options = {}) => sharp({
  create: { width: 12, height: 8, channels: 3, background: { r: 12, g: 200, b: 64 }, ...options },
}).toFormat(format).toBuffer()

function deferred() {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}

async function fixture(run, config = {}) {
  const root = await mkdtemp(join(tmpdir(), 'pocket-attachment-test-'))
  const ctx = new Context()
  const agents = new Map()
  ctx.provide('agents', { get: id => agents.get(id) })
  ctx.provide('commands', { registerFileReceiptResolver: () => () => {} })
  ctx.provide('connection', { fetch: { register: () => () => {} } })
  const store = new LocalAttachmentStore(ctx, { dshHome: join(root, 'home'), ...config })
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
  try { await run({ bridge, root, selected, agents, store, uploads, ctx, ensureSession }) }
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
    assert.deepEqual(await bridge.content('one', [id]), [{ type: 'file', receiptId: receipt.receiptId }])
    assert.deepEqual(await bridge.commandContent('one', [id]), await bridge.content('one', [id]))
    await assert.rejects(bridge.content('two', [id]), /未就绪/)
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
    await assert.rejects(bridge.content('one', [id]), /凭据已失效/)
    const after = await bridge.prepare({ sessionId: 'one', id })
    assert.notEqual(after.receiptId, before.receiptId)
    assert.deepEqual(after.file, before.file)
  })
})

for (const format of ['png', 'jpeg', 'webp', 'gif']) {
  test(`${format} remains original image wire until DSH admits the batch, without file receipts or premature writes`, async () => {
    await fixture(async ({ bridge, selected, uploads, store, root }) => {
      const data = await image(format)
      const name = `相片.${format}`
      const mediaType = `image/${format}`
      const id = await selected(data, { mediaType, name })
      uploads.uploadStream = async () => { assert.fail('image silently fell back to a generic file') }
      const originalSave = store.saveImages.bind(store)
      let admitted = 0
      store.saveImages = async inputs => { admitted++; return originalSave(inputs) }
      assert.deepEqual(await bridge.prepare({ sessionId: 'one', id }), {
        id, kind: 'image', name, mediaType, bytes: data.length,
      })
      const expected = [{ type: 'image', mediaType, name, data: data.toString('base64') }]
      assert.deepEqual(await bridge.content('one', [id]), expected)
      assert.deepEqual(await bridge.commandContent('one', [id]), expected)
      assert.deepEqual(await bridge.preview({ sessionId: 'one', id }), {
        id, kind: 'image', name, mediaType, bytes: data.length, data: data.toString('base64'),
      })
      assert.equal(admitted, 0, 'prepare/content/preview do not bypass authoritative prompt admission')
      await assert.rejects(readFile(join(root, 'home', 'attachments', 'v1')), { code: 'ENOENT' })
      const parts = await store.admitPromptContent(expected)
      assert.equal(admitted, 1)
      assert.equal(parts[0].type, 'image')
      assert.equal(parts[0].attachment.width, 12)
      assert.equal(parts[0].attachment.height, 8)
      const stored = await store.readImage(parts[0].attachment)
      assert.ok(stored.data.length > 0)
      await bridge.release({ sessionId: 'one', id })
      assert.deepEqual((await store.readImage(parts[0].attachment)).data, stored.data,
        'removing a consumed draft leaves original-core durable image bytes intact')
      assert.equal('data' in (bridge.records.get(id) ?? {}), false)
    })
  })
}

test('mixed image/file command and prompt content preserves attachment order and each original wire shape', async () => {
  await fixture(async ({ bridge, selected, uploads, agents, store }) => {
    const picture = await image()
    const imageId = await selected(picture, { name: 'photo.png', mediaType: 'image/png' })
    const fileId = await selected(Buffer.from('document'))
    await bridge.prepare({ sessionId: 'one', id: imageId })
    const file = await bridge.prepare({ sessionId: 'one', id: fileId })
    const parts = await bridge.content('one', [fileId, imageId, fileId])
    assert.deepEqual(parts.map(part => part.type), ['file', 'image', 'file'])
    assert.equal(parts[0].receiptId, file.receiptId)
    assert.deepEqual(await bridge.commandContent('one', [fileId, imageId, fileId]), parts)
    const admitted = await store.admitPromptContent(parts.map(part => part.type === 'file'
      ? { type: 'file', attachment: uploads.resolve(agents.get('one'), part.receiptId) } : part))
    assert.deepEqual(admitted.map(part => part.type), ['file', 'image', 'file'])
    assert.deepEqual(admitted[0].attachment, file.file)
  })
})

test('invalid, mismatched and unsupported images remain private drafts and never become ordinary files', async () => {
  await fixture(async ({ bridge, selected, uploads, root }) => {
    uploads.uploadStream = async () => { assert.fail('image silently fell back to a generic file') }
    for (const [data, mediaType, code] of [
      [Buffer.from('not an image'), 'image/png', 'INVALID_IMAGE'],
      [await image(), 'image/jpeg', 'IMAGE_TYPE_MISMATCH'],
      [await image(), 'image/heic', 'UNSUPPORTED_IMAGE_TYPE'],
    ]) {
      const id = await selected(data, { mediaType, name: 'photo' })
      await assert.rejects(bridge.prepare({ sessionId: 'one', id }), { code })
      assert.deepEqual(await readFile(join(root, `${id}.bin`)), data)
      await assert.rejects(bridge.content('one', [id]), /未就绪/)
      await assert.rejects(bridge.preview({ sessionId: 'one', id }), /未就绪/)
    }
  })
})

test('preparation honors original byte, pixel and dimension limits while retaining the selection', async () => {
  const data = await image()
  for (const [config, code] of [
    [{ maxImageBytes: data.length - 1 }, 'IMAGE_TOO_LARGE'],
    [{ maxImagePixels: 95 }, 'IMAGE_TOO_MANY_PIXELS'],
    [{ maxImageDimension: 11 }, 'IMAGE_DIMENSION_TOO_LARGE'],
  ]) {
    await fixture(async ({ bridge, selected, root }) => {
      const id = await selected(data, { mediaType: 'image/png' })
      await assert.rejects(bridge.prepare({ sessionId: 'one', id }), { code })
      assert.deepEqual(await readFile(join(root, `${id}.bin`)), data)
    }, config)
  }
})

test('image count and total bytes include repeated IDs and are checked before payload reads', async () => {
  const data = await image()
  for (const [config, code] of [
    [{ maxImagesPerMessage: 1 }, 'TOO_MANY_IMAGES'],
    [{ maxMessageImageBytes: data.length * 2 - 1 }, 'IMAGES_TOO_LARGE'],
  ]) {
    await fixture(async ({ bridge, selected }) => {
      const id = await selected(data, { mediaType: 'image/png' })
      await bridge.prepare({ sessionId: 'one', id })
      const original = bridge.readImage.bind(bridge)
      let reads = 0
      bridge.readImage = async (...args) => { reads++; return original(...args) }
      await assert.rejects(bridge.content('one', [id, id]), { code })
      await assert.rejects(bridge.commandContent('one', [id, id]), { code })
      assert.equal(reads, 0)
      assert.equal((await bridge.content('one', [id]))[0].type, 'image', 'a batch rejection does not consume a draft')
    }, config)
  }
})

test('same-length source replacement fails digest revalidation; explicit retry validates the replacement', async () => {
  await fixture(async ({ bridge, selected, root }) => {
    const data = await image()
    const id = await selected(data, { mediaType: 'image/png' })
    await bridge.prepare({ sessionId: 'one', id })
    const changed = Buffer.from(data)
    changed[changed.length - 1] ^= 1
    await writeFile(join(root, `${id}.bin`), changed)
    await assert.rejects(bridge.content('one', [id]), /Selected image changed/)
    await assert.rejects(bridge.preview({ sessionId: 'one', id }), /未就绪/)
    assert.deepEqual(await readFile(join(root, `${id}.bin`)), changed)
    await writeFile(join(root, `${id}.bin`), data)
    await bridge.prepare({ sessionId: 'one', id })
    assert.equal((await bridge.content('one', [id]))[0].data, data.toString('base64'))
  })
})

test('source growth or changed metadata cannot expand the prepared image read budget', async () => {
  for (const change of ['source', 'metadata']) {
    await fixture(async ({ bridge, selected, root }) => {
      const data = await image()
      const id = await selected(data, { mediaType: 'image/png', name: 'photo.png' })
      await bridge.prepare({ sessionId: 'one', id })
      if (change === 'source') await writeFile(join(root, `${id}.bin`), Buffer.concat([data, Buffer.from('growth')]))
      else await writeFile(join(root, `${id}.json`), JSON.stringify({
        id, mediaType: 'image/png', name: 'replacement.png', bytes: data.length,
      }))
      await assert.rejects(bridge.preview({ sessionId: 'one', id }), /Selected (?:file|image) changed/)
      assert.ok((await readFile(join(root, `${id}.bin`))).length >= data.length)
    })
  }
})

test('image draft ownership, session retirement and service restart require fresh preparation', async () => {
  await fixture(async ({ bridge, selected, agents, root, ctx, ensureSession }) => {
    const data = await image()
    const id = await selected(data, { mediaType: 'image/png' })
    await bridge.prepare({ sessionId: 'one', id })
    await assert.rejects(bridge.preview({ sessionId: 'two', id }), /未就绪/)
    await assert.rejects(bridge.content('two', [id]), /未就绪/)
    await assert.rejects(bridge.release({ sessionId: 'two', id }), /another conversation/)
    agents.set('one', { id: 'one', session: { header: {} } })
    await assert.rejects(bridge.content('one', [id]), /已失效/)
    await bridge.prepare({ sessionId: 'one', id })
    assert.equal((await bridge.preview({ sessionId: 'one', id })).data, data.toString('base64'))
    await bridge.close()
    await assert.rejects(bridge.content('one', [id]), /closed/)
    assert.deepEqual(await readFile(join(root, `${id}.bin`)), data)
    const next = new AppAttachments(ctx, { directory: async () => root, ensureSession })
    try {
      await assert.rejects(next.content('one', [id]), /未就绪/)
      await next.prepare({ sessionId: 'one', id })
      assert.equal((await next.content('one', [id]))[0].data, data.toString('base64'))
    } finally { await next.close() }
  })
})

test('preview refuses regular files and caps only preview bytes independently of original send limits', async () => {
  await fixture(async ({ bridge, selected }) => {
    const fileId = await selected(Buffer.from('document'))
    await bridge.prepare({ sessionId: 'one', id: fileId })
    await assert.rejects(bridge.preview({ sessionId: 'one', id: fileId }), /Only prepared image/)
    const id = await selected(await image(), { mediaType: 'image/png' })
    await bridge.prepare({ sessionId: 'one', id })
    // Test the pre-allocation guard without allocating a giant fixture or decoding 21 MiB.
    bridge.records.get(id).item.bytes = 21 * 1024 * 1024
    bridge.readImage = async () => { assert.fail('oversized preview reached payload read') }
    await assert.rejects(bridge.preview({ sessionId: 'one', id }), { code: 'IMAGE_PREVIEW_TOO_LARGE' })
    // Ordinary content is governed by core limits, then fails the intentionally changed source identity.
    await assert.rejects(bridge.content('one', [id]), /Selected image changed/)
  }, { maxImageBytes: 40 * 1024 * 1024, maxMessageImageBytes: 80 * 1024 * 1024 })
})

test('replacing the original image policy invalidates cached preparation before preview or send', async () => {
  await fixture(async ({ bridge, selected, ctx, root }) => {
    const data = await image()
    const id = await selected(data, { mediaType: 'image/png' })
    await bridge.prepare({ sessionId: 'one', id })
    const nextContext = new Context()
    const nextStore = new LocalAttachmentStore(nextContext, {
      dshHome: join(root, 'next-home'), maxImagePixels: 95,
    })
    bridge.ctx = { agents: ctx.agents, fileUploads: ctx.fileUploads, attachments: nextStore }
    try {
      await assert.rejects(bridge.preview({ sessionId: 'one', id }), /已失效/)
      await assert.rejects(bridge.prepare({ sessionId: 'one', id }), { code: 'IMAGE_TOO_MANY_PIXELS' })
      assert.deepEqual(await readFile(join(root, `${id}.bin`)), data)
    } finally { await nextContext.fiber.dispose() }
  })
})

test('retiring an Agent while image bytes are being read rejects the late result', async () => {
  await fixture(async ({ bridge, selected, agents }) => {
    const id = await selected(await image(), { mediaType: 'image/png' })
    await bridge.prepare({ sessionId: 'one', id })
    const entered = deferred(), resume = deferred()
    const original = bridge.readImage.bind(bridge)
    bridge.readImage = async (...args) => { entered.resolve(); await resume.promise; return original(...args) }
    const content = bridge.content('one', [id])
    const rejected = assert.rejects(content, /已失效/)
    await entered.promise
    agents.set('one', { id: 'one', session: { header: {} } })
    resume.resolve()
    await rejected
    await bridge.prepare({ sessionId: 'one', id })
    assert.equal((await bridge.content('one', [id]))[0].type, 'image')
  })
})

test('concurrent image preparation deduplicates and retains no binary payload after validation', async () => {
  await fixture(async ({ bridge, selected, store }) => {
    const id = await selected(await image(), { mediaType: 'image/png' })
    const original = store.validateImage.bind(store)
    let validations = 0
    store.validateImage = async input => { validations++; return original(input) }
    const first = bridge.prepare({ sessionId: 'one', id })
    assert.equal(first, bridge.prepare({ sessionId: 'one', id }))
    await first
    assert.equal(first, bridge.prepare({ sessionId: 'one', id }))
    assert.equal(validations, 1)
    assert.equal(Object.values(bridge.records.get(id)).some(value => Buffer.isBuffer(value)), false)
  })
})

test('remove during original image validation cancels readiness and waits before deleting the source', async () => {
  await fixture(async ({ bridge, selected, store, root }) => {
    const id = await selected(await image(), { mediaType: 'image/png' })
    const entered = deferred(), resume = deferred()
    const original = store.validateImage.bind(store)
    store.validateImage = async input => { entered.resolve(); await resume.promise; return original(input) }
    const pending = bridge.prepare({ sessionId: 'one', id })
    const rejected = assert.rejects(pending, /removed/)
    await entered.promise
    const removal = bridge.release({ sessionId: 'one', id })
    assert.ok((await readFile(join(root, `${id}.bin`))).length > 0)
    resume.resolve()
    await removal
    await rejected
    await assert.rejects(bridge.content('one', [id]), /未就绪/)
    await assert.rejects(readFile(join(root, `${id}.bin`)), { code: 'ENOENT' })
  })
})

test('remove or close during image read rejects late content; only explicit removal deletes source', async () => {
  for (const operation of ['remove', 'close']) {
    await fixture(async ({ bridge, selected, root }) => {
      const data = await image()
      const id = await selected(data, { mediaType: 'image/png' })
      await bridge.prepare({ sessionId: 'one', id })
      const entered = deferred(), resume = deferred()
      const original = bridge.readImage.bind(bridge)
      bridge.readImage = async (...args) => { entered.resolve(); await resume.promise; return original(...args) }
      const pending = bridge.preview({ sessionId: 'one', id })
      const rejected = assert.rejects(pending, operation === 'remove' ? /removed/ : /stopped/)
      await entered.promise
      const stopping = operation === 'remove' ? bridge.release({ sessionId: 'one', id }) : bridge.close()
      resume.resolve()
      await rejected
      await stopping
      if (operation === 'remove') await assert.rejects(readFile(join(root, `${id}.bin`)), { code: 'ENOENT' })
      else assert.deepEqual(await readFile(join(root, `${id}.bin`)), data)
    })
  }
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
    await assert.rejects(bridge.content('one', [id]), /未就绪/)
    await assert.rejects(readFile(join(root, `${id}.bin`)), { code: 'ENOENT' })
  })
})
