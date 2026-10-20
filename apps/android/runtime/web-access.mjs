import WebServer from '@deepseek-ai/dsh-host-webserver'
import * as WebApp from '@deepseek-ai/dsh-web-app'

/** App-owned listener preferences never enter the browser-editable Settings namespace. */
export class WebAccess {
  constructor(ctx, transport) {
    this.ctx = ctx
    this.transport = transport
    this.preferences = { enabled: false, scope: 'local', port: 3080 }
    this.state = { phase: 'disabled', host: null, url: null, error: null }
    this.tail = Promise.resolve()
    this.server = undefined
    this.frontend = undefined
  }
  status() { return { ...this.preferences, ...this.state } }
  publish(state) {
    this.state = state
    this.transport.notify('web.changed', this.status())
  }
  serialize(action) {
    const result = this.tail.then(action)
    this.tail = result.catch(() => {})
    return result
  }
  restore() {
    return this.serialize(async () => {
      const saved = await this.transport.request('native.web.preferences', {})
      this.preferences = this.validate(saved)
      await this.reconcile()
      return this.status()
    })
  }
  validate(value) {
    if (typeof value.enabled !== 'boolean' || !['local', 'lan'].includes(value.scope)
      || !Number.isInteger(value.port) || value.port < 1024 || value.port > 65535) {
      throw new Error('Web settings require enabled, local/lan scope, and a port from 1024 to 65535')
    }
    return { enabled: value.enabled, scope: value.scope, port: value.port }
  }
  configure(value) {
    const next = this.validate(value)
    return this.serialize(async () => {
      await this.transport.request('native.web.save', next)
      this.preferences = next
      await this.reconcile(true)
      return this.status()
    })
  }
  refresh() { return this.serialize(async () => { await this.reconcile(); return this.status() }) }
  rotate() { return this.serialize(async () => { await this.reconcile(true); return this.status() }) }
  async close() {
    const frontend = this.frontend, server = this.server
    this.frontend = undefined; this.server = undefined
    if (frontend) await frontend.dispose()
    if (server) await server.dispose()
    if (this.ctx.get('connection')) await this.ctx.connection.rotateBrowserCredentials()
  }
  async reconcile(force = false) {
    try {
      let host = null
      if (this.preferences.enabled) {
        if (this.preferences.scope === 'local') host = '127.0.0.1'
        else {
          const network = await this.transport.request('native.network.addresses', {})
          host = network.addresses[0] ?? null
        }
      }
      if (!force && this.state.phase === 'listening' && this.state.host === host
        && this.ctx.get('webServer')?.port === this.preferences.port) return
      await this.close()
      if (!this.preferences.enabled || host === null) {
        this.publish({ phase: this.preferences.enabled ? 'waiting-network' : 'disabled', host: null, url: null, error: null })
        return
      }
      this.publish({ phase: 'starting', host: null, url: null, error: null })
      this.server = this.ctx.plugin(WebServer, { host, port: this.preferences.port, compression: 'gzip' })
      await this.server
      this.frontend = this.ctx.plugin(WebApp, { openBrowser: false, printUrl: false, surfaceContext: false })
      await this.frontend
      const loader = this.ctx.get('loader')
      if (loader === undefined) throw new Error('The DSH profile loader is unavailable')
      await loader.await()
      const listener = this.ctx.get('webServer')
      if (listener === undefined) throw new Error('Web listener did not become available')
      const url = this.ctx.connection.authenticatedUrl(listener.getOrigin() + '/')
      this.publish({ phase: 'listening', host, url, error: null })
    } catch (error) {
      await this.close()
      this.publish({ phase: 'failed', host: null, url: null, error: String(error) })
    }
  }
}
