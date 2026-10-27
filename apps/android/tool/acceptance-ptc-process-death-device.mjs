import { createHash, randomUUID } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'
import { parsePids, parseGuestProcesses, parseRunGuestPid } from './acceptance-native-workflow-process-death-device.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.NativeRuntimeToolsAcceptanceInstrumentation`
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

/** Require one complete readiness frame for the exact generated acceptance case. */
export function parsePtcDeathReady(output, caseId) {
  const matches = [...output.matchAll(/^INSTRUMENTATION_STATUS: ready=(.*)\r?\n/gm)]
  if (!matches.length) return null
  if (matches.length !== 1) throw new Error('Duplicate PTC readiness marker')
  if (!/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m.test(output.slice(matches[0].index))) return null
  const marker = JSON.parse(matches[0][1])
  if (Object.keys(marker).sort().join(',') !== 'agentPid,caseId,fileSha256,runId,schema' ||
      marker.schema !== 1 || marker.caseId !== caseId || !UUID.test(marker.runId) ||
      !/^[0-9a-f]{64}$/.test(marker.fileSha256) || !Number.isSafeInteger(marker.agentPid) || marker.agentPid <= 0) {
    throw new Error('Invalid PTC readiness identity')
  }
  return marker
}

/** Verify no replay and a read-only native receipt observation; this does not execute native recovery. */
export function parsePtcDeathRecovery(output, ready) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const results = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gm)]
  if (codes.length !== 1 || codes[0][1] !== '-1' || results.length !== 1) throw new Error('PTC recovery instrumentation failed')
  const result = JSON.parse(results[0][1])
  const checks = result.reports?.flatMap(report => report.checks ?? [])
  if (result.passed !== true || result.complete !== true || checks?.length !== 1) throw new Error('PTC recovery is incomplete')
  const check = checks[0]
  if (!['ADMITTED', 'INTERRUPTED_UNCONFIRMED'].includes(result.nativeReceiptState)
    || result.nativeOutputAbsent !== true) {
    throw new Error('PTC native receipt is missing or no longer unconfirmed without output')
  }
  if (check.name !== 'ptc-killed-dispatch-no-replay' || check.status !== 'passed' || check.caseId !== ready.caseId ||
      check.runId !== ready.runId || check.fileSha256 !== ready.fileSha256 || check.oldAgentPid !== ready.agentPid ||
      !Number.isSafeInteger(check.newAgentPid) || check.newAgentPid <= 0 || check.newAgentPid === ready.agentPid ||
      check.journalState !== 'dispatch-unconfirmed' || check.nativeRebindRequests !== 0 || check.replayedExecutions !== 0) {
    throw new Error('PTC recovery evidence disagrees with the killed run')
  }
  return { ...check, nativeReceiptState: result.nativeReceiptState, nativeOutputAbsent: true,
    nativeReceiptInspection: 'read-only-unconfirmed' }
}

function argument(args, flag) {
  const index = args.indexOf(flag)
  if (index < 0 || !args[index + 1] || args[index + 1].startsWith('--')) throw new Error(`Missing ${flag}`)
  return args[index + 1]
}

/**
 * Own an already-spawned preparation client until its stdio and process close.
 * @param {object} child - The runner's child process, observed immediately after spawn.
 * @param {number} timeoutMillis - Maximum teardown wait; timeout is an unconfirmed cleanup failure.
 * @returns {object} Bounded status and an idempotent disposal promise, never a device pass result.
 */
export function ownPtcPreparationProcess(child, timeoutMillis = 10000) {
  let output = '', ended = false, failure, disposal
  const stdout = chunk => { output = (output + chunk).slice(-64000) }
  const stderr = chunk => { output = (output + chunk).slice(-64000) }
  const error = value => { failure ??= value }
  const closed = new Promise(resolve => child.once('close', (code, signal) => {
    ended = true
    child.stdout?.off('data', stdout); child.stderr?.off('data', stderr)
    child.off('error', error)
    resolve({ code, signal })
  }))
  child.stdout?.on('data', stdout); child.stderr?.on('data', stderr)
  child.on('error', error)
  return {
    status: () => ({ output, ended, error: failure }),
    dispose() {
      disposal ??= (async () => {
        let timer
        try {
          if (!ended && child.pid !== undefined) {
            try { child.kill('SIGKILL') } catch (error) { failure ??= error }
          }
          const outcome = await Promise.race([closed, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('Owned ADB preparation client did not close; cleanup is unconfirmed')),
              timeoutMillis)
          })])
          if (failure) throw failure
          return outcome
        } finally { clearTimeout(timer) }
      })()
      return disposal
    },
  }
}

async function run(binary, args, timeout = 120_000) {
  const { stdout, stderr } = await exec(binary, args, { timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true })
  return `${stdout}${stderr}`
}
async function fingerprint(input) {
  const path = resolve(input), info = await stat(path)
  if (!path.endsWith('.apk') || !info.isFile() || info.size < 1) throw new Error('Invalid APK')
  const hash = createHash('sha256')
  for await (const part of createReadStream(path)) hash.update(part)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

/** Require the real Node/native carrier in the App Agent process, not a synthetic callback runner. */
export function requirePtcDeathInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter(block => /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1] === `${PACKAGE}.NativeRuntimeToolsAcceptanceInstrumentation`
    && /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1] === PACKAGE
    && /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1] === `${PACKAGE}:agent`)
  if (matches.length !== 1) throw new Error('AndroidTest APK lacks the exact PTC process-death carrier')
}

async function main(args) {
  const tools = await sdkTools()
  const inspect = async input => {
    const artifact = await fingerprint(input)
    return { ...artifact, ...parseBadging(await run(tools.aapt2, ['dump', 'badging', artifact.path], 30000)),
      certificate: parseCertificate(await run('java', ['-jar', tools.apksigner, 'verify', '--print-certs', artifact.path], 30000)) }
  }
  const [app, testApk] = await Promise.all([inspect(argument(args, '--apk')), inspect(argument(args, '--test-apk'))])
  if (app.packageName !== PACKAGE || testApk.packageName !== `${PACKAGE}.test` || app.certificate !== testApk.certificate)
    throw new Error('APK package or signing identities do not match')
  requirePtcDeathInstrumentation(await run(tools.aapt2, ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30000))
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass', app, testApk }, null, 2) + '\n'); return
  }
  if (!args.includes('--accept-force-stop')) throw new Error('Explicit --accept-force-stop is required')
  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15000), args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  if (parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15000)) && !args.includes('--allow-existing'))
    throw new Error('Existing App requires explicit --allow-existing authorization')
  for (const artifact of [app, testApk]) if (!/^Success\s*$/m.test(await device(['install', '-r', artifact.path])))
    throw new Error('Data-preserving APK update failed')
  const agentPids = async () => {
    try { return parsePids(await device(['shell', 'pidof', `${PACKAGE}:agent`], 15000)) }
    catch (error) { if (Number(error.code) === 1) return []; throw error }
  }
  const guestPids = async () => parseGuestProcesses(await device(['shell', 'ps', '-A', '-w', '-o', 'PID,ARGS'], 15000))
  const caseId = randomUUID()
  const instrument = phase => ['shell', 'am', 'instrument', '-w', '-r', '-e', 'suite', 'ptc-process-death',
    '-e', 'phase', phase, '-e', 'caseId', caseId]
  const child = spawn(adb, ['-s', serial, ...instrument('prepare'), RUNNER], { windowsHide: true })
  const preparation = ownPtcPreparationProcess(child)
  let stopIssued = false, completedReport, operationError
  try {
    let ready
    const deadline = Date.now() + 120000
    while (Date.now() < deadline) {
      const status = preparation.status()
      if (status.error) throw status.error
      if (status.ended) throw new Error(`PTC preparation exited before readiness: ${status.output.slice(-6000)}`)
      ready = parsePtcDeathReady(status.output, caseId)
      if (ready) break
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    if (!ready) throw new Error('PTC did not reach an unconfirmed real write')
    const [agents, guests, guest] = await Promise.all([agentPids(), guestPids(),
      device(['shell', 'dumpsys', 'activity', 'services', PACKAGE], 15000).then(text => parseRunGuestPid(text, ready.runId))])
    if (!agents.includes(ready.agentPid) || !guests.includes(guest)) throw new Error('Exact PTC Agent and isolated guest are not live')
    await device(['shell', 'am', 'force-stop', PACKAGE], 15000); stopIssued = true
    let stopped = false
    const stopDeadline = Date.now() + 10000
    while (Date.now() < stopDeadline) {
      if (!(await agentPids()).length && !(await guestPids()).length) { stopped = true; break }
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    if (!stopped) throw new Error('Both old PTC processes have not retired')
    const recovery = parsePtcDeathRecovery(await device([...instrument('recover'),
      '-e', 'processStopConfirmed', 'true', RUNNER], 150000), ready)
    completedReport = { result: 'pass', app, testApk, serial, agentBefore: agents,
      guestBefore: guests, exactGuestPid: guest, bothOldProcessesStopped: true, recovery }
  } catch (error) {
    operationError = error
    throw error
  } finally {
    const cleanupErrors = []
    if (!stopIssued) {
      try { await device(['shell', 'am', 'force-stop', PACKAGE], 15000) }
      catch (error) { cleanupErrors.push(new Error('Fixture stop is unconfirmed', { cause: error })) }
    }
    try { await preparation.dispose() } catch (error) { cleanupErrors.push(error) }
    if (cleanupErrors.length) throw new AggregateError(
      operationError ? [operationError, ...cleanupErrors] : cleanupErrors, 'PTC runner cleanup failed')
  }
  process.stdout.write(JSON.stringify({ ...completedReport, preparationProcessClosed: true }, null, 2) + '\n')
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1 })
}
