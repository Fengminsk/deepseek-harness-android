import { createHash, randomUUID } from 'node:crypto'
import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { setTimeout as delay } from 'node:timers/promises'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'
import { parseAcceptanceProcesses } from './device-screen-protection.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.NativeWorkflowAcceptanceInstrumentation`
const REQUIRED = [
  'isolated-callbacks-and-durable-result',
  'isolated-guest-reported-error-is-durable-failure',
  'isolated-malformed-dsl-outcome-needs-review',
  'isolated-child-reservation-result-and-retirement',
  'isolated-route-denial-requires-confirmed-retirement',
  'admitted-workflow-pre-execution-cancel',
  'bounded-extended-workflow-and-upper-limit',
  'in-flight-child-cancel-retirement-and-cold-owner',
]
const NEGATIVE_PHASES = ['bad-reservation', 'rpc-failure', 'close-failure']
const PHASES = ['baseline', ...NEGATIVE_PHASES, 'cold-recovery']
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function argument(args, flag) {
  const index = args.indexOf(flag)
  if (index < 0 || index + 1 >= args.length || args[index + 1].startsWith('--')) {
    throw new Error(`Missing ${flag}`)
  }
  return args[index + 1]
}

async function run(binary, args, timeout = 120_000) {
  const { stdout, stderr } = await exec(binary, args, {
    timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true,
  })
  return `${stdout}${stderr}`
}

async function fingerprint(input) {
  const path = resolve(input)
  const info = await stat(path)
  if (!path.endsWith('.apk') || !info.isFile() || info.size < 1) throw new Error(`Invalid APK: ${path}`)
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return { path, bytes: info.size, sha256: hash.digest('hex') }
}

export function requireWorkflowInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter(block => {
    const name = /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const target = /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const process = /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    return name === `${PACKAGE}.NativeWorkflowAcceptanceInstrumentation` &&
      target === PACKAGE && process === `${PACKAGE}:agent`
  })
  if (matches.length !== 1) throw new Error('AndroidTest APK lacks the exact Agent-process workflow instrumentation')
}

export function parseWorkflowResult(output, phase = 'baseline') {
  if (!PHASES.includes(phase)) throw new Error('Unknown workflow acceptance phase')
  const required = phase === 'baseline' ? REQUIRED : [phase === 'cold-recovery'
    ? 'isolated-route-denial-cold-recovery-retains-unknown'
    : `isolated-route-denial-${phase}-remains-unconfirmed`]
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const field = name => {
    const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${name}=(.*)$`, 'gm'))]
    if (matches.length !== 1) throw new Error(`Missing or duplicate ${name} workflow result`)
    return matches[0][1].trim()
  }
  const passed = field('passed').split(',')
  const passedCount = Number(field('passedCount'))
  const failedCount = Number(field('failedCount'))
  if (codes.length !== 1 || codes[0][1] !== '-1' || field('failed') !== '' ||
      failedCount !== 0 || passedCount !== required.length || passed.length !== required.length ||
      new Set(passed).size !== required.length ||
      !Number.isSafeInteger(passedCount) || required.some(name => !passed.includes(name))) {
    throw new Error(`Native workflow device acceptance failed: ${output.slice(-4000)}`)
  }
  const pid = Number(field('pid')), leaseId = field('leaseId')
  if (field('phase') !== phase || field('processName') !== `${PACKAGE}:agent`
    || !Number.isSafeInteger(pid) || pid < 1 || !UUID.test(leaseId)) {
    throw new Error('Workflow phase process identity is invalid')
  }
  const result = { phase, pid, leaseId, passed }
  const json = name => {
    const value = field(name)
    if (value.length > 8192) throw new Error('Workflow observation exceeds its bound')
    return JSON.parse(value)
  }
  if (NEGATIVE_PHASES.includes(phase)) {
    result.runId = field('runId')
    const observed = json('negativeObservation')
    if (!UUID.test(result.runId) || observed.runId !== result.runId
      || observed.state !== 'INTERRUPTED_UNCONFIRMED' || observed.requiresReview !== true
      || observed.releaseAcknowledged !== false || observed.children !== 2
      || observed.allChildrenRetired !== (phase !== 'close-failure')) {
      throw new Error('Negative workflow phase lost its unconfirmed receipt or retirement facts')
    }
    result.observation = observed
  } else if (phase === 'cold-recovery') {
    const recoveries = json('recoveries')
    if (!Array.isArray(recoveries) || recoveries.length !== 3
      || new Set(recoveries.map(row => row?.runId)).size !== 3 || recoveries.some(row => !UUID.test(row?.runId)
        || !UUID.test(row.previousLeaseId) || row.previousLeaseId === leaseId
        || row.state !== 'INTERRUPTED_UNCONFIRMED' || row.previousProcess !== 'STOPPED'
        || row.children !== 2 || row.allChildrenRetired !== true)) {
      throw new Error('Workflow cold recovery lacks retained unknown receipts and stopped-process proof')
    }
    result.recoveries = recoveries
  }
  return result
}

/** Force-stop commands are requests; two complete empty process listings confirm retirement. */
export async function retireWorkflowProcesses(device, { now = () => performance.now(), pause = delay } = {}) {
  const requests = await Promise.allSettled([PACKAGE, `${PACKAGE}.test`]
    .map(name => device(['shell', 'am', 'force-stop', name], 8000)))
  const failed = requests.filter(result => result.status === 'rejected').map(result => result.reason)
  const observations = [], end = now() + 15_000
  let empty = 0, samples = 0
  while (now() < end) {
    const processes = parseAcceptanceProcesses(await device(['shell', 'ps', '-A', '-w', '-o', 'PID,ARGS'],
      Math.max(1, Math.min(5000, end - now()))))
    if (processes.length > 64 || ++samples > 80) throw new Error('Workflow retirement observation limit reached')
    observations.push(processes)
    if (observations.length > 8) observations.shift()
    empty = processes.length === 0 ? empty + 1 : 0
    if (empty === 2) {
      if (failed.length) throw new AggregateError(failed, 'Workflow force-stop request failed; retirement not accepted')
      return { confirmed: true, emptySamples: 2, samples, observations }
    }
    await pause(Math.min(200, Math.max(1, end - now())))
  }
  throw Object.assign(new Error('Workflow App/test/guest processes did not retire'), { observations })
}

/** Run each unknown-outcome case in a fresh process; preserve every receipt for cold inspection. */
export async function runWorkflowPhases(device, retirementOptions) {
  const phases = [], retired = []
  let failure, activePhase = null
  try {
    retired.push(await retireWorkflowProcesses(device, retirementOptions))
    for (const phase of PHASES) {
      activePhase = phase
      const runId = NEGATIVE_PHASES.includes(phase) ? randomUUID() : null
      const command = ['shell', 'am', 'instrument', '-w', '-r', '-e', 'phase', phase]
      if (runId) command.push('-e', 'runId', runId)
      if (phase === 'cold-recovery') command.push('-e', 'priorRunIds',
        phases.filter(row => row.runId).map(row => row.runId).join(','))
      command.push(RUNNER)
      const result = parseWorkflowResult(await device(command, phase === 'baseline' ? 150_000 : 30_000), phase)
      if (runId && result.runId !== runId) throw new Error('Workflow negative phase changed its requested run identity')
      if (phases.some(row => row.leaseId === result.leaseId)) throw new Error('Workflow phase reused a live process lease')
      if (result.recoveries) for (const observed of result.recoveries) {
        const prior = phases.find(row => row.runId === observed.runId)
        if (!prior || prior.leaseId !== observed.previousLeaseId) throw new Error('Cold recovery changed a prior workflow owner')
      }
      phases.push(result)
      retired.push(await retireWorkflowProcesses(device, retirementOptions))
    }
  } catch (error) { failure = error }
  if (failure) {
    // No subsequent phase can run after an unconfirmed stop. Cleanup preserves
    // receipts and uses no wake, unlock, clear-data or synthetic retirement API.
    try { retired.push(await retireWorkflowProcesses(device, retirementOptions)) }
    catch (cleanup) { failure = new AggregateError([failure, cleanup], 'Workflow phase or final retirement failed') }
    throw Object.assign(failure, { phaseEvidence: { phases, retired, activePhase, complete: false,
      failure: String(failure).slice(0, 4000),
      causes: failure instanceof AggregateError ? failure.errors.slice(0, 4).map(error => String(error).slice(0, 1000)) : [],
    } })
  }
  return { phases, retired, complete: true, passed: phases.flatMap(row => row.passed) }
}

async function main(args) {
  const [app, testApk] = await Promise.all([
    fingerprint(argument(args, '--apk')), fingerprint(argument(args, '--test-apk')),
  ])
  if (app.path === testApk.path) throw new Error('App and AndroidTest APK must differ')
  const tools = await sdkTools()
  const inspect = async artifact => ({
    ...parseBadging(await run(tools.aapt2, ['dump', 'badging', artifact.path], 30_000)),
    certificate: parseCertificate(await run('java', ['-jar', tools.apksigner,
      'verify', '--print-certs', artifact.path], 30_000)),
  })
  const [appIdentity, testIdentity] = await Promise.all([inspect(app), inspect(testApk)])
  if (appIdentity.packageName !== PACKAGE || testIdentity.packageName !== `${PACKAGE}.test` ||
      appIdentity.certificate !== testIdentity.certificate) {
    throw new Error('App and AndroidTest APK package or signing identity differs')
  }
  requireWorkflowInstrumentation(await run(tools.aapt2,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30_000))
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass',
      app: { ...app, ...appIdentity }, testApk: { ...testApk, ...testIdentity } }, null, 2) + '\n')
    return
  }
  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15_000),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  const existed = parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15_000))
  if (existed && !args.includes('--allow-existing')) {
    throw new Error('App already installed; pass --allow-existing only after authorizing this test on that installation')
  }
  for (const artifact of [app, testApk]) {
    const installed = await device(['install', '-r', artifact.path], 120_000)
    if (!/^Success\s*$/m.test(installed)) throw new Error(`ADB install failed: ${installed}`)
  }
  const result = await runWorkflowPhases(device)
  process.stdout.write(JSON.stringify({ result: 'pass', serial, app: { ...app, ...appIdentity },
    testApk: { ...testApk, ...testIdentity }, ...result }, null, 2) + '\n')
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`)
    if (error.phaseEvidence) process.stderr.write(JSON.stringify(error.phaseEvidence, null, 2) + '\n')
    process.exitCode = 1
  })
}
