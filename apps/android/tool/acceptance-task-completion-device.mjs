import { createHash, randomBytes } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { connectedDevice, parseAgentPids, parseBadging, parseCertificate,
  parseHoldStatus, parseInstalledPath, sdkTools } from './acceptance-upgrade-device.mjs'

const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const RUNNER = `${PACKAGE}.test/${PACKAGE}.TaskCompletionCrashInstrumentation`
const TOKEN = /^[0-9a-f]{32}$/

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
    throw new Error(`Android ${phase} completion acceptance failed: ${output.slice(-4000)}`)
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

function startHold(adb, serial, token) {
  const child = spawn(adb, ['-s', serial, 'shell', 'am', 'instrument', '-w', '-r',
    '-e', 'phase', 'hold', '-e', 'token', token, RUNNER], {
    windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  })
  let output = '', closed = false, settled = false
  let resolveDone, resolveReady, rejectReady
  const done = new Promise(resolve => { resolveDone = resolve })
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const timeout = setTimeout(() => rejectReady(new Error('Committed completion hold did not become ready')), 20_000)
  const accept = chunk => {
    output += chunk.toString('utf8')
    if (output.length > 2 * 1024 * 1024) {
      clearTimeout(timeout)
      rejectReady(new Error('Completion instrumentation output exceeded 2 MiB'))
      child.kill()
      return
    }
    if (settled) return
    try {
      const pid = parseCommittedHold(output, token)
      if (pid !== null) { settled = true; clearTimeout(timeout); resolveReady(pid) }
    } catch (error) { settled = true; clearTimeout(timeout); rejectReady(error) }
  }
  child.stdout.on('data', accept)
  child.stderr.on('data', accept)
  child.on('error', error => { clearTimeout(timeout); rejectReady(error) })
  child.on('close', (code, signal) => {
    closed = true
    clearTimeout(timeout)
    rejectReady(new Error(`Completion hold exited before force-stop: ${output.slice(-1200)}`))
    resolveDone({ code, signal, output })
  })
  return { ready, done, get closed() { return closed }, stopClient: () => child.kill() }
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
  requireTaskCompletionInstrumentation(await run(tools.aapt2,
    ['dump', 'xmltree', '--file', 'AndroidManifest.xml', testApk.path], 30_000))
  if (args.includes('--preflight-only')) {
    process.stdout.write(JSON.stringify({ result: 'preflight-pass', app: { ...app, ...appIdentity },
      testApk: { ...testApk, ...testIdentity } }, null, 2) + '\n')
    return
  }

  const adb = args.includes('--adb') ? resolve(argument(args, '--adb')) : tools.adb
  const serial = connectedDevice(await run(adb, ['devices'], 15_000),
    args.includes('--serial') ? argument(args, '--serial') : undefined)
  const device = (command, timeout) => run(adb, ['-s', serial, ...command], timeout)
  const installed = parseInstalledPath(await device(['shell', 'pm', 'path', PACKAGE], 15_000))
  if (installed && !args.includes('--allow-existing')) {
    throw new Error('App already installed; --allow-existing is required before interrupting its Agent process')
  }
  for (const artifact of [app, testApk]) {
    const output = await device(['install', '-r', artifact.path], 180_000)
    if (!/^Success\s*$/m.test(output)) throw new Error(`ADB install failed: ${output.slice(-1200)}`)
  }
  const token = randomBytes(16).toString('hex')
  process.stderr.write(`Completion acceptance token=${token}; a failed run may retain synthetic receipts.\n`)
  const phase = async (name, previousPid) => parseTaskCompletionPhase(
    await device(['shell', 'am', 'instrument', '-w', '-r', '-e', 'phase', name,
      '-e', 'token', token, RUNNER], 30_000), name, token, previousPid)
  const pids = async () => {
    try { return parseAgentPids(await device(['shell', 'pidof', `${PACKAGE}:agent`], 15_000)) }
    catch (error) {
      if (error.code === 1 && !error.stdout?.trim() && !error.stderr?.trim()) return []
      throw error
    }
  }
  const hold = startHold(adb, serial, token)
  let heldPid, forceStopped = false
  try {
    heldPid = await hold.ready
    if (hold.closed || !(await pids()).includes(heldPid)) {
      throw new Error('Committed completion Agent process is not alive')
    }
    await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
    forceStopped = true
    if ((await pids()).length !== 0) throw new Error('Agent process remained after force-stop')
    let timer
    const terminal = await Promise.race([hold.done, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Agent hold did not exit after force-stop')), 20_000)
    })]).finally(() => clearTimeout(timer))
    if (/^INSTRUMENTATION_RESULT: passed=true$/m.test(terminal.output)) {
      throw new Error('Held Agent completed normally instead of being killed')
    }
  } finally {
    if (!hold.closed) {
      if (!forceStopped) await device(['shell', 'am', 'force-stop', PACKAGE], 15_000)
      hold.stopClient()
    }
  }
  const verified = await phase('verify', heldPid)
  const cleaned = await phase('cleanup')
  process.stdout.write(JSON.stringify({ result: 'pass', serial, app: { ...app, ...appIdentity },
    testApk: { ...testApk, ...testIdentity }, heldPid, verified, cleaned,
    committedReceiptRecoveredAfterForceStop: true, invalidReceiptSuppressed: true,
    realAgentTaskReplayTested: false }, null, 2) + '\n')
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  })
}
