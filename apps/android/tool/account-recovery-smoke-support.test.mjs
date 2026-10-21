import assert from 'node:assert/strict'
import { mkdir, mkdtemp } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { join, resolve } from 'node:path'
import test from 'node:test'
import { FixtureProcesses } from './fixture-processes.mjs'
import { launchRecoveryFixture } from './account-recovery-smoke-support.mjs'

const root = resolve(import.meta.dirname, '../../..')
const idleCarrier = `
  const socket = require('node:net').createConnection({
    host: '127.0.0.1', port: Number(process.env.POCKET_ACCOUNT_FIXTURE_IPC_PORT),
  });
  socket.on('connect', () => socket.write(JSON.stringify({ jsonrpc: '2.0', method: 'runtime.ready' }) + '\\n'));
  socket.on('data', () => {});
  socket.on('error', () => process.exit(1));
`

async function setup(context) {
  const home = await mkdtemp(join(root, '.cache/android/account-recovery-lifecycle-'))
  await mkdir(join(home, 'workspace'))
  const children = new FixtureProcesses()
  const owners = [], failures = []
  context.after(async () => {
    const results = await Promise.allSettled([...owners.map(owner => owner.stop()), children.close()])
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
    if (errors.length) throw new AggregateError(errors, 'Lifecycle test cleanup failed')
  })
  const spawn = (_command, _args, options) => children.spawn(process.execPath, ['-e', idleCarrier], options)
  return {
    children, owners, failures, spawn,
    options: { root, home, origin: 'http://127.0.0.1:1', fail: error => failures.push(error),
      register: owner => owners.push(owner), processes: { spawn, stop: child => children.stop(child) } },
  }
}

async function assertListenerClosed(port) {
  assert.ok(Number.isInteger(port))
  const socket = createConnection({ host: '127.0.0.1', port })
  const closed = new Promise(resolve => socket.once('close', resolve))
  try {
    await new Promise((resolve, reject) => {
      socket.once('error', error => error.code === 'ECONNREFUSED' ? resolve() : reject(error))
      socket.once('connect', () => reject(new Error(`Fixture listener still accepts connections on ${port}`)))
    })
  } finally { socket.destroy(); await closed }
}

test('spawn failure releases the already acquired listener and keeps stop idempotent', { timeout: 20000 }, async context => {
  const fixture = await setup(context)
  const failure = new Error('synthetic spawn failure')
  fixture.options.processes.spawn = () => { throw failure }
  await assert.rejects(launchRecoveryFixture(fixture.options), error => error === failure)
  assert.equal(fixture.owners.length, 1)
  const owner = fixture.owners[0]
  assert.equal(owner.child, undefined)
  assert.equal(owner.stop(), owner.stop())
  await owner.stop()
  await assertListenerClosed(owner.ipcPort)
  assert.deepEqual(owner.outstanding, { requests: 0, observations: 0 })
})

test('shutdown during acquisition prevents a later child from being spawned', { timeout: 20000 }, async context => {
  const fixture = await setup(context)
  let spawned = false
  fixture.options.processes.spawn = () => { spawned = true; throw new Error('must not spawn') }
  fixture.options.register = owner => { fixture.owners.push(owner); void owner.stop() }
  await assert.rejects(launchRecoveryFixture(fixture.options), /Fixture runtime stopping/)
  assert.equal(spawned, false)
  assert.equal(fixture.owners[0].ipcPort, undefined)
})

test('failure after child acquisition waits for its exit and releases the listener', { timeout: 20000 }, async context => {
  const fixture = await setup(context)
  const failure = new Error('synthetic stream setup failure')
  fixture.options.processes.spawn = (...args) => {
    const child = fixture.spawn(...args)
    child.stdout.pipe = () => { throw failure }
    return child
  }
  await assert.rejects(launchRecoveryFixture(fixture.options), error => error === failure)
  const owner = fixture.owners[0]
  assert.ok(fixture.children.records.get(owner.child).ended, 'the owned child must have emitted close')
  await assertListenerClosed(owner.ipcPort)
})

test('stop rejects pending requests and observations, closes IPC and waits for child exit', { timeout: 20000 }, async context => {
  const fixture = await setup(context)
  const owner = await launchRecoveryFixture(fixture.options)
  await owner.wait(frame => frame.method === 'runtime.ready')
  const request = assert.rejects(owner.request('never-reply'), /Fixture runtime stopping/)
  const observation = assert.rejects(owner.wait(frame => frame.method === 'never-observed'), /Fixture runtime stopping/)
  assert.deepEqual(owner.outstanding, { requests: 1, observations: 1 })
  const stopped = owner.stop()
  assert.equal(owner.stop(), stopped)
  await Promise.all([stopped, request, observation])
  assert.deepEqual(owner.outstanding, { requests: 0, observations: 0 })
  assert.ok(fixture.children.records.get(owner.child).ended)
  await assertListenerClosed(owner.ipcPort)
  await assert.rejects(owner.wait(() => true), /Fixture runtime stopping/)
  await assert.rejects(owner.request('late-request'), /Fixture runtime stopping/)
  assert.deepEqual(fixture.failures, [], 'intentional disposal cannot report a runtime failure')
})
