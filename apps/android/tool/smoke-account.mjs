import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { createServer, request as httpRequest } from 'node:http'
import { once } from 'node:events'
import { resolve, join } from 'node:path'
import { createInterface } from 'node:readline'

const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/account-'))
await mkdir(join(home, 'workspace'))
await mkdir(join(home, 'profiles/android'), { recursive: true })
let platformOrigin, initialization, exchangeCount = 0
const platform = createServer((request, response) => {
  void (async () => {
    const raw = Buffer.concat(await Array.fromAsync(request)).toString('utf8')
    const body = raw ? JSON.parse(raw) : {}
    let value
    if (request.url.endsWith('auth_init')) {
      initialization = body
      value = { authorize_id: 'local-fixture', authorize_url: `${platformOrigin}/dsh/authorize`, expires_in: 60 }
    } else if (request.url.endsWith('auth_exchange')) {
      assert.equal(createHash('sha256').update(body.code_verifier).digest('base64url'), initialization.code_challenge)
      assert.equal(body.redirect_uri, initialization.redirect_uri)
      assert.equal(body.code, 'fixture-code')
      exchangeCount++
      value = { user: null, token: 'dsh_mock_callback_fixture', authorized_url: `${platformOrigin}/dsh/authorized` }
    } else if (request.url.endsWith('auth_cancel') || request.url.endsWith('/logout')) value = null
    else throw new Error(`Unexpected local Platform request ${request.url}`)
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ code: 0, data: { biz_code: 0, biz_data: value } }))
  })().catch(error => response.destroy(error))
})
platform.listen(0, '127.0.0.1')
await once(platform, 'listening')
platformOrigin = `http://127.0.0.1:${platform.address().port}`
await writeFile(join(home, 'profiles/android/cordis.patch.yml'), JSON.stringify([{
  id: 'deepseek-account', config: { platformOrigin, allowLoopbackHttp: true, requestTimeoutMs: 5000 },
}]))
const child = spawn(process.execPath, [join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
  cwd: join(home, 'workspace'), env: { ...process.env, DSH_HOME: home }, stdio: ['pipe', 'pipe', 'pipe'],
})
const exited = once(child, 'exit')
const records = new Map(), pending = new Map(), notices = [], waiters = []
const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
let serial = 0
const request = (method, params = {}) => new Promise((resolve, reject) => {
  const id = `account-${++serial}`
  pending.set(id, { resolve, reject })
  send({ id, method, params })
})
const waitFor = predicate => {
  const found = notices.find(predicate)
  if (found) return Promise.resolve(found)
  return new Promise(resolve => waiters.push({ predicate, resolve }))
}
const lines = createInterface({ input: child.stdout })
child.stderr.pipe(process.stderr)
lines.on('line', line => {
  const frame = JSON.parse(line)
  if (frame.method?.startsWith('native.credentials.')) {
    const { name, value } = frame.params
    let result = null
    if (frame.method === 'native.credentials.get') result = records.get(name) ?? null
    else if (frame.method === 'native.credentials.names') result = [...records.keys()]
    else if (frame.method === 'native.credentials.set') { records.set(name, value); result = true }
    else if (frame.method === 'native.credentials.remove') { records.delete(name); result = true }
    send({ id: frame.id, result })
  } else if (frame.method === 'native.storage.root') send({ id: frame.id, result: home })
  else if (frame.method === 'native.web.preferences') {
    send({ id: frame.id, result: { enabled: false, scope: 'local', port: 3080 } })
  } else if (frame.method?.startsWith('native.') && frame.id) {
    send({ id: frame.id, error: { code: -32601, message: `Unexpected native method ${frame.method}` } })
  } else if (pending.has(frame.id)) {
    const waiter = pending.get(frame.id)
    pending.delete(frame.id)
    if (frame.error) waiter.reject(new Error(frame.error.message))
    else waiter.resolve(frame.result)
  } else {
    notices.push(frame)
    if (frame.method === 'api.stream' && frame.params.type === 'item') {
      send({ method: 'api.ack', params: frame.params, id: `ack-${++serial}` })
    }
    for (const waiter of [...waiters]) if (waiter.predicate(frame)) {
      waiters.splice(waiters.indexOf(waiter), 1)
      waiter.resolve(frame)
    }
  }
})
let timer
try {
  await Promise.race([(async () => {
    await waitFor(frame => frame.method === 'runtime.ready')
    assert.equal((await request('web.status')).enabled, false)
    await request('api.subscribe', { owner: 'account-smoke', subscriptionId: 'account', namespace: 'account', method: 'watch', args: {} })
    const client = { version: '0.1.0', locale: 'zh-CN', timezoneOffsetSeconds: 28800 }
    const started = await request('account.signIn', { client })
    const waiting = await waitFor(frame => frame.method === 'api.stream'
      && frame.params.value?.attempt?.id === started.attempt.id && frame.params.value.attempt.phase === 'waiting-browser')
    assert.equal(waiting.params.value.attempt.authorizeUrl, `${platformOrigin}/dsh/authorize`)
    assert.equal((await request('account.signIn', { client })).attempt.id, started.attempt.id)
    const callback = new URL(initialization.redirect_uri)
    assert.equal(callback.hostname, '127.0.0.1')
    assert.equal((await fetch(new URL('/', callback))).status, 404)
    assert.equal((await fetch(new URL('/api/account/getState', callback))).status, 404)
    const badHost = await new Promise((resolve, reject) => {
      const probe = httpRequest(callback, { headers: { host: 'untrusted.invalid' } }, response => {
        response.resume()
        response.on('end', () => resolve(response.statusCode))
      })
      probe.on('error', reject)
      probe.end()
    })
    assert.equal(badHost, 421)
    callback.search = '?state=wrong&code=fixture-code'
    assert.equal((await fetch(callback)).status, 400)
    assert.equal(exchangeCount, 0)
    callback.search = new URLSearchParams({ state: initialization.state, code: 'fixture-code' }).toString()
    assert.equal((await fetch(callback, { redirect: 'manual' })).status, 302)
    const completed = await request('api.call', { namespace: 'account', method: 'cancelSignIn', args: { attemptId: started.attempt.id } })
    assert.equal(completed.status, 'credential-stored')
    assert.equal(completed.attempt.phase, 'succeeded')
    assert.equal(exchangeCount, 1)
    await assert.rejects(fetch(callback))
    assert.equal((await request('web.status')).enabled, false)
    await request('api.call', { namespace: 'account', method: 'signOut', args: { client } })
    const next = await request('account.signIn', { client })
    await waitFor(frame => frame.method === 'api.stream'
      && frame.params.value?.attempt?.id === next.attempt.id && frame.params.value.attempt.phase === 'waiting-browser')
    const cancelledCallback = initialization.redirect_uri
    const cancelled = await request('api.call', { namespace: 'account', method: 'cancelSignIn', args: { attemptId: next.attempt.id } })
    assert.equal(cancelled.attempt.phase, 'cancelled')
    await assert.rejects(fetch(cancelledCallback))
    assert.equal((await request('web.status')).enabled, false)
    console.log(JSON.stringify({ sharedAccountOwner: true, callbackOnly: true, originalPkce: true,
      hostChecked: true, loginClosedListener: true, cancelClosedListener: true, webRemainedDisabled: true }))
  })(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Account smoke timed out')), 60000) })])
} finally {
  clearTimeout(timer)
  lines.close()
  child.kill()
  await exited
  await new Promise(resolve => { platform.close(resolve); platform.closeAllConnections() })
}
