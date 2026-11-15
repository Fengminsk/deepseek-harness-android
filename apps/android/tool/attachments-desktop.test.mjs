// 桌面宿主附件适配器：假 transport（按帧驱动反向请求）+ 假 fileUploads / 图片校验服务，
// 不建 HTTP 监听、不落宿主附件文件。契约见 p5-remaining-design.md §3.4.2。
import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { test } from 'node:test'
import { DesktopAppAttachments } from '../runtime/attachments-desktop.mjs'

const SESSION = 'session-1'
const PAGE = 256 * 1024
const READ_METHOD = 'native.attachments.read'

function deferred() {
  return Promise.withResolvers()
}

/** 让已排队的微任务/一次 I/O 轮转跑完，用于断言「之后没有新的反向请求」。 */
function tick() {
  return new Promise(resolve => setImmediate(resolve))
}

async function waitFor(predicate, label = 'condition') {
  for (let attempt = 0; attempt < 500; attempt++) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 1))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

/** 门面传输看到的手机 JSON-RPC 错误（`-32601` / `-32603`）。 */
function rpcFailure(code, data, message = '手机拒绝了附件读取。') {
  return Object.assign(new Error(message), { code, data })
}

/** 协议 §5.3 风格的 `-32603` + `data.code`。 */
function appFailure(code, message = '手机拒绝了附件读取。') {
  return rpcFailure(-32603, { code }, message)
}

/** 手机按页应答一份私有副本；`pageBytes` 用来制造短读。 */
function serveBytes(bytes, { pageBytes = PAGE, size = bytes.length, eof, nextOffset } = {}) {
  return params => {
    const take = Math.min(params.length, pageBytes, Math.max(0, size - params.offset))
    const data = bytes.subarray(params.offset, params.offset + take)
    const advanced = params.offset + data.length
    return {
      data: data.toString('base64'),
      nextOffset: nextOffset === undefined ? advanced : nextOffset(params.offset, data.length),
      size,
      eof: eof === undefined ? advanced === size : eof,
    }
  }
}

function fileMeta(id, bytes, overrides = {}) {
  return { sessionId: SESSION, id, name: '测试.txt', mediaType: 'text/plain', bytes: bytes.length, ...overrides }
}

function imageMeta(id, bytes, overrides = {}) {
  return { sessionId: SESSION, id, name: '图片.png', mediaType: 'image/png', bytes: bytes.length, ...overrides }
}

/**
 * 模拟真实链路对「流式生成器失败」的两层包装：
 * - `attachment-local` 的 `stageImmutableObject` 把非 `AttachmentError` 的迭代器错误包成
 *   `ATTACHMENT_WRITE_FAILED`（信号已中止时原样重抛）；
 * - `file-upload` 的 `store()` 再把 `AttachmentError` 映射成 `session/attachment-invalid`
 *   （只保留 reason、丢掉 cause），其它普通错误映射成 `gateway/internal`。
 */
function wrappedStreamingFailure(error, { aborted }) {
  if (aborted) {
    return Object.assign(new Error(`failed to store file upload: ${String(error)}`), { code: 'gateway/internal' })
  }
  const attachmentError = Object.assign(new Error('Unable to persist attachment.'), {
    code: 'ATTACHMENT_WRITE_FAILED',
    cause: error,
  })
  return Object.assign(new Error(attachmentError.message), {
    code: 'session/attachment-invalid',
    details: { reason: attachmentError.code },
  })
}

/**
 * 假宿主：`request` 记录每一次反向请求并交给当前 responder；`fileUploads` 完整消费
 * `uploadStream` 的异步字节流并按真实服务形状返回收据。
 */
function createHost(options = {}) {
  const state = {
    reads: [],
    uploads: [],
    validations: [],
    responder: undefined,
  }
  const agents = new Map()
  const staged = new Map()

  const fileUploads = {
    async uploadStream(request) {
      const entry = { sessionId: request.sessionId, name: request.name, chunks: [], aborted: false }
      state.uploads.push(entry)
      const onAbort = () => { entry.aborted = true }
      request.signal?.addEventListener('abort', onAbort, { once: true })
      const hash = createHash('sha256')
      let bytes = 0
      try {
        for await (const chunk of request.data) {
          const copy = Buffer.from(chunk)
          entry.chunks.push(copy)
          hash.update(copy)
          bytes += copy.length
        }
      } catch (error) {
        entry.failure = error
        if (options.wrapStreamingFailures === true) {
          throw wrappedStreamingFailure(error, { aborted: request.signal?.aborted === true })
        }
        throw error
      } finally {
        request.signal?.removeEventListener('abort', onAbort)
      }
      const file = { attachmentId: `sha256:${hash.digest('hex')}`, name: request.name, bytes }
      const receiptId = `receipt-${state.uploads.length}`
      const owner = agents.get(request.sessionId)
      let receipts = staged.get(owner)
      if (receipts === undefined) {
        receipts = new Map()
        staged.set(owner, receipts)
      }
      receipts.set(receiptId, { type: 'file', attachment: file })
      Object.assign(entry, { file, receiptId })
      return { receiptId, file }
    },
    resolve(agent, receiptId) {
      return staged.get(agent)?.get(receiptId)
    },
  }

  const imageStore = {
    imageLimits: {
      maxImageBytes: options.maxImageBytes ?? 20 * 1024 * 1024,
      maxImagesPerMessage: options.maxImagesPerMessage ?? 20,
      maxMessageImageBytes: options.maxMessageImageBytes ?? 200 * 1024 * 1024,
      mediaTypes: options.imageTypes ?? ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
    },
    async validateImage(input) {
      state.validations.push(input)
      return options.validateImage?.(input)
    },
  }

  const ctx = {
    agents: { get: id => agents.get(id) },
    fileUploads,
    attachments: imageStore,
  }
  const ensureSession = async sessionId => {
    if (!agents.has(sessionId)) agents.set(sessionId, { id: sessionId, session: { header: {} } })
  }
  const request = (method, params) => {
    state.reads.push({ method, params })
    if (state.responder === undefined) return Promise.reject(new Error('unexpected reverse request'))
    return Promise.resolve().then(() => state.responder(params))
  }
  const bridge = new DesktopAppAttachments(ctx, {
    request,
    ensureSession,
    limits: () => ({ maxFileBytes: options.maxFileBytes ?? 256 * 1024 * 1024 }),
  })
  return { bridge, state, agents, fileUploads, imageStore, ensureSession }
}

async function fixture(run, options = {}) {
  const host = createHost(options)
  try {
    await run(host)
  } finally {
    await host.bridge.close()
  }
}

test('file: one page becomes a DSH receipt; content reuses it without phone traffic', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('中文🙂\nattachment\u0000bytes')
    state.responder = serveBytes(bytes)
    const receipt = await bridge.prepare(fileMeta(id, bytes))
    assert.equal(receipt.id, id)
    assert.equal(receipt.kind, 'file')
    assert.equal(receipt.name, '测试.txt')
    assert.equal(receipt.bytes, bytes.length)
    assert.equal(receipt.file.attachmentId, `sha256:${createHash('sha256').update(bytes).digest('hex')}`)
    assert.equal(receipt.receiptId, 'receipt-1')
    assert.deepEqual(state.reads, [{ method: READ_METHOD, params: { id, offset: 0, length: PAGE } }])
    assert.equal(state.uploads.length, 1)
    assert.deepEqual(Buffer.concat(state.uploads[0].chunks), bytes)
    assert.equal(state.uploads[0].sessionId, SESSION)
    assert.equal(state.uploads[0].name, '测试.txt')

    const parts = await bridge.content(SESSION, [id])
    assert.deepEqual(parts, [{ type: 'file', receiptId: 'receipt-1' }])
    assert.deepEqual(await bridge.commandContent(SESSION, [id]), parts)
    assert.equal(state.reads.length, 1, 'sending a prepared file does not read the phone again')

    assert.deepEqual(await bridge.release({ sessionId: SESSION, id }), { released: true })
    assert.deepEqual(await bridge.release({ sessionId: SESSION, id }), { released: true })
    await assert.rejects(bridge.content(SESSION, [id]), /未就绪/)
    assert.equal(state.reads.length, 1, 'release never reads the phone')
    assert.ok(state.reads.every(read => read.method === READ_METHOD), 'no reverse request besides the attachment read')
    assert.ok(state.reads.every(read => Object.keys(read.params).sort().join()
      === 'id,length,offset'), 'page requests carry only the private draft identity and window')
  })
})

test('file: short reads advance by nextOffset across multiple pages', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.alloc(650000)
    for (let index = 0; index < bytes.length; index++) bytes[index] = index % 251
    state.responder = serveBytes(bytes, { pageBytes: 100000 })
    const receipt = await bridge.prepare(fileMeta(id, bytes))
    assert.equal(receipt.file.bytes, bytes.length)
    assert.equal(state.uploads.length, 1)
    assert.deepEqual(Buffer.concat(state.uploads[0].chunks), bytes)
    assert.ok(state.reads.length > 1)
    let expectedOffset = 0
    for (const read of state.reads) {
      assert.equal(read.params.offset, expectedOffset)
      assert.equal(read.params.length, PAGE)
      expectedOffset += 100000
    }
  })
})

test('file: declaration, page-size and eof reconciliation fail as attachment-file/changed', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.alloc(1000, 7)
    // 声明大小与手机权威 size 不符。
    let id = randomUUID()
    state.responder = serveBytes(bytes, { size: 900 })
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)), { code: 'attachment-file/changed' })
    assert.ok(state.uploads.every(entry => entry.file === undefined), 'a changed file never yields a receipt')

    // 中页 size 变化。
    id = randomUUID()
    state.responder = params => {
      const first = params.offset === 0
      const length = first ? 100 : 100
      const data = bytes.subarray(params.offset, params.offset + length)
      return { data: data.toString('base64'), nextOffset: params.offset + data.length,
        size: first ? 1000 : 950, eof: false }
    }
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)), { code: 'attachment-file/changed' })

    // eof 时 nextOffset 不等于 size：应答自相矛盾。
    id = randomUUID()
    state.responder = () => ({ data: bytes.subarray(0, 900).toString('base64'),
      nextOffset: 900, size: 1000, eof: true })
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)), { code: 'attachment-file/unavailable' })
  })
})

test('file: malformed pages are refused instead of silently truncated', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.alloc(64, 1)
    const cases = [
      () => ({ data: '!!!!', nextOffset: 3, size: 64, eof: false }),
      () => ({ data: bytes.toString('base64'), nextOffset: 5, size: 64, eof: false }),
      () => ({ data: '', nextOffset: 0, size: 64, eof: false }),
      () => ({ data: bytes.toString('base64'), nextOffset: 64, size: 64, eof: 'no' }),
      () => null,
    ]
    for (const responder of cases) {
      state.responder = responder
      await assert.rejects(bridge.prepare(fileMeta(randomUUID(), bytes)),
        { code: 'attachment-file/unavailable' })
    }
    assert.ok(state.uploads.every(entry => entry.file === undefined), 'malformed pages never become receipts')
  })
})

test('-32601 from an old App maps to attachment-file/unsupported', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.from('old app')
    const id = randomUUID()
    state.responder = () => { throw rpcFailure(-32601, { code: 'unsupported-method', method: READ_METHOD }) }
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)), {
      code: 'attachment-file/unsupported',
      message: /不支持上传附件/,
    })
    // 协议附录 B 期望的「带 data.code 的 Error」形状同样识别。
    state.responder = () => { throw Object.assign(new Error('unsupported'), { code: 'unsupported-method' }) }
    await assert.rejects(bridge.prepare(fileMeta(randomUUID(), bytes)),
      { code: 'attachment-file/unsupported' })
    assert.equal(state.reads.length, 2)
  })
})

test('App structured errors are preserved; unknown failures are not misclassified', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.from('gone')
    for (const code of ['attachment-file/not-found', 'attachment-file/cancelled', 'attachment-file/invalid-request']) {
      state.responder = () => { throw appFailure(code) }
      await assert.rejects(bridge.prepare(fileMeta(randomUUID(), bytes)), { code })
    }
    state.responder = () => { throw appFailure('attachment-file/corrupt') }
    await assert.rejects(bridge.prepare(fileMeta(randomUUID(), bytes)),
      { code: 'attachment-file/unavailable' })
  })
})

test('connection loss surfaces as gateway/cancelled instead of a silent hang', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.from('payload')
    state.responder = () => { throw new Error('JSON-RPC transport closed') }
    const pending = bridge.prepare(fileMeta(randomUUID(), bytes))
    await assert.rejects(pending, { code: 'gateway/cancelled', message: /连接已断开/ })
  })
})

test('detaching the connection aborts an in-flight pull and stops further pages', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.alloc(PAGE * 2, 3)
    const gate = deferred()
    state.responder = () => gate.promise
    const pending = bridge.prepare(fileMeta(id, bytes))
    const failed = assert.rejects(pending, { code: 'gateway/cancelled', message: /连接已断开/ })
    await waitFor(() => state.reads.length === 1, 'first page request')
    bridge.detachAll()
    await failed
    await tick()
    assert.equal(state.reads.length, 1, 'no page is requested after detach')
    assert.equal(state.uploads.length, 1)
    assert.equal(state.uploads[0].aborted, true)
  })
})

test('release during a pending pull fails preparation, sends no further pages and is idempotent', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.alloc(PAGE * 2, 4)
    const gate = deferred()
    state.responder = () => gate.promise
    const pending = bridge.prepare(fileMeta(id, bytes))
    const failed = assert.rejects(pending, { code: 'gateway/cancelled', message: /附件草稿已移除/ })
    await waitFor(() => state.reads.length === 1, 'first page request')
    assert.deepEqual(await bridge.release({ sessionId: SESSION, id }), { released: true })
    await failed
    await tick()
    assert.equal(state.reads.length, 1, 'release interrupts the paging loop')
    await assert.rejects(bridge.content(SESSION, [id]), /未就绪/)
  })
})

test('close aborts in-flight pulls, is idempotent and leaves no usable service', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    state.responder = () => deferred().promise
    const pending = bridge.prepare(fileMeta(id, Buffer.alloc(32)))
    const failed = assert.rejects(pending, { code: 'gateway/cancelled', message: /附件服务已停止/ })
    await waitFor(() => state.reads.length === 1, 'first page request')
    await bridge.close()
    await bridge.close()
    await failed
    assert.equal(state.reads.length, 1)
    assert.throws(() => bridge.prepare(fileMeta(id, Buffer.alloc(32))), /closed/)
    await assert.rejects(bridge.content(SESSION, [id]), /closed/)
    assert.equal((await bridge.release({ sessionId: SESSION, id })).released, true)
  })
})

test('images are read whole, validated once, then re-pulled with a digest check', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const data = Buffer.from('pretend-png-bytes')
    state.responder = serveBytes(data)
    const prepared = await bridge.prepare(imageMeta(id, data))
    assert.deepEqual(prepared, { id, kind: 'image', name: '图片.png', mediaType: 'image/png', bytes: data.length })
    assert.equal(state.uploads.length, 0, 'an image never falls back to a generic file receipt')
    assert.equal(state.validations.length, 1)
    assert.deepEqual(state.validations[0], { data, mediaType: 'image/png', name: '图片.png' })

    const before = state.reads.length
    assert.deepEqual(await bridge.content(SESSION, [id]), [{
      type: 'image', mediaType: 'image/png', name: '图片.png', data: data.toString('base64'),
    }])
    assert.equal(state.reads.length, before + 1, 'content re-reads the original image once')
    assert.equal(state.validations.length, 1, 'content does not re-run DSH image validation')

    assert.deepEqual(await bridge.preview({ sessionId: SESSION, id }), {
      id, kind: 'image', name: '图片.png', mediaType: 'image/png', bytes: data.length,
      data: data.toString('base64'),
    })
    assert.deepEqual(await bridge.commandContent(SESSION, [id]), await bridge.content(SESSION, [id]))
  })
})

test('image limits reject unsupported or oversized declarations before any pull', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const data = Buffer.alloc(16, 9)
    for (const [metadata, code] of [
      [imageMeta(id, data, { mediaType: 'image/heic' }), 'UNSUPPORTED_IMAGE_TYPE'],
      [imageMeta(id, data, { bytes: 17 }), 'IMAGE_TOO_LARGE'],
    ]) {
      await assert.rejects(bridge.prepare(metadata), { code })
      assert.equal(state.reads.length, 0)
      assert.equal(state.validations.length, 0)
    }
  }, { maxImageBytes: 16 })
})

test('DSH image validation failure keeps the draft unsendable', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    state.responder = serveBytes(Buffer.from('not an image'))
    await assert.rejects(bridge.prepare(imageMeta(id, Buffer.from('not an image'))), { code: 'INVALID_IMAGE' })
    assert.equal(state.uploads.length, 0)
    await assert.rejects(bridge.content(SESSION, [id]), /未就绪/)
    await assert.rejects(bridge.preview({ sessionId: SESSION, id }), /未就绪/)
  }, {
    validateImage: async () => { throw Object.assign(new Error('Invalid image'), { code: 'INVALID_IMAGE' }) },
  })
})

test('remote preview is capped at 8 MiB without blocking preparation', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const data = Buffer.from('small-image')
    state.responder = serveBytes(data)
    await bridge.prepare(imageMeta(id, data))
    // 与本地实现同一取巧点：只验证上限判定，不分配 9 MiB 夹具。
    bridge.records.get(id).item.bytes = 9 * 1024 * 1024
    state.responder = () => assert.fail('oversized remote preview reached the phone')
    await assert.rejects(bridge.preview({ sessionId: SESSION, id }), { code: 'IMAGE_PREVIEW_TOO_LARGE' })
  }, { maxImageBytes: 40 * 1024 * 1024, maxMessageImageBytes: 80 * 1024 * 1024 })
})

test('a changed image on the second pull fails the send as attachment-file/changed', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const original = Buffer.from('original-image')
    const changed = Buffer.from('changed!-image')
    assert.equal(original.length, changed.length)
    state.responder = serveBytes(original)
    await bridge.prepare(imageMeta(id, original))
    state.responder = serveBytes(changed)
    await assert.rejects(bridge.content(SESSION, [id]), { code: 'attachment-file/changed' })
    await assert.rejects(bridge.content(SESSION, [id]), /未就绪/)
    state.responder = serveBytes(original)
    const retried = await bridge.prepare(imageMeta(id, original))
    assert.equal(retried.kind, 'image')
    assert.equal((await bridge.content(SESSION, [id]))[0].data, original.toString('base64'))
  })
})

test('mixed file and image content keeps order and each original wire shape', async () => {
  await fixture(async ({ bridge, state }) => {
    const fileId = randomUUID()
    const fileBytes = Buffer.from('document')
    const imageId = randomUUID()
    const imageBytes = Buffer.from('picture')
    state.responder = params => params.id === fileId
      ? serveBytes(fileBytes)(params) : serveBytes(imageBytes)(params)
    const file = await bridge.prepare(fileMeta(fileId, fileBytes))
    await bridge.prepare(imageMeta(imageId, imageBytes))
    const parts = await bridge.content(SESSION, [fileId, imageId, fileId])
    assert.deepEqual(parts.map(part => part.type), ['file', 'image', 'file'])
    assert.equal(parts[0].receiptId, file.receiptId)
    assert.equal(parts[2].receiptId, file.receiptId)
    assert.equal(parts[1].data, imageBytes.toString('base64'))
    assert.deepEqual(await bridge.commandContent(SESSION, [fileId, imageId, fileId]), parts)
  })
})

test('the host file-size limit and request parameters are enforced without phone traffic', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    await assert.rejects(bridge.prepare(fileMeta(id, Buffer.alloc(101), { bytes: 101 })),
      { code: 'gateway/bad-request', message: /大小上限/ })
    assert.equal(state.reads.length, 0)
    assert.equal(state.uploads.length, 0)
    const bytes = Buffer.from('x')
    assert.throws(() => bridge.prepare(fileMeta(id, bytes, { sessionId: '' })), /Session/)
    assert.throws(() => bridge.prepare(fileMeta(id, bytes, { name: '' })), /name/)
    assert.throws(() => bridge.prepare(fileMeta(id, bytes, { mediaType: '' })), /media type/)
    assert.throws(() => bridge.prepare(fileMeta(id, bytes, { bytes: -1 })), /size/)
    assert.throws(() => bridge.prepare(fileMeta(id, bytes, { bytes: 1.5 })), /size/)
    assert.throws(() => bridge.prepare({ sessionId: SESSION, id }), /name/)
    assert.equal(state.reads.length, 0)
  }, { maxFileBytes: 100 })
})

test('only uuid draft identities and safe display names are accepted', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.from('x')
    for (const id of ['content://provider/private', '../foreign', '/private/key', 'not-a-uuid',
      '......................................']) {
      assert.throws(() => bridge.prepare(fileMeta(id, bytes)), /identity/)
      await assert.rejects(bridge.release({ sessionId: SESSION, id }), /identity/)
    }
    const id = randomUUID()
    for (const name of ['', '.', '..', 'dir/name.txt', 'back\\slash', 'control\u0001name', 'a'.repeat(256)]) {
      assert.throws(() => bridge.prepare(fileMeta(id, bytes, { name })), /name/)
    }
    assert.equal(state.reads.length, 0)
  })
})

test('draft ownership, retired receipts and explicit retries follow the local semantics', async () => {
  await fixture(async ({ bridge, state, agents }) => {
    const id = randomUUID()
    const bytes = Buffer.from('retry-me')
    state.responder = serveBytes(bytes)
    const first = await bridge.prepare(fileMeta(id, bytes))
    assert.throws(() => bridge.prepare(fileMeta(id, bytes, { sessionId: 'session-2' })), /another conversation/)
    await assert.rejects(bridge.content('session-2', [id]), /未就绪/)
    await assert.rejects(bridge.preview({ sessionId: 'session-2', id }), /未就绪/)
    await assert.rejects(bridge.release({ sessionId: 'session-2', id }), /another conversation/)
    // 会话被重新激活：旧收据失效，重试会重新拉取并生成新收据。
    agents.set(SESSION, { id: SESSION, session: { header: {} } })
    await assert.rejects(bridge.content(SESSION, [id]), /凭据已失效/)
    const second = await bridge.prepare(fileMeta(id, bytes))
    assert.notEqual(second.receiptId, first.receiptId)
    assert.deepEqual(second.file, first.file)
    assert.equal(state.reads.length, 2)
  })
})

test('concurrent preparation deduplicates one file upload', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('single-upload')
    const gate = deferred()
    state.responder = () => gate.promise
    const one = bridge.prepare(fileMeta(id, bytes))
    const two = bridge.prepare(fileMeta(id, bytes))
    assert.equal(one, two)
    gate.resolve(serveBytes(bytes)({ id, offset: 0, length: PAGE }))
    const receipt = await one
    assert.equal(receipt.receiptId, 'receipt-1')
    assert.equal(state.uploads.length, 1)
    assert.equal(state.reads.length, 1)
  })
})

test('concurrent image preparation validates once and stores no binary payload', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('image-once')
    const gate = deferred()
    state.responder = () => gate.promise
    const one = bridge.prepare(imageMeta(id, bytes))
    const two = bridge.prepare(imageMeta(id, bytes))
    assert.equal(one, two)
    gate.resolve(serveBytes(bytes)({ id, offset: 0, length: PAGE }))
    await one
    assert.equal(state.validations.length, 1)
    assert.equal(state.uploads.length, 0)
    assert.equal(Object.values(bridge.records.get(id))
      .some(value => Buffer.isBuffer(value)), false)
  })
})

test('detach keeps an already prepared draft usable for the next connection', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('survives-detach')
    state.responder = serveBytes(bytes)
    const receipt = await bridge.prepare(fileMeta(id, bytes))
    bridge.detachAll()
    assert.deepEqual(await bridge.content(SESSION, [id]), [{ type: 'file', receiptId: receipt.receiptId }])
    assert.equal((await bridge.prepare(fileMeta(id, bytes))).receiptId, receipt.receiptId)
    assert.equal(state.reads.length, 1)
  })
})

test('release during an in-flight image content read aborts it quietly', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('prepared-image')
    state.responder = serveBytes(bytes)
    await bridge.prepare(imageMeta(id, bytes))
    const gate = deferred()
    state.responder = () => gate.promise
    const before = state.reads.length
    const content = bridge.content(SESSION, [id])
    const failed = assert.rejects(content, { code: 'gateway/cancelled', message: /附件草稿已移除/ })
    await waitFor(() => state.reads.length === before + 1, 'content re-read request')
    assert.deepEqual(await bridge.release({ sessionId: SESSION, id }), { released: true })
    await failed
    await tick()
    assert.equal(state.reads.length, before + 1)
    assert.equal((await bridge.release({ sessionId: SESSION, id })).released, true)
  })
})

test('an empty selected file produces an empty receipt without extra pages', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    state.responder = serveBytes(Buffer.alloc(0))
    const receipt = await bridge.prepare(fileMeta(id, Buffer.alloc(0)))
    assert.equal(receipt.file.bytes, 0)
    assert.equal(receipt.receiptId, 'receipt-1')
    assert.equal(state.uploads[0].chunks.length, 0)
    assert.deepEqual(state.reads, [{ method: READ_METHOD, params: { id, offset: 0, length: PAGE } }])
    assert.deepEqual(await bridge.content(SESSION, [id]), [{ type: 'file', receiptId: 'receipt-1' }])
  })
})

test('preview refuses regular files without requesting the phone', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('plain')
    state.responder = serveBytes(bytes)
    await bridge.prepare(fileMeta(id, bytes))
    const before = state.reads.length
    await assert.rejects(bridge.preview({ sessionId: SESSION, id }), /Only prepared image/)
    assert.equal(state.reads.length, before)
  })
})

test('base64 page boundaries near 1 MiB and download frame limits are accepted', async () => {
  await fixture(async ({ bridge, state }) => {
    // 一页 256 KiB 原始字节 → base64 349 528 字节，仍远低于 1 MiB 上行帧；短读尾页照常推进。
    const id = randomUUID()
    const bytes = Buffer.alloc(PAGE + 17, 5)
    state.responder = serveBytes(bytes, { pageBytes: PAGE })
    const receipt = await bridge.prepare(fileMeta(id, bytes))
    assert.equal(receipt.file.bytes, bytes.length)
    assert.equal(state.reads.length, 2)
    assert.deepEqual(state.reads.map(read => read.params.offset), [0, PAGE])
    assert.deepEqual(Buffer.concat(state.uploads[0].chunks), bytes)
  })
})

test('the draft record never stores attachment bytes, only digests and receipts', async () => {
  await fixture(async ({ bridge, state }) => {
    const fileId = randomUUID()
    const fileBytes = Buffer.from('private-file-bytes')
    state.responder = serveBytes(fileBytes)
    await bridge.prepare(fileMeta(fileId, fileBytes))
    const imageId = randomUUID()
    const imageBytes = Buffer.from('private-image-bytes')
    state.responder = serveBytes(imageBytes)
    await bridge.prepare(imageMeta(imageId, imageBytes))
    for (const id of [fileId, imageId]) {
      const values = Object.values(bridge.records.get(id))
      assert.equal(values.some(value => Buffer.isBuffer(value)
        || (value !== null && typeof value === 'object' && Buffer.isBuffer(value?.data))), false)
    }
    assert.equal(typeof bridge.records.get(imageId).imageDigest, 'string')
    assert.equal(bridge.records.get(imageId).imageDigest.length, 64)
  })
})

test('an explicit retry after a mid-transfer failure re-reads from offset zero', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.alloc(1000, 11)
    let calls = 0
    state.responder = params => {
      calls++
      if (calls === 1) throw new Error('JSON-RPC transport closed')
      return serveBytes(bytes)(params)
    }
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)), { code: 'gateway/cancelled' })
    const receipt = await bridge.prepare(fileMeta(id, bytes))
    assert.equal(receipt.file.bytes, bytes.length)
    assert.equal(state.reads[1].params.offset, 0, 'retry starts from the first page')
    assert.equal(state.uploads.length, 2)
    assert.deepEqual(Buffer.concat(state.uploads[1].chunks), bytes)
  })
})

test('streamed failures keep their mapped code after attachment store wrapping', async () => {
  await fixture(async ({ bridge, state }) => {
    const bytes = Buffer.alloc(PAGE * 2, 6)
    const cases = [
      // 手机不认识这个草稿 id / 草稿已被移除。
      [() => { throw appFailure('attachment-file/not-found') },
        'attachment-file/not-found', /文件已不在手机上/],
      // 旧版 App 没有反向请求 handler。
      [() => { throw rpcFailure(-32601, { code: 'unsupported-method', method: READ_METHOD }) },
        'attachment-file/unsupported', /不支持上传附件/],
      // 分页期间连接断开。
      [() => { throw new Error('JSON-RPC transport closed') },
        'gateway/cancelled', /连接已断开/],
      // 流内字节数与 prepare 声明不符。
      [serveBytes(bytes, { size: bytes.length - 1 }),
        'attachment-file/changed', /已变化/],
    ]
    for (const [responder, code, message] of cases) {
      state.responder = responder
      await assert.rejects(bridge.prepare(fileMeta(randomUUID(), bytes)), { code, message })
    }
    assert.ok(state.uploads.every(entry => entry.file === undefined),
      'a wrapped streaming failure never yields a receipt')
    assert.ok(state.uploads.every(entry => entry.failure !== undefined),
      'the fake store saw the mapped failure before wrapping it')
  }, { wrapStreamingFailures: true })
})

test('detach during a wrapped stream still maps to gateway/cancelled', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const gate = deferred()
    state.responder = () => gate.promise
    const pending = bridge.prepare(fileMeta(id, Buffer.alloc(PAGE * 2)))
    const failed = assert.rejects(pending, { code: 'gateway/cancelled', message: /连接已断开/ })
    await waitFor(() => state.reads.length === 1, 'first page request')
    bridge.detachAll()
    await failed
    await tick()
    assert.equal(state.reads.length, 1, 'no page is requested after detach')
    assert.equal(state.uploads.length, 1)
    assert.equal(state.uploads[0].aborted, true)
  }, { wrapStreamingFailures: true })
})

test('release during a wrapped stream still maps to gateway/cancelled', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const gate = deferred()
    state.responder = () => gate.promise
    const pending = bridge.prepare(fileMeta(id, Buffer.alloc(PAGE * 2)))
    const failed = assert.rejects(pending, { code: 'gateway/cancelled', message: /附件草稿已移除/ })
    await waitFor(() => state.reads.length === 1, 'first page request')
    assert.deepEqual(await bridge.release({ sessionId: SESSION, id }), { released: true })
    await failed
    await tick()
    assert.equal(state.reads.length, 1, 'release interrupts the paging loop')
  }, { wrapStreamingFailures: true })
})

test('an abort landing between streamed pages is restored from the record signal', async () => {
  await fixture(async ({ bridge, state, fileUploads }) => {
    const id = randomUUID()
    const bytes = Buffer.alloc(PAGE * 2, 7)
    state.responder = serveBytes(bytes)
    let released
    fileUploads.uploadStream = async request => {
      // 让第一页真正进入 store，再在取下一页之前中止：真实 stageImmutableObject 会在
      // `for await` 推进前先检查 signal，抛出的不是生成器错误，而是记录的中止原因。
      const iterator = request.data[Symbol.asyncIterator]()
      await iterator.next()
      released = bridge.release({ sessionId: SESSION, id })
      await new Promise(resolve => setImmediate(resolve))
      throw wrappedStreamingFailure(request.signal.reason, { aborted: true })
    }
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)),
      { code: 'gateway/cancelled', message: /附件草稿已移除/ })
    assert.deepEqual(await released, { released: true })
    await assert.rejects(bridge.content(SESSION, [id]), /未就绪/)
  })
})

test('a wrapped-stream failure is cleared before an explicit retry uploads again', async () => {
  await fixture(async ({ bridge, state }) => {
    const id = randomUUID()
    const bytes = Buffer.from('retry-after-wrapped-failure')
    state.responder = () => { throw appFailure('attachment-file/not-found') }
    await assert.rejects(bridge.prepare(fileMeta(id, bytes)), { code: 'attachment-file/not-found' })
    assert.equal(state.uploads.length, 1)
    assert.equal(state.uploads[0].failure.code, 'attachment-file/not-found')
    state.responder = serveBytes(bytes)
    const receipt = await bridge.prepare(fileMeta(id, bytes))
    assert.equal(receipt.receiptId, 'receipt-2')
    assert.equal(receipt.file.bytes, bytes.length)
    assert.deepEqual(Buffer.concat(state.uploads[1].chunks), bytes)
    assert.equal((await bridge.content(SESSION, [id]))[0].receiptId, 'receipt-2')
  }, { wrapStreamingFailures: true })
})
