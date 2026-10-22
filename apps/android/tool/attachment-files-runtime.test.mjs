// Real original DSH attachment reader, including its EOF integrity check; no live Agent or HTTP.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { chmod, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join, dirname, basename } from 'node:path'
import { pathToFileURL } from 'node:url'
import { test } from 'node:test'
import { AppAttachmentFiles } from '../runtime/attachment-files.mjs'

const require = createRequire(new URL('../../../packages/api/session-controller/package.json', import.meta.url))
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')).href)
const { default: LocalAttachmentStore } = await import('../../../packages/attachment/attachment-local/lib/index.js')

function deferred() {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}
async function fixture(run, configured = {}) {
  const parent = tmpdir()
  const root = await mkdtemp(join(parent, 'pocket-file-read-test-'))
  const cache = join(root, 'cache', randomUUID())
  const ctx = new Context()
  const store = new LocalAttachmentStore(ctx, { dshHome: join(root, 'home') })
  const sessions = new Map(), queried = []
  const query = { readSession: async id => {
    queried.push(id)
    return { events: structuredClone(sessions.get(id) ?? []) }
  } }
  ctx.provide('sessionQuery', query)
  const limits = { maxBytes: 8 * 1024 * 1024, readPageBytes: 65536, maxRequests: 4, ...configured }
  const bridge = new AppAttachmentFiles(ctx, { directory: async () => cache, limits: () => limits })
  const owner = randomUUID()
  const add = async (data, name = '历史附件.txt', sessionId = 'cold-session') => {
    const attachment = await store.saveFile({ data: Buffer.from(data), name })
    const part = { type: 'file', attachment }
    sessions.set(sessionId, [...(sessions.get(sessionId) ?? []), { type: 'user/message', data: { content: [part] } }])
    return { id: randomUUID(), owner, sessionId, attachmentId: attachment.attachmentId, name: attachment.name }
  }
  try { await run({ root, cache, ctx, store, sessions, queried, query, limits, bridge, owner, add }) }
  finally {
    await bridge.close()
    await ctx.fiber.dispose()
    assert.equal(dirname(root), parent)
    assert.ok(basename(root).startsWith('pocket-file-read-test-'))
    await rm(root, { recursive: true, maxRetries: 3, retryDelay: 30 })
  }
}

test('cold history is read without activating an Agent; verified bytes and exact long Unicode filename survive', async () => {
  await fixture(async ({ bridge, add, cache, ctx, queried, sessions }) => {
    const bytes = Buffer.from('\ufeff历史🙂\nA😀Z\r\n')
    const request = await add(bytes, `${'名'.repeat(80)}.txt`)
    const history = structuredClone(sessions)
    const originalGet = ctx.get.bind(ctx)
    ctx.get = name => {
      assert.ok(['sessionQuery', 'attachments'].includes(name), `Unexpected runtime activation: ${name}`)
      return originalGet(name)
    }
    const first = bridge.prepare(request), duplicate = bridge.prepare(request)
    assert.equal(first, duplicate)
    assert.deepEqual(await first, { id: request.id, filename: request.name, size: bytes.length, previewKind: 'text' })
    assert.deepEqual(await readFile(join(cache, `${request.id}.file`)), bytes)
    assert.deepEqual(await readdir(cache), [`${request.id}.file`])
    assert.deepEqual(queried, [request.sessionId])
    assert.deepEqual(sessions, history, 'reading cannot rewrite history')
    ctx.get = originalGet
  })
})

test('UTF-8 pages use byte offsets, bounded memory and whole characters; empty file remains previewable', async () => {
  await fixture(async ({ bridge, add }) => {
    const original = '\ufeff中文🙂a😀Z\n结束'
    const request = await add(original)
    await bridge.prepare(request)
    let offset = 0, reconstructed = '', pages = 0
    do {
      const page = await bridge.read({ ...request, offset })
      assert.equal(page.offset, offset)
      assert.equal(page.eof, page.nextOffset === page.size)
      assert.ok(page.nextOffset - offset <= 5)
      assert.ok(page.nextOffset > offset)
      assert.ok(!page.text.includes('\ufffd'))
      reconstructed += page.text
      offset = page.nextOffset
      pages++
      if (page.eof) break
    } while (pages < 50)
    assert.equal(reconstructed, original.slice(1))
    assert.equal(offset, Buffer.byteLength(original))
    assert.deepEqual(await bridge.read({ ...request, offset }), { text: '', offset, nextOffset: offset, eof: true, size: offset })
    await assert.rejects(bridge.read({ ...request, offset: 1 }), /完整字符/)
    assert.throws(() => bridge.read({ ...request, offset: -1 }), /分页位置/)
    assert.throws(() => bridge.read({ ...request, offset: offset + 1 }), /分页位置/)
    const empty = await add('', 'empty.txt')
    assert.equal((await bridge.prepare(empty)).previewKind, 'text')
    assert.deepEqual(await bridge.read(empty), { text: '', offset: 0, nextOffset: 0, eof: true, size: 0 })
  }, { readPageBytes: 5 })
})

test('invalid UTF-8 and binary controls are never lossy text previews, but original bytes are saveable', async () => {
  await fixture(async ({ bridge, add, cache }) => {
    for (const bytes of [Buffer.from([0xc3, 0x28]), Buffer.from([0xf0, 0x9f]), Buffer.from('abc\0def'), Buffer.from([127])]) {
      const request = await add(bytes, 'binary.dat')
      assert.equal((await bridge.prepare(request)).previewKind, 'binary')
      assert.throws(() => bridge.read(request), /不是可预览/)
      assert.deepEqual(await readFile(join(cache, `${request.id}.file`)), bytes)
      await bridge.release(request)
    }
  })
})

test('only declared original content carriers grant a reference, never nested arbitrary payloads or deltas', async () => {
  await fixture(async ({ bridge, add, sessions }) => {
    const request = await add('carrier')
    const content = sessions.get(request.sessionId)[0].data.content
    const carriers = [
      ...['user/message', 'tool/ptc-dispatch'].map(type => ({ type, data: { content } })),
      ...['system/message', 'developer/message', 'tool/result', 'team/message/queued'].map(type => ({ type, data: { message: { content } } })),
      { type: 'agent/inbox/spliced', data: { inserted: [{ content }] } },
      { type: 'compaction/summary', data: { summary: content } },
      { type: 'compaction/summary', data: { rawOutput: content } },
      { type: 'assistant/message', data: { message: { content } } },
      ...['assistant/message', 'assistant/attempt'].map(type => ({ type,
        data: { stream: [{ type: 'chunk', chunk: { type: 'block-end', block: content[0] } }] } })),
    ]
    for (const event of carriers) {
      const next = { ...request, id: randomUUID() }
      sessions.set(request.sessionId, [event])
      assert.equal((await bridge.prepare(next)).previewKind, 'text')
      await bridge.release(next)
    }
    for (const event of [
      { type: 'unknown/payload', data: { content } },
      { type: 'user/message', data: { object: { content } } },
      { type: 'assistant/attempt', data: { stream: [{ type: 'chunk', chunk: { type: 'block-delta', block: content[0] } }] } },
      { type: 'assistant/attempt', data: { message: { content } } },
    ]) {
      const next = { ...request, id: randomUUID() }
      sessions.set(request.sessionId, [event])
      await assert.rejects(bridge.prepare(next), /没有引用/)
      await bridge.release(next)
    }
  })
})

test('same digest is not authorization for another filename or session; owner cannot be impersonated', async () => {
  await fixture(async ({ bridge, add, store }) => {
    const request = await add('same bytes', 'allowed.txt')
    await store.saveFile({ data: Buffer.from('same bytes'), name: 'other.txt' })
    for (const unauthorized of [{ name: 'other.txt' }, { sessionId: 'other-session' }, { attachmentId: `sha256:${'0'.repeat(64)}` }]) {
      const bad = { ...request, ...unauthorized, id: randomUUID() }
      await assert.rejects(bridge.prepare(bad), /没有引用/)
      await bridge.release(bad)
    }
    await bridge.prepare(request)
    const foreign = { ...request, owner: randomUUID() }
    assert.throws(() => bridge.info(foreign), /失效/)
    assert.throws(() => bridge.read(foreign), /失效/)
    assert.throws(() => bridge.cancel(foreign), /不属于/)
    assert.throws(() => bridge.prepare(foreign), /其他请求/)
    assert.equal(bridge.info(request).filename, request.name)
    assert.throws(() => bridge.prepare({ ...request, id: '../source' }), /标识无效/)
    assert.throws(() => bridge.prepare({ ...request, name: '../source' }), /文件名无效/)
  })
})

test('original EOF hash verification must finish before publication, including corruption after all chunks', async () => {
  await fixture(async ({ bridge, add, store, sessions, cache }) => {
    const request = await add(Buffer.alloc(200000, 65))
    const ref = sessions.get(request.sessionId)[0].data.content[0].attachment
    const source = store.fileHostPath(ref)
    await chmod(source, 0o600) // Deliberately corrupt this test-owned immutable store object.
    await writeFile(source, Buffer.alloc(200000, 66))
    await assert.rejects(bridge.prepare(request), /完整性校验失败/)
    assert.deepEqual(await readdir(cache), [], 'corrupt file never becomes a saveable completed file')
    assert.throws(() => bridge.info(request), /失效/)
    await bridge.release(request)
    assert.equal((await readFile(source)).length, 200000, 'consumer must not delete original source')
  })
})

test('fully received chunks are still private until source iterator has verified EOF', async () => {
  await fixture(async ({ bridge, add, store, cache }) => {
    const request = await add('all bytes received')
    const original = store.readFileStream.bind(store), reachedEnd = deferred(), finishCheck = deferred()
    store.readFileStream = async function* (...args) {
      yield* original(...args)
      reachedEnd.resolve()
      await finishCheck.promise
    }
    const preparing = bridge.prepare(request)
    await reachedEnd.promise
    assert.deepEqual(await readdir(cache), [`${request.id}.partial`])
    assert.throws(() => bridge.info(request), /失效/)
    finishCheck.resolve()
    await preparing
    assert.deepEqual(await readdir(cache), [`${request.id}.file`])
  })
})

test('cancel during cold query or after streamed bytes waits for quiescence and never publishes late', async () => {
  await fixture(async ({ bridge, add, query, store, cache }) => {
    const request = await add('cancel in query')
    const oldRead = query.readSession, queryStarted = deferred(), allowQuery = deferred()
    query.readSession = async id => { queryStarted.resolve(); await allowQuery.promise; return oldRead(id) }
    const prepared = bridge.prepare(request)
    const failure = assert.rejects(prepared, /取消/)
    await queryStarted.promise
    let cancelled = false
    const cancellation = bridge.cancel(request).then(() => { cancelled = true })
    await Promise.resolve()
    assert.equal(cancelled, false)
    allowQuery.resolve()
    await Promise.all([failure, cancellation])
    assert.throws(() => bridge.prepare(request), /已取消/)
    query.readSession = oldRead

    const next = await add('cancel in stream')
    const original = store.readFileStream.bind(store), yielded = deferred(), proceed = deferred()
    store.readFileStream = async function* (...args) { yield* original(...args); yielded.resolve(); await proceed.promise }
    const pending = bridge.prepare(next)
    const pendingFailure = assert.rejects(pending, /取消/)
    await yielded.promise
    const cancelledStream = bridge.cancel(next)
    proceed.resolve()
    await Promise.all([pendingFailure, cancelledStream])
    assert.deepEqual(await readdir(cache), [])
  })
})

test('cancel before prepare retires that ID; disconnect clears only that owner and blocks stale requests', async () => {
  await fixture(async ({ bridge, add, cache }) => {
    const retired = await add('retired')
    await bridge.cancel(retired)
    assert.throws(() => bridge.prepare(retired), /已取消/)
    const one = await add('owner one'), two = { ...await add('owner two'), owner: randomUUID() }
    await Promise.all([bridge.prepare(one), bridge.prepare(two)])
    await bridge.closeOwner(one.owner)
    assert.deepEqual(await readdir(cache), [`${two.id}.file`])
    assert.throws(() => bridge.prepare({ ...one, id: randomUUID() }), /连接已变化/)
    assert.equal((await bridge.read(two)).text, 'owner two')
  })
})

test('release can retry cleanup failure but cannot reuse or read the cancelled record', async () => {
  await fixture(async ({ bridge, add, cache }) => {
    const request = await add('cleanup retry')
    await bridge.prepare(request)
    const original = bridge.cleanup.bind(bridge)
    let attempts = 0
    bridge.cleanup = async record => { if (attempts++ === 0) throw new Error('private unlink path'); return original(record) }
    await assert.rejects(bridge.release(request), /清理未完成/)
    assert.throws(() => bridge.read(request), /取消/)
    assert.throws(() => bridge.prepare(request), /正在关闭/)
    assert.deepEqual(await bridge.release(request), { released: true })
    assert.deepEqual(await readdir(cache), [])
  })
})

test('limits bound held copies and next page size without invalidating an already verified copy', async () => {
  await fixture(async ({ bridge, add, limits }) => {
    const request = await add('1234567890'.repeat(300))
    await bridge.prepare(request)
    const next = await add('second')
    assert.throws(() => bridge.prepare(next), /打开的附件过多/)
    limits.maxBytes = 1024
    limits.readPageBytes = 1024
    assert.equal((await bridge.read(request)).nextOffset, 1024)
    await bridge.release(request)
    const tooLarge = await add('large'.repeat(1000))
    await assert.rejects(bridge.prepare(tooLarge), /大小限制/)
    await bridge.release(tooLarge)
    assert.equal((await bridge.prepare(next)).size, 6)
  }, { maxRequests: 1 })
})

test('foreign file collisions are never overwritten or removed by failed cleanup', async () => {
  await fixture(async ({ bridge, add, cache }) => {
    const request = await add('collision')
    const initial = await add('create directory')
    await bridge.prepare(initial)
    await bridge.release(initial)
    for (const extension of ['partial', 'file']) {
      const colliding = { ...request, id: randomUUID() }
      const path = join(cache, `${colliding.id}.${extension}`)
      await writeFile(path, 'foreign immutable file')
      await assert.rejects(bridge.prepare(colliding), /读取未完成/)
      await bridge.release(colliding)
      assert.equal(await readFile(path, 'utf8'), 'foreign immutable file')
    }
  })
})

test('changed cache cannot be read even if it has the same byte length', async () => {
  await fixture(async ({ bridge, add, cache }) => {
    const request = await add('original')
    await bridge.prepare(request)
    await writeFile(join(cache, `${request.id}.file`), 'modified')
    assert.equal(bridge.info(request).attachmentId, request.attachmentId, 'native save receives original reference digest, never cache-derived hash')
    await assert.rejects(bridge.read(request), /副本已变化/)
  })
})
