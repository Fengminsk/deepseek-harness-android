const MAX_WINDOW_BYTES = 1024 * 1024

function failure(code, message) {
  return Object.assign(new Error(message), { code })
}

function validString(value, limit, label) {
  if (typeof value !== 'string' || value.length === 0 || value.length > limit || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw failure('gateway/bad-request', `Invalid ${label}`)
  }
  return value
}

/**
 * A settled Markdown image reads through the same Session-scoped original
 * workspaceFiles service as the document preview. No Android file path, URL,
 * attachment store, or process cwd is an alternate authority here.
 */
export class AppChatImages {
  constructor({ invoke, mimeType, limits }) {
    this.invoke = invoke
    this.mimeType = mimeType
    this.limits = limits
    this.active = new Set()
    this.closed = false
  }

  async preview(params) {
    if (this.closed) throw failure('gateway/cancelled', 'Image previews are closed')
    const sessionId = validString(params?.sessionId, 200, 'sessionId')
    const path = validString(params?.path, 8192, 'path')
    if (/^[a-z][a-z\d+.-]*:/iu.test(path) && !/^[a-z]:[\\/]/iu.test(path)) {
      throw failure('gateway/bad-request', 'Image preview requires a workspace file path')
    }
    const mediaType = this.mimeType(path)
    if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(mediaType)) {
      throw failure('chat-image/unsupported', 'This image format cannot be previewed')
    }
    const limits = this.limits()
    if (!Number.isSafeInteger(limits.maxBytes) || limits.maxBytes < 1) {
      throw failure('chat-image/unavailable', 'The original image policy is unavailable')
    }
    if (this.active.size >= limits.maxRequests) throw failure('chat-image/busy', 'Too many images are loading')
    const controller = new AbortController()
    const entry = { controller, done: null }
    this.active.add(entry)
    const timeout = setTimeout(() => controller.abort(failure('chat-image/timeout', 'Image loading timed out')), limits.timeoutMs)
    const aborted = Promise.withResolvers()
    const onAbort = () => aborted.reject(controller.signal.reason)
    controller.signal.addEventListener('abort', onAbort, { once: true })
    entry.done = Promise.resolve().then(async () => {
      const scope = { workspaceFileScopeId: sessionId, path }
      const stat = await this.invoke('workspaceFiles', 'stat', scope, controller.signal)
      controller.signal.throwIfAborted()
      if (!Number.isSafeInteger(stat?.bytes) || stat.bytes <= 0 || stat.bytes > limits.maxBytes) {
        throw failure('chat-image/too-large', 'This image exceeds the inline preview limit')
      }
      const data = Buffer.alloc(stat.bytes)
      for (let offset = 0; offset < data.length; offset += MAX_WINDOW_BYTES) {
        const length = Math.min(MAX_WINDOW_BYTES, data.length - offset)
        const window = await this.invoke('workspaceFiles', 'readBytes', {
          ...scope, options: { range: { offset, length } },
        }, controller.signal)
        controller.signal.throwIfAborted()
        if (window?.absolutePath !== stat.absolutePath || window.version !== stat.version
          || window.bytes !== stat.bytes || window.offset !== offset
          || !(window.data instanceof Uint8Array) || window.data.byteLength !== length
          || window.eof !== (offset + length === data.length)) {
          throw failure('chat-image/changed', 'This image changed while loading')
        }
        Buffer.from(window.data).copy(data, offset)
      }
      controller.signal.throwIfAborted()
      return { sessionId, path, mediaType, bytes: data.length, data: data.toString('base64') }
    }).finally(() => {
      clearTimeout(timeout)
      controller.signal.removeEventListener('abort', onAbort)
      this.active.delete(entry)
    })
    return Promise.race([entry.done, aborted.promise])
  }

  async close() {
    this.closed = true
    const pending = [...this.active]
    for (const entry of pending) entry.controller.abort(failure('gateway/cancelled', 'Image previews are closed'))
    if (pending.length === 0) return
    let timer
    try {
      await Promise.race([Promise.allSettled(pending.map(entry => entry.done)), new Promise((_, reject) => {
        timer = setTimeout(() => reject(failure('chat-image/cleanup-timeout', 'Image reads have not stopped')),
          this.limits().closeTimeoutMs)
      })])
    } finally { clearTimeout(timer) }
  }
}
