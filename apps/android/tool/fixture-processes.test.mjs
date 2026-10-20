import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtemp, readFile, rmdir, unlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { FixtureProcesses } from './fixture-processes.mjs'

const waitingProgram = "process.stdout.write('ready'); process.stdin.resume()"
function ready(child) {
  return once(child.stdout, 'data').then(([data]) => assert.equal(data.toString(), 'ready'))
}

test('shutdown drains real child close and prevents a late post-timeout restart at the recovery barrier', { timeout: 30000 }, async t => {
  const scope = new FixtureProcesses()
  const home = await mkdtemp(join(tmpdir(), 'pocket-library-lifetime-'))
  const marker = join(home, 'late-child-started.txt')
  const atRestart = Promise.withResolvers(), resumeRestart = Promise.withResolvers(), timeout = Promise.withResolvers()
  const deadlineFailure = new Error('synthetic profile deadline')
  let lateChild, attempted = false
  t.after(async () => {
    resumeRestart.resolve()
    if (lateChild) await scope.stop(lateChild)
    await scope.close()
    await unlink(marker).catch(error => { if (error.code !== 'ENOENT') throw error })
    await rmdir(home)
  })
  const first = scope.spawn(process.execPath, ['-e', waitingProgram], { stdio: ['pipe', 'pipe', 'pipe'] })
  await ready(first)
  const scenario = (async () => {
    const stopped = await scope.stop(first)
    assert.equal(stopped.signal, 'SIGKILL')
    assert.equal(stopped.error, undefined)
    // Deterministically pause exactly where the old smoke could resume after
    // the outer timeout had already captured its cleanup list.
    atRestart.resolve()
    await resumeRestart.promise
    attempted = true
    lateChild = scope.spawn(process.execPath, ['-e',
      "require('node:fs').writeFileSync(process.argv[1], 'late process executed')", marker],
    { stdio: ['ignore', 'pipe', 'pipe'] })
    await once(lateChild, 'close')
  })()
  const profile = Promise.race([scenario, timeout.promise]).finally(() => scope.close())
  await atRestart.promise
  timeout.reject(deadlineFailure)
  await assert.rejects(profile, error => error === deadlineFailure)
  resumeRestart.resolve()
  await assert.rejects(scenario, { code: 'FIXTURE_CLOSED' })
  assert.equal(attempted, true, 'the late launch attempt actually ran after timeout cleanup')
  assert.equal(lateChild, undefined, 'shutdown must reject before allocating a child')
  await assert.rejects(readFile(marker), { code: 'ENOENT' })
})

test('close shuts the allocation gate immediately and awaits every active child and pipe closing', { timeout: 30000 }, async t => {
  const scope = new FixtureProcesses()
  t.after(() => scope.close())
  const children = [0, 1].map(() =>
    scope.spawn(process.execPath, ['-e', waitingProgram], { stdio: ['pipe', 'pipe', 'pipe'] }))
  const closed = children.map(child => once(child, 'close'))
  await Promise.all(children.map(ready))
  const closing = scope.close()
  assert.throws(() => scope.spawn(process.execPath, ['-e', 'process.exit(0)']), { code: 'FIXTURE_CLOSED' })
  await closing
  for (const [code, signal] of await Promise.all(closed)) {
    assert.equal(signal, 'SIGKILL')
    assert.equal(code, null)
  }
  assert.ok(children.every(child => child.stdout.destroyed && child.stderr.destroyed))
  await scope.close()
})

test('stopping a finished generation permits a deliberate restart before global cleanup', { timeout: 30000 }, async t => {
  const scope = new FixtureProcesses()
  t.after(() => scope.close())
  const first = scope.spawn(process.execPath, ['-e', waitingProgram], { stdio: ['pipe', 'pipe', 'pipe'] })
  await ready(first)
  assert.equal((await scope.stop(first)).signal, 'SIGKILL')
  const second = scope.spawn(process.execPath, ['-e', waitingProgram], { stdio: ['pipe', 'pipe', 'pipe'] })
  await ready(second)
  assert.notEqual(second.pid, first.pid)
  await scope.close()
  assert.equal((await scope.stop(second)).signal, 'SIGKILL')
})
