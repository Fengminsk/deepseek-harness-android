import { randomUUID } from 'node:crypto'
import { performance } from 'node:perf_hooks'

const RESERVATION_MS = 15_000
const tokenPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

/** Process-local maintenance admission over the original PluginManager operation lifecycle. */
export class AppPackageOperations {
  constructor(ctx, { pendingAppSessions = () => 0,
    terminalActivity = () => ({ live: 0, pending: 0 }) } = {}) {
    this.ctx = ctx
    this.manager = ctx.get('pluginManager')
    this.epoch = randomUUID()
    this.reservation = undefined
    this.closed = false
    this.pendingAppSessions = pendingAppSessions
    this.terminalActivity = terminalActivity
    this.pendingAppWork = 0
    this.dispose = ctx.on('plugin-manager/before-package-operation', () => {
      this.expire()
      if (this.closed || this.reservation) {
        throw Object.assign(new Error('服务正在切换模式，请等待切换完成后再管理插件'), {
          code: 'ANDROID_RUNTIME_TRANSITION',
        })
      }
    })
  }

  expire() {
    if (this.reservation?.state === 'reserved' && performance.now() >= this.reservation.expiresAt) this.clear()
  }

  clear() {
    clearTimeout(this.reservation?.timer)
    this.reservation = undefined
  }

  /** App requests admitted after reservation must not run in the old service. */
  assertWorkAllowed() {
    this.expire()
    if (this.closed || this.reservation) {
      throw Object.assign(new Error('服务正在切换模式，请等待切换完成后再发送请求'), {
        code: 'ANDROID_RUNTIME_TRANSITION',
      })
    }
  }

  /** The admission and the in-flight receipt share one synchronous boundary. */
  async runWork(action) {
    this.assertWorkAllowed()
    this.pendingAppWork++
    try { return await action() }
    finally { this.pendingAppWork-- }
  }

  /** A service replacement must not silently kill an Agent turn or a live job. */
  activity() {
    try {
      const agents = this.ctx.agents?.list()
      const jobs = this.ctx.get('jobs')?.snapshot()
      if (!Array.isArray(agents) || !Array.isArray(jobs)) return 'unknown'
      const pendingAppSessions = this.pendingAppSessions()
      if (!Number.isSafeInteger(pendingAppSessions) || pendingAppSessions < 0) return 'unknown'
      const terminals = this.terminalActivity()
      if (!Number.isSafeInteger(terminals?.live) || terminals.live < 0
        || !Number.isSafeInteger(terminals?.pending) || terminals.pending < 0) return 'unknown'
      let busy = pendingAppSessions > 0 || this.pendingAppWork > 0
        || terminals.live > 0 || terminals.pending > 0
      for (const agent of agents) {
        if (agent?.status !== 'idle' && agent?.status !== 'running'
          || !Array.isArray(agent?.inbox?.nextTurn) || !Array.isArray(agent?.inbox?.nextStep)) return 'unknown'
        if (agent.status === 'running' || agent.inbox.nextTurn.length || agent.inbox.nextStep.length) busy = true
      }
      for (const job of jobs) {
        if (!['running', 'stopping', 'completed', 'killed', 'failed'].includes(job?.status)) return 'unknown'
        if (job.status === 'running' || job.status === 'stopping') busy = true
      }
      return busy ? 'busy' : 'idle'
    } catch {
      return 'unknown'
    }
  }

  activityRefusal(token) {
    const activity = this.activity()
    if (activity === 'busy') return this.response(token, false, 'runtime/task-busy',
      'Agent 任务、排队输入、终端或后台作业尚未结束，未切换服务')
    if (activity === 'unknown') return this.response(token, false, 'runtime/task-state-unknown',
      '无法确认 Agent、终端与后台作业状态，未切换服务；请重新读取状态')
  }

  packageRefusal(token) {
    if (typeof this.manager?.packageOperationsSnapshot !== 'function') {
      return this.response(token, false, 'runtime/package-state-unknown', '无法确认插件管理操作状态，未切换服务')
    }
    let packages
    try { packages = this.manager.packageOperationsSnapshot() }
    catch { return this.response(token, false, 'runtime/package-state-unknown', '无法确认插件管理操作状态，未切换服务') }
    if (!Array.isArray(packages)) {
      return this.response(token, false, 'runtime/package-state-unknown', '无法确认插件管理操作状态，未切换服务')
    }
    if (packages.length > 0) return this.response(token, false, 'runtime/package-busy',
      '插件管理操作尚未完成，未切换服务；请等待操作结束')
  }

  response(token, accepted, code, message) {
    return { token, epoch: this.epoch, accepted, ...(accepted ? { state: this.reservation.state } : { code, message }) }
  }

  /** Snapshot check and reservation assignment run synchronously in the same JavaScript turn. */
  reserve({ token }) {
    if (typeof token !== 'string' || !tokenPattern.test(token)) throw new TypeError('Invalid transition token')
    this.expire()
    if (this.closed) return this.response(token, false, 'runtime/unavailable', '运行时已关闭，未切换服务')
    if (this.reservation) return this.response(token, false, 'runtime/busy', '服务模式正在切换，请等待操作结果')
    const packageRefusal = this.packageRefusal(token)
    if (packageRefusal) return packageRefusal
    const activityRefusal = this.activityRefusal(token)
    if (activityRefusal) return activityRefusal
    const reservation = { token, state: 'reserved', expiresAt: performance.now() + RESERVATION_MS }
    this.reservation = reservation
    reservation.timer = setTimeout(() => {
      if (this.reservation === reservation) this.clear()
    }, RESERVATION_MS)
    reservation.timer.unref()
    return this.response(token, true)
  }

  /** Commit seals admission until explicit release or process exit; no lease may reopen it after this ACK. */
  commit({ token, epoch }) {
    this.expire()
    if (this.closed || epoch !== this.epoch || this.reservation?.token !== token) {
      return this.response(token, false, 'runtime/transition-expired', '服务切换预留已失效，旧服务未被主动停止；请重新读取状态')
    }
    // An Agent can start while the App saves the maintenance preference.
    // Recheck the original owners at the last Node acknowledgment, not a UI snapshot.
    const refusal = this.packageRefusal(token) ?? this.activityRefusal(token)
    if (refusal) { this.clear(); return refusal }
    clearTimeout(this.reservation.timer)
    this.reservation.state = 'committed'
    return this.response(token, true)
  }

  /** A release without an epoch is permitted only for a reservation whose acknowledgment was lost. */
  release({ token, epoch }) {
    if ((epoch === undefined || epoch === this.epoch) && this.reservation?.token === token) this.clear()
    return { token, epoch: this.epoch, released: this.reservation?.token !== token }
  }

  close() {
    if (this.closed) return
    this.closed = true
    this.clear()
    this.dispose()
  }
}
