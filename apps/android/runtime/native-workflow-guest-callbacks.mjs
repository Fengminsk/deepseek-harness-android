import { WorkflowGuestHostPort } from './workflow-guest-host-port.mjs'
import { snapshotIsolatedJson } from './isolated-execution-contract.mjs'
import { consumeWorkflowModelRouteDenial } from './workflow-subagent-backend.mjs'

const MAX_BOUND_RUNS = 4
const MAX_PENDING_CALLS = 8
const MAX_CALLBACK_BYTES = 64 * 1024
const MAX_REPLY_BYTES = 64 * 1024
const BIND_TIMEOUT_MS = 10_000
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const ACTIONS = new Map([
  ['WORKFLOW_BEGIN', 'begin'],
  ['WORKFLOW_START_CHILD', 'startChild'],
  ['WORKFLOW_CHILD_RESULT', 'childResult'],
  ['WORKFLOW_DISPOSE_CHILD', 'disposeChild'],
  ['WORKFLOW_PROGRESS', 'progress'],
])

function exact(value, fields) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new TypeError('Invalid workflow callback frame')
  }
  const keys = Reflect.ownKeys(value)
  if (keys.length !== fields.length || keys.some(key => typeof key !== 'string'
    || !fields.includes(key) || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) {
    throw new TypeError('Invalid workflow callback frame')
  }
  return value
}

function identity(value) {
  const pair = exact(value, ['runId', 'token'])
  if (typeof pair.runId !== 'string' || !pair.runId || typeof pair.token !== 'string' || !pair.token) {
    throw new TypeError('Invalid workflow callback owner')
  }
  return pair
}

/**
 * App-owned Node endpoint for an already admitted isolated workflow. It does
 * not admit or execute guest code. The App must bind only after durable workflow
 * admission and route a callback only from the matching Binder run and token.
 */
export class NativeWorkflowGuestCallbacks {
  #transport
  #runs = new Map()
  #closed = false

  constructor(transport) {
    if (!transport || typeof transport.request !== 'function') throw new TypeError('Native transport required')
    this.#transport = transport
  }

  async bind({ prepared, admission, authorizeChild, activateChild, onProgress, signal }) {
    if (this.#closed || this.#runs.size >= MAX_BOUND_RUNS) throw new Error('Workflow callback capacity reached')
    const { runId, token } = identity(admission)
    if (prepared?.kind !== 'workflow' || prepared.runId !== runId) {
      throw new TypeError('Workflow admission does not match the prepared run')
    }
    if (this.#runs.has(runId)) throw new Error('Workflow callback is already bound')
    const port = new WorkflowGuestHostPort({ prepared, authorizeChild, activateChild, onProgress, signal })
    const entry = { token, port, state: 'binding', lastCallId: 0, pending: 0,
      reservations: new Set(),
      tail: Promise.resolve(), closePromise: null }
    this.#runs.set(runId, entry)
    try {
      const accepted = await this.#transport.request('native.workflow.bindCallbacks',
        { runId, token }, AbortSignal.timeout(BIND_TIMEOUT_MS))
      if (accepted !== true || this.#closed) throw new Error('Native workflow binding was not confirmed')
      entry.state = 'active'
    } catch (error) {
      entry.state = 'closing'
      try { await port.close() } finally {
        if (this.#runs.get(runId) === entry) this.#runs.delete(runId)
      }
      throw error
    }
    return Object.freeze({ runId, close: () => this.#closeEntry(runId, entry) })
  }

  async call(value) {
    const frame = exact(value, value?.action === 'WORKFLOW_START_CHILD'
      ? ['runId', 'token', 'callId', 'action', 'value', 'childId']
      : ['runId', 'token', 'callId', 'action', 'value'])
    const { runId, token } = identity({ runId: frame.runId, token: frame.token })
    const entry = this.#runs.get(runId)
    if (!entry || entry.token !== token || entry.state !== 'active') {
      throw new Error('Workflow callback has no live admitted owner')
    }
    if (!Number.isSafeInteger(frame.callId) || frame.callId !== entry.lastCallId + 1
      || frame.callId > 128 || !ACTIONS.has(frame.action)) {
      throw new TypeError('Invalid workflow callback sequence or action')
    }
    if (frame.action === 'WORKFLOW_START_CHILD' && !UUID.test(frame.childId)) {
      throw new TypeError('Workflow child has no App-issued reservation')
    }
    if (frame.action === 'WORKFLOW_START_CHILD' && entry.reservations.has(frame.childId)) {
      throw new TypeError('Workflow child reservation was already consumed')
    }
    // Snapshot before reserving the sequence: a rejected frame must neither
    // consume a call id nor leave a mutable object waiting in the async queue.
    const request = snapshotIsolatedJson(frame.value, 'workflow callback request', MAX_CALLBACK_BYTES)
    if (entry.pending >= MAX_PENDING_CALLS) throw new Error('Workflow callback queue is full')
    entry.lastCallId = frame.callId
    if (frame.action === 'WORKFLOW_START_CHILD') entry.reservations.add(frame.childId)
    entry.pending += 1
    const method = ACTIONS.get(frame.action)
    const dispatch = entry.tail.then(async () => {
      if (entry.state !== 'active') throw new Error('Workflow callback closed before dispatch')
      let result
      try {
        result = await entry.port[method](request,
          frame.action === 'WORKFLOW_START_CHILD' ? frame.childId : undefined)
      } catch (error) {
        if (entry.state === 'active' && frame.action === 'WORKFLOW_START_CHILD'
          && consumeWorkflowModelRouteDenial(error, runId, frame.childId)) {
          // The App must still stop the guest and join every sibling before a
          // terminal failure. This envelope only proves this child did not activate.
          return { runId, callId: frame.callId,
            denied: { code: 'MODEL_ROUTE_DENIED', childId: frame.childId } }
        }
        throw error
      }
      if (entry.state !== 'active') throw new Error('Workflow callback closed during dispatch')
      const boundedReply = snapshotIsolatedJson(result ?? null, 'workflow callback reply', MAX_REPLY_BYTES)
      return { runId, callId: frame.callId,
        value: JSON.parse(JSON.stringify(boundedReply)) }
    })
    entry.tail = dispatch.then(() => {}, () => {})
    try { return await dispatch } finally { entry.pending -= 1 }
  }

  async close(value) {
    const { runId, token } = identity(value)
    const entry = this.#runs.get(runId)
    if (!entry || entry.token !== token) throw new Error('Workflow callback has no live admitted owner')
    await this.#closeEntry(runId, entry)
    return { closed: true }
  }

  #closeEntry(runId, entry) {
    if (entry.closePromise) return entry.closePromise
    entry.state = 'closing'
    entry.closePromise = Promise.resolve().then(async () => {
      let failure
      try { await entry.port.close() } catch (error) { failure = error }
      await entry.tail
      if (failure) throw failure
    })
      .finally(() => { if (this.#runs.get(runId) === entry) this.#runs.delete(runId) })
    return entry.closePromise
  }

  async dispose() {
    this.#closed = true
    const results = await Promise.allSettled([...this.#runs.entries()].map(([runId, entry]) =>
      this.#closeEntry(runId, entry)))
    const failure = results.find(result => result.status === 'rejected')
    if (failure) throw failure.reason
  }
}
