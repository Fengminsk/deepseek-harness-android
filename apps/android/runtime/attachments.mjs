import { constants } from 'node:fs'
import { createHash } from 'node:crypto'
import { open, realpath, unlink } from 'node:fs/promises'
import { dirname, isAbsolute, join } from 'node:path'

const attachmentId = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const imageTypes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
// The native frame cap is 32 MiB; leave room for base64 expansion and JSON metadata.
const maxPreviewBytes = 20 * 1024 * 1024

function imageError(code, message) {
  return Object.assign(new Error(message), { code })
}

/** Read only the verified length, even if the private source grows during a read. */
async function readExact(handle, bytes, signal) {
  signal?.throwIfAborted()
  const data = Buffer.alloc(bytes)
  let offset = 0
  while (offset < bytes) {
    signal?.throwIfAborted()
    const result = await handle.read(data, offset, Math.min(64 * 1024, bytes - offset), offset)
    if (result.bytesRead === 0) throw new Error('Selected file changed; select it again')
    offset += result.bytesRead
  }
  signal?.throwIfAborted()
  const extra = await handle.read(Buffer.alloc(1), 0, 1, bytes)
  if (extra.bytesRead !== 0 || (await handle.stat()).size !== bytes) {
    throw new Error('Selected file changed; select it again')
  }
  signal?.throwIfAborted()
  return data
}

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
    // Decode at most one selected image at a time; the original store owns its codec policy.
    this.imageWork = Promise.resolve()
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
      item = JSON.parse((await readExact(handle, info.size)).toString('utf8'))
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
      record = { id, sessionId, reads: new Set() }
      this.records.set(id, record)
    }
    record.lifetime?.abort(new Error('Attachment preparation replaced'))
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
      record.kind = selected.item.mediaType.startsWith('image/') ? 'image' : 'file'
      if (record.kind === 'image') {
        this.checkImage(selected.item)
        const imageStore = this.ctx.attachments
        const imagePolicy = imageStore.imageLimits
        await this.serializeImage(async () => {
          const data = await this.readImage(selected, signal)
          // Validation fully decodes the source but does not persist or normalize the App draft.
          await imageStore.validateImage({
            data, mediaType: selected.item.mediaType, name: selected.item.name,
          })
          signal.throwIfAborted()
          record.imageDigest = createHash('sha256').update(data).digest('hex')
          // Cordis wraps services on each lookup; the store's frozen policy object is stable.
          record.imagePolicy = imagePolicy
        })
        signal.throwIfAborted()
        await this.ensureSession(record.sessionId)
        signal.throwIfAborted()
        record.agent = this.ctx.agents.get(record.sessionId)
        if (!record.agent) throw new Error('Attachment Session is unavailable')
        if (this.ctx.attachments?.imageLimits !== imagePolicy) throw new Error('图片校验设置已变更，原图已保留，请重试。')
        record.state = 'ready'
        return { id: record.id, kind: 'image', name: selected.item.name,
          mediaType: selected.item.mediaType, bytes: selected.item.bytes }
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
    if (record.kind === 'image') return agent !== undefined && agent === record.agent
      && record.imageDigest !== undefined && this.ctx.attachments?.imageLimits === record.imagePolicy
    return agent !== undefined && record.receipt !== undefined
      && this.ctx.fileUploads.resolve(agent, record.receipt.receiptId) !== undefined
  }

  imageLimits() {
    const store = this.ctx.attachments
    const limits = store?.imageLimits
    if (typeof store?.validateImage !== 'function' || !limits
      || !['maxImageBytes', 'maxImagesPerMessage', 'maxMessageImageBytes'].every(
        key => Number.isSafeInteger(limits[key]) && limits[key] > 0,
      ) || !Array.isArray(limits.mediaTypes)) {
      throw imageError('IMAGE_RUNTIME_UNAVAILABLE', '图片校验服务暂不可用，原图已保留，请稍后重试。')
    }
    return limits
  }

  checkImage(item) {
    const limits = this.imageLimits()
    if (!imageTypes.has(item.mediaType) || !limits.mediaTypes.includes(item.mediaType)) {
      throw imageError('UNSUPPORTED_IMAGE_TYPE', '当前图片格式不受支持，请选择 PNG、JPEG、WebP 或 GIF。')
    }
    if (item.bytes > limits.maxImageBytes) {
      throw imageError('IMAGE_TOO_LARGE', '图片超过 DSH 配置的单张大小限制，原图已保留。')
    }
  }

  serializeImage(operation) {
    const work = this.imageWork.then(operation)
    this.imageWork = work.then(() => {}, () => {})
    return work
  }

  async readImage(selected, signal) {
    signal.throwIfAborted()
    this.checkImage(selected.item)
    const source = await open(selected.source, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
    try {
      const info = await source.stat()
      if (!info.isFile() || info.size !== selected.item.bytes) throw new Error('Selected file changed; select it again')
      return await readExact(source, info.size, signal)
    } finally { await source.close() }
  }

  readyRecords(sessionId, ids) {
    if (this.closed) throw new Error('Attachment service is closed')
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
      return { record, lifetime: record.lifetime }
    })
  }

  checkReady({ record, lifetime }) {
    lifetime.signal.throwIfAborted()
    if (this.closed || record.lifetime !== lifetime || this.records.get(record.id) !== record
      || record.state !== 'ready' || record.releasing) throw new Error('附件未就绪，请在该会话中重试上传。')
    if (!this.receiptValid(record)) {
      record.state = 'error'
      throw new Error('附件准备状态已失效，原文件仍保留，请重试后发送。')
    }
  }

  trackReads(records, work) {
    for (const { record } of records) record.reads.add(work)
    const finished = () => { for (const { record } of records) record.reads.delete(work) }
    void work.then(finished, finished)
    return work
  }

  async buildContent(records, { preview = false } = {}) {
    const images = records.filter(({ record }) => record.kind === 'image')
    if (images.length) {
      const limits = this.imageLimits()
      if (images.length > limits.maxImagesPerMessage) {
        throw imageError('TOO_MANY_IMAGES', '图片数量超过 DSH 配置的每条消息限制。')
      }
      let totalBytes = 0
      for (const { record } of images) {
        this.checkImage(record.item)
        // Subtract before adding so even inconsistent cache metadata cannot overflow a budget.
        if (record.item.bytes > limits.maxMessageImageBytes - totalBytes) {
          throw imageError('IMAGES_TOO_LARGE', '图片总大小超过 DSH 配置的每条消息限制。')
        }
        totalBytes += record.item.bytes
        if (preview && record.item.bytes > maxPreviewBytes) {
          throw imageError('IMAGE_PREVIEW_TOO_LARGE', '此图片超过 20 MiB 预览限制，仍可按 DSH 的发送限制发送。')
        }
      }
    }
    const content = []
    for (const snapshot of records) {
      const { record, lifetime } = snapshot
      this.checkReady(snapshot)
      if (record.kind === 'file') {
        content.push({ type: 'file', receiptId: record.receipt.receiptId })
        continue
      }
      try {
        content.push(await this.serializeImage(async () => {
          this.checkReady(snapshot)
          const selected = await this.describe(record.id)
          this.checkReady(snapshot)
          if (selected.source !== record.source || selected.metadata !== record.metadata
            || selected.item.bytes !== record.item.bytes || selected.item.name !== record.item.name
            || selected.item.mediaType !== record.item.mediaType) {
            throw new Error('Selected image changed; retry preparation before sending')
          }
          const data = await this.readImage(selected, lifetime.signal)
          if (createHash('sha256').update(data).digest('hex') !== record.imageDigest) {
            throw new Error('Selected image changed; retry preparation before sending')
          }
          this.checkReady(snapshot)
          return { type: 'image', mediaType: selected.item.mediaType,
            data: data.toString('base64'), name: selected.item.name }
        }))
      } catch (failure) {
        if (record.lifetime === lifetime) record.state = 'error'
        throw failure
      }
    }
    for (const snapshot of records) this.checkReady(snapshot)
    // The original session/command endpoint performs model checks and ONE ordered batch admission.
    // Keep base64 only in this request, never in the draft record; binary reads above are sequential.
    return content
  }

  /** Called inside the ordinary send queue; images remain original PromptContentPart wire inputs. */
  async content(sessionId, ids) {
    const records = this.readyRecords(sessionId, ids)
    return this.trackReads(records, this.buildContent(records))
  }

  /** Both original command and prompt endpoints admit the same image/file wire shapes. */
  commandContent(sessionId, ids) {
    return this.content(sessionId, ids)
  }

  async preview({ sessionId, id }) {
    const records = this.readyRecords(sessionId, [id])
    if (records[0].record.kind !== 'image') throw new TypeError('Only prepared image drafts can be previewed')
    const [part] = await this.trackReads(records, this.buildContent(records, { preview: true }))
    return { id, kind: 'image', name: part.name, mediaType: part.mediaType,
      bytes: records[0].record.item.bytes, data: part.data }
  }

  async release({ sessionId, id }) {
    requireId(id)
    const record = this.records.get(id)
    if (record && record.sessionId !== sessionId) throw new Error('Attachment draft belongs to another conversation')
    if (record) {
      record.releasing = true
      record.lifetime.abort(new Error('Attachment draft removed'))
      await record.done.catch(_failure => { /* Upload failure remains visible in its original App request. */ })
      await Promise.allSettled([...record.reads])
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
      await Promise.allSettled([...record.reads])
    }))
    this.records.clear()
  }
}
