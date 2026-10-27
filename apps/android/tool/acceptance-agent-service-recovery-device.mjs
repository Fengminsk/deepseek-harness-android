import { randomBytes } from 'node:crypto'
import { spawn } from 'node:child_process'
import { open, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { connectedDevice } from './acceptance-upgrade-device.mjs'
import { awaitRecoveryClose, runRecoveryAcceptance } from './agent-service-recovery-driver.mjs'
import { radioTaskProtocol } from './agent-service-task-radio.mjs'

const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.AgentServiceRecoveryInstrumentation`
const TASK_RUNNER = `${PACKAGE}.test/${PACKAGE}.AgentServiceTaskAcceptanceInstrumentation`
const check = (ok, message) => { if (!ok) throw new Error(message) }
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

/** Require target, network consent and a fresh report; radio-linux additionally admits one existing-account request. */
export function parseRecoveryArguments(args) {
  const values = new Map(), flags = new Set(['--accept-network-toggle-and-lock', '--no-wake', '--accept-real-account-request'])
  for (let i = 0; i < args.length; i++) {
    const flag = args[i]
    check(!values.has(flag), `Duplicate ${flag}`)
    if (flags.has(flag)) values.set(flag, true)
    else {
      check(['--adb', '--serial', '--report', '--exercise'].includes(flag), `Unknown recovery argument ${flag}`)
      check(args[i + 1] && !args[i + 1].startsWith('--'), `Missing ${flag}`)
      values.set(flag, args[++i])
    }
  }
  check(values.get('--accept-network-toggle-and-lock'), 'Explicit --accept-network-toggle-and-lock is required')
  for (const flag of ['--adb', '--serial', '--report']) check(values.has(flag), `Missing ${flag}`)
  check(/^[A-Za-z0-9._:-]+$/.test(values.get('--serial')), 'Invalid recovery serial')
  const exercise = values.get('--exercise')
  check(exercise === undefined || exercise === 'radio-linux', 'Unsupported recovery exercise')
  check((exercise === 'radio-linux') === values.has('--accept-real-account-request'),
    'radio-linux and explicit --accept-real-account-request must be supplied together')
  return { adb: resolve(values.get('--adb')), serial: values.get('--serial'), report: resolve(values.get('--report')),
    ...(exercise ? { exercise } : {}) }
}

/** Own bounded ADB close; timeout or cancellation never becomes a successful command. */
export function startRecoveryAdb(adb, serial, argv, { timeoutMs, signal, mutation = false, launch = spawn }) {
  signal?.throwIfAborted()
  const child = launch(adb, ['-s', serial, ...argv], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
  let output = '', bytesRead = 0, failure = null, exit = null, timer, killTimer
  let finish
  const closed = new Promise(resolve => { finish = resolve })
  const unref = () => { child.unref(); child.stdout.destroy(); child.stderr.destroy() }
  const requestStop = error => {
    failure ??= error
    clearTimeout(timer)
    try { child.kill('SIGKILL') } catch (error) { failure ??= error }
    killTimer ??= setTimeout(unref, 3000)
  }
  const append = bytes => {
    bytesRead += bytes.length
    if (bytesRead > 2 * 1024 * 1024) requestStop(new Error('ADB output exceeded 2 MiB'))
    else output += bytes.toString()
  }
  child.stdout.on('data', append)
  child.stderr.on('data', append)
  child.on('error', error => { failure ??= error })
  child.once('close', (code, exitSignal) => {
    exit = { code, signal: exitSignal }
    clearTimeout(timer); clearTimeout(killTimer)
    signal?.removeEventListener('abort', abort)
    finish(exit)
  })
  const abort = () => requestStop(signal.reason)
  // Dispatching svc transfers cancellation responsibility to its bounded command
  // owner. Restoration must not race a network mutation whose RPC was just aborted.
  if (signal && !mutation) signal.addEventListener('abort', abort, { once: true })
  if (signal?.aborted && !mutation) requestStop(signal.reason)
  timer = setTimeout(() => requestStop(new Error('ADB command deadline exceeded')), timeoutMs)
  const result = async () => {
    try { await awaitRecoveryClose(closed, timeoutMs + 3500) }
    catch (error) { failure ??= error; requestStop(error); unref() }
    if (failure || exit?.code !== 0) {
      const error = new Error(`ADB ${argv.slice(0, 4).join(' ')} failed`, { cause: failure })
      error.commandOutcomeUnknown = mutation
      throw error
    }
    return output
  }
  return { pid: child.pid ?? null, closed, stop: async () => requestStop(new Error('Instrumentation retired by host')),
    unref, transcript: () => output, output: () => { if (failure) throw failure; return output }, result }
}

/** Invoke in the screen guard's process so cancellation awaits independent network restoration. */
export async function runRecoveryEntry(args, { signal }) {
  const config = parseRecoveryArguments(args)
  const reservation = await open(config.report, 'wx')
  await reservation.close()
  const originalPath = `${config.report}.original.json`
  const progressPath = `${config.report}.progress.json`
  await writeFile(progressPath, '{}\n', { flag: 'wx' })
  const io = {
    now: () => performance.now(), delay,
    command: async (argv, scope) => {
      scope.throwIfAborted()
      return startRecoveryAdb(config.adb, config.serial, ['shell', ...argv],
        { timeoutMs: 8000, signal: scope, mutation: argv[0] === 'svc' }).result()
    },
    instrument: token => startRecoveryAdb(config.adb, config.serial,
      ['shell', 'am', 'instrument', '-w', '-r', '-e', 'token', token,
        ...(config.exercise === 'radio-linux'
          ? ['-e', 'acceptRealAccountRequest', 'true', '-e', 'exercise', config.exercise, TASK_RUNNER] : [RUNNER])],
      { timeoutMs: 330000 }),
  }
  let completed
  try {
    const devices = await startRecoveryAdb(config.adb, config.serial, ['devices'], { timeoutMs: 8000, signal }).result()
    connectedDevice(devices, config.serial)
    const report = await runRecoveryAcceptance(io, { signal, token: randomBytes(16).toString('hex'),
      taskProtocol: config.exercise === 'radio-linux' ? radioTaskProtocol : undefined,
      onProgress: progress => writeFile(progressPath, JSON.stringify(progress, null, 2) + '\n'),
      onSnapshot: snapshot => writeFile(originalPath, JSON.stringify({ ...snapshot, serial: config.serial }, null, 2) + '\n', { flag: 'wx' }) })
    const result = { ...report, evidence: 'device-adb', serial: config.serial, originalSnapshotPath: originalPath,
      progressPath, exercise: config.exercise ?? 'idle-session' }
    completed = result
    await writeFile(config.report, JSON.stringify(result, null, 2) + '\n')
    return result
  } catch (error) {
    const report = { ...(error.recovery ?? completed), result: 'unknown', evidence: 'device-adb', serial: config.serial,
      originalSnapshotPath: originalPath, progressPath, exercise: config.exercise ?? 'idle-session', error: error.message }
    error.recovery = report
    error.retirement ??= completed?.retirement
    try { await writeFile(config.report, JSON.stringify(report, null, 2) + '\n') }
    catch (reportError) {
      process.stderr.write(JSON.stringify({ ...report, reportWriteFailure: reportError.message }) + '\n')
      const combined = new AggregateError([error, reportError], 'Recovery and report persistence failed')
      combined.recovery = report
      combined.retirement = error.retirement
      throw combined
    }
    throw error
  }
}

async function main(args) {
  const controller = new AbortController()
  const abort = () => controller.abort(new Error('Recovery interrupted; restoring original network'))
  process.on('SIGINT', abort); process.on('SIGTERM', abort)
  try { process.stdout.write(JSON.stringify(await runRecoveryEntry(args, { signal: controller.signal }), null, 2) + '\n') }
  finally { process.off('SIGINT', abort); process.off('SIGTERM', abort) }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  main(process.argv.slice(2)).catch(error => { console.error(error); process.exitCode = 1 })
