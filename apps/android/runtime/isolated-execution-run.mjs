import {
  IsolatedExecutionContractError,
  prepareIsolatedExecution,
  projectIsolatedReceipt,
} from './isolated-execution-contract.mjs'

const BRIDGE_METHODS = ['admit', 'execute', 'cancel', 'settle', 'release']

function unconfirmed(message, cause) {
  const error = new IsolatedExecutionContractError(
    'ANDROID_EXECUTION_UNCONFIRMED',
    message,
  )
  if (cause !== undefined) error.cause = cause
  return error
}

function requireBridge(bridge) {
  if (!bridge || typeof bridge !== 'object' || BRIDGE_METHODS.some((name) => typeof bridge[name] !== 'function')) {
    throw new IsolatedExecutionContractError(
      'ANDROID_EXECUTION_BRIDGE_REQUIRED',
      'A trusted durable Android execution bridge is required.',
    )
  }
  return bridge
}

/**
 * Owns exactly one App-authorized isolated run. The bridge is trusted host code,
 * never supplied by a model or a guest script. It must durably admit before
 * returning, make cancellation quiescent, and settle from its terminal record.
 */
export class IsolatedExecutionRun {
  #prepared
  #bridge
  #toolBinding
  #boundTools = null
  #controller = new AbortController()
  #admission = null
  #cancelPromise = null
  #cancelRequested = false
  #terminalRead = false
  #finished = false
  #disposePromise = null
  #externalSignal
  #onExternalAbort

  constructor({ request, scope, parentScope, bridge, toolBinding, signal } = {}) {
    this.#prepared = prepareIsolatedExecution(request, scope, parentScope)
    this.#bridge = requireBridge(bridge)
    if (toolBinding !== undefined && (!toolBinding || typeof toolBinding.bind !== 'function')) {
      throw new TypeError('toolBinding must be a trusted binder')
    }
    this.#toolBinding = toolBinding
    if (signal !== undefined && !(signal instanceof AbortSignal)) {
      throw new TypeError('signal must be an AbortSignal')
    }
    this.#externalSignal = signal
    this.#onExternalAbort = () => this.cancel(signal.reason)
    if (signal?.aborted) this.#onExternalAbort()
    else signal?.addEventListener('abort', this.#onExternalAbort, { once: true })

    // Begin in a microtask, so cancellation during construction still prevents
    // an unnecessary native admission. Keep an internal rejection observer for
    // callers which only use dispose() after an early failure.
    this.result = Promise.resolve().then(() => this.#run())
    this.result.catch(() => {})
  }

  get runId() {
    return this.#prepared.runId
  }

  get cancelled() {
    return this.#cancelRequested
  }

  cancel(reason = 'cancelled') {
    if (this.#finished || this.#cancelRequested) return
    this.#cancelRequested = true
    this.#controller.abort(reason)
    if (this.#admission && !this.#terminalRead) this.#requestNativeCancel()
  }

  async dispose() {
    if (!this.#disposePromise) {
      if (!this.#finished) this.cancel('disposed')
      this.#disposePromise = this.result.then(
        () => undefined,
        (error) => {
          if (error?.code === 'ANDROID_EXECUTION_UNCONFIRMED') throw error
        },
      )
    }
    return this.#disposePromise
  }

  #requestNativeCancel() {
    if (!this.#cancelPromise && this.#admission) {
      this.#cancelPromise = Promise.resolve()
        .then(() => this.#bridge.cancel(this.#admission, this.#controller.signal.reason))
      // A cancellation request can race with execute(). The owner joins this
      // promise before reading or publishing any terminal receipt.
      this.#cancelPromise.catch(() => {})
    }
    return this.#cancelPromise
  }

  async #run() {
    let admission
    let receipt
    let failure
    try {
      if (this.#cancelRequested) {
        throw new IsolatedExecutionContractError('ANDROID_EXECUTION_CANCELLED', 'Run cancelled before admission.')
      }
      try {
        admission = await this.#bridge.admit(this.#prepared, this.#controller.signal)
      } catch (error) {
        throw unconfirmed('Durable run admission could not be confirmed.', error)
      }
      if (!admission || typeof admission !== 'object' || admission.runId !== this.runId) {
        // An unowned handle must never be executed, cancelled or released.
        throw unconfirmed('Native admission did not match the requested run.')
      }
      this.#admission = admission

      if (!this.#cancelRequested && this.#toolBinding) {
        try {
          this.#boundTools = await this.#toolBinding.bind(this.#prepared, admission, this.#controller.signal)
          if (!this.#boundTools || typeof this.#boundTools.close !== 'function') {
            throw new TypeError('Trusted tool binding returned no retirement handle')
          }
        } catch (error) {
          this.cancel(error)
          throw unconfirmed('Native tool callback binding could not be confirmed.', error)
        }
      }

      if (this.#cancelRequested) {
        await this.#requestNativeCancel()
      } else {
        try {
          await this.#bridge.execute(admission, this.#prepared, this.#controller.signal)
        } catch (error) {
          this.cancel(error)
          throw unconfirmed('Isolated execution ended without a confirmed terminal state.', error)
        }
      }
      if (this.#cancelPromise) await this.#cancelPromise
      receipt = await this.#bridge.settle(admission)
      if (this.#cancelPromise) await this.#cancelPromise
      this.#terminalRead = true
    } catch (error) {
      failure = error
      if (this.#admission) {
        try {
          this.cancel(error)
          if (!this.#terminalRead) await this.#requestNativeCancel()
        } catch (cancelError) {
          failure = unconfirmed('Cancellation could not be confirmed.', cancelError)
        }
      }
    } finally {
      if (this.#boundTools) {
        try { await this.#boundTools.close() }
        catch (error) { failure = unconfirmed('Tool callback retirement could not be confirmed.', error) }
      }
      if (this.#admission) {
        try {
          await this.#bridge.release(this.#admission)
        } catch (error) {
          failure = unconfirmed('Native run retirement could not be confirmed.', error)
        }
      }
      this.#finished = true
      this.#externalSignal?.removeEventListener('abort', this.#onExternalAbort)
    }

    if (failure) {
      if (failure?.code === 'ANDROID_EXECUTION_CANCELLED') throw failure
      if (failure?.code === 'ANDROID_EXECUTION_UNCONFIRMED') throw failure
      throw unconfirmed('Native execution did not return a trustworthy receipt.', failure)
    }
    let projected
    try {
      projected = projectIsolatedReceipt(receipt, this.runId)
    } catch (error) {
      throw unconfirmed('Native terminal receipt failed ownership validation.', error)
    }
    if (this.#cancelRequested && projected.state === 'completed') {
      throw unconfirmed('Native run completed after cancellation; output was withheld.')
    }
    return projected
  }
}

export function startIsolatedExecutionRun(options) {
  return new IsolatedExecutionRun(options)
}
