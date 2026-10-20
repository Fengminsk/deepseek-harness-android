import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { glob, mkdtemp, mkdir, readFile, realpath, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// Real staged Android composition and original storage. Only model HTTP, native
// credentials, ephemeral Web ports and the Windows sh executable are fixture-owned.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/library-profile-'))
const workspace = join(home, 'workspace')
await mkdir(workspace)
const vault = new Map(), runtimes = []
const processes = new FixtureProcesses()
const failed = Promise.withResolvers(), held = Promise.withResolvers()
const markers = { parent: 'POCKET_LIBRARY_PARENT', child: 'POCKET_LIBRARY_CHILD', hold: 'POCKET_LIBRARY_ACTIVE',
  shell: 'POCKET_LIBRARY_SHELL' }
let phase = 'starting', spawned = false, shellCalled = false, modelCalls = 0
const shellCommand = process.platform === 'win32' ? 'pwd -W' : 'pwd'
const checkpoint = value => { phase = value; console.error(`[library-profile] ${value}`) }
function scenario(body) {
  for (const message of [...body.messages ?? []].reverse()) {
    if (message.role !== 'user') continue
    const texts = typeof message.content === 'string' ? [message.content]
      : message.content?.flatMap(block => block.type === 'text' ? [block.text] : []) ?? []
    const match = texts.find(text => Object.values(markers).includes(text))
    if (match) return match
  }
}
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    modelCalls++
    assert.ok(modelCalls < 25, 'finite fixture must not replay or loop')
    const selected = scenario(body)
    if (selected === markers.hold) {
      held.resolve()
      await once(response, 'close')
      return
    }
    let block = { type: 'text', text: 'Library fixture completed.' }
    if (selected === markers.shell && !shellCalled && body.tools?.some(tool => tool.name === 'android_shell')) {
      shellCalled = true
      block = { type: 'tool_use', id: 'library-shell-call', name: 'android_shell', input: { command: shellCommand } }
    }
    if (selected === markers.parent && !spawned && body.tools?.some(tool => tool.name === 'subagent')) {
      spawned = true
      block = { type: 'tool_use', id: 'library-child-call', name: 'subagent',
        input: { description: 'Library child isolation', prompt: markers.child } }
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `library-model-${modelCalls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: block },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: block.type === 'tool_use' ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => { failed.reject(error); response.destroy(error) })
})
model.listen(0, '127.0.0.1')
await once(model, 'listening')

function launch() {
  const child = processes.spawn(process.execPath, ['--import', new URL('./library-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: workspace,
    env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1',
      ...(process.platform === 'win32' ? { POCKET_LIBRARY_TEST_SHELL: 'C:/Program Files/Git/bin/sh.exe' } : {}),
      DEEPSEEK_BASE_URL: `http://127.0.0.1:${model.address().port}` },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const pending = new Map(), notices = [], waiters = new Set()
  let ended = false, failure, requestSerial = 0
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const lines = createInterface({ input: child.stdout })
  const rejectAll = error => {
    failure ??= error
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear()
    waiters.clear()
  }
  const stop = error => { rejectAll(error); if (!ended) child.kill('SIGKILL') }
  child.once('error', error => { ended = true; rejectAll(error) })
  child.once('exit', (code, signal) => { ended = true; rejectAll(new Error(`Runtime exited: ${code ?? signal}`)) })
  child.stdin.on('error', stop)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (failure || ended) return
    try {
      const frame = JSON.parse(line)
      if (frame.method?.startsWith('native.')) {
        const { name, value } = frame.params ?? {}
        let result
        switch (frame.method) {
          case 'native.credentials.get': result = vault.get(name) ?? null; break
          case 'native.credentials.names': result = [...vault.keys()]; break
          case 'native.credentials.set': vault.set(name, value); result = true; break
          case 'native.credentials.remove': vault.delete(name); result = true; break
          case 'native.web.preferences': result = { enabled: false, scope: 'local', port: 3080 }; break
          case 'native.web.save': result = true; break
          case 'native.network.addresses': result = { addresses: [] }; break
          case 'native.storage.root': result = home; break
          default: throw new Error(`Unexpected native request ${frame.method}`)
        }
        send({ id: frame.id, result })
      } else if (pending.has(frame.id)) {
        const call = pending.get(frame.id)
        pending.delete(frame.id)
        if (frame.error) call.reject(new Error(`${call.method}: ${frame.error.message}`))
        else call.resolve(frame.result)
      } else {
        notices.push(frame)
        for (const waiter of waiters) if (waiter.predicate(frame)) {
          waiters.delete(waiter)
          waiter.resolve(frame)
        }
      }
    } catch (error) { stop(error) }
  })
  const runtime = {
    notices,
    request(method, params = {}) {
      if (ended || failure) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const id = `library-${++requestSerial}`
      return new Promise((resolve, reject) => { pending.set(id, { resolve, reject, method }); send({ id, method, params }) })
    },
    async library(method, params = {}) {
      const result = await runtime.request(`library.${method}`, params)
      assert.equal(result?._pocket_error, undefined, `${method}: ${JSON.stringify(result)}`)
      return result
    },
    wait(predicate) {
      if (ended || failure) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const existing = notices.find(predicate)
      return existing ? Promise.resolve(existing) : new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
    },
    async close() {
      try { return await processes.stop(child) } finally { lines.close() }
    },
    diagnostics: () => ({ pid: child.pid, pending: [...pending.values()].map(call => call.method), notices: notices.length }),
  }
  runtimes.push(runtime)
  return runtime
}
async function poll(read, predicate, label) {
  const until = performance.now() + 15000
  while (true) {
    const result = await read()
    if (predicate(result)) return result
    if (performance.now() >= until) throw new Error(`Timed out: ${label}`)
    await new Promise(resolve => setTimeout(resolve, 25))
  }
}
const events = (runtime, id) => runtime.notices.flatMap(frame =>
  frame.method === 'session.event' && frame.params.sessionId === id ? [frame.params.event] : [])
async function persisted(sessionId) {
  const files = await Array.fromAsync(glob(`sessions/**/${sessionId}/session.v4.jsonl`, { cwd: home }))
  if (!files.length) return []
  assert.equal(files.length, 1)
  return (await readFile(join(home, files[0]), 'utf8')).split('\n').slice(0, -1).filter(Boolean).map(JSON.parse)
}

async function closeFixture() {
  // Stop allocation before taking the runtime snapshot: a timed-out scenario can
  // still resume from its first generation's close and attempt the next launch.
  const processCleanup = processes.close()
  try {
    const results = await Promise.allSettled([processCleanup, ...runtimes.map(runtime => runtime.close())])
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
    if (errors.length) throw new AggregateError(errors, 'Library fixture cleanup did not complete')
  } finally {
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}

let deadline
try {
  await Promise.race([(async () => {
    const first = launch()
    await first.wait(frame => frame.method === 'runtime.ready')
    checkpoint('default initialization and read-only catalog')
    const initial = await first.library('catalog')
    assert.equal(initial.workspaces.length, 1)
    assert.equal(await realpath(initial.workspaces[0].path), await realpath(workspace))
    assert.deepEqual(initial.sessions, [])
    assert.equal(initial.capabilities.crossWorkspaceMove, false)
    const defaultId = initial.workspaces[0].workspaceId
    const directory = await first.library('directoryCreate', { path: initial.defaultDirectory, name: 'project-a' })
    assert.equal((await first.library('directoryList')).entries.some(entry => entry.path === directory.path), true)
    const files = async (method, params = {}) => {
      const result = await first.request(`workspace.files.${method}`, params)
      assert.equal(result?._pocket_error, undefined, `${method}: ${JSON.stringify(result)}`)
      return result
    }
    const fileInfo = await files('info')
    assert.equal(await realpath(fileInfo.root), await realpath(workspace))
    assert.ok(Number.isSafeInteger(fileInfo.limits.readPageBytes) && fileInfo.limits.readPageBytes >= 4)
    assert.ok(Number.isSafeInteger(fileInfo.limits.search.maxEntries) && fileInfo.limits.search.maxEntries > 0)
    const notePath = 'project-a/library-fixture-note.txt'
    const note = '中文🙂\n'.repeat(Math.ceil(fileInfo.limits.readPageBytes / 8) + 1)
    await writeFile(join(directory.path, 'library-fixture-note.txt'), note)
    const fileList = await files('list', { path: 'project-a' })
    assert.deepEqual(fileList.entries.map(entry => [entry.path, entry.kind]), [[notePath, 'file']])
    const firstPage = await files('read', { path: notePath })
    assert.equal(firstPage.eof, false)
    assert.ok(Buffer.byteLength(firstPage.text) <= fileInfo.limits.readPageBytes)
    let fullText = firstPage.text, page = firstPage
    while (!page.eof) {
      const next = await files('read', { path: notePath, offset: page.nextOffset, version: firstPage.version })
      assert.ok(next.nextOffset > page.nextOffset)
      fullText += next.text
      page = next
    }
    assert.equal(fullText, note, 'real RPC must preserve UTF-8 page boundaries')
    const found = await files('search', {
      requestId: randomUUID(), path: '', query: 'library-fixture-note', mode: 'name', caseSensitive: false,
    })
    assert.equal(found.complete, true)
    assert.deepEqual(found.matches.map(match => match.path), [notePath])
    assert.equal(found.limits.maxEntries, fileInfo.limits.search.maxEntries)
    const escaped = await first.request('workspace.files.read', { path: '../outside.txt' })
    assert.equal(escaped._pocket_error.code, 'workspace-files/invalid-path')
    const adopted = await first.library('workspaceCreate', { path: directory.path })
    const workspaceId = adopted.workspace.workspaceId
    assert.equal(adopted.created, true)
    assert.equal((await first.library('workspaceCreate', { path: directory.path })).created, false)
    await first.library('workspaceRename', { workspaceId, title: 'Project A' })
    await first.library('workspaceReorder', { workspaceId: defaultId, beforeWorkspaceId: workspaceId })
    assert.deepEqual((await first.library('catalog')).workspaces.map(item => item.workspaceId), [defaultId, workspaceId])
    const invalid = await first.request('library.workspaceCreate', { path: 'content://fixture/document/tree' })
    assert.equal(invalid._pocket_error.code, 'workspace/invalid-path')

    const parent = (await first.library('sessionCreate', { workspaceId, sessionId: 'library-parent' })).sessionId
    const sibling = (await first.library('sessionCreate', { workspaceId, sessionId: 'library-sibling' })).sessionId
    assert.notEqual(parent, sibling)
    const catalog = await first.library('catalog')
    assert.equal(await realpath(catalog.sessions.find(item => item.sessionId === parent).cwd), await realpath(directory.path))
    assert.equal(catalog.sessions.find(item => item.sessionId === parent).projections.values.workingDirectory, directory.path)
    await first.library('sessionReorder', { workspaceId, sessionId: parent, beforeSessionId: sibling })
    assert.deepEqual((await first.library('catalog')).workspaces.find(item => item.workspaceId === workspaceId).sessionIds, [parent, sibling])
    const crossMove = await first.request('library.sessionReorder', { workspaceId: defaultId, sessionId: parent })
    assert.equal(crossMove._pocket_error.code, 'workspace/move-invalid')
    const emptyFork = await first.request('library.sessionFork', { sessionId: parent })
    assert.equal(emptyFork._pocket_error.code, 'session/fork-unavailable')
    await first.library('sessionPin', { sessionId: parent, pinned: true })
    await first.library('sessionPin', { sessionId: sibling, pinned: true })
    assert.deepEqual((await first.request('sessions.list')).map(item => item.header.id), [sibling, parent])
    await first.library('sessionArchive', { sessionId: sibling, archived: true })
    assert.deepEqual((await first.request('sessions.list')).map(item => item.header.id), [parent])
    assert.deepEqual((await first.library('catalog')).pinnedSessionIds, [parent])

    checkpoint('original model turn, child isolation and exact user-message fork')
    await first.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-library-fixture-key' })
    const prompt = text => first.request('session.send', {
      sessionId: parent, requestId: text, text, provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true,
    })
    await prompt(markers.shell)
    const pending = await poll(() => first.request('interactions.list'), value =>
      value.requests.some(request => request.sessionId === parent && request.toolName === 'android_shell'), 'shell approval')
    const approval = pending.requests.find(request => request.sessionId === parent && request.toolName === 'android_shell')
    assert.equal(await realpath(approval.executionContext.cwd), await realpath(directory.path))
    assert.equal(JSON.parse(approval.toolCall.arguments).command, shellCommand)
    assert.equal(events(first, parent).some(event => event.type === 'tool/result'
      && event.data.message?.source.callId === approval.callId), false, 'shell must still wait for approval')
    assert.equal((await first.request('interactions.reply', {
      id: approval.id, version: approval.version, response: 'allowed-once',
    })).accepted, true)
    const shellFrame = await first.wait(frame => frame.method === 'session.event' && frame.params.sessionId === parent
      && frame.params.event.type === 'tool/result' && frame.params.event.data.message?.source.callId === approval.callId)
    const shellMessage = shellFrame.params.event.data.message
    assert.notEqual(shellMessage.isError, true, JSON.stringify(shellMessage))
    const shellOutput = JSON.parse(shellMessage.content.find(block => block.type === 'text').text)
    assert.equal(shellOutput.exitCode, 0)
    assert.equal(await realpath(shellOutput.stdout.trim()), await realpath(approval.executionContext.cwd))
    await poll(() => first.request('tasks.summary'), value => value.summary.running === 0, 'shell turn settlement')
    await prompt(markers.parent)
    const childFrame = await first.wait(frame => frame.method === 'session.event' && frame.params.sessionId === parent
      && frame.params.event.type === 'subagent/catalog')
    const childId = childFrame.params.event.data.childId
    await first.wait(frame => frame.method === 'session.event' && frame.params.sessionId === childId
      && frame.params.event.type === 'turn/end')
    await poll(() => first.request('tasks.summary'), value => value.summary.running === 0, 'parent and child settlement')
    assert.equal((await first.library('catalog')).sessions.some(item => item.sessionId === childId), false)
    assert.equal((await first.request('library.sessionArchive', { sessionId: childId, archived: true }))._pocket_error.code,
      'session/agent-busy')
    await first.library('sessionRename', { sessionId: parent, title: 'Library durable title' })
    const cut = events(first, parent).find(event => event.type === 'user/message' && event.data.source?.rpcId === markers.parent)
    assert.ok(cut, 'fork boundary must be the actual original user-message event')
    const fork = await first.library('sessionFork', { sessionId: parent, atSeq: cut.seq, allowMigration: false })
    const latestFork = await first.library('sessionFork', { sessionId: parent })
    assert.notEqual(fork.sessionId, latestFork.sessionId)
    const withForks = await first.library('catalog')
    for (const sessionId of [fork.sessionId, latestFork.sessionId]) {
      const summary = withForks.sessions.find(item => item.sessionId === sessionId)
      assert.equal(summary.parentSessionId, parent)
      assert.equal(summary.origin, undefined)
      assert.ok(withForks.workspaces.find(item => item.workspaceId === workspaceId).sessionIds.includes(sessionId))
    }
    const forkLog = await poll(() => persisted(fork.sessionId), rows => rows.length > cut.seq + 1, 'fork prefix persistence')
    assert.equal(forkLog[0].parentSession, parent)
    assert.equal(forkLog[0].origin, undefined)
    assert.ok(forkLog.some(event => event.type === 'user/message' && event.seq === cut.seq))
    assert.equal(forkLog.some(event => event.type === 'subagent/catalog'), false, 'the explicit cut must not include later child delegation')

    checkpoint('active archive refusal and explicit stop')
    await prompt(markers.hold)
    await held.promise
    const refused = await first.request('library.sessionArchive', { sessionId: parent, archived: true })
    assert.equal(refused._pocket_error.code, 'workspace/session-active')
    assert.ok(refused._pocket_error.details.activity.length > 0)
    assert.equal((await first.library('catalog')).archivedSessionIds.includes(parent), false)
    await first.library('sessionArchive', { sessionId: parent, archived: true, stopActivity: true })
    await poll(() => first.request('tasks.summary'), value => value.summary.running === 0, 'explicit archive stop')
    await first.library('sessionArchive', { sessionId: parent, archived: false })
    await first.library('sessionPin', { sessionId: parent, pinned: true })
    await first.library('sessionReorder', { workspaceId, sessionId: parent, beforeSessionId: fork.sessionId })
    const beforeRestart = await first.library('catalog')
    const finalSeq = events(first, parent).at(-1).seq
    await poll(() => persisted(parent), rows => rows.some(row => row.type === 'session/title'
      && row.data.title === 'Library durable title') && rows.at(-1)?.seq >= finalSeq,
    'final original session log')
    const modelCount = modelCalls
    await first.close()

    checkpoint('cold restart retains original registry state without activating or replaying')
    const second = launch()
    await second.wait(frame => frame.method === 'runtime.ready')
    const afterRestart = await second.library('catalog')
    assert.deepEqual(afterRestart.workspaces, beforeRestart.workspaces)
    assert.deepEqual(afterRestart.archivedSessionIds, beforeRestart.archivedSessionIds)
    assert.deepEqual(afterRestart.pinnedSessionIds, beforeRestart.pinnedSessionIds)
    assert.deepEqual(new Set(afterRestart.sessions.map(item => item.sessionId)), new Set(beforeRestart.sessions.map(item => item.sessionId)))
    assert.ok(afterRestart.sessions.every(item => !item.agentAvailable && !item.running))
    assert.equal(afterRestart.sessions.find(item => item.sessionId === parent).projections.values.title, 'Library durable title')
    assert.deepEqual((await second.request('runtime.live')).statuses, {})
    assert.equal((await second.request('sessions.list'))[0].header.id, parent)
    assert.equal((await second.request('sessions.list')).some(item => item.header.id === sibling || item.header.id === childId), false)
    assert.equal(modelCalls, modelCount, 'catalog/sidebars/restart must not replay requests')
    await second.library('sessionArchive', { sessionId: sibling, archived: false })
    assert.ok((await second.request('sessions.list')).some(item => item.header.id === sibling))
    assert.deepEqual((await second.request('runtime.live')).statuses, {}, 'unarchive only restores visibility')
    // The Web uses this same original remote namespace, not a second store.
    await second.request('api.call', { namespace: 'session', method: 'rename',
      args: { request: { sessionId: parent, title: 'Shared original API title' } } })
    assert.equal((await second.library('catalog')).sessions.find(item => item.sessionId === parent).projections.values.title,
      'Shared original API title')
    assert.equal((await second.request('sessions.list'))[0].title, 'Shared original API title')
    console.log(JSON.stringify({ realProfile: true, defaultPrivateWorkspace: true, originalDirectoryPicker: true,
      workspaceRegistrationAndOrder: true, sessionCwd: true, approvalAndExecutedShellCwd: true,
      shellExecutableFixture: process.platform === 'win32' ? 'Git sh' : '/bin/sh', originalPinArchiveOrder: true,
      childIsolation: true, originalExactAndCompletedFork: true, activeArchiveRequiresExplicitStop: true,
      processRecovery: true, coldReadDoesNotActivate: true, noRequestReplay: true,
      titleRecovery: true, sharedOriginalApi: true, privateWorkspaceFilesRpc: true,
      utf8ReadPages: true, boundedFilenameSearch: true, home }))
  })(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Library profile timed out at ${phase}: ${
      JSON.stringify(runtimes.map(runtime => runtime.diagnostics()))}`)), 180000)
  })])
} finally {
  clearTimeout(deadline)
  await closeFixture()
}
