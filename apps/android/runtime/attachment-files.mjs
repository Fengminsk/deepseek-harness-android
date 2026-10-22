import { constants } from 'node:fs'
import { mkdir, open, realpath, stat, unlink } from 'node:fs/promises'
import { basename, isAbsolute, join } from 'node:path'
import { publishImmutableFile } from './immutable-file-publisher.mjs'

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const digest = /^sha256:[a-f0-9]{64}$/
// eslint-disable-next-line no-control-regex -- Controls identify binary content; tabs and line endings remain text.
const binaryControls = /[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/
// eslint-disable-next-line no-control-regex -- A wire filename is a display leaf, never a host path.
const invalidName = /[\0-\x1f\x7f/\\]/

class AttachmentFileError extends Error {
  constructor(code, message) { super(message); this.code = `attachment-file/${code}` }
}
function refuse(code, message) { throw new AttachmentFileError(code, message) }
function identity(id) {
  if (typeof id !== 'string' || !uuid.test(id)) refuse('invalid-request', '附件读取标识无效，请重新打开附件。')
}
function ownerOf(owner) {
  if (typeof owner !== 'string' || !uuid.test(owner)) refuse('disconnected', '附件页面连接已变化，请重新打开。')
  return owner
}
function filename(name) {
  if (typeof name !== 'string' || !name.isWellFormed() || !name || name === '.' || name === '..'
    || Buffer.byteLength(name) > 255 || invalidName.test(name)) refuse('invalid-reference', '附件文件名无效。')
  return name
}
function version(info) { return `${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}:${info.ctimeMs}` }
function publicFailure(error) {
  if (error instanceof AttachmentFileError) return error
  const details = {
    ATTACHMENT_NOT_FOUND: ['not-found', '附件原文件已不存在，无法读取。'],
    ATTACHMENT_CORRUPT: ['corrupt', '附件完整性校验失败，未提供预览或保存副本。'],
    ENOSPC: ['storage-full', '手机存储空间不足，未生成附件副本。'],
  }[error?.code]
  return new AttachmentFileError(...(details ?? ['unavailable', '附件读取未完成，请重新打开后重试。']))
}

/** Only declared first-party content carriers authorize a file, as in the DSH archive reader. */
function contentsOf(event) {
  const data = event?.data
  if (!data || typeof data !== 'object') return []
  switch (event.type) {
    case 'user/message': case 'tool/ptc-dispatch': return [data.content]
    case 'system/message': case 'developer/message': case 'tool/result': case 'team/message/queued':
      return [data.message?.content]
    case 'agent/inbox/spliced': return Array.isArray(data.inserted) ? data.inserted.map(message => message?.content) : []
    case 'compaction/summary': return [data.summary, data.rawOutput]
    case 'assistant/message': case 'assistant/attempt': return [
      ...(event.type === 'assistant/message' ? [data.message?.content] : []),
      ...(Array.isArray(data.stream) ? data.stream.filter(record => record.type === 'chunk'
        && record.chunk?.type === 'block-end').map(record => [record.chunk.block]) : []),
    ]
    default: return []
  }
}

function referencedFile(events, attachmentId, name) {
  for (const event of events) for (const content of contentsOf(event)) {
    if (!Array.isArray(content)) continue
    for (const part of content) {
      if (part?.type === 'file' && part.attachment?.attachmentId === attachmentId && part.attachment.name === name) {
        const ref = part.attachment
        if (!Number.isSafeInteger(ref.bytes) || ref.bytes < 0) refuse('invalid-reference', '附件记录中的文件大小无效。')
        return ref
      }
    }
  }
  refuse('not-referenced', '当前会话没有引用这个文件附件。')
}

/**
 * Private verified copies of historical file references. Reading uses the original
 * logical session query and attachment store; it never activates or modifies a session.
 * The native Binder injects the owner, and only opaque operation ids select cache files.
 */
export class AppAttachmentFiles {
  constructor(ctx, { directory, limits }) {
    this.ctx = ctx
    this.directory = directory
    this.limits = limits
    this.records = new Map()
    this.retired = new Map()
    this.closedOwners = new Set()
    this.closed = false
  }

  checkOwner(owner) {
    ownerOf(owner)
    if (this.closed || this.closedOwners.has(owner)) refuse('disconnected', '附件页面连接已变化，请重新打开。')
  }

  budgets() {
    const limits = this.limits()
    if (!Number.isSafeInteger(limits.maxBytes) || limits.maxBytes < 1024 || limits.maxBytes > 2147483648
      || !Number.isSafeInteger(limits.readPageBytes) || limits.readPageBytes < 4 || limits.readPageBytes > 1048576
      || !Number.isSafeInteger(limits.maxRequests) || limits.maxRequests < 1 || limits.maxRequests > 16) {
      refuse('invalid-config', '附件读取限额配置无效，请检查高级设置。')
    }
    return limits
  }

  prepare({ id, sessionId, attachmentId, name, owner }) {
    identity(id)
    this.checkOwner(owner)
    filename(name)
    if (typeof sessionId !== 'string' || !sessionId || sessionId.length > 256 || !sessionId.isWellFormed()
      || typeof attachmentId !== 'string' || !digest.test(attachmentId)) refuse('invalid-reference', '附件引用无效。')
    const existing = this.records.get(id)
    if (existing) {
      if (existing.owner !== owner || existing.sessionId !== sessionId || existing.attachmentId !== attachmentId
        || existing.name !== name) refuse('conflict', '附件读取标识已用于其他请求。')
      if (existing.releasing || existing.lifetime.signal.aborted) refuse('cancelled', '附件正在关闭，请重新打开。')
      return existing.done
    }
    if (this.retired.get(owner)?.has(id)) refuse('cancelled', '附件读取已取消，请重新打开。')
    const budgets = this.budgets()
    if (this.records.size >= budgets.maxRequests) refuse('busy', '打开的附件过多，请先关闭其他附件页面。')
    const record = { id, sessionId, attachmentId, name, owner, maxBytes: budgets.maxBytes,
      lifetime: new AbortController(), state: 'preparing', reads: new Set() }
    this.records.set(id, record)
    record.done = this.write(record)
    return record.done
  }

  check(record) {
    record.lifetime.signal.throwIfAborted()
    this.checkOwner(record.owner)
  }

  async write(record) {
    try {
      const query = this.ctx.get('sessionQuery'), attachments = this.ctx.get('attachments')
      if (!query || !attachments) refuse('unavailable', '会话或附件服务尚未就绪，请稍后重试。')
      const source = await query.readSession(record.sessionId)
      this.check(record)
      const ref = referencedFile(source.events, record.attachmentId, record.name)
      if (ref.bytes > record.maxBytes) refuse('too-large', '附件超过当前查看与保存的大小限制，可在会话附件设置中调整。')
      const configured = await this.directory()
      if (typeof configured !== 'string' || !isAbsolute(configured)) refuse('unavailable', '手机附件缓存目录不可用。')
      await mkdir(configured, { recursive: true, mode: 0o700 })
      const directory = await realpath(configured)
      record.cacheInstance = basename(directory)
      identity(record.cacheInstance)
      this.check(record)
      record.partial = join(directory, `${record.id}.partial`)
      record.complete = join(directory, `${record.id}.file`)
      const target = await open(record.partial, 'wx', 0o600)
      record.partialOwned = true
      let bytes = 0, text = true
      const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })
      try {
        for await (const chunk of attachments.readFileStream(ref, record.lifetime.signal)) {
          this.check(record)
          bytes += chunk.byteLength
          if (bytes > ref.bytes || bytes > record.maxBytes) refuse('corrupt', '附件大小与会话记录不一致，未提供文件副本。')
          if (text) {
            try { if (binaryControls.test(decoder.decode(chunk, { stream: true }))) text = false }
            catch { text = false } // Non-UTF-8 bytes remain saveable as an intact binary file.
          }
          await target.writeFile(chunk)
        }
        this.check(record)
        if (bytes !== ref.bytes) refuse('corrupt', '附件大小与会话记录不一致，未提供文件副本。')
        if (text) {
          try { if (binaryControls.test(decoder.decode())) text = false }
          catch { text = false } // An incomplete final UTF-8 sequence is not a text preview.
        }
        await target.sync()
      } finally { await target.close() }
      this.check(record)
      // readFileStream verifies the original length and SHA256 only when its iterator completes.
      await publishImmutableFile(record.partial, record.complete)
      record.completeOwned = true
      await unlink(record.partial)
      record.partialOwned = false
      this.check(record)
      const info = await stat(record.complete)
      record.version = version(info)
      record.result = { id: record.id, filename: record.name, size: bytes, previewKind: text ? 'text' : 'binary' }
      record.state = 'ready'
      return record.result
    } catch (error) {
      record.state = 'failed'
      record.lifetime.abort(error)
      try { await this.cleanup(record) }
      catch { refuse('cleanup-failed', '附件副本清理未完成，请重试关闭附件。') }
      throw publicFailure(error)
    }
  }

  ready({ id, owner }) {
    identity(id)
    this.checkOwner(owner)
    const record = this.records.get(id)
    if (!record || record.owner !== owner || record.state !== 'ready' || record.releasing) {
      refuse('unavailable', '附件副本已失效，请重新打开。')
    }
    this.check(record)
    return record
  }

  /** Native Save As rechecks the current connection before accepting a cache id. */
  info(params) {
    const record = this.ready(params)
    // Keep the persisted reference digest, never adopt a hash from mutable cache bytes.
    return { ...record.result, attachmentId: record.attachmentId, cacheInstance: record.cacheInstance }
  }

  read(params) {
    const record = this.ready(params), offset = params.offset ?? 0
    if (record.result.previewKind !== 'text') refuse('not-text', '此附件不是可预览的 UTF-8 文本，可以保存文件后打开。')
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > record.result.size) refuse('invalid-page', '附件分页位置无效，请从头读取。')
    const budget = this.budgets().readPageBytes
    const operation = this.readPage(record, offset, budget)
    record.reads.add(operation)
    void operation.finally(() => record.reads.delete(operation)).catch(_error => { /* The original read reports its failure. */ })
    return operation
  }

  async readPage(record, offset, budget) {
    let handle
    try {
      this.check(record)
      handle = await open(record.complete, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
      const before = await handle.stat()
      if (!before.isFile() || version(before) !== record.version) refuse('changed', '附件副本已变化，请重新打开。')
      const data = Buffer.alloc(Math.min(budget + 3, before.size - offset))
      let length = 0
      while (length < data.length) {
        this.check(record)
        const read = await handle.read(data, length, data.length - length, offset + length)
        if (!read.bytesRead) break
        length += read.bytesRead
      }
      let end = Math.min(budget, length)
      if (offset + end < before.size) while (end > 0 && end < length && (data[end] & 0xc0) === 0x80) end--
      if (end === 0 && offset < before.size) refuse('changed', '未能读取下一段附件内容，请重新打开。')
      let text
      try { text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(data.subarray(0, end)) }
      catch { refuse('invalid-page', '附件分页位置不是完整字符的边界，请从头读取。') }
      if (binaryControls.test(text) || version(await handle.stat()) !== record.version) refuse('changed', '附件副本已变化，请重新打开。')
      this.check(record)
      return { text: offset === 0 && text.startsWith('\ufeff') ? text.slice(1) : text,
        offset, nextOffset: offset + end, eof: offset + end >= before.size, size: before.size }
    } catch (error) { throw publicFailure(error) }
    finally { if (handle) await handle.close() }
  }

  retire(owner, id) {
    let retired = this.retired.get(owner)
    if (!retired) { retired = new Set(); this.retired.set(owner, retired) }
    retired.add(id)
  }

  cancel({ id, owner }) {
    identity(id)
    ownerOf(owner)
    const record = this.records.get(id)
    if (record && record.owner !== owner) refuse('unavailable', '附件副本不属于当前页面连接。')
    if (!this.closed && !this.closedOwners.has(owner)) this.retire(owner, id)
    if (!record) return Promise.resolve({ released: true })
    if (record.releasing) return record.releasing
    record.lifetime.abort(new AttachmentFileError('cancelled', '附件读取已取消。'))
    const releasing = (async () => {
      await record.done.catch(_error => { /* prepare reports its own failure. */ })
      await Promise.allSettled([...record.reads])
      try { await this.cleanup(record) }
      catch { refuse('cleanup-failed', '附件副本清理未完成，请重试关闭附件。') }
      if (this.records.get(id) === record) this.records.delete(id)
      return { released: true }
    })().catch(error => {
      if (record.releasing === releasing) record.releasing = undefined
      throw error
    })
    record.releasing = releasing
    return record.releasing
  }

  release(params) { return this.cancel(params) }

  async cleanup(record) {
    for (const [file, owned] of [[record.partial, 'partialOwned'], [record.complete, 'completeOwned']]) {
      if (!record[owned]) continue
      try { await unlink(file); record[owned] = false }
      catch (error) { if (error.code !== 'ENOENT') throw error; record[owned] = false }
    }
  }

  async closeOwner(owner) {
    ownerOf(owner)
    this.closedOwners.add(owner)
    const results = await Promise.allSettled([...this.records.values()].filter(record => record.owner === owner)
      .map(record => this.cancel({ id: record.id, owner })))
    this.retired.delete(owner)
    const failure = results.find(result => result.status === 'rejected')
    if (failure) throw failure.reason
  }

  async close() {
    this.closed = true
    const owners = new Set([...this.records.values()].map(record => record.owner))
    const results = await Promise.allSettled([...owners].map(owner => this.closeOwner(owner)))
    const failure = results.find(result => result.status === 'rejected')
    if (failure) throw failure.reason
  }
}
