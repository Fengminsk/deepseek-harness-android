import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { realpathSync } from 'node:fs'
import { readFile, writeFile, unlink } from 'node:fs/promises'
import { join, relative, isAbsolute, sep } from 'node:path'
import { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'

export const PTC_LINUX_DEVICE_CHECK = 'reviewed-ptc-linux-import-analysis-export'
const names = ['linux_import', 'linux_exec', 'linux_export', 'linux_inspect']
const sha256 = value => createHash('sha256').update(value).digest('hex')

const diagnosticText = value => typeof value === 'string' ? value.slice(0, 96) : null
const diagnosticError = value => typeof value === 'string' && /^[A-Za-z][A-Za-z0-9_.:/-]{0,63}$/u.test(value) ? value : 'unclassified'
const diagnosticFacts = value => Object.fromEntries(['status', 'state', 'exitCode', 'guestUid',
  'diskCommitted', 'filePublished', 'retirementConfirmed', 'blocked', 'needsReview'].flatMap(key => {
  const fact = value?.[key]
  return typeof fact === 'boolean' || Number.isSafeInteger(fact) || fact === null
    || ['status', 'state'].includes(key) && typeof fact === 'string' ? [[key, typeof fact === 'string' ? fact.slice(0, 48) : fact]] : []
}))

/** Project only bounded identities and state; never copy commands, paths, messages or tool output. */
export function ptcLinuxFailureDiagnostics({ phase, startedAt, requests, settlements, liveEvents,
  durableEvents, durableRead }) {
  const dispatches = events => events.filter(event => ['tool/ptc-dispatch-start', 'tool/ptc-dispatch'].includes(event.type))
    .slice(-8).map(event => ({ seq: event.seq, type: event.type,
      name: diagnosticText(event.data.name), subCallId: diagnosticText(event.data.subCallId),
      ...(typeof event.data.isError === 'boolean' ? { isError: event.data.isError } : {}),
      ...(event.data.error ? { errorCode: diagnosticError(event.data.error.code) } : {}) }))
  return { version: 1, phase: diagnosticText(phase), elapsedMs: Date.now() - startedAt,
    requests: requests.slice(-8).map(row => ({ method: diagnosticText(row.method),
      id: diagnosticText(row.params.id), sessionId: diagnosticText(row.params.sessionId),
      startedAtMs: row.startedAtMs, completedAtMs: row.completedAtMs ?? null,
      observation: row.result !== null ? 'returned' : row.errorCode ? 'rejected' : 'pending',
      ...(row.errorCode ? { errorCode: diagnosticError(row.errorCode) } : {}),
      result: diagnosticFacts(row.result) })),
    settlements: settlements.slice(-2).map(row => ({ runId: diagnosticText(row.runId), ...diagnosticFacts(row) })),
    liveDispatch: dispatches(liveEvents), durableDispatch: dispatches(durableEvents), durableRead }
}

export class PtcLinuxAcceptanceFailure extends Error {
  constructor(cause, diagnostics) {
    super(String(cause?.message ?? cause).slice(0, 500), { cause })
    this.diagnostics = diagnostics
  }
}

// Diagnostic reads must not flush or wait indefinitely behind the failed call.
// The original native/ToolRuntime owners still own cancellation and retirement.
export async function readPtcLinuxFailureDispatch(ctx, session, offset) {
  const controller = new AbortController(), { signal } = controller
  let timer
  const timeout = new Promise(resolve => { timer = setTimeout(() => {
    controller.abort(new Error('Bounded diagnostic read expired'))
    resolve({ events: [], state: 'timed-out' })
  }, 2000) })
  const read = (async () => {
    let reader
    try {
      reader = await ctx.sessionPersistence.open(session.id, 'read', { signal })
      const { events } = await reader.read(offset, 64, { signal })
      return { events, state: 'read' }
    } catch (error) { return { events: [], state: signal.aborted ? 'timed-out' : 'unavailable',
      errorCode: diagnosticError(error?.code ?? error?.name) } }
    finally { await reader?.close() }
  })().catch(error => ({ events: [], state: 'unavailable', errorCode: diagnosticError(error?.code ?? error?.name) }))
  try { return await Promise.race([read, timeout]) }
  finally { clearTimeout(timer) }
}

/** Build the device program; only original reviewed tools cross the guest boundary. */
export function ptcLinuxProgram({ source, destination, guestInput, guestOutput }) {
  const python = [
    'import hashlib,json,pathlib',
    `data=pathlib.Path(${JSON.stringify(guestInput)}).read_bytes()`,
    'source=json.loads(data)',
    "result={'count':len(source['values']),'sum':sum(source['values']),'sourceSha256':hashlib.sha256(data).hexdigest(),'nonce':source['nonce']}",
    "output=(json.dumps(result,separators=(',',':'))+'\\n').encode()",
    `pathlib.Path(${JSON.stringify(guestOutput)}).write_bytes(output)`,
    'print(hashlib.sha256(output).hexdigest())',
  ].join('\n')
  const command = `python3 - <<'DSH_PTC_LINUX_ANALYSIS'\n${python}\nDSH_PTC_LINUX_ANALYSIS`
  return `function completed(r,disk){if(r.status!=='completed'||r.exitCode!==0||r.retirementConfirmed!==true||r.diskCommitted!==disk)throw new Error('Linux step not confirmed; stop without retry')}
    const imported=await tools.linux_import(${JSON.stringify({ source, destination: guestInput, timeoutMs: 120000 })});completed(imported,true);
    const executed=await tools.linux_exec(${JSON.stringify({ command, timeoutMs: 120000 })});completed(executed,true);
    const exported=await tools.linux_export(${JSON.stringify({ source: guestOutput, destination, timeoutMs: 120000 })});completed(exported,false);
    if(exported.filePublished!==true)throw new Error('Linux publication not confirmed; stop without retry');
    const inspection=await tools.linux_inspect({runId:exported.id});
    return {imported,executed,exported,inspection,ambient:{process:typeof process,fetch:typeof fetch}};`
}

/** Reject incomplete or contradictory native, filesystem and durable Session observations. */
export function validatePtcLinuxEvidence({ result, settlement, requests, liveEvents, durableEvents,
  fileBytes, inputBytes, expectedBytes, sessionId, appUid, hostInput, hostOutput, guestInput, guestOutput,
  nativeInput, nativeOutput }) {
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(settlement?.state, 'COMPLETED', 'PTC must confirm its own native retirement')
  assert.ok(Number.isInteger(settlement.guestUid))
  assert.notEqual(settlement.guestUid, appUid)
  const value = result.value.result
  assert.deepEqual(value.ambient, { process: 'undefined', fetch: 'undefined' })
  assert.deepEqual(requests.map(row => row.method), ['native.linuxVm.inspect',
    'native.linuxVm.importFile', 'native.linuxVm.execute', 'native.linuxVm.exportFile', 'native.linuxVm.inspect'])
  assert.deepEqual(requests[0].params, { sessionId })
  assert.equal(requests[0].result.status, 'absent', 'This case must start with a new Linux Session, without prewarming')
  assert.equal(requests[0].result.sessionId, sessionId)
  assert.equal(requests[0].result.blocked, false)
  assert.equal(requests[0].result.needsReview, false)
  assert.deepEqual(requests[0].result.records, [])
  const executions = requests.slice(1, 4), returned = [value.imported, value.executed, value.exported]
  assert.equal(new Set(executions.map(row => row.params.id)).size, 3)
  for (const [index, row] of executions.entries()) {
    assert.equal(row.params.sessionId, sessionId)
    const receipt = row.result
    assert.equal(receipt.id, row.params.id)
    assert.equal(receipt.sessionId, sessionId)
    assert.equal(receipt.status, 'completed'); assert.equal(receipt.exitCode, 0, receipt.output)
    assert.equal(receipt.retirementConfirmed, true)
    assert.equal(receipt.diskCommitted, index < 2)
    assert.ok(Number.isInteger(receipt.guestUid))
    assert.notEqual(receipt.guestUid, appUid)
    assert.notEqual(receipt.guestUid, settlement.guestUid, 'Linux and the still-running PTC guest must have different isolated UIDs')
    for (const [key, fact] of Object.entries(receipt)) assert.deepEqual(returned[index][key], fact)
    assert.equal(returned[index].cancelRequested, false)
  }
  assert.equal(requests[1].params.source, nativeInput)
  assert.equal(requests[1].params.destination, guestInput)
  assert.equal(value.imported.bytes, inputBytes.length)
  assert.equal(value.imported.sha256, sha256(inputBytes))
  assert.equal(requests[2].params.persistChanges, true)
  assert.equal(value.executed.output.trim(), sha256(expectedBytes))
  assert.equal(requests[3].params.source, guestOutput)
  assert.equal(requests[3].params.destination, nativeOutput)
  assert.equal(value.exported.filePublished, true)
  assert.equal(value.exported.file_path, hostOutput)
  assert.equal(value.exported.bytes, expectedBytes.length)
  assert.equal(value.exported.sha256, sha256(expectedBytes))
  assert.deepEqual(fileBytes, expectedBytes, 'Actual App file must match the independent expected analysis')
  assert.deepEqual(requests[4].params, { sessionId, id: value.exported.id })
  assert.deepEqual(value.inspection, requests[4].result)
  assert.equal(value.inspection.status, 'ready')
  assert.equal(value.inspection.blocked, false); assert.equal(value.inspection.needsReview, false)
  assert.equal(value.inspection.requestedRunFound, true)
  assert.equal(value.inspection.records.length, 1)
  const inspected = value.inspection.records[0]
  assert.equal(inspected.runId, value.exported.id)
  assert.equal(inspected.operation, 'export'); assert.equal(inspected.state, 'completed')
  assert.equal(inspected.filePublished, true); assert.equal(inspected.diskCommitted, false)
  assert.equal(inspected.retirementConfirmed, true)
  const dispatches = events => events.filter(event => event.type === 'tool/ptc-dispatch')
  const live = dispatches(liveEvents), durable = dispatches(durableEvents)
  assert.deepEqual(live.map(event => event.data.name), names)
  assert.deepEqual(durable, live, 'PTC callback facts must survive a real persistence read')
  const starts = durableEvents.filter(event => event.type === 'tool/ptc-dispatch-start')
  assert.deepEqual(starts.map(event => event.data.name), names)
  const contexts = []
  for (const [index, event] of durable.entries()) {
    assert.equal(event.data.isError, false)
    assert.equal(starts[index].data.subCallId, event.data.subCallId)
    assert.ok(starts[index].seq < event.seq)
    assert.deepEqual(JSON.parse(event.data.content[0].text), index < 3 ? returned[index] : value.inspection)
    contexts.push(...event.data.additionalContexts)
  }
  const receipts = contexts.filter(message => message.source.kind === 'android-linux-receipt')
    .map(message => JSON.parse(message.content[0].text).linuxVmReceipt)
  assert.equal(receipts.length, 3)
  for (const [index, receipt] of receipts.entries()) {
    assert.equal(receipt.tool, names[index])
    assert.equal(receipt.callId, durable[index].data.subCallId)
    assert.equal(receipt.sessionId, sessionId)
    assert.equal(receipt.runId, returned[index].id)
    assert.equal(receipt.status, 'completed'); assert.equal(receipt.exitCode, 0)
    assert.equal(receipt.diskCommitted, index < 2)
    assert.equal(receipt.retirementConfirmed, true); assert.equal(receipt.cancelRequested, false)
  }
  assert.equal(receipts[0].sha256, sha256(inputBytes))
  assert.equal(receipts[2].filePublished, true)
  assert.equal(receipts[2].sha256, sha256(fileBytes))
  const inspections = contexts.filter(message => message.source.kind === 'android-linux-inspection')
  assert.equal(inspections.length, 1)
  assert.deepEqual(JSON.parse(inspections[0].content[0].text).linuxVmInspection, value.inspection)
  assert.deepEqual(result.additionalContexts, contexts, 'Original Linux contexts must reach the parent PTC caller')
  return { sessionId, runId: settlement.runId, ptcGuestUid: settlement.guestUid, appUid,
    guestUids: returned.map(receipt => receipt.guestUid), linuxRunIds: returned.map(receipt => receipt.id),
    nativeState: settlement.state, coldInspection: 'absent', filePublished: true,
    bytes: fileBytes.length, sha256: sha256(fileBytes), inputSha256: sha256(inputBytes),
    source: hostInput, file: hostOutput, durableReceipts: receipts.length,
    durableDispatches: durable.length, sessionEvidenceSha256: sha256(JSON.stringify(durableEvents)) }
}

/** Use the installed native bridge; no simulated RPC, preboot or alternate file publication. */
export async function runPtcLinuxAcceptance({ ctx, transport, agent, workspace, appWorkspaceRoot,
  nativeModule, invoke, settlements }) {
  const startedAt = Date.now()
  let phase = 'setup'
  assert.equal(typeof appWorkspaceRoot, 'string')
  appWorkspaceRoot = realpathSync(appWorkspaceRoot)
  workspace = realpathSync(workspace)
  const scope = relative(appWorkspaceRoot, workspace)
  assert.ok(scope && !isAbsolute(scope) && scope !== '..' && !scope.startsWith(`..${sep}`))
  const [{ NativeLinuxVm }, factories] = await Promise.all([
    nativeModule('native-linux-vm.mjs'), nativeModule('tool-linux-vm.mjs'),
  ])
  const requests = []
  const owner = new NativeLinuxVm({ async request(method, params, signal) {
    const row = { method, params, result: null, startedAtMs: Date.now() - startedAt }
    requests.push(row)
    try {
      row.result = await transport.request(method, params, signal)
      return row.result
    } catch (error) { row.errorCode = error?.code ?? error?.name ?? 'request-rejected'; throw error }
    finally { row.completedAtMs = Date.now() - startedAt }
  } })
  const token = randomUUID(), source = `ptc-linux-input-${token}.json`, destination = `ptc-linux-output-${token}.json`
  const guestInput = `ptc-${token}/input.json`, guestOutput = `ptc-${token}/output.json`
  const hostInput = join(workspace, source), hostOutput = join(workspace, destination)
  const inputBytes = Buffer.from(JSON.stringify({ values: [2, 3, 5, 12], nonce: token }))
  const expectedBytes = Buffer.from(`${JSON.stringify({ count: 4, sum: 22, sourceSha256: sha256(inputBytes), nonce: token })}\n`)
  const originalMode = ctx.sandboxPolicy.resolve({ session: agent.session }).mode
  const liveEvents = []
  let before = agent.session.seq
  const priorSettlements = settlements.length
  let fiber, stopObserving, failure
  try {
    // A disposable registration fiber keeps all mode's later Linux owner separate.
    fiber = await ctx.plugin({ name: 'ptc-device-linux-tools',
      inject: ['tools', 'agents', 'sandboxPolicy', 'fs', 'workingDirectory'], apply(scope) {
      for (const name of names) assert.equal(scope.tools.get(name, agent), undefined)
      factories.registerLinuxVmTool(scope, owner, true)
      factories.registerLinuxImportTool(scope, owner, true, appWorkspaceRoot)
      factories.registerLinuxExportTool(scope, owner, true, appWorkspaceRoot)
      factories.registerLinuxInspectTool(scope, owner, true)
    } })
    setSandboxMode(agent.session, 'workspace-write')
    await writeFile(hostInput, inputBytes, { flag: 'wx' })
    before = agent.session.seq
    stopObserving = ctx.on('session/event', (session, event) => {
      if (session === agent.session) liveEvents.push(event)
    })
    phase = 'ptc-invoke'
    const result = await invoke(ptcLinuxProgram({ source, destination, guestInput, guestOutput }))
    assert.equal(result.isError, false, JSON.stringify(result.error))
    assert.equal(settlements.length, priorSettlements + 1)
    phase = 'session-flush-after-result'
    assert.equal(await ctx.sessions.flush(agent.session), true)
    phase = 'session-read-after-flush'
    const reader = await ctx.sessionPersistence.open(agent.session.id, 'read')
    let events
    try { ({ events } = await reader.read(before, 10000)) } finally { await reader.close() }
    phase = 'evidence-validation'
    return validatePtcLinuxEvidence({ result, settlement: settlements.at(-1), requests,
      liveEvents, durableEvents: events,
      fileBytes: await readFile(hostOutput), inputBytes, expectedBytes,
      sessionId: String(agent.session.id), appUid: process.getuid(), hostInput, hostOutput, guestInput, guestOutput,
      nativeInput: relative(appWorkspaceRoot, hostInput).split(sep).join('/'),
      nativeOutput: relative(appWorkspaceRoot, hostOutput).split(sep).join('/') })
  } catch (error) {
    const { events, ...durableRead } = await readPtcLinuxFailureDispatch(ctx, agent.session, before)
    failure = new PtcLinuxAcceptanceFailure(error, ptcLinuxFailureDiagnostics({ phase, startedAt,
      requests, settlements: settlements.slice(priorSettlements), liveEvents, durableEvents: events, durableRead }))
    throw failure
  } finally {
    stopObserving?.()
    setSandboxMode(agent.session, originalMode)
    const cleanup = async (name, action) => {
      try { await action(); if (failure) (failure.diagnostics.cleanup ??= {})[name] = { state: 'closed' } }
      catch (error) {
        failure ??= new PtcLinuxAcceptanceFailure(error, ptcLinuxFailureDiagnostics({ phase: 'cleanup', startedAt,
          requests, settlements: settlements.slice(priorSettlements), liveEvents, durableEvents: [],
          durableRead: { state: 'not-read' } }))
        const states = failure.diagnostics.cleanup ??= {}
        states[name] = { state: 'unconfirmed', errorCode: diagnosticError(error?.code ?? error?.name) }
      }
    }
    await cleanup('linuxOwner', () => owner.dispose())
    await cleanup('registrations', () => fiber?.dispose())
    for (const file of [hostInput, hostOutput]) {
      try { await unlink(file) } catch (error) { if (error?.code !== 'ENOENT') throw error }
    }
    if (failure) throw failure
  }
}
