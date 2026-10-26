/**
 * App-private adapter for the original workflow JavaScript DSL. The exported
 * program is trusted source; the model body arrives only through WORKFLOW_BEGIN
 * inside the isolated V8 worker. Neither this module nor its caller evaluates
 * that body in the App/Node process.
 */

function workflowDslGuest(input, host) {
  return (async () => {
    const MAX_CALLS = 128
    const MAX_ITEMS = 32
    const MAX_NODES = 8192
    const AsyncFunction = (async () => {}).constructor
    class WorkflowFault extends Error {
      constructor(code, message) { super(message); this.code = code }
    }
    const fail = (code, message) => { throw new WorkflowFault(code, message) }
    const plain = value => value !== null && typeof value === 'object'
      && !Array.isArray(value) && (Object.getPrototypeOf(value) === Object.prototype
        || Object.getPrototypeOf(value) === null)
    const json = (value, name) => {
      const seen = new WeakSet()
      let nodes = MAX_NODES
      function copy(current, depth) {
        if (--nodes < 0 || depth > 24) fail('INVALID_JSON', `${name} is too large`)
        if (current === null || typeof current === 'string' || typeof current === 'boolean') return current
        if (typeof current === 'number' && Number.isFinite(current) && !Object.is(current, -0)) return current
        if (typeof current !== 'object' || seen.has(current)) fail('INVALID_JSON', `${name} is not plain JSON`)
        seen.add(current)
        try {
          if (Array.isArray(current)) {
            if (Object.keys(current).length !== current.length) fail('INVALID_JSON', `${name} is not a dense array`)
            return Array.from({ length: current.length }, (_, index) => {
              const slot = Object.getOwnPropertyDescriptor(current, String(index))
              if (!slot || !Object.hasOwn(slot, 'value')) fail('INVALID_JSON', `${name} has an accessor`)
              return copy(slot.value, depth + 1)
            })
          }
          if (!plain(current)) fail('INVALID_JSON', `${name} is not a plain object`)
          const result = Object.create(null)
          for (const key of Reflect.ownKeys(current)) {
            const slot = Object.getOwnPropertyDescriptor(current, key)
            if (typeof key !== 'string' || !slot || !slot.enumerable || !Object.hasOwn(slot, 'value')) {
              fail('INVALID_JSON', `${name} has an unsupported member`)
            }
            result[key] = copy(slot.value, depth + 1)
          }
          return result
        } finally {
          // Track only the current ancestry. A shared value in two branches is
          // ordinary JSON data after each branch has been materialized.
          seen.delete(current)
        }
      }
      return copy(value, 0)
    }
    let callbackId = 0
    let callbackTail = Promise.resolve()
    let callbackFault = null
    const callback = (action, value) => {
      const run = callbackTail.then(async () => {
        if (callbackFault) throw callbackFault
        if (++callbackId > MAX_CALLS) fail('CALL_CAP', 'Workflow callback budget exhausted')
        const reply = await host.callAsync({ action, callId: callbackId, value })
        if (!plain(reply) || !Object.hasOwn(reply, 'value')) fail('BAD_REPLY', 'Workflow callback reply is invalid')
        return reply.value
      })
      callbackTail = run.catch(error => { callbackFault ??= error })
      return run
    }
    const initialization = await callback('WORKFLOW_BEGIN', {})
    if (!plain(input) || Reflect.ownKeys(input).length !== 0 || !plain(initialization)
      || typeof initialization.body !== 'string' || !plain(initialization.limits)) {
      fail('BAD_BEGIN', 'Workflow initialization is invalid')
    }
    const limits = initialization.limits
    if (!Number.isSafeInteger(limits.maxTotalAgents) || limits.maxTotalAgents < 1 || limits.maxTotalAgents > 128
      || !Number.isSafeInteger(limits.maxConcurrentAgents) || limits.maxConcurrentAgents < 1
      || limits.maxConcurrentAgents > 8 || limits.maxConcurrentAgents > limits.maxTotalAgents
      || limits.maxItemsPerCall !== MAX_ITEMS) fail('BAD_LIMITS', 'Workflow limits are invalid')
    const args = json(initialization.args, 'workflow args')
    let started = 0
    let active = 0
    let currentPhase
    let fatalFault = null
    const waiters = []
    const pendingWork = new Set()
    const pendingProgress = new Set()
    const track = (promise, target = pendingWork) => {
      target.add(promise)
      promise.then(() => target.delete(promise), () => target.delete(promise))
      promise.catch(() => {})
      return promise
    }
    const acquire = async () => {
      if (active < limits.maxConcurrentAgents) { active++; return }
      await new Promise(resolve => waiters.push(resolve))
      active++
    }
    const release = () => { active--; waiters.shift()?.() }
    const event = value => track(callback('WORKFLOW_PROGRESS', [value]), pendingProgress)
    const labelFor = prompt => {
      const line = prompt.split('\n', 1)[0]
      return line.length <= 48 ? line : `${line.slice(0, 47)}…`
    }
    const optionsFor = raw => {
      if (raw === undefined) return {}
      if (!plain(raw)) fail('INVALID_ARGUMENT', 'agent() options must be an object')
      const opts = json(raw, 'agent() options')
      for (const key of Object.keys(opts)) {
        if (key === 'schema') {
          if (!plain(opts.schema) || opts.schema.type !== 'object') {
            fail('UNSUPPORTED_SCHEMA', 'agent() schema must have an object root')
          }
          continue
        }
        if (!['label', 'phase', 'provider', 'model'].includes(key)) {
          fail('UNSUPPORTED_OPTION', `Unsupported agent() option: ${key}`)
        }
        if (typeof opts[key] !== 'string' || !opts[key].trim()) {
          fail('INVALID_ARGUMENT', `agent() option ${key} must be non-empty text`)
        }
      }
      return opts
    }
    const agent = (prompt, rawOptions) => track((async () => {
      if (typeof prompt !== 'string' || !prompt.trim()) fail('INVALID_ARGUMENT', 'agent() requires a prompt')
      const opts = optionsFor(rawOptions)
      if (started >= limits.maxTotalAgents) fail('AGENT_CAP', 'Workflow child budget exhausted')
      const seq = ++started
      const label = opts.label ?? labelFor(prompt)
      const phaseName = opts.phase ?? currentPhase
      await acquire()
      let child
      try {
        child = await callback('WORKFLOW_START_CHILD', {
          prompt, ...(opts.provider === undefined ? {} : { provider: opts.provider }),
          ...(opts.model === undefined ? {} : { model: opts.model }),
          ...(opts.schema === undefined ? {} : { schema: opts.schema }),
        })
        if (!plain(child) || !Number.isSafeInteger(child.callId) || child.callId < 1
          || typeof child.childId !== 'string' || !child.childId) {
          fail('BAD_CHILD', 'Workflow child publication is invalid')
        }
        const info = { seq, label, ...(phaseName === undefined ? {} : { phase: phaseName }),
          childId: child.childId }
        await event({ type: 'agent-start', info })
        let result
        try { result = await callback('WORKFLOW_CHILD_RESULT', { callId: child.callId }) }
        catch (error) {
          // A callback failure is infrastructure failure, never an ordinary
          // per-item null. The native owner retires any live child on close.
          throw error
        }
        const completed = plain(result) && result.stopReason === 'completed'
          && (opts.schema === undefined || result.structured !== undefined)
        await event({ type: 'agent-end', info: { ...info, outcome: completed ? 'completed' : 'failed' } })
        if (!completed) return null
        if (opts.schema !== undefined) return json(result.structured, 'structured child output')
        if (!Array.isArray(result.output)) fail('BAD_CHILD', 'Workflow child output is invalid')
        return result.output.filter(block => block?.type === 'text').map(block => block.text).join('')
      } finally {
        if (child) await callback('WORKFLOW_DISPOSE_CHILD', { callId: child.callId })
        release()
      }
    })().catch(error => {
      if (error instanceof WorkflowFault || callbackFault) fatalFault ??= error
      throw error
    }))
    const parallel = thunks => track((async () => {
      if (!Array.isArray(thunks)) fail('INVALID_ARGUMENT', 'parallel() requires an array')
      if (thunks.length > limits.maxItemsPerCall) fail('ITEM_CAP', 'parallel() item budget exhausted')
      if (thunks.some(thunk => typeof thunk !== 'function')) fail('INVALID_ARGUMENT', 'parallel() items must be functions')
      return Promise.all(thunks.map(async thunk => {
        try { return await thunk() }
        catch (error) { if (error instanceof WorkflowFault || callbackFault) throw error; return null }
      }))
    })().catch(error => {
      if (error instanceof WorkflowFault || callbackFault) fatalFault ??= error
      throw error
    }))
    const pipeline = (items, ...stages) => track((async () => {
      if (!Array.isArray(items) || !stages.length || stages.some(stage => typeof stage !== 'function')) {
        fail('INVALID_ARGUMENT', 'pipeline() requires items and stage functions')
      }
      if (items.length > limits.maxItemsPerCall) fail('ITEM_CAP', 'pipeline() item budget exhausted')
      return Promise.all(items.map(async (item, index) => {
        let value = item
        try { for (const stage of stages) value = await stage(value, item, index); return value }
        catch (error) { if (error instanceof WorkflowFault || callbackFault) throw error; return null }
      }))
    })().catch(error => {
      if (error instanceof WorkflowFault || callbackFault) fatalFault ??= error
      throw error
    }))
    const phase = title => {
      if (typeof title !== 'string' || !title.trim()) fail('INVALID_ARGUMENT', 'phase() requires a title')
      currentPhase = title
      event({ type: 'phase', title })
    }
    const log = message => {
      if (typeof message !== 'string' || !message.trim()) fail('INVALID_ARGUMENT', 'log() requires a message')
      event({ type: 'log', message })
    }
    try {
      const script = new AsyncFunction('agent', 'parallel', 'pipeline', 'phase', 'log', 'args',
        `"use strict";\n${initialization.body}`)
      const raw = await script(agent, parallel, pipeline, phase, log, args)
      await Promise.allSettled([...pendingProgress])
      if (pendingWork.size) fail('UNJOINED_WORK', 'Workflow returned while asynchronous hooks were still running')
      await callbackTail
      if (callbackFault) throw callbackFault
      if (fatalFault) throw fatalFault
      return { value: raw === undefined ? null : json(raw, 'workflow result'),
        stopReason: 'completed', agentsStarted: started }
    } catch (error) {
      await callbackTail
      if (callbackFault) error = callbackFault
      else if (fatalFault) error = fatalFault
      return { value: null, stopReason: 'error',
        error: { name: error?.name ?? 'Error', code: error?.code ?? 'SCRIPT_ERROR',
          message: String(error?.message ?? error).slice(0, 1024) }, agentsStarted: started }
    }
  })()
}

/** Function expression accepted by PtcScriptEngine.run; fixed for every model body. */
export const WORKFLOW_DSL_GUEST_PROGRAM = workflowDslGuest.toString()

/** Only an App-admitted, ungranted workflow may use this private program. */
export function workflowDslNativeProgram(prepared) {
  if (prepared?.kind !== 'workflow' || typeof prepared.program !== 'string'
    || !prepared.program || typeof prepared.runId !== 'string'
    || !Number.isSafeInteger(prepared.deadlineMillis)
    || prepared.deadlineMillis < 1 || prepared.deadlineMillis > 120_000
    || prepared.scope?.workspaceId !== null
    || prepared.scope?.readablePaths?.length !== 0
    || prepared.scope?.writablePaths?.length !== 0
    || prepared.scope?.exactHosts?.length !== 0
    || prepared.scope?.fileCallLimit !== 0
    || prepared.scope?.networkCallLimit !== 0) {
    throw new TypeError('Workflow DSL guest requires an admitted, ungranted workflow')
  }
  return Object.freeze({ kind: 'workflow', runId: prepared.runId,
    sessionId: prepared.sessionId, program: WORKFLOW_DSL_GUEST_PROGRAM,
    inputJson: '{}', deadlineMillis: prepared.deadlineMillis })
}
