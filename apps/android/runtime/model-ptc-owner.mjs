import { prepareModelIsolatedScript } from './model-isolated-script.mjs'
import {
  createAppOwnedListAgentsPtcCaller,
  createAppOwnedListAgentsPtcPolicyIssuer,
} from './model-ptc-list-agents-review.mjs'

const SCRIPT_LEASE_MILLIS = 5_000
const issuedOwners = new WeakSet()

/**
 * Trusted App lifecycle for the first reviewed model-style script path.
 * This service is not a model tool and does not open the Android PTC gate.
 */
export function createAppOwnedListAgentsPtcOwner({ bridge, callbacks, runtime, services } = {}) {
  if (typeof runtime?.isActiveExecution !== 'function') {
    throw new TypeError('Android PTC requires the original ToolRuntime')
  }
  const caller = createAppOwnedListAgentsPtcCaller({ bridge, callbacks, runtime, services })
  const issuer = createAppOwnedListAgentsPtcPolicyIssuer({ agents: services?.agents })
  let closed = false
  let closePromise

  const owner = Object.freeze({
    /** Only a live ToolRuntime parent can supply script identity and authority. */
    start(modelArguments, parent) {
      if (closed) throw new TypeError('Android PTC App owner is closed')
      if (!parent?.agent?.session?.id || typeof parent.callId !== 'string'
        || typeof parent.token !== 'symbol' || !(parent.signal instanceof AbortSignal)
        || !runtime.isActiveExecution(parent)) {
        throw new TypeError('Android PTC requires the current ToolRuntime parent execution')
      }
      parent.signal.throwIfAborted()
      const sessionId = parent.agent.session.id
      const sandboxPolicy = issuer.issue({ sessionId, agent: parent.agent, signal: parent.signal })
      const draft = prepareModelIsolatedScript(modelArguments, {
        sessionId, sandboxPolicy, deadlineMillis: SCRIPT_LEASE_MILLIS,
      })
      // The caller rechecks the live parent and the exact first-party tool
      // registration immediately before native admission and each callback.
      return caller.start(draft, parent)
    },
    close() {
      if (closed) return closePromise
      closed = true
      issuer.close()
      closePromise = caller.close()
      return closePromise
    },
  })
  issuedOwners.add(owner)
  return owner
}

/** A model tool can use only the owner issued by the trusted Android host. */
export function requireAppOwnedListAgentsPtcOwner(value) {
  if (!issuedOwners.has(value)) throw new TypeError('App-owned list_agents PTC owner required')
  return value
}
