import { parseAcceptanceProcesses, parseNonInteractivePowerState } from './device-screen-protection.mjs'

const PACKAGE = 'com.minnnng.dsh_android'
const check = (ok, message) => { if (!ok) throw new Error(message) }
const BUDGETS = { ready: 150000, stage: 30000, observation: 15000, restore: 15000, retirement: 20000 }

/** Inspect the scoped keyguard delegate, never an unrelated showing flag. */
export function parseRecoveryKeyguard(text) {
  const lines = text.split(/\r?\n/)
  const headers = lines.flatMap((line, i) => /^\s*KeyguardServiceDelegate\s*$/.test(line) ? [i] : [])
  if (headers.length !== 1) return false
  const start = headers[0], indent = lines[start].search(/\S/), fields = new Map()
  for (const line of lines.slice(start + 1)) {
    if (!line.trim()) continue
    if (line.search(/\S/) <= indent) break
    const pair = /^\s*(showing|inputRestricted|occluded|systemReady)=(.*?)\s*$/.exec(line)
    if (pair) {
      if (fields.has(pair[1]) || !['true', 'false'].includes(pair[2])) return false
      fields.set(pair[1], pair[2])
    }
  }
  return fields.get('showing') === 'true' && fields.get('inputRestricted') === 'true' &&
    fields.get('occluded') === 'false' && fields.get('systemReady') === 'true'
}

function jsonField(output, category, name) {
  const matches = [...output.matchAll(new RegExp(`^INSTRUMENTATION_${category}: ${name}=(.*)\\r?\\n`, 'gm'))]
  check(matches.length <= 1, `Duplicate instrumentation ${name}`)
  return matches.length ? JSON.parse(matches[0][1]) : null
}

function validateReady(value, token) {
  check(value && value.token === token && value.sessionId === `android-recovery-${token}` &&
    typeof value.generation === 'string' && value.generation.length > 0 && value.generation.length <= 128 &&
    /^[0-9a-f]{64}$/.test(value.eventsSha256) && Number.isSafeInteger(value.eventCount) && value.eventCount > 0,
  'Recovery ready identity or Session evidence is invalid')
  return value
}

function validateCheckpoint(value, ready, stage) {
  check(value && value.stage === stage && ['generation', 'sessionId', 'eventsSha256', 'eventCount']
    .every(key => value[key] === ready[key]) && value.interactive === false && value.locked === true,
  'Recovery checkpoint changed Session, generation or locked state')
  validateRecoveryNetworks(value.networkEvidence)
  return value
}

/** Recompute native counts from anonymous capability facts; never whitelist just Wi-Fi/cellular. */
export function validateRecoveryNetworks(value) {
  check(value?.schema === 2 && Array.isArray(value.networks) && value.networks.length <= 64,
    'Recovery network evidence is missing or has an unsupported schema')
  const handles = new Set(), defaults = []
  const counts = { validatedNetworks: 0, validatedInternetNetworks: 0, validatedVpnInternetNetworks: 0,
    usableUnderlyingInternetNetworks: 0, unvalidatedUnderlyingInternetNetworks: 0, unknownCapabilityNetworks: 0 }
  for (const network of value.networks) {
    check(network && typeof network.handle === 'string' && /^[0-9]{1,20}$/.test(network.handle) && !handles.has(network.handle) &&
      ['capabilitiesKnown', 'internet', 'validated', 'vpn', 'notSuspended', 'appDefault'].every(key => typeof network[key] === 'boolean') &&
      Array.isArray(network.transportTypes) && network.transportTypes.length <= 16 &&
      network.transportTypes.every(type => Number.isSafeInteger(type) && type >= 0 && type <= 255) &&
      new Set(network.transportTypes).size === network.transportTypes.length,
    'Recovery network inventory is incomplete or ambiguous')
    handles.add(network.handle)
    if (network.appDefault) defaults.push(network.handle)
    check(network.vpn === network.transportTypes.includes(4), 'VPN evidence conflicts with its transport types')
    if (!network.capabilitiesKnown) {
      check(!network.internet && !network.validated && !network.vpn && !network.notSuspended && !network.transportTypes.length,
        'Unknown network capabilities cannot carry inferred flags')
      counts.unknownCapabilityNetworks++
      continue
    }
    if (network.validated) counts.validatedNetworks++
    if (network.internet && network.validated) {
      counts.validatedInternetNetworks++
      if (network.vpn) counts.validatedVpnInternetNetworks++
      else counts.usableUnderlyingInternetNetworks++
    }
    if (network.internet && !network.validated && !network.vpn) counts.unvalidatedUnderlyingInternetNetworks++
  }
  check(value.appDefaultNetworkHandle === null ? defaults.length === 0 :
    defaults.length === 1 && defaults[0] === value.appDefaultNetworkHandle, 'App default network evidence is inconsistent')
  for (const [key, expected] of Object.entries(counts)) check(value[key] === expected, `Recovery network count differs: ${key}`)
  return counts
}

const hasInternet = value => value.networkEvidence.unknownCapabilityNetworks === 0 &&
  value.networkEvidence.usableUnderlyingInternetNetworks > 0
const isOffline = value => value.networkEvidence.unknownCapabilityNetworks === 0 &&
  value.networkEvidence.usableUnderlyingInternetNetworks === 0 && value.networkEvidence.unvalidatedUnderlyingInternetNetworks === 0

/** Preserve bounded, nested diagnostic causes without stacks or arbitrary error properties. */
export function describeRecoveryFailure(error) {
  const seen = new Set()
  const describe = (value, depth) => {
    if (value == null) return null
    if (seen.has(value) || seen.size >= 32 || depth >= 6) return { type: 'truncated', message: 'Further causes omitted' }
    seen.add(value)
    const result = { type: String(value.name ?? typeof value).slice(0, 80), message: String(value.message ?? value).slice(0, 2000) }
    const causes = [...(value.cause ? [value.cause] : []), ...(Array.isArray(value.errors) ? value.errors.slice(0, 16) : [])]
    if (causes.length) result.causes = causes.map(cause => describe(cause, depth + 1))
    return result
  }
  return describe(error, 0)
}

/** Validate one final result against the original dedicated Session. */
export function parseRecoveryResult(output, ready) {
  const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)[ \t]*\r?\n/gm)]
  const passed = [...output.matchAll(/^INSTRUMENTATION_RESULT: passed=(.*)\r?\n/gm)]
  check(codes.length === 1 && codes[0][1] === '-1' && passed.length === 1 && passed[0][1].trim() === 'true',
    'Production AgentService recovery instrumentation failed')
  const result = validateCheckpoint(jsonField(output, 'RESULT', 'result'), ready, 'restored')
  check(hasInternet(result), 'Restored checkpoint has no known usable underlying internet network')
  return result
}

/** Bound close observation; an expired wait is never reported as process retirement. */
export async function awaitRecoveryClose(promise, milliseconds) {
  let timer
  try { return await Promise.race([promise, new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error('Instrumentation close deadline exceeded')), milliseconds)
  })]) } finally { clearTimeout(timer) }
}

/** Own network restoration and instrumentation/device retirement before returning.
 * IO commands join bounded subprocess close or report commandOutcomeUnknown.
 * Caller cancellation never cancels this owner's independent cleanup.
 */
export async function runRecoveryAcceptance(io, { signal, token, onSnapshot = async () => {}, budgets = BUDGETS }) {
  check(/^[0-9a-f]{32}$/.test(token), 'Invalid recovery token')
  for (const key of Object.keys(BUDGETS)) check(Number.isSafeInteger(budgets[key]) && budgets[key] > 0 && budgets[key] <= BUDGETS[key], `Invalid ${key} budget`)
  let original = null, child = null, closed = null, childOutcome = null, closeFailure = null, changed = false, failure = null
  let ready, online, offline, restored, agentPid, lastObservedNetwork, lastObservation, nativeFailure
  let phase = 'preflight'
  let networkCommandUnknown = false, networkRestored = false, deviceRetired = false, childUnreferenced = false
  const cleanupErrors = [], command = (argv, scope = signal) => io.command(argv, scope)
  const network = async scope => {
    const wifi = (await command(['settings', 'get', 'global', 'wifi_on'], scope)).trim()
    const data = (await command(['settings', 'get', 'global', 'mobile_data'], scope)).trim()
    check(['0', '1'].includes(wifi) && ['0', '1'].includes(data), 'Network flags are not exact booleans')
    lastObservedNetwork = { wifi, data }
    return lastObservedNetwork
  }
  const locked = async scope => {
    check(parseNonInteractivePowerState(await command(['dumpsys', 'power'], scope)), 'Recovery requires noninteractive state; no wake is permitted')
    check(parseRecoveryKeyguard(await command(['dumpsys', 'window', 'policy'], scope)), 'Recovery requires a confirmed locked keyguard')
  }
  const setNetwork = async (kind, value, scope) => {
    try { await command(['svc', kind, value === '1' ? 'enable' : 'disable'], scope) }
    catch (error) { networkCommandUnknown ||= error.commandOutcomeUnknown === true; throw error }
  }
  const wait = async (read, ms, label, scope = signal, allowClosed = false) => {
    const end = io.now() + ms
    while (io.now() < end) {
      scope.throwIfAborted()
      if (closeFailure && !allowClosed) throw closeFailure
      const result = await read()
      if (result) return result
      if (childOutcome && !allowClosed) throw new Error(`Instrumentation closed before ${label}`)
      await io.delay(100)
    }
    throw new Error(`Recovery timed out waiting for ${label}`)
  }
  const broadcast = stage => command(['am', 'broadcast', '-a', `${PACKAGE}.acceptance.${token}`, '-p', PACKAGE, '--es', 'stage', stage])
  const observe = async (predicate, label) => wait(async () => {
    const cut = child.output().length
    await broadcast('observe')
    lastObservation = await wait(() => jsonField(child.output().slice(cut), 'STATUS', 'observation'), budgets.observation, `${label} observation`)
    const state = validateCheckpoint(lastObservation, ready, 'observe')
    return predicate(state) ? state : null
  }, budgets.stage, label)
  const requireAgent = async () => {
    const pid = (await command(['pidof', `${PACKAGE}:agent`])).trim()
    check(/^[1-9]\d*$/.test(pid) && (!agentPid || agentPid === pid), 'Production AgentService PID changed or is unavailable')
    agentPid = pid
  }
  const restoreNetwork = async scope => {
    const results = await Promise.allSettled(['wifi', 'data'].map(kind => setNetwork(kind, original[kind], scope)))
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
    try {
      await wait(async () => {
        const actual = await network(scope)
        return actual.wifi === original.wifi && actual.data === original.data
      }, budgets.restore, 'exact original network flags', scope, true)
    } catch (error) { errors.push(error) }
    if (errors.length) throw new AggregateError(errors, 'Original network restoration is unconfirmed')
  }
  try {
    signal.throwIfAborted()
    await locked(signal)
    original = await network(signal)
    check(original.wifi === '1' || original.data === '1', 'Recovery requires an originally enabled network')
    await onSnapshot({ schema: 1, token, original, noWake: true })
    signal.throwIfAborted()
    child = io.instrument(token)
    phase = 'startup'
    closed = child.closed.then(outcome => { childOutcome = outcome; return outcome })
    // A rejected close is retained for the awaited retirement path, not ignored as success.
    closed.catch(error => { closeFailure = error })
    ready = validateReady(await wait(() => jsonField(child.output(), 'STATUS', 'ready'), budgets.ready, 'AgentService ready'), token)
    await requireAgent()
    phase = 'online-observation'
    online = await observe(hasInternet, 'initial usable underlying internet')
    await locked(signal)
    changed = true
    phase = 'disable-network'
    await setNetwork('wifi', '0', signal)
    await setNetwork('data', '0', signal)
    phase = 'offline-observation'
    await observe(isOffline, 'locked offline state without usable underlying internet')
    const disabled = await network(signal)
    check(disabled.wifi === '0' && disabled.data === '0', 'Network flags did not become fully disabled')
    const cut = child.output().length
    phase = 'offline-checkpoint'
    await broadcast('offline')
    offline = validateCheckpoint(await wait(() => jsonField(child.output().slice(cut), 'STATUS', 'checkpoint'), budgets.stage, 'offline Session checkpoint'), ready, 'offline')
    lastObservation = offline
    check(isOffline(offline), 'Offline checkpoint still has usable or unknown underlying networks')
    await requireAgent()
    phase = 'restore-network'
    await restoreNetwork(signal)
    phase = 'restored-observation'
    await observe(hasInternet, 'restored usable underlying internet')
    phase = 'restored-result'
    await broadcast('restored')
    await wait(() => /^INSTRUMENTATION_CODE: -?\d+[ \t]*\r?\n/m.test(child.output()), budgets.stage, 'restored result')
    restored = parseRecoveryResult(child.output(), ready)
    lastObservation = restored
    await requireAgent()
    await locked(signal)
    check((await awaitRecoveryClose(closed, budgets.retirement)).code === 0, 'Instrumentation host exited unsuccessfully')
    phase = 'complete'
  } catch (error) {
    failure = error
    if (child) {
      try {
        const output = child.transcript()
        nativeFailure = { causes: jsonField(output, 'RESULT', 'failureCauses'),
          lastObservation: jsonField(output, 'RESULT', 'lastObservation') }
        const message = [...output.matchAll(/^INSTRUMENTATION_RESULT: failure=(.*)\r?\n/gm)]
        if (message.length) nativeFailure.message = message.at(-1)[1].slice(0, 2000)
        if (nativeFailure.lastObservation) lastObservation = nativeFailure.lastObservation
      } catch (diagnosticError) { nativeFailure = { readFailure: describeRecoveryFailure(diagnosticError) } }
    }
  }
  finally {
    const cleanup = new AbortController()
    if (changed) {
      try { await restoreNetwork(cleanup.signal); networkRestored = !networkCommandUnknown }
      catch (error) { cleanupErrors.push(error) }
    } else networkRestored = original !== null
    if (child) {
      const stops = await Promise.allSettled([PACKAGE, `${PACKAGE}.test`].map(name => command(['am', 'force-stop', name], cleanup.signal)))
      cleanupErrors.push(...stops.filter(value => value.status === 'rejected').map(value => value.reason))
      if (!childOutcome) {
        try { await child.stop() } catch (error) { cleanupErrors.push(error) }
      }
      try { await awaitRecoveryClose(closed, budgets.retirement) } catch (error) { cleanupErrors.push(error) }
      if (!childOutcome) {
        try { child.unref(); childUnreferenced = true } catch (error) { cleanupErrors.push(error) }
      }
      try {
        await wait(async () => parseAcceptanceProcesses(await command(['ps', '-A', '-w', '-o', 'PID,ARGS'], cleanup.signal)).length === 0,
          budgets.retirement, 'all App/test processes to retire', cleanup.signal, true)
        deviceRetired = true
      } catch (error) { cleanupErrors.push(error) }
    }
  }
  const retirement = { hostPid: child?.pid ?? null, hostProcessClosed: child ? childOutcome !== null : true,
    hostHandleReleased: childUnreferenced, deviceProcessesGone: child ? deviceRetired : true,
    networkRestored, confirmed: (!child || (childOutcome !== null && deviceRetired)) && networkRestored }
  const report = { schema: 1, result: failure || cleanupErrors.length || !retirement.confirmed || signal.aborted ? 'unknown' : 'pass',
    token, phase, agentPid, original, lastObservedNetwork, lastObservation, nativeFailure,
    failures: { execution: describeRecoveryFailure(failure), cleanup: cleanupErrors.map(describeRecoveryFailure),
      cancellation: signal.aborted ? describeRecoveryFailure(signal.reason) : null },
    online, offline, restored, instrumentationExit: childOutcome,
    noWake: true, retirement, networkCommandOutcomeUnknown: networkCommandUnknown,
    modelRequestRetryTested: false, activeAgentTaskSurvivalTested: false }
  if (report.result !== 'pass') {
    const error = new AggregateError([failure, ...cleanupErrors, signal.aborted ? signal.reason : null].filter(Boolean),
      'AgentService recovery did not pass; inspect original network snapshot and retirement evidence')
    error.recovery = report
    error.retirement = retirement
    throw error
  }
  return report
}
