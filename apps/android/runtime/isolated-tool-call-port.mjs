import {
  IsolatedExecutionContractError, normalizeExecutionScope, snapshotIsolatedJson,
} from './isolated-execution-contract.mjs'

const MAX_CALLS = 32
const MAX_ARGUMENT_BYTES = 64 * 1024
const MAX_RESULT_BYTES = 64 * 1024
const MAX_AUDIT_BYTES = 128 * 1024
const MAX_ERROR_BYTES = 4 * 1024
const NAME = /^[A-Za-z][A-Za-z0-9_./:-]{0,127}$/
const encoder = new TextEncoder()
const AMBIENT_APP_TOOLS = new Set([
  'android_shell', 'android_linux', 'read_image',
  'write', 'edit', 'str_replace_editor', 'workflow', 'android_ptc',
])

function denied(code, message) {
  return new IsolatedExecutionContractError(code, message)
}

class RecoverableGuestToolError extends IsolatedExecutionContractError {
  #brand = true
  static is(value) {
    return value !== null && typeof value === 'object' && #brand in value
  }
}

function recoverable(code, message) {
  return new RecoverableGuestToolError(code, message)
}

/** Distinguish settled guest errors from failures in audit or transport code. */
export function isRecoverableToolGuestError(value) {
  return RecoverableGuestToolError.is(value)
}

function plain(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && [Object.prototype, null].includes(Object.getPrototypeOf(value))
}

function ownData(value, allowed, label) {
  if (!plain(value)) throw denied('ANDROID_TOOL_CALLBACK_INVALID', `Invalid ${label}`)
  for (const key of Reflect.ownKeys(value)) {
    const property = Object.getOwnPropertyDescriptor(value, key)
    if (typeof key !== 'string' || !allowed.includes(key) || !property
      || !Object.hasOwn(property, 'value')) {
      throw denied('ANDROID_TOOL_CALLBACK_INVALID', `Invalid ${label}`)
    }
  }
  return value
}

function callbackInput(value) {
  const input = ownData(value, ['runId', 'callId', 'name', 'arguments'], 'tool callback')
  if (Reflect.ownKeys(input).length !== 4 || typeof input.runId !== 'string'
    || !Number.isSafeInteger(input.callId) || input.callId < 1 || input.callId > MAX_CALLS
    || typeof input.name !== 'string' || !NAME.test(input.name)) {
    throw denied('ANDROID_TOOL_CALLBACK_INVALID', 'Invalid tool callback')
  }
  return input
}

function classifiedFor(value, definition) {
  if (!plain(value)) return false
  const keys = Reflect.ownKeys(value)
  if (keys.length < 2 || keys.length > 3
    || keys.some(key => !['effect', 'definition', 'projectResult'].includes(key))) return false
  const effect = Object.getOwnPropertyDescriptor(value, 'effect')
  const bound = Object.getOwnPropertyDescriptor(value, 'definition')
  const projection = Object.getOwnPropertyDescriptor(value, 'projectResult')
  return effect && bound && Object.hasOwn(effect, 'value')
    && Object.hasOwn(bound, 'value')
    && (effect.value === 'pure' || effect.value === 'read-only')
    && bound.value === definition
    && (projection === undefined || Object.hasOwn(projection, 'value') && typeof projection.value === 'function')
}

/**
 * Host-owned sub-dispatch boundary for one durably admitted Android guest.
 * It does not authorize a guest or register a model tool. The native service
 * must bind its callback endpoint to the admission token before invoking it.
 * Only the trusted host supplies the parent ToolRunContext and allowlist.
 * `authorizeTool` returns `{ effect: 'pure' | 'read-only', definition }` for
 * the supplied bound definition, null for an ordinary denial, and must throw
 * only when policy settlement is uncertain. Every definition needs App review.
 */
export class IsolatedToolCallPort {
  #runId
  #runtime
  #parent
  #allowed
  #boundDefinitions
  #authorizeTool
  #journal
  #scope
  #controller = new AbortController()
  #tail = Promise.resolve()
  #closePromise
  #closed = false
  #count = 0
  #failed = null
  #unconfirmed = false
  #onParentAbort

  constructor({ prepared, admission, runtime, parent, allowedToolNames, authorizeTool, journal } = {}) {
    if (!plain(prepared) || !['script', 'ptc', 'workflow'].includes(prepared.kind)
      || typeof prepared.runId !== 'string' || !plain(admission)
      || admission.runId !== prepared.runId || typeof admission.token !== 'string'
      || admission.token.length === 0) {
      throw denied('ANDROID_TOOL_OWNER_INVALID', 'A matching durable guest admission is required')
    }
    const scope = normalizeExecutionScope(prepared.scope)
    if (prepared.sessionId !== scope.sessionId
      || scope.workspaceId !== null || scope.readablePaths.length || scope.writablePaths.length
      || scope.exactHosts.length || scope.fileCallLimit || scope.networkCallLimit) {
      throw denied('ANDROID_TOOL_SCOPE_UNAVAILABLE', 'Generic tool callbacks require an ungranted guest scope')
    }
    if (!runtime || typeof runtime.get !== 'function' || typeof runtime.execute !== 'function'
      || !plain(parent) || typeof parent.token !== 'symbol'
      || typeof parent.callId !== 'string' || !parent.callId
      || parent.agent?.session?.id !== prepared.sessionId
      || typeof parent.agent.session.append !== 'function'
      || !(parent.signal instanceof AbortSignal)
      || !Array.isArray(allowedToolNames) || allowedToolNames.length > MAX_CALLS
      || typeof authorizeTool !== 'function'
      || !journal || typeof journal.prepare !== 'function'
      || typeof journal.dispatch !== 'function' || typeof journal.observe !== 'function'
      || typeof journal.confirm !== 'function') {
      throw denied('ANDROID_TOOL_HOST_INVALID', 'A trusted tool runtime, parent execution and allowlist are required')
    }
    const names = new Set()
    const definitions = new Map()
    for (const name of allowedToolNames) {
      const definition = typeof name === 'string' && NAME.test(name)
        ? runtime.get(name, parent.agent) : undefined
      if (typeof name !== 'string' || !NAME.test(name) || name === 'run_code'
        || AMBIENT_APP_TOOLS.has(name) || names.has(name)
        || definition === undefined) {
        throw denied('ANDROID_TOOL_HOST_INVALID', 'Invalid or invisible tool in host allowlist')
      }
      names.add(name)
      definitions.set(name, definition)
    }
    this.#runId = prepared.runId
    this.#runtime = runtime
    this.#parent = parent
    this.#allowed = names
    this.#boundDefinitions = definitions
    this.#authorizeTool = authorizeTool
    this.#journal = journal
    this.#scope = scope
    this.#onParentAbort = () => { this.close(parent.signal.reason).catch(() => {}) }
    if (parent.signal.aborted) this.#onParentAbort()
    else parent.signal.addEventListener('abort', this.#onParentAbort, { once: true })
  }

  /** Serial execution keeps start, policy and terminal audit in submission order. */
  call(value) {
    if (this.#closed || this.#failed) {
      throw denied('ANDROID_TOOL_CALLBACK_CLOSED', 'The isolated tool callback is closed')
    }
    // Count malformed and denied callbacks too. A guest cannot spend an
    // unbounded number of host checks without consuming its run budget.
    if (++this.#count > MAX_CALLS) {
      this.close('tool call limit').catch(() => {})
      throw denied('ANDROID_TOOL_LIMIT', 'Isolated tool call limit reached')
    }
    const input = callbackInput(value)
    if (input.runId !== this.#runId) {
      throw denied('ANDROID_TOOL_OWNER_INVALID', 'Tool callback belongs to another isolated run')
    }
    if (input.callId !== this.#count) {
      throw denied('ANDROID_TOOL_REPLAY', 'Tool callback sequence was reused or skipped')
    }
    if (!this.#allowed.has(input.name)) {
      throw recoverable('ANDROID_TOOL_NOT_GRANTED', 'The tool was not selected by the trusted host')
    }
    const args = snapshotIsolatedJson(input.arguments, 'isolated tool arguments', MAX_ARGUMENT_BYTES)
    const number = this.#count
    const work = this.#tail.then(() => this.#dispatch(number, input.name, args))
    this.#tail = work.then(() => undefined, error => {
      // A materialized tool error is part of the normal PTC API: guest code
      // may catch it and make another call. Ownership/audit failures poison
      // the lane because subsequent execution could no longer be trusted.
      if (this.#unconfirmed || (error?.code !== 'ANDROID_TOOL_DISPATCH_FAILED'
        && error?.code !== 'ANDROID_TOOL_RESULT_UNSUPPORTED'
        && error?.code !== 'ANDROID_TOOL_NOT_GRANTED'
        && error?.code !== 'ANDROID_TOOL_CALLBACK_CLOSED')) {
        this.#failed ??= error
        this.#controller.abort(error)
      }
    })
    return work
  }

  async #dispatch(number, name, args) {
    if (this.#controller.signal.aborted) {
      throw denied('ANDROID_TOOL_CALLBACK_CLOSED', 'Tool callback ended before dispatch')
    }
    let authorized
    try {
      authorized = await this.#authorizeTool(Object.freeze({
        runId: this.#runId, name, arguments: args, scope: this.#scope,
        definition: this.#boundDefinitions.get(name),
        agent: this.#parent.agent, signal: this.#controller.signal,
      }))
    } catch {
      // An exception may mean approval, policy audit or persistence failed
      // after an external decision. The guest must not catch it and continue.
      throw denied('ANDROID_TOOL_POLICY_UNCONFIRMED',
        'Host tool policy did not settle')
    }
    if (this.#controller.signal.aborted) {
      throw denied('ANDROID_TOOL_CALLBACK_CLOSED', 'Tool callback ended during policy review')
    }
    // The App must classify this exact, currently bound definition. A generic
    // allow flag, name-only grant, or effect string cannot authorize dispatch.
    if (!classifiedFor(authorized, this.#boundDefinitions.get(name))) {
      throw recoverable('ANDROID_TOOL_NOT_GRANTED', 'Host policy did not authorize the tool')
    }
    // Re-check visibility at dispatch time. A policy or plugin may revoke a
    // tool while an earlier sub-call occupies the serial lane.
    if (this.#runtime.get(name, this.#parent.agent) !== this.#boundDefinitions.get(name)) {
      throw recoverable('ANDROID_TOOL_NOT_GRANTED', 'Tool visibility or definition changed')
    }
    const subCallId = `${this.#parent.callId}:ptc:${number}`
    const audit = {
      rootCallId: this.#parent.rootCallId ?? this.#parent.callId,
      parentCallId: this.#parent.callId,
      subCallId, name, arguments: args,
    }
    await this.#journal.prepare({ runId: this.#runId, callId: number,
      parentCallId: this.#parent.callId, name, arguments: args })
    this.#parent.agent.session.append('tool/ptc-dispatch-start', audit)
    if (this.#controller.signal.aborted) {
      throw denied('ANDROID_TOOL_CALLBACK_CLOSED', 'Tool callback ended before dispatch')
    }
    // Once this synced marker exists, a restart must assume execute may have
    // reached a side effect. Never replay a marker with unknown settlement.
    await this.#journal.dispatch({ runId: this.#runId, callId: number })
    this.#unconfirmed = true
    let result
    try {
      result = await this.#runtime.execute({
        callId: subCallId,
        rootCallId: audit.rootCallId,
        name, arguments: args,
        agent: this.#parent.agent,
        parent: this.#parent.token,
        signal: this.#controller.signal,
      })
    } catch (error) {
      // ToolRuntime normally materializes failures; a thrown failure means
      // the pipeline or its audit is uncertain. Do not fabricate a settle.
      throw denied('ANDROID_TOOL_DISPATCH_UNCONFIRMED', 'Tool dispatch did not settle')
    }
    if (!plain(result) || typeof result.isError !== 'boolean'
      || !Array.isArray(result.content)) {
      throw denied('ANDROID_TOOL_DISPATCH_UNCONFIRMED', 'Tool runtime returned no materialized outcome')
    }
    let content
    let meta
    let errorInfo
    let auditOverflow = false
    let projectedValue
    let projectionFailed = false
    if (!result.isError && authorized.projectResult !== undefined) {
      try {
        projectedValue = snapshotIsolatedJson(authorized.projectResult(result.value, args),
          'isolated reviewed tool projection', MAX_RESULT_BYTES - 1024)
      } catch { projectionFailed = true }
    }
    try {
      content = projectedValue === undefined
        ? snapshotIsolatedJson(result.content, 'isolated tool audit content', MAX_AUDIT_BYTES)
        : [{ type: 'text', text: JSON.stringify(projectedValue) }]
      if (result.meta !== undefined && projectedValue === undefined) {
        meta = snapshotIsolatedJson(result.meta, 'isolated tool audit metadata', MAX_AUDIT_BYTES)
      }
      if (result.error?.info !== undefined) {
        errorInfo = snapshotIsolatedJson(result.error.info, 'isolated tool audit error', MAX_ERROR_BYTES)
      }
    } catch {
      auditOverflow = true
      content = [{ type: 'text', text: 'Tool completed, but its result exceeded the Android isolated callback audit limit.' }]
    }
    // Validate the guest projection before confirming the observed host
    // outcome. A completed tool with a non-JSON or oversized value is a
    // settled unsupported reply, not an uncertain tool dispatch.
    let guestValue
    let unsupportedReason = projectionFailed ? 'Reviewed tool result could not be projected'
      : auditOverflow ? 'Tool result exceeded the guest audit limit' : null
    if (!unsupportedReason && result.isError) {
      const message = result.error?.message ?? 'Tool call failed'
      if (typeof message !== 'string' || encoder.encode(message).length > MAX_ERROR_BYTES) {
        unsupportedReason = 'Tool error exceeded the guest reply limit'
      }
    }
    if (!unsupportedReason && !result.isError) {
      if (result.content.some(block => block?.type === 'image')
        || result.additionalContexts?.length || result.concludesTurn) {
        unsupportedReason = 'Tool result needs host-only context handling'
      } else {
        try { guestValue = snapshotIsolatedJson(projectedValue === undefined ? result.value : projectedValue,
          'isolated tool result', MAX_RESULT_BYTES - 1024) }
        catch { unsupportedReason = 'Tool result is not bounded guest JSON' }
      }
    }
    const terminalAudit = {
      ...audit,
      isError: result.isError || unsupportedReason !== null,
      content,
      ...(!auditOverflow && meta !== undefined ? { meta } : {}),
      ...(unsupportedReason
        ? { error: { name: 'IsolatedToolResultError', code: 'ANDROID_TOOL_RESULT_UNSUPPORTED' } }
        : errorInfo === undefined ? {} : { error: errorInfo }),
    }
    await this.#journal.observe({ runId: this.#runId, callId: number, result: terminalAudit })
    this.#parent.agent.session.append('tool/ptc-dispatch', terminalAudit)
    if (this.#controller.signal.aborted) {
      throw denied('ANDROID_TOOL_CALLBACK_CLOSED', 'Tool settled after guest cancellation')
    }
    if (unsupportedReason) {
      await this.#journal.confirm({ runId: this.#runId, callId: number,
        outcome: 'unsupported', result: terminalAudit })
      this.#unconfirmed = false
      throw recoverable('ANDROID_TOOL_RESULT_UNSUPPORTED', unsupportedReason)
    }
    if (result.isError) {
      const message = result.error?.message ?? 'Tool call failed'
      await this.#journal.confirm({ runId: this.#runId, callId: number,
        outcome: 'tool-error', result: terminalAudit })
      this.#unconfirmed = false
      throw recoverable('ANDROID_TOOL_DISPATCH_FAILED', message)
    }
    await this.#journal.confirm({ runId: this.#runId, callId: number,
      outcome: 'success', result: terminalAudit })
    this.#unconfirmed = false
    if (this.#controller.signal.aborted) {
      throw denied('ANDROID_TOOL_CALLBACK_CLOSED', 'Tool confirmed after guest cancellation')
    }
    return guestValue
  }

  /** Abort queued and running work, then join every started ToolRuntime call. */
  close(reason = 'guest closed') {
    if (this.#closePromise) return this.#closePromise
    this.#closed = true
    this.#controller.abort(reason)
    this.#parent.signal.removeEventListener('abort', this.#onParentAbort)
    this.#closePromise = this.#tail.then(() => {
      if (this.#failed || this.#unconfirmed) {
        throw denied('ANDROID_TOOL_DISPATCH_UNCONFIRMED',
          'An isolated sub-dispatch did not complete its audit')
      }
    })
    return this.#closePromise
  }
}
