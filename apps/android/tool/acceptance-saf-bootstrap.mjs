/** Own a bounded, independently identified test-UID process around real SAF acceptance. */
import { spawn, execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { open } from 'node:fs/promises'
import { promisify } from 'node:util'
import { ownPtcPreparationProcess } from './acceptance-ptc-process-death-device.mjs'

/** Only this test package may be started or stopped by the bootstrap owner. */
export const SAF_TEST_PACKAGE = 'com.minnnng.dsh_android.test'
/** Self-target instrumentation; the main SAF runner continues to target the production App. */
export const SAF_BOOTSTRAP_RUNNER = `${SAF_TEST_PACKAGE}/com.minnnng.dsh_android.PtcSafBootstrapInstrumentation`
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const positive = value => Number.isSafeInteger(value) && value > 0
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))
const exec = promisify(execFile)

/**
 * @param output Owned instrumentation output.
 * @param token Expected UUID.
 * @param leaseMillis Expected lease.
 * @returns Complete readiness or null before its frame ends.
 */
export function parseSafBootstrapReady(output, token, leaseMillis) {
  const matches = [...output.matchAll(/^INSTRUMENTATION_STATUS: safBootstrapReady=(.*)\r?\n/gm)]
  if (!matches.length) return null
  if (matches.length !== 1) throw new Error('Duplicate SAF bootstrap readiness')
  if (!/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m.test(output.slice(matches[0].index))) return null
  const value = JSON.parse(matches[0][1])
  if (Object.keys(value).sort().join(',') !== 'appUid,leaseMillis,packageName,pid,schema,serviceBound,token,uid' ||
      !uuid.test(token) || value.token !== token || value.schema !== 1 || value.packageName !== SAF_TEST_PACKAGE ||
      !positive(value.pid) || !positive(value.uid) || !positive(value.appUid) || value.uid === value.appUid ||
      value.serviceBound !== true || value.leaseMillis !== leaseMillis) throw new Error('Invalid SAF bootstrap identity')
  return value
}

/**
 * @param output Full numeric PID/UID process observation.
 * @returns Parsed processes; incomplete observations fail.
 */
export function parseSafProcesses(output) {
  const lines = output.trim().split(/\r?\n/)
  if (!/^\s*PID\s+UID\s+\S+\s*$/.test(lines.shift() ?? '')) throw new Error('Missing full PID/UID process header')
  const processes = lines.filter(line => line.trim()).map(line => {
    const fields = /^\s*([1-9][0-9]*)\s+([0-9]+)\s+(\S.*)\s*$/.exec(line)
    if (!fields || !Number.isSafeInteger(Number(fields[1])) || !Number.isSafeInteger(Number(fields[2])))
      throw new Error('Invalid PID/UID process observation')
    return { pid: Number(fields[1]), uid: Number(fields[2]), name: fields[3].trim() }
  })
  if (new Set(processes.map(row => row.pid)).size !== processes.length) throw new Error('Duplicate observed PID')
  return processes
}

async function bounded(promise, milliseconds, message) {
  let timer
  try { return await Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), milliseconds)
  })]) } finally { clearTimeout(timer) }
}

/**
 * Own only the bootstrap; the callback owns its main-test resources and must settle on abort.
 * @param io Process adapter with actual close and full PID/UID observations.
 * @param operation Main SAF acceptance; rejection stays failure and abort requires actual teardown.
 * @param options Bounded lease and host deadlines.
 * @returns Main result plus confirmed bootstrap retirement, never SAF acceptance by itself.
 */
export async function runSafBootstrap(io, operation, { token = randomUUID(), leaseMillis = 300_000,
  readyTimeoutMillis = 30_000, cleanupTimeoutMillis = 15_000 } = {}) {
  if (!uuid.test(token) || !Number.isSafeInteger(leaseMillis) || leaseMillis < 60_000 || leaseMillis > 600_000)
    throw new Error('Invalid SAF bootstrap lease')
  if (![readyTimeoutMillis, cleanupTimeoutMillis].every(value => positive(value) && value <= 60_000))
    throw new Error('Invalid SAF bootstrap host deadline')
  if ((await io.processes()).some(row => row.name === SAF_TEST_PACKAGE || row.name.startsWith(`${SAF_TEST_PACKAGE}:`)))
    throw new Error('An existing test-package process is not owned by this bootstrap')
  const client = await io.start({ token, leaseMillis })
  const abort = new AbortController()
  let ready, value, mainTask, mainSettled = true, failure, stopped = false, retired = false, exitFailure
  const unexpectedExit = new Promise((_, reject) => { exitFailure = reject })
  // An early exit can precede readiness; observe it even before the main-operation race starts.
  unexpectedExit.catch(() => {})
  const onExit = client.closed.then(() => {
    if (!stopped) {
      const error = new Error('SAF bootstrap exited before the main test completed')
      abort.abort(error)
      exitFailure(error)
    }
  })
  try {
    const deadline = performance.now() + readyTimeoutMillis
    while (performance.now() < deadline) {
      const status = client.status()
      if (status.error) throw status.error
      if (status.ended) throw new Error('SAF bootstrap exited before readiness')
      ready = parseSafBootstrapReady(status.output, token, leaseMillis)
      if (ready) break
      await wait(50)
    }
    if (!ready) throw new Error('SAF bootstrap did not become ready')
    const observed = (await io.processes()).filter(row => row.pid === ready.pid)
    if (observed.length !== 1 || observed[0].uid !== ready.uid || observed[0].name !== SAF_TEST_PACKAGE)
      throw new Error('SAF bootstrap ready PID/UID was not actually observed')
    if (abort.signal.aborted) throw abort.signal.reason
    mainSettled = false
    mainTask = Promise.resolve().then(() => operation(abort.signal)).finally(() => { mainSettled = true })
    value = await bounded(Promise.race([mainTask, unexpectedExit]), leaseMillis, 'SAF main operation exceeded its bootstrap lease')
    if (abort.signal.aborted || client.status().ended) throw abort.signal.reason ?? new Error('SAF bootstrap ended early')
  } catch (error) { failure = error }
  finally {
    const errors = []
    abort.abort(failure ?? new Error('SAF main operation has finished'))
    if (mainTask && !mainSettled) {
      try { await bounded(mainTask.catch(() => {}), cleanupTimeoutMillis, 'SAF main operation teardown is unconfirmed') }
      catch (error) { errors.push(error) }
    }
    stopped = true
    try {
      await io.stopTestPackage()
      const deadline = performance.now() + cleanupTimeoutMillis
      do {
        const rows = await io.processes()
        if (!rows.some(row => row.name === SAF_TEST_PACKAGE || row.name.startsWith(`${SAF_TEST_PACKAGE}:`) ||
            (ready && (row.pid === ready.pid || row.uid === ready.uid)))) { retired = true; break }
        await wait(50)
      } while (performance.now() < deadline)
      if (!retired) throw new Error('SAF bootstrap PID/UID retirement is unconfirmed')
    } catch (error) { errors.push(error) }
    try {
      await bounded(client.dispose(), cleanupTimeoutMillis, 'SAF bootstrap ADB client cleanup is unconfirmed')
      await bounded(onExit, cleanupTimeoutMillis, 'SAF bootstrap ADB client close is unconfirmed')
    } catch (error) { errors.push(error) }
    if (errors.length) failure = new AggregateError(failure ? [failure, ...errors] : errors, 'SAF bootstrap cleanup failed')
  }
  if (failure) throw failure
  return { value, bootstrap: { ...ready, readyProcessObserved: true, uidRetired: retired,
    hostProcessClosed: true, mainOperationSettled: mainSettled } }
}

/**
 * Reusable around either the packaged PTC SAF suite or native SAF instrumentation. No APK installation.
 * @param options Exact ADB executable/device, fresh log path and optional bounded lease/deadlines.
 * @param operation Main acceptance callback; owns and joins its ADB/process resources on abort.
 * @returns Main result and confirmed bootstrap retirement after writing the owned output log.
 */
export async function withSafBootstrap({ adb, serial, logPath, ...options }, operation) {
  if (!adb || !serial || !logPath) throw new Error('ADB path, exact serial and a new bootstrap log path are required')
  const log = await open(logPath, 'wx')
  let client
  const shell = async args => {
    const result = await exec(adb, ['-s', serial, 'shell', ...args],
      { timeout: 15_000, maxBuffer: 2 * 1024 * 1024, windowsHide: true })
    return result.stdout
  }
  const io = {
    processes: async () => parseSafProcesses(await shell(['ps', '-A', '-w', '-o', 'PID,UID,ARGS'])),
    stopTestPackage: () => shell(['am', 'force-stop', SAF_TEST_PACKAGE]),
    start: async ({ token, leaseMillis }) => {
      const child = spawn(adb, ['-s', serial, 'shell', 'am', 'instrument', '-w', '-r',
        '-e', 'token', token, '-e', 'leaseMillis', String(leaseMillis), SAF_BOOTSTRAP_RUNNER], { windowsHide: true })
      const owned = ownPtcPreparationProcess(child)
      client = { ...owned, closed: new Promise(resolve => child.once('close', resolve)) }
      return client
    },
  }
  try { return await runSafBootstrap(io, operation, options) }
  finally {
    try { if (client) { await log.writeFile(client.status().output); await log.sync() } }
    finally { await log.close() }
  }
}
