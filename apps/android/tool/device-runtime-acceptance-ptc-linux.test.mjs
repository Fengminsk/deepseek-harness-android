import assert from 'node:assert/strict'
import test from 'node:test'
import { createHash, randomUUID } from 'node:crypto'
import { runInNewContext } from 'node:vm'
import { mkdtemp, mkdir, readdir, readFile, writeFile, rm } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import SandboxPolicy from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { isFirstPartyLinuxDefinition } from '../runtime/tool-linux-vm.mjs'
import { ptcLinuxProgram, runPtcLinuxAcceptance, validatePtcLinuxEvidence, ptcLinuxFailureDiagnostics,
  readPtcLinuxFailureDispatch, PtcLinuxAcceptanceFailure } from './device-runtime-acceptance/ptc-linux.mjs'

const sha = value => createHash('sha256').update(value).digest('hex')
const names = ['linux_import', 'linux_exec', 'linux_export', 'linux_inspect']

// Synthetic observations test only the evidence validator. They are never
// emitted as a device report or used as native execution/retirement proof.
function evidence() {
  const sessionId = `validator-${randomUUID()}`, appUid = 10100
  const inputBytes = Buffer.from('[2,3,5]'), expectedBytes = Buffer.from('{"sum":10}\n')
  const paths = { hostInput: '/app/fixture/input.json', hostOutput: '/app/fixture/result.json',
    guestInput: 'private/input.json', guestOutput: 'private/result.json',
    nativeInput: 'fixture/input.json', nativeOutput: 'fixture/result.json' }
  const settled = (index, extra = {}) => ({ id: randomUUID(), sessionId, status: 'completed',
    exitCode: 0, retirementConfirmed: true, diskCommitted: index < 2, guestUid: 99001 + index,
    output: '', ...extra })
  const imported = settled(0, { bytes: inputBytes.length, sha256: sha(inputBytes) })
  const executed = settled(1, { output: `${sha(expectedBytes)}\n` })
  const exported = settled(2, { filePublished: true, bytes: expectedBytes.length, sha256: sha(expectedBytes) })
  const inspection = { sessionId, status: 'ready', blocked: false, needsReview: false,
    requestedRunFound: true, records: [{ runId: exported.id, operation: 'export', state: 'completed',
      filePublished: true, diskCommitted: false, retirementConfirmed: true }] }
  const requests = [
    { method: 'native.linuxVm.inspect', params: { sessionId }, result: { sessionId, status: 'absent', blocked: false, needsReview: false, records: [] } },
    { method: 'native.linuxVm.importFile', params: { id: imported.id, sessionId, source: paths.nativeInput, destination: paths.guestInput }, result: imported },
    { method: 'native.linuxVm.execute', params: { id: executed.id, sessionId, persistChanges: true }, result: executed },
    { method: 'native.linuxVm.exportFile', params: { id: exported.id, sessionId, source: paths.guestOutput, destination: paths.nativeOutput }, result: exported },
    { method: 'native.linuxVm.inspect', params: { sessionId, id: exported.id }, result: inspection },
  ]
  const values = [imported, executed, exported].map(value => ({ ...value, cancelRequested: false }))
  values[2].file_path = paths.hostOutput
  values.push(inspection)
  const contexts = values.map((value, index) => ({ source: { kind: index < 3 ? 'android-linux-receipt' : 'android-linux-inspection' },
    content: [{ type: 'text', text: JSON.stringify(index < 3 ? { linuxVmReceipt: { ...value,
      tool: names[index], callId: `parent:ptc:${index}`, runId: value.id } } : { linuxVmInspection: value }) }] }))
  const liveEvents = values.flatMap((value, index) => [
    { seq: index * 2, type: 'tool/ptc-dispatch-start', data: { name: names[index], subCallId: `parent:ptc:${index}` } },
    { seq: index * 2 + 1, type: 'tool/ptc-dispatch', data: { name: names[index], subCallId: `parent:ptc:${index}`,
      isError: false, content: [{ type: 'text', text: JSON.stringify(value) }], additionalContexts: [contexts[index]] } },
  ])
  return { sessionId, appUid, inputBytes, expectedBytes, ...paths,
    result: { isError: false, value: { result: { imported: values[0], executed: values[1], exported: values[2],
      inspection, ambient: { process: 'undefined', fetch: 'undefined' } } }, additionalContexts: contexts },
    settlement: { runId: randomUUID(), state: 'COMPLETED', guestUid: 99000 }, requests,
    liveEvents, durableEvents: structuredClone(liveEvents), fileBytes: Buffer.from(expectedBytes) }
}

test('validator retains independent file, retirement, isolated UID and durable Session facts', () => {
  const input = evidence(), result = validatePtcLinuxEvidence(input)
  assert.equal(result.sha256, sha(input.fileBytes))
  assert.equal(result.durableReceipts, 3); assert.equal(result.durableDispatches, 4)
  assert.deepEqual(result.linuxRunIds, input.requests.slice(1, 4).map(row => row.result.id))
  assert.equal(result.coldInspection, 'absent')
})

for (const [name, corrupt] of [
  ['native retirement', e => { e.requests[2].result.retirementConfirmed = false }],
  ['PTC retirement', e => { e.settlement.state = 'RETIRE_UNCONFIRMED' }],
  ['App UID isolation', e => { e.settlement.guestUid = e.appUid }],
  ['two simultaneous guest UIDs', e => { e.requests[1].result.guestUid = e.settlement.guestUid }],
  ['actual exported bytes', e => { e.fileBytes = Buffer.from('wrong file') }],
  ['cold-start inspection', e => { e.requests[0].result.status = 'ready' }],
  ['durable Session publication', e => { e.durableEvents.pop() }],
  ['parent deferred contexts', e => { e.result.additionalContexts = [] }],
  ['native same-Session scope', e => { e.requests[2].params.sessionId = 'other-session' }],
  ['independent disk/publication facts', e => { e.requests[3].result.diskCommitted = true }],
  ['explicit export publication', e => { e.result.value.result.exported.filePublished = null }],
]) {
  test(`validator refuses missing or contradictory ${name}`, () => {
    const input = evidence(); corrupt(input)
    assert.throws(() => validatePtcLinuxEvidence(input))
  })
}

test('device guest program stops dependent Linux work after unconfirmed import, execution or export', async () => {
  const code = ptcLinuxProgram({ source: 'input.json', destination: 'output.json',
    guestInput: 'private/input.json', guestOutput: 'private/output.json' })
  const program = runInNewContext(`(async function(tools){${code}})`)
  for (const failedIndex of [0, 1, 2]) {
    const calls = []
    const tools = Object.fromEntries(names.map((name, index) => [name, async args => {
      calls.push({ name, args })
      return { status: 'completed', exitCode: 0, retirementConfirmed: index !== failedIndex,
        diskCommitted: index < 2, filePublished: true, id: randomUUID() }
    }]))
    await assert.rejects(program(tools), /not confirmed; stop without retry/u)
    assert.deepEqual(calls.map(call => call.name), names.slice(0, failedIndex + 1))
    for (const call of calls) assert.equal(call.args.timeoutMs, 120000)
  }
})

test('fixture unregisters original Linux definitions and restores policy when the PTC caller fails', async t => {
  const root = await mkdtemp(join(tmpdir(), 'ptc-device-registration-')), workspace = join(root, 'workspace')
  await mkdir(workspace)
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode: 'read-only', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  await ctx.plugin(AgentLoop, { agents: [] })
  const agent = await ctx.agentLoop.create(SessionId(`registration-${randomUUID()}`), {}, { cwd: workspace })
  let entered = 0
  const invoke = async code => {
    entered++
    assert.match(code, /python3 - /u)
    assert.equal(ctx.sandboxPolicy.resolve({ session: agent.session }).mode, 'workspace-write')
    for (const name of names) assert.equal(isFirstPartyLinuxDefinition(ctx.tools.get(name, agent), agent), true)
    assert.equal((await readdir(workspace)).length, 1)
    throw new Error('Deliberate PTC caller failure before native dispatch')
  }
  // No simulated native success: this host check stops before any VM is called.
  const transport = { request() { throw new Error('Unexpected native request in registration-only test') } }
  for (let attempt = 0; attempt < 2; attempt++) {
    await assert.rejects(runPtcLinuxAcceptance({ ctx, transport, agent, workspace, appWorkspaceRoot: root,
      nativeModule: name => import(`../runtime/${name}`), invoke, settlements: [] }), error => {
      assert.ok(error instanceof PtcLinuxAcceptanceFailure)
      assert.match(error.message, /Deliberate PTC caller failure/u)
      assert.equal(error.diagnostics.phase, 'ptc-invoke')
      assert.deepEqual(error.diagnostics.requests, [])
      assert.deepEqual(error.diagnostics.settlements, [])
      assert.deepEqual(error.diagnostics.cleanup, { linuxOwner: { state: 'closed' }, registrations: { state: 'closed' } })
      return true
    })
    assert.equal(ctx.sandboxPolicy.resolve({ session: agent.session }).mode, 'read-only')
    for (const name of names) assert.equal(ctx.tools.get(name, agent), undefined)
    assert.deepEqual(await readdir(workspace), [])
  }
  assert.equal(entered, 2, 'Later all-mode suites can register their own Linux owner')
})

test('the exact device Python body analyzes actual host files; this is script evidence, not native evidence', async t => {
  const root = await mkdtemp(join(tmpdir(), 'ptc-device-python-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, 'private'))
  const input = Buffer.from(JSON.stringify({ values: [2, 3, 5, 12], nonce: 'host-script-only' }))
  await writeFile(join(root, 'private/input.json'), input)
  const code = ptcLinuxProgram({ source: 'input.json', destination: 'output.json',
    guestInput: 'private/input.json', guestOutput: 'private/output.json' })
  const program = runInNewContext(`(async function(tools){${code}})`)
  let command
  await assert.rejects(program({
    async linux_import() { return { status: 'completed', exitCode: 0, retirementConfirmed: true, diskCommitted: true } },
    async linux_exec(args) { command = args.command; throw new Error('Capture Python script only') },
  }), /Capture Python script only/u)
  const match = /^python3 - <<'DSH_PTC_LINUX_ANALYSIS'\n([\s\S]+)\nDSH_PTC_LINUX_ANALYSIS$/u.exec(command)
  assert.ok(match)
  const run = spawnSync('python', ['-'], { cwd: root, input: match[1], encoding: 'utf8', timeout: 10000, windowsHide: true })
  assert.equal(run.error, undefined)
  assert.equal(run.status, 0, run.stderr)
  const bytes = await readFile(join(root, 'private/output.json'))
  assert.equal(run.stdout.trim(), sha(bytes))
  assert.deepEqual(JSON.parse(bytes.toString()), { count: 4, sum: 22, sourceSha256: sha(input), nonce: 'host-script-only' })
})

test('failure diagnostics distinguish pending native RPC and durable dispatch without copying sensitive or large content', () => {
  const e = evidence(), secret = 'unrelated-path-token-command-output', huge = secret.repeat(100000)
  const requests = e.requests.map((row, index) => ({ ...row, startedAtMs: index,
    completedAtMs: index + 1, params: { ...row.params, command: huge, source: huge },
    result: { ...row.result, output: huge, detail: huge } }))
  requests[2].result = null; delete requests[2].completedAtMs
  const live = structuredClone(e.liveEvents)
  for (const row of live) row.data.arguments = { content: huge }
  const diagnostic = ptcLinuxFailureDiagnostics({ phase: 'ptc-invoke', startedAt: Date.now(), requests,
    settlements: [{ ...e.settlement, detail: huge, outputJson: huge, token: huge }],
    liveEvents: live, durableEvents: e.durableEvents.slice(0, 3), durableRead: { state: 'read' } })
  assert.equal(diagnostic.requests[2].observation, 'pending')
  assert.equal(diagnostic.requests[2].completedAtMs, null)
  assert.equal(diagnostic.requests[1].observation, 'returned')
  assert.equal(diagnostic.liveDispatch.length, 8)
  assert.equal(diagnostic.durableDispatch.length, 3)
  assert.equal(diagnostic.settlements[0].state, 'COMPLETED')
  const encoded = JSON.stringify(diagnostic)
  assert.ok(encoded.length < 8192)
  assert.ok(!encoded.includes(secret))
})

test('failure diagnostic reads are bounded, read-only and close their independent Session reader', async () => {
  let closed = 0, flushes = 0
  const started = Date.now()
  const ctx = { sessions: { flush() { flushes++; throw new Error('diagnostics must not flush') } },
    sessionPersistence: { async open(id, access) {
      assert.equal(id, 'diagnostic-session'); assert.equal(access, 'read')
      return { async read(offset, count, { signal }) {
        assert.equal(offset, 7); assert.equal(count, 64)
        await new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }))
      }, async close() { closed++ } }
    } } }
  const result = await readPtcLinuxFailureDispatch(ctx, { id: 'diagnostic-session' }, 7)
  assert.equal(result.state, 'timed-out')
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(closed, 1); assert.equal(flushes, 0)
  assert.ok(Date.now() - started < 4000)
})
