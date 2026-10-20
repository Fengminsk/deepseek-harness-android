import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { resolve, join } from 'node:path'
import { createInterface } from 'node:readline'

const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/interactions-'))
await mkdir(join(home, 'workspace'))
await mkdir(join(home, 'native-attachment-cache'))
const modelSteps = []
let modelRequests = 0
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString('utf8'))
    modelRequests++
    const agent = body.tools?.some(tool => tool.name === 'smoke_approval')
    const step = agent ? modelSteps.shift() : undefined
    const block = step ? { type: 'tool_use', id: step.id, name: step.tool, input: step.args }
      : { type: 'text', text: 'interaction complete' }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `fixture-${Date.now()}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: block },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: step ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => response.destroy(error))
})
model.listen(0, '127.0.0.1')
await once(model, 'listening')
const child = spawn(process.execPath, ['--import', new URL('./interaction-smoke-loader.mjs', import.meta.url).href,
  join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
  cwd: join(home, 'workspace'), env: { ...process.env, DSH_HOME: home,
    DSH_TELEMETRY_DISABLED: '1', DEEPSEEK_BASE_URL: `http://127.0.0.1:${model.address().port}` }, stdio: ['pipe', 'pipe', 'pipe'],
})
const exited = once(child, 'exit')
const records = new Map(), pending = new Map(), notices = [], waiters = []
const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
let serial = 0
const request = (method, params = {}) => {
  const id = `interaction-${++serial}`
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ id, method, params }) })
}
const waitFor = predicate => {
  const found = notices.find(predicate)
  if (found) return Promise.resolve(found)
  return new Promise(resolve => waiters.push({ predicate, resolve }))
}
const lines = createInterface({ input: child.stdout })
child.stderr.pipe(process.stderr)
lines.on('line', line => {
  const frame = JSON.parse(line)
  if (frame.method?.startsWith('native.credentials.')) {
    const { name, value } = frame.params
    let result = null
    if (frame.method === 'native.credentials.get') result = records.get(name) ?? null
    else if (frame.method === 'native.credentials.names') result = [...records.keys()]
    else if (frame.method === 'native.credentials.set') { records.set(name, value); result = true }
    else if (frame.method === 'native.credentials.remove') { records.delete(name); result = true }
    send({ id: frame.id, result })
  } else if (frame.method === 'native.web.preferences') send({ id: frame.id, result: { enabled: false, scope: 'local', port: 3080 } })
  else if (frame.method === 'native.web.save') send({ id: frame.id, result: true })
  else if (frame.method === 'native.network.addresses') send({ id: frame.id, result: { addresses: [] } })
  else if (frame.method === 'native.exports.directory') send({ id: frame.id, result: join(home, 'native-export-cache') })
  else if (frame.method === 'native.attachments.directory') send({ id: frame.id, result: join(home, 'native-attachment-cache') })
  else if (pending.has(frame.id)) {
    const waiter = pending.get(frame.id)
    pending.delete(frame.id)
    if (frame.error) waiter.reject(new Error(frame.error.message))
    else waiter.resolve(frame.result)
  } else {
    notices.push(frame)
    for (const waiter of [...waiters]) if (waiter.predicate(frame)) {
      waiters.splice(waiters.indexOf(waiter), 1)
      waiter.resolve(frame)
    }
  }
})
let socket, deadline
const started = performance.now()
let phase = 'startup'
const checkpoint = value => {
  phase = value
  console.error(`[interaction-smoke ${Math.round(performance.now() - started)}ms] ${phase}`)
}
try {
  await Promise.race([(async () => {
    await waitFor(frame => frame.method === 'runtime.ready')
    checkpoint('runtime ready')
    assert.deepEqual((await request('interactions.list')).requests, [])
    assert.ok(Array.isArray(await request('api.call', { namespace: 'llm', method: 'listProviders', args: {} })))
    assert.ok(Array.isArray(await request('api.call', { namespace: 'llm', method: 'listConfigurableProviders', args: {} })))
    assert.ok(Array.isArray((await request('api.call', { namespace: 'session', method: 'modelCatalog', args: {} })).groups))
    const inventory = await request('api.call', { namespace: 'pluginInventory', method: 'list', args: {} })
    assert.equal(inventory.managementAvailable, true)
    assert.ok(inventory.entries.length > 0)
    const plugins = await request('api.call', { namespace: 'pluginManager', method: 'listPlugins', args: {} })
    assert.ok(Array.isArray(plugins))
    for (const moduleName of ['@deepseek-ai/dsh-web-app/startup', '@minnnng/dsh-android-runtime']) {
      const plugin = plugins.find(item => item.moduleName === moduleName)
      assert.equal(plugin?.readOnlyReason, 'management-required')
      const refused = await request('api.call', { namespace: 'pluginManager', method: 'setPluginEnabled',
        args: { id: plugin.entryId, enabled: !plugin.enabled } })
      assert.equal(refused.application, 'failed')
      assert.equal(refused.error.code, 'management-required')
    }
    assert.equal((await request('web.status')).enabled, false)
    assert.ok(Array.isArray(await request('api.call', { namespace: 'pluginManager', method: 'listBundles', args: {} })))
    await assert.rejects(request('api.call', { namespace: 'llm', method: 'discoverModels',
      args: { settingsNs: 'unregistered-fixture', request: { baseURL: `http://127.0.0.1:${model.address().port}` } } }), /no model discovery/i)
    const observe = async (subscriptionId, namespace, method, args) => {
      const admitted = await request('api.subscribe', { owner: 'fixture-activity', subscriptionId, namespace, method, args })
      const notification = await waitFor(frame => frame.method === 'api.stream'
        && frame.params.subscriptionId === subscriptionId && frame.params.generation === admitted.generation)
      assert.equal(notification.params.type, 'item', notification.params.error?.message)
      await request('api.ack', notification.params)
      await request('api.unsubscribe', { owner: 'fixture-activity', ...admitted })
      return notification.params.value
    }
    const account = await observe('account-baseline', 'account', 'watch', {})
    assert.ok(account && typeof account === 'object')
    await request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-smoke-fixture-only' })
    await request('session.ensure', { sessionId: 'command-session', provider: 'deepseek-official', model: 'deepseek-flash' })
    checkpoint('command session ready')
    const commands = await request('api.call', { namespace: 'commands', method: 'list', args: { agentId: 'command-session' } })
    for (const name of ['goal', 'plan', 'feedback', 'compact']) assert.ok(commands.some(command => command.name === name),
      `Missing ${name}; catalog=${JSON.stringify(commands)}; plugins=${JSON.stringify(inventory.entries.filter(entry =>
        /goal|plan-mode|command|compaction/.test(entry.moduleName)))}`)
    const beforeCommands = modelRequests
    for (const line of ['/goal', '/plan', '/plan off', '/feedback local fixture feedback']) {
      const command = await request('session.command', { sessionId: 'command-session', line, attachmentIds: [] })
      assert.ok(command)
      assert.notEqual(command.result.kind, 'error', command.result.text)
    }
    const commandHistory = await request('session.read', { sessionId: 'command-session' })
    assert.equal(commandHistory.events.filter(event => event.type === 'command/done').length, 4)
    assert.equal(commandHistory.events.filter(event => event.type === 'feedback/record').length, 1)
    assert.equal(modelRequests, beforeCommands)
    checkpoint('original commands complete')
    const run = async (sessionId, step) => {
      modelSteps.push(step)
      await request('session.send', { sessionId, requestId: sessionId, text: 'Run the fixture interaction.',
        provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
      const notice = await waitFor(frame => frame.method === 'interactions.changed'
        && frame.params.requests.some(item => item.sessionId === sessionId))
      return notice.params.requests.find(item => item.sessionId === sessionId)
    }
    const finish = sessionId => waitFor(frame => frame.method === 'session.event'
      && frame.params.sessionId === sessionId && frame.params.event.type === 'turn/end')
    const question = await run('question-direct', { id: 'question-one', tool: 'ask_user_question',
      args: { timeout: -1, questions: [{ id: 'choice', question: 'Pick the fixture output', options: [{ label: 'Original label' }] }] } })
    assert.equal(question.kind, 'question')
    const invalid = await request('interactions.reply', { id: question.id, version: question.version,
      response: { answers: [{ id: 'choice', selected: ['invented'] }] } })
    assert.equal(invalid.requestStillPending, true)
    const answer = { answers: [{ id: 'choice', selected: [], custom: 'notification text' }] }
    assert.equal((await request('interactions.reply', { id: question.id, version: question.version, response: answer })).accepted, true)
    await finish('question-direct')
    checkpoint('direct question complete')
    const attachmentId = randomUUID()
    const attachmentBytes = Buffer.from('Pocket Harness local attachment fixture')
    await writeFile(join(home, 'native-attachment-cache', `${attachmentId}.bin`), attachmentBytes)
    await writeFile(join(home, 'native-attachment-cache', `${attachmentId}.json`), JSON.stringify({
      id: attachmentId, name: 'fixture.txt', bytes: attachmentBytes.length, mediaType: 'text/plain',
    }))
    const uploaded = await request('attachments.prepare', { sessionId: 'attachment-session', id: attachmentId })
    assert.equal(typeof uploaded.receiptId, 'string')
    await request('session.send', { sessionId: 'attachment-session', requestId: 'attachment-admission',
      text: '', attachmentIds: [attachmentId], provider: 'deepseek-official', model: 'deepseek-flash' })
    await finish('attachment-session')
    const attachmentHistory = await request('session.read', { sessionId: 'attachment-session' })
    assert.ok(attachmentHistory.events.some(event => JSON.stringify(event).includes('"type":"file"')))
    await request('attachments.release', { sessionId: 'attachment-session', id: attachmentId })
    checkpoint('real file attachment complete')
    const jobs = await observe('job-baseline', 'job', 'list', { request: { sessionId: 'question-direct' } })
    assert.deepEqual(jobs, { type: 'rows', jobs: [] })
    const session = await observe('session-baseline', 'session', 'follow',
      { request: { address: { kind: 'session', sessionId: 'question-direct' } } })
    assert.equal(session.type, 'snapshot')
    assert.ok(session.records.length > 0)
    const exportId = randomUUID()
    const exported = await request('session.export.prepare', { id: exportId, sessionId: 'question-direct' })
    const exportedFile = join(home, 'native-export-cache', `${exportId}.zip`)
    assert.equal((await stat(exportedFile)).size, exported.size)
    assert.equal((await readFile(exportedFile)).subarray(0, 2).toString(), 'PK')
    await request('session.export.release', { id: exportId })
    await assert.rejects(stat(exportedFile), { code: 'ENOENT' })
    checkpoint('stream baselines and export complete')
    assert.equal((await request('interactions.reply', { id: question.id, version: question.version, response: answer })).requestStillPending, false)

    const editable = await run('question-edit', { id: 'question-edit-call', tool: 'ask_user_question',
      args: { timeout: 1, questions: [{ id: 'edit', question: 'Keep editing the fixture answer' }] } })
    await request('interactions.wait', { id: editable.id, version: editable.version, action: 'holdFocus' })
    await request('interactions.wait', { id: editable.id, version: editable.version, action: 'engage' })
    await request('interactions.wait', { id: editable.id, version: editable.version, action: 'releaseFocus' })
    const editState = (await request('interactions.list')).requests.find(item => item.id === editable.id)
    assert.equal(editState.waitState, 'editing')
    assert.equal(editState.countdown.running, false)
    await request('interactions.reply', { id: editable.id, version: editable.version,
      response: { answers: [{ id: 'edit', selected: [], custom: 'edited answer' }] } })
    await finish('question-edit')
    checkpoint('question edit complete')
    const timed = await run('question-timed', { id: 'question-timeout', tool: 'ask_user_question',
      args: { timeout: 1, questions: [{ id: 'late', question: 'This fixture can continue' }] } })
    await finish('question-timed')
    const continuation = await waitFor(frame => frame.method === 'interactions.changed'
      && frame.params.requests.some(item => item.sessionId === timed.sessionId && item.state === 'continued'))
    const late = continuation.params.requests.find(item => item.sessionId === timed.sessionId)
    assert.equal(late.waitState, 'continued')
    assert.equal((await request('interactions.reply', { id: late.id, version: late.version,
      response: { answers: [{ id: 'late', selected: [], custom: 'late original answer' }] } })).accepted, true)
    await waitFor(frame => frame.method === 'session.event' && frame.params.sessionId === late.sessionId
      && frame.params.event.type === 'turn/end' && frame.params.event.data.turn === 2)
    checkpoint('timed and continued question complete')

    const approval = await run('approval-app', { id: 'approve-one', tool: 'smoke_approval', args: { command: 'fixture command' } })
    assert.equal(approval.kind, 'approval')
    assert.match(approval.reason, /fixture command/)
    assert.equal((await request('interactions.reply', { id: approval.id, version: approval.version, response: 'allowed-once' })).accepted, true)
    await finish('approval-app')
    const history = await request('session.read', { sessionId: 'approval-app' })
    assert.ok(history.events.some(event => event.type === 'approval/decided' && event.data.outcome === 'allowed-once'))
    checkpoint('App approval complete')

    const web = await request('web.configure', { enabled: true, scope: 'local', port: 0 })
    const login = await fetch(web.url, { redirect: 'manual' })
    const cookie = login.headers.get('set-cookie').split(';')[0]
    const { default: WebSocket } = await import(new URL('../../../.cache/android/runtime-bundle/node_modules/ws/wrapper.mjs', import.meta.url))
    const url = new URL('/api/remote.mux', web.url)
    url.protocol = 'ws:'
    socket = new WebSocket(url, { headers: { cookie, origin: new URL(web.url).origin } })
    const browser = [], browserWaiters = []
    socket.on('message', data => {
      const frame = JSON.parse(data.toString())
      browser.push(frame)
      for (const waiter of [...browserWaiters]) if (waiter.predicate(frame)) {
        browserWaiters.splice(browserWaiters.indexOf(waiter), 1); waiter.resolve(frame)
      }
    })
    const browserWait = predicate => browser.find(predicate) ?? new Promise(resolve => browserWaiters.push({ predicate, resolve }))
    await once(socket, 'open')
    socket.send(JSON.stringify({ type: 'open', streamId: 'events', endpoint: '$events', payload: { args: {} } }))
    const ready = await browserWait(frame => frame.value?.type === 'ready')
    const appFirst = await run('approval-shared-app', { id: 'approve-shared-app', tool: 'smoke_approval', args: { command: 'shared app answer' } })
    await browserWait(frame => frame.value?.type === 'waterfall' && frame.value.eventId === appFirst.id)
    assert.equal((await request('interactions.reply', { id: appFirst.id, version: appFirst.version, response: 'allowed-once' })).accepted, true)
    await browserWait(frame => frame.value?.type === 'cancel' && frame.value.eventId === appFirst.id)
    await finish(appFirst.sessionId)
    checkpoint('App answer cancels Web request')
    const shared = await run('approval-web', { id: 'approve-web', tool: 'smoke_approval', args: { command: 'shared request' } })
    const forwarded = await browserWait(frame => frame.value?.type === 'waterfall' && frame.value.agentId === 'approval-web')
    assert.equal(shared.id, forwarded.value.eventId)
    const browserReply = await fetch(new URL('/api/$events/result', web.url), {
      method: 'POST', headers: { cookie, 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'client-request', rpcId: 'browser-answer', method: '$events/result',
        payload: { args: { clientId: ready.value.clientId, eventId: shared.id, outcome: { kind: 'result', value: 'rejected' } } } }),
    })
    assert.equal((await browserReply.json()).result.ok, true)
    await finish('approval-web')
    assert.equal((await request('interactions.reply', { id: shared.id, version: shared.version, response: 'allowed-once' })).accepted, false)
    checkpoint('Web answer wins')
    const cancelled = await run('approval-cancel', { id: 'cancel-one', tool: 'smoke_approval', args: { command: 'cancel this' } })
    checkpoint('cancellation request pending')
    await request('session.cancel', { sessionId: cancelled.sessionId })
    checkpoint('cancellation acknowledged')
    let cancelDeadline
    try {
      await Promise.race([finish(cancelled.sessionId), new Promise((_, reject) => {
        cancelDeadline = setTimeout(() => reject(new Error('Cancel did not finish within 10 seconds')), 10000)
      })])
    } catch (error) {
      const state = await request('runtime.live')
      const pendingState = await request('interactions.list')
      const current = await request('session.read', { sessionId: cancelled.sessionId })
      console.error(JSON.stringify({ cancellationDiagnostic: {
        state, pending: pendingState.requests.map(item => ({ id: item.id, sessionId: item.sessionId, kind: item.kind })),
        events: current.events.slice(-8).map(event => ({ type: event.type, data: event.data })),
      } }))
      throw error
    } finally { clearTimeout(cancelDeadline) }
    checkpoint('cancelled turn complete')
    assert.equal((await request('interactions.list')).requests.some(item => item.id === cancelled.id), false)
    console.log(JSON.stringify({ questionTool: true, invalidAnswerPreserved: true, textAnswer: true,
      originalQuestionEditHold: true, originalTimeoutContinues: true, continuedAnswer: true,
      actualApprovalAudit: true, sharedWebRequestId: true, appAnswerCancelsWeb: true,
      webFirstAnswerWins: true, turnCancellationWithdraws: true,
      gatewayModelEndpoints: true, accountStream: true, jobStream: true, sessionStream: true,
      pluginManagement: true, sessionExport: true, originalCommands: true, fileAttachmentAdmission: true }))
  })(), new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error(`Interaction smoke timed out during ${phase}`)), 120000) })])
} finally {
  clearTimeout(deadline)
  socket?.terminate()
  child.kill()
  await exited
  lines.close()
  model.closeAllConnections()
  await new Promise(resolve => model.close(resolve))
}
