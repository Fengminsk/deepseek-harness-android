import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'
import { parseRunGuestPid } from './acceptance-native-workflow-process-death-device.mjs'
import { ownPtcPreparationProcess, requirePtcDeathInstrumentation } from './acceptance-ptc-process-death-device.mjs'
import { retireWorkflowProcesses } from './acceptance-native-workflow-device.mjs'
import { parseAcceptanceProcesses } from './device-screen-protection.mjs'
import { carrierEvidence, requireNodeCarrierReady } from './acceptance-carrier.mjs'
import { validateWorkflowDeathMarker, validateWorkflowDeadline } from './device-runtime-acceptance/workflow-lifecycle-evidence.mjs'
import { WORKFLOW_DEADLINE_CHECK, WORKFLOW_DEATH_CHECK } from './device-runtime-acceptance/workflow-checks.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.NativeRuntimeToolsAcceptanceInstrumentation`
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

/** Require the complete, exact-case ready frame emitted after real child activation and fsync. */
export function parseWorkflowDeathReady(output, caseId) {
  const matches = [...output.matchAll(/^INSTRUMENTATION_STATUS: ready=(.*)\r?\n/gm)]
  if (!matches.length) return null
  assert.equal(matches.length, 1, 'Duplicate workflow readiness marker')
  if (!/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m.test(output.slice(matches[0].index))) return null
  assert.ok(matches[0][1].length < 16384)
  return validateWorkflowDeathMarker(JSON.parse(matches[0][1]), caseId)
}

/** Keep framework lock/closure evidence separate from the wrapper's physical panel observations. */
export function parseWorkflowLifecycleResult(output, suite, ready) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const results = [...output.matchAll(/^INSTRUMENTATION_RESULT: result=(.*)\r?$/gm)]
  assert.ok(codes.length === 1 && codes[0][1] === '-1' && results.length === 1,
    `Workflow instrumentation did not complete: ${output.slice(-4000)}`)
  assert.ok(results[0][1].length < 128 * 1024)
  const result = JSON.parse(results[0][1]), carrier = carrierEvidence(output, 'service')
  assert.equal(result.foregroundCarrier, 'service')
  for (const key of ['deviceStateBefore', 'deviceStateReady', 'deviceStateAfter']) {
    assert.equal(carrier[key].interactive, false)
    assert.equal(carrier[key].keyguardLocked, true)
    assert.equal(carrier[key].deviceLocked, true)
  }
  assert.equal(result.passed, true); assert.equal(result.complete, true)
  assert.equal(result.reports?.length, 1)
  const report = result.reports[0]
  assert.equal(report.suite, suite); assert.equal(report.checks?.length, 1)
  const check = report.checks[0]
  assert.equal(check.status, 'passed')
  if (suite === 'workflow-deadline') {
    assert.equal(check.name, WORKFLOW_DEADLINE_CHECK); validateWorkflowDeadline(check)
  } else {
    assert.equal(suite, 'workflow-process-death'); assert.equal(check.name, WORKFLOW_DEATH_CHECK)
    validateWorkflowDeathMarker(check, ready.caseId)
    for (const [key, value] of Object.entries(ready)) assert.deepEqual(check[key], value)
    assert.equal(check.oldAgentPid, ready.agentPid)
    assert.ok(Number.isSafeInteger(check.newAgentPid) && check.newAgentPid > 0 && check.newAgentPid !== ready.agentPid)
    assert.match(check.currentLeaseId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    assert.notEqual(check.currentLeaseId, ready.processLeaseId)
    assert.equal(check.nativeState, 'INTERRUPTED_UNCONFIRMED')
    assert.equal(check.sessionState, 'interrupted-unconfirmed')
    for (const key of ['nativeOutputAbsent', 'oldLeaseStopped', 'childRetired', 'requiresReview',
      'unchangedParentLog', 'unchangedChildLog']) assert.equal(check[key], true, key)
    for (const key of ['replayedModelCalls', 'replayedCallbacks', 'newAdmissions']) assert.equal(check[key], 0, key)
  }
  return { ...check, ...carrier }
}

/** Execute selected lifecycle phases with joined host clients and confirmed device retirement. */
export async function runWorkflowLifecyclePhases(io, { suite = 'all', now = () => performance.now(), pause = delay } = {}) {
  assert.ok(['all', 'deadline', 'process-death'].includes(suite))
  const checks = [], retirements = []
  const retire = async () => { const value = await retireWorkflowProcesses(io.device, { now, pause }); retirements.push(value) }
  const instrument = (selected, extra = []) => ['shell', 'am', 'instrument', '-w', '-r', '-e', 'suite', selected,
    '-e', 'foregroundCarrier', 'service', ...extra, RUNNER]
  let preparation, phase = 'initial-retirement', operationError
  try {
    await retire()
    if (suite !== 'process-death') {
      phase = 'native-deadline'
      checks.push(parseWorkflowLifecycleResult(await io.device(instrument('workflow-deadline'), 360000), 'workflow-deadline'))
      await retire()
    }
    if (suite !== 'deadline') {
      const caseId = randomUUID()
      phase = 'death-prepare'
      preparation = io.start(instrument('workflow-process-death', ['-e', 'phase', 'prepare', '-e', 'caseId', caseId]))
      let ready
      const end = now() + 150000
      while (now() < end) {
        const status = preparation.status()
        if (status.error) throw status.error
        assert.equal(status.ended, false, `Preparation ended before the host stop: ${status.output.slice(-4000)}`)
        ready = parseWorkflowDeathReady(status.output, caseId)
        if (ready) break
        await pause(200)
      }
      assert.ok(ready, 'Workflow never reached its durable active child marker')
      requireNodeCarrierReady(preparation.status().output, 'service')
      const processes = parseAcceptanceProcesses(await io.device(['shell', 'ps', '-A', '-w', '-o', 'PID,ARGS'], 10000))
      const guestPid = parseRunGuestPid(await io.device(['shell', 'dumpsys', 'activity', 'services', PACKAGE], 10000), ready.runId)
      assert.ok(processes.some(row => row.pid === ready.agentPid && row.name === `${PACKAGE}:agent`), 'Old Agent is not live')
      assert.ok(processes.some(row => row.pid === guestPid && row.name.includes(':ptc_script')), 'Exact isolated workflow guest is not live')
      phase = 'death-retirement'
      await retire()
      await preparation.dispose()
      assert.equal(preparation.status().ended, true, 'Preparation ADB client did not close')
      preparation = undefined
      phase = 'death-recovery'
      const recovery = parseWorkflowLifecycleResult(await io.device(instrument('workflow-process-death',
        ['-e', 'phase', 'recover', '-e', 'caseId', caseId, '-e', 'processStopConfirmed', 'true']), 240000),
      'workflow-process-death', ready)
      checks.push({ ...recovery, exactGuestPid: guestPid, bothOldProcessesStopped: true, preparationProcessClosed: true })
    }
  } catch (error) { operationError = error }
  finally {
    const failures = []
    try { await retire() } catch (error) { failures.push(error) }
    try { await preparation?.dispose() } catch (error) { failures.push(error) }
    if (failures.length) operationError = new AggregateError(operationError ? [operationError, ...failures] : failures,
      'Workflow lifecycle retirement is unconfirmed')
  }
  if (operationError) throw Object.assign(operationError, { evidence: { suite, phase, checks, retirements, complete: false } })
  return { result: 'pass', suite, checks, retirements, complete: true }
}

function argument(args, flag, required = true) {
  const positions = args.flatMap((value, index) => value === flag ? [index] : [])
  assert.ok(positions.length <= 1, `Duplicate ${flag}`)
  if (!positions.length && !required) return undefined
  const value = args[positions[0] + 1]
  assert.ok(value && !value.startsWith('--'), `Missing ${flag}`)
  return value
}
async function run(binary, args, timeout = 120000) {
  const result = await exec(binary, args, { timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true })
  return result.stdout + result.stderr
}
/** This disruptive driver cannot use a foreground Activity or request an interactive device. */
export function requireWorkflowLifecycleCarrier(args) {
  assert.equal(argument(args, '--foreground-carrier', false) ?? 'service', 'service')
  return 'service'
}
async function main(args) {
  requireWorkflowLifecycleCarrier(args)
  const suite = argument(args, '--suite', false) ?? 'all'
  assert.ok(['all', 'deadline', 'process-death'].includes(suite), 'Choose suite all, deadline or process-death')
  const tools = await sdkTools()
  const inspect = async input => {
    const path = resolve(input), info = await stat(path), hash = createHash('sha256')
    assert.ok(path.endsWith('.apk') && info.isFile() && info.size > 0)
    for await (const part of createReadStream(path)) hash.update(part)
    return { path, bytes: info.size, sha256: hash.digest('hex'),
      ...parseBadging(await run(tools.aapt2, ['dump', 'badging', path], 30000)),
      certificate: parseCertificate(await run('java', ['-jar', tools.apksigner, 'verify', '--print-certs', path], 30000)) }
  }
  const [app, testApk] = await Promise.all([inspect(argument(args, '--apk')), inspect(argument(args, '--test-apk'))])
  assert.equal(app.packageName, PACKAGE); assert.equal(testApk.packageName, `${PACKAGE}.test`)
  assert.equal(app.certificate, testApk.certificate)
  requirePtcDeathInstrumentation(await run(tools.aapt2, ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30000))
  if (args.includes('--preflight-only')) { console.log(JSON.stringify({ result: 'preflight-pass', app, testApk })); return }
  assert.ok(args.includes('--accept-force-stop'), 'Explicit --accept-force-stop is required')
  const adb = argument(args, '--adb', false) ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15000), argument(args, '--serial', false))
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  if (parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15000)))
    assert.ok(args.includes('--allow-existing'), 'Existing App requires --allow-existing')
  for (const artifact of [app, testApk]) assert.match(await device(['install', '-r', artifact.path]), /^Success\s*$/m)
  const result = await runWorkflowLifecyclePhases({ device,
    start: command => ownPtcPreparationProcess(spawn(adb, ['-s', serial, ...command], { windowsHide: true })) },
  { suite })
  console.log(JSON.stringify({ ...result, app, testApk, serial, foregroundCarrier: 'service' }, null, 2))
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    console.error(JSON.stringify({ result: 'fail', error: String(error), evidence: error.evidence,
      causes: error instanceof AggregateError ? error.errors.map(value => String(value)).slice(0, 8) : [] }))
    process.exitCode = 1
  })
}
