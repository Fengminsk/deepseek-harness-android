import { NativeIsolatedToolCallbacks } from './native-isolated-tool-callbacks.mjs'
import { requireNativeIsolatedExecutionBridge } from './native-isolated-execution-bridge.mjs'
import { startAppOwnedModelIsolatedScript } from './model-isolated-script.mjs'

const issuedCallers = new WeakSet()
const MAX_TOOLS = 32
const TOOL_NAME = /^[A-Za-z][A-Za-z0-9_]*$/
const UNSAFE_NAMES = new Set(['__proto__', 'constructor', 'prototype', 'then'])
const AMBIENT_TOOLS = new Set(['run_code', 'android_shell', 'android_linux',
  'read_image', 'str_replace_editor', 'workflow', 'android_ptc'])
const WRITE_TOOLS = new Set(['write', 'edit', 'android_attachments'])
const ISOLATED_TOOLS = new Set(['linux_exec', 'linux_import', 'linux_export'])
const READ_TOOLS = new Set(['read', 'glob', 'grep', 'web_search', 'web_fetch',
  'android_files', 'android_attachments', 'linux_inspect'])

/**
 * Pin the App-reviewed tool definitions, rather than trusting a name, effect
 * classification or grant included in model-authored script arguments. This
 * factory is called by the trusted Android host, not exposed as a model tool.
 */
export function createAppOwnedModelPtcCaller({ bridge, callbacks, runtime, reviewedTools } = {}) {
  requireNativeIsolatedExecutionBridge(bridge)
  if (!(callbacks instanceof NativeIsolatedToolCallbacks)
    || !runtime || typeof runtime.get !== 'function'
    || typeof runtime.registrationIdentity !== 'function'
    || typeof runtime.isActiveExecution !== 'function'
    || typeof runtime.execute !== 'function'
    || !Array.isArray(reviewedTools) || reviewedTools.length > MAX_TOOLS) {
    throw new TypeError('Android PTC requires App-owned callbacks, ToolRuntime and reviewed tools')
  }
  const reviewed = new Map()
  for (const entry of reviewedTools) {
    if (!entry || typeof entry !== 'object'
      || typeof entry.name !== 'string' || !TOOL_NAME.test(entry.name)
      || AMBIENT_TOOLS.has(entry.name)
      || UNSAFE_NAMES.has(entry.name)
      || !entry.definition || entry.definition.name !== entry.name
      || !entry.registrationIdentity || typeof entry.registrationIdentity !== 'object'
      || !['pure', 'read-only', 'workspace-write', 'isolated-execution'].includes(entry.effect)
      || READ_TOOLS.has(entry.name) && entry.effect !== 'read-only'
        && !(entry.name === 'android_attachments' && entry.effect === 'workspace-write')
      || ['write', 'edit'].includes(entry.name) && entry.effect !== 'workspace-write'
      || entry.effect === 'workspace-write' && (!WRITE_TOOLS.has(entry.name)
        || typeof entry.flushSession !== 'function')
      || ISOLATED_TOOLS.has(entry.name) !== (entry.effect === 'isolated-execution')
      || entry.effect === 'isolated-execution' && typeof entry.flushSession !== 'function'
      || entry.effectForArguments !== undefined && (entry.effect !== 'workspace-write'
        || entry.name !== 'android_attachments' || typeof entry.effectForArguments !== 'function')
      || entry.flushSession !== undefined && typeof entry.flushSession !== 'function'
      || entry.authorizeArguments !== undefined && typeof entry.authorizeArguments !== 'function'
      || entry.projectResult !== undefined && typeof entry.projectResult !== 'function'
      || entry.effect !== 'pure' && typeof entry.authorizeArguments !== 'function'
      || reviewed.has(entry.name)) {
      throw new TypeError('Android PTC requires a unique reviewed tool definition and effect')
    }
    reviewed.set(entry.name, Object.freeze({
      definition: entry.definition, registrationIdentity: entry.registrationIdentity,
      effect: entry.effect,
      effectForArguments: entry.effectForArguments,
      flushSession: entry.flushSession,
      authorizeArguments: entry.authorizeArguments,
      projectResult: entry.projectResult,
    }))
  }
  const caller = Object.freeze({
    /** Only the trusted outer defineTool.execute closure supplies this context. */
    start(draft, parent) {
      if (!parent?.agent?.session?.id || typeof parent.agent.session.append !== 'function'
        || typeof parent.token !== 'symbol' || typeof parent.callId !== 'string'
        || !parent.callId || !(parent.signal instanceof AbortSignal)
        || parent.agent.session.id !== draft?.execution?.sessionId
        || !runtime.isActiveExecution(parent)) {
        throw new TypeError('Android PTC requires the current ToolRuntime parent execution')
      }
      parent.signal.throwIfAborted()
      const exact = (name, agent) => {
        const review = reviewed.get(name)
        return runtime.isActiveExecution(parent) && review !== undefined
          && runtime.registrationIdentity(name, agent) === review.registrationIdentity
          && runtime.get(name, agent) === review.definition
      }
      const allowedToolNames = []
      for (const name of reviewed.keys()) {
        if (exact(name, parent.agent)) allowedToolNames.push(name)
      }
      // The port checks definitions; this narrow facade also checks the
      // ToolRuntime registration generation immediately before execute(). A
      // disposed/re-registered identical definition never inherits review.
      const boundRuntime = Object.freeze({
        get(name, agent) { return exact(name, agent) ? runtime.get(name, agent) : undefined },
        async execute(input) {
          // The merged runtime dispatches call batches; every call must still
          // resolve to the registration this review captured.
          if (input === null || typeof input !== 'object'
            || !Array.isArray(input.calls) || input.calls.length === 0
            || input.agent !== parent.agent
            || input.calls.some(call => typeof call?.name !== 'string'
              || !exact(call.name, input.agent))) {
            throw new TypeError('Reviewed Android PTC tool registration changed')
          }
          // Conditional registrations are executable only through a resolved
          // tool set; resolve the parent Agent's conditions for this batch.
          const selection = parent.agent.model?.current?.() ?? { provider: '', model: '' }
          const toolSet = await runtime.resolve({
            agent: parent.agent, modelSelection: selection, signal: input.signal,
          })
          try {
            return await runtime.execute({ ...input, toolSet })
          } finally {
            toolSet.dispose()
          }
        },
      })
      const authorizeTool = async input => {
        const review = reviewed.get(input.name)
        if (!review || !exact(input.name, parent.agent)
          || input.agent !== parent.agent || input.signal.aborted
          || parent.signal.aborted) return undefined
        if (review.authorizeArguments
          && await review.authorizeArguments(input.arguments, Object.freeze({
            agent: parent.agent, signal: input.signal,
          })) !== true) return undefined
        const effect = review.effectForArguments === undefined ? review.effect
          : review.effectForArguments(input.arguments)
        if (effect !== review.effect && !(review.effect === 'workspace-write'
          && effect === 'read-only')) return undefined
        // The callback port admits only a classification of the exact
        // definition it captured at binding, not a name-wide effect label.
        return Object.freeze({ effect, definition: review.definition,
          ...(!['workspace-write', 'isolated-execution'].includes(effect) ? {} : { flushSession: review.flushSession }),
          ...(review.projectResult === undefined ? {} : { projectResult: review.projectResult }) })
      }
      return startAppOwnedModelIsolatedScript(draft, {
        bridge, callbacks, runtime: boundRuntime, parent, allowedToolNames,
        authorizeTool, signal: parent.signal,
      })
    },
  })
  issuedCallers.add(caller)
  return caller
}

/**
 * Resolve scoped first-party reviews for the exact live parent call. Android
 * presets can register different list_agents definitions per Agent; a review
 * captured when the App boots must never become a name-wide grant.
 */
export function createAppOwnedModelPtcCallerForExecution({
  bridge, callbacks, runtime, reviewedToolsForExecution,
} = {}) {
  if (typeof reviewedToolsForExecution !== 'function') {
    throw new TypeError('Android PTC requires an App-owned per-execution review')
  }
  // Validate the immutable host dependencies before the caller can be issued.
  createAppOwnedModelPtcCaller({ bridge, callbacks, runtime, reviewedTools: [] })
  let closed = false
  let closePromise
  const activeRuns = new Set()
  const caller = Object.freeze({
    start(draft, parent) {
      if (closed) throw new TypeError('Android PTC App review owner is closed')
      const reviewedTools = reviewedToolsForExecution(parent?.agent)
      const run = createAppOwnedModelPtcCaller({
        bridge, callbacks, runtime, reviewedTools,
      }).start(draft, parent)
      activeRuns.add(run)
      run.result.then(
        () => activeRuns.delete(run),
        () => activeRuns.delete(run),
      )
      return run
    },
    close() {
      if (closed) return closePromise
      closed = true
      const runs = [...activeRuns]
      for (const run of runs) run.cancel('Android PTC App review owner closed')
      // The Cordis effect awaits this promise before releasing the native
      // transport. A cancellation request alone cannot confirm that an
      // in-flight ToolRuntime callback or native guest has retired.
      closePromise = Promise.allSettled(runs.map(run => run.dispose())).then(results => {
        const failures = results.filter(result => result.status === 'rejected')
        if (failures.length) {
          throw new AggregateError(failures.map(result => result.reason),
            'Android PTC App review owner retirement was not confirmed')
        }
      })
      return closePromise
    },
  })
  issuedCallers.add(caller)
  return caller
}

export function requireAppOwnedModelPtcCaller(value) {
  if (!issuedCallers.has(value)) throw new TypeError('App-owned model PTC caller required')
  return value
}
