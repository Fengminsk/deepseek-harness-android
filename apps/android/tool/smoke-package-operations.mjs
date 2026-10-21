import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { FixtureProcesses } from './fixture-processes.mjs'

const registry = 'https://package-fixture.invalid/'

async function fixturePnpm() {
  const [control, ...args] = process.argv.slice(3)
  assert.deepEqual(args, ['config', 'get', 'registry'], 'fixture must never execute install, network or Git commands')
  const id = String(process.pid)
  await writeFile(join(control, `${id}.started.json`), JSON.stringify({ pid: process.pid, args, cwd: process.cwd() }), { flag: 'wx' })
  const deadline = performance.now() + 15000
  while (!existsSync(join(control, `${id}.release`))) {
    if (existsSync(join(control, 'closing'))) return
    if (performance.now() > deadline) throw new Error('Fixture pnpm release was not received within 15 seconds')
    await delay(10)
  }
  process.stdout.write(`${registry}\n`)
}

async function smoke() {
  const root = resolve(import.meta.dirname, '../../..')
  const home = await mkdtemp(join(root, '.cache/android/package-operations-profile-'))
  const control = join(home, 'fixture-control'), workspace = join(home, 'workspace'), bundle = join(home, 'fixture-bundle')
  await Promise.all([control, workspace, bundle].map(path => mkdir(path)))
  await writeFile(join(bundle, 'package.json'), JSON.stringify({ name: '@fixture/package-operations', version: '1.0.0',
    dsh: { bundle: { patch: 'cordis.patch.yml' } } }))
  await writeFile(join(bundle, 'cordis.patch.yml'), '[]\n')
  const processes = new FixtureProcesses()
  const child = processes.spawn(process.execPath, ['--import', new URL('./package-operations-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: workspace,
    env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1', POCKET_PACKAGE_SMOKE_CONTROL: control },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const pending = new Map(), notices = [], waiters = new Set(), vault = new Map()
  const lines = createInterface({ input: child.stdout })
  let serial = 0, failure, stopping = false, exited = false
  const abort = new AbortController()
  const fail = error => {
    failure ??= error
    abort.abort(error)
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    waiters.clear()
  }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    exited = true
    fail(new Error(`Android profile exited (${code ?? signal})`))
  })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  const send = frame => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...frame })}\n`)
  lines.on('line', line => {
    if (exited) return
    try {
      const frame = JSON.parse(line)
      if (frame.method?.startsWith('native.')) {
        let result
        const { name, value } = frame.params ?? {}
        switch (frame.method) {
          case 'native.credentials.get': result = vault.get(name) ?? null; break
          case 'native.credentials.names': result = [...vault.keys()]; break
          case 'native.credentials.set': vault.set(name, value); result = true; break
          case 'native.credentials.remove': vault.delete(name); result = true; break
          case 'native.web.preferences': result = { enabled: false, scope: 'local', port: 3080 }; break
          case 'native.network.addresses': result = { addresses: [] }; break
          case 'native.storage.root': result = home; break
          default: throw new Error(`Unexpected native request ${frame.method}`)
        }
        send({ id: frame.id, result })
      } else if (pending.has(frame.id)) {
        const call = pending.get(frame.id)
        pending.delete(frame.id)
        if (frame.error) call.reject(Object.assign(new Error(frame.error.message), { rpcError: frame.error }))
        else call.resolve(frame.result)
      } else {
        notices.push(frame)
        for (const waiter of waiters) if (waiter.predicate(frame)) {
          waiters.delete(waiter)
          waiter.resolve(frame)
        }
      }
    } catch (error) { fail(error) }
  })
  function request(method, params = {}) {
    if (failure || stopping) return Promise.reject(failure ?? new Error('Fixture is closing'))
    const id = `packages-${++serial}`
    return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ id, method, params }) })
  }
  function waitNotice(predicate, after = 0) {
    if (failure || stopping) return Promise.reject(failure ?? new Error('Fixture is closing'))
    const existing = notices.slice(after).find(predicate)
    return existing ? Promise.resolve(existing) : new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
  }
  async function waitFor(read, predicate, label) {
    const deadline = performance.now() + 10000
    while (true) {
      if (failure || stopping) throw failure ?? new Error('Fixture is closing')
      const value = await read()
      if (predicate(value)) return value
      if (performance.now() > deadline) throw new Error(`${label} was not observed within 10 seconds`)
      await delay(10, undefined, { signal: abort.signal })
    }
  }
  const fixtureCalls = async () => Promise.all((await readdir(control)).filter(name => name.endsWith('.started.json'))
    .map(async name => JSON.parse(await readFile(join(control, name), 'utf8'))))
  const packageCall = (method, args = {}) => request('api.call', { namespace: 'pluginManager', method, args })
  const start = (method, args) => packageCall(method, args).then(value => ({ value }), error => ({ error }))
  const finish = async operation => { const result = await operation; if (result.error) throw result.error; return result.value }
  const release = call => writeFile(join(control, `${call.pid}.release`), '')
  let lastRevision
  async function changed(count, after) {
    const frame = await waitNotice(frame => frame.method === 'runtime.tasks.changed'
      && frame.params.summary.packageOperations === count && frame.params.revision > lastRevision, after)
    lastRevision = frame.params.revision
    assert.deepEqual(frame.params.active, [])
    assert.equal(frame.params.summary.running, 0)
    assert.equal(frame.params.summary.waiting, 0)
    assert.equal(frame.params.summary.queued, 0)
    return frame.params
  }
  const timeout = setTimeout(() => fail(new Error('Package-operation profile smoke exceeded 60 seconds')), 60000)
  try {
    await waitNotice(frame => frame.method === 'runtime.ready')
    assert.equal((await request('runtime.info')).profile, 'android')
    await request('api.call', { namespace: 'session', method: 'create', args: { request: { sessionId: 'package-smoke-idle' } } })
    const baseline = await request('tasks.summary')
    lastRevision = baseline.revision
    assert.equal(baseline.summary.packageOperations, 0)
    assert.deepEqual(baseline.active, [])
    assert.equal((await request('runtime.live')).statuses['package-smoke-idle'], 'idle')

    let after = notices.length
    const inspection = start('inspect', { spec: bundle })
    const [firstCall] = await waitFor(fixtureCalls, calls => calls.length === 1, 'inspection external command')
    await changed(1, after)
    after = notices.length
    const registries = start('registries')
    const calls = await waitFor(fixtureCalls, calls => calls.length === 2, 'concurrent registry command')
    const secondCall = calls.find(call => call.pid !== firstCall.pid)
    await changed(2, after)
    for (const call of calls) {
      assert.deepEqual(call.args, ['config', 'get', 'registry'])
      assert.equal(call.cwd, join(home, 'profiles', 'android'))
    }
    const busy = await request('tasks.summary')
    assert.equal(busy.summary.packageOperations, 2, 'inspection nested registry lookup must count only once')
    assert.deepEqual(busy.active, [], 'idle Agent must not hide active package commands')
    assert.equal(busy.epoch, baseline.epoch)
    assert.ok(busy.revision >= lastRevision)
    const refused = await request('runtime.transition.reserve', { token: randomUUID() })
    assert.equal(refused.accepted, false)
    assert.equal(refused.code, 'runtime/package-busy')

    after = notices.length
    await release(firstCall)
    assert.equal((await finish(inspection)).status, 'accepted')
    await changed(1, after)
    assert.equal((await request('runtime.transition.reserve', { token: randomUUID() })).code, 'runtime/package-busy')
    after = notices.length
    await release(secondCall)
    assert.equal((await finish(registries)).resolved, registry)
    await changed(0, after)

    const token = randomUUID()
    const reserved = await request('runtime.transition.reserve', { token })
    assert.equal(reserved.accepted, true)
    assert.equal(reserved.state, 'reserved')
    async function assertClosedAdmission() {
      await assert.rejects(packageCall('inspect', { spec: bundle }), /服务正在切换模式/)
      await assert.rejects(packageCall('registries'), /服务正在切换模式/)
      assert.equal((await fixtureCalls()).length, 2, 'rejected admission must start no package command')
      assert.equal((await request('tasks.summary')).summary.packageOperations, 0)
    }
    await assertClosedAdmission()
    const committed = await request('runtime.transition.commit', { token, epoch: reserved.epoch })
    assert.equal(committed.accepted, true)
    assert.equal(committed.state, 'committed')
    await assertClosedAdmission()
    assert.equal((await request('runtime.transition.release', { token, epoch: reserved.epoch })).released, true)

    after = notices.length
    const reopened = start('registries')
    const reopenedCalls = await waitFor(fixtureCalls, calls => calls.length === 3, 'registry command after maintenance release')
    await changed(1, after)
    const thirdCall = reopenedCalls.find(call => !calls.some(previous => previous.pid === call.pid))
    after = notices.length
    await release(thirdCall)
    assert.equal((await finish(reopened)).resolved, registry)
    await changed(0, after)
    assert.equal((await request('tasks.summary')).summary.packageOperations, 0)
    console.log(JSON.stringify({ realAndroidProfile: true, originalPluginManagerApi: true, fixturePnpmProcesses: 3,
      readyPackageBaseline: true, concurrentInspectAndRegistries: true, nestedRegistryCountsOnce: true,
      idleAgentPreservesPackageActivity: true, freshStartedAndSettledSnapshots: true, activeReservationRefused: true,
      reservedAdmissionRefused: true, committedAdmissionRefused: true, releaseRestoresAdmission: true }))
  } finally {
    clearTimeout(timeout)
    stopping = true
    // Any already-created command or late child observes closing and cannot retain a wait.
    await writeFile(join(control, 'closing'), '')
    try {
      // An API reply follows execa's child completion, including a command still starting at timeout.
      const deadline = performance.now() + 15000
      while (pending.size && !exited) {
        if (performance.now() > deadline) throw new Error('Package calls did not settle during fixture cleanup')
        await delay(10)
      }
    } finally {
      fail(new Error('Fixture is closing'))
      try { await processes.close() } finally { lines.close() }
    }
  }
}

if (process.argv[2] === '--fixture-pnpm') await fixturePnpm()
else await smoke()
