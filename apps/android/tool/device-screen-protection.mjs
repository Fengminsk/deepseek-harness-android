import { execFile, spawn } from 'node:child_process'
import { writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const CATEGORY = 'android.hardware.display.category.ALL_INCLUDING_DISABLED'
const check = (ok, message) => { if (!ok) throw new Error(message) }
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const TOOL_ROOT = dirname(fileURLToPath(import.meta.url))
const ENTRIES = new Set([
  'acceptance-native-workflow-device.mjs', 'acceptance-native-workflow-process-death-device.mjs',
  'acceptance-upgrade-device.mjs', 'acceptance-ptc-process-death-device.mjs',
  'acceptance-ptc-callback-device.mjs', 'acceptance-linux-vm-lifecycle-device.mjs',
].map(name => resolve(TOOL_ROOT, name)))

/** Match every internal logical display to its physical panel without rounding 64-bit IDs. */
export function parseInternalDisplays(idsText, displayText, surfaceText) {
  const ids = idsText.trim().split(/\s+/)
  check(ids.length > 0 && ids.length <= 8 && ids.every(id => /^(0|[1-9]\d*)$/.test(id)) &&
    new Set(ids).size === ids.length, 'Internal display IDs are missing or ambiguous')
  const logical = [...displayText.matchAll(/^  Display (\d+):\r?\n([\s\S]*?)(?=^  Display \d+:|^(?!\s)\S|$(?![\s\S]))/gm)]
  const physical = [...surfaceText.matchAll(/^Display (\d+)\r?\n([\s\S]*?)(?=^Display \d+\r?$|^(?!\s)\S|$(?![\s\S]))/gm)]
    .filter(match => /^\s+connectionType=Internal\s*$/m.test(match[2]))
  check(physical.length === ids.length && new Set(physical.map(p => p[1])).size === physical.length,
    'Internal panel inventory is incomplete')
  const panels = ids.map(id => {
    const matches = logical.filter(match => match[1] === id)
    check(matches.length === 1, 'Logical display mapping is missing or duplicated')
    const mappings = [...matches[0][2].matchAll(/^\s+mPrimaryDisplayDevice=.*\(local:(\d+)\)\r?$/gm)]
    check(mappings.length === 1, 'Physical display mapping is unavailable')
    const panelId = mappings[0][1]
    const found = physical.filter(match => match[1] === panelId)
    check(found.length === 1, 'Internal panel is not present in SurfaceFlinger')
    const modes = [...found[0][2].matchAll(/^\s+powerMode=(\w+)\r?$/gm)]
    check(modes.length === 1, 'Panel power mode is unavailable')
    return { id, physicalId: panelId, powerMode: modes[0][1] }
  })
  check(new Set(panels.map(p => p.physicalId)).size === panels.length, 'Two displays map to the same panel')
  return panels.sort((a, b) => Number(a.id) - Number(b.id))
}

function requireOff(panels, original) {
  check(panels.every(p => p.powerMode === 'Off'), 'OLED protection lost: an internal panel is not Off')
  check(JSON.stringify(panels.map(p => [p.id, p.physicalId])) ===
    JSON.stringify(original.map(p => [p.id, p.physicalId])), 'Internal display topology changed during testing')
}

/** The run owner must join bounded retirement, reporting unknown retirement explicitly on failure. */
export async function withScreenProtection(io, run, { timeoutMs, pollMs = 2000, signal }) {
  check(Number.isSafeInteger(timeoutMs) && timeoutMs >= 1000 && timeoutMs <= 3660000,
    'Screen protection requires a bounded deadline of at most 61 minutes')
  check(Number.isSafeInteger(pollMs) && pollMs >= 10 && pollMs <= 5000, 'Invalid polling interval')
  const controller = new AbortController()
  const samples = []
  let original = null
  let stopping = false
  let watcher
  let timer
  let result
  let failure
  let retirement
  let blackout
  let blackoutFailure
  let restored = false
  const known = new Set()
  const remember = panels => { for (const panel of panels) known.add(panel.id) }
  const forceOff = async () => {
    const offController = new AbortController()
    const timer = setTimeout(() => offController.abort(new Error('Emergency power-off deadline exceeded')), 8000)
    let results
    try {
      results = await Promise.allSettled([...known].map(id =>
        beforeDeadline(io.powerOff(id, offController.signal), offController.signal)))
    } finally { clearTimeout(timer) }
    const errors = results.filter(r => r.status === 'rejected').map(r => r.reason)
    if (errors.length) throw new AggregateError(errors, 'Panel power-off is unconfirmed')
  }
  const interrupt = error => {
    if (controller.signal.aborted) return
    // Begin physical protection before asking potentially slow device work to retire.
    blackout = forceOff().catch(error => { blackoutFailure = error })
    controller.abort(error)
  }
  const interrupted = () => interrupt(signal.reason)
  signal?.addEventListener('abort', interrupted, { once: true })
  try {
    if (signal?.aborted) throw signal.reason
    timer = setTimeout(() => interrupt(new Error('Screen-protected test deadline exceeded')), timeoutMs)
    original = await io.inspect(controller.signal)
    remember(original)
    check(original.length > 0, 'No internal panel found')
    await forceOff()
    const sample = async () => {
      const panels = await io.inspect(controller.signal)
      remember(panels)
      requireOff(panels, original)
      samples.push({ at: new Date().toISOString(), panels })
    }
    await sample()
    controller.signal.throwIfAborted()
    watcher = (async () => {
      while (!stopping && !controller.signal.aborted) {
        await io.delay(pollMs)
        if (stopping || controller.signal.aborted) return
        try { await sample() } catch (error) { interrupt(error) }
      }
    })()
    result = await run(controller.signal)
    retirement = result?.retirement
    if (controller.signal.aborted) throw controller.signal.reason
    await sample()
    if (controller.signal.aborted) throw controller.signal.reason
  } catch (error) {
    failure = error instanceof Error ? error : new Error(String(error))
    retirement = failure.retirement ?? retirement
    interrupt(failure)
  }
  finally {
    stopping = true
    signal?.removeEventListener('abort', interrupted)
    clearTimeout(timer)
    try { await watcher } catch (error) { failure ??= error }
    await blackout
    if (blackoutFailure) failure = new AggregateError([failure, blackoutFailure].filter(Boolean),
      'Test and emergency power-off failed')
    if (!failure && controller.signal.aborted) failure = controller.signal.reason
    if (original) {
      const cleanup = new AbortController()
      const cleanupTimer = setTimeout(() => cleanup.abort(new Error('Display cleanup deadline exceeded')), 40000)
      const operation = promise => beforeDeadline(promise, cleanup.signal)
      try {
        // Never restore normal display power while Android is interactive.
        await operation(io.sleep(cleanup.signal))
        check(await operation(io.nonInteractive(cleanup.signal)), 'Phone did not sleep; leave panel power overrides in place')
        check(retirement?.confirmed !== false,
          'Acceptance retirement is unconfirmed; leave panel power overrides in place')
        for (const panel of original) {
          check(await operation(io.nonInteractive(cleanup.signal)), 'Phone left sleep; leave panel power overrides in place')
          await operation(io.powerReset(panel.id, cleanup.signal))
        }
        const panels = await operation(io.inspect(cleanup.signal))
        remember(panels)
        requireOff(panels, original)
        check(await operation(io.nonInteractive(cleanup.signal)), 'Phone left sleep during display cleanup')
        restored = true
      } catch (cleanup) {
        // A failed reset or unreadable topology still leaves the original IDs known.
        // Do not rely on one more successful dumpsys to reapply their overrides.
        let offFailure
        try { await forceOff() } catch (error) { offFailure = error }
        failure = new AggregateError([failure, cleanup, offFailure].filter(Boolean), 'Test and screen cleanup failed')
      } finally { clearTimeout(cleanupTimer) }
    }
  }
  if (failure) {
    if (retirement) failure.retirement = retirement
    failure.protection = { samples, restoredWhileNonInteractive: restored,
      finalDisplayState: restored ? 'off' : 'unknown', powerOffAttempted: known.size > 0 }
    throw failure
  }
  return { result, protection: { samples, restoredWhileNonInteractive: true } }
}

function adapter(adb, serial) {
  const shell = async (args, signal) => {
    const { stdout } = await exec(adb, ['-s', serial, 'shell', ...args],
      { timeout: 8000, signal, killSignal: 'SIGKILL', maxBuffer: 12 * 1024 * 1024, windowsHide: true })
    return stdout
  }
  return {
    delay,
    inspect: async signal => {
      const ids = await shell(['cmd', 'display', 'get-displays', '--ids-only', '--type', 'internal', '--category', CATEGORY], signal)
      const displays = await shell(['dumpsys', 'display'], signal)
      return parseInternalDisplays(ids, displays, await shell(['dumpsys', 'SurfaceFlinger'], signal))
    },
    powerOff: (id, signal) => shell(['cmd', 'display', 'power-off', id], signal),
    powerReset: (id, signal) => shell(['cmd', 'display', 'power-reset', id], signal),
    sleep: signal => shell(['input', 'keyevent', '223'], signal),
    nonInteractive: async signal => parseNonInteractivePowerState(await shell(['dumpsys', 'power'], signal)),
    stopAcceptance: async signal => {
      const results = await Promise.allSettled([PACKAGE, `${PACKAGE}.test`]
        .map(name => shell(['am', 'force-stop', name], signal)))
      const errors = results.filter(r => r.status === 'rejected').map(r => r.reason)
      if (errors.length) throw new AggregateError(errors, 'Acceptance force-stop was not acknowledged')
    },
    acceptanceProcesses: async signal => parseAcceptanceProcesses(await shell(['ps', '-A', '-w', '-o', 'PID,ARGS'], signal)),
    startChild: args => {
      const child = spawn(process.execPath, args, { stdio: 'inherit', windowsHide: true,
        detached: process.platform !== 'win32', env: { ...process.env, ANDROID_SERIAL: serial } })
      const closed = new Promise((resolve, reject) => {
        child.once('error', reject)
        child.once('close', code => resolve(code))
      })
      return { closed, pid: child.pid ?? null, unref: () => child.unref(), async stop(signal) {
        if (process.platform === 'win32' && child.pid) {
          await exec('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'],
            { signal, killSignal: 'SIGKILL', windowsHide: true, timeout: 8000 })
        } else if (child.pid) {
          try { process.kill(-child.pid, 'SIGKILL') }
          catch (error) { if (error.code !== 'ESRCH') throw error }
        }
      } }
    },
  }
}

/** Noninteractive state permits reset only after retirement; physical Off is verified separately. */
export function parseNonInteractivePowerState(text) {
  const raw = [...text.matchAll(/^\s*mWakefulness=(.*?)\r?$/gm)].map(match => match[1].trim())
  const names = new Map([['Asleep', 'Asleep'], ['Dozing', 'Dozing'], ['0', 'Asleep'], ['3', 'Dozing']])
  const states = raw.map(state => names.get(state))
  if (!states.length || states.some(state => state === undefined)) return false
  // Vendor numeric mirrors must agree with the named value; without a reliable
  // group mapping, mixed mirror values cannot authorize resetting panel power.
  return !raw.some(state => /^\d+$/.test(state)) || new Set(states).size === 1
}

/** Screen-only seconds measure observation; acceptance seconds include preparation. */
export function resolveScreenProtectionTiming(seconds, screenOnly) {
  check(Number.isSafeInteger(seconds) && seconds >= 1 && seconds <= 3600,
    'Screen protection requires 1 to 3600 whole seconds')
  const requestedMs = seconds * 1000
  return { observationMs: screenOnly ? requestedMs : null,
    timeoutMs: requestedMs + (screenOnly ? 60000 : 0) }
}

/** Observe for the full requested duration after protection has been established. */
export async function runScreenOnlyProbe(signal, observationMs) {
  check(Number.isSafeInteger(observationMs) && observationMs >= 1000 && observationMs <= 3600000,
    'Invalid screen observation duration')
  signal.throwIfAborted()
  const started = performance.now()
  while (performance.now() - started < observationMs) {
    await delay(Math.min(100, Math.max(1, observationMs - (performance.now() - started))))
    signal.throwIfAborted()
  }
  return { kind: 'screen-only-probe', appTestsRun: false, requestedObservationMs: observationMs,
    observedMs: performance.now() - started }
}

/** Bind only reviewed entry points to the wrapper's exact ADB executable and device. */
export function bindAcceptanceArguments(args, { adb, serial }) {
  check(args.length > 0 && ENTRIES.has(resolve(args[0])), 'Device acceptance entry has not been reviewed for target binding')
  const result = [resolve(args[0]), ...args.slice(1)]
  check(!result.slice(1).includes('--'), 'Nested argument separators are not permitted')
  for (const [flag, value] of [['--adb', resolve(adb)], ['--serial', serial]]) {
    check(!result.some(arg => arg.startsWith(`${flag}=`)), `Use the exact ${flag} argument`)
    const positions = result.flatMap((arg, i) => arg === flag ? [i] : [])
    check(positions.length <= 1, `Duplicate ${flag}`)
    if (positions.length) {
      const actual = result[positions[0] + 1]
      check(actual && (flag === '--adb' ? resolve(actual) === value : actual === value), `Acceptance ${flag} differs from protection target`)
      result[positions[0] + 1] = value
    } else result.push(flag, value)
  }
  return result
}

/** Read full App, test and isolated-service process names; a truncated listing is not retirement proof. */
export function parseAcceptanceProcesses(output) {
  const lines = output.trim().split(/\r?\n/)
  check(/^\s*PID\s+(ARGS|CMD|COMMAND)\s*$/.test(lines.shift() ?? ''), 'Full process-name listing is unavailable')
  const found = [], seen = new Set()
  for (const line of lines) {
    const match = /^\s*([1-9]\d*)\s+(\S.*)$/.exec(line)
    check(match && Number.isSafeInteger(Number(match[1])) && !seen.has(match[1]), 'Process listing is malformed')
    seen.add(match[1])
    const name = match[2].split(/\s/)[0]
    check(!(name.startsWith('com.minnnng') && PACKAGE.startsWith(name) && name !== PACKAGE),
      'Acceptance process name is truncated')
    if ([PACKAGE, `${PACKAGE}.test`].some(prefix => name === prefix || name.startsWith(`${prefix}:`))) {
      found.push({ pid: Number(match[1]), name })
    }
  }
  return found
}

async function beforeDeadline(promise, signal) {
  let reject
  const expired = new Promise((_resolve, fail) => { reject = fail })
  const aborted = () => reject(signal.reason)
  signal.addEventListener('abort', aborted, { once: true })
  if (signal.aborted) aborted()
  try { return await Promise.race([expired, promise]) }
  finally { signal.removeEventListener('abort', aborted) }
}

/** Own child termination and verify device retirement before allowing display cleanup to reset overrides. */
export async function runAcceptanceChild(args, signal, io, { cleanupMs = 20000 } = {}) {
  check(Number.isSafeInteger(cleanupMs) && cleanupMs >= 10 && cleanupMs <= 60000, 'Invalid retirement budget')
  signal.throwIfAborted()
  const child = io.startChild(args)
  let hostClosed = false
  const closed = child.closed.then(code => { hostClosed = true; return { code } }, error => ({ error }))
  let wake
  const aborted = new Promise(resolve => { wake = () => resolve({ error: signal.reason }); signal.addEventListener('abort', wake, { once: true }) })
  if (signal.aborted) wake()
  let outcome
  try {
    outcome = await Promise.race([closed, aborted])
  } finally { signal.removeEventListener('abort', wake) }
  const errors = []
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(new Error('Acceptance retirement deadline exceeded')), cleanupMs)
  const cleanupSignal = controller.signal
  let deviceRetired = false
  let hostStopAcknowledged = null
  let hostHandleReleased = false
  try {
    if (!hostClosed) {
      hostStopAcknowledged = false
      try {
        await beforeDeadline(child.stop(cleanupSignal), cleanupSignal)
        hostStopAcknowledged = true
      } catch (error) { errors.push(error) }
      try { await beforeDeadline(closed, cleanupSignal) } catch (error) { errors.push(error) }
    }
    // Even a failed host kill must attempt device retirement. Its own bounded
    // command is separate from the exhausted host retirement deadline.
    const forceStop = new AbortController()
    const stopTimer = setTimeout(() => forceStop.abort(new Error('Device force-stop deadline exceeded')), Math.min(cleanupMs, 8000))
    try { await beforeDeadline(io.stopAcceptance(forceStop.signal), forceStop.signal) }
    catch (error) { errors.push(error) }
    finally { clearTimeout(stopTimer) }
    if (hostClosed) {
      try {
        do {
          if ((await beforeDeadline(io.acceptanceProcesses(cleanupSignal), cleanupSignal)).length === 0) { deviceRetired = true; break }
          await beforeDeadline(io.delay(100), cleanupSignal)
        } while (!cleanupSignal.aborted)
      } catch (error) { errors.push(error) }
    }
  } finally {
    clearTimeout(timer)
    if (!hostClosed) {
      // Bounded cleanup has failed. Release the host handle, not its ownership
      // claim: the PID remains explicitly unretired and display reset is forbidden.
      try { child.unref(); hostHandleReleased = true } catch (error) { errors.push(error) }
    }
  }
  const retirement = { hostPid: child.pid, hostProcessClosed: hostClosed, hostStopAcknowledged,
    hostHandleReleased, deviceProcessesGone: deviceRetired,
    confirmed: hostClosed && deviceRetired && hostStopAcknowledged !== false }
  if (outcome.error || outcome.code !== 0 || signal.aborted || errors.length || !retirement.confirmed) {
    const error = new AggregateError([outcome.error, signal.aborted ? signal.reason : undefined, ...errors].filter(Boolean),
      `Device acceptance failed (exit ${outcome.code ?? 'unknown'}; host PID ${child.pid ?? 'unavailable'}; retirement ${retirement.confirmed ? 'confirmed' : 'unconfirmed'})`)
    error.retirement = retirement
    throw error
  }
  return { exitCode: outcome.code, retirement }
}

async function main(args) {
  const separator = args.indexOf('--')
  const options = separator < 0 ? args : args.slice(0, separator)
  const get = key => {
    const at = options.indexOf(key)
    check(at >= 0 && options[at + 1], `Missing ${key}`)
    return options[at + 1]
  }
  const serial = get('--serial')
  check(/^[A-Za-z0-9._:-]+$/.test(serial), 'Invalid ADB serial')
  const adb = resolve(get('--adb'))
  const io = adapter(adb, serial)
  const seconds = Number(get('--seconds'))
  const report = resolve(get('--report'))
  const probe = separator < 0
  const timing = resolveScreenProtectionTiming(seconds, probe)
  const controller = new AbortController()
  const interrupted = () => controller.abort(new Error('Screen-protected run interrupted'))
  process.on('SIGINT', interrupted)
  process.on('SIGTERM', interrupted)
  const childArgs = probe ? null : bindAcceptanceArguments(args.slice(separator + 1), { adb, serial })
  const run = probe ? signal => runScreenOnlyProbe(signal, timing.observationMs)
    : signal => runAcceptanceChild(childArgs, signal, io)
  try {
    const result = await withScreenProtection(io, run, { timeoutMs: timing.timeoutMs, signal: controller.signal })
    await writeFile(report, JSON.stringify({ schema: 2, serial, passed: true, ...result }, null, 2) + '\n')
    process.stdout.write(`Screen protection verified; report: ${report}\n`)
  } catch (error) {
    await writeFile(report, JSON.stringify({ schema: 2, serial, passed: false,
      error: error.message, protection: error.protection, retirement: error.retirement,
      deviceOutcome: error.protection?.finalDisplayState === 'off' && error.retirement?.confirmed !== false
        ? 'Test failed; final panels Off and display control restored while noninteractive'
        : 'Unknown until display and process retirement are verified; keep power-off overrides' }, null, 2) + '\n')
    throw error
  } finally {
    process.off('SIGINT', interrupted)
    process.off('SIGTERM', interrupted)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  main(process.argv.slice(2)).catch(error => { console.error(error); process.exitCode = 1 })
