import { requireModelFacingIsolatedExecution } from './isolated-execution-contract.mjs'
import { prepareModelWorkflow } from './tool-workflow-preflight.mjs'

const issuedAdmissions = new WeakSet()
const issuedDrafts = new WeakMap()

/** Preserve the original foreground workflow value without exposing a failed guest output. */
export function projectModelWorkflowForeground(receipt, ticket) {
  if (!ticket || typeof ticket !== 'object'
    || receipt?.runId !== ticket.runId || receipt?.sessionId !== ticket.sessionId
    || receipt?.state !== 'COMPLETED' || receipt?.requiresReview !== false
    || typeof receipt?.outputJson !== 'string') {
    throw new TypeError('Android workflow has no confirmed foreground result')
  }
  let output
  try { output = JSON.parse(receipt.outputJson) }
  catch { throw new TypeError('Android workflow foreground result is invalid') }
  if (!output || typeof output !== 'object' || Array.isArray(output)
    || output.stopReason !== 'completed' || !Object.hasOwn(output, 'value')
    || !Number.isSafeInteger(output.agentsStarted) || output.agentsStarted < 0
    || Object.hasOwn(output, 'error')) {
    throw new TypeError('Android workflow foreground result is invalid')
  }
  return Object.freeze({ kind: 'foreground', runId: ticket.runId,
    agentsStarted: output.agentsStarted, result: output.value })
}

/**
 * The original workflow plugin is disabled in the Android profile. This
 * App-private seam pins its first-party definition and one live ToolRuntime
 * execution before preparing a model script. A reviewed App-private path can
 * start the native runner, while the model-facing path remains closed.
 */
export function createAppOwnedModelWorkflowAdmission({
  runtime, agents, agent, definition, registrationIdentity, issueHost, runPrepared,
  isAvailable = () => true,
} = {}) {
  if (!runtime || typeof runtime.get !== 'function'
    || typeof runtime.registrationIdentity !== 'function'
    || typeof runtime.isActiveExecution !== 'function'
    || !agents || typeof agents.get !== 'function'
    || !definition || typeof definition !== 'object'
    || typeof definition.name !== 'string' || !definition.name
    || !registrationIdentity || typeof registrationIdentity !== 'object'
    || typeof issueHost !== 'function' || typeof isAvailable !== 'function'
    || typeof agent?.id !== 'string' || agents.get(agent.id) !== agent
    || runtime.get(definition.name, agent) !== definition
    || runtime.registrationIdentity(definition.name, agent) !== registrationIdentity) {
    throw new TypeError('Android workflow requires an App-captured ToolRuntime definition and host policy')
  }
  const current = execution => {
    const parent = execution?.agent
    return isAvailable() && execution?.name === definition.name
      && parent === agent
      && execution.parent === undefined
      && execution.rootCallId === execution.callId
      && execution.signal instanceof AbortSignal
      && !execution.signal.aborted
      && typeof execution.token === 'symbol'
      && runtime.isActiveExecution(execution)
      && typeof parent?.id === 'string'
      && agents.get(parent.id) === parent
      && typeof parent.session?.id === 'string'
      && typeof parent.session.append === 'function'
      && runtime.registrationIdentity(definition.name, parent) === registrationIdentity
      && runtime.get(definition.name, parent) === definition
  }
  function ownedDraft(ticket) {
    const owned = issuedDrafts.get(ticket)
    if (owned?.owner !== admission || owned.used || !current(owned.execution)) {
      throw new TypeError('Android workflow requires the current App-owned draft')
    }
    return owned
  }
  const admission = Object.freeze({
    /** A model call supplies arguments only; App policy supplies all authority. */
    async prepare(modelArguments, execution) {
      if (!current(execution)) {
        throw new TypeError('Android workflow requires the current first-party parent execution')
      }
      const parent = execution.agent
      const host = await issueHost(Object.freeze({ agent: parent, signal: execution.signal }))
      // Policy issuance may await an App approval. A cancelled, replaced or
      // re-registered call must not use an approval granted to the old owner.
      if (!current(execution)) {
        throw new TypeError('Android workflow parent execution changed during policy review')
      }
      if (!host || typeof host !== 'object') {
        throw new TypeError('Android workflow App host policy is missing')
      }
      const draft = prepareModelWorkflow(modelArguments, {
        sessionId: parent.session.id,
        sandboxPolicy: host.sandboxPolicy,
        deadlineMillis: host.deadlineMillis,
        maxTotalAgents: host.maxTotalAgents,
        maxConcurrentAgents: host.maxConcurrentAgents,
      })
      if (!current(execution)) {
        throw new TypeError('Android workflow parent execution changed during draft preparation')
      }
      // The script-bearing execution is retained privately. Returning it here
      // would let another App component accidentally pass it to runDsl() and
      // bypass the still-closed model-facing gate.
      const ticket = Object.freeze({
        runId: draft.execution.runId,
        sessionId: draft.execution.sessionId,
        maxTotalAgents: draft.execution.maxTotalAgents,
        maxConcurrentAgents: draft.execution.maxConcurrentAgents,
      })
      issuedDrafts.set(ticket, { owner: admission, draft, execution, used: false })
      return ticket
    },
    /** Trusted App integration only. Consume before native admission; never replay. */
    executePrivate(ticket) {
      const owned = ownedDraft(ticket)
      if (typeof runPrepared !== 'function') {
        throw new TypeError('Android workflow private runner is unavailable')
      }
      owned.used = true
      issuedDrafts.delete(ticket)
      return runPrepared({ prepared: owned.draft.execution,
        parent: owned.execution.agent, signal: owned.execution.signal })
    },
    /** Do not publish an executor until native/device acceptance opens it. */
    run(ticket) {
      ownedDraft(ticket)
      requireModelFacingIsolatedExecution()
      return Promise.resolve(admission.executePrivate(ticket))
        .then(receipt => projectModelWorkflowForeground(receipt, ticket))
    },
  })
  issuedAdmissions.add(admission)
  return admission
}

export function requireAppOwnedModelWorkflowAdmission(value) {
  if (!issuedAdmissions.has(value)) throw new TypeError('App-owned model workflow admission required')
  return value
}
