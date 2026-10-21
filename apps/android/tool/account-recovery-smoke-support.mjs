import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { createServer as createSocketServer } from 'node:net'
import { once } from 'node:events'
import { join } from 'node:path'
import { createInterface } from 'node:readline'

/** Synthetic durable native credential storage; each read reopens the file. */
export class RecoveryFixtureVault {
  constructor(home) {
    this.path = join(home, 'fixture-native-credentials.json')
    if (!existsSync(this.path)) writeFileSync(this.path, '{}\n', { flag: 'wx' })
  }
  entries() { return JSON.parse(readFileSync(this.path, 'utf8')) }
  request(method, { name, value }) {
    const records = this.entries()
    if (method === 'native.credentials.get') return records[name] ?? null
    if (method === 'native.credentials.names') return Object.keys(records)
    if (method === 'native.credentials.set') records[name] = value
    else if (method === 'native.credentials.remove') delete records[name]
    else throw new Error(`Unexpected native credential operation ${method}`)
    const temporary = `${this.path}.${randomUUID()}.tmp`
    writeFileSync(temporary, JSON.stringify(records) + '\n', { flag: 'wx' })
    renameSync(temporary, this.path)
    return true
  }
}

/** Local account and Messages endpoints with explicit transport/authentication outcomes. */
export class RecoveryFixturePlatform {
  constructor(fail) {
    this.fail = fail
    this.mode = 'online'
    this.listingUnauthorized = false
    this.profileUnauthorized = false
    this.requests = []
    this.initialization = undefined
    this.server = createServer((request, response) => {
      void this.handle(request, response).catch(error => { fail(error); response.destroy(error) })
    })
  }
  async open() {
    this.server.listen(0, '127.0.0.1')
    await once(this.server, 'listening')
    this.origin = `http://127.0.0.1:${this.server.address().port}`
  }
  count(path) { return this.requests.filter(request => request.path === path).length }
  async handle(request, response) {
    const path = new URL(request.url, this.origin).pathname
    const bytes = Buffer.concat(await Array.fromAsync(request)).toString()
    const body = bytes ? JSON.parse(bytes) : {}
    const record = { path, status: 200 }
    this.requests.push(record)
    const finish = (value, status = 200) => {
      record.status = status
      response.writeHead(status, { 'content-type': 'application/json' })
      response.end(JSON.stringify(value))
    }
    const platform = value => finish({ code: 0, data: { biz_code: 0, biz_data: value } })
    if (path === '/auth-api/v0/dsh/auth_init') {
      this.initialization = body
      platform({ authorize_id: 'recovery-fixture', authorize_url: `${this.origin}/dsh/authorize`, expires_in: 60 })
      return
    }
    if (path === '/auth-api/v0/dsh/auth_exchange') {
      assert.equal(createHash('sha256').update(body.code_verifier).digest('base64url'), this.initialization.code_challenge)
      assert.equal(body.redirect_uri, this.initialization.redirect_uri)
      assert.equal(body.code, 'fixture-code')
      // dsh_mock_* is deliberately excluded from inference by the original
      // provider. This synthetic grant is scoped to our explicit loopback issuer.
      platform({ user: null, token: 'fixture-account-grant-not-a-real-token', authorized_url: `${this.origin}/dsh/authorized` })
      return
    }
    if (path === '/auth-api/v0/dsh/auth_cancel' || path === '/auth-api/v0/users/logout') {
      platform(null)
      return
    }
    assert.equal(request.headers['x-dsh-auth-token'], 'fixture-account-grant-not-a-real-token', 'the original account route must authenticate with the stored fixture grant')
    if (this.mode === 'service-unavailable') { finish({ error: 'fixture service unavailable' }, 503); return }
    if (this.mode === 'transport-unavailable') {
      record.status = 'connection-closed'
      response.destroy()
      return
    }
    if (path === '/models') {
      if (this.listingUnauthorized) { finish({ error: 'fixture listing rejected' }, 401); return }
      finish({ object: 'list', data: [{ id: 'deepseek-flash', name: 'Recovery Fixture Flash',
        input_modalities: ['text'], api_capabilities: { anthropic_messages: {} } }] })
      return
    }
    if (path === '/auth-api/v0/users/current') {
      if (this.profileUnauthorized) { finish({ error: 'fixture account rejected' }, 401); return }
      platform({ id: 'recovery-fixture-user', email: 'fixture@example.invalid', id_profile: { name: 'Recovery Fixture', picture: null } })
      return
    }
    if (path === '/api/v0/users/get_user_summary') {
      platform({ normal_wallets: [{ currency: 'CNY', balance: '1.00' }], bonus_wallets: [] })
      return
    }
    if (path === '/api/v0/users/get_unnotified_bonuses') { platform([]); return }
    if (path.endsWith('/messages')) {
      response.writeHead(200, { 'content-type': 'text/event-stream' })
      for (const event of [
        { type: 'message_start', message: { id: `recovery-${this.requests.length}`, model: body.model, usage: { input_tokens: 1, output_tokens: 0 } } },
        { type: 'content_block_start', index: 0, content_block: { type: 'text', text: 'Recovery fixture completed' } },
        { type: 'content_block_stop', index: 0 },
        { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
        { type: 'message_stop' },
      ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
      response.end()
      return
    }
    throw new Error(`Unexpected fixture endpoint ${path}`)
  }
  async close() {
    if (!this.server.listening) return
    await new Promise((resolve, reject) => {
      this.server.close(error => error ? reject(error) : resolve())
      this.server.closeAllConnections()
    })
  }
}

/** One independent Node generation. Native credentials are reconstructed from disk. */
export async function launchRecoveryFixture({ processes, root, home, origin, fail, register }) {
  const vault = new RecoveryFixtureVault(home)
  const ipc = createSocketServer()
  let socket, lines, child, port, closing
  let listening = Promise.resolve()
  const pending = new Map(), notices = [], waiters = new Set()
  let serial = 0, stopped = false, ended = false, failure
  const reject = error => {
    failure ??= error
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear()
    waiters.clear()
    if (!stopped) fail(error)
  }
  const send = frame => {
    if (stopped || ended || !socket) throw new Error('Fixture IPC is closed')
    socket.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  }
  ipc.on('error', reject)
  const receive = line => {
    if (ended || failure) return
    try {
      const frame = JSON.parse(line)
      if (frame.method?.startsWith('native.')) {
        let result
        if (frame.method.startsWith('native.credentials.')) result = vault.request(frame.method, frame.params ?? {})
        else if (frame.method === 'native.storage.root') result = home
        else if (frame.method === 'native.web.preferences') result = { enabled: false, scope: 'local', port: 3080 }
        else if (frame.method === 'native.network.addresses') result = { addresses: [] }
        else throw new Error(`Unexpected native request ${frame.method}`)
        send({ id: frame.id, result })
      } else if (pending.has(frame.id)) {
        const call = pending.get(frame.id)
        pending.delete(frame.id)
        if (frame.error) call.reject(new Error(frame.error.message))
        else if (frame.result?._pocket_error) call.reject(Object.assign(new Error(frame.result._pocket_error.message), frame.result._pocket_error))
        else call.resolve(frame.result)
      } else {
        notices.push(frame)
        for (const waiter of waiters) if (waiter.predicate(frame)) { waiters.delete(waiter); waiter.resolve(frame) }
      }
    } catch (error) { reject(error) }
  }
  ipc.on('connection', connection => {
    if (socket || stopped) { connection.destroy(); reject(new Error('Unexpected fixture IPC connection')); return }
    socket = connection
    socket.on('error', reject)
    lines = createInterface({ input: socket })
    lines.on('error', reject)
    lines.on('line', receive)
  })
  const request = (method, params = {}) => {
    if (failure || stopped) return Promise.reject(failure ?? new Error('Fixture runtime stopping'))
    return new Promise((resolve, reject) => {
      const id = `recovery-${++serial}`
      pending.set(id, { resolve, reject })
      try { send({ id, method, params }) } catch (error) { pending.delete(id); reject(error) }
    })
  }
  const owner = {
    get child() { return child },
    get ipcPort() { return port },
    get outstanding() { return { requests: pending.size, observations: waiters.size } },
    notices, request, vault,
    api: (namespace, method, args = {}) => request('api.call', { namespace, method, args }),
    wait(predicate) {
      if (failure || stopped) return Promise.reject(failure ?? new Error('Fixture runtime stopping'))
      const found = notices.find(predicate)
      return found ? Promise.resolve(found) : new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
    },
    stop() {
      if (closing) return closing
      stopped = true
      reject(new Error('Fixture runtime stopping'))
      closing = (async () => {
        // Disposal owns even an in-flight listen. No child can be acquired after
        // this gate closes, including when the outer smoke deadline fires.
        await Promise.allSettled([listening])
        const cleanup = await Promise.allSettled([
          child ? processes.stop(child) : Promise.resolve(),
          (async () => {
            lines?.close()
            socket?.destroy()
            if (ipc.listening) await new Promise((resolve, reject) => ipc.close(error => error ? reject(error) : resolve()))
          })(),
        ])
        const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
        if (errors.length) throw new AggregateError(errors, 'Fixture generation cleanup did not settle')
      })()
      return closing
    },
  }
  try {
    // Publish ownership before the first await, not after a successful spawn.
    register(owner)
    if (stopped) throw new Error('Fixture runtime stopping')
    ipc.listen(0, '127.0.0.1')
    listening = once(ipc, 'listening')
    await listening
    port = ipc.address().port
    if (stopped) throw new Error('Fixture runtime stopping')
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
      ['PATH', 'PATHEXT', 'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'TEMP', 'TMP'].includes(key.toUpperCase())))
    child = processes.spawn(process.execPath, ['--import', new URL('./account-recovery-smoke-loader.mjs', import.meta.url).href,
      join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
      cwd: join(home, 'workspace'), stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...env, HOME: home, USERPROFILE: home, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1',
        DEEPSEEK_BASE_URL: `${origin}/anthropic`, POCKET_ACCOUNT_FIXTURE_ORIGIN: origin,
        POCKET_ACCOUNT_FIXTURE_IPC_PORT: String(port) },
    })
    child.once('error', reject)
    child.once('exit', (code, signal) => { ended = true; reject(new Error(`Fixture runtime exited: ${code ?? signal}`)) })
    child.stdout.pipe(process.stderr)
    child.stderr.pipe(process.stderr)
    return owner
  } catch (error) {
    try { await owner.stop() } catch (cleanupError) {
      throw new AggregateError([error, cleanupError], 'Fixture setup and cleanup failed')
    }
    throw error
  }
}
