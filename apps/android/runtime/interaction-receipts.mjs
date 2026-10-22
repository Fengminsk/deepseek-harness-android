import { createHash, randomUUID } from 'node:crypto'
import { mkdir, open, readFile, readdir, rename, rm } from 'node:fs/promises'
import { join } from 'node:path'

const identityHash = identity => createHash('sha256').update(JSON.stringify(identity)).digest('hex')

/**
 * A write-ahead, App-private guard for human answers. The Session and the
 * original interaction owners decide whether an answer was accepted; this
 * journal only proves that Android might already have sent it. In particular,
 * a pending snapshot never removes a marker after a lost acknowledgement.
 */
export class InteractionReceipts {
  constructor() {
    this.directory = undefined
    this.entries = new Map()
  }

  async initialize(privateRoot) {
    if (typeof privateRoot !== 'string' || !privateRoot) throw new TypeError('Private storage root is required')
    this.directory = join(privateRoot, 'interaction-replies-v1')
    await mkdir(this.directory, { recursive: true, mode: 0o700 })
    for (const name of await readdir(this.directory)) {
      if (!/^[a-f0-9]{64}\.json$/.test(name)) continue
      const hash = name.slice(0, -5)
      try {
        const entry = JSON.parse(await readFile(join(this.directory, name), 'utf8'))
        if (entry.version !== 1 || !Array.isArray(entry.identity)
          || identityHash(entry.identity) !== hash
          || !['started', 'accepted'].includes(entry.phase)) throw new Error('Invalid receipt')
        this.entries.set(hash, entry.phase)
      } catch {
        // An incomplete marker is evidence of a possible prior submission.
        // Keep just its filename-derived identity blocked; other requests work.
        this.entries.set(hash, 'started')
      }
    }
  }

  phase(identity) {
    return this.entries.get(identityHash(identity))
  }

  async begin(identity) {
    if (!this.directory) throw new Error('Private interaction receipt storage is not ready')
    const hash = identityHash(identity)
    if (this.entries.has(hash)) return false
    const file = join(this.directory, `${hash}.json`)
    let handle
    try {
      handle = await open(file, 'wx', 0o600)
      await handle.writeFile(JSON.stringify({ version: 1, identity, phase: 'started' }) + '\n')
      await handle.sync()
      if (process.platform !== 'win32') {
        // On Android the directory entry must survive a process/device crash
        // before any human decision crosses the original DSH carrier.
        const directoryHandle = await open(this.directory, 'r')
        try { await directoryHandle.sync() } finally { await directoryHandle.close() }
      }
      this.entries.set(hash, 'started')
      return true
    } catch (error) {
      // An incomplete marker or lost write receipt is uncertain, not a reason
      // to retry an interaction that might have crossed the carrier boundary.
      this.entries.set(hash, 'started')
      if (error.code === 'EEXIST') return false
      throw error
    } finally {
      await handle?.close()
    }
  }

  async accepted(identity) {
    if (!this.directory) throw new Error('Private interaction receipt storage is not ready')
    const hash = identityHash(identity)
    if (!this.entries.has(hash)) throw new Error('Missing interaction receipt')
    const file = join(this.directory, `${hash}.json`)
    const temporary = join(this.directory, `${hash}.${randomUUID()}.tmp`)
    let handle
    try {
      handle = await open(temporary, 'wx', 0o600)
      await handle.writeFile(JSON.stringify({ version: 1, identity, phase: 'accepted' }) + '\n')
      await handle.sync()
      await handle.close()
      handle = undefined
      for (let attempt = 0;; attempt++) {
        try {
          await rename(temporary, file)
          break
        } catch (error) {
          if (process.platform !== 'win32' || !['EPERM', 'EACCES', 'EBUSY'].includes(error.code)
            || attempt >= 8) throw error
          await new Promise(resolve => setTimeout(resolve, Math.min(20 * 2 ** attempt, 200)))
        }
      }
    } finally {
      await handle?.close()
      await rm(temporary, { force: true })
    }
    this.entries.set(hash, 'accepted')
  }
}

/** The original approval audit id disambiguates repeat asks about one call. */
export function approvalAuditIdentity(agent, request) {
  if (!agent?.session) return undefined
  const decided = new Set()
  const matching = []
  for (let seq = agent.session.seq - 1; seq >= 0; seq--) {
    const event = agent.session.eventAt(seq)
    if (event?.type === 'approval/decided') decided.add(event.data.id)
    if (event?.type !== 'approval/asked' || decided.has(event.data.id)) continue
    if (event.data.toolName === request.toolName
      && event.data.callId === request.callId
      && event.data.reason === request.reason) matching.push(event.data.id)
  }
  return matching.length === 1 ? String(matching[0]) : undefined
}

export function interactionReceiptIdentity(record) {
  if (record.kind === 'approval') {
    return record.approvalAuditId
      ? ['approval', record.sessionId, record.approvalAuditId] : undefined
  }
  if (record.callId) return ['question', record.sessionId, record.callId]
  return record.eventId ? ['unnamed-question', record.sessionId, record.eventId] : undefined
}
