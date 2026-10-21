import { randomUUID } from 'node:crypto'
import { performance } from 'node:perf_hooks'

const RESERVATION_MS = 15_000
const tokenPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

/** Process-local maintenance admission over the original PluginManager operation lifecycle. */
export class AppPackageOperations {
  constructor(ctx) {
    this.manager = ctx.get('pluginManager')
    this.epoch = randomUUID()
    this.reservation = undefined
    this.closed = false
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

  response(token, accepted, code, message) {
    return { token, epoch: this.epoch, accepted, ...(accepted ? { state: this.reservation.state } : { code, message }) }
  }

  /** Snapshot check and reservation assignment run synchronously in the same JavaScript turn. */
  reserve({ token }) {
    if (typeof token !== 'string' || !tokenPattern.test(token)) throw new TypeError('Invalid transition token')
    this.expire()
    if (this.closed) return this.response(token, false, 'runtime/unavailable', '运行时已关闭，未切换服务')
    if (this.reservation) return this.response(token, false, 'runtime/busy', '服务模式正在切换，请等待操作结果')
    if (typeof this.manager?.packageOperationsSnapshot !== 'function') {
      return this.response(token, false, 'runtime/package-state-unknown', '无法确认插件管理操作状态，未切换服务')
    }
    if (this.manager.packageOperationsSnapshot().length > 0) {
      return this.response(token, false, 'runtime/package-busy', '插件管理操作尚未完成，未切换服务；请等待操作结束')
    }
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
