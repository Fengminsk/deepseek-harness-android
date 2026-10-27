import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { open, readFile, realpath, stat } from 'node:fs/promises'
import { join, basename } from 'node:path'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import { NativeIsolatedToolCallbacks } from '../../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from '../../runtime/model-ptc-reviewed-owner.mjs'
import { registerAndroidPtcTool } from '../../runtime/tool-model-ptc.mjs'
import { registerModelFileReadGuard } from '../../runtime/model-file-read-guard.mjs'
import { inPtcAcceptanceTurn } from './ptc.mjs'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const markerName = 'ptc-death-ready.json'

async function syncFile(path, content) {
  const file = await open(path, 'wx', 0o600)
  try { await file.writeFile(JSON.stringify(content) + '\n'); await file.sync() }
  finally { await file.close() }
  let directory
  try { directory = await open(join(path, '..'), 'r'); await directory.sync() }
  catch (error) {
    if (process.platform !== 'win32' || !['EISDIR', 'EINVAL', 'EACCES', 'EPERM'].includes(error.code)) throw error
  } finally { await directory?.close() }
}

function readyFields(marker) {
  return { schema: 1, caseId: marker.caseId, runId: marker.prepared.runId,
    agentPid: marker.agentPid, fileSha256: marker.fileSha256 }
}

/**
 * Interrupt a real PTC write after execution and durable dispatch, before result confirmation.
 * @param {object} input - Dedicated acceptance Session, native transport, UUID home and phase.
 * @returns {Promise<object>} Recovery evidence; prepare remains pending until process death.
 */
export async function runPtcProcessDeathAcceptance({ ctx, transport, agent, workspace, callbackRouting, configuration }) {
  assert.match(configuration.caseId, UUID)
  assert.ok(['prepare', 'recover'].includes(configuration.phase))
  const caseId = configuration.caseId, home = await realpath(resolveDshHome())
  workspace = await realpath(workspace)
  assert.equal(basename(home), caseId, 'PTC death test requires its UUID-specific home')
  assert.equal(basename(workspace), `.ptc-death-${caseId}`, 'PTC death test requires its UUID-specific workspace')
  assert.equal(agent.session.id, `ptc-death-${caseId}`)
  assert.equal(ctx.agents.get(agent.id), agent)
  const journal = new IsolatedToolCallJournal(join(home, 'ptc-death-journal'))
  const fileName = 'unconfirmed-write.txt', file = join(workspace, fileName)
  const expected = `PTC unconfirmed side effect ${caseId}\n`
  const markerPath = join(home, markerName)
  if (!ctx.tools.get('write', agent)) await ctx.plugin(FsTools, { readImage: false })
  registerModelFileReadGuard(ctx, workspace)
  if (configuration.phase === 'recover') {
    assert.equal(configuration.processStopConfirmed, true, 'Host must observe both old processes exit')
    const info = await stat(markerPath)
    assert.ok(info.isFile() && info.size < 128 * 1024)
    const marker = JSON.parse(await readFile(markerPath, 'utf8'))
    assert.equal(marker.schema, 1); assert.equal(marker.caseId, caseId)
    assert.equal(marker.sessionId, agent.session.id)
    assert.equal(marker.prepared.sessionId, agent.session.id)
    assert.equal(marker.prepared.kind, 'ptc')
    assert.equal(marker.prepared.runId, marker.admission.runId)
    assert.match(marker.prepared.runId, UUID)
    assert.equal(marker.fileSha256, sha256(expected))
    assert.ok(Number.isSafeInteger(marker.agentPid) && marker.agentPid > 0 && marker.agentPid !== process.pid,
      'Recovery must use a fresh Node/Agent process')
    const before = await readFile(file)
    assert.equal(sha256(before), marker.fileSha256)
    assert.equal((await journal.inspect({ runId: marker.prepared.runId, callId: 1 })).state, 'dispatch-unconfirmed')
    let nativeRequests = 0, executions = 0
    const callbacks = new NativeIsolatedToolCallbacks({ async request() {
      nativeRequests++; throw new Error('Old PTC run reached native binding')
    } }, journal)
    const runtime = { get: (name, owner) => ctx.tools.get(name, owner), async execute() {
      executions++; throw new Error('Old PTC write was replayed')
    } }
    try {
      await assert.rejects(callbacks.bind({ prepared: marker.prepared, admission: marker.admission,
        runtime, parent: { agent, token: Symbol('recovery-refusal'), callId: marker.parentCallId,
          signal: new AbortController().signal }, allowedToolNames: ['write'], authorizeTool: () => {
          throw new Error('Old PTC run reached authorization')
        } }), error => error?.code === 'ANDROID_TOOL_REPLAY')
      assert.equal(nativeRequests, 0); assert.equal(executions, 0)
      assert.deepEqual(await readFile(file), before)
      assert.equal((await journal.inspect({ runId: marker.prepared.runId, callId: 1 })).state, 'dispatch-unconfirmed')
    } finally { await callbacks.dispose() }
    return { suite: 'ptc-process-death', checks: [{ name: 'ptc-killed-dispatch-no-replay', status: 'passed',
      ...readyFields(marker), oldAgentPid: marker.agentPid, newAgentPid: process.pid,
      journalState: 'dispatch-unconfirmed', nativeRebindRequests: nativeRequests, replayedExecutions: executions }] }
  }
  assert.equal(configuration.processStopConfirmed, false)
  await assert.rejects(stat(markerPath), error => error.code === 'ENOENT')
  await assert.rejects(stat(file), error => error.code === 'ENOENT')
  let binding
  const callbacks = new NativeIsolatedToolCallbacks(transport, journal)
  const originalBind = callbacks.bind.bind(callbacks)
  callbacks.bind = async input => {
    assert.equal(binding, undefined)
    binding = { prepared: input.prepared, admission: input.admission, parentCallId: input.parent.callId }
    return originalBind(input)
  }
  const unbind = callbackRouting.bind('tool', callbacks)
  const owner = createAppOwnedPtcOwner({ bridge: createNativeIsolatedExecutionBridge(transport), callbacks,
    runtime: ctx.tools, services: { agents: ctx.agents, subagents: ctx.subagents,
      sessions: ctx.sessions, sandboxPolicy: ctx.sandboxPolicy } })
  registerAndroidPtcTool(ctx, { owner, available: () => true })
  const stop = ctx.on('tools/execute', async (execution, next) => {
    const result = await next()
    if (execution.agent !== agent || execution.name !== 'write') return result
    assert.equal(execution.arguments.file_path, fileName)
    assert.equal(result.isError, false)
    const bytes = await readFile(file)
    assert.equal(bytes.toString('utf8'), expected)
    const handle = await open(file, 'r+')
    try { await handle.sync() } finally { await handle.close() }
    assert.equal((await journal.inspect({ runId: binding.prepared.runId, callId: 1 })).state, 'dispatch-unconfirmed')
    const marker = { schema: 1, caseId, agentPid: process.pid, sessionId: agent.session.id,
      ...binding, fileSha256: sha256(bytes) }
    await syncFile(markerPath, marker)
    await transport.notify('acceptance.ptcDeathReady', readyFields(marker))
    await new Promise((resolve, reject) => {
      const abort = () => reject(execution.signal.reason ?? new Error('Acceptance cancelled before process death'))
      if (execution.signal.aborted) abort()
      else execution.signal.addEventListener('abort', abort, { once: true })
    })
    throw new Error('Pending PTC callback unexpectedly resumed')
  })
  const originalMode = ctx.sandboxPolicy.resolve({ session: agent.session }).mode
  try {
    setSandboxMode(agent.session, 'workspace-write')
    return await inPtcAcceptanceTurn(ctx, agent, async () => {
      const result = await ctx.tools.execute({ name: 'android_ptc', callId: `ptc-death-${randomUUID()}`,
        arguments: { description: 'PTC process-death acceptance',
          code: `await tools.write({file_path:${JSON.stringify(fileName)},content:${JSON.stringify(expected)}});return 'unexpected-confirmed'` },
        agent, signal: new AbortController().signal })
      throw new Error(`PTC preparation ended before process death: ${JSON.stringify(result.error)}`)
    })
  } finally {
    stop(); setSandboxMode(agent.session, originalMode)
    try { await owner.close() } finally { try { await callbacks.dispose() } finally { unbind() } }
  }
}
