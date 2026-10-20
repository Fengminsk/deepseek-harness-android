/** Source-only process-lifecycle regression; no Android staging or model calls. */
import assert from 'node:assert/strict'
import test from 'node:test'
import childProcess from 'node:child_process'
import fs from 'node:fs'
import { EventEmitter } from 'node:events'
import { syncBuiltinESMExports } from 'node:module'
import { PassThrough } from 'node:stream'
import { setTimeout as delay } from 'node:timers/promises'
import { runShell } from '../runtime/shell.mjs'

function fixture(t, { rows = { 972301: 'S' }, unreadable = false, rowOwners = {},
  groupError, directSignal = false } = {}) {
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')
  const getuid = Object.getOwnPropertyDescriptor(process, 'getuid')
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' })
  Object.defineProperty(process, 'getuid', { configurable: true, value: () => 10496 })
  const child = new EventEmitter()
  child.pid = 972301
  child.exitCode = null
  child.signalCode = null
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.exit = (code = 0, signal = null) => {
    child.exitCode = code
    child.signalCode = signal
    child.emit('exit', code, signal)
  }
  child.finish = (code = child.exitCode ?? 0, signal = child.signalCode) => {
    child.stdout.end()
    child.stderr.end()
    child.exit(code, signal)
    child.emit('close', code, signal)
  }
  child.kill = () => directSignal
  const calls = []
  const spawn = t.mock.method(childProcess, 'spawn', () => child)
  const kill = t.mock.method(process, 'kill', (pid, signal) => {
    assert.equal(pid, -child.pid)
    assert.equal(signal, 'SIGKILL')
    calls.push({ pid, signal })
    if (groupError) throw Object.assign(new Error('group unavailable'), { code: groupError })
    queueMicrotask(() => child.finish(child.exitCode, child.exitCode === null ? 'SIGKILL' : null))
    return true
  })
  const readDir = t.mock.method(fs, 'readdirSync', path => {
    assert.equal(path, '/proc')
    if (unreadable) throw Object.assign(new Error('proc unavailable'), { code: 'EACCES' })
    return Object.keys(rows)
  })
  const readFile = t.mock.method(fs, 'readFileSync', path => {
    const pid = path.match(/^\/proc\/(\d+)\/stat$/)?.[1]
    assert.ok(pid && rows[pid])
    if (rows[pid] === 'unreadable') throw Object.assign(new Error('row unavailable'), { code: 'EACCES' })
    // Parenthesized names can themselves contain ')'; pgrp is field 5.
    return `${pid} (a name) with spaces) ${rows[pid]} 10 ${child.pid} ${child.pid} 0 0\n`
  })
  const stat = t.mock.method(fs, 'statSync', path => {
    const pid = path.match(/^\/proc\/(\d+)$/)?.[1]
    assert.ok(pid && rows[pid])
    return { uid: rowOwners[pid] ?? 10496 }
  })
  syncBuiltinESMExports()
  t.after(() => {
    child.finish()
    for (const mock of [spawn, kill, readDir, readFile, stat]) mock.mock.restore()
    syncBuiltinESMExports()
    Object.defineProperty(process, 'platform', platform)
    if (getuid) Object.defineProperty(process, 'getuid', getuid)
    else delete process.getuid
  })
  return { child, calls, rows }
}

test('late deadline after process disappearance does not invent a timeout', async t => {
  const f = fixture(t, { rows: {}, groupError: 'ESRCH' })
  const result = runShell('sleep 45; echo BACKGROUND_OK', '.', { timeoutMs: 5 })
  f.child.stdout.write('BACKGROUND_OK\n')
  // Native exit/close delivery is intentionally later than the timer.
  await delay(20)
  f.child.finish(0)
  assert.deepEqual(await result, { stdout: 'BACKGROUND_OK\n', stderr: '', exitCode: 0,
    signal: null, timedOut: false, cancelled: false, truncated: false })
})

test('zombie-only process group is not signalled or reported as timed out', async t => {
  const f = fixture(t, { rows: { 972301: 'Z', 972302: 'Z' } })
  const result = runShell('already completed', '.', { timeoutMs: 5 })
  await delay(20)
  f.child.finish(0)
  assert.equal((await result).timedOut, false)
  assert.deepEqual(f.calls, [])
})

test('hidden other-UID processes do not invalidate an observed finished app group', async t => {
  const f = fixture(t, { rows: { 972301: 'Z', 972302: 'unreadable' }, rowOwners: { 972302: 10001 } })
  const result = runShell('already completed', '.', { timeoutMs: 5 })
  await delay(20)
  f.child.finish(0)
  assert.equal((await result).timedOut, false)
  assert.deepEqual(f.calls, [])
})

test('hidden same-UID process may be a live descendant and keeps timeout unconfirmed', async t => {
  const f = fixture(t, { rows: { 972301: 'Z', 972302: 'unreadable' } })
  const result = runShell('child & exit 0', '.', { timeoutMs: 5 })
  f.child.exit(0)
  const value = await result
  assert.equal(value.timedOut, null)
  assert.equal(value.timeoutStatus, 'unconfirmed')
  assert.equal(value.timeoutDiagnostic, 'GROUP_LIVENESS_UNCONFIRMED')
  assert.equal(f.calls.length, 1)
})

test('live timed-out command receives a group signal and preserves partial output', async t => {
  const f = fixture(t)
  const result = runShell('long command', '.', { timeoutMs: 5 })
  f.child.stdout.write('partial\n')
  const value = await result
  assert.equal(value.timedOut, true)
  assert.equal(value.cancelled, false)
  assert.equal(value.signal, 'SIGKILL')
  assert.equal(value.stdout, 'partial\n')
  assert.equal(f.calls.length, 1)
})

test('successful shell exit does not cancel deadline for live descendants holding pipes', async t => {
  const f = fixture(t, { rows: { 972302: 'S' } })
  const result = runShell('long_child & exit 0', '.', { timeoutMs: 5 })
  f.child.exit(0)
  const value = await result
  assert.equal(value.exitCode, 0)
  assert.equal(value.signal, null)
  assert.equal(value.timedOut, true)
  assert.equal(f.calls.length, 1)
})

test('unreadable process table keeps successful-root group termination unconfirmed', async t => {
  const f = fixture(t, { unreadable: true })
  const result = runShell('child & exit 0', '.', { timeoutMs: 5 })
  f.child.exit(0)
  const value = await result
  assert.equal(value.timedOut, null)
  assert.equal(value.timeoutStatus, 'unconfirmed')
  assert.equal(value.timeoutDiagnostic, 'GROUP_LIVENESS_UNCONFIRMED')
  assert.equal(f.calls.length, 1)
})

test('actual SIGKILL outcome confirms timeout even when proc is unreadable', async t => {
  fixture(t, { unreadable: true })
  const value = await runShell('long command', '.', { timeoutMs: 5 })
  assert.equal(value.signal, 'SIGKILL')
  assert.equal(value.timedOut, true)
  assert.equal(value.timeoutStatus, undefined)
})

test('failed group signal cannot be reported as a confirmed timeout', async t => {
  const f = fixture(t, { groupError: 'EPERM' })
  const result = runShell('command', '.', { timeoutMs: 5 })
  await delay(20)
  f.child.finish(0)
  const value = await result
  assert.equal(value.timedOut, null)
  assert.equal(value.timeoutDiagnostic, 'GROUP_SIGNAL_FAILED')
  assert.equal(value.terminationDiagnostic, 'GROUP_SIGNAL_FAILED')
})

test('unrelated SIGKILL after our rejected signal cannot confirm our timeout', async t => {
  const f = fixture(t, { groupError: 'EPERM' })
  const result = runShell('command', '.', { timeoutMs: 5 })
  await delay(20)
  f.child.finish(null, 'SIGKILL')
  const value = await result
  assert.equal(value.timedOut, null)
  assert.equal(value.timeoutStatus, 'unconfirmed')
  assert.equal(value.timeoutDiagnostic, 'GROUP_SIGNAL_FAILED')
})

test('direct-child fallback retains the group failure diagnostic', async t => {
  const f = fixture(t, { groupError: 'EPERM', directSignal: true })
  const result = runShell('command', '.', { timeoutMs: 5 })
  await delay(20)
  f.child.finish(null, 'SIGKILL')
  const value = await result
  assert.equal(value.timedOut, true)
  assert.equal(value.terminationDiagnostic, 'GROUP_SIGNAL_FAILED_CHILD_SIGNALLED')
})

test('cancellation owns termination and its later deadline does not relabel the result', async t => {
  const f = fixture(t, { groupError: 'ESRCH' })
  const controller = new AbortController()
  const result = runShell('command', '.', { timeoutMs: 5, signal: controller.signal })
  controller.abort()
  await delay(20)
  f.child.finish(0)
  const value = await result
  assert.equal(value.cancelled, true)
  assert.equal(value.timedOut, false)
  assert.equal(f.calls.length, 1)
})

test('spawn failure removes deadline and abort listener without a second termination', async t => {
  const f = fixture(t)
  const controller = new AbortController()
  const result = runShell('command', '.', { timeoutMs: 5, signal: controller.signal })
  f.child.emit('error', Object.assign(new Error('spawn failed'), { code: 'ENOENT' }))
  await assert.rejects(result, { code: 'ENOENT' })
  controller.abort()
  await delay(20)
  assert.deepEqual(f.calls, [])
})

test('ordinary close cleans up a future deadline and cancellation listener', async t => {
  const f = fixture(t)
  const controller = new AbortController()
  const result = runShell('done', '.', { timeoutMs: 5, signal: controller.signal })
  f.child.finish(0)
  assert.equal((await result).timedOut, false)
  controller.abort()
  await delay(20)
  assert.deepEqual(f.calls, [])
})
