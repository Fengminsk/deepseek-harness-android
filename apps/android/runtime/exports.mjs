import { mkdir, open, realpath, stat, unlink } from 'node:fs/promises'
import { isAbsolute, join } from 'node:path'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { publishImmutableFile } from './immutable-file-publisher.mjs'
import {
  DEFAULT_SESSION_LOG_COMPRESSION_LEVEL,
  flushLiveSessionLog,
  readSessionLogText,
  sessionLogExportDeps,
  sessionLogZipFilename,
  streamSessionLogZip,
} from '@deepseek-ai/dsh-session-log-export'

const exportId = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function identity(value) {
  if (typeof value !== 'string' || !exportId.test(value)) throw new TypeError('Invalid export identity')
  return value
}

/** Original DSH ZIP production to a native-owned cache directory; no Web listener is used. */
export class AppExports {
  constructor(ctx, { directory }) {
    this.ctx = ctx
    this.directory = directory
    this.records = new Map()
    this.closed = false
  }

  prepare({ id, sessionId, includeDescendants = true }) {
    identity(id)
    if (this.closed) throw new Error('Export service is closed')
    if (typeof sessionId !== 'string' || sessionId.length === 0 || typeof includeDescendants !== 'boolean') {
      throw new TypeError('A session and descendant selection are required')
    }
    const previous = this.records.get(id)
    if (previous) {
      if (previous.sessionId !== sessionId || previous.includeDescendants !== includeDescendants) {
        throw new Error('Export identity already belongs to a different request')
      }
      return previous.done
    }
    const record = { id, sessionId, includeDescendants, lifetime: new AbortController(), state: 'preparing' }
    this.records.set(id, record)
    record.done = this.write(record)
    return record.done
  }

  async write(record) {
    const signal = record.lifetime.signal
    try {
      const configured = await this.directory()
      if (typeof configured !== 'string' || !isAbsolute(configured)) throw new Error('Native export directory is unavailable')
      await mkdir(configured, { recursive: true, mode: 0o700 })
      const directory = await realpath(configured)
      signal.throwIfAborted()
      record.partial = join(directory, `${record.id}.partial`)
      record.complete = join(directory, `${record.id}.zip`)
      const deps = sessionLogExportDeps(this.ctx)
      if (!deps.sessionQuery || !deps.sessionPersistence || !deps.attachments) {
        throw new Error('Session export requires session query, persistence and attachment services')
      }
      await flushLiveSessionLog(deps, record.sessionId, signal)
      const content = await readSessionLogText(deps.sessionPersistence, record.sessionId, signal)
      signal.throwIfAborted()
      if (content === undefined) throw new Error('Session no longer exists')
      const archive = streamSessionLogZip(deps, content, record.sessionId, record.includeDescendants,
        DEFAULT_SESSION_LOG_COMPRESSION_LEVEL, signal)
      const target = await open(record.partial, 'wx', 0o600)
      record.partialOwned = true
      await pipeline(Readable.fromWeb(archive), target.createWriteStream(), { signal })
      signal.throwIfAborted()
      // Exclusive publication preserves another producer's completed artifact.
      await publishImmutableFile(record.partial, record.complete)
      record.completeOwned = true
      await unlink(record.partial)
      record.partialOwned = false
      signal.throwIfAborted()
      const metadata = await stat(record.complete)
      record.state = 'ready'
      return { id: record.id, filename: sessionLogZipFilename(record.sessionId), size: metadata.size }
    } catch (failure) {
      // The ZIP producer starts when its ReadableStream is created. Stop it even
      // when opening the destination fails before pipeline can own cancellation.
      record.lifetime.abort(failure)
      record.state = 'failed'
      await this.cleanup(record)
      throw failure
    }
  }

  /** Cancel only ZIP preparation or remove this producer's completed temporary archive. */
  async cancel({ id }) {
    identity(id)
    const record = this.records.get(id)
    if (!record) return { released: true }
    record.lifetime.abort(new Error('Session export cancelled'))
    await record.done.catch(_failure => { /* Preparation already reports its own failure to the App. */ })
    await this.cleanup(record)
    if (this.records.get(id) === record) this.records.delete(id)
    return { released: true }
  }

  /** The App releases after save, cancelled target selection, or abandoning an export page. */
  release(params) {
    return this.cancel(params)
  }

  async cleanup(record) {
    for (const [path, owned] of [[record.partial, 'partialOwned'], [record.complete, 'completeOwned']]) {
      if (!record[owned]) continue
      try { await unlink(path); record[owned] = false }
      catch (failure) { if (failure.code !== 'ENOENT') throw failure }
    }
  }

  async close() {
    this.closed = true
    await Promise.all([...this.records.keys()].map(id => this.cancel({ id })))
  }
}
