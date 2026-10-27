import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
import { join, relative, isAbsolute, sep } from 'node:path'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import { preparePythonAnalysis, validatePythonAnalysis } from './python-analysis.mjs'

/** Exercise production ToolRuntime and Linux native ownership using only acceptance-owned files. */
export async function runLinuxAcceptance({ ctx, transport, agent, workspace, appWorkspaceRoot, nativeModule,
  adapter, workflow }) {
  assert.equal(ctx.agents.get(agent.id), agent)
  assert.equal(typeof appWorkspaceRoot, 'string', 'Acceptance requires the explicit production App workspace root')
  // Android exposes the same App directory through /data/user/0 and /data/data.
  appWorkspaceRoot = realpathSync(appWorkspaceRoot)
  workspace = realpathSync(workspace)
  const scope = relative(appWorkspaceRoot, workspace)
  assert.ok(scope && !isAbsolute(scope) && scope !== '..' && !scope.startsWith(`..${sep}`))
  const [{ NativeLinuxVm }, { registerLinuxVmTool, registerLinuxImportTool, registerLinuxExportTool,
    registerLinuxInspectTool }] = await Promise.all([
    nativeModule('native-linux-vm.mjs'), nativeModule('tool-linux-vm.mjs'),
  ])
  if (!ctx.get('sandboxPolicy')) await ctx.plugin(SandboxPolicy, { mode: 'workspace-write', workspaceRoot: workspace })
  setSandboxMode(agent.session, 'workspace-write')
  await mkdir(workspace, { recursive: true })
  const token = randomUUID(), source = `linux-input-${token}.txt`
  const content = Buffer.from(`Linux device import ${token}\n中文\n`)
  const sha256 = createHash('sha256').update(content).digest('hex')
  const hostFile = join(workspace, source)
  await writeFile(hostFile, content, { flag: 'wx' })
  const requests = [], checks = []
  const owner = new NativeLinuxVm({ async request(method, params, signal) {
    const row = { method, params, result: null }
    requests.push(row)
    row.result = await transport.request(method, params, signal)
    return row.result
  } })
  registerLinuxVmTool(ctx, owner, true)
  registerLinuxImportTool(ctx, owner, true, appWorkspaceRoot)
  registerLinuxExportTool(ctx, owner, true, appWorkspaceRoot)
  registerLinuxInspectTool(ctx, owner, true)
  const invoke = (name, args) => ctx.tools.execute({ name, arguments: args, agent,
    callId: `linux-device-${randomUUID()}`, signal: new AbortController().signal })
  const execute = async (command, persisted = true) => {
    const result = await invoke('linux_exec', { command, timeoutMs: 120000 })
    assert.equal(result.isError, false, JSON.stringify(result.error ?? result).slice(0, 1500))
    assert.equal(result.value.status, 'completed', JSON.stringify(result.value))
    assert.equal(result.value.exitCode, 0, result.value.output)
    assert.equal(result.value.retirementConfirmed, true)
    assert.equal(result.value.diskCommitted, persisted)
    assert.ok(Number.isInteger(result.value.guestUid))
    assert.notEqual(result.value.guestUid, process.getuid())
    return result.value
  }
  const check = async (name, action) => {
    const started = Date.now()
    try { checks.push({ name, status: 'passed', ...(await action()), elapsedMs: Date.now() - started }) }
    catch (error) { checks.push({ name, status: 'failed', error: String(error?.message ?? error).slice(0, 1500), elapsedMs: Date.now() - started }) }
  }
  const state = `linux-state-${token}.txt`, destination = `imports/${source}`
  const exportedName = `linux-export-${token}.txt`, exportedFile = join(workspace, exportedName)
  const childExport = `linux-child-export-${token}.txt`
  try {
    await check('production-tool-shell-and-session-persistence', async () => {
      const first = await execute(`uname -sm\nprintf '%s\\n' '${token}' > '${state}'\ncat '${state}'`)
      assert.match(first.output, /Linux/)
      assert.ok(first.output.includes(token))
      const next = await execute(`cat '${state}'`)
      assert.equal(next.output.trim(), token)
      const observation = await invoke('linux_inspect', { runId: next.id })
      assert.equal(observation.isError, false, JSON.stringify(observation))
      assert.equal(observation.value.sessionId, String(agent.session.id))
      assert.equal(observation.value.status, 'ready')
      assert.equal(observation.value.needsReview, false)
      assert.equal(observation.value.requestedRunFound, true)
      assert.equal(observation.value.records.length, 1)
      assert.equal(observation.value.records[0].runId, next.id)
      assert.equal(observation.value.records[0].diskCommitted, true)
      assert.equal(observation.value.records[0].retirementConfirmed, true)
      return { guestUid: next.guestUid, appUid: process.getuid(), diskCommitted: next.diskCommitted,
        inspectionConfirmed: true }
    })
    await check('production-python-stdlib-file-analysis', async () => {
      const fixture = await preparePythonAnalysis(token)
      const receipt = await execute(fixture.command)
      const analysis = validatePythonAnalysis(receipt.output, fixture.expected)
      assert.equal(analysis.platform, 'linux')
      assert.equal(analysis.machine, 'riscv64')
      return { guestUid: receipt.guestUid, diskCommitted: receipt.diskCommitted,
        retirementConfirmed: receipt.retirementConfirmed, ...analysis }
    })
    await check('production-tool-import-hash-and-guest-readback', async () => {
      const result = await invoke('linux_import', { source, destination, timeoutMs: 120000 })
      assert.equal(result.isError, false, JSON.stringify(result.error ?? result).slice(0, 1500))
      assert.equal(result.value.status, 'completed')
      assert.equal(result.value.exitCode, 0, result.value.output)
      assert.equal(result.value.diskCommitted, true)
      assert.equal(result.value.retirementConfirmed, true)
      assert.equal(result.value.source, relative(appWorkspaceRoot, hostFile).split(sep).join('/'))
      assert.equal(result.value.destination, destination)
      assert.equal(result.value.bytes, content.length)
      assert.equal(result.value.sha256, sha256)
      const readback = await execute(`sha256sum '${destination}'`)
      assert.equal(readback.output.trim().split(/\s+/u)[0], sha256)
      return { bytes: result.value.bytes, sha256, guestUid: readback.guestUid }
    })
    await check('production-tool-export-hash-and-no-overwrite', async () => {
      const result = await invoke('linux_export', { source: destination, destination: exportedName, timeoutMs: 120000 })
      assert.equal(result.isError, false, JSON.stringify(result.error ?? result).slice(0, 1500))
      assert.equal(result.value.status, 'completed'); assert.equal(result.value.exitCode, 0)
      assert.equal(result.value.filePublished, true); assert.equal(result.value.diskCommitted, false)
      assert.equal(result.value.bytes, content.length); assert.equal(result.value.sha256, sha256)
      assert.equal(result.value.file_path, exportedFile)
      const data = await readFile(exportedFile)
      assert.deepEqual(data, content)
      assert.equal(createHash('sha256').update(data).digest('hex'), sha256)
      const before = requests.length
      const duplicate = await invoke('linux_export', { source: destination, destination: exportedName })
      assert.equal(duplicate.isError, true); assert.equal(requests.length, before)
      assert.deepEqual(await readFile(exportedFile), content)
      return { bytes: result.value.bytes, sha256, filePublished: true, overwriteRejected: true }
    })
    await check('production-read-only-policy-discards-disk-and-denies-import', async () => {
      setSandboxMode(agent.session, 'read-only')
      const transient = await execute(`printf '%s\\n' temporary > '${state}'\ncat '${state}'`, false)
      assert.equal(transient.output.trim(), 'temporary')
      const preserved = await execute(`cat '${state}'`, false)
      assert.equal(preserved.output.trim(), token)
      const before = requests.length
      const denied = await invoke('linux_import', { source, destination: `readonly/${source}` })
      assert.equal(denied.isError, true)
      assert.equal(requests.length, before, 'Read-only import must be rejected before native dispatch')
      assert.match(JSON.stringify(denied), /writable session policy/)
      const deniedExport = await invoke('linux_export', { source: destination, destination: `readonly-${exportedName}` })
      assert.equal(deniedExport.isError, true); assert.equal(requests.length, before)
      return { diskCommitted: preserved.diskCommitted, importRejectedBeforeNative: true, exportRejectedBeforeNative: true }
    })
    await check('workflow-child-linux-import-exec-export', async () => {
      setSandboxMode(agent.session, 'workspace-write')
      return runLinuxWorkflowAcceptance({ ctx, transport, agent, adapter, workflow, requests,
        source, content, sha256, destination: childExport, workspace, appWorkspaceRoot })
    })
    return { suite: 'linux', checks, passed: checks.filter(item => item.status === 'passed').length,
      failed: checks.filter(item => item.status === 'failed').length,
      unverified: ['Guest networking', 'Process-death import recovery'] }
  } finally {
    setSandboxMode(agent.session, 'workspace-write')
    await owner.dispose()
    await unlink(hostFile)
    try { await unlink(exportedFile) } catch (error) { if (error?.code !== 'ENOENT') throw error }
    try { await unlink(join(workspace, childExport)) } catch (error) { if (error?.code !== 'ENOENT') throw error }
  }
}

const inheritedTools = ['read', 'glob', 'grep', 'write', 'edit', 'web_search', 'web_fetch',
  'linux_exec', 'linux_import', 'linux_export', 'linux_inspect']

async function runLinuxWorkflowAcceptance({ ctx, transport, agent, adapter, workflow, requests,
  source, content, sha256, destination, workspace, appWorkspaceRoot }) {
  const expected = Buffer.concat([Buffer.from('child processed\n'), content])
  const expectedHash = createHash('sha256').update(expected).digest('hex')
  const guestInput = 'acceptance/input.txt', guestOutput = 'acceptance/output.txt'
  const calls = [
    { name: 'linux_import', args: { source, destination: guestInput, timeoutMs: 120000 } },
    { name: 'linux_exec', args: { command: `printf 'child processed\\n' > '${guestOutput}'\ncat '${guestInput}' >> '${guestOutput}'\nsha256sum '${guestOutput}'`, timeoutMs: 120000 } },
    { name: 'linux_export', args: { source: guestOutput, destination, timeoutMs: 120000 } },
  ]
  const visible = inheritedTools.filter(name => ctx.tools.get(name, agent)).sort()
  const children = []
  const unregister = ctx.on('subagent/start', info => { children.push(ctx.agents.get(info.id)) })
  const requestStart = requests.length
  let step = 0
  const toolResults = () => children[0].session.snapshotEvents().filter(event => event.type === 'tool/result')
  adapter.scriptedStream = async function* (options) {
    assert.deepEqual((options.tools ?? []).map(tool => tool.name).sort(), visible)
    assert.equal(children.length, 1)
    const child = children[0]
    assert.ok(child)
    assert.notEqual(child.id, agent.id)
    for (const { name } of calls) {
      assert.equal(ctx.tools.get(name, child), ctx.tools.get(name, agent))
      assert.notEqual(ctx.tools.registrationIdentity(name, child), ctx.tools.registrationIdentity(name, agent))
    }
    assert.equal(toolResults().length, step)
    for (const row of toolResults()) assert.equal(row.data.message.isError, false, JSON.stringify(row.data))
    assert.ok(step <= calls.length, 'Scripted child requested an unexpected model turn')
    if (step < calls.length) {
      const call = calls[step++], id = `device-child-linux-${step}`
      const argumentsJson = JSON.stringify(call.args)
      yield { type: 'block-start', index: 0, blockType: 'tool-call' }
      yield { type: 'tool-call-delta', index: 0, id, name: call.name, argumentsDelta: argumentsJson }
      yield { type: 'block-end', index: 0, block: { type: 'tool-call', id, name: call.name, arguments: argumentsJson } }
      yield { type: 'finish', reason: { kind: 'tool-calls' } }
    } else {
      step++
      const text = 'device Linux child completed'
      yield { type: 'block-start', index: 0, blockType: 'text' }
      yield { type: 'text-delta', index: 0, text }
      yield { type: 'block-end', index: 0, block: { type: 'text', text } }
      yield { type: 'finish', reason: { kind: 'stop' } }
    }
  }
  try {
    const result = await ctx.tools.execute({ name: 'workflow', agent, callId: `linux-child-${randomUUID()}`,
      arguments: { script: "return await agent('Process the acceptance file with the authorized Linux tools')",
        meta: { name: 'device-linux-child', description: 'Import, process and export one acceptance file' } },
      signal: AbortSignal.timeout(120000) })
    assert.equal(result.isError, false, JSON.stringify(result.error ?? result).slice(0, 1500))
    assert.equal(result.value.result, 'device Linux child completed')
    assert.equal(step, 4)
    const child = children[0], childSessionId = String(child.session.id)
    assert.notEqual(childSessionId, String(agent.session.id))
    assert.equal(ctx.agents.get(child.id), undefined, 'Completed workflow must retire its child')
    const childRequests = requests.slice(requestStart)
    assert.deepEqual(childRequests.map(row => row.method), [
      'native.linuxVm.inspect', 'native.linuxVm.importFile', 'native.linuxVm.execute', 'native.linuxVm.exportFile',
    ])
    assert.deepEqual(childRequests[0].params, { sessionId: childSessionId })
    assert.equal(childRequests[0].result.sessionId, childSessionId)
    assert.ok(['absent', 'ready'].includes(childRequests[0].result.status))
    assert.equal(childRequests[0].result.blocked, false)
    assert.equal(childRequests[0].result.needsReview, false)
    assert.deepEqual(childRequests[0].result.records, [])
    const executed = childRequests.slice(1)
    for (const { params, result: receipt } of executed) {
      assert.equal(params.sessionId, childSessionId)
      assert.equal(receipt.sessionId, childSessionId)
      assert.equal(receipt.status, 'completed')
      assert.equal(receipt.exitCode, 0)
      assert.equal(receipt.retirementConfirmed, true)
      assert.ok(Number.isInteger(receipt.guestUid))
      assert.notEqual(receipt.guestUid, process.getuid())
    }
    assert.equal(executed[0].params.source, relative(appWorkspaceRoot, join(workspace, source)).split(sep).join('/'))
    assert.equal(executed[0].result.sha256, sha256)
    assert.equal(executed[0].result.bytes, content.length)
    assert.equal(executed[0].result.diskCommitted, true)
    assert.equal(executed[1].params.persistChanges, true)
    assert.equal(executed[1].result.diskCommitted, true)
    assert.equal(executed[1].result.output.trim().split(/\s+/u)[0], expectedHash)
    assert.equal(executed[2].result.diskCommitted, false)
    assert.equal(executed[2].params.destination, relative(appWorkspaceRoot, join(workspace, destination)).split(sep).join('/'))
    assert.equal(executed[2].result.filePublished, true)
    assert.equal(executed[2].result.sha256, expectedHash)
    assert.equal(executed[2].result.bytes, expected.length)
    assert.deepEqual(await readFile(join(workspace, destination)), expected)
    const reader = await ctx.sessionPersistence.open(child.session.id, 'read')
    let events
    try { ({ events } = await reader.read(0, 10000)) } finally { await reader.close() }
    const rows = events.filter(event => event.type === 'tool/result')
    assert.equal(rows.length, 3)
    for (const row of rows) assert.equal(row.data.message.isError, false)
    const receipts = events.flatMap(event => event.type === 'agent/inbox/spliced' ? event.data.inserted : [])
      .filter(message => message.source.kind === 'android-linux-receipt')
      .map(message => JSON.parse(message.content[0].text).linuxVmReceipt)
    assert.equal(receipts.length, 3)
    assert.deepEqual(receipts.map(receipt => receipt.tool), calls.map(call => call.name))
    for (const [index, receipt] of receipts.entries()) {
      assert.equal(receipt.sessionId, childSessionId)
      assert.equal(receipt.runId, executed[index].result.id)
      assert.equal(receipt.status, 'completed')
      assert.equal(receipt.retirementConfirmed, true)
      assert.equal(receipt.cancelRequested, false)
      assert.equal(receipt.diskCommitted, index < 2)
    }
    assert.equal(receipts[2].filePublished, true)
    assert.equal(receipts[2].sha256, expectedHash)
    const runId = result.value.runId
    assert.equal((await workflow.owner.inspectRun({ sessionId: agent.id, runId })).state, 'completed')
    const native = await transport.request('native.workflow.inspect', { runId })
    assert.equal(native.state, 'COMPLETED')
    assert.deepEqual(native.children, [{ childId: child.id, state: 'RETIRED' }])
    const starts = agent.session.snapshotEvents().filter(event => event.type === 'tool-workflow/agent-start'
      && event.data.runId === runId)
    assert.equal(starts.length, 1)
    assert.equal(starts[0].data.childId, child.id)
    return { runId, childSessionId, parentSessionId: String(agent.session.id), bytes: expected.length,
      sha256: expectedHash, durableReceipts: receipts.length,
      childLogSha256: createHash('sha256').update(JSON.stringify(events)).digest('hex'),
      guestUids: executed.map(row => row.result.guestUid), childRetired: true, nativeState: native.state }
  } finally { adapter.scriptedStream = null; unregister() }
}
