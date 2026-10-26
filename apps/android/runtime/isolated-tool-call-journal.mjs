import { createHash } from 'node:crypto'
import { open, mkdir, readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { IsolatedExecutionContractError } from './isolated-execution-contract.mjs'

const RUN_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const MAX_CALL_ID = 32
const SHA256 = /^[0-9a-f]{64}$/

function denied(code, message) {
  return new IsolatedExecutionContractError(code, message)
}

function key(runId, callId) {
  if (typeof runId !== 'string' || !RUN_ID.test(runId)
    || !Number.isSafeInteger(callId) || callId < 1 || callId > MAX_CALL_ID) {
    throw denied('ANDROID_TOOL_JOURNAL_INVALID', 'Invalid isolated callback journal key')
  }
  return { runId: runId.toLowerCase(), callId }
}

function digest(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex')
}

async function syncDirectory(path) {
  let handle
  try {
    handle = await open(path, 'r')
    await handle.sync()
  } catch (error) {
    // Windows cannot fsync directory handles. Android/Linux must succeed.
    if (process.platform !== 'win32' || !['EISDIR', 'EINVAL', 'EACCES', 'EPERM'].includes(error.code)) throw error
  } finally {
    await handle?.close()
  }
}

async function createMarker(path, data) {
  let handle
  try {
    handle = await open(path, 'wx', 0o600)
    await handle.writeFile(`${JSON.stringify(data)}\n`, 'utf8')
    await handle.sync()
  } catch (error) {
    if (error.code === 'EEXIST') throw denied('ANDROID_TOOL_REPLAY', 'Isolated callback was already prepared or dispatched')
    throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', `Isolated callback journal write failed: ${error.code ?? 'unknown'}`)
  } finally {
    await handle?.close()
  }
  try {
    await syncDirectory(dirname(path))
  } catch (error) {
    throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', `Isolated callback journal sync failed: ${error.code ?? 'unknown'}`)
  }
}

async function readMarker(path) {
  try {
    const data = await readFile(path, 'utf8')
    if (Buffer.byteLength(data) > 2048) throw Error('oversized')
    const value = JSON.parse(data)
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('invalid')
    return value
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Isolated callback journal is unreadable')
  }
}

/**
 * Exclusive, synced markers are the restart boundary for one native callback.
 * A dispatch marker means a side effect may have happened. No state is ever
 * replayed, including prepare-only and terminal calls.
 */
export class IsolatedToolCallJournal {
  #root

  constructor(root) {
    if (typeof root !== 'string' || !root) throw new TypeError('App-private callback journal root required')
    this.#root = resolve(root)
  }

  /** Claim a newly admitted run before native binding. A prior claim, even
   * without a prepared call, makes rebinding after a crash non-retryable. */
  async claimRun(runId) {
    const id = key(runId, 1)
    try {
      await mkdir(this.#root, { recursive: true, mode: 0o700 })
      await syncDirectory(dirname(this.#root))
      await mkdir(join(this.#root, id.runId), { mode: 0o700 })
      await syncDirectory(this.#root)
    } catch (error) {
      if (error.code === 'EEXIST') {
        throw denied('ANDROID_TOOL_REPLAY', 'Isolated callback run was already bound or prepared')
      }
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE',
        `Isolated callback run claim failed: ${error.code ?? 'unknown'}`)
    }
  }

  async #directory(runId) {
    try {
      await mkdir(this.#root, { recursive: true, mode: 0o700 })
      await syncDirectory(dirname(this.#root))
      const directory = join(this.#root, runId)
      await mkdir(directory, { recursive: true, mode: 0o700 })
      await syncDirectory(this.#root)
      return directory
    } catch (error) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', `Isolated callback journal directory failed: ${error.code ?? 'unknown'}`)
    }
  }

  async prepare({ runId, callId, parentCallId, name, arguments: args }) {
    const id = key(runId, callId)
    if (typeof parentCallId !== 'string' || !parentCallId
      || typeof name !== 'string' || !name) throw denied('ANDROID_TOOL_JOURNAL_INVALID', 'Invalid callback audit metadata')
    const directory = await this.#directory(id.runId)
    await createMarker(join(directory, `${id.callId}.prepare.json`), {
      version: 1, ...id, parentCallId, name, argumentsSha256: digest(args),
    })
  }

  async dispatch({ runId, callId }) {
    const id = key(runId, callId)
    const directory = await this.#directory(id.runId)
    const prepared = await readMarker(join(directory, `${id.callId}.prepare.json`))
    if (prepared?.version !== 1 || prepared.runId !== id.runId || prepared.callId !== id.callId) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Missing or corrupt callback preparation')
    }
    await createMarker(join(directory, `${id.callId}.dispatch.json`), { version: 1, ...id })
  }

  async observe({ runId, callId, result }) {
    const id = key(runId, callId)
    const directory = await this.#directory(id.runId)
    const dispatched = await readMarker(join(directory, `${id.callId}.dispatch.json`))
    if (dispatched?.version !== 1 || dispatched.runId !== id.runId || dispatched.callId !== id.callId) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Missing or corrupt callback dispatch')
    }
    await createMarker(join(directory, `${id.callId}.result.json`), {
      version: 1, ...id, resultSha256: digest(result),
    })
  }

  async confirm({ runId, callId, outcome, result }) {
    const id = key(runId, callId)
    if (!['success', 'tool-error', 'unsupported'].includes(outcome)) {
      throw denied('ANDROID_TOOL_JOURNAL_INVALID', 'Invalid callback confirmation')
    }
    const directory = await this.#directory(id.runId)
    const observed = await readMarker(join(directory, `${id.callId}.result.json`))
    if (observed?.version !== 1 || observed.runId !== id.runId || observed.callId !== id.callId) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Missing or corrupt callback result')
    }
    const resultSha256 = digest(result)
    if (!SHA256.test(observed.resultSha256) || observed.resultSha256 !== resultSha256) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Callback confirmation disagrees with observed result')
    }
    await createMarker(join(directory, `${id.callId}.confirm.json`), {
      version: 1, ...id, outcome, resultSha256,
    })
  }

  /** Read-only reconciliation; dispatch without confirm is always unconfirmed. */
  async inspect({ runId, callId }) {
    const id = key(runId, callId)
    const directory = join(this.#root, id.runId)
    const [prepared, dispatched, observed, confirmed] = await Promise.all([
      readMarker(join(directory, `${id.callId}.prepare.json`)),
      readMarker(join(directory, `${id.callId}.dispatch.json`)),
      readMarker(join(directory, `${id.callId}.result.json`)),
      readMarker(join(directory, `${id.callId}.confirm.json`)),
    ])
    for (const record of [prepared, dispatched, observed, confirmed]) {
      if (record && (record.version !== 1 || record.runId !== id.runId || record.callId !== id.callId)) {
        throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Corrupt callback journal identity')
      }
    }
    if ((dispatched && !prepared) || (observed && !dispatched) || (confirmed && !observed)) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Incomplete callback journal chain')
    }
    if ((prepared && (typeof prepared.parentCallId !== 'string' || !prepared.parentCallId
      || typeof prepared.name !== 'string' || !prepared.name || !SHA256.test(prepared.argumentsSha256)))
      || (observed && !SHA256.test(observed.resultSha256))
      || (confirmed && (!['success', 'tool-error', 'unsupported'].includes(confirmed.outcome)
        || !SHA256.test(confirmed.resultSha256)
        || confirmed.resultSha256 !== observed.resultSha256))) {
      throw denied('ANDROID_TOOL_JOURNAL_UNAVAILABLE', 'Corrupt callback journal content')
    }
    return Object.freeze({ ...id, state: confirmed ? 'confirmed'
      : observed ? 'result-unconfirmed' : dispatched ? 'dispatch-unconfirmed'
        : prepared ? 'prepared' : 'absent',
    ...(confirmed ? { outcome: confirmed.outcome } : {}) })
  }
}
