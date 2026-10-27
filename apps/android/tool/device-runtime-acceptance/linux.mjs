import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises'
import { join, relative, isAbsolute, sep } from 'node:path'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'

/** Exercise production ToolRuntime and Linux native ownership using only acceptance-owned files. */
export async function runLinuxAcceptance({ ctx, transport, agent, workspace, appWorkspaceRoot, nativeModule }) {
  assert.equal(ctx.agents.get(agent.id), agent)
  assert.equal(typeof appWorkspaceRoot, 'string', 'Acceptance requires the explicit production App workspace root')
  const scope = relative(appWorkspaceRoot, workspace)
  assert.ok(scope && !isAbsolute(scope) && scope !== '..' && !scope.startsWith(`..${sep}`))
  const [{ NativeLinuxVm }, { registerLinuxVmTool, registerLinuxImportTool, registerLinuxExportTool }] = await Promise.all([
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
    requests.push({ method, persistChanges: params.persistChanges })
    return transport.request(method, params, signal)
  } })
  registerLinuxVmTool(ctx, owner, true)
  registerLinuxImportTool(ctx, owner, true, appWorkspaceRoot)
  registerLinuxExportTool(ctx, owner, true, appWorkspaceRoot)
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
  try {
    await check('production-tool-shell-and-session-persistence', async () => {
      const first = await execute(`uname -sm\nprintf '%s\\n' '${token}' > '${state}'\ncat '${state}'`)
      assert.match(first.output, /Linux/)
      assert.ok(first.output.includes(token))
      const next = await execute(`cat '${state}'`)
      assert.equal(next.output.trim(), token)
      return { guestUid: next.guestUid, appUid: process.getuid(), diskCommitted: next.diskCommitted }
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
    return { suite: 'linux', checks, passed: checks.filter(item => item.status === 'passed').length,
      failed: checks.filter(item => item.status === 'failed').length,
      unverified: ['Python and analyst package availability', 'Guest networking', 'Process-death import recovery'] }
  } finally {
    setSandboxMode(agent.session, 'workspace-write')
    await owner.dispose()
    await unlink(hostFile)
    try { await unlink(exportedFile) } catch (error) { if (error?.code !== 'ENOENT') throw error }
  }
}
