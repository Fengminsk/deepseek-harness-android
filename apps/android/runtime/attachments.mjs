import { constants } from 'node:fs'
import { open, realpath, unlink } from 'node:fs/promises'
import { dirname, isAbsolute, join } from 'node:path'

const attachmentId = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const imageTypes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])

function requireId(id) {
  if (typeof id !== 'string' || !attachmentId.test(id)) throw new TypeError('Invalid selected attachment identity')
}

/** Native-selected files enter the original Session-owned DSH upload receipt service. */
export class AppAttachments {
  constructor(ctx, { directory, ensureSession }) {
    this.ctx = ctx
    this.directory = directory
    this.ensureSession = ensureSession
    this.records = new Map()
    this.closed = false
  }

  async describe(id) {
    requireId(id)
    const configured = await this.directory()
    if (typeof configured !== 'string' || !isAbsolute(configured)) throw new Error('Native attachment cache unavailable')
    const root = await realpath(configured)
    const source = join(root, `${id}.bin`)
    const metadata = join(root, `${id}.json`)
    for (const path of [source, metadata]) {
      if (dirname(await realpath(path)) !== root) throw new Error('Selected attachment escaped its private cache')
    }
    const handle = await open(metadata, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    let item
    try {
      const info = await handle.stat()
      if (!info.isFile() || info.size > 16384) throw new Error('Invalid selected attachment metadata')
      item = JSON.parse(await handle.readFile('utf8'))
    } finally { await handle.close() }
    if (item.id !== id || typeof item.name !== 'string' || typeof item.mediaType !== 'string'
      || !Number.isSafeInteger(item.bytes) || item.bytes < 0) throw new Error('Invalid selected attachment metadata')
    return { source, metadata, item }
  }

  prepare({ sessionId, id }) {
    requireId(id)
    if (this.closed) throw new Error('Attachment service is closed')
    if (typeof sessionId !== 'string' || sessionId.length === 0) throw new TypeError('Attachment Session is required')
    let record = this.records.get(id)
    if (record && record.sessionId !== sessionId) throw new Error('Attachment draft belongs to another conversation')
    if (record?.releasing) throw new Error('Attachment is being removed')
    if (record?.state === 'preparing') return record.done
    if (record?.state === 'ready' && this.receiptValid(record)) return record.done
    if (!record) {
      record = { id, sessionId }
      this.records.set(id, record)
    }
    record.state = 'preparing'
    record.lifetime = new AbortController()
    record.done = this.upload(record)
    return record.done
  }

  async upload(record) {
    const signal = record.lifetime.signal
    try {
      const selected = await this.describe(record.id)
      Object.assign(record, selected)
      signal.throwIfAborted()
      if (imageTypes.has(selected.item.mediaType)) {
        const failure = new Error('当前 Android 运行时尚未提供原 DSH 图像校验能力。图片已保留，请移除后发送其他内容，或稍后重试。')
        failure.code = 'IMAGE_RUNTIME_UNAVAILABLE'
        throw failure
      }
      await this.ensureSession(record.sessionId)
      signal.throwIfAborted()
      const source = await open(selected.source, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
      try {
        const info = await source.stat()
        if (!info.isFile() || info.size !== selected.item.bytes) throw new Error('Selected file changed; select it again')
        record.receipt = await this.ctx.fileUploads.uploadStream({
          sessionId: record.sessionId,
          name: selected.item.name,
          data: source.createReadStream({ autoClose: false }),
          signal,
        })
      } finally { await source.close() }
      signal.throwIfAborted()
      record.state = 'ready'
      return { id: record.id, kind: 'file', name: record.receipt.file.name,
        bytes: record.receipt.file.bytes, ...record.receipt }
    } catch (failure) {
      record.state = 'error'
      const codes = []
      for (let cause = failure, depth = 0; cause && depth < 6; cause = cause.cause, depth++) {
        if (typeof cause.code === 'string' && /^[A-Z][A-Z_0-9]{0,63}$/.test(cause.code)) codes.push(cause.code)
        if (cause.cause === cause) break
      }
      // Log only stable error codes; selected names, content, paths and tokens stay private.
      if (codes.length) console.error(`Pocket attachment storage failure: ${codes.join(' > ')}`)
      throw failure
    }
  }

  receiptValid(record) {
    const agent = this.ctx.agents.get(record.sessionId)
    return agent !== undefined && record.receipt !== undefined
      && this.ctx.fileUploads.resolve(agent, record.receipt.receiptId) !== undefined
  }

  /** Called inside the ordinary send queue: no creation, no second upload, no synthetic path text. */
  content(sessionId, ids) {
    if (!Array.isArray(ids)) throw new TypeError('Attachment draft identities must be an array')
    return ids.map(id => {
      requireId(id)
      const record = this.records.get(id)
      if (!record || record.sessionId !== sessionId || record.state !== 'ready' || record.releasing) {
        throw new Error('附件未就绪，请在该会话中重试上传。')
      }
      if (!this.receiptValid(record)) {
        record.state = 'error'
        throw new Error('附件上传凭据已失效，文件仍保留，请重试上传后发送。')
      }
      return { type: 'file', receiptId: record.receipt.receiptId }
    })
  }

  /** DSH CommandSubmitAttachment file parts use the same Session-owned receipt wire shape. */
  commandContent(sessionId, ids) {
    return this.content(sessionId, ids)
  }

  async release({ sessionId, id }) {
    requireId(id)
    const record = this.records.get(id)
    if (record && record.sessionId !== sessionId) throw new Error('Attachment draft belongs to another conversation')
    if (record) {
      record.releasing = true
      record.lifetime.abort(new Error('Attachment draft removed'))
      await record.done.catch(_failure => { /* Upload failure remains visible in its original App request. */ })
    }
    // Also allows a newly picked draft to be removed before upload or after a service restart.
    let selected
    try { selected = record?.source ? record : await this.describe(id) }
    catch (failure) {
      if (failure.code !== 'ENOENT') throw failure
      this.records.delete(id)
      return { released: true }
    }
    for (const path of [selected.source, selected.metadata]) {
      try { await unlink(path) }
      catch (failure) { if (failure.code !== 'ENOENT') throw failure }
    }
    this.records.delete(id)
    return { released: true }
  }

  async close() {
    this.closed = true
    // Keep selected source caches for App drafts across a service restart; stop only active reads.
    await Promise.all([...this.records.values()].map(async record => {
      record.lifetime.abort(new Error('Attachment service stopped'))
      await record.done.catch(_failure => { /* Original upload request owns its error. */ })
    }))
    this.records.clear()
  }
}
