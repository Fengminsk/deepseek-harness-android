import assert from 'node:assert/strict'
import { setTimeout as delay } from 'node:timers/promises'
import { glob, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { FixtureProcesses } from './fixture-processes.mjs'
import { RecoveryFixturePlatform, launchRecoveryFixture } from './account-recovery-smoke-support.mjs'

const root = resolve(import.meta.dirname, '../../..')
const processes = new FixtureProcesses()
const failed = Promise.withResolvers()
const platform = new RecoveryFixturePlatform(failed.reject)
const generations = []
const client = { version: '0.1.0', locale: 'zh-CN', timezoneOffsetSeconds: 28800 }
const sessionId = 'account-recovery-conversation'
const requestId = 'account-recovery-one-prompt'
let phase = 'setup', home, deadline, outcome, failure
const checkpoint = next => { phase = next; console.error(`[account-recovery] ${next}`) }
const state = runtime => runtime.api('account', 'getState')
const catalog = runtime => runtime.api('session', 'modelCatalog')
const accountModels = value => value.groups.find(group => group.id === 'deepseek-account')?.models ?? []
const messages = () => platform.requests.filter(request => request.path.endsWith('/messages')).length
async function persisted() {
  const files = await Array.fromAsync(glob(`sessions/**/${sessionId}/session.v4.jsonl`, { cwd: home }))
  if (!files.length) return []
  assert.equal(files.length, 1)
  return (await readFile(join(home, files[0]), 'utf8')).trim().split('\n').map(line => JSON.parse(line))
}
async function until(read, accept, label) {
  const timeout = Date.now() + 15000
  while (true) {
    const value = await read()
    if (accept(value)) return value
    if (Date.now() >= timeout) throw new Error(`Recovery observation did not settle: ${label}`)
    await delay(20)
  }
}
async function launch() {
  const runtime = await launchRecoveryFixture({ processes, root, home, origin: platform.origin, fail: failed.reject,
    register: runtime => generations.push(runtime) })
  await runtime.wait(frame => frame.method === 'runtime.ready')
  assert.equal((await runtime.request('web.status')).enabled, false)
  return runtime
}
async function verifyNoReplay(runtime, originalMessages) {
  assert.equal(platform.count('/auth-api/v0/dsh/auth_init'), 1, 'recovery cannot initiate login')
  assert.equal(platform.count('/auth-api/v0/dsh/auth_exchange'), 1, 'recovery cannot replay token exchange')
  assert.equal(messages(), originalMessages, 'read-only recovery cannot make a model request')
  const records = await persisted()
  assert.equal(records.filter(row => row.type === 'user/message' && row.data.source?.rpcId === requestId).length, 1,
    'recovery cannot duplicate the submitted prompt')
  const projected = await runtime.api('session', 'projections', { request: { sessionId } })
  assert.equal(projected.kind, 'sequenced')
  assert.equal(projected.values.modelSelection.lastUsed.provider, 'deepseek-account')
  assert.equal(projected.values.modelSelection.lastUsed.model, 'deepseek-flash')
}
try {
  await Promise.race([(async () => {
    home = await mkdtemp(join(root, '.cache/android/account-recovery-'))
    await mkdir(join(home, 'workspace'))
    await mkdir(join(home, 'profiles/android'), { recursive: true })
    await platform.open()
    await writeFile(join(home, 'profiles/android/cordis.patch.yml'), JSON.stringify([
      { id: 'deepseek-account', config: { platformOrigin: platform.origin, inferenceOrigin: platform.origin,
        allowLoopbackHttp: true, requestTimeoutMs: 1000, balanceTimeoutMs: 1000 } },
      { id: 'llm-deepseek-account', config: { baseURL: `${platform.origin}/anthropic`, modelsTimeoutMs: 1000, modelsMaxAgeMs: 0 } },
    ]) + '\n')
    checkpoint('first generation: original login, model request and persisted conversation')
    const first = await launch()
    const started = await first.request('account.signIn', { client })
    await until(async () => {
      const value = await state(first)
      assert.notEqual(value.attempt?.phase, 'failed', `fixture login failed: ${JSON.stringify(value.attempt)}; requests: ${JSON.stringify(platform.requests)}`)
      return value
    }, value => value.attempt?.phase === 'waiting-browser', 'login callback readiness')
    const callback = new URL(platform.initialization.redirect_uri)
    callback.search = new URLSearchParams({ state: platform.initialization.state, code: 'fixture-code' }).toString()
    assert.equal((await fetch(callback, { redirect: 'manual' })).status, 302)
    assert.equal((await state(first)).status, 'credential-stored')
    assert.equal((await state(first)).attempt.id, started.attempt.id)
    assert.equal((await first.api('account', 'getProfile', { client })).value.name, 'Recovery Fixture')
    const observed = await catalog(first)
    assert.ok(accountModels(observed).some(model => model.name === 'Recovery Fixture Flash'))
    await first.api('session', 'initializeDefaultModel')
    await first.request('session.send', { sessionId, requestId, provider: 'deepseek-account', model: 'deepseek-flash', text: 'one recovery fixture prompt' })
    await first.wait(frame => frame.method === 'session.event' && frame.params.sessionId === sessionId && frame.params.event.type === 'turn/end')
    await until(persisted, rows => rows.some(row => row.type === 'turn/end'), 'durable turn completion')
    await first.stop()
    // Title generation can outlive turn/end. Count requests only after every
    // writer in this generation has exited, so recovery has a fixed baseline.
    const originalMessages = messages()
    assert.ok(originalMessages > 0)
    const originalVault = first.vault.entries()
    assert.ok(Object.keys(originalVault).some(key => key.includes('deepseek-account-platform') && key.endsWith('/default')))

    // Negative control intentionally drops only the synthetic persisted store.
    if (process.argv.includes('--negative-control-drop-vault')) {
      await writeFile(first.vault.path, '{}\n')
    }
    checkpoint('second generation: new process restores credential, model directory and session')
    const second = await launch()
    assert.notEqual(first.child.pid, second.child.pid)
    const restored = await state(second)
    assert.equal(restored.status, 'credential-stored', 'cold restart must restore the persisted account grant')
    assert.equal(restored.attempt, null, 'a historical browser attempt is not persisted or replayed')
    assert.deepEqual(second.vault.entries(), originalVault)
    assert.equal((await second.api('account', 'getProfile', { client })).value.name, 'Recovery Fixture')
    assert.ok(accountModels(await catalog(second)).some(model => model.name === 'Recovery Fixture Flash'))
    await verifyNoReplay(second, originalMessages)
    await second.stop()

    checkpoint('third generation: HTTP 503 cold start preserves the grant and uses original bundled models')
    platform.mode = 'service-unavailable'
    const third = await launch()
    assert.notEqual(third.child.pid, second.child.pid)
    assert.equal((await state(third)).status, 'credential-stored')
    assert.equal((await third.api('account', 'getProfile', { client })).status, 'failed', 'a new process cannot invent an old profile cache')
    assert.equal((await third.api('account', 'getBalance', { client })).status, 'failed')
    const fallback = await catalog(third)
    assert.ok(accountModels(fallback).some(model => model.id === 'deepseek-flash'), 'the original bundled catalog remains usable while listing is unavailable')
    assert.equal(accountModels(fallback).some(model => model.name === 'Recovery Fixture Flash'), false)
    assert.deepEqual(third.vault.entries(), originalVault)
    await verifyNoReplay(third, originalMessages)
    await third.stop()

    checkpoint('fourth generation: connection failure preserves the grant and bundled models')
    platform.mode = 'transport-unavailable'
    const fourth = await launch()
    assert.notEqual(fourth.child.pid, third.child.pid)
    assert.equal((await state(fourth)).status, 'credential-stored')
    assert.equal((await fourth.api('account', 'getProfile', { client })).status, 'failed')
    assert.equal((await fourth.api('account', 'getBalance', { client })).status, 'failed')
    assert.ok(accountModels(await catalog(fourth)).some(model => model.id === 'deepseek-flash'))
    assert.ok(platform.requests.some(request => request.status === 'connection-closed'))
    assert.deepEqual(fourth.vault.entries(), originalVault)
    await verifyNoReplay(fourth, originalMessages)

    checkpoint('network restored: original shared cache refreshes without login or prompt replay')
    platform.mode = 'online'
    await until(() => catalog(fourth), value => accountModels(value).some(model => model.name === 'Recovery Fixture Flash'), 'account model listing recovery')
    assert.equal((await fourth.api('account', 'getProfile', { client })).value.name, 'Recovery Fixture')
    await verifyNoReplay(fourth, originalMessages)

    checkpoint('listing 401 retains the grant; account profile 401 expires only that grant')
    platform.listingUnauthorized = true
    const before401 = platform.requests.filter(request => request.path === '/models' && request.status === 401).length
    await until(async () => {
      const value = await catalog(fourth)
      return { value, failures: platform.requests.filter(request => request.path === '/models' && request.status === 401).length }
    }, value => value.failures > before401, 'listing rejection response')
    assert.equal((await state(fourth)).status, 'credential-stored', 'model listing failure is not an account revocation')
    assert.ok(accountModels(await catalog(fourth)).some(model => model.name === 'Recovery Fixture Flash'), 'listing failure retains the previous successful catalog')
    assert.deepEqual(fourth.vault.entries(), originalVault)
    platform.profileUnauthorized = true
    assert.equal(await fourth.api('account', 'getProfile', { client }), null)
    assert.equal((await state(fourth)).status, 'signed-out')
    const remaining = fourth.vault.entries()
    const removed = Object.keys(originalVault).filter(key => !(key in remaining))
    assert.equal(removed.length, 1, 'a real account rejection removes exactly the grant, preserving device identity')
    assert.ok(removed[0].endsWith('/default'))
    assert.deepEqual(remaining, Object.fromEntries(Object.entries(originalVault).filter(([key]) => key !== removed[0])))
    assert.equal(accountModels(await catalog(fourth)).length, 0)
    await verifyNoReplay(fourth, originalMessages)
    outcome = { androidProfile: true, nodeGenerations: generations.length, durableSyntheticCredentials: true,
      onlineColdRestart: true, service503ColdRestart: true, connectionFailureColdRestart: true, modelDirectoryRecovered: true,
      listing401RetainsGrant: true, profile401ExpiresGrant: true, noLoginOrPromptReplay: true,
      deviceKeystoreTested: false, home }
  })(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Account recovery fixture timed out at ${phase}`)), 120000)
  })])
} catch (error) { failure = error }
finally {
  clearTimeout(deadline)
  const cleanup = await Promise.allSettled([
    ...generations.map(runtime => runtime.stop()),
    processes.close(),
    platform.close(),
  ])
  const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) failure = new AggregateError([...(failure ? [failure] : []), ...errors], 'Account recovery cleanup did not settle')
  else console.error(`[account-recovery] cleanup complete: ${generations.length} generations, all listeners and child processes closed`)
}
if (failure) throw failure
console.log(JSON.stringify({ ...outcome, cleanupComplete: true }))
