/** Trusted callbacks for one admitted Android workflow guest. No model-facing tool registers this port. */
import { snapshotIsolatedJson } from './isolated-execution-contract.mjs'
import { WorkflowChildPort } from './workflow-child-port.mjs'

const encoder = new TextEncoder()
const MAX_PROGRESS_BATCH = 64
const MAX_PROGRESS_EVENTS = 2048

function invalid(message) {
  throw Object.assign(new TypeError(message), { code: 'ANDROID_WORKFLOW_PROGRESS_INVALID' })
}

function record(value, keys) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) invalid('Expected an object')
  for (const key of Reflect.ownKeys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (typeof key !== 'string' || !keys.includes(key) || !descriptor || !Object.hasOwn(descriptor, 'value')) {
      invalid('Unexpected progress field')
    }
  }
  return value
}

function text(value, name, maxBytes) {
  if (typeof value !== 'string' || !value.trim() || encoder.encode(value).length > maxBytes) {
    invalid(`Invalid ${name}`)
  }
  return value
}

function sequence(value) {
  if (!Number.isSafeInteger(value) || value < 1 || value > 128) invalid('Invalid agent sequence')
  return value
}

function agentInfo(value, ending) {
  const info = record(value, ending
    ? ['seq', 'label', 'phase', 'childId', 'outcome']
    : ['seq', 'label', 'phase', 'childId'])
  const result = {
    seq: sequence(info.seq),
    label: text(info.label, 'agent label', 256),
    childId: text(info.childId, 'child identity', 256),
  }
  if (info.phase !== undefined) result.phase = text(info.phase, 'agent phase', 128)
  if (ending) {
    if (!['completed', 'failed', 'cancelled'].includes(info.outcome)) invalid('Invalid agent outcome')
    result.outcome = info.outcome
  }
  return result
}

function sameAgent(left, right) {
  return left.seq === right.seq && left.label === right.label
    && left.childId === right.childId && left.phase === right.phase
}

/**
 * Accepts bounded, ordered guest progress and delegates child ownership to a
 * trusted child port. The caller must durably admit the run and provide a
 * confined child backend; neither is supplied here. Callback failure makes
 * terminal publication unconfirmed and close() rejects after cleanup.
 */
export class WorkflowGuestHostPort {
  #prepared
  #children
  #onProgress
  #published = new Set()
  #startedChildren = new Set()
  #live = new Map()
  #seen = new Set()
  #tail = Promise.resolve()
  #begun = false
  #closed = false
  #closePromise = null
  #progressFailure = null
  #eventCount = 0

  constructor({ prepared, authorizeChild, activateChild, onProgress, signal }) {
    if (prepared?.kind !== 'workflow' || typeof onProgress !== 'function') {
      throw new TypeError('An admitted workflow and progress observer are required')
    }
    this.#prepared = prepared
    this.#onProgress = onProgress
    this.#children = new WorkflowChildPort({
      authorize: authorizeChild,
      activate: activateChild,
      maxTotalAgents: prepared.maxTotalAgents,
      maxConcurrentAgents: prepared.maxConcurrentAgents,
      signal,
    })
  }

  begin(value) {
    if (this.#closed || this.#begun) invalid('Workflow initialization is unavailable')
    record(value, [])
    this.#begun = true
    return snapshotIsolatedJson({
      meta: this.#prepared.meta,
      args: this.#prepared.args,
      limits: {
        maxTotalAgents: this.#prepared.maxTotalAgents,
        maxConcurrentAgents: this.#prepared.maxConcurrentAgents,
        maxItemsPerCall: 32,
        syncTimeoutMs: this.#prepared.deadlineMillis,
      },
    }, 'workflow initialization')
  }

  #active() {
    if (!this.#begun || this.#closed || this.#progressFailure) invalid('Workflow callbacks are unavailable')
  }

  async startChild(request, reservedChildId) {
    this.#active()
    const published = await this.#children.start(request, reservedChildId)
    if (this.#closed) invalid('Workflow closed during child start')
    if (this.#published.has(published.childId)) {
      await this.#children.dispose(published.callId)
      invalid('Child identity reused')
    }
    this.#published.add(published.childId)
    return published
  }

  childResult(value) {
    this.#active()
    const request = record(value, ['callId'])
    return this.#children.result(sequence(request.callId))
  }

  async disposeChild(value) {
    const request = record(value, ['callId'])
    await this.#children.dispose(sequence(request.callId))
    return null
  }

  progress(value) {
    this.#active()
    let batch
    try {
      batch = snapshotIsolatedJson(value, 'workflow progress', 64 * 1024)
      if (!Array.isArray(batch) || batch.length > MAX_PROGRESS_BATCH) invalid('Invalid progress batch')
    } catch (error) {
      this.#progressFailure ??= error
      this.#children.cancel()
      throw error
    }
    const next = this.#tail.then(() => this.#deliver(batch))
    this.#tail = next.catch(error => {
      this.#progressFailure ??= error
      this.#children.cancel()
    })
    return next
  }

  async #deliver(batch) {
    this.#active()
    if (this.#eventCount + batch.length > MAX_PROGRESS_EVENTS) invalid('Progress event limit reached')
    const live = new Map(this.#live)
    const seen = new Set(this.#seen)
    const startedChildren = new Set(this.#startedChildren)
    const events = batch.map(value => {
      const event = record(value, ['type', 'title', 'message', 'info'])
      let normalized
      switch (event.type) {
        case 'phase': normalized = { type: 'phase', title: text(event.title, 'phase', 128) }; break
        case 'log': normalized = { type: 'log', message: text(event.message, 'log', 1024) }; break
        case 'agent-start': {
          const info = agentInfo(event.info, false)
          if (!this.#published.has(info.childId) || startedChildren.has(info.childId)
            || seen.has(info.seq)
            || [...seen].some(seq => seq >= info.seq)) invalid('Unowned or out-of-order agent start')
          seen.add(info.seq)
          startedChildren.add(info.childId)
          live.set(info.seq, info)
          normalized = { type: 'agent-start', info }
          break
        }
        case 'agent-end': {
          const info = agentInfo(event.info, true)
          if (!sameAgent(live.get(info.seq) ?? {}, info)) invalid('Unpaired agent end')
          live.delete(info.seq)
          normalized = { type: 'agent-end', info }
          break
        }
        default: invalid('Unknown progress event')
      }
      if (event.type === 'phase' && (event.message !== undefined || event.info !== undefined)
        || event.type === 'log' && (event.title !== undefined || event.info !== undefined)
        || event.type.startsWith('agent-') && (event.title !== undefined || event.message !== undefined)) {
        invalid('Unexpected progress field')
      }
      return normalized
    })
    for (const event of events) {
      if (this.#closed || this.#progressFailure) invalid('Workflow stopped during progress delivery')
      try { await this.#onProgress(event) }
      catch (error) {
        this.#progressFailure = error
        this.#children.cancel()
        throw error
      }
      if (event.type === 'agent-start') {
        this.#seen.add(event.info.seq)
        this.#startedChildren.add(event.info.childId)
        this.#live.set(event.info.seq, event.info)
      } else if (event.type === 'agent-end') this.#live.delete(event.info.seq)
      this.#eventCount += 1
    }
  }

  /** Stop callbacks and children, await retirement, and close live progress pairs. */
  close() {
    if (this.#closePromise) return this.#closePromise
    this.#closed = true
    this.#children.cancel()
    this.#closePromise = (async () => {
      await this.#tail
      let childFailure
      try { await this.#children.close() } catch (error) { childFailure = error }
      if (!this.#progressFailure) {
        for (const info of this.#live.values()) {
          try { await this.#onProgress({ type: 'agent-end', info: { ...info, outcome: 'cancelled' } }) }
          catch (error) { this.#progressFailure = error; break }
        }
      }
      if (childFailure || this.#progressFailure) {
        throw Object.assign(new AggregateError([childFailure, this.#progressFailure].filter(Boolean),
          'Workflow retirement or progress is unconfirmed'), {
          code: 'ANDROID_WORKFLOW_RETIRE_UNCONFIRMED',
        })
      }
    })()
    return this.#closePromise
  }
}
