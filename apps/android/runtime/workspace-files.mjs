import { constants } from 'node:fs'
import { lstat, open, opendir, realpath } from 'node:fs/promises'
import path from 'node:path'
import { setImmediate as yieldToIo } from 'node:timers/promises'

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
// eslint-disable-next-line no-control-regex -- Reject control characters in client-supplied relative paths.
const invalidCharacters = /[\0-\x1f\x7f\\:]/
// eslint-disable-next-line no-control-regex -- Detect binary controls while permitting text tabs and line endings.
const binaryCharacters = /[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/

class WorkspaceError extends Error {
  constructor(code, message) { super(message); this.code = `workspace-files/${code}` }
}

function refuse(code, message) { throw new WorkspaceError(code, message) }
function relative(value = '') {
  if (typeof value !== 'string' || value.length > 4096 || !value.isWellFormed()
    || invalidCharacters.test(value) || value.startsWith('/')
    || value !== '' && value.split('/').some(part => !part || part === '.' || part === '..')) {
    refuse('invalid-path', '仅接受工作区内的相对路径，请从目录重新选择。')
  }
  return value
}
function offsetOf(value = 0) {
  if (!Number.isSafeInteger(value) || value < 0) refuse('invalid-page', '分页位置无效，请从头读取。')
  return value
}
function versionOf(info) { return `${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}:${info.ctimeMs}` }
function sameIdentity(left, right) { return left.dev === right.dev && left.ino === right.ino }
function samePath(left, right) {
  return process.platform === 'win32' ? left.toLowerCase() === right.toLowerCase() : left === right
}
function contained(root, target) {
  const suffix = path.relative(root, target)
  return suffix === '' || !suffix.startsWith(`..${path.sep}`) && suffix !== '..' && !path.isAbsolute(suffix)
}
function requireVersion(expected, actual) {
  if (expected !== undefined && (typeof expected !== 'string' || expected !== actual)) {
    refuse('changed', '文件或目录已变化，已显示内容保留。请从头刷新后继续。')
  }
}
function textOf(bytes, offset = 0) {
  let text
  try { text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes) }
  catch { throw new WorkspaceError('not-text', '此文件不是可预览的 UTF-8 文本。') }
  if (binaryCharacters.test(text)) refuse('not-text', '此文件包含二进制内容，无法作为文本预览。')
  return offset === 0 && text.startsWith('\ufeff') ? text.slice(1) : text
}
function failureOf(error) {
  if (error instanceof WorkspaceError) return { code: error.code, message: error.message }
  const known = {
    ENOENT: ['not-found', '路径已不存在，请刷新上级目录。'],
    ENOTDIR: ['not-directory', '路径已不是目录，请刷新上级目录。'],
    EACCES: ['unavailable', '当前无法读取此路径，请刷新后重试。'],
    EPERM: ['unavailable', '当前无法读取此路径，请刷新后重试。'],
    ELOOP: ['symlink', '此入口不跟随符号链接，请选择工作区中的实际文件。'],
  }[error?.code]
  return known ? { code: `workspace-files/${known[0]}`, message: known[1] }
    : { code: 'workspace-files/unavailable', message: '工作区读取未完成，已显示内容保留。请刷新后重试。' }
}

/**
 * Read-only view of the one App-private workspace captured by the native host.
 * No client can supply a root or Session filesystem authority. Unlike original
 * workspaceFiles.read, this surface never intentionally reads outside that root.
 *
 * Every path component is checked without following links. Open file identity,
 * ancestor identity, and versions are rechecked before publishing. This detects
 * ordinary moves/replacements; it is not an OS sandbox against a malicious peer
 * with the same UID concurrently rewriting the filesystem.
 */
export class AppWorkspaceFiles {
  constructor({ root, limits }) {
    if (typeof root !== 'string' || !path.isAbsolute(root)) throw new TypeError('A trusted absolute workspace root is required')
    this.rootPath = path.resolve(root)
    this.limits = limits
    this.rootIdentity = null
    this.searches = new Map()
    this.pending = new Set()
    this.closed = false
  }

  /** JSON carrier; failures retain stable codes without native stack or content. */
  async call(method, params = {}) {
    const done = Promise.withResolvers()
    this.pending.add(done.promise)
    try {
      if (this.closed) refuse('closed', '工作区服务已关闭，请重新连接。')
      if (Object.hasOwn(params, 'root') || Object.hasOwn(params, 'workspace') || Object.hasOwn(params, 'sessionId')) {
        refuse('invalid-path', '此入口只访问 App 的默认私有工作区。')
      }
      let result
      switch (method) {
        case 'info': result = await this.info(); break
        case 'list': result = await this.list(params); break
        case 'read': result = await this.read(params); break
        case 'search': result = await this.search(params); break
        case 'search.cancel': result = await this.cancel(params); break
        default: refuse('invalid-request', '无法识别此工作区操作。')
      }
      this.checkOpen()
      return result
    } catch (error) { return { _pocket_error: failureOf(error) } }
    finally { this.pending.delete(done.promise); done.resolve() }
  }

  checkOpen() {
    if (this.closed) refuse('closed', '工作区服务已关闭，请重新连接。')
  }

  budgets() {
    const limits = this.limits()
    for (const [key, value] of Object.entries({
      readPageBytes: limits.readPageBytes, maxDirectoryEntries: limits.maxDirectoryEntries,
      listPageSize: limits.listPageSize, maxSearches: limits.maxSearches,
      closeTimeoutMs: limits.closeTimeoutMs, ...limits.search,
    })) {
      if (!Number.isSafeInteger(value) || value < 1) throw new TypeError(`Invalid workspace budget: ${key}`)
    }
    if (limits.readPageBytes < 4) throw new TypeError('Text pages require at least four bytes')
    return limits
  }

  async root() {
    this.checkOpen()
    const info = await lstat(this.rootPath)
    if (info.isSymbolicLink()) refuse('symlink', '工作区根目录不能是符号链接。')
    if (!info.isDirectory()) refuse('not-directory', 'App 工作区目录暂不可用。')
    const canonical = await realpath(this.rootPath)
    if (this.rootIdentity && (!sameIdentity(this.rootIdentity.info, info)
      || !samePath(this.rootIdentity.canonical, canonical))) {
      refuse('changed', 'App 工作区根目录已被替换，请重启服务后重新确认。')
    }
    this.rootIdentity ??= { canonical, info }
    return { canonical, info }
  }

  async info() {
    const root = await this.root()
    return { root: root.canonical, label: 'App 私有工作区', limits: this.budgets() }
  }

  async locate(value) {
    const name = relative(value)
    const root = await this.root()
    const ancestry = [{ absolute: root.canonical, info: root.info }]
    let absolute = root.canonical, info = root.info
    for (const part of name === '' ? [] : name.split('/')) {
      if (!info.isDirectory()) refuse('not-directory', '路径中的上级项目已不是目录，请刷新。')
      absolute = path.join(absolute, part)
      info = await lstat(absolute)
      if (info.isSymbolicLink()) refuse('symlink', '此入口不跟随符号链接，请选择工作区中的实际文件。')
      const canonical = await realpath(absolute)
      if (!contained(root.canonical, canonical) || !samePath(canonical, absolute)) {
        refuse('outside-workspace', '该路径不在 App 私有工作区内。')
      }
      ancestry.push({ absolute, info })
    }
    return { root: root.canonical, path: name, absolute, info, ancestry }
  }

  async verify(target) {
    for (const entry of target.ancestry) {
      const now = await lstat(entry.absolute)
      if (now.isSymbolicLink()) refuse('symlink', '读取期间路径变成了符号链接，请刷新目录。')
      if (!sameIdentity(now, entry.info)) refuse('changed', '读取期间路径已被移动或替换，请刷新目录。')
    }
    const canonical = await realpath(target.absolute)
    if (!contained(target.root, canonical) || !samePath(canonical, target.absolute)) {
      refuse('outside-workspace', '读取期间路径已离开 App 私有工作区。')
    }
  }

  /** Bounded, stable-order directory window. A changed directory invalidates continuation. */
  async list(params) {
    const target = await this.locate(params.path ?? '')
    if (!target.info.isDirectory()) refuse('not-directory', '此项目不是目录。')
    const limits = this.budgets()
    const version = versionOf(target.info)
    requireVersion(params.version, version)
    const offset = offsetOf(params.offset)
    const directory = await opendir(target.absolute)
    const names = []
    let truncated = false
    try {
      while (true) {
        this.checkOpen()
        const entry = await directory.read()
        if (!entry) break
        if (names.length >= limits.maxDirectoryEntries) { truncated = true; break }
        names.push(entry.name)
      }
    } finally { await directory.close() }
    names.sort((left, right) => left < right ? -1 : left > right ? 1 : 0)
    if (offset > names.length) refuse('invalid-page', '目录分页位置已失效，请从头刷新。')
    const entries = []
    for (const name of names.slice(offset, offset + limits.listPageSize)) {
      this.checkOpen()
      const childPath = [target.path, name].filter(Boolean).join('/')
      try { relative(childPath) }
      catch { entries.push({ name, path: null, kind: 'other', blockedReason: 'unsupported-name' }); continue }
      const info = await lstat(path.join(target.absolute, name))
      const kind = info.isSymbolicLink() ? 'link' : info.isDirectory() ? 'directory' : info.isFile() ? 'file' : 'other'
      entries.push({ name, path: childPath, kind, modifiedAt: info.mtimeMs,
        ...(kind === 'file' ? { bytes: info.size } : {}),
        ...(['link', 'other'].includes(kind) ? { blockedReason: kind === 'link' ? 'symlink' : 'not-regular-file' } : {}) })
    }
    await this.verify(target)
    requireVersion(version, versionOf(await lstat(target.absolute)))
    return { root: target.root, path: target.path, version, entries, offset,
      nextOffset: offset + limits.listPageSize < names.length ? offset + limits.listPageSize : null,
      truncated, listedEntries: names.length }
  }

  async withFile(value, expectedVersion, operation) {
    const target = await this.locate(value)
    if (!target.info.isFile()) refuse('not-file', '此项目不是可读取的普通文件。')
    const version = versionOf(target.info)
    requireVersion(expectedVersion, version)
    const handle = await open(target.absolute, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0))
    try {
      this.checkOpen()
      const opened = await handle.stat()
      if (!opened.isFile() || versionOf(opened) !== version) refuse('changed', '文件在打开时已变化，请刷新后重试。')
      await this.verify(target)
      const result = await operation(handle, target, version)
      this.checkOpen()
      requireVersion(version, versionOf(await handle.stat()))
      await this.verify(target)
      return result
    } finally { await handle.close() }
  }

  /** Byte offsets are opaque continuation positions at valid UTF-8 boundaries. */
  async read(params) {
    const offset = offsetOf(params.offset)
    const budget = this.budgets().readPageBytes
    return this.withFile(params.path, params.version, async (handle, target, version) => {
      this.checkOpen()
      if (offset > target.info.size) refuse('invalid-page', '分页位置已超过文件末尾，请从头读取。')
      const data = Buffer.alloc(Math.min(budget + 3, target.info.size - offset))
      let length = 0
      while (length < data.length) {
        this.checkOpen()
        const read = await handle.read(data, length, data.length - length, offset + length)
        if (!read.bytesRead) break
        length += read.bytesRead
      }
      let end = Math.min(budget, length)
      if (offset + end < target.info.size) {
        while (end > 0 && end < length && (data[end] & 0xc0) === 0x80) end--
      }
      if (end === 0 && offset < target.info.size) refuse('changed', '未能读取下一段内容，请从头刷新。')
      return { root: target.root, path: target.path, version, bytes: target.info.size,
        offset, nextOffset: offset + end, eof: offset + end >= target.info.size,
        text: textOf(data.subarray(0, end), offset) }
    })
  }

  async search(params) {
    relative(params.path ?? '')
    if (!uuid.test(params.requestId ?? '')) refuse('invalid-request', '搜索请求标识无效。')
    if (!['name', 'content'].includes(params.mode) || typeof params.caseSensitive !== 'boolean'
      || typeof params.query !== 'string' || !params.query || params.query.length > 256
      || !params.query.isWellFormed() || /[\0\r\n]/.test(params.query)) {
      refuse('invalid-query', '请输入 1–256 个单行字符，并选择名称或内容搜索。')
    }
    const budgets = this.budgets()
    if (this.searches.has(params.requestId)) refuse('busy', '该搜索仍在进行，请等待或先停止。')
    if (this.searches.size >= budgets.maxSearches) refuse('busy', '搜索任务已达上限，请等待已有搜索结束。')
    const done = Promise.withResolvers()
    const entry = { cancelled: false, done: done.promise }
    this.searches.set(params.requestId, entry)
    try { return await this.scan(params, entry, budgets.search) }
    finally { this.searches.delete(params.requestId); done.resolve() }
  }

  async scan(params, operation, limits) {
    const base = await this.locate(params.path ?? '')
    const started = performance.now()
    const matches = [], skipped = []
    let entries = 0, files = 0, bytes = 0, stoppedBy = null
    const check = () => {
      if (operation.cancelled || this.closed) refuse('cancelled', '搜索已停止，未完成整个范围的检查。')
      if (performance.now() - started >= limits.maxDurationMs) stoppedBy ??= 'duration'
      return stoppedBy === null
    }
    const match = value => params.caseSensitive ? value.includes(params.query) : value.toLowerCase().includes(params.query.toLowerCase())
    const skip = (name, reason) => skipped.push({ path: name, reason })
    const add = result => {
      matches.push(result)
      if (matches.length >= limits.maxMatches) stoppedBy = 'matches'
    }
    const visit = async (name, depth) => {
      if (!check()) return
      if (entries >= limits.maxEntries) { stoppedBy = 'entries'; return }
      entries++
      let target
      try { target = await this.locate(name) }
      catch (error) { skip(name, failureOf(error).code.replace('workspace-files/', '')); return }
      const kind = target.info.isDirectory() ? 'directory' : target.info.isFile() ? 'file' : 'other'
      if (params.mode === 'name' && name !== '' && match(path.basename(name))) {
        add({ path: name, name: path.basename(name), kind })
      }
      if (!check()) return
      if (kind === 'directory') {
        if (depth >= limits.maxDepth) { skip(name, 'depth'); return }
        const directory = await opendir(target.absolute)
        try {
          while (check()) {
            const child = await directory.read()
            if (!child) break
            await visit([name, child.name].filter(Boolean).join('/'), depth + 1)
            await yieldToIo()
          }
        } finally { await directory.close() }
        await this.verify(target)
        requireVersion(versionOf(target.info), versionOf(await lstat(target.absolute)))
        return
      }
      if (kind !== 'file') { skip(name, 'not-regular-file'); return }
      if (params.mode !== 'content') return
      if (files >= limits.maxFiles) { stoppedBy = 'files'; return }
      files++
      if (target.info.size > limits.fileBytes) { skip(name, 'file-bytes'); return }
      if (bytes + target.info.size > limits.totalBytes) { stoppedBy = 'total-bytes'; return }
      try {
        const result = await this.withFile(name, versionOf(target.info), async (handle, file, version) => {
          const data = Buffer.alloc(file.info.size)
          let size = 0
          while (size < data.length && check()) {
            const read = await handle.read(data, size, Math.min(this.budgets().readPageBytes, data.length - size), size)
            if (!read.bytesRead) break
            size += read.bytesRead
          }
          if (!check()) return null
          if (size !== data.length) refuse('changed', '搜索期间文件已变化。')
          bytes += size
          return { text: textOf(data), version,
            bomBytes: data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf ? 3 : 0 }
        })
        if (!result || !check()) return
        let line = 0, byteOffset = 0, from = 0
        while (from <= result.text.length) {
          const newline = result.text.indexOf('\n', from)
          const end = newline < 0 ? result.text.length : newline
          const sourceLine = result.text.slice(from, end)
          line++
          if (match(sourceLine)) {
            add({ path: name, name: path.basename(name), kind: 'file', line,
              offset: byteOffset, version: result.version, preview: sourceLine.slice(0, limits.previewChars) })
          }
          byteOffset += Buffer.byteLength(sourceLine, 'utf8') + 1 + (line === 1 ? result.bomBytes : 0)
          if (!check()) break
          if (line % 256 === 0) await yieldToIo()
          if (newline < 0) break
          from = newline + 1
        }
      } catch (error) {
        if (error instanceof WorkspaceError && error.code === 'workspace-files/cancelled') throw error
        skip(name, failureOf(error).code.replace('workspace-files/', ''))
      }
    }
    await visit(base.path, 0)
    check()
    return { root: base.root, path: base.path, query: params.query, mode: params.mode,
      matches, skipped, complete: stoppedBy === null && skipped.length === 0, stoppedBy,
      scanned: { entries, files, bytes }, limits }
  }

  /** Cancellation acknowledges completion of the owned scan, not just a flag. */
  async cancel(params) {
    if (!uuid.test(params.requestId ?? '')) refuse('invalid-request', '搜索请求标识无效。')
    const entry = this.searches.get(params.requestId)
    if (entry) { entry.cancelled = true; await entry.done }
    return { cancelled: true }
  }

  async close() {
    this.closed = true
    const entries = [...this.searches.values()]
    for (const entry of entries) entry.cancelled = true
    let timer
    try {
      await Promise.race([
        Promise.all([...this.pending, ...entries.map(entry => entry.done)]),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new WorkspaceError('close-timeout',
            '工作区读取仍在释放资源，尚未确认服务关闭完成。')), this.budgets().closeTimeoutMs)
        }),
      ])
    } finally { clearTimeout(timer) }
  }
}
