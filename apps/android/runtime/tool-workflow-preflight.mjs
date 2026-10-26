import { randomUUID } from 'node:crypto'
import {
  IsolatedExecutionContractError,
  prepareIsolatedExecution,
  projectIsolatedReceipt,
  requireModelFacingIsolatedExecution,
} from './isolated-execution-contract.mjs'
import { requireIsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'

const AsyncFunction = (async () => {}).constructor
const MODEL_FIELDS = new Set(['script', 'meta', 'args', 'run_in_background'])
const HOST_FIELDS = new Set([
  'sessionId', 'sandboxPolicy', 'deadlineMillis', 'maxTotalAgents', 'maxConcurrentAgents',
])

function invalid(name) {
  throw new IsolatedExecutionContractError('ANDROID_WORKFLOW_MODEL_INVALID', `Invalid ${name}`)
}

function record(value, name, fields) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) invalid(name)
  const own = Object.create(null)
  for (const key of Reflect.ownKeys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (typeof key !== 'string' || !fields.has(key) || !descriptor
      || !Object.hasOwn(descriptor, 'value')) invalid(name)
    own[key] = descriptor.value
  }
  return own
}

function noNativeCapabilityGrants(policy) {
  const scope = policy.scope
  if (policy.mode !== 'read-only' || policy.networkMode !== 'deny'
    || scope.workspaceId !== null || scope.readablePaths.length || scope.writablePaths.length
    || scope.exactHosts.length || scope.fileCallLimit || scope.networkCallLimit) {
    throw new IsolatedExecutionContractError('ANDROID_WORKFLOW_SCOPE_UNAVAILABLE',
      'Android workflow execution has no approved native file or network broker')
  }
  return scope
}

/**
 * Copy the original `workflow` tool arguments into a host-owned admission
 * request. Model input cannot name a run, Session, capability scope, child
 * budget or runtime deadline. This parses JavaScript but never evaluates it.
 */
export function prepareModelWorkflow(modelArguments, trustedHost) {
  const input = record(modelArguments, 'workflow arguments', MODEL_FIELDS)
  const host = record(trustedHost, 'trusted workflow host', HOST_FIELDS)
  if (!['script', 'meta'].every(key => Object.hasOwn(input, key))
    || ![...HOST_FIELDS].every(key => Object.hasOwn(host, key))) invalid('workflow fields')
  if (input.run_in_background !== undefined && input.run_in_background !== false) {
    throw new IsolatedExecutionContractError('ANDROID_WORKFLOW_BACKGROUND_UNAVAILABLE',
      'A durable Android background workflow owner is not connected')
  }
  if (Object.hasOwn(input, 'args') && (input.args === null
    || typeof input.args !== 'object' || Array.isArray(input.args)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(input.args)))) {
    invalid('workflow JSON args object')
  }
  const policy = requireIsolatedSandboxPolicy(host.sandboxPolicy)
  const scope = noNativeCapabilityGrants(policy)
  const execution = prepareIsolatedExecution({
    kind: 'workflow', runId: randomUUID(), sessionId: host.sessionId,
    program: input.script, args: input.args ?? null,
    deadlineMillis: host.deadlineMillis, meta: input.meta,
    maxTotalAgents: host.maxTotalAgents,
    maxConcurrentAgents: host.maxConcurrentAgents,
  }, scope)
  try {
    // Grammar check only. The model body is never interpolated into an
    // expression executed by this trusted Node host.
    new AsyncFunction('agent', 'pipeline', 'parallel', 'phase', 'log', 'args', execution.program)
  } catch {
    invalid('workflow JavaScript body')
  }
  return Object.freeze({ source: execution.program, execution, background: false })
}

/** Native workflow admission, callbacks and durable progress are not wired. */
export function runModelWorkflow(_draft, _host, _signal) {
  requireModelFacingIsolatedExecution()
}

/** A failed or uncertain native outcome never yields workflow output. */
export function projectModelWorkflowReceipt(receipt, expectedRunId) {
  const result = projectIsolatedReceipt(receipt, expectedRunId)
  return result.state === 'completed'
    ? Object.freeze({ runId: result.runId, state: 'completed', value: result.value })
    : Object.freeze({ runId: result.runId, state: 'failed', failure: result.failure,
      requiresReview: result.requiresReview, detail: result.detail })
}
