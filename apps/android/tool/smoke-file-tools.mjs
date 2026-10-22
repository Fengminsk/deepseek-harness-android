import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { glob, mkdir, mkdtemp, readFile, readdir, symlink, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// Real staged Android profile, Agent loop, tool registry, filesystem provider,
// observation policy, approvals and recorder. Only the model HTTP responses and
// native platform services are fixtures. Never read a user's home/credentials.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/file-tools-profile-'))
const workspace = join(home, 'workspace'), outside = join(home, 'outside'), scratch = join(home, 'runtime-temp')
const sessionId = 'file-tools-fixture'
for (const path of [workspace, outside, scratch]) await mkdir(path)
// A deliberately invalid local Git marker stops discovery at this fixture;
// the original recorder must take its non-repository file-intent path.
await writeFile(join(workspace, '.git'), 'gitdir: ../not-a-repository\n')
await writeFile(join(workspace, 'protected.txt'), 'initial\n')
await writeFile(join(workspace, 'repeated.txt'), 'same\nsame\n')
await writeFile(join(workspace, 'binary.dat'), Buffer.from([0, 255, 1, 2]))
await symlink(outside, join(workspace, 'outside-link'), process.platform === 'win32' ? 'junction' : 'dir')

const createText = '第一行\r\nbefore\r\n尾行\r\n'
const success = 'FILE_TOOLS_COMPLETE'
const escalation = { sandbox_permissions: 'danger-full-access', justification: '修改本次合成测试明确指定的工作区外文件。' }
const steps = [
  ['write', { file_path: 'created.txt', content: createText }],
  ['edit', { file_path: 'created.txt', old_string: 'before', new_string: 'after' }],
  ['read', { file_path: 'created.txt' }],
  ['write', { file_path: 'protected.txt', content: 'blind overwrite\n' }],
  ['read', { file_path: 'protected.txt' }],
  ['write', { file_path: 'protected.txt', content: 'stale overwrite\n' }],
  ['read', { file_path: 'protected.txt' }],
  ['edit', { file_path: 'protected.txt', old_string: 'external change', new_string: 'recovered' }],
  ['read', { file_path: 'repeated.txt' }],
  ['edit', { file_path: 'repeated.txt', old_string: 'same', new_string: 'changed' }],
  ['edit', { file_path: 'repeated.txt', old_string: 'same', new_string: 'changed', replace_all: true }],
  ['write', { file_path: join(outside, 'denied.txt'), content: 'must not exist\n' }],
  ['write', { file_path: 'outside-link/symlink-denied.txt', content: 'must not exist\n' }],
  ['write', { file_path: join(outside, 'rejected.txt'), content: 'must not exist\n', ...escalation }],
  ['write', { file_path: join(outside, 'allowed.txt'), content: 'allowed once\n', ...escalation }],
  ['write', { file_path: join(outside, 'allowed.txt'), content: 'must not overwrite\n' }],
  ['read', { file_path: 'binary.dat' }],
  ['read', { file_path: 'missing.txt' }],
  ['write', { file_path: 'missing.txt', content: 'created after missing read\n' }],
]
const processes = new FixtureProcesses(), runtimes = [], vault = new Map(), failed = Promise.withResolvers()
let phase = 'setup', deadline, activeScenario = 'main', agentCalls = 0, totalCalls = 0
const counts = { main: 0, approvalCancel: 0, atomicCancel: 0, recovery: 0 }
const checkpoint = value => { phase = value; console.error(`[file-tools-profile] ${value}`) }
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    assert.ok(++totalCalls <= 40, 'Synthetic model requests must remain bounded')
    let block = { type: 'text', text: 'Synthetic file tools title' }
    if (body.tools?.some(tool => tool.name === 'android_shell')) {
      agentCalls++
      const names = body.tools.map(tool => tool.name)
      for (const name of ['read', 'write', 'edit']) assert.ok(names.includes(name), `Missing original ${name} tool`)
      const write = body.tools.find(tool => tool.name === 'write')
      assert.ok(JSON.stringify(write).includes('sandbox_permissions'), 'Original filesystem escalation must be advertised')
      const number = ++counts[activeScenario]
      const call = (name, input) => ({ type: 'tool_use', id: `files-${activeScenario}-${number}`, name, input })
      if (activeScenario === 'main') {
        // Simulate an external writer after the original read, before a stale
        // overwrite attempt. This does not stand in for a model file tool.
        if (number === 6) await writeFile(join(workspace, 'protected.txt'), 'external change\n')
        block = number <= steps.length ? call(...steps[number - 1]) : { type: 'text', text: success }
        assert.ok(number <= steps.length + 1)
      } else if (activeScenario === 'approvalCancel') {
        assert.equal(number, 1, 'Cancelling the owning turn must not replay the model')
        block = call('write', { file_path: join(outside, 'cancelled.txt'), content: 'must not exist\n', ...escalation })
      } else if (activeScenario === 'atomicCancel') {
        assert.equal(number, 1)
        block = call('write', { file_path: 'cancel-commit.txt', content: 'must never publish\n' })
      } else {
        assert.ok(number <= 2)
        block = number === 1 ? call('write', { file_path: 'after-cancel.txt', content: 'owner recovered\n' })
          : { type: 'text', text: 'FILE_TOOLS_RECOVERED' }
      }
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `file-model-${totalCalls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: block },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: block.type === 'tool_use' ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => { failed.reject(error); response.destroy(error) })
})

function environment() {
  const env = { ...process.env }
  for (const key of Object.keys(env)) if (/^(DSH_|DEEPSEEK_|OPENAI_|ANTHROPIC_|POCKET_)/i.test(key)) delete env[key]
  const origin = `http://127.0.0.1:${model.address().port}`
  return { ...env, DSH_HOME: home, DSH_AGENTS_HOME: join(home, '.agents'), DSH_TELEMETRY_DISABLED: '1',
    DEEPSEEK_BASE_URL: origin, POCKET_FILES_MODEL_ORIGIN: origin, TMP: scratch, TEMP: scratch, TMPDIR: scratch }
}

function launch() {
  const child = processes.spawn(process.execPath, ['--import', new URL('./file-tools-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')],
  { cwd: workspace, env: environment(), windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
  const pending = new Map(), notices = [], waiters = new Set()
  let serial = 0, closing = false, ended = false, failure, receipt, outstandingAtClose
  const lines = createInterface({ input: child.stdout })
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const rejectAll = error => {
    failure ??= error
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear(); waiters.clear()
  }
  const fail = error => { rejectAll(error); if (!closing) failed.reject(error); if (!ended) child.kill('SIGKILL') }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    ended = true
    const error = new Error(`File tools runtime exited: ${code ?? signal}`)
    rejectAll(error)
    if (!closing) failed.reject(error)
  })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (ended || failure) return
    try {
      const frame = JSON.parse(line)
      if (frame.method === 'fixture.unexpectedNetwork') throw new Error('Unexpected model endpoint')
      if (frame.method?.startsWith('native.')) {
        const { name, value } = frame.params ?? {}
        let result
        switch (frame.method) {
          case 'native.credentials.get': result = vault.get(name) ?? null; break
          case 'native.credentials.names': result = [...vault.keys()]; break
          case 'native.credentials.set': vault.set(name, value); result = true; break
          case 'native.credentials.remove': vault.delete(name); result = true; break
          case 'native.web.preferences': result = { enabled: false, scope: 'local', port: 3080 }; break
          case 'native.network.addresses': result = { addresses: [] }; break
          case 'native.storage.root': result = home; break
          default: throw new Error(`Unexpected native request ${frame.method}`)
        }
        send({ id: frame.id, result })
      } else if (pending.has(frame.id)) {
        const call = pending.get(frame.id); pending.delete(frame.id)
        if (frame.error) call.reject(new Error(`${call.method}: ${frame.error.message}`))
        else call.resolve(frame.result)
      } else {
        notices.push(frame)
        for (const waiter of waiters) if (waiter.predicate(frame)) { waiters.delete(waiter); waiter.resolve(frame) }
      }
    } catch (error) { fail(error) }
  })
  const runtime = {
    notices,
    request(method, params = {}) {
      if (ended || failure || closing) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const id = `files-${++serial}`
      return new Promise((resolve, reject) => { pending.set(id, { resolve, reject, method }); send({ id, method, params }) })
    },
    wait(predicate) {
      if (ended || failure) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const existing = notices.find(predicate)
      return existing ? Promise.resolve(existing) : new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
    },
    async close() {
      outstandingAtClose ??= { requests: pending.size, waiters: waiters.size }
      closing = true
      try { receipt = await processes.stop(child); return receipt } finally { lines.close() }
    },
    exitEvidence: () => ({ pid: child.pid, ended, ...receipt, outstandingAtClose, pending: pending.size, waiters: waiters.size }),
  }
  runtimes.push(runtime)
  return runtime
}

const event = (frame, type, turn) => frame.method === 'session.event' && frame.params.sessionId === sessionId
  && frame.params.event.type === type && frame.params.event.data.turn === turn
const resultFor = (events, callId) => {
  const result = events.find(item => item.type === 'tool/result' && item.data.message.toolCallId === callId)
  assert.ok(result, `Missing real tool result ${callId}`)
  return result.data
}
async function approval(runtime, callId) {
  const notice = await runtime.wait(frame => frame.method === 'interactions.changed'
    && frame.params.requests.some(request => request.sessionId === sessionId && request.callId === callId))
  return notice.params.requests.find(request => request.callId === callId)
}
async function send(runtime, marker, selectModel = false) {
  const result = await runtime.request('session.send', { sessionId, requestId: randomUUID(), text: marker,
    provider: 'deepseek-official', model: 'deepseek-flash', selectModel })
  assert.equal(result.accepted, true, JSON.stringify(result))
}
async function filesUnder(path) { return await Array.fromAsync(glob('**/*', { cwd: path })) }
async function logHashes() {
  const hashes = {}
  for (const path of await Array.fromAsync(glob('sessions/**/session.v*.jsonl', { cwd: home }))) {
    hashes[path] = createHash('sha256').update(await readFile(join(home, path))).digest('hex')
  }
  return hashes
}
async function absent(path) { await assert.rejects(readFile(path), { code: 'ENOENT' }) }
async function ready(runtime) {
  await runtime.wait(frame => frame.method === 'runtime.ready')
  await runtime.wait(frame => frame.method === 'fixture.fileToolsReady')
  assert.equal((await runtime.request('runtime.info')).profile, 'android')
  assert.equal((await runtime.request('web.status')).phase, 'disabled')
}

async function scenario() {
  const runtime = launch()
  await ready(runtime)
  checkpoint('original create/read/edit, stale recovery, real bounds and original approvals')
  await runtime.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-file-fixture-only' })
  await send(runtime, 'FILE_MAIN', true)
  const denied = await approval(runtime, 'files-main-14')
  assert.equal(denied.toolName, 'write')
  assert.deepEqual(await runtime.request('interactions.reply', { id: denied.id, version: denied.version, response: 'rejected' }),
    { accepted: true, requestStillPending: false })
  const granted = await approval(runtime, 'files-main-15')
  assert.deepEqual(await runtime.request('interactions.reply', { id: granted.id, version: granted.version, response: 'allowed-once' }),
    { accepted: true, requestStillPending: false })
  await runtime.wait(frame => event(frame, 'turn/end', 1))
  const firstEvents = (await runtime.request('session.read', { sessionId })).events
  assert.equal(counts.main, steps.length + 1)
  assert.match(JSON.stringify(firstEvents), /FILE_TOOLS_COMPLETE/)
  for (const number of [4, 6, 10, 12, 13, 14, 16, 17, 18]) {
    assert.equal(resultFor(firstEvents, `files-main-${number}`).message.isError, true, `Tool ${number} must fail closed`)
  }
  for (const number of [1, 2, 3, 5, 7, 8, 9, 11, 15, 19]) {
    assert.equal(resultFor(firstEvents, `files-main-${number}`).message.isError, false, `Tool ${number} must succeed`)
  }
  for (const [number, code] of [[4, 'FS_NOT_OBSERVED'], [6, 'FS_STALE_VERSION'], [10, 'FS_AMBIGUOUS_EDIT'],
    [12, 'FS_SANDBOX_DENIED'], [13, 'FS_SANDBOX_DENIED'], [16, 'FS_SANDBOX_DENIED'], [17, 'FS_NOT_TEXT']]) {
    assert.match(JSON.stringify(resultFor(firstEvents, `files-main-${number}`)), new RegExp(code))
  }
  assert.deepEqual(firstEvents.filter(item => item.type === 'approval/decided').map(item => item.data.outcome), ['rejected', 'allowed-once'])
  assert.equal(await readFile(join(workspace, 'created.txt'), 'utf8'), createText.replace('before', 'after'))
  assert.equal(await readFile(join(workspace, 'protected.txt'), 'utf8'), 'recovered\n')
  assert.equal(await readFile(join(workspace, 'repeated.txt'), 'utf8'), 'changed\nchanged\n')
  assert.equal(await readFile(join(workspace, 'missing.txt'), 'utf8'), 'created after missing read\n')
  assert.equal(await readFile(join(outside, 'allowed.txt'), 'utf8'), 'allowed once\n')
  for (const name of ['denied.txt', 'symlink-denied.txt', 'rejected.txt']) await absent(join(outside, name))

  checkpoint('original no-Git intent summary and stable content diff')
  const changes = firstEvents.findLast(item => item.type === 'workspace/changes')
  assert.ok(changes)
  const coordinates = { owner: randomUUID(), requestId: randomUUID(), sessionId, seq: changes.seq }
  const summaryResult = await runtime.request('workspaceChanges.summary', coordinates)
  assert.equal(summaryResult.ok, true, JSON.stringify(summaryResult))
  const summary = summaryResult.value
  assert.equal(summary.total, 5)
  assert.ok(summary.files.some(file => file.path === 'created.txt'))
  const index = summary.files.findIndex(file => file.path === 'created.txt')
  const diff = await runtime.request('workspaceChanges.diff', { ...coordinates, requestId: randomUUID(), index })
  assert.equal(diff.ok, true, JSON.stringify(diff))
  assert.equal(diff.value.kind, 'text')
  assert.match(JSON.stringify(diff.value), /after/)

  checkpoint('cancel the owning turn while original approval is pending')
  activeScenario = 'approvalCancel'
  await send(runtime, 'FILE_APPROVAL_CANCEL')
  const cancelled = await approval(runtime, 'files-approvalCancel-1')
  await runtime.request('session.cancel', { sessionId })
  await runtime.wait(frame => event(frame, 'turn/end', 2))
  await absent(join(outside, 'cancelled.txt'))
  const late = await runtime.request('interactions.reply', { id: cancelled.id, version: cancelled.version, response: 'allowed-once' })
  assert.equal(late.accepted, false)
  const cancelEvents = (await runtime.request('session.read', { sessionId })).events
  assert.equal(cancelEvents.filter(item => item.type === 'approval/decided').at(-1).data.outcome, 'cancelled')

  checkpoint('cancel after actual bytes were staged, before atomic publication')
  activeScenario = 'atomicCancel'
  assert.equal(await runtime.request('fixture.armWrite'), true)
  await send(runtime, 'FILE_ATOMIC_CANCEL')
  const staged = await runtime.wait(frame => frame.method === 'fixture.writeStaged')
  assert.equal(await readFile(staged.params.tempPath, 'utf8'), 'must never publish\n')
  await absent(join(workspace, 'cancel-commit.txt'))
  const cancellation = runtime.request('session.cancel', { sessionId })
  await runtime.wait(frame => frame.method === 'fixture.writeAborted')
  assert.deepEqual(await runtime.request('fixture.releaseWrite'), { inspections: 1, aborts: 1 })
  await cancellation
  await runtime.wait(frame => event(frame, 'turn/end', 3))
  await absent(join(workspace, 'cancel-commit.txt'))
  await assert.rejects(readdir(staged.params.stagingDir), { code: 'ENOENT' })
  assert.equal((await filesUnder(workspace)).some(path => path.includes('.tmpdir')), false)

  checkpoint('same owner recovers after cancellation without replay')
  activeScenario = 'recovery'
  await send(runtime, 'FILE_RECOVERY')
  await runtime.wait(frame => event(frame, 'turn/end', 4))
  assert.equal(await readFile(join(workspace, 'after-cancel.txt'), 'utf8'), 'owner recovered\n')
  assert.deepEqual((await runtime.request('interactions.list')).requests, [])
  const published = runtime.notices.filter(frame => frame.method === 'fixture.filePublished').map(frame => frame.params.target).sort()
  assert.deepEqual(published, [join(workspace, 'created.txt'), join(workspace, 'missing.txt'),
    join(workspace, 'after-cancel.txt'), join(outside, 'allowed.txt')].sort())
  for (const directory of [workspace, outside]) {
    assert.equal((await filesUnder(directory)).some(path => /\.tmpdir|\.pocket-publish-/.test(path)), false)
  }
  const before = await logHashes(), callsBeforeRestart = agentCalls
  await runtime.close()

  checkpoint('cold restart keeps writes and original history, without replaying tools')
  const cold = launch()
  await ready(cold)
  const history = await cold.request('session.read', { sessionId })
  assert.match(JSON.stringify(history.events), /FILE_TOOLS_RECOVERED/)
  assert.equal(agentCalls, callsBeforeRestart)
  assert.deepEqual((await cold.request('runtime.live')).statuses, {})
  assert.deepEqual(await logHashes(), before)
  assert.equal(await readFile(join(workspace, 'created.txt'), 'utf8'), createText.replace('before', 'after'))
  const unavailable = await cold.request('workspaceChanges.summary', { ...coordinates, requestId: randomUUID() })
  assert.equal(unavailable.ok, false)
  assert.equal(unavailable.error.code, 'workspace-changes/unavailable')
  await cold.close()
  return { home, realAndroidProfile: true, originalFsTools: true, originalSandboxAndObservationPolicy: true,
    realFilesystemWrites: true, unicodeAndCRLF: true, blindOverwriteRejected: true, staleVersionRecovery: true,
    ambiguousEditAndReplaceAll: true, workspaceAndSymlinkBounds: true, originalApprovalOutcomes: true,
    grantIsOneInvocation: true, noGitIntentSummary: true, binaryReadRejected: true,
    pendingApprovalOwnerCancellation: true, atomicPublicationCancellation: true, noMutationStagingResidue: true,
    cancellationTiming: 'original fs-local inspectTemp test hook before publication', sameOwnerRecovery: true,
    copiedFilePublication: { count: published.length, nativeBoundary: 'host adapts renameat2 with exclusive link/unlink' },
    coldHistoryNoReplayOrRewrite: true, coldSnapshotsExplicitlyMissing: true, webEnabled: false,
    modelProvider: 'local synthetic SSE, original adapter and Agent loop', agentCalls, totalCalls, counts,
    androidBinderOrDevice: false, summary }
}

let report
try {
  model.listen(0, '127.0.0.1')
  await once(model, 'listening')
  report = await Promise.race([scenario(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`File tools profile exceeded 180 seconds during ${phase}`)), 180000)
  })])
} finally {
  clearTimeout(deadline)
  const cleanup = await Promise.allSettled([processes.close(), ...runtimes.map(runtime => runtime.close())])
  model.closeAllConnections()
  await new Promise(resolve => model.close(resolve))
  const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) throw new AggregateError(errors, 'File tools fixture cleanup failed')
}
const processExits = runtimes.map(runtime => runtime.exitEvidence())
for (const exit of processExits) {
  assert.equal(exit.ended, true)
  assert.equal(exit.error, undefined)
  assert.deepEqual(exit.outstandingAtClose, { requests: 0, waiters: 0 })
  assert.equal(exit.pending, 0)
  assert.equal(exit.waiters, 0)
}
assert.ok([...processes.records.values()].every(record => record.ended))
report = { ...report, processExits, ownedProcessesClosed: processes.records.size }
await writeFile(join(home, 'report.json'), JSON.stringify(report, null, 2) + '\n')
console.log(JSON.stringify(report))
