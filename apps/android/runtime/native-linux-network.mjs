import { randomUUID } from 'node:crypto'
import { HarnessError } from '@deepseek-ai/dsh-llm'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u
const grants = new WeakMap()
const bridges = new WeakSet()
const OUTCOMES = new Set(['allowed-once', 'rejected', 'cancelled', 'unavailable'])

/** A native approval could not be safely issued or withdrawn; no new guest command is dispatched. */
export class LinuxNetworkApprovalError extends HarnessError {
  constructor(message, code = 'linux-vm/network-approval-unavailable', cause) {
    super(message, code, { cause })
  }
}

async function request(transport, method, params, milliseconds) {
  const signal = AbortSignal.timeout(milliseconds)
  let reject
  const deadline = new Promise((_resolve, fail) => { reject = fail })
  const onAbort = () => reject(signal.reason)
  signal.addEventListener('abort', onAbort, { once: true })
  try { return await Promise.race([transport.request(method, params, signal), deadline]) }
  finally { signal.removeEventListener('abort', onAbort) }
}

function owned(ticket) {
  const record = ticket && grants.get(ticket)
  if (!record || record.used || record.closed) throw new TypeError('A current native Linux network approval is required')
  return record
}

/**
 * Mark the native decision usable only after its original DSH approval audit was flushed.
 * @param ticket - Private native review receipt, never a model argument.
 * @param validate - Recheck the original live execution and policy immediately before dispatch.
 */
export function armLinuxNetworkGrant(ticket, validate) {
  const record = owned(ticket)
  if (record.armed || typeof validate !== 'function') throw new TypeError('Linux approval was already armed')
  validate()
  record.validate = validate
  record.armed = true
}

/**
 * Read the run identity without exposing its single-use native token.
 * @param ticket - An armed native approval.
 * @returns The exact approved run and Session identities.
 */
export function linuxNetworkGrantIdentity(ticket) {
  const record = owned(ticket)
  if (!record.armed) throw new TypeError('Linux approval has no flushed Session decision')
  return Object.freeze({ id: record.plan.id, sessionId: record.plan.sessionId })
}

/**
 * Consume once, matching the exact execution and rechecking live policy after recovery inspection.
 * @param ticket - Host-only approval, never copied from JSON.
 * @param execution - Exact native command parameters.
 * @returns Native-only token and original DSH audit identity.
 */
export function consumeLinuxNetworkGrant(ticket, execution) {
  const record = owned(ticket)
  if (!record.armed || ['id', 'sessionId', 'command', 'timeoutMs', 'persistChanges']
    .some(key => execution[key] !== record.plan[key])) throw new TypeError('Linux command differs from its approval')
  record.validate()
  record.used = true
  record.release()
  return Object.freeze({ approvalToken: record.token, approvalAuditId: record.plan.approvalAuditId })
}

/** Withdraw an unused native review or grant; a consumed grant belongs to the Linux execution owner. */
export async function discardLinuxNetworkGrant(ticket) {
  const record = ticket && grants.get(ticket)
  if (!record || record.used) return
  await record.revoke()
}

/**
 * App-private native UI adapter. Neither a model host list nor a Node boolean grants network access.
 * @param transport - The production Node-to-App RPC transport.
 * @returns The bounded review owner; disposal revokes its outstanding reviews and unused grants.
 */
export function createNativeLinuxNetworkBridge(transport) {
  if (typeof transport?.request !== 'function') throw new TypeError('Native Linux network transport required')
  const active = new Set()
  let closed = false
  const bridge = Object.freeze({
    async review(input, signal) {
      if (closed) throw new LinuxNetworkApprovalError('Linux 联网审批已停止，请重新启动服务后查看状态。')
      signal.throwIfAborted()
      const plan = Object.freeze({ ...input, id: randomUUID() })
      if (!UUID.test(plan.approvalAuditId)) throw new TypeError('Original DSH approval audit identity required')
      const ticket = Object.freeze({})
      const record = { plan, used: false, armed: false, closed: false, token: undefined,
        release: () => active.delete(record), revoke: undefined }
      let revocation
      record.revoke = () => revocation ??= (async () => {
        record.closed = true
        try {
          const reply = await request(transport, 'native.linuxVm.network.cancelReview',
            { id: plan.id, sessionId: plan.sessionId }, 10_000)
          if (reply?.id !== plan.id || reply?.sessionId !== plan.sessionId || reply?.revoked !== true) {
            throw new Error('Native Linux network revocation was not confirmed')
          }
        } catch (cause) {
          closed = true
          throw new LinuxNetworkApprovalError('无法确认 Linux 联网授权已撤销，已停止后续联网审批。请查看任务状态。',
            'linux-vm/network-revocation-uncertain', cause)
        } finally { active.delete(record) }
      })()
      active.add(record)
      grants.set(ticket, record)
      const onAbort = () => { void record.revoke().catch(() => { /* Awaited below before returning. */ }) }
      signal.addEventListener('abort', onAbort, { once: true })
      try {
        const reply = await request(transport, 'native.linuxVm.network.review', plan, 130_000)
        if (reply?.id !== plan.id || reply?.sessionId !== plan.sessionId || !OUTCOMES.has(reply?.outcome)) {
          throw new Error('Native Linux network decision did not match its review')
        }
        if (signal.aborted || closed || record.closed) {
          await record.revoke()
          signal.throwIfAborted()
          throw new LinuxNetworkApprovalError('Linux 联网审批已失效，命令未启动。')
        }
        if (reply.outcome !== 'allowed-once') {
          await record.revoke()
          return Object.freeze({ outcome: reply.outcome })
        }
        if (!UUID.test(reply.token) || !UUID.test(reply.approvalId)
          || typeof reply.route !== 'string' || !reply.route || reply.route.length > 256) {
          throw new Error('Native Linux network decision has no bound approval token or route')
        }
        record.token = reply.token
        return Object.freeze({ outcome: reply.outcome, ticket,
          audit: Object.freeze({ runId: plan.id, approvalId: reply.approvalId,
            approvalAuditId: plan.approvalAuditId, route: reply.route }) })
      } catch (cause) {
        await record.revoke()
        if (signal.aborted) throw signal.reason
        if (cause instanceof LinuxNetworkApprovalError) throw cause
        throw new LinuxNetworkApprovalError('Linux 联网审批结果无法确认，命令未启动。', undefined, cause)
      } finally { signal.removeEventListener('abort', onAbort) }
    },
    async dispose() {
      closed = true
      const results = await Promise.allSettled([...active].map(record => record.revoke()))
      const failure = results.find(result => result.status === 'rejected')
      if (failure) throw failure.reason
    },
  })
  bridges.add(bridge)
  return bridge
}

/** Reject substitute native approval adapters at the model admission owner. */
export function requireNativeLinuxNetworkBridge(bridge) {
  if (!bridges.has(bridge)) throw new TypeError('App-owned native Linux network bridge required')
  return bridge
}
