import assert from 'node:assert/strict'
import { test } from 'node:test'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { createConnection, createServer } from 'node:net'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { ANDROID_BUNDLES } from '../runtime/host-guard.mjs'

const root = resolve(import.meta.dirname, '../../..')
const loader = new URL('./host-guard-test-loader.mjs', import.meta.url).href
async function unusedPort() {
  const server = createServer()
  server.listen(0, '127.0.0.1')
  try {
    await once(server, 'listening')
    return server.address().port
  } finally { await new Promise(resolve => server.close(resolve)) }
}
async function assertNotListening(port) {
  const connection = createConnection({ host: '127.0.0.1', port })
  try {
    await assert.rejects(once(connection, 'connect'), { code: 'ECONNREFUSED' })
  } finally { connection.destroy() }
}

for (const layer of ['profile', 'home']) {
  test(`real bootstrap refuses ${layer} Web override before any native request or HTTP listener`, { timeout: 30000 }, async t => {
    const port = await unusedPort()
    const home = await mkdtemp(join(root, '.cache/android/guard-profile-'))
    const profile = join(home, 'profiles/android')
    await mkdir(profile, { recursive: true })
    await writeFile(join(profile, 'package.json'), JSON.stringify({
      name: 'guard-profile', type: 'module', dsh: { profile: { bundles: ANDROID_BUNDLES } },
    }))
    await writeFile(join(layer === 'profile' ? profile : home, 'cordis.patch.yml'),
      `- id: webserver\n  disabled: false\n  inject: []\n  config:\n    host: 127.0.0.1\n    port: ${port}\n`)
    const child = spawn(process.execPath, ['--import', loader,
      join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
      cwd: home, env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const closed = once(child, 'close')
    t.after(async () => { if (child.exitCode === null) child.kill(); await closed })
    let stdout = '', stderr = ''
    child.stdout.on('data', bytes => { stdout += bytes; assert.ok(stdout.length < 65536) })
    child.stderr.on('data', bytes => { stderr += bytes; assert.ok(stderr.length < 65536) })
    let deadline
    try {
      const [code] = await Promise.race([closed, new Promise((_, reject) => {
        deadline = setTimeout(() => reject(new Error('Rejected profile did not exit')), 20000)
      })])
      assert.notEqual(code, 0)
      assert.match(stderr, /ANDROID_HOST_CONFIGURATION/)
      assert.equal(stdout, '', 'No native carrier or protocol output is admitted before preflight')
      await assertNotListening(port)
    } finally { clearTimeout(deadline) }
  })
}

test('real profile keeps ordinary host settings and original credential reference RPCs', { timeout: 60000 }, async t => {
  const home = await mkdtemp(join(root, '.cache/android/guard-ready-'))
  const profile = join(home, 'profiles/android')
  await mkdir(profile, { recursive: true })
  await writeFile(join(profile, 'package.json'), JSON.stringify({
    name: 'guard-ready', type: 'module', dsh: { profile: { bundles: ANDROID_BUNDLES } },
  }))
  await writeFile(join(profile, 'cordis.patch.yml'),
    '# Ordinary user config survives host preflight.\n- id: android-runtime\n  config:\n    shellOutputLimit: 8192\n')
  const child = spawn(process.execPath, ['--import', loader,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: home, env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const closed = once(child, 'close')
  const pending = new Map(), vault = new Map()
  const ready = Promise.withResolvers()
  const lines = createInterface({ input: child.stdout })
  let serial = 0, stderr = ''
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const fail = error => {
    ready.reject(error)
    for (const entry of pending.values()) entry.reject(error)
    pending.clear()
  }
  t.after(async () => { if (child.exitCode === null) child.kill(); await closed; lines.close() })
  child.on('error', fail)
  child.stdin.on('error', fail)
  child.stderr.on('data', bytes => { stderr = (stderr + bytes).slice(-32768) })
  child.on('exit', () => fail(new Error(`Fixture runtime exited: ${stderr}`)))
  lines.on('line', line => {
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
          case 'native.storage.root': result = home; break
          case 'native.web.preferences': result = { enabled: false, scope: 'local', port: 3080 }; break
          case 'native.network.addresses': result = { addresses: [] }; break
          default: throw new Error(`Unexpected native request ${frame.method}`)
        }
        send({ id: frame.id, result })
      } else if (frame.method === 'runtime.ready') ready.resolve()
      else if (pending.has(frame.id)) {
        const entry = pending.get(frame.id)
        pending.delete(frame.id)
        if (frame.error) entry.reject(new Error(frame.error.message))
        else entry.resolve(frame.result)
      }
    } catch (error) { fail(error) }
  })
  const request = (method, params = {}) => {
    const id = `guard-${++serial}`
    return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ id, method, params }) })
  }
  let deadline
  try {
    await Promise.race([(async () => {
      await ready.promise
      assert.equal((await request('web.status')).phase, 'disabled')
      const settings = await request('settings.describe')
      assert.equal(settings.find(item => item.ns === 'android-runtime').value.shellOutputLimit, 8192)
      const credential = (method, args) => request('api.call', { namespace: 'credentials', method, args })
      const ref = 'POCKET_GUARD_TEST_REFERENCE'
      const initial = await credential('describe', { refs: [ref] })
      assert.equal(initial[ref].configured, false)
      assert.equal(await credential('set', { ref, value: 'fixture-only-not-a-provider-secret' }), undefined)
      assert.equal((await credential('describe', { refs: [ref] }))[ref].configured, true)
      assert.equal(await credential('unset', { ref }), undefined)
      assert.equal((await credential('describe', { refs: [ref] }))[ref].configured, false)
    })(), new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error('Ready profile timed out')), 45000) })])
  } finally { clearTimeout(deadline) }
})
