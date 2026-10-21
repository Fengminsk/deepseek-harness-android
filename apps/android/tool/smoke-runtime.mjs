import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdir, mkdtemp } from 'node:fs/promises'
import { createServer } from 'node:net'
import { once } from 'node:events'
import { resolve, join } from 'node:path'
import { createInterface } from 'node:readline'
import { startSmokeModel } from './smoke-model.mjs'

const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/smoke-'))
await mkdir(join(home, 'workspace'))
const model = await startSmokeModel()
const child = spawn(process.execPath, ['--import', new URL('./web-smoke-loader.mjs', import.meta.url).href,
  join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
  cwd: join(home, 'workspace'), env: { ...process.env, DSH_HOME: home, DEEPSEEK_BASE_URL: model.url }, stdio: ['pipe', 'pipe', 'pipe'],
})
const exited = once(child, 'exit')
const records = new Map(), pending = new Map()
const started = performance.now()
const trace = label => { if (process.env.POCKET_SMOKE_TRACE === '1') console.error(`[runtime-smoke ${Math.round(performance.now() - started)}ms] ${label}`) }
let preferences = { enabled: false, scope: 'local', port: 3080 }
const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
let serial = 0
const request = (method, params = {}) => {
  const id = `smoke-${++serial}`
  trace(`request ${id} ${method}${method === 'api.call' ? ` ${params.namespace}.${params.method}` : ''}`)
  return new Promise((resolve, reject) => { pending.set(id, { method, resolve, reject }); send({ id, method, params }) })
}
const boot = Promise.withResolvers()
const turnEnded = Promise.withResolvers()
let fileReads = 0
const lines = createInterface({ input: child.stdout })
child.stderr.pipe(process.stderr)
child.once('error', boot.reject)
child.once('exit', () => {
  const error = new Error('Runtime exited before smoke completion')
  boot.reject(error)
  for (const waiter of pending.values()) waiter.reject(error)
  pending.clear()
})
lines.on('line', line => {
  let frame
  try { frame = JSON.parse(line) } catch (error) { boot.reject(new Error('Invalid runtime frame', { cause: error })); return }
  if (frame.method?.startsWith('native.')) trace(`native request ${frame.method}`)
  if (frame.method === 'session.event') trace(`session event ${frame.params.event.type}`)
  if (frame.method === 'session.event' && frame.params.event.type === 'turn/end') trace(`turn ended ${JSON.stringify(frame.params.event.data?.reason ?? frame.params.event.reason)}`)
  if (frame.method?.startsWith('native.credentials.')) {
    const { name, value } = frame.params
    let result = null
    if (frame.method === 'native.credentials.get') result = records.get(name) ?? null
    else if (frame.method === 'native.credentials.names') result = [...records.keys()]
    else if (frame.method === 'native.credentials.set') { records.set(name, value); result = true }
    else if (frame.method === 'native.credentials.remove') { records.delete(name); result = true }
    send({ id: frame.id, result })
  } else if (frame.method === 'native.storage.root') send({ id: frame.id, result: home })
  else if (frame.method === 'native.web.preferences') send({ id: frame.id, result: preferences })
  else if (frame.method === 'native.web.save') { preferences = frame.params; send({ id: frame.id, result: true }) }
  else if (frame.method === 'native.network.addresses') send({ id: frame.id, result: { addresses: [] } })
  else if (frame.method === 'native.documents.read') {
    assert.equal(frame.params.root, 'smoke-root')
    assert.equal(frame.params.path, 'test.txt')
    fileReads++
    send({ id: frame.id, result: { text: 'authorized fixture text', offset: 0, nextOffset: 23, truncated: false } })
  }
  else if (frame.method === 'session.event' && frame.params.sessionId === 'android-smoke-shared'
    && frame.params.event.type === 'turn/end') turnEnded.resolve(frame.params.event)
  else if (frame.method === 'runtime.ready') { trace('runtime ready'); boot.resolve() }
  else if (pending.has(frame.id)) {
    const waiter = pending.get(frame.id)
    pending.delete(frame.id)
    trace(`reply ${frame.id} ${waiter.method} ${frame.error ? 'error' : 'ok'}`)
    if (frame.error) waiter.reject(new Error(frame.error.message))
    else waiter.resolve(frame.result)
  } else if (frame.method?.startsWith('native.') && frame.id) {
    send({ id: frame.id, error: { code: -32601, message: `Unsupported smoke native method: ${frame.method}` } })
  }
})
let deadline
const bounded = new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error(
  `Runtime smoke timed out; pending=${JSON.stringify([...pending.values()].map(call => call.method))}; modelCalls=${model.calls()}; fileReads=${fileReads}`,
)), 60000) })
const conflict = createServer()
try {
  await Promise.race([(async () => {
    await boot.promise
    assert.equal((await request('runtime.info')).profile, 'android')
    assert.equal((await request('web.status')).enabled, false)
    const settings = await request('settings.describe')
    const defaultModel = settings.find(form => form.ns === 'agent-default-model')
    assert.ok(defaultModel, 'The Android profile must expose its default-model settings')
    assert.equal(defaultModel.display.moduleName, '@deepseek-ai/dsh-agent-default-model')
    assert.ok(Number.isInteger(defaultModel.revision))
    assert.ok(defaultModel.value && typeof defaultModel.value === 'object')
    assert.deepEqual(await request('runtime.live'), {
      revision: 0, statuses: {}, streaming: {}, errors: {}, liveMessages: {},
    })
    assert.deepEqual(await request('sessions.list'), [])
    const list = await request('api.call', { namespace: 'session', method: 'list', args: { _request: {} } })
    assert.deepEqual(list.items, [])
    const created = await request('api.call', { namespace: 'session', method: 'create', args: {
      request: { sessionId: 'android-smoke-shared' },
    } })
    assert.equal(created.sessionId, 'android-smoke-shared')
    const stored = await request('sessions.list')
    assert.equal(stored[0].header.id, created.sessionId)
    assert.equal((await request('runtime.live')).statuses[created.sessionId], 'idle')
    await request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-smoke-fixture-only' })
    const receipt = await request('session.send', { sessionId: created.sessionId, requestId: 'smoke-prompt',
      text: 'Read the authorized fixture file.', provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
    assert.equal(receipt.accepted, true)
    trace('awaiting held second model response')
    await Promise.race([model.waiting, turnEnded.promise.then(event => {
      throw new Error(`Turn ended before the held model response: ${JSON.stringify(event.data.reason)}`)
    })])
    assert.equal(fileReads, 1)
    assert.equal((await request('runtime.live')).statuses[created.sessionId], 'running')
    const waiting = await request('web.configure', { enabled: true, scope: 'lan', port: 3080 })
    assert.equal(waiting.phase, 'waiting-network')
    assert.equal(waiting.url, null)
    conflict.listen(0, '127.0.0.1')
    await once(conflict, 'listening')
    const failed = await request('web.configure', { enabled: true, scope: 'local', port: conflict.address().port })
    assert.equal(failed.phase, 'failed')
    assert.equal(failed.url, null)
    const disabled = await request('web.configure', { enabled: false, scope: 'local', port: 3080 })
    assert.equal(disabled.phase, 'disabled')
    assert.equal((await request('runtime.info')).profile, 'android')
    const first = await request('web.configure', { enabled: true, scope: 'local', port: 0 })
    assert.equal(first.phase, 'listening', first.error)
    const unauthorized = await fetch(new URL('/', first.url), { redirect: 'manual' })
    assert.equal(unauthorized.status, 401)
    const login = await fetch(first.url, { redirect: 'manual' })
    assert.equal(login.status, 303)
    const cookie = login.headers.get('set-cookie').split(';')[0]
    const page = await fetch(new URL('/', first.url), { headers: { cookie } })
    assert.equal(page.status, 200)
    assert.match(await page.text(), /<html/i)
    const connect = new URL(first.url)
    connect.pathname = '/connect'
    const apiLogin = await fetch(connect, { redirect: 'manual' })
    assert.equal(apiLogin.status, 302)
    const { default: WebSocket } = await import(new URL('../../../.cache/android/runtime-bundle/node_modules/ws/wrapper.mjs', import.meta.url))
    const socketUrl = new URL(apiLogin.headers.get('location'), connect)
    socketUrl.protocol = 'ws:'
    const socket = new WebSocket(socketUrl, {
      headers: { cookie: apiLogin.headers.get('set-cookie').split(';')[0], origin: new URL(first.url).origin },
    })
    try {
      await once(socket, 'open')
      const closed = once(socket, 'close')
      await request('web.configure', { enabled: false, scope: 'local', port: 3080 })
      await closed
      await assert.rejects(fetch(first.url))
      assert.equal((await request('runtime.info')).profile, 'android')
      assert.equal((await request('runtime.live')).statuses[created.sessionId], 'running')
      model.release()
      await turnEnded.promise
      const history = await request('session.read', { sessionId: created.sessionId, offset: 0 })
      assert.match(JSON.stringify(history.events), /smoke completed/)
      assert.equal(model.calls(), 2)
    } finally {
      if (socket.readyState !== WebSocket.CLOSED) socket.terminate()
    }
    // Reopen the listener's own allocated port so cookie audience stays identical.
    const second = await request('web.configure', { enabled: true, scope: 'local', port: Number(new URL(first.url).port) })
    assert.equal(second.phase, 'listening', second.error)
    const stale = new URL(second.url)
    stale.search = new URL(first.url).search
    assert.equal((await fetch(stale, { redirect: 'manual' })).status, 401)
    assert.equal((await fetch(new URL('/', second.url), { headers: { cookie }, redirect: 'manual' })).status, 401)
    assert.equal((await fetch(second.url, { redirect: 'manual' })).status, 303)
    await request('web.configure', { enabled: false, scope: 'local', port: 3080 })
    console.log(JSON.stringify({ ready: true, sharedSessionGateway: true, webDefaultDisabled: true,
      missingLanWaits: true, portConflictReported: true, appSurvivesWebFailure: true,
      webAuthentication: true, webSocketClosed: true, oldTokenAndCookieRejected: true,
      realAgentAdmission: true, adapterAndFileTool: true, turnContinuesAfterWebClose: true }))
  })(), bounded])
} finally {
  clearTimeout(deadline)
  if (conflict.listening) await new Promise(resolve => conflict.close(resolve))
  child.kill()
  await exited
  lines.close()
  await model.close()
}
