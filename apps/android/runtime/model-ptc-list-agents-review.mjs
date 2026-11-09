import { isFirstPartyListAgentsDefinition } from '@deepseek-ai/dsh-tool-subagent-control'
import { createAppOwnedModelPtcCallerForExecution } from './model-ptc-caller-binding.mjs'
import { projectIsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'

const TOOL_NAME = 'list_agents'
const SCRIPT_LEASE_MILLIS = 5_000

function exactPolicyRequest(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) return false
  const keys = Reflect.ownKeys(value)
  return keys.length === 3 && ['sessionId', 'agent', 'signal'].every(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    return descriptor !== undefined && Object.hasOwn(descriptor, 'value')
  }) && keys.every(key => ['sessionId', 'agent', 'signal'].includes(key))
}

function childScopeOnly(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) return false
  const keys = Reflect.ownKeys(value)
  if (keys.length === 0) return true
  if (keys.length !== 1 || keys[0] !== 'scope') return false
  const scope = Object.getOwnPropertyDescriptor(value, 'scope')
  return scope !== undefined && Object.hasOwn(scope, 'value')
    && scope.value === 'children'
}

/**
 * Review the original direct-child listing for one live Agent. The trusted
 * App must supply the first-party definition it registered; discovery by name
 * alone cannot attest which plugin owns a ToolRuntime registration. This entry
 * does not publish or enable the model-facing PTC tool.
 */
export function reviewListAgentsForModelPtc({ runtime, agent, definition, services } = {}) {
  if (!runtime || typeof runtime.get !== 'function'
    || typeof runtime.registrationIdentity !== 'function'
    || !agent?.session?.id || !definition || definition.name !== TOOL_NAME
    || !services?.subagents || typeof services?.agents?.get !== 'function'
    || services.agents.get(agent.id) !== agent
    || !isFirstPartyListAgentsDefinition(definition, agent)
    || runtime.get(TOOL_NAME, agent) !== definition) {
    throw new TypeError('Android PTC requires the captured first-party list_agents definition')
  }
  const registrationIdentity = runtime.registrationIdentity(TOOL_NAME, agent)
  if (!registrationIdentity || typeof registrationIdentity !== 'object') {
    throw new TypeError('Android PTC requires an active list_agents registration')
  }
  return Object.freeze({
    name: TOOL_NAME,
    definition,
    registrationIdentity,
    effect: 'read-only',
    async authorizeArguments(args, input) {
      if (input?.agent !== agent || !(input.signal instanceof AbortSignal)) return false
      input.signal.throwIfAborted()
      return childScopeOnly(args)
    },
  })
}

/** Issue the production caller lazily from the current scoped registration. */
export function createAppOwnedListAgentsPtcCaller({ bridge, callbacks, runtime, services } = {}) {
  if (!services?.subagents || typeof services?.agents?.get !== 'function') {
    throw new TypeError('Android PTC requires the original subagent and Agent services')
  }
  return createAppOwnedModelPtcCallerForExecution({
    bridge, callbacks, runtime,
    reviewedToolsForExecution(agent) {
      const definition = runtime.get(TOOL_NAME, agent)
      return [reviewListAgentsForModelPtc({ runtime, agent, definition, services })]
    },
  })
}

/**
 * Issue only the zero-grant policy needed to call the reviewed direct-child
 * catalog tool. This is an App-owned producer for a future model-facing tool,
 * not native approval or permission to register that tool today.
 */
export function createAppOwnedListAgentsPtcPolicyIssuer({ agents } = {}) {
  if (typeof agents?.get !== 'function') {
    throw new TypeError('Android PTC requires the live Agent registry')
  }
  let closed = false
  return Object.freeze({
    issue(input) {
      if (closed) throw new TypeError('Android PTC App policy owner is closed')
      if (!exactPolicyRequest(input) || !(input.signal instanceof AbortSignal)
        || typeof input.sessionId !== 'string' || !input.agent?.id
        || input.agent.session?.id !== input.sessionId
        || agents.get(input.agent.id) !== input.agent) {
        throw new TypeError('Android PTC requires the current Agent session')
      }
      input.signal.throwIfAborted()
      return projectIsolatedSandboxPolicy({
        mode: 'read-only', networkMode: 'deny',
        approvedScope: {
          ownerId: 'app-model-list-agents', sessionId: input.sessionId,
          version: 1, workspaceId: null, readablePaths: [], writablePaths: [],
          exactHosts: [], fileCallLimit: 0, networkCallLimit: 0,
          leaseMillis: SCRIPT_LEASE_MILLIS,
        },
      })
    },
    close() { closed = true },
  })
}
