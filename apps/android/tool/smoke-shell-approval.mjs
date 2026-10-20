/** Built Android profile: original approval policy, real host shell, App/Web carriers and Session audit. */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises'
import { watch } from 'node:fs'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { resolve, join } from 'node:path'
import { createInterface } from 'node:readline'

const root = resolve(import.meta.dirname, '../../..')
const { default: WebSocket } = await import(new URL('../../../.cache/android/runtime-bundle/node_modules/ws/wrapper.mjs', import.meta.url))

async function fixture(policy, exercise) {
  const home = await mkdtemp(join(root, '.cache/android/shell-approval-'))
  const workspace = join(home, 'workspace')
  await mkdir(workspace)
  await mkdir(join(home, 'profiles/android'), { recursive: true })
  await writeFile(join(home, 'profiles/android/cordis.patch.yml'), JSON.stringify([
    { id: 'approval', config: { policy } },
    { id: 'android-runtime', config: { shellTimeoutMs: 10000 } },
  ]))
  const steps = [], modelMessages = []
  const model = createServer((request, response) => {
    void (async () => {
      const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString('utf8'))
      const agent = body.tools?.some(tool => tool.name === 'android_shell')
      const step = agent ? steps.shift() : undefined
      if (agent) modelMessages.push(body.messages)
      const block = step ? { type: 'tool_use', id: step.id, name: 'android_shell', input: { command: step.command } }
        : { type: 'text', text: 'shell fixture complete' }
      response.writeHead(200, { 'content-type': 'text/event-stream' })
      for (const event of [
        { type: 'message_start', message: { id: `shell-${Date.now()}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
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
  const child = spawn(process.execPath, ['--import', new URL('./shell-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: workspace, env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1',
      DEEPSEEK_BASE_URL: `http://127.0.0.1:${model.address().port}` }, stdio: ['pipe', 'pipe', 'pipe'],
  })
  const exited = once(child, 'exit')
  const records = new Map(), pending = new Map(), notices = [], waiters = [], sockets = [], watchers = []
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  let serial = 0
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = `shell-${++serial}`
    pending.set(id, { resolve, reject })
    send({ id, method, params })
  })
  const waitFor = predicate => notices.find(predicate) ?? new Promise(resolve => waiters.push({ predicate, resolve }))
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
    } else if (frame.method === 'native.storage.root') send({ id: frame.id, result: home })
    else if (frame.method === 'native.web.preferences') send({ id: frame.id, result: { enabled: false, scope: 'local', port: 3080 } })
    else if (frame.method === 'native.web.save') send({ id: frame.id, result: true })
    else if (frame.method === 'native.network.addresses') send({ id: frame.id, result: { addresses: [] } })
    else if (frame.method?.startsWith('native.') && frame.id) {
      send({ id: frame.id, error: { code: -32601, message: `Unexpected fixture native request ${frame.method}` } })
    } else if (pending.has(frame.id)) {
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
  const submit = async (sessionId, callId, command) => {
    steps.push({ id: callId, command })
    await request('session.send', { sessionId, requestId: callId, text: 'Execute the shell fixture command.',
      provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
  }
  const interaction = async callId => {
    const frame = await waitFor(frame => frame.method === 'interactions.changed'
      && frame.params.requests.some(item => item.callId === callId))
    return frame.params.requests.find(item => item.callId === callId)
  }
  const finish = (sessionId, turn = 1) => waitFor(frame => frame.method === 'session.event'
    && frame.params.sessionId === sessionId && frame.params.event.type === 'turn/end'
    && frame.params.event.data.turn === turn)
  const reply = (item, response) => request('interactions.reply', { id: item.id, version: item.version, response })
  const history = async sessionId => (await request('session.read', { sessionId })).events
  const absent = name => assert.rejects(stat(join(workspace, name)), { code: 'ENOENT' })
  const content = name => readFile(join(workspace, name), 'utf8')
  const marker = name => {
    const promise = Promise.withResolvers()
    const observer = watch(workspace, (_event, file) => {
      if (String(file) === name) { observer.close(); promise.resolve() }
    })
    observer.on('error', promise.reject)
    watchers.push(observer)
    return promise.promise
  }
  const browser = async () => {
    const web = await request('web.configure', { enabled: true, scope: 'local', port: 0 })
    const login = await fetch(web.url, { redirect: 'manual' })
    const cookie = login.headers.get('set-cookie').split(';')[0]
    const address = new URL('/api/remote.mux', web.url)
    address.protocol = 'ws:'
    const socket = new WebSocket(address, { headers: { cookie, origin: new URL(web.url).origin } })
    sockets.push(socket)
    const frames = [], waits = []
    socket.on('message', data => {
      const frame = JSON.parse(data.toString())
      frames.push(frame)
      for (const waiter of [...waits]) if (waiter.predicate(frame)) {
        waits.splice(waits.indexOf(waiter), 1); waiter.resolve(frame)
      }
    })
    const wait = predicate => frames.find(predicate) ?? new Promise(resolve => waits.push({ predicate, resolve }))
    await once(socket, 'open')
    socket.send(JSON.stringify({ type: 'open', streamId: 'events', endpoint: '$events', payload: { args: {} } }))
    const ready = await wait(frame => frame.value?.type === 'ready')
    return {
      wait,
      async reply(id, response) {
        const returned = await fetch(new URL('/api/$events/result', web.url), {
          method: 'POST', headers: { cookie, 'content-type': 'application/json' },
          body: JSON.stringify({ type: 'client-request', rpcId: `browser-${++serial}`, method: '$events/result',
            payload: { args: { clientId: ready.value.clientId, eventId: id, outcome: { kind: 'result', value: response } } } }),
        })
        return returned.json()
      },
    }
  }
  let deadline
  try {
    await Promise.race([(async () => {
      await waitFor(frame => frame.method === 'runtime.ready')
      await request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-fixture-only' })
      await exercise({ request, submit, interaction, finish, reply, history, absent, content, marker, browser, modelMessages })
    })(), new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error(`Shell ${policy} smoke exceeded 90 seconds`)), 90000) })])
  } finally {
    clearTimeout(deadline)
    watchers.forEach(observer => observer.close())
    sockets.forEach(socket => socket.terminate())
    child.kill()
    await exited
    lines.close()
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}

await fixture('ask', async f => {
  await f.submit('shell-once', 'allowed-call', "printf approved > allowed.txt; printf shell-output")
  const allowed = await f.interaction('allowed-call')
  assert.equal(allowed.toolName, 'android_shell')
  assert.equal(JSON.parse(allowed.toolCall.arguments).command, 'printf approved > allowed.txt; printf shell-output')
  await f.absent('allowed.txt')
  assert.equal((await f.reply(allowed, 'allowed-once')).accepted, true)
  await f.finish('shell-once')
  assert.equal(await f.content('allowed.txt'), 'approved')
  assert.match(JSON.stringify(f.modelMessages), /shell-output/)
  const firstHistory = await f.history('shell-once')
  assert.ok(firstHistory.some(event => event.type === 'tool/result'
    && JSON.stringify(event.data).includes('shell-output')))
  assert.deepEqual(firstHistory.filter(event => event.type === 'approval/decided')
    .map(event => event.data.outcome), ['allowed-once'])
  await f.submit('shell-once', 'denied-call', 'printf forbidden > denied.txt')
  const denied = await f.interaction('denied-call')
  assert.notEqual(denied.id, allowed.id)
  assert.equal((await f.reply(denied, 'rejected')).accepted, true)
  await f.finish('shell-once', 2)
  await f.absent('denied.txt')
  assert.deepEqual((await f.history('shell-once')).filter(event => event.type === 'approval/decided')
    .map(event => event.data.outcome), ['allowed-once', 'rejected'])
  assert.equal((await f.reply(denied, 'allowed-once')).accepted, false)

  await f.submit('shell-cancel-wait', 'cancel-wait', 'printf forbidden > cancelled.txt')
  const cancelled = await f.interaction('cancel-wait')
  await f.request('session.cancel', { sessionId: cancelled.sessionId })
  await f.finish(cancelled.sessionId)
  assert.equal((await f.reply(cancelled, 'allowed-once')).accepted, false)
  await f.absent('cancelled.txt')
  assert.deepEqual((await f.history(cancelled.sessionId)).filter(event => event.type === 'approval/decided')
    .map(event => event.data.outcome), ['cancelled'])

  await f.submit('shell-running-cancel', 'cancel-running', 'printf started > started.txt; while :; do :; done')
  const running = await f.interaction('cancel-running')
  const started = f.marker('started.txt')
  await f.reply(running, 'allowed-once')
  await started
  await f.request('session.cancel', { sessionId: running.sessionId })
  let timer
  try {
    await Promise.race([f.finish(running.sessionId), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Approved shell cancellation did not settle in 5 seconds')), 5000)
    })])
  } finally { clearTimeout(timer) }
  assert.equal((await f.request('runtime.live')).statuses[running.sessionId], 'idle')

  const web = await f.browser()
  await f.submit('shell-race', 'race-call', 'printf exactly-once >> race.txt')
  const race = await f.interaction('race-call')
  const forwarded = await web.wait(frame => frame.value?.type === 'waterfall' && frame.value.eventId === race.id)
  assert.equal(forwarded.value.agentId, race.sessionId)
  const responses = await Promise.all([f.reply(race, 'allowed-once'), web.reply(race.id, 'rejected')])
  await f.finish(race.sessionId)
  const audit = (await f.history(race.sessionId)).filter(event => event.type === 'approval/decided')
  assert.equal(audit.length, 1)
  if (audit[0].data.outcome === 'allowed-once') assert.equal(await f.content('race.txt'), 'exactly-once')
  else { assert.equal(audit[0].data.outcome, 'rejected'); await f.absent('race.txt') }
  assert.equal(responses[0].requestStillPending, false)
  assert.equal((await f.reply(race, 'allowed-once')).accepted, false)
  assert.equal((await f.request('interactions.list')).requests.length, 0)
  console.log(JSON.stringify({ originalToolGate: true, appApprovalStartsRealShell: true,
    outputReachesModel: true, outputLogged: true, oneShotGrant: true, rejectionNeverExecutes: true,
    waitingCancellationDiscardsLateGrant: true, runningCancellationSettles: true,
    sharedWebEventId: true, concurrentAppWebSingleDecision: true, durableApprovalAudit: true,
    executionPlatform: process.platform, windowsShellAndTerminationAdapter: process.platform === 'win32',
    androidDeviceExecution: false }))
})

await fixture('never', async f => {
  await f.submit('shell-never', 'never-call', 'printf forbidden > never.txt')
  await f.finish('shell-never')
  assert.equal((await f.request('interactions.list')).requests.length, 0)
  await f.absent('never.txt')
  const history = await f.history('shell-never')
  assert.equal(history.filter(event => event.type === 'approval/asked').length, 1)
  assert.deepEqual(history.filter(event => event.type === 'approval/decided').map(event => event.data.outcome), ['rejected'])
  console.log(JSON.stringify({ originalNeverPolicy: true, noInteractivePrompt: true, noShellExecution: true }))
})
