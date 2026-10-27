import { randomBytes } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { sdkTools, connectedDevice } from './acceptance-upgrade-device.mjs'
const exec = promisify(execFile)
const PACKAGE = 'com.minnnng.dsh_android'
const args = process.argv.slice(2)
if (!args.includes('--accept-network-toggle-and-lock')) throw new Error('Explicit --accept-network-toggle-and-lock is required')
const tools = await sdkTools()
const run = async argv => (await exec(tools.adb, argv, { timeout: 30000, maxBuffer: 2 * 1024 * 1024, windowsHide: true })).stdout
const index = args.indexOf('--serial')
const serial = connectedDevice(await run(['devices']), index < 0 ? undefined : args[index + 1])
const adb = argv => run(['-s', serial, ...argv])
const wifi = (await adb(['shell', 'settings', 'get', 'global', 'wifi_on'])).trim()
const data = (await adb(['shell', 'settings', 'get', 'global', 'mobile_data'])).trim()
const power = await adb(['shell', 'dumpsys', 'power'])
const awake = /mWakefulness=Awake/.test(power)
if (!['0', '1'].includes(wifi) || !['0', '1'].includes(data) || (!awake && !/mWakefulness=(Asleep|Dozing)/.test(power))) {
  throw new Error('Original network/display state could not be read precisely; no settings changed')
}
if (wifi === '0' && data === '0') throw new Error('No original network enabled; restore acceptance requires an initial connection')
const token = randomBytes(16).toString('hex')
const child = spawn(tools.adb, ['-s', serial, 'shell', 'am', 'instrument', '-w', '-r', '-e', 'token', token,
  `${PACKAGE}.test/${PACKAGE}.AgentServiceRecoveryInstrumentation`], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
let output = '', ended = false, childError = null
child.stdout.on('data', bytes => { output += bytes })
child.stderr.on('data', bytes => { output += bytes })
child.on('error', error => { childError = error })
child.on('close', () => { ended = true })
const parse = (field, after = 0) => {
  const matches = [...output.slice(after).matchAll(new RegExp(`^INSTRUMENTATION_STATUS: ${field}=(.*)\\r?\\n`, 'gm'))]
  return matches.length ? JSON.parse(matches.at(-1)[1]) : null
}
async function wait(predicate, millis, label) {
  const deadline = Date.now() + millis
  while (Date.now() < deadline) {
    if (childError) throw childError
    const value = predicate()
    if (value) return value
    if (ended) throw new Error(`Service recovery ended before ${label}: ${output.slice(-8000)}`)
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  throw new Error(`Timed out waiting for ${label}: ${output.slice(-8000)}`)
}
const broadcast = stage => adb(['shell', 'am', 'broadcast', '-a', `${PACKAGE}.acceptance.${token}`, '-p', PACKAGE, '--es', 'stage', stage])
async function observeUntil(predicate, label) {
  const deadline = Date.now() + 30000
  while (Date.now() < deadline) {
    const cut = output.length
    await broadcast('observe')
    const state = await wait(() => parse('observation', cut), 15000, `${label} observation`)
    if (predicate(state)) return state
    await new Promise(resolve => setTimeout(resolve, 300))
  }
  throw new Error(`Device did not reach ${label}`)
}
let changed = false
try {
  const ready = await wait(() => parse('ready'), 150000, 'production AgentService ready')
  if (ready.token !== token) throw new Error('Wrong recovery fixture token')
  const agentPid = (await adb(['shell', 'pidof', `${PACKAGE}:agent`])).trim()
  const online = await observeUntil(state => state.validatedNetworks > 0, 'initial validated network')
  changed = true
  await adb(['shell', 'svc', 'wifi', 'disable'])
  await adb(['shell', 'svc', 'data', 'disable'])
  await adb(['shell', 'input', 'keyevent', '223'])
  await observeUntil(state => state.validatedNetworks === 0 && state.locked && !state.interactive, 'locked offline state')
  const offlineCut = output.length
  await broadcast('offline')
  const offline = await wait(() => parse('checkpoint', offlineCut), 20000, 'offline Session read')
  if ((await adb(['shell', 'pidof', `${PACKAGE}:agent`])).trim() !== agentPid) throw new Error('AgentService process changed while offline')
  await adb(['shell', 'svc', 'wifi', wifi === '1' ? 'enable' : 'disable'])
  await adb(['shell', 'svc', 'data', data === '1' ? 'enable' : 'disable'])
  if (awake) await adb(['shell', 'input', 'keyevent', '224'])
  await observeUntil(state => state.validatedNetworks > 0, 'restored validated network')
  await broadcast('restored')
  await wait(() => /^INSTRUMENTATION_CODE: -?\d+\s*$/m.test(output), 30000, 'restored result')
  if (!/^INSTRUMENTATION_CODE: -1\s*$/m.test(output) || !/^INSTRUMENTATION_RESULT: passed=true\s*$/m.test(output)) {
    throw new Error(`Production service recovery failed: ${output.slice(-8000)}`)
  }
  const match = /^INSTRUMENTATION_RESULT: result=(.*)$/m.exec(output)
  const restored = JSON.parse(match[1])
  console.log(JSON.stringify({ result: 'pass', serial, token, agentPid, original: { wifi, data, awake },
    online, offline, restored, modelRequestRetryTested: false, activeAgentTaskSurvivalTested: false,
    note: 'The real production service and a dedicated Session survived lock/offline/restore; no paid model call was made.' }, null, 2))
} finally {
  const restoreFailures = []
  if (changed) {
    for (const command of [['shell', 'svc', 'wifi', wifi === '1' ? 'enable' : 'disable'],
      ['shell', 'svc', 'data', data === '1' ? 'enable' : 'disable'],
      ['shell', 'input', 'keyevent', awake ? '224' : '223']]) {
      try { await adb(command) } catch (error) { restoreFailures.push(error.message) }
    }
    try {
      const deadline = Date.now() + 15000
      let restored = false
      while (Date.now() < deadline) {
        restored = (await adb(['shell', 'settings', 'get', 'global', 'wifi_on'])).trim() === wifi &&
          (await adb(['shell', 'settings', 'get', 'global', 'mobile_data'])).trim() === data
        if (restored) break
        await new Promise(resolve => setTimeout(resolve, 200))
      }
      if (!restored) restoreFailures.push('Original network flags were not restored')
    } catch (error) { restoreFailures.push(error.message) }
  }
  if (!ended) {
    if (!/^INSTRUMENTATION_RESULT: passed=true\s*$/m.test(output)) {
      try { await adb(['shell', 'am', 'force-stop', PACKAGE]) }
      catch (error) { restoreFailures.push(`Acceptance fixture stop failed: ${error.message}`) }
    }
    child.kill()
  }
  if (restoreFailures.length) throw new Error(`Recovery cleanup needs attention: ${restoreFailures.join('; ')}`)
}
