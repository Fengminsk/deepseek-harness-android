import { createHash, randomUUID } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseBadging, parseCertificate, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const AGENT = `${PACKAGE}:agent`
const GUEST = `${PACKAGE}:ptc_script`
const RUNNER = `${PACKAGE}.test/${PACKAGE}.NativeWorkflowProcessDeathInstrumentation`
const PASSED = 'process-kill-interruption-no-replay-and-guarded-retirement'

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

export function requireProcessDeathInstrumentation(output) {
  const declarations = output.split(/^\s*E: instrumentation(?:\s|$).*$/m).slice(1)
  const matches = declarations.filter(block => {
    const name = /android:name[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const target = /android:targetPackage[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    const process = /android:targetProcesses[^\r\n]*="([^"]+)"/.exec(block)?.[1]
    return name === `${PACKAGE}.NativeWorkflowProcessDeathInstrumentation` &&
      target === PACKAGE && process === AGENT
  })
  if (matches.length !== 1) throw new Error('AndroidTest APK lacks the exact Agent-process death instrumentation')
}

export function parseReadyMarker(raw, runId) {
  const marker = JSON.parse(raw)
  if (Object.keys(marker).sort().join(',') !== 'agentPid,childId,runId,schema' ||
      marker.schema !== 1 || marker.runId !== runId ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(marker.childId) ||
      !Number.isSafeInteger(marker.agentPid) || marker.agentPid <= 0) {
    throw new Error('The synced process-death marker is invalid or belongs to another run')
  }
  return marker
}

export function parseReadyStatus(output, runId) {
  const values = [...output.matchAll(/^INSTRUMENTATION_STATUS: ready=(.*)\r?\n/gm)]
  if (!values.length) return null
  if (values.length !== 1) throw new Error('Duplicate process-death ready status')
  if (!/^INSTRUMENTATION_STATUS_CODE: 1\s*$/m.test(output.slice(values[0].index))) return null
  return parseReadyMarker(values[0][1].trim(), runId)
}

export function parsePids(output) {
  const trimmed = output.trim()
  if (!trimmed) return []
  const values = trimmed.split(/\s+/).map(Number)
  if (values.some(value => !Number.isSafeInteger(value) || value <= 0) ||
      new Set(values).size !== values.length) throw new Error(`Invalid pidof result: ${output}`)
  return values
}

export function parseGuestProcesses(output) {
  const prefix = `${GUEST}:${PACKAGE}.IsolatedScriptService:script_`
  const lines = output.trim().split(/\r?\n/)
  if (!/^\s*PID\s+(?:ARGS|CMD|COMMAND)\s*$/.test(lines.shift() ?? '')) {
    throw new Error('Guest process listing is missing its full-arguments header')
  }
  const matches = []
  for (const line of lines) {
    const match = /^\s*([1-9][0-9]*)\s+(.*)$/.exec(line)
    if (!match) throw new Error('Malformed guest process listing')
    const name = match[2].trim()
    if (!name.startsWith(prefix)) continue
    // Android truncates argv[0] even with ps -w. ActivityManager's full
    // service identity below binds an exact run to these independently live PIDs.
    if (!/^[0-9a-f]{8,32}$/.test(name.slice(prefix.length))) {
      throw new Error('Isolated script process identity is invalid')
    }
    matches.push(Number(match[1]))
  }
  return parsePids(matches.join(' '))
}

export function parseRunGuestPid(output, runId) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(runId)) {
    throw new Error('Guest service lookup requires a canonical run UUID')
  }
  const expected = `${GUEST}:${PACKAGE}.IsolatedScriptService:script_${runId.replaceAll('-', '')}`
  const blocks = output.split(/^\s*\* ServiceRecord\{/m).slice(1)
  const matching = blocks.filter(block => block.split(/\r?\n/).some(line => line.trim() === `processName=${expected}`))
  if (matching.length !== 1) throw new Error('Missing or ambiguous exact workflow guest service')
  const apps = [...matching[0].matchAll(/^\s*app=ProcessRecord\{[^\s]+ ([1-9][0-9]*):([^\s/]+)\/[^}]+\}\s*$/gm)]
  if (apps.length !== 1 || apps[0][2] !== expected) throw new Error('Workflow guest service has no exact process owner')
  return parsePids(apps[0][1])[0]
}

export function parseProcessDeathRecovery(output, runId, ready) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const field = name => {
    const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${name}=(.*)$`, 'gm'))]
    if (matches.length !== 1) throw new Error(`Missing or duplicate ${name} recovery result`)
    return matches[0][1].trim()
  }
  const oldPid = Number(field('oldAgentPid'))
  const newPid = Number(field('newAgentPid'))
  if (codes.length !== 1 || codes[0][1] !== '-1' || field('passed') !== PASSED ||
      field('oldRunId') !== runId || field('oldChildId') !== ready.childId ||
      oldPid !== ready.agentPid || !Number.isSafeInteger(newPid) || newPid <= 0 ||
      newPid === oldPid) {
    throw new Error(`Workflow process-death recovery failed: ${output.slice(-4000)}`)
  }
  return { passed: field('passed'), oldAgentPid: oldPid, newAgentPid: newPid }
}

function exactResult(output, name) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\s*$/gm)]
  const values = [...output.matchAll(new RegExp(`^INSTRUMENTATION_RESULT: ${name}=(.*)$`, 'gm'))]
  if (codes.length !== 1 || codes[0][1] !== '-1' || values.length !== 1) {
    throw new Error(`Unconfirmed legacy ${name}: ${output.slice(-2000)}`)
  }
  return values[0][1].trim()
}

export function parseLegacyInspection(output, runId) {
  const entries = JSON.parse(exactResult(output, 'legacy'))
  const agentPid = Number(exactResult(output, 'agentPid'))
  if (!Array.isArray(entries) || !Number.isSafeInteger(agentPid) || agentPid <= 0) {
    throw new Error('Invalid legacy inspection')
  }
  const matches = entries.filter(entry => entry.runId === runId)
  if (matches.length !== 1 || !Array.isArray(matches[0].childIds) || !matches[0].childIds.length ||
      matches[0].childIds.some(id => typeof id !== 'string' || !id) ||
      new Set(matches[0].childIds).size !== matches[0].childIds.length) {
    throw new Error('Exact legacy run is absent or has no unretired children')
  }
  return { agentPid, childIds: matches[0].childIds }
}

export function parseLegacyRetirement(output, runId, count) {
  if (exactResult(output, 'passed') !== 'explicit-legacy-retirement' ||
      exactResult(output, 'oldRunId') !== runId || Number(exactResult(output, 'retiredCount')) !== count) {
    throw new Error('Legacy retirement did not confirm the exact pending children')
  }
  return { audit: exactResult(output, 'audit'), retiredCount: count }
}

function startPreparation(adb, serial, runId) {
  const child = spawn(adb, ['-s', serial, 'shell', 'am', 'instrument', '-w', '-r',
    '-e', 'phase', 'prepare', '-e', 'runId', runId, RUNNER], { windowsHide: true })
  let output = ''
  let error
  let ended = false
  child.stdout.on('data', chunk => { output = (output + chunk).slice(-4000) })
  child.stderr.on('data', chunk => { output = (output + chunk).slice(-4000) })
  child.once('error', failure => { error = failure; ended = true })
  child.once('close', () => { ended = true })
  return { child, status: () => ({ ended, error, output }) }
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
  requireProcessDeathInstrumentation(await run(tools.aapt2,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30_000))
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass',
      app: { ...app, ...appIdentity }, testApk: { ...testApk, ...testIdentity } }, null, 2) + '\n')
    return
  }
  if (!args.includes('--accept-force-stop')) {
    throw new Error('This test deliberately force-stops the App; pass --accept-force-stop to opt in')
  }
  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15_000),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  const installed = parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15_000))
  if (installed && !args.includes('--allow-existing')) {
    throw new Error('App already installed; --allow-existing must explicitly authorize stopping that installation')
  }
  for (const artifact of [app, testApk]) {
    const result = await device(['install', '-r', artifact.path], 120_000)
    if (!/^Success\s*$/m.test(result)) throw new Error(`ADB install failed: ${result}`)
  }
  const pids = async processName => {
    if (processName === GUEST) {
      return parseGuestProcesses(await device(['shell', 'ps', '-A', '-w', '-o', 'PID,ARGS'], 15_000))
    }
    try { return parsePids(await device(['shell', 'pidof', processName], 15_000)) }
    catch (error) { if (Number(error.code) === 1) return []; throw error }
  }
  if (args.includes('--retire-legacy-run')) {
    const runId = argument(args, '--retire-legacy-run')
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(runId)) {
      throw new Error('Legacy retirement requires one canonical run UUID')
    }
    const inspected = parseLegacyInspection(await device(['shell', 'am', 'instrument', '-w', '-r',
      '-e', 'phase', 'inspect-legacy', RUNNER], 30_000), runId)
    const stoppedAgentPids = [...new Set([inspected.agentPid, ...await pids(AGENT)])]
    const guestBefore = await pids(GUEST)
    await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
    if ((await pids(AGENT)).length || (await pids(GUEST)).length) {
      throw new Error('Legacy owner process stop was not confirmed; nothing was retired')
    }
    const output = await device(['shell', 'am', 'instrument', '-w', '-r',
      '-e', 'phase', 'retire-legacy', '-e', 'runId', runId,
      '-e', 'processStopConfirmed', 'true', '-e', 'stoppedAgentPids', stoppedAgentPids.join(','), RUNNER], 30_000)
    const retired = parseLegacyRetirement(output, runId, inspected.childIds.length)
    process.stdout.write(JSON.stringify({ result: 'legacy-retired', serial, runId,
      childIds: inspected.childIds, stoppedAgentPids, guestBefore, ...retired,
      app: { ...app, ...appIdentity }, testApk: { ...testApk, ...testIdentity } }, null, 2) + '\n')
    return
  }
  await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
  const runId = randomUUID()
  const preparation = startPreparation(adb, serial, runId)
  const deadline = Date.now() + 25_000
  let ready
  let stopIssued = false
  try {
    while (Date.now() < deadline) {
      const status = preparation.status()
      if (status.error) throw status.error
      if (status.ended) throw new Error(`Workflow preparation ended before process stop: ${status.output}`)
      ready = parseReadyStatus(status.output, runId)
      if (ready) break
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    if (!ready) throw new Error('Workflow did not publish a durable pending-child marker')
    const [agentBefore, guestBefore, guestPid] = await Promise.all([pids(AGENT), pids(GUEST),
      device(['shell', 'dumpsys', 'activity', 'services', PACKAGE], 15_000)
        .then(output => parseRunGuestPid(output, runId))])
    if (!agentBefore.includes(ready.agentPid) || !guestBefore.includes(guestPid)) {
      throw new Error('The pending workflow was not live in both Agent and isolated guest processes')
    }
    await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
    stopIssued = true
    let stopped = false
    const stopDeadline = Date.now() + 10_000
    while (Date.now() < stopDeadline) {
      const [agentAfter, guestAfter] = await Promise.all([pids(AGENT), pids(GUEST)])
      if (agentAfter.length === 0 && guestAfter.length === 0) { stopped = true; break }
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    if (!stopped) throw new Error('Android did not confirm both old process names stopped')
    const output = await device(['shell', 'am', 'instrument', '-w', '-r',
      '-e', 'phase', 'recover', '-e', 'runId', runId,
      '-e', 'processStopConfirmed', 'true', RUNNER], 90_000)
    const recovery = parseProcessDeathRecovery(output, runId, ready)
    process.stdout.write(JSON.stringify({ result: 'pass', serial, app: { ...app, ...appIdentity },
      testApk: { ...testApk, ...testIdentity }, runId, childId: ready.childId,
      agentBefore, guestBefore, ...recovery }, null, 2) + '\n')
  } finally {
    // The opt-in run must not leave a live fixture behind after a failed poll.
    if (!stopIssued) {
      try { await device(['shell', 'am', 'force-stop', PACKAGE], 15_000) }
      catch { /* Preserve the original failure; the device may have disconnected. */ }
    }
    preparation.child.kill()
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  })
}
