import { prepareModelIsolatedScript } from './model-isolated-script.mjs'
import { projectIsolatedSandboxPolicy } from './isolated-sandbox-policy.mjs'
import { createAppOwnedReadOnlyPtcCaller } from './model-ptc-readonly-review.mjs'

const LEASE_MILLIS = 120_000
const owners = new WeakSet()

/**
 * Trusted host owner for bounded file/web PTC. The guest receives no direct
 * filesystem, network, shell or Node authority; reviewed ToolRuntime calls
 * retain their live Agent policy and durable child-call record.
 */
export function createAppOwnedReadOnlyPtcOwner({ bridge, callbacks, runtime, services } = {}) {
  if (typeof runtime?.isActiveExecution !== 'function' || typeof services?.agents?.get !== 'function') {
    throw new TypeError('Read-only PTC requires the live ToolRuntime and Agent registry')
  }
  const caller = createAppOwnedReadOnlyPtcCaller({ bridge, callbacks, runtime, services })
  let closed = false, closePromise
  const owner = Object.freeze({
    start(modelArguments, parent) {
      if (closed || !parent?.agent?.session?.id || services.agents.get(parent.agent.id) !== parent.agent
        || !runtime.isActiveExecution(parent) || !(parent.signal instanceof AbortSignal)) {
        throw new TypeError('Read-only PTC requires its active parent ToolRuntime execution')
      }
      parent.signal.throwIfAborted()
      const sessionId = parent.agent.session.id
      const sandboxPolicy = projectIsolatedSandboxPolicy({ mode: 'read-only', networkMode: 'deny',
        approvedScope: { ownerId: 'app-model-readonly-ptc', sessionId, version: 1,
          workspaceId: null, readablePaths: [], writablePaths: [], exactHosts: [],
          fileCallLimit: 0, networkCallLimit: 0, leaseMillis: LEASE_MILLIS },
      })
      return caller.start(prepareModelIsolatedScript(modelArguments, { sessionId, sandboxPolicy,
        deadlineMillis: LEASE_MILLIS, executionKind: 'ptc' }), parent)
    },
    close() {
      if (closed) return closePromise
      closed = true
      closePromise = caller.close()
      return closePromise
    },
  })
  owners.add(owner)
  return owner
}

/** Reject forged owners before a future product registration can use them. */
export function requireAppOwnedReadOnlyPtcOwner(owner) {
  if (!owners.has(owner)) throw new TypeError('App-owned read-only PTC owner required')
  return owner
}
