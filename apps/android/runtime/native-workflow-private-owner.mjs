import { createWorkflowSubagentBackend, installWorkflowSubagentPreset } from './workflow-subagent-backend.mjs'
import { workflowDslNativeProgram } from './workflow-dsl-guest.mjs'
import { createWorkflowSessionRecord } from './workflow-session-record.mjs'
import { inspectWorkflowColdRun } from './workflow-cold-observation.mjs'
import { createAppOwnedModelWorkflowAdmission } from './model-workflow-admission.mjs'

const MAX_BACKGROUND_RESULT_CHARS = 12_000
// The App owns the native deadline and cancels at deadline + 3 s. Node must outlive
// that path so the App settles first, but an unanswered request must end the tool call.
const EXECUTION_GRACE_MILLIS = 30_000
// One bounded attempt per cleanup call; a suspended or dead App cannot answer at all.
const CLEANUP_TIMEOUT_MILLIS = 30_000

function unanswered(label, timeoutMillis) {
  return Object.assign(new Error(`${label} did not answer within ${timeoutMillis} ms`),
    { code: 'ANDROID_WORKFLOW_UNANSWERED' })
}

/** Race one App operation against a bound and, when supplied, the tool's abort signal. */
async function withinTimeout(operation, timeoutMillis, label, signal) {
  if (!Number.isSafeInteger(timeoutMillis) || timeoutMillis <= 0) {
    throw new TypeError('Workflow operation timeout is invalid')
  }
  let timer
  let abortListener
  try {
    const pending = [Promise.resolve().then(operation),
      new Promise((_resolve, reject) => {
        timer = setTimeout(() => reject(unanswered(label, timeoutMillis)), timeoutMillis)
      })]
    if (signal) {
      pending.push(new Promise((_resolve, reject) => {
        abortListener = () => reject(signal.reason instanceof Error
          ? signal.reason : new Error(`${label} was cancelled`))
        if (signal.aborted) abortListener()
        else signal.addEventListener('abort', abortListener, { once: true })
      }))
    }
    return await Promise.race(pending)
  } finally {
    clearTimeout(timer)
    if (signal && abortListener) signal.removeEventListener('abort', abortListener)
  }
}

function backgroundResult(receipt, prepared) {
  const output = JSON.parse(receipt.outputJson)
  const value = JSON.stringify(output.value, null, 2)
  const rendered = value.length > MAX_BACKGROUND_RESULT_CHARS
    ? `${value.slice(0, MAX_BACKGROUND_RESULT_CHARS)}\n… [truncated]` : value
  return `workflow "${prepared.meta.name}" completed (${output.agentsStarted} agents).\nReturn value:\n${rendered}`
}

/**
 * Internal App-side owner for one App-prepared native workflow. It admits and
 * retires the native run, records the original workflow Session events, and
 * never exposes a model tool. The Binder bridge persists each child ID before
 * Node receives a START_CHILD callback.
 */
export function createNativeWorkflowPrivateOwner(ctx, callbacks, transport) {
  if (!callbacks || typeof callbacks.bind !== 'function' || typeof callbacks.dispose !== 'function') {
    throw new TypeError('Native workflow callbacks are required')
  }
  let preset = null
  let closed = false
  const backends = new Set()
  const activeRunIds = new Set()
  const backgroundRuns = new Set()
  function ready() {
    if (closed) throw new Error('Private workflow owner has closed')
    if (!preset) preset = installWorkflowSubagentPreset(ctx).catch(error => {
      preset = null
      throw error
    })
    return preset
  }
  return Object.freeze({
    /** Capture a reviewed original definition for this live parent. No model tool is published. */
    modelAdmission({ agent, definition, registrationIdentity, issueHost, modelAvailable }) {
      if (closed) throw new Error('Private workflow owner has closed')
      return createAppOwnedModelWorkflowAdmission({
        runtime: ctx.tools, agents: ctx.agents,
        agent, definition, registrationIdentity, issueHost,
        runPrepared: request => this.runDsl(request),
        startBackground: request => this.startBackgroundDsl(request),
        modelAvailable,
        isAvailable: () => !closed,
      })
    },
    /** Read-only status for a recorded run. No Agent resume or native replay. */
    inspectRun(request) {
      if (closed) throw new Error('Private workflow owner has closed')
      return inspectWorkflowColdRun(ctx, request, activeRunIds, transport)
    },
    /** App-private detached run owned by the original jobs registry and parent Agent. */
    startBackgroundDsl({ prepared, parent, toolCall } = {}) {
      if (closed) throw new Error('Private workflow owner has closed')
      if (typeof parent?.id !== 'string' || ctx.agents?.get(parent.id) !== parent
        || prepared?.sessionId !== parent.session?.id) {
        throw new TypeError('Background workflow requires the exact live parent Agent and Session')
      }
      // Validate synchronously before the registry commits a job ID. A rejected
      // admission must leave no detached producer or registered job behind.
      workflowDslNativeProgram(prepared)
      const jobs = ctx.get?.('jobs')
      if (!jobs || typeof jobs.start !== 'function') {
        throw new Error('Background workflow requires the original jobs registry')
      }
      const owner = this
      const jobId = jobs.start({
        kind: 'workflow', label: prepared.meta.name, owner: parent.id, toolCall,
        run(job) {
          const controller = new AbortController()
          const tracked = { controller, done: null }
          backgroundRuns.add(tracked)
          const done = Promise.resolve().then(() => owner.runDsl({ prepared, parent,
            signal: controller.signal,
            onProgress: async event => {
              if (event.type === 'phase' || event.type === 'log') {
                const line = event.title ?? event.message ?? event.info?.label ?? event.info?.message
                if (typeof line === 'string' && line) job.updateProgress(line.slice(0, 200))
              } else if (event.type === 'agent-start') {
                job.updateProgress(`${event.info.seq} agent(s) started`)
              }
            },
          })).then(receipt => ({ status: 'completed',
            detail: `${JSON.parse(receipt.outputJson).agentsStarted} agents`,
            result: backgroundResult(receipt, prepared),
          }), async error => {
            let observed
            try { observed = await inspectWorkflowColdRun(ctx,
              { sessionId: prepared.sessionId, runId: prepared.runId }, activeRunIds, transport) }
            catch { /* An unreadable Session is uncertain, never a successful cancellation. */ }
            // A missing Session start does not prove native admission never
            // occurred. Only the durable cancelled run-end confirms retirement.
            if (controller.signal.aborted && observed?.state === 'cancelled') {
              return { status: 'killed' }
            }
            return { status: 'failed', detail: observed?.requiresReview
              ? `Workflow requires review: ${String(error)}` : String(error) }
          }).finally(() => { backgroundRuns.delete(tracked) })
          tracked.done = done
          return { cancel(reason) {
            if (!controller.signal.aborted) controller.abort(new Error(reason ?? 'background workflow job killed'))
          }, done }
        },
      })
      return Object.freeze({ kind: 'background', jobId, runId: prepared.runId })
    },
    /** Private App path only. The model-facing workflow tool remains disabled. */
    async runDsl({ prepared, parent, onProgress, signal }) {
      let active = false
      try {
        if (closed) throw new Error('Private workflow owner has closed')
        if (!transport || typeof transport.request !== 'function') {
          throw new TypeError('Native workflow transport is required')
        }
        signal?.throwIfAborted()
        const request = workflowDslNativeProgram(prepared)
        const record = createWorkflowSessionRecord(ctx, prepared, parent)
        if (typeof parent?.id !== 'string' || ctx.agents?.get(parent.id) !== parent) {
          throw new TypeError('Workflow record requires the exact live parent Agent')
        }
        await ready()
        if (closed) throw new Error('Private workflow owner has closed')
        signal?.throwIfAborted()
        let admission, bound, receipt, failure
        let recorded = false
        try {
          admission = await withinTimeout(() => transport.request('native.workflow.admit', request),
            CLEANUP_TIMEOUT_MILLIS, 'native.workflow.admit')
          if (!admission || admission.runId !== prepared.runId || typeof admission.token !== 'string') {
            throw new Error('Native workflow admission was not confirmed')
          }
          await record.start()
          recorded = true
          activeRunIds.add(prepared.runId)
          active = true
          bound = await this.attach({ prepared, admission, parent, signal,
            onProgress: async event => {
              await record.progress(event)
              await onProgress?.(event)
            } })
          const identity = { runId: admission.runId, token: admission.token }
          let abortRequested = false
          let abortCancellation
          const onAbort = () => {
            abortRequested = true
            // Join the native cancellation before settlement or release. A fire-and-forget
            // request can still be retiring children when execute returns.
            abortCancellation ??= withinTimeout(() => transport.request('native.workflow.cancel', identity),
              CLEANUP_TIMEOUT_MILLIS, 'native.workflow.cancel')
              .then(value => value === true
                ? { confirmed: true } : { confirmed: false,
                  error: new Error('Native workflow cancellation was not confirmed') },
              error => ({ confirmed: false, error }))
          }
          signal?.addEventListener('abort', onAbort, { once: true })
          let executionFailure
          try {
            if (signal?.aborted) onAbort()
            signal?.throwIfAborted()
            if (await withinTimeout(() => transport.request('native.workflow.execute', identity),
              prepared.deadlineMillis + EXECUTION_GRACE_MILLIS, 'native.workflow.execute', signal) !== true) {
              throw new Error('Native workflow execution was not confirmed')
            }
          } catch (error) { executionFailure = error }
          finally { signal?.removeEventListener('abort', onAbort) }
          if (signal?.aborted && !abortRequested) onAbort()
          if (abortRequested) {
            const cancellation = await abortCancellation
            const abortError = signal?.reason instanceof Error
              ? signal.reason : new Error('Workflow was cancelled')
            if (!cancellation.confirmed) {
              executionFailure = new AggregateError(
                [executionFailure ?? abortError, cancellation.error],
                'Workflow cancellation is unconfirmed')
            } else if (!executionFailure) executionFailure = abortError
          }
          if (executionFailure) throw executionFailure
        } catch (error) { failure = error }
        if (admission?.runId === prepared.runId && typeof admission.token === 'string') {
          const identity = { runId: admission.runId, token: admission.token }
          let cleanupCertain = true
          if (failure) {
            try {
              if (await withinTimeout(() => transport.request('native.workflow.cancel', identity),
                CLEANUP_TIMEOUT_MILLIS, 'native.workflow.cancel') !== true) {
                throw new Error('Native workflow cancellation was not confirmed')
              }
            }
            catch (error) {
              cleanupCertain = false
              failure = new AggregateError([failure, error], 'Workflow cancellation is unconfirmed')
            }
          }
          if (bound) {
            try { await bound.close() }
            catch (error) {
              cleanupCertain = false
              failure = failure
                ? new AggregateError([failure, error], 'Workflow child retirement is unconfirmed') : error
            }
          }
          try { receipt = await withinTimeout(() => transport.request('native.workflow.settle', identity),
            CLEANUP_TIMEOUT_MILLIS, 'native.workflow.settle') }
          catch (error) { failure = failure
            ? new AggregateError([failure, error], 'Workflow settlement is unconfirmed') : error }
          let confirmedTerminal = false
          if (receipt) {
            try {
              if (receipt.runId !== prepared.runId || receipt.sessionId !== prepared.sessionId
                || receipt.requiresReview !== (receipt.state === 'INTERRUPTED_UNCONFIRMED')
                || !['COMPLETED', 'FAILED', 'CANCELLED', 'INTERRUPTED_UNCONFIRMED'].includes(receipt.state)) {
                throw new Error('Native workflow receipt is invalid')
              }
              if (receipt.state === 'COMPLETED') {
                const result = JSON.parse(receipt.outputJson)
                if (!result || typeof result !== 'object' || Array.isArray(result)
                  || result.stopReason !== 'completed' || !Object.hasOwn(result, 'value')
                  || Object.hasOwn(result, 'error')
                  || !Number.isSafeInteger(result.agentsStarted)
                  || result.agentsStarted !== record.agentsStarted) {
                  throw new Error('Workflow guest did not report completion')
                }
              } else if (receipt.outputJson != null) {
                throw new Error('Noncompleted workflow exposed output')
              }
              confirmedTerminal = !receipt.requiresReview
            } catch (error) { failure = failure
              ? new AggregateError([failure, error], 'Workflow receipt is unconfirmed') : error }
          }
          if (confirmedTerminal && cleanupCertain) {
            let released = false
            try {
              if (await withinTimeout(() => transport.request('native.workflow.release', identity),
                CLEANUP_TIMEOUT_MILLIS, 'native.workflow.release') !== true) {
                throw new Error('Native workflow release was not confirmed')
              }
              released = true
            }
            catch (error) { failure = failure
              ? new AggregateError([failure, error], 'Workflow release is unconfirmed') : error }
            if (released && recorded && (receipt.state !== 'COMPLETED' || !failure)) {
              try {
                await record.finish(receipt.state === 'CANCELLED' ? 'cancelled'
                  : receipt.state === 'FAILED' ? 'error' : 'completed')
              } catch (error) { failure = failure
                ? new AggregateError([failure, error], 'Workflow Session settlement failed') : error }
            }
          }
        }
        if (failure) throw failure
        if (!receipt) throw new Error('Native workflow receipt is missing')
        if (receipt.state !== 'COMPLETED') throw new Error(`Workflow ended as ${receipt.state}`)
        return receipt
      } finally {
        if (active) activeRunIds.delete(prepared?.runId)
      }
    },
    async attach({ prepared, admission, parent, onProgress, signal }) {
      await ready()
      if (closed) throw new Error('Private workflow owner has closed')
      const backend = createWorkflowSubagentBackend({
        ctx, parent, runId: admission?.runId,
        authorize: (_request, childSignal, owner, runId, childId) => {
          childSignal.throwIfAborted()
          return { runId, parentId: owner.id, childId }
        },
      })
      backends.add(backend)
      try {
        const bound = await callbacks.bind({ prepared, admission,
          authorizeChild: backend.authorizeChild,
          activateChild: backend.activateChild, onProgress, signal })
        return Object.freeze({ runId: bound.runId, async close() {
          try {
            await withinTimeout(() => bound.close(), CLEANUP_TIMEOUT_MILLIS, 'workflow child retirement')
          } finally { backend.close(); backends.delete(backend) }
        } })
      } catch (error) {
        backend.close()
        backends.delete(backend)
        throw error
      }
    },
    async dispose() {
      closed = true
      for (const run of backgroundRuns) {
        if (!run.controller.signal.aborted) run.controller.abort(new Error('Workflow owner disposed'))
      }
      try {
        await Promise.allSettled([...backgroundRuns].map(run => run.done))
        await callbacks.dispose()
      }
      finally {
        for (const backend of backends) backend.close()
        backends.clear()
        activeRunIds.clear()
        if (preset) await (await preset)()
      }
    },
  })
}
