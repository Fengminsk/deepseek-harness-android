import { createHash, randomBytes } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { open, stat, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate,
  parseHoldStatus, sdkTools } from './acceptance-upgrade-device.mjs'
import { startRecoveryAdb } from './acceptance-agent-service-recovery-device.mjs'
import { awaitRecoveryClose, parseRecoveryKeyguard } from './agent-service-recovery-driver.mjs'
import { parseAcceptanceProcesses, parseNonInteractivePowerState } from './device-screen-protection.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.TaskCompletionCrashInstrumentation`
const TOKEN = /^[0-9a-f]{32}$/

async function run(binary, args, timeout = 120_000) {
  const { stdout, stderr } = await exec(binary, args, {
    timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

async function fingerprint(input) {
  const path = resolve(input)
  const info = await stat(path)
  if (!path.endsWith('.apk') || !info.isFile() || info.size < 1 || info.size > 1024 * 1024 * 1024) {
    throw new Error(`Invalid APK: ${path}`)
  }
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

export function requireTaskCompletionInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter(block => {
    const name = /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const target = /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const process = /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    return name === `${PACKAGE}.TaskCompletionCrashInstrumentation` &&
      target === PACKAGE && process === `${PACKAGE}:agent`
  })
  if (matches.length !== 1) {
    throw new Error('AndroidTest APK lacks the exact Agent-process completion crash instrumentation')
  }
}

export function parseTaskCompletionPhase(output, phase, token, heldPid = null) {
  if (!TOKEN.test(token) || !['verify', 'cleanup'].includes(phase)) throw new Error('Invalid completion phase')
  const values = new Map()
  for (const match of output.matchAll(/^INSTRUMENTATION_RESULT: ([A-Za-z][A-Za-z0-9]*)=(.*)$/gm)) {
    if (values.has(match[1])) throw new Error(`Duplicate completion result field ${match[1]}`)
    values.set(match[1], match[2].trim())
  }
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const pid = values.get('processPid')
  if (codes.length !== 1 || codes[0][1] !== '-1' || values.get('passed') !== 'true' ||
      values.get('phase') !== phase || values.get('token') !== token ||
      values.get('endSeq') !== '41' || !/^[1-9]\d*$/.test(pid ?? '') ||
      !Number.isSafeInteger(Number(pid)) || (heldPid !== null && Number(pid) === heldPid) ||
      (phase === 'verify' && (values.get('validNotice') !== 'true' ||
        values.get('invalidNotices') !== 'false' || values.get('receiptsCleared') !== 'true')) ||
      (phase === 'cleanup' && values.get('cleaned') !== 'true')) {
    throw new Error(`Android ${phase} completion acceptance failed`)
  }
  return { phase, processPid: Number(pid),
    ...(phase === 'verify' ? { validNotice: true, invalidNotices: false, receiptsCleared: true }
      : { cleaned: true }) }
}

export function parseCommittedHold(output, token) {
  const pid = parseHoldStatus(output, token)
  if (pid === null) return null
  const status = output.split(/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m)[0]
  const committed = [...status.matchAll(/^INSTRUMENTATION_STATUS: receiptCommitted=(.*)$/gm)]
  if (committed.length !== 1 || committed[0][1].trim() !== 'true') {
    throw new Error('Held Agent has no committed completion receipt')
  }
  return pid
}

const BUDGETS = { command: 8000, hold: 20000, phase: 30000, retirement: 20000, close: 20000 }
const check = (condition, message) => { if (!condition) throw new Error(message) }
const failureType = error => ['Error', 'TypeError', 'RangeError', 'AbortError', 'AggregateError'].includes(error?.name)
  ? error.name : 'Error'

/** Parse explicit, noninstalling device consent or preserve the artifact-only preflight. */
export function parseTaskCompletionArguments(args) {
  const values = new Map(), flags = new Set(['--preflight-only', '--allow-existing', '--installed-only', '--no-wake'])
  for (let i = 0; i < args.length; i++) {
    const flag = args[i]
    check(!values.has(flag), 'Duplicate completion argument')
    if (flags.has(flag)) values.set(flag, true)
    else {
      check(['--adb', '--serial', '--apk', '--test-apk', '--report'].includes(flag), 'Unknown completion argument')
      check(args[i + 1] && !args[i + 1].startsWith('--'), `Missing ${flag}`)
      values.set(flag, args[++i])
    }
  }
  for (const name of ['--apk', '--test-apk']) check(values.has(name), `Missing ${name}`)
  const preflightOnly = values.has('--preflight-only')
  if (!preflightOnly) for (const name of ['--adb', '--serial', '--allow-existing', '--installed-only', '--no-wake', '--report'])
    check(values.has(name), `Missing ${name}`)
  if (values.has('--serial')) check(/^[A-Za-z0-9._:-]+$/.test(values.get('--serial')), 'Invalid device serial')
  return { preflightOnly, apk: resolve(values.get('--apk')), testApk: resolve(values.get('--test-apk')),
    ...(preflightOnly ? {} : { adb: resolve(values.get('--adb')), serial: values.get('--serial'),
      report: resolve(values.get('--report')), allowExisting: true, installedOnly: true, noWake: true }) }
}

/** Accept one installed base APK only; split APKs cannot be equated with a single local artifact. */
export function parseCompletionInstalledPath(output) {
  const match = /^package:(\/data\/app\/[A-Za-z0-9_~+./=-]+\/base\.apk)$/.exec(output.trim())
  check(match && !match[1].split('/').includes('..'), 'Installed base APK path is missing or ambiguous')
  return match[1]
}

/** Require the checksum output to name the exact inspected installed artifact. */
export function requireCompletionInstalledHash(output, path, expected) {
  const match = /^([0-9a-f]{64})[ \t]+([^\r\n]+)\r?\n?$/.exec(output)
  check(/^[0-9a-f]{64}$/.test(expected) && match?.[1] === expected && match[2] === path,
    'Installed APK SHA-256 differs from the inspected artifact')
}

/**
 * Run synthetic receipt recovery against exact installed artifacts and await independent retirement.
 * @param {object} io - Owned start(argv, options) ADB children, monotonic now() and bounded delay(ms).
 * @param {object} options - Explicit installed-only admission, serial, artifact hashes, token and optional cancellation.
 * @returns {Promise<object>} Sanitized evidence after all owned clients close and device processes retire; throws with report otherwise.
 */
export async function runTaskCompletionCrashAcceptance(io, { signal = new AbortController().signal, serial,
  app, testApk, token, allowExisting, installedOnly, noWake, budgets = BUDGETS }) {
  check(allowExisting === true && installedOnly === true && noWake === true, 'Explicit installed-only no-wake admission is required')
  check(TOKEN.test(token) && /^[A-Za-z0-9._:-]+$/.test(serial), 'Invalid completion identity')
  for (const key of Object.keys(BUDGETS)) check(Number.isSafeInteger(budgets[key]) && budgets[key] > 0 && budgets[key] <= BUDGETS[key], 'Invalid completion budget')
  check([app, testApk].every(value => /^[0-9a-f]{64}$/.test(value?.sha256)), 'Missing artifact hashes')
  const owners = [], cleanupFailures = []
  const independent = new AbortController().signal
  let stage = 'preflight', failure = null, started = false, heldPid, verified, cleaned
  let preflightEmpty = false, deviceProcessesGone = false, forceStopConfirmed = false
  const start = (argv, timeoutMs, scope) => {
    scope?.throwIfAborted()
    const child = io.start(argv, { timeoutMs, signal: scope })
    const owner = { child, settled: false, exit: null }
    owner.closed = child.closed.then(exit => { owner.settled = true; owner.exit = exit; return exit })
    owners.push(owner)
    return owner
  }
  const command = async (argv, scope = signal) => {
    const owner = start(['shell', ...argv], budgets.command, scope)
    return owner.child.result()
  }
  const locked = async scope => {
    check(parseNonInteractivePowerState(await command(['dumpsys', 'power'], scope)), 'Completion acceptance requires noninteractive state')
    check(parseRecoveryKeyguard(await command(['dumpsys', 'window', 'policy'], scope)), 'Completion acceptance requires locked keyguard')
  }
  const processes = async scope => parseAcceptanceProcesses(await command(['ps', '-A', '-w', '-o', 'PID,ARGS'], scope))
  const waitEmpty = async scope => {
    const deadline = io.now() + budgets.retirement
    do {
      if (!(await processes(scope)).length) return true
      await io.delay(50)
    } while (io.now() < deadline)
    return false
  }
  const instrument = (phase, scope) => start(['shell', 'am', 'instrument', '-w', '-r',
    '-e', 'phase', phase, '-e', 'token', token, RUNNER], phase === 'hold' ? budgets.hold : budgets.phase, scope)
  const phase = async (name, scope, previousPid) => {
    const owner = instrument(name, scope)
    const output = await owner.child.result()
    return parseTaskCompletionPhase(output, name, token, previousPid)
  }
  try {
    signal.throwIfAborted()
    const devices = start(['devices'], budgets.command, signal)
    connectedDevice(await devices.child.result(), serial)
    await locked(signal)
    preflightEmpty = (await processes(signal)).length === 0
    check(preflightEmpty, 'Completion acceptance refuses existing App or test processes')
    for (const [packageName, artifact] of [[PACKAGE, app], [`${PACKAGE}.test`, testApk]]) {
      const path = parseCompletionInstalledPath(await command(['pm', 'path', packageName]))
      requireCompletionInstalledHash(await command(['sha256sum', path]), path, artifact.sha256)
    }
    await locked(signal)
    preflightEmpty = (await processes(signal)).length === 0
    check(preflightEmpty, 'App or test process started during preflight')
    signal.throwIfAborted()
    stage = 'hold'; started = true
    // The held main thread must be killed before any further observation RPC.
    const hold = instrument('hold', signal), deadline = io.now() + budgets.hold
    do {
      signal.throwIfAborted()
      check(!hold.settled, 'Completion hold exited before force-stop')
      heldPid = parseCommittedHold(hold.child.output(), token)
      if (heldPid !== null) break
      await io.delay(20)
    } while (io.now() < deadline)
    check(heldPid !== null && heldPid !== undefined, 'Committed completion hold did not become ready')
    stage = 'kill'
    await command(['am', 'force-stop', PACKAGE], independent)
    await awaitRecoveryClose(hold.closed, budgets.close)
    check(!/^INSTRUMENTATION_(RESULT: passed=true|CODE: -1)\s*$/m.test(hold.child.transcript()),
      'Held Agent returned successfully instead of being killed')
    check(await waitEmpty(independent), 'Held Agent or related process remained after force-stop')
    signal.throwIfAborted()
    await locked(signal)
    stage = 'verify'; verified = await phase('verify', signal, heldPid)
    signal.throwIfAborted()
  } catch (error) { failure = error }
  finally {
    // Native cleanup requires a successfully acknowledged receipt. Never bypass
    // that precondition to clear unknown state after a failed verification.
    if (verified) {
      try {
        await locked(independent)
        cleaned = await phase('cleanup', independent)
      } catch (error) { cleanupFailures.push({ stage: 'native-cleanup', type: failureType(error) }) }
    }
    if (started) {
      let stops = 0
      for (const packageName of [PACKAGE, `${PACKAGE}.test`]) {
        try { await command(['am', 'force-stop', packageName], independent); stops++ }
        catch (error) { cleanupFailures.push({ stage: 'force-stop', type: failureType(error) }) }
      }
      forceStopConfirmed = stops === 2
    }
    for (const owner of owners) {
      if (!owner.settled) {
        try {
          await owner.child.stop()
          await awaitRecoveryClose(owner.closed, budgets.close)
        } catch (error) {
          cleanupFailures.push({ stage: 'client-close', type: failureType(error) })
          owner.child.unref()
        }
      }
    }
    if (started) {
      try { deviceProcessesGone = await waitEmpty(independent) }
      catch (error) { cleanupFailures.push({ stage: 'process-observation', type: failureType(error) }) }
      if (!deviceProcessesGone) cleanupFailures.push({ stage: 'device-retirement', type: 'Error' })
    } else deviceProcessesGone = preflightEmpty
    // Retirement observations themselves own ADB clients, including failed ps.
    for (const owner of owners) if (!owner.settled) {
      try { await owner.child.stop(); await awaitRecoveryClose(owner.closed, budgets.close) }
      catch (error) { cleanupFailures.push({ stage: 'client-close', type: failureType(error) }); owner.child.unref() }
    }
  }
  if (signal.aborted && !failure) failure = signal.reason ?? new Error('Completion acceptance cancelled')
  const hostProcessClosed = owners.every(owner => owner.settled)
  const retirement = { hostProcessClosed, deviceProcessesGone, forceStopConfirmed,
    confirmed: hostProcessClosed && deviceProcessesGone && (!started || forceStopConfirmed) }
  const report = { schema: 1, result: !failure && cleaned && retirement.confirmed && !cleanupFailures.length ? 'pass' : 'unknown',
    phase: failure ? stage : 'complete', token, serial, installedOnly: true, noWake: true,
    appSha256: app.sha256, testApkSha256: testApk.sha256, heldPid: heldPid ?? null,
    verified: verified ?? null, cleaned: cleaned ?? null, retirement, cleanupFailures,
    syntheticStateMayRemain: started && !cleaned, committedReceiptRecoveredAfterForceStop: !!verified,
    invalidReceiptSuppressed: !!verified, realAgentTaskReplayTested: false,
    physicalPanelEvidence: 'requires-outer-owner', ...(failure ? { failure: { stage, type: failureType(failure) } } : {}) }
  if (report.result !== 'pass') {
    const error = new Error('Completion crash acceptance failed', { cause: failure })
    error.completion = report; error.retirement = retirement
    throw error
  }
  return report
}

async function inspectArtifacts(config) {
  const [app, testApk] = await Promise.all([fingerprint(config.apk), fingerprint(config.testApk)])
  check(app.path !== testApk.path, 'App and AndroidTest APK must differ')
  const tools = await sdkTools()
  const inspect = async artifact => ({ ...artifact,
    ...parseBadging(await run(tools.aapt2, ['dump', 'badging', artifact.path], 30000)),
    certificate: parseCertificate(await run('java', ['-jar', tools.apksigner, 'verify', '--print-certs', artifact.path], 30000)) })
  const [appIdentity, testIdentity] = await Promise.all([inspect(app), inspect(testApk)])
  check(appIdentity.packageName === PACKAGE && testIdentity.packageName === `${PACKAGE}.test` &&
    appIdentity.certificate === testIdentity.certificate, 'App and AndroidTest package or signing identity differs')
  requireTaskCompletionInstrumentation(await run(tools.aapt2,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30000))
  return { app: appIdentity, testApk: testIdentity }
}

/**
 * Run in the screen guard process so cancellation waits for independent cleanup.
 * @param {string[]} args - Explicit installed-only arguments, or artifact-only preflight.
 * @param {object} options - Optional signal controlled by the caller; no display operations are performed.
 * @returns {Promise<object>} Persisted sanitized report; a failure also carries completion and retirement evidence.
 */
export async function runTaskCompletionEntry(args, { signal = new AbortController().signal } = {}) {
  const config = parseTaskCompletionArguments(args)
  if (config.preflightOnly) return { result: 'preflight-pass', ...await inspectArtifacts(config) }
  check(config.report !== config.apk && config.report !== config.testApk, 'Report must not replace an artifact')
  const reservation = await open(config.report, 'wx')
  await reservation.close()
  const token = randomBytes(16).toString('hex')
  let completed
  try {
    await writeFile(config.report, JSON.stringify({ schema: 1, result: 'pending', token, installedOnly: true }) + '\n')
    signal.throwIfAborted()
    const artifacts = await inspectArtifacts(config)
    signal.throwIfAborted()
    const result = await runTaskCompletionCrashAcceptance({ now: () => performance.now(),
      delay: ms => new Promise(resolve => setTimeout(resolve, ms)),
      start: (argv, options) => startRecoveryAdb(config.adb, config.serial, argv, options),
    }, { ...config, ...artifacts, token, signal })
    completed = { ...result, evidence: 'device-adb' }
    await writeFile(config.report, JSON.stringify(completed, null, 2) + '\n')
    return completed
  } catch (error) {
    const report = { ...(error.completion ?? completed ?? { schema: 1, token, phase: 'artifact-preflight',
      retirement: { confirmed: false } }), result: 'unknown', evidence: 'device-adb',
      failure: error.completion?.failure ?? { stage: 'entry', type: failureType(error) } }
    error.completion = report; error.retirement = report.retirement
    try { await writeFile(config.report, JSON.stringify(report, null, 2) + '\n') }
    catch (writeError) {
      const combined = new AggregateError([error, writeError], 'Completion report persistence failed')
      combined.completion = report; combined.retirement = report.retirement
      process.stderr.write(JSON.stringify(report) + '\n')
      throw combined
    }
    throw error
  }
}

async function main(args) {
  const controller = new AbortController()
  const abort = () => controller.abort(new Error('Completion acceptance cancelled'))
  process.on('SIGINT', abort); process.on('SIGTERM', abort)
  try { process.stdout.write(JSON.stringify(await runTaskCompletionEntry(args, { signal: controller.signal }), null, 2) + '\n') }
  finally { process.off('SIGINT', abort); process.off('SIGTERM', abort) }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(JSON.stringify(error.completion ?? { result: 'unknown', failure: { type: failureType(error) } }) + '\n')
    process.exitCode = 1
  })
