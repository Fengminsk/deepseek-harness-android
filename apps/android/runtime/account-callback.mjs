import { createServer } from 'node:http'
import { AccountCallback } from '@deepseek-ai/dsh-deepseek-account-platform'

const activePhases = new Set(['initializing', 'waiting-browser', 'exchanging', 'committing'])

/** A callback-only listener, never the Web frontend, authenticated RPC, or another account owner. */
export class AndroidAccountCallback extends AccountCallback {
  static inject = ['deepseekAccount']

  constructor(ctx) {
    super(ctx)
    this.listeners = new Map()
    this.tail = Promise.resolve()
    this.closed = false
    ctx.effect(() => () => this.close())
  }

  signIn(client) {
    const operation = this.tail.then(() => this.begin(client))
    this.tail = operation.catch(() => {})
    return operation
  }

  async begin(client) {
    if (this.closed) throw new Error('Account callback carrier is closed')
    const state = await this.ctx.deepseekAccount.getState()
    if (this.closed) throw new Error('Account callback carrier is closed')
    if (activePhases.has(state.attempt?.phase)) return state
    const record = { lifetime: new AbortController(), route: null, closing: null }
    record.server = createServer((request, response) => {
      const validHost = request.headers.host === new URL(record.origin).host
      let path
      try { path = new URL(request.url ?? '/', record.origin).pathname } catch {}
      response.setHeader('cache-control', 'no-store')
      if (!validHost) { response.writeHead(421).end(); return }
      if (path !== '/oauth/callback' || !record.route) { response.writeHead(404).end(); return }
      try {
        Promise.resolve(record.route.handler(request, response)).catch(() => {
          if (!response.headersSent) response.writeHead(500)
          response.end()
        })
      } catch {
        if (!response.headersSent) response.writeHead(500)
        response.end()
      }
    })
    record.server.headersTimeout = 10000
    record.server.requestTimeout = 15000
    record.server.on('upgrade', (_request, socket) => socket.destroy())
    try {
      await new Promise((resolve, reject) => {
        record.server.once('error', reject)
        record.server.listen(0, '127.0.0.1', () => {
          record.server.off('error', reject)
          resolve()
        })
      })
      if (this.closed) throw new Error('Account callback carrier is closed')
      record.origin = `http://127.0.0.1:${record.server.address().port}`
      this.listeners.set(record.origin, record)
      const result = await this.ctx.deepseekAccount.startSignIn(client, record.origin, 'desktop')
      record.attemptId = result.attempt?.id
      record.watch = this.watch(record).catch(error => {
        if (!record.lifetime.signal.aborted) console.error('Account callback observation failed:', error.message)
        return this.closeRecord(record)
      })
      return result
    } catch (error) {
      await this.closeRecord(record)
      throw error
    }
  }

  register(origin, route) {
    const record = this.listeners.get(origin)
    if (record) {
      if (route.kind !== 'exact' || route.path !== '/oauth/callback' || record.route) {
        throw new Error('Account callback carrier only accepts one exact OAuth callback')
      }
      record.route = route
      return () => this.closeRecord(record)
    }
    // Browser-initiated attempts keep their original Web route and lifecycle.
    const web = this.ctx.get('webServer')
    if (!web) throw new Error('The browser callback listener is not running')
    return web.register(route)
  }

  async watch(record) {
    for await (const state of this.ctx.deepseekAccount.watch(record.lifetime.signal)) {
      if (state.attempt?.id !== record.attemptId || !activePhases.has(state.attempt.phase)) {
        // The provider settles its captured HTTP response before disposing its route.
        if (!record.route) await this.closeRecord(record)
        return
      }
    }
  }

  closeRecord(record) {
    if (record.closing) return record.closing
    record.lifetime.abort()
    if (this.listeners.get(record.origin) === record) this.listeners.delete(record.origin)
    record.route = null
    record.closing = new Promise(resolve => {
      record.server.close(() => resolve())
      record.server.closeAllConnections()
    })
    return record.closing
  }

  async close() {
    this.closed = true
    await this.tail
    await Promise.all([...this.listeners.values()].map(record => this.closeRecord(record)))
  }
}

export default AndroidAccountCallback
