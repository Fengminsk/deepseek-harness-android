import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { copyFile, glob, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { basename, join, resolve, sep } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { FixtureProcesses } from './fixture-processes.mjs'
import { RecoveryFixturePlatform, launchRecoveryFixture } from './account-recovery-smoke-support.mjs'

// Both generations run the original Android profile from runtime.zip inside
// real APKs. The fake Platform and native vault are fixture boundaries only.
const root = resolve(import.meta.dirname, '../../..')
const retainHome = process.argv.includes('--retain-home')
const [previousApkArg, currentApkArg] = process.argv.slice(2).filter(arg => arg !== '--retain-home')
const previousApk = resolve(previousApkArg ?? join(root, '.cache/android/pocket-harness-0.1.0+54-arm64-debug.apk'))
const currentApk = resolve(currentApkArg ?? join(root, 'apps/android/build/app/outputs/flutter-apk/app-debug.apk'))
for (const apk of [previousApk, currentApk]) {
  if (!existsSync(apk)) throw new Error(`Required versioned APK is missing: ${apk}`)
}
const processes = new FixtureProcesses()
const failed = Promise.withResolvers()
const platform = new RecoveryFixturePlatform(failed.reject)
const generations = []
const client = { version: '0.1.0', locale: 'zh-CN', timezoneOffsetSeconds: 28800 }
const sessionId = 'apk-upgrade-conversation'
const requestId = 'apk-upgrade-one-prompt'
const priorInterruptedSessionId = 'apk-upgrade-prior-interrupted-conversation'
const priorInterruptedRequestId = 'apk-upgrade-prior-interrupted-prompt'
const interruptedSessionId = 'apk-upgrade-interrupted-conversation'
const interruptedRequestId = 'apk-upgrade-interrupted-prompt'
let phase = 'setup', home, deadline, failure, outcome
const checkpoint = next => { phase = next; console.error(`[apk-upgrade] ${next}`) }
const state = runtime => runtime.api('account', 'getState')
const catalog = runtime => runtime.api('session', 'modelCatalog')
const accountModels = value => value.groups.find(group => group.id === 'deepseek-account')?.models ?? []
const messages = () => platform.requests.filter(request => request.path.endsWith('/messages')).length
async function admitHeldInference(runtime, id, rpcId) {
  const baseline = messages()
  const receipt = await runtime.request('session.send', {
    sessionId: id, requestId: rpcId, provider: 'deepseek-account',
    model: 'deepseek-flash', text: 'An interrupted upgrade fixture prompt',
  })
  assert.equal(receipt.accepted, true)
  await until(() => platform.requests.filter(row => row.path.endsWith('/messages')),
    rows => rows.length > baseline && rows.some(row => row.purpose === 'turn'
      && row.status === 'stream-held'),
    'held inference request')
  await until(() => persistedFor(id), rows => rows.some(row => row.type === 'user/message'
    && row.data.source?.rpcId === rpcId), 'durable interrupted prompt')
  return messages()
}

async function persistedFor(id) {
  const files = await Array.fromAsync(glob(`sessions/**/${id}/session.v4.jsonl`, { cwd: home }))
  if (files.length === 0) return []
  assert.equal(files.length, 1, 'the prior APK must persist exactly one conversation log')
  return (await readFile(join(home, files[0]), 'utf8')).split('\n').slice(0, -1).filter(Boolean).map(JSON.parse)
}
const persisted = () => persistedFor(sessionId)
async function until(read, accept, label) {
  const expires = Date.now() + 15000
  while (true) {
    const value = await read()
    if (accept(value)) return value
    if (Date.now() > expires) throw new Error(`Observation did not settle: ${label}`)
    await delay(20)
  }
}
function extract(apk, target) {
  const result = execFileSync('python', [join(import.meta.dirname, 'extract-apk-runtime.py'), apk, target], {
    encoding: 'utf8', windowsHide: true, timeout: 300000,
  })
  return JSON.parse(result)
}
async function hydrateHostNative(bundle) {
  for (const [addon, file] of [
    ['node_modules/node-addon-require-builtin-win32-x64-msvc', 'prebuilt/win32-x64-msvc-napi-v9.node'],
    ['node_modules/@koromix/koffi-win32-x64', 'win32_x64/koffi.node'],
  ]) {
    const staged = join(root, '.cache/android/runtime-bundle', addon)
    const packaged = join(bundle, addon)
    assert.equal(await readFile(join(packaged, 'package.json'), 'utf8'),
      await readFile(join(staged, 'package.json'), 'utf8'),
      'the host test binding must match the APK package metadata')
    await mkdir(join(packaged, file.split('/').slice(0, -1).join('/')), { recursive: true })
    await copyFile(join(staged, file), join(packaged, file))
  }
}
async function launch(bundle) {
  const runtime = await launchRecoveryFixture({ processes, root, home, origin: platform.origin,
    fail: failed.reject, register: value => generations.push(value),
    bootstrapPath: join(bundle, 'bootstrap.mjs'),
    preload: new URL('./upgrade-runtime-loader.mjs', import.meta.url).href,
    extraEnv: { POCKET_UPGRADE_BUNDLE_ROOT: bundle },
  })
  await runtime.wait(frame => frame.method === 'runtime.ready')
  assert.equal((await runtime.request('runtime.info')).profile, 'android')
  assert.equal((await runtime.request('web.status')).enabled, false)
  return runtime
}
async function verifyNoReplay(runtime, baseline, originalRows, originalVault) {
  assert.equal(platform.count('/auth-api/v0/dsh/auth_init'), 1, 'cold boot cannot restart browser login')
  assert.equal(platform.count('/auth-api/v0/dsh/auth_exchange'), 1, 'cold boot cannot repeat token exchange')
  assert.equal(messages(), baseline, 'cold reads cannot make a second inference request')
  assert.deepEqual(runtime.vault.entries(), originalVault, 'upgrade and offline recovery keep the synthetic native vault')
  assert.deepEqual(await persisted(), originalRows, 'cold reads must not rewrite the completed session')
  assert.equal(originalRows.filter(row => row.type === 'user/message' && row.data.source?.rpcId === requestId).length, 1)
  const read = await runtime.request('session.read', { sessionId })
  assert.ok(read.events.some(row => row.type === 'assistant/message'), 'upgraded code must reopen the prior reply')
  assert.equal(read.events.filter(row => row.type === 'user/message' && row.data.source?.rpcId === requestId).length, 1)
  const projection = await runtime.api('session', 'projections', { request: { sessionId } })
  assert.equal(projection.kind, 'sequenced')
  assert.equal(projection.values.modelSelection.lastUsed.provider, 'deepseek-account')
  assert.equal(projection.values.modelSelection.lastUsed.model, 'deepseek-flash')
  assert.deepEqual((await runtime.request('tasks.summary')).active, [])
}

try {
  await Promise.race([(async () => {
    home = await mkdtemp(join(root, '.cache/android/apk-upgrade-'))
    const priorBundle = join(home, 'prior-runtime')
    const nextBundle = join(home, 'next-runtime')
    checkpoint('verify and extract the previous APK runtime ZIP')
    const before = extract(previousApk, priorBundle)
    await hydrateHostNative(priorBundle)
    await mkdir(join(home, 'workspace'))
    await mkdir(join(home, 'profiles/android'), { recursive: true })
    await platform.open()
    await writeFile(join(home, 'profiles/android/cordis.patch.yml'), JSON.stringify([
      { id: 'deepseek-account', config: { platformOrigin: platform.origin, inferenceOrigin: platform.origin,
        allowLoopbackHttp: true, requestTimeoutMs: 1000, balanceTimeoutMs: 1000 } },
      { id: 'llm-deepseek-account', config: { baseURL: `${platform.origin}/anthropic`, modelsTimeoutMs: 1000, modelsMaxAgeMs: 0 } },
    ]) + '\n')

    checkpoint('previous APK: sign in, complete an inference and persist the conversation')
    const first = await launch(priorBundle)
    const started = await first.request('account.signIn', { client })
    await until(() => state(first), value => value.attempt?.phase === 'waiting-browser', 'account callback')
    const callback = new URL(platform.initialization.redirect_uri)
    callback.search = new URLSearchParams({ state: platform.initialization.state, code: 'fixture-code' }).toString()
    assert.equal((await fetch(callback, { redirect: 'manual' })).status, 302)
    assert.equal((await state(first)).attempt.id, started.attempt.id)
    assert.equal((await state(first)).status, 'credential-stored')
    assert.ok(accountModels(await catalog(first)).some(model => model.name === 'Recovery Fixture Flash'))
    await first.api('session', 'initializeDefaultModel')
    const receipt = await first.request('session.send', { sessionId, requestId, provider: 'deepseek-account',
      model: 'deepseek-flash', text: 'One upgrade fixture prompt' })
    assert.equal(receipt.accepted, true, `previous APK did not admit the prompt: ${JSON.stringify(receipt)}`)
    const ended = await first.wait(frame => frame.method === 'session.event' && frame.params.sessionId === sessionId
      && frame.params.event.type === 'turn/end')
    assert.equal(ended.params.event.data.reason.kind, 'completed',
      `previous APK did not complete the turn: ${JSON.stringify(ended.params.event.data.reason)}`)
    await until(persisted, rows => rows.some(row => row.type === 'turn/end'), 'completed durable turn')
    checkpoint('previous APK: terminate a streaming turn before upgrading')
    platform.mode = 'hold-inference'
    const beforeUpgradeMessages = await admitHeldInference(first,
      priorInterruptedSessionId, priorInterruptedRequestId)
    await first.stop()
    assert.equal((await processes.records.get(first.child).closed).signal, 'SIGKILL')
    assert.equal((await persistedFor(priorInterruptedSessionId)).some(row =>
      row.type === 'turn/end' && row.data.reason?.kind === 'completed'), false,
    'prior-version inference must still be incomplete at process death')
    const originalRows = await persisted()
    const originalVault = first.vault.entries()
    const originalMessages = messages()
    assert.equal(originalMessages, beforeUpgradeMessages)
    assert.ok(originalMessages > 0)
    assert.ok(Object.keys(originalVault).some(key => key.includes('deepseek-account-platform') && key.endsWith('/default')))

    // Only the durable home survives an upgrade. Releasing the stopped prior
    // runtime also keeps the host fixture within one extracted runtime's disk budget.
    const cacheRoot = resolve(root, '.cache/android')
    assert.ok(resolve(home).startsWith(cacheRoot + sep), 'upgrade fixture home escaped the cache')
    assert.equal(resolve(priorBundle), join(home, 'prior-runtime'))
    await rm(priorBundle, { recursive: true })
    checkpoint('verify and extract the new APK runtime ZIP')
    const after = extract(currentApk, nextBundle)
    assert.notEqual(before.sha256, after.sha256, 'the two APKs must carry distinct runtime versions')
    await hydrateHostNative(nextBundle)

    checkpoint('new APK: offline cold boot uses the same on-disk home without replay')
    platform.mode = 'transport-unavailable'
    const second = await launch(nextBundle)
    assert.notEqual(second.child.pid, first.child.pid)
    assert.equal((await state(second)).status, 'credential-stored')
    assert.equal((await state(second)).attempt, null)
    assert.equal((await second.api('account', 'getProfile', { client })).status, 'failed')
    assert.ok(accountModels(await catalog(second)).some(model => model.id === 'deepseek-flash'))
    assert.ok(platform.requests.some(row => row.status === 'connection-closed'))
    await verifyNoReplay(second, originalMessages, originalRows, originalVault)
    const priorInterruptedRead = await second.request('session.read', { sessionId: priorInterruptedSessionId })
    assert.equal(priorInterruptedRead.events.filter(row => row.type === 'user/message'
      && row.data.source?.rpcId === priorInterruptedRequestId).length, 1,
    'upgraded runtime must not duplicate the interrupted prior-version prompt')

    checkpoint('new APK: recovered network refreshes models without login or turn replay')
    platform.mode = 'online'
    await until(() => catalog(second), value => accountModels(value).some(model => model.name === 'Recovery Fixture Flash'),
      'model catalog network recovery')
    assert.equal((await second.api('account', 'getProfile', { client })).value.name, 'Recovery Fixture')
    await verifyNoReplay(second, originalMessages, originalRows, originalVault)
    await second.stop()

    checkpoint('new APK: a second cold boot keeps the already upgraded durable state')
    const third = await launch(nextBundle)
    assert.notEqual(third.child.pid, second.child.pid)
    await verifyNoReplay(third, originalMessages, originalRows, originalVault)
    checkpoint('new APK: terminate an admitted streaming turn and restart offline without replay')
    platform.mode = 'hold-inference'
    const interruptedMessages = await admitHeldInference(third,
      interruptedSessionId, interruptedRequestId)
    await third.stop()
    assert.equal((await processes.records.get(third.child).closed).signal, 'SIGKILL')
    assert.equal((await persistedFor(interruptedSessionId)).some(row =>
      row.type === 'turn/end' && row.data.reason?.kind === 'completed'), false,
    'new-version inference must still be incomplete at process death')
    platform.mode = 'transport-unavailable'
    const fourth = await launch(nextBundle)
    assert.notEqual(fourth.child.pid, third.child.pid)
    await verifyNoReplay(fourth, interruptedMessages, originalRows, originalVault)
    const interruptedRead = await fourth.request('session.read', { sessionId: interruptedSessionId })
    assert.equal(interruptedRead.events.filter(row => row.type === 'user/message'
      && row.data.source?.rpcId === interruptedRequestId).length, 1,
    'cold boot must not duplicate the interrupted user prompt')
    await delay(250)
    assert.equal(messages(), interruptedMessages,
      'cold boot and Session read must not restart the interrupted inference')
    await fourth.stop()
    const fifth = await launch(nextBundle)
    await verifyNoReplay(fifth, interruptedMessages, originalRows, originalVault)
    assert.equal((await fifth.request('session.read', { sessionId: interruptedSessionId })).events
      .filter(row => row.type === 'user/message' && row.data.source?.rpcId === interruptedRequestId).length, 1)
    outcome = { androidProfile: true, extractedApkRuntimes: [before.sha256, after.sha256],
      windowsTestBindingInjected: true,
      nodeGenerations: generations.length, sharedDurableHome: true, offlineUpgradeColdBoot: true,
      networkRecovery: true, completedSessionReopened: true, noAutomaticLoginOrInferenceReplay: true,
      priorVersionInterruptedTurnNotReplayed: true,
      interruptedTurnNotReplayedAcrossTwoColdBoots: true,
      androidPackageManagerUpgradeTested: false, keystoreTested: false, safGrantTested: false,
      androidProcessDeathTested: false, home }
  })(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`APK upgrade fixture timed out at ${phase}`)), 300000)
  })])
} catch (error) { failure = error }
finally {
  clearTimeout(deadline)
  const cleanup = await Promise.allSettled([
    ...generations.map(runtime => runtime.stop()), processes.close(), platform.close(),
  ])
  const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
  if (home && !retainHome) {
    const cacheRoot = resolve(root, '.cache/android')
    const target = resolve(home)
    if (!target.startsWith(cacheRoot + sep) || !/^apk-upgrade-[A-Za-z0-9]{6}$/.test(basename(target))) {
      errors.push(new Error(`Refusing to remove an unexpected fixture path: ${target}`))
    } else {
      try { await rm(target, { recursive: true, force: true, maxRetries: 3, retryDelay: 200 }) }
      catch (error) { errors.push(error) }
    }
  }
  if (outcome) {
    outcome.home = retainHome ? home : null
    outcome.temporaryHomeRemoved = !retainHome && errors.length === 0
  }
  if (errors.length) failure = new AggregateError([...(failure ? [failure] : []), ...errors], 'APK upgrade fixture cleanup failed')
}
if (failure) throw failure
console.log(JSON.stringify(outcome))
