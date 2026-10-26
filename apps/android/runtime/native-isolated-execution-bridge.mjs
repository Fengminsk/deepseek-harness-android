import { IsolatedExecutionContractError } from './isolated-execution-contract.mjs'

const issuedBridges = new WeakSet()

function unavailable(message) {
  return new IsolatedExecutionContractError('ANDROID_PTC_UNAVAILABLE', message)
}

async function boundedRequest(transport, method, params, duration) {
  // Abandonment does not undo a native admission. The receipt ledger makes its
  // runId non-retryable and cold recovery marks any orphaned run uncertain.
  const deadline = AbortSignal.timeout(duration)
  return transport.request(method, params, deadline)
}

/**
 * Internal App-owned, no-capability script adapter. Only the native service may
 * durably admit a run or start a guest. The model-facing PTC gate stays closed.
 */
export function createNativeIsolatedExecutionBridge(transport) {
  if (!transport || typeof transport.request !== 'function') throw new TypeError('Native transport required')
  const bridge = Object.freeze({
    async admit(prepared) {
      if (prepared.kind !== 'script') throw unavailable('Android workflow execution is unavailable')
      if (prepared.scope.readablePaths.length || prepared.scope.writablePaths.length
        || prepared.scope.exactHosts.length || prepared.scope.fileCallLimit
        || prepared.scope.networkCallLimit || prepared.scope.workspaceId !== null) {
        throw unavailable('Granted script scopes require App-selected native approval')
      }
      const admitted = await boundedRequest(transport, 'native.isolated.admit', {
        kind: prepared.kind, runId: prepared.runId, sessionId: prepared.sessionId,
        program: prepared.program, inputJson: JSON.stringify(prepared.args),
        deadlineMillis: prepared.deadlineMillis, scope: prepared.scope,
      }, 10_000)
      if (!admitted || admitted.runId !== prepared.runId || typeof admitted.token !== 'string') {
        throw new Error('Native admission owner did not match the run')
      }
      return Object.freeze({ runId: admitted.runId, token: admitted.token })
    },
    async execute(admission, prepared) {
      if (admission.runId !== prepared.runId) throw new Error('Native run identity changed')
      await boundedRequest(transport, 'native.isolated.execute', admission,
        Math.min(20_000, prepared.deadlineMillis + 10_000))
    },
    async cancel(admission) {
      await boundedRequest(transport, 'native.isolated.cancel', admission, 12_000)
    },
    async settle(admission) {
      return boundedRequest(transport, 'native.isolated.settle', admission, 10_000)
    },
    async release(admission) {
      await boundedRequest(transport, 'native.isolated.release', admission, 12_000)
    },
  })
  issuedBridges.add(bridge)
  return bridge
}

/** Refuse substitute adapters in the App-owned script dispatch path. */
export function requireNativeIsolatedExecutionBridge(value) {
  if (!issuedBridges.has(value)) throw new TypeError('App-owned native isolated bridge required')
  return value
}
