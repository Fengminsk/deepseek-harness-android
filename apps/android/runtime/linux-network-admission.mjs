import { createHash } from 'node:crypto'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { prepareLinuxVmCommand } from './native-linux-vm.mjs'
import { isFirstPartyLinuxDefinition } from './tool-linux-vm.mjs'
import { approvalAuditIdentity } from './interaction-receipts.mjs'
import { armLinuxNetworkGrant, discardLinuxNetworkGrant, LinuxNetworkApprovalError,
  requireNativeLinuxNetworkBridge } from './native-linux-network.mjs'

const owners = new WeakSet()

function object(value, allowed) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))
    || Reflect.ownKeys(value).some(key => !allowed.includes(key)
      || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) {
    throw new TypeError('Invalid Linux command arguments')
  }
}

function exactHost(host) {
  if (typeof host !== 'string' || host.length < 4 || host.length > 253
    || host.split('.').length < 2 || /^\d+$/u.test(host.split('.').at(-1))
    || /(?:^|\.)(?:localhost|local|internal|localdomain|lan|test|invalid|example)$/u.test(host)
    || /(?:^|\.)home\.arpa$/u.test(host)) return false
  return host.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(label))
}

/**
 * Parse model intent only. Requested hosts never constitute network authority.
 * @param args - Command, timeout and an optional explicit host list plus request count.
 * @returns A copied command and optional bounded network request.
 */
export function prepareLinuxModelCommand(args) {
  object(args, ['command', 'timeoutMs', 'networkHosts', 'networkCallLimit'])
  const command = prepareLinuxVmCommand({ command: args.command,
    ...(args.timeoutMs === undefined ? {} : { timeoutMs: args.timeoutMs }) })
  if (args.networkHosts === undefined && args.networkCallLimit === undefined) return { command, network: null }
  if (!Array.isArray(args.networkHosts) || args.networkHosts.length < 1 || args.networkHosts.length > 32
    || Array.from(args.networkHosts).some(host => !exactHost(host))
    || new Set(args.networkHosts).size !== args.networkHosts.length
    || !Number.isSafeInteger(args.networkCallLimit) || args.networkCallLimit < 1 || args.networkCallLimit > 64) {
    throw new TypeError('Linux network requires 1–32 distinct exact lowercase DNS hosts and networkCallLimit 1–64')
  }
  return { command, network: Object.freeze({ exactHosts: Object.freeze([...args.networkHosts]),
    networkCallLimit: args.networkCallLimit }) }
}

/**
 * Answer only this owner's exact requests through the native trusted UI, then flush original DSH audit.
 * @param ctx - Live tools, Agents, approval and durable Session services.
 * @param bridge - App-owned native network review adapter.
 * @returns Admission owner; the existing ApprovalService still decides never, cancellation and audit.
 */
export function createLinuxNetworkAdmission(ctx, bridge) {
  requireNativeLinuxNetworkBridge(bridge)
  const approval = ctx.get('approval')
  if (typeof approval?.request !== 'function' || typeof ctx.sessions?.flush !== 'function') {
    throw new TypeError('Linux network requires original approval and durable Session services')
  }
  const pending = new WeakMap()
  let closed = false
  ctx.on('approval/request', (request, next) => {
    const call = pending.get(request)
    if (!call) return next()
    return call.answer = (async () => {
      try {
        call.validate()
        const approvalAuditId = approvalAuditIdentity(request.agent, request)
        if (!approvalAuditId) throw new TypeError('Linux review cannot identify its original approval audit')
        call.auditId = approvalAuditId
        call.review = await bridge.review({ ...call.plan, approvalAuditId }, request.signal)
        return call.review.outcome
      } catch (error) {
        call.failure = error
        return request.signal.aborted ? 'cancelled' : 'unavailable'
      }
    })()
  }, { prepend: true })
  ctx.effect(() => async () => { closed = true; await bridge.dispose() })
  const owner = Object.freeze({
    async request(execution, command, network, persistChanges, revalidate) {
      const agent = execution?.agent
      const definition = ctx.tools.get('linux_exec', agent)
      const registration = ctx.tools.registrationIdentity('linux_exec', agent)
      const validate = () => {
        execution.signal.throwIfAborted()
        if (closed || execution.name !== 'linux_exec' || !ctx.tools.isActiveExecution(execution)
          || !agent || ctx.agents.get(agent.id) !== agent || execution.agent !== agent
          || ctx.tools.get('linux_exec', agent) !== definition
          || ctx.tools.registrationIdentity('linux_exec', agent) !== registration
          || !isFirstPartyLinuxDefinition(definition, agent)
          || revalidate() !== persistChanges) {
          throw new LinuxNetworkApprovalError('Linux 联网审批对应的任务或权限已变化，命令未启动。',
            'linux-vm/network-approval-stale')
        }
      }
      validate()
      const digest = createHash('sha256').update(command.command).digest('hex')
      const reason = `Linux HTTPS GET: ${network.exactHosts.join(', ')}; calls=${network.networkCallLimit}; `
        + `timeoutMs=${command.timeoutMs}; persistChanges=${persistChanges}; commandSha256=${digest}`
      const request = { agent, toolName: 'linux_exec', callId: execution.callId, reason,
        displayReason: {
          en: 'Review this exact Linux command, HTTPS hosts and network route in the App approval dialog. Permission applies once.',
          zh: '请在 App 授权页面核对本条 Linux 命令、HTTPS 域名与网络路由，仅允许本次执行。',
        }, signal: execution.signal }
      const call = { validate, plan: { sessionId: String(agent.session.id), callId: String(execution.callId),
        ...command, persistChanges, ...network }, review: undefined, failure: undefined, auditId: undefined }
      pending.set(request, call)
      const auditStart = agent.session.seq
      let armed = false
      try {
        const outcome = await approval.request(request)
        // ApprovalService may settle cancellation before its answerer returns.
        // Join the native review and revocation before the tool relinquishes it.
        await call.answer
        if (call.failure) throw call.failure
        if (outcome !== 'allowed-once' || call.review?.outcome !== 'allowed-once') {
          throw new LinuxNetworkApprovalError(outcome === 'rejected' ? '本次 Linux 联网未获批准，命令未启动。'
            : outcome === 'cancelled' ? '本次 Linux 联网审批已取消，命令未启动。'
              : 'Linux 联网审批不可用，命令未启动。',
          `linux-vm/network-${outcome === 'allowed-once' ? 'unavailable' : outcome}`)
        }
        validate()
        const decisions = []
        for (let seq = auditStart; seq < agent.session.seq; seq++) {
          const event = agent.session.eventAt(seq)
          if (event?.type === 'approval/decided' && event.data.id === call.auditId) decisions.push(event)
        }
        if (decisions.length !== 1 || decisions[0].data.outcome !== 'allowed-once') {
          throw new LinuxNetworkApprovalError('Linux 联网审批缺少原始决定记录，命令未启动。')
        }
        let flushed
        try { flushed = await ctx.sessions.flush(agent.session) }
        catch (cause) { throw new LinuxNetworkApprovalError('Linux 联网审批记录未能保存，命令未启动。', undefined, cause) }
        if (flushed !== true) {
          throw new LinuxNetworkApprovalError('Linux 联网审批记录未能保存，命令未启动。')
        }
        validate()
        armLinuxNetworkGrant(call.review.ticket, validate)
        execution.deferContext(createUserMessage({ source: { kind: 'android-linux-network-approval' },
          content: [{ type: 'text', text: JSON.stringify({ linuxNetworkApproval: { ...call.review.audit,
            exactHosts: network.exactHosts, networkCallLimit: network.networkCallLimit,
            commandSha256: digest, timeoutMs: command.timeoutMs, persistChanges } }) }] }))
        armed = true
        return call.review.ticket
      } finally {
        pending.delete(request)
        if (!armed && call.review?.ticket) await discardLinuxNetworkGrant(call.review.ticket)
      }
    },
  })
  owners.add(owner)
  return owner
}

/** Reject model JSON or a substitute callback where the live native approval owner is required. */
export function requireLinuxNetworkAdmission(value) {
  if (!owners.has(value)) throw new TypeError('App-owned Linux network admission required')
  return value
}
