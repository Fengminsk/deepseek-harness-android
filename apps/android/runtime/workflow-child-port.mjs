/**
 * Internal host-side ownership for children started by an isolated workflow.
 * The caller must supply an App policy check and a confined child activation;
 * authorization must verify parent ownership, the supported schema subset,
 * child scope, inherited tools and durable admission before returning true.
 * This class is not an App RPC or a model-facing tool. The Android backend
 * uses dedicated plain and structured child presets to prevent tool widening.
 */
import { snapshotIsolatedJson } from './isolated-execution-contract.mjs'
import { assertObjectJsonSchema, JsonSchemaError } from '@deepseek-ai/dsh-tools'

const encoder = new TextEncoder()
const MAX_CHILD_PROMPT_BYTES = 64 * 1024
const MAX_CHILD_RESULT_BYTES = 64 * 1024

function invalid(message) {
  throw Object.assign(new TypeError(message), { code: 'ANDROID_WORKFLOW_CHILD_INVALID' })
}

function requireText(value, name, limit) {
  if (typeof value !== 'string' || !value.trim() || encoder.encode(value).length > limit) {
    invalid(`${name} must be non-empty text within ${limit} bytes`)
  }
  return value
}

function copyJson(value, name) {
  try { return snapshotIsolatedJson(value, name, MAX_CHILD_RESULT_BYTES) }
  catch { invalid(`${name} must be bounded lossless JSON`) }
}

function childRequest(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) invalid('Child request must be an object')
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string' || !['prompt', 'provider', 'model', 'schema'].includes(key)
      || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key) ?? {}, 'value')) invalid('Unknown child request field')
  }
  const request = { prompt: requireText(value.prompt, 'prompt', MAX_CHILD_PROMPT_BYTES) }
  if (value.provider !== undefined) request.provider = requireText(value.provider, 'provider', 128)
  if (value.model !== undefined) request.model = requireText(value.model, 'model', 128)
  if (value.schema !== undefined) {
    const schema = copyJson(value.schema, 'schema')
    try { assertObjectJsonSchema(schema) }
    catch (error) {
      if (!(error instanceof JsonSchemaError)) throw error
      invalid(`Child schema is outside the supported JSON Schema subset: ${error.message}`)
    }
    request.schema = schema
  }
  return Object.freeze(request)
}

function cancelled() {
  return Object.assign(new Error('Workflow child port is cancelled'), { code: 'ANDROID_WORKFLOW_CANCELLED' })
}

function childResult(value) {
  if (value === null || typeof value !== 'object'
    || typeof value.stopReason !== 'string' || !value.stopReason
    || encoder.encode(value.stopReason).length > 128) {
    invalid('Child result has no bounded stop reason')
  }
  const output = copyJson(value.output, 'child output')
  if (!Array.isArray(output)) invalid('Child output must be content blocks')
  const response = { output, stopReason: value.stopReason }
  if (value.structured !== undefined) response.structured = copyJson(value.structured, 'structured output')
  return response
}

/**
 * A one-run port that owns every published child until disposal. A rejected
 * activation never creates a call id visible to the script. Cancellation
 * drains children published after an asynchronous start raced with abort.
 */
export class WorkflowChildPort {
  constructor({ authorize, activate, maxTotalAgents, maxConcurrentAgents, signal }) {
    if (typeof authorize !== 'function' || typeof activate !== 'function') {
      throw new TypeError('Workflow child port needs trusted policy and activation adapters')
    }
    if (!Number.isSafeInteger(maxTotalAgents) || maxTotalAgents < 1 || maxTotalAgents > 128
      || !Number.isSafeInteger(maxConcurrentAgents) || maxConcurrentAgents < 1
      || maxConcurrentAgents > 8 || maxConcurrentAgents > maxTotalAgents) {
      throw new RangeError('Invalid workflow child limits')
    }
    this.authorize = authorize
    this.activate = activate
    this.maxTotalAgents = maxTotalAgents
    this.maxConcurrentAgents = maxConcurrentAgents
    this.controller = new AbortController()
    this.children = new Map()
    this.pendingStarts = new Set()
    this.disposals = new Set()
    this.disposalFailures = []
    this.waiters = []
    this.slots = 0
    this.started = 0
    this.closed = false
    this.externalSignal = signal
    this.externalAbort = () => { this.cancel() }
    if (signal?.aborted) this.cancel()
    else signal?.addEventListener('abort', this.externalAbort, { once: true })
  }

  async acquire() {
    if (this.closed) throw cancelled()
    if (this.slots < this.maxConcurrentAgents) {
      this.slots += 1
      return
    }
    await new Promise((resolve, reject) => { this.waiters.push({ resolve, reject }) })
    // release() transfers an occupied permit directly to this waiter. If
    // cancellation wins before this continuation runs, return that permit.
    if (this.closed) {
      this.release()
      throw cancelled()
    }
  }

  release() {
    const waiter = this.waiters.shift()
    if (waiter) waiter.resolve()
    else this.slots -= 1
  }

  /** Authorize and activate one child; publication is the returned handle. */
  async start(value, reservedChildId) {
    const request = childRequest(value)
    if (this.closed || this.started >= this.maxTotalAgents) {
      if (this.closed) throw cancelled()
      throw Object.assign(new Error('Workflow reached its total child limit'), { code: 'ANDROID_WORKFLOW_CHILD_CAP' })
    }
    const callId = ++this.started
    const start = this.startReserved(callId, request, reservedChildId)
    this.pendingStarts.add(start)
    try { return await start }
    finally { this.pendingStarts.delete(start) }
  }

  async startReserved(callId, request, reservedChildId) {
    await this.acquire()
    let published = false
    try {
      if (this.closed) throw cancelled()
      if (await this.authorize(request, this.controller.signal, reservedChildId) !== true) {
        throw Object.assign(new Error('Workflow child was not authorized'), { code: 'ANDROID_WORKFLOW_CHILD_DENIED' })
      }
      if (this.closed) throw cancelled()
      const run = await this.activate(request, this.controller.signal)
      if (run === null || typeof run !== 'object' || typeof run.childId !== 'string'
        || !run.childId || typeof run.dispose !== 'function' || !run.result
        || typeof run.result.then !== 'function') {
        if (run !== null && typeof run === 'object' && typeof run.dispose === 'function') {
          // A partial handle still gives this port one exact retirement path.
          const record = { callId, run, disposal: null, resultController: new AbortController() }
          this.children.set(callId, record)
          if (run.result && typeof run.result.then === 'function') {
            void Promise.resolve(run.result).catch(() => {})
          }
          published = true
          await this.dispose(callId)
          invalid('Activation did not publish a child handle')
        }
        // No disposal capability can prove that a child was not created.
        // Retain the acquired slot and fail the owner closed.
        if (run !== null && typeof run === 'object'
          && run.result && typeof run.result.then === 'function') {
          void Promise.resolve(run.result).catch(() => {})
        }
        this.disposalFailures.push(new Error('Activation returned no disposable child handle'))
        published = true
        this.cancel()
        invalid('Activation did not publish a child handle')
      }
      // A child can be published after cancellation; that handle still belongs
      // to this port and must be disposed before the start is rejected.
      const record = { callId, run, disposal: null, resultController: new AbortController() }
      this.children.set(callId, record)
      void Promise.resolve(run.result).catch(() => {})
      published = true
      // Keep a mismatched activation under this port until its retirement is
      // confirmed. A failed dispose must not free a slot or lose the handle.
      if (reservedChildId !== undefined && run.childId !== reservedChildId) {
        await this.dispose(callId)
        invalid('Child publication changed the durable App reservation')
      }
      if (this.closed) {
        await this.dispose(callId)
        throw cancelled()
      }
      return { callId, childId: run.childId }
    } finally {
      if (!published) this.release()
    }
  }

  async result(callId) {
    const record = this.children.get(callId)
    if (this.closed) throw cancelled()
    if (!record) invalid('Workflow child call is not active')
    if (record.disposal) throw cancelled()
    const signal = this.controller.signal
    const aborted = Promise.withResolvers()
    const onAbort = () => { aborted.reject(cancelled()) }
    signal.addEventListener('abort', onAbort, { once: true })
    record.resultController.signal.addEventListener('abort', onAbort, { once: true })
    try {
      if (signal.aborted || record.resultController.signal.aborted) throw cancelled()
      const result = await Promise.race([record.run.result, aborted.promise])
      if (this.closed || record.disposal) throw cancelled()
      return childResult(result)
    } finally {
      signal.removeEventListener('abort', onAbort)
      record.resultController.signal.removeEventListener('abort', onAbort)
    }
  }

  dispose(callId) {
    const record = this.children.get(callId)
    if (!record) return Promise.resolve()
    if (!record.disposal) {
      // Once disposal starts, no pending result may publish a late child value.
      record.resultController.abort(cancelled())
      let retired = false
      record.disposal = Promise.resolve().then(() => record.run.dispose()).catch((error) => {
        this.disposalFailures.push(error)
        // A failed backend disposal cannot free a concurrency slot: the child
        // might still be running. Stop all further starts and drain peers.
        this.cancel()
        throw error
      }).then(() => { retired = true }).finally(() => {
        if (retired) {
          this.children.delete(callId)
          this.release()
        }
        this.disposals.delete(record.disposal)
      })
      this.disposals.add(record.disposal)
    }
    return record.disposal
  }

  /** Stop active work immediately; close() additionally waits for cleanup. */
  cancel() {
    if (this.closed) return
    this.closed = true
    this.controller.abort(cancelled())
    for (const waiter of this.waiters.splice(0)) waiter.reject(cancelled())
    for (const callId of this.children.keys()) void this.dispose(callId).catch(() => {})
  }

  /** Wait for starts, including a late publication, and all child disposal.
   * Reject when any published child's disposal failed: quiescence is unconfirmed.
   */
  async close() {
    this.cancel()
    this.externalSignal?.removeEventListener('abort', this.externalAbort)
    await Promise.allSettled([...this.pendingStarts])
    await Promise.allSettled([...this.disposals])
    if (this.disposalFailures.length) {
      throw Object.assign(new AggregateError(this.disposalFailures, 'Workflow child retirement is unconfirmed'), {
        code: 'ANDROID_WORKFLOW_CHILD_RETIRE_UNCONFIRMED',
      })
    }
  }
}
