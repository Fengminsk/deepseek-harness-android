/**
 * 桌面宿主（`platform: desktop`）的附件适配器：手机选好的附件草稿留在手机私有缓存里，
 * 桌面宿主在 `attachments.prepare` 内用反向请求 `native.attachments.read` 分页拉取字节，
 * 直接流式写进既有 `ctx.fileUploads.uploadStream`（设计见
 * `apps/android/docs/remote-dsh/p5-remaining-design.md` §3.4）。
 *
 * App 只看到与本地 Android 实现相同的 `attachments.*` 方法面（prepare/preview/release）；
 * 宿主侧不保存副本、不引入二进制帧、不新增 App→宿主方法（protocol §5.2 只追加一行）。
 * 本模块不引入新的 Node 内建模块：Android 上不会构造这个类。
 */

import { createHash } from 'node:crypto'

/** 分页读取的手机附件草稿；protocol §5.2 唯一新增的 `native.*` 转发条目。 */
const READ_METHOD = 'native.attachments.read'
/** 单页字节数：base64 后约 350 KiB，远低于 1 MiB 上行帧（protocol §1.3）。 */
const PAGE_BYTES = 256 * 1024
/** 远程预览上限：下行单帧 16 MiB，8 MiB 原始字节 base64 后约 10.7 MiB，留出信封余量。 */
const MAX_PREVIEW_BYTES = 8 * 1024 * 1024
/** 单页反向请求的重试退避（毫秒）：共 5 次尝试，最后一次失败即整体失败。 */
const DEFAULT_RETRY_DELAYS_MS = [300, 600, 1200, 2400]
/** 可重试失败码：其它 `attachment-file/*`、unsupported 与对账失败都是永久失败。 */
const RETRYABLE_CODES = new Set(['gateway/timeout', 'gateway/unavailable'])
/** 与 `attachments.mjs` 相同的 uuid v4 语法：只接受 `attachment.pick` 产生的私有草稿标识。 */
const attachmentId = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const imageTypes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
// eslint-disable-next-line no-control-regex -- Controls identify binary content; tabs and line endings remain text.
const invalidName = /[\0-\x1f\x7f/\\]/
const base64 = /^[A-Za-z0-9+/]*={0,2}$/

/**
 * 构造可直接交给门面 `remoteFailure` 的失败：`code` 进 `_pocket_error.code`，
 * `message` 是能直接展示的中文句子（protocol §9.4）。
 * @param {string} code 协议词汇表的错误码
 * @param {string} message 可直接展示的说明
 * @returns {Error} 带 code 的错误
 */
function attachmentFailure(code, message) {
  return Object.assign(new Error(message), { code })
}

function imageError(code, message) {
  return attachmentFailure(code, message)
}

/** 手机返回的字节流不符合线上语法：内容已不可信，只能让用户重新选择。 */
function pageFailure() {
  return attachmentFailure('attachment-file/unavailable', '手机返回的附件数据无效，请重新选择。')
}

function changedFailure() {
  return attachmentFailure('attachment-file/changed', '选择的文件已变化，请重新选择。')
}

/**
 * 校验附件草稿标识：宿主只把 uuid 当线上标识，永远不做路径拼接。
 * @param {unknown} id 草稿标识
 * @returns {void}
 */
function requireId(id) {
  if (typeof id !== 'string' || !attachmentId.test(id)) {
    throw new TypeError('Invalid selected attachment identity')
  }
}

/**
 * 校验显示名；规则与 `attachment-files.mjs` 的 wire 文件名一致。
 * @param {unknown} name 显示名
 * @returns {string} 合法显示名
 */
function requireName(name) {
  if (typeof name !== 'string' || !name.isWellFormed() || !name || name === '.' || name === '..'
    || Buffer.byteLength(name) > 255 || invalidName.test(name)) {
    throw new TypeError('Invalid selected attachment name')
  }
  return name
}

/**
 * 校验 App 声明的媒体类型；图片分流只认 `image/` 前缀，最终是否受理由图片校验服务决定。
 * @param {unknown} mediaType App 声明的媒体类型
 * @returns {string} 合法媒体类型
 */
function requireMediaType(mediaType) {
  if (typeof mediaType !== 'string' || mediaType.length === 0 || mediaType.length > 255
    || !/^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+$/.test(mediaType)) {
    throw new TypeError('Invalid selected attachment media type')
  }
  return mediaType
}

/**
 * 校验 App 声明的大小。声明值只用于和手机返回的权威 `size` 对账，实际字节以拉取结果为准。
 * @param {unknown} bytes 声明字节数
 * @returns {number} 合法字节数
 */
function requireBytes(bytes) {
  if (!Number.isSafeInteger(bytes) || bytes < 0) throw new TypeError('Invalid selected attachment size')
  return bytes
}

/**
 * 校验一页 `native.attachments.read` 应答，并解出这一页的字节。
 * @param {unknown} response 手机应答的 `result`
 * @param {number} offset 本次请求的 `offset`
 * @returns {{ bytes: Buffer, nextOffset: number, size: number, eof: boolean }} 校验后的页
 */
function readPage(response, offset) {
  if (typeof response !== 'object' || response === null || Array.isArray(response)) throw pageFailure()
  const { data, nextOffset, size, eof } = response
  if (typeof data !== 'string' || data.length % 4 !== 0 || !base64.test(data)) throw pageFailure()
  if (typeof eof !== 'boolean' || !Number.isSafeInteger(nextOffset) || nextOffset < offset
    || !Number.isSafeInteger(size) || size < 0) {
    throw pageFailure()
  }
  const bytes = Buffer.from(data, 'base64')
  // 页大小、剩余字节与前进量都必须自洽；短读允许，但 `nextOffset` 必须对应真实返回的字节数。
  if (bytes.length > PAGE_BYTES || bytes.length > size - offset
    || nextOffset !== offset + bytes.length || (eof && nextOffset !== size)) {
    throw pageFailure()
  }
  return { bytes, nextOffset, size, eof }
}

/**
 * 把传输层 Promise 与记录的中止信号合并：release/close/连接解绑要能立即打断在途页请求，
 * 而不是等手机回一页。
 * @param {Promise<unknown>} promise 在途请求
 * @param {AbortSignal} signal 记录的生命周期信号
 * @returns {Promise<unknown>} 请求结果或中止原因
 */
function raceAbort(promise, signal) {
  signal.throwIfAborted()
  const { promise: aborted, reject } = Promise.withResolvers()
  const onAbort = () => reject(signal.reason)
  signal.addEventListener('abort', onAbort, { once: true })
  return Promise.race([promise, aborted]).finally(() => signal.removeEventListener('abort', onAbort))
}

/**
 * 可取消的退避等待：连接解绑/用户取消时立即以记录的中止原因失败，不等定时器。
 * @param {number} delayMs 退避毫秒数
 * @param {AbortSignal} signal 记录的生命周期信号
 * @returns {Promise<void>} 等待完成
 */
function waitForRetry(delayMs, signal) {
  signal.throwIfAborted()
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort)
      resolve()
    }, delayMs)
    const onAbort = () => {
      clearTimeout(timer)
      reject(signal.reason)
    }
    signal.addEventListener('abort', onAbort, { once: true })
  })
}

/** 桌面宿主侧的附件适配器：字节只在手机上，宿主按页拉取后直接交给 DSH 附件入库。 */
export class DesktopAppAttachments {
  /**
   * @param {object} ctx 宿主插件上下文；读取 `fileUploads`、`attachments`（图片校验）与 `agents`
   * @param {object} deps 宿主侧依赖
   * @param {(method: string, params: object) => Promise<unknown>} deps.request 门面反向请求（已绑定当前设备）
   * @param {(sessionId: string) => Promise<unknown>} deps.ensureSession 复用 `AppSessions.ensure`
   * @param {() => { maxFileBytes: number }} deps.limits 宿主附件大小配置（`attachmentFileMaxBytes`）
   */
  constructor(ctx, { request, ensureSession, limits, retryDelaysMs } = {}) {
    if (typeof request !== 'function' || typeof ensureSession !== 'function' || typeof limits !== 'function') {
      throw new TypeError('DesktopAppAttachments requires request, ensureSession and limits')
    }
    this.ctx = ctx
    this.request = request
    this.ensureSession = ensureSession
    this.limits = limits
    // 测试可以缩短退避；生产固定 300→600→1200→2400ms（见 DEFAULT_RETRY_DELAYS_MS）。
    this.retryDelaysMs = Array.isArray(retryDelaysMs) && retryDelaysMs.every(
      delay => Number.isSafeInteger(delay) && delay >= 0,
    ) ? [...retryDelaysMs] : DEFAULT_RETRY_DELAYS_MS
    this.records = new Map()
    this.closed = false
    // 与本地实现一致：一次只解码/校验一张图片，图片编解码策略仍由 DSH 附件服务拥有。
    this.imageWork = Promise.resolve()
  }

  /**
   * 准备一个手机草稿：文件流式写入 DSH 附件入库，图片整图读取并交 DSH 校验。
   * @param {object} params App 请求参数
   * @param {string} params.sessionId 所属会话
   * @param {string} params.id `attachment.pick` 产生的 uuid v4
   * @param {string} params.name 显示名
   * @param {string} params.mediaType App 声明的媒体类型
   * @param {number} params.bytes App 声明的字节数
   * @returns {Promise<object>} App 看到的草稿信息
   */
  prepare({ sessionId, id, name, mediaType, bytes } = {}) {
    requireId(id)
    if (this.closed) throw new Error('Attachment service is closed')
    if (typeof sessionId !== 'string' || sessionId.length === 0) throw new TypeError('Attachment Session is required')
    const item = { id, name: requireName(name), mediaType: requireMediaType(mediaType), bytes: requireBytes(bytes) }
    let record = this.records.get(id)
    if (record && record.sessionId !== sessionId) throw new Error('Attachment draft belongs to another conversation')
    if (record?.releasing) throw new Error('Attachment is being removed')
    if (record?.state === 'preparing') return record.done
    if (record?.state === 'ready' && this.receiptValid(record)) return record.done
    if (!record) {
      record = { id, sessionId, reads: new Set() }
      this.records.set(id, record)
    }
    record.item = item
    record.transferFailure = undefined
    record.lifetime?.abort(attachmentFailure('gateway/cancelled', '附件准备已重新开始。'))
    record.state = 'preparing'
    record.lifetime = new AbortController()
    record.done = this.upload(record)
    return record.done
  }

  /**
   * 传输一条草稿：文件以分页生成器写进 `uploadStream`，图片整图读取后交 DSH 校验。
   * @param {object} record 草稿记录
   * @returns {Promise<object>} App 看到的草稿信息
   */
  async upload(record) {
    const signal = record.lifetime.signal
    try {
      const item = record.item
      record.kind = item.mediaType.startsWith('image/') ? 'image' : 'file'
      if (record.kind === 'image') {
        this.checkImage(item)
        const imageStore = this.ctx.attachments
        const imagePolicy = imageStore.imageLimits
        await this.serializeImage(async () => {
          const data = await this.readImage(record)
          // Validation fully decodes the source but does not persist or normalize the App draft.
          await imageStore.validateImage({ data, mediaType: item.mediaType, name: item.name })
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
        if (this.ctx.attachments?.imageLimits !== imagePolicy) throw imageError('IMAGE_RUNTIME_UNAVAILABLE', '图片校验设置已变更，原图已保留，请重试。')
        record.state = 'ready'
        return { id: record.id, kind: 'image', name: item.name, mediaType: item.mediaType, bytes: item.bytes }
      }
      if (item.bytes > this.fileLimit()) {
        throw attachmentFailure('gateway/bad-request', '附件超过这台电脑允许的大小上限，请重新选择。')
      }
      await this.ensureSession(record.sessionId)
      signal.throwIfAborted()
      record.receipt = await this.ctx.fileUploads.uploadStream({
        sessionId: record.sessionId,
        name: item.name,
        data: this.pull(record),
        signal,
      })
      signal.throwIfAborted()
      if (record.receipt.file.bytes !== item.bytes) throw changedFailure()
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
      // Log only stable error codes; selected names, content and wire payloads stay private.
      if (codes.length) console.error(`Pocket attachment transfer failure: ${codes.join(' > ')}`)
      // `fileUploads.uploadStream` 会把流内失败包成 session/attachment-invalid 并丢掉 cause；
      // 流里已经映射过的失败优先原样交给门面（设计 §3.4.3 的可分类 code）。
      if (record.transferFailure !== undefined) throw record.transferFailure
      // 中止也可能落在两次取页之间：此时外层包装来自 store 自己的 signal 检查。记录里的
      // 中止原因同样是协议词汇表失败，优先还原它。
      if (signal.aborted && typeof signal.reason?.code === 'string') throw signal.reason
      throw failure
    }
  }

  /**
   * 分页读取手机草稿的私有副本；每页都按 `nextOffset` 推进并与 `prepare` 声明的大小对账。
   *
   * 流式读取在 `ctx.fileUploads.uploadStream` 里消费：`attachment-local` 会把生成器抛出的
   * 非 `AttachmentError` 包成 `ATTACHMENT_WRITE_FAILED`，`file-upload` 再映射成
   * `session/attachment-invalid` 并丢掉 cause，App 只看到通用错误。因此这里记录映射后的
   * 失败，由 {@link upload} 在包装之后原样重抛（设计 §3.4.3 的可分类 code）。
   * @param {object} record 草稿记录
   * @returns {AsyncGenerator<Buffer, void, void>} 手机上的有序字节
   */
  async *pull(record) {
    try {
      yield* this.pullPages(record)
    } catch (failure) {
      if (record.state === 'preparing') record.transferFailure = failure
      throw failure
    }
  }

  /**
   * 逐页读取字节并把 `size`/`eof`/声明值对账；失败已由 {@link page} 映射到协议词汇表。
   * @param {object} record 草稿记录
   * @returns {AsyncGenerator<Buffer, void, void>} 手机上的有序字节
   */
  async *pullPages(record) {
    const signal = record.lifetime.signal
    const declared = record.item.bytes
    let offset = 0
    let size
    for (;;) {
      signal.throwIfAborted()
      const page = await this.page(record, offset)
      signal.throwIfAborted()
      if (size === undefined) {
        // `size` 是该文件在手机上的权威大小；与 `prepare` 声明不符说明选择已变化。
        size = page.size
        if (size !== declared) throw changedFailure()
      } else if (page.size !== size) {
        throw changedFailure()
      }
      if (!page.eof && page.bytes.length === 0) throw pageFailure()
      if (page.bytes.length > 0) yield page.bytes
      offset = page.nextOffset
      if (page.eof) {
        // eof 必须落在声明的总字节数上；累计字节与 `prepare` 的对账在这里收口。
        if (offset !== declared) throw changedFailure()
        return
      }
    }
  }

  /**
   * 请求一页并处理失败翻译：`-32601` → unsupported，手机给出的 `attachment-file/*`
   * 原样保留，传输层失败按协议 §5.4 收敛成 `gateway/cancelled`。
   * @param {object} record 草稿记录
   * @param {number} offset 本页起始偏移
   * @returns {Promise<{ bytes: Buffer, nextOffset: number, size: number, eof: boolean }>} 校验后的页
   */
  async page(record, offset) {
    const signal = record.lifetime.signal
    signal.throwIfAborted()
    // 只重试「这一页的请求」：页面校验（对账/坏 payload）与 attachment-file/* 永久失败
    // 直接抛出；重试期间没有写入任何字节，offset 仍停在本页起始位置。
    let attempt = 0
    for (;;) {
      signal.throwIfAborted()
      const pending = Promise.resolve().then(() => this.request(READ_METHOD, {
        id: record.id, offset, length: PAGE_BYTES,
      }))
      let response
      try {
        response = await raceAbort(pending, signal)
      } catch (failure) {
        const mapped = this.readFailure(failure, record)
        if (!RETRYABLE_CODES.has(mapped.code) || attempt >= this.retryDelaysMs.length) throw mapped
        await waitForRetry(this.retryDelaysMs[attempt], signal)
        attempt += 1
        continue
      }
      signal.throwIfAborted()
      return readPage(response, offset)
    }
  }

  /**
   * 把一次反向请求失败收敛到 App 可分类的 `_pocket_error.code`。
   * @param {unknown} failure 捕获的失败
   * @param {object} record 草稿记录
   * @returns {Error} 带协议词汇表 code 的失败
   */
  readFailure(failure, record) {
    const signal = record.lifetime.signal
    if (signal.aborted) {
      const reason = signal.reason
      return reason instanceof Error && typeof reason.code === 'string'
        ? reason : attachmentFailure('gateway/cancelled', '附件读取已取消，请重新选择。')
    }
    const wire = typeof failure?.code === 'number' ? failure.code : undefined
    if (wire === -32601) {
      return attachmentFailure('attachment-file/unsupported', '这台手机上的 App 版本不支持上传附件，请升级后重试。')
    }
    const code = typeof failure?.data?.code === 'string'
      ? failure.data.code
      : typeof failure?.code === 'string' ? failure.code : undefined
    if (code === 'unsupported-method') {
      return attachmentFailure('attachment-file/unsupported', '这台手机上的 App 版本不支持上传附件，请升级后重试。')
    }
    if (code === 'attachment-file/not-found') {
      return attachmentFailure(code, '文件已不在手机上，请重新选择。')
    }
    if (code === 'attachment-file/cancelled') {
      return attachmentFailure(code, '手机上的附件草稿已取消，请重新选择。')
    }
    if (code === 'attachment-file/invalid-request') {
      return attachmentFailure(code, '附件读取请求无效，请重新选择。')
    }
    if (code === 'gateway/cancelled') return attachmentFailure(code, '连接已断开，请重试。')
    // 超时/暂不可用是可重试的传输错误：交给 page() 的退避重试，最终失败仍保留
    // 可分类 code，App 提示「传输中断，可重试」。
    if (code === 'gateway/timeout') return attachmentFailure(code, '电脑上的 DSH 响应超时，请重试。')
    if (code === 'gateway/unavailable') return attachmentFailure(code, '与手机的连接暂不可用，请重试。')
    if (wire !== undefined || code !== undefined) {
      return attachmentFailure('attachment-file/unavailable', '手机没有返回可用的附件数据，请重试。')
    }
    // 传输层没有 JSON-RPC 应答：连接关闭、门面关闭或设备未绑定（protocol §5.4）。
    return attachmentFailure('gateway/cancelled', '连接已断开，请重试。')
  }

  /**
   * 宿主允许的单文件上限；`attachmentFileMaxBytes` 由插件配置注入，缺失是部署问题。
   * @returns {number} 上限字节数
   */
  fileLimit() {
    const maxFileBytes = this.limits()?.maxFileBytes
    if (!Number.isSafeInteger(maxFileBytes) || maxFileBytes <= 0) {
      throw attachmentFailure('gateway/internal', '附件大小配置不可用')
    }
    return maxFileBytes
  }

  /**
   * 整图读取：图片必须在内存里完整解码，长度由 `prepare` 声明值约束。
   * @param {object} record 草稿记录
   * @returns {Promise<Buffer>} 原图字节
   */
  async readImage(record) {
    const chunks = []
    let total = 0
    for await (const chunk of this.pull(record)) {
      chunks.push(chunk)
      total += chunk.length
    }
    return Buffer.concat(chunks, total)
  }

  /**
   * 检查一个已准备好的草稿仍持有可用的收据/摘要。
   * @param {object} record 草稿记录
   * @returns {boolean} 是否仍可直接发送
   */
  receiptValid(record) {
    const agent = this.ctx.agents.get(record.sessionId)
    if (record.kind === 'image') return agent !== undefined && agent === record.agent
      && record.imageDigest !== undefined && this.ctx.attachments?.imageLimits === record.imagePolicy
    return agent !== undefined && record.receipt !== undefined
      && this.ctx.fileUploads.resolve(agent, record.receipt.receiptId) !== undefined
  }

  /**
   * 读取 DSH 图片限额；缺失或形状不对是能力问题，不是参数问题。
   * @returns {object} `imageLimits`
   */
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

  /**
   * 手机声明的图片格式与大小必须先在 DSH 限额内，之后才拉取整图。
   * @param {object} item 草稿声明
   * @returns {void}
   */
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
        // Subtract before adding so even inconsistent declarations cannot overflow a budget.
        if (record.item.bytes > limits.maxMessageImageBytes - totalBytes) {
          throw imageError('IMAGES_TOO_LARGE', '图片总大小超过 DSH 配置的每条消息限制。')
        }
        totalBytes += record.item.bytes
        if (preview && record.item.bytes > MAX_PREVIEW_BYTES) {
          throw imageError('IMAGE_PREVIEW_TOO_LARGE', '此图片超过 8 MiB 远程预览限制，仍可按 DSH 的发送限制发送。')
        }
      }
    }
    const content = []
    for (const snapshot of records) {
      const { record, lifetime } = snapshot
      this.checkReady(snapshot)
      if (record.kind === 'file') {
        // 文件字节已在 prepare 时入库；这里只引用收据，不再产生手机流量。
        content.push({ type: 'file', receiptId: record.receipt.receiptId })
        continue
      }
      try {
        content.push(await this.serializeImage(async () => {
          this.checkReady(snapshot)
          const data = await this.readImage(record)
          this.checkReady(snapshot)
          if (data.length !== record.item.bytes
            || createHash('sha256').update(data).digest('hex') !== record.imageDigest) {
            throw attachmentFailure('attachment-file/changed', '选择的图片已变化，请重新选择。')
          }
          return { type: 'image', mediaType: record.item.mediaType,
            data: data.toString('base64'), name: record.item.name }
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

  /**
   * 构造发送内容；图片在这里重新向手机取整图并核对摘要。
   * @param {string} sessionId 所属会话
   * @param {string[]} ids 草稿标识
   * @returns {Promise<object[]>} PromptContentPart 列表
   */
  async content(sessionId, ids) {
    const records = this.readyRecords(sessionId, ids)
    return this.trackReads(records, this.buildContent(records))
  }

  /** Both original command and prompt endpoints admit the same image/file wire shapes. */
  commandContent(sessionId, ids) {
    return this.content(sessionId, ids)
  }

  /**
   * 预览已准备好的图片；远程上限 8 MiB，超过时回既有 `IMAGE_PREVIEW_TOO_LARGE`，不阻塞发送。
   * @param {object} params `{sessionId, id}`
   * @returns {Promise<object>} App 的预览结果
   */
  async preview({ sessionId, id } = {}) {
    const records = this.readyRecords(sessionId, [id])
    if (records[0].record.kind !== 'image') throw new TypeError('Only prepared image drafts can be previewed')
    const [part] = await this.trackReads(records, this.buildContent(records, { preview: true }))
    return { id, kind: 'image', name: part.name, mediaType: part.mediaType,
      bytes: records[0].record.item.bytes, data: part.data }
  }

  /**
   * 移除一个草稿：宿主没有副本，只清记录并打断在途拉取；手机侧在 App 自己的通道里删缓存。
   * @param {object} params `{sessionId, id}`
   * @returns {Promise<{ released: true }>} 幂等的移除确认
   */
  async release({ sessionId, id } = {}) {
    requireId(id)
    const record = this.records.get(id)
    if (record && record.sessionId !== sessionId) throw new Error('Attachment draft belongs to another conversation')
    if (record) {
      record.releasing = true
      record.lifetime.abort(attachmentFailure('gateway/cancelled', '附件草稿已移除。'))
      await record.done.catch(_failure => { /* The original App request owns its failure. */ })
      await Promise.allSettled([...record.reads])
      this.records.delete(id)
    }
    return { released: true }
  }

  /**
   * 解绑设备时打断在途传输（协议 §7.2：连接断开只失败当次操作，已准备好的收据留待重连）。
   * 必须在 transport.unbind 的同步路径上调用。
   * @returns {void}
   */
  detachAll() {
    if (this.closed) return
    const failure = attachmentFailure('gateway/cancelled', '远程连接已断开，请重试。')
    for (const record of this.records.values()) {
      if (record.state === 'preparing') record.lifetime.abort(failure)
    }
  }

  /** 门面卸载：中止全部在途传输并清空记录。幂等。 */
  async close() {
    if (this.closed) return
    this.closed = true
    await Promise.all([...this.records.values()].map(async record => {
      record.lifetime.abort(attachmentFailure('gateway/cancelled', '附件服务已停止。'))
      await record.done.catch(_failure => { /* The original App request owns its failure. */ })
      await Promise.allSettled([...record.reads])
    }))
    this.records.clear()
  }
}
