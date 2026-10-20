import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { glob, mkdtemp, mkdir, readFile, stat } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'

// Run the staged Android profile unchanged. Only its model HTTP endpoint,
// native credential store, and Web port allocation belong to this fixture.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/delegation-profile-'))
const workspace = join(home, 'workspace')
await mkdir(workspace)
const forbiddenOutput = join(workspace, 'child-shell-must-not-run.txt')
const vault = new Map(), runtimes = [], modelRequests = [], scripts = new Map()
const modelFailure = Promise.withResolvers()
const heldControl = Promise.withResolvers(), heldApp = Promise.withResolvers(), heldCrash = Promise.withResolvers()
let controlChildId, requestSerial = 0, callSerial = 0, phase = 'starting'
const started = performance.now()
const checkpoint = label => {
  phase = label
  console.error(`[delegation-profile ${Math.round(performance.now() - started)}ms] ${label}`)
}
const marker = Object.freeze({
  history: 'POCKET_FIXTURE_PARENT_COMPLETED_HISTORY',
  spawn: 'POCKET_FIXTURE_PARENT_SPAWN',
  fresh: 'POCKET_FIXTURE_CHILD_FRESH',
  fork: 'POCKET_FIXTURE_PARENT_FORK',
  forked: 'POCKET_FIXTURE_CHILD_FORK',
  resumed: 'POCKET_FIXTURE_CHILD_RESUMED',
  control: 'POCKET_FIXTURE_PARENT_CONTROL',
  held: 'POCKET_FIXTURE_CHILD_HELD',
  parked: 'POCKET_FIXTURE_PARKED_STEERING',
  appParent: 'POCKET_FIXTURE_APP_CONTROL_PARENT',
  appHeld: 'POCKET_FIXTURE_APP_CONTROLLED_CHILD',
  appQueued: 'POCKET_FIXTURE_APP_RETAINED_INPUT',
  crash: 'POCKET_FIXTURE_EXPLICIT_WAKE_BEFORE_CRASH',
  retained: 'POCKET_FIXTURE_RETAINED_AFTER_CRASH',
})
const markers = new Set(Object.values(marker))
const delegationTools = ['subagent', 'subagent_fork', 'send_message', 'interrupt_agent', 'list_agents']
const messageTexts = body => body.messages?.flatMap(message => typeof message.content === 'string'
  ? [message.content]
  : message.content?.flatMap(block => block.type === 'text' ? [block.text] : []) ?? []) ?? []
function scenarioOf(body) {
  for (const message of [...body.messages ?? []].reverse()) {
    if (message.role !== 'user') continue
    const texts = typeof message.content === 'string' ? [message.content]
      : message.content?.flatMap(block => block.type === 'text' ? [block.text] : []) ?? []
    const selected = texts.findLast(text => markers.has(text))
    if (selected) return selected
  }
}
function tool(name, input) {
  return { type: 'tool_use', id: `delegation-call-${++callSerial}`, name, input }
}
const text = value => ({ type: 'text', text: value })
function childIdFromToolResult(body) {
  const results = body.messages?.flatMap(message => Array.isArray(message.content)
    ? message.content.filter(block => block.type === 'tool_result') : []) ?? []
  const ids = results.map(result => /started subagent ([^\s"\\]+)/.exec(JSON.stringify(result.content))?.[1]).filter(Boolean)
  assert.ok(ids.length > 0, 'the original delegation tool must return its child id')
  return ids.at(-1)
}
async function nextResponse(body, response) {
  const scenario = scenarioOf(body)
  if (!scenario) return text('Fixture conversation')
  const tools = body.tools?.map(entry => entry.name) ?? []
  for (const name of delegationTools) assert.ok(tools.includes(name), `${scenario} is missing ${name}`)
  assert.ok(tools.includes('android_shell'), `${scenario} is missing the Android shell`)
  for (const name of ['run_code', 'workflow']) assert.ok(!tools.includes(name), `${name} requires a disabled Android runtime`)
  modelRequests.push({ scenario, body })
  const count = (scripts.get(scenario) ?? 0) + 1
  scripts.set(scenario, count)
  assert.ok(count <= 8, `${scenario} exceeded its finite fixture script`)
  switch (scenario) {
    case marker.history: return text('The parent completed its history turn.')
    case marker.spawn:
      return count === 1 ? tool('subagent', { description: 'Check fresh Android child', prompt: marker.fresh })
        : text('The fresh child delegation was recorded.')
    case marker.fresh: {
      const texts = messageTexts(body)
      assert.ok(!texts.includes(marker.history), 'spawn must not inherit the parent conversation')
      assert.ok(!texts.includes(marker.spawn), 'spawn must not inherit the delegating turn')
      return count === 1
        ? tool('android_shell', { command: `printf forbidden > '${forbiddenOutput.replaceAll('\\', '/')}'` })
        : text('The child shell was rejected by its original policy.')
    }
    case marker.fork:
      return count === 1 ? tool('subagent_fork', { description: 'Check inherited Android child', prompt: marker.forked })
        : text('The fork child delegation was recorded.')
    case marker.forked: {
      const texts = messageTexts(body)
      assert.ok(texts.includes(marker.history), 'fork must inherit the completed history')
      assert.ok(!texts.includes(marker.fork), 'fork must exclude its current unbalanced parent turn')
      return count === 1 ? tool('list_agents', {}) : text('The fork child has its inherited history.')
    }
    case marker.resumed: return text('The original child resumed explicitly.')
    case marker.appParent:
      return count === 1 ? tool('subagent', { description: 'Check App-controlled child', prompt: marker.appHeld })
        : text('The App-controlled child was delegated.')
    case marker.control:
      if (count === 1) return tool('subagent', { description: 'Check controlled Android child', prompt: marker.held })
      if (count === 2) {
        controlChildId = childIdFromToolResult(body)
        await heldControl.promise
        return tool('send_message', { agent_id: controlChildId, message: marker.parked })
      }
      if (count === 3) return tool('interrupt_agent', { agent_id: controlChildId })
      return text('The child was interrupted; its accepted message remains parked.')
    case marker.held:
      assert.equal(count, 1, 'the interrupted child must not automatically restart')
      heldControl.resolve()
      await once(response, 'close')
      return null
    case marker.crash:
      assert.equal(count, 1, 'the crash fixture must not automatically replay')
      heldCrash.resolve()
      await once(response, 'close')
      return null
    case marker.appHeld:
      assert.equal(count, 1, 'the App-interrupted child must not automatically restart')
      heldApp.resolve()
      await once(response, 'close')
      return null
    case marker.parked:
    case marker.appQueued:
    case marker.retained:
      throw new Error(`Queued child work replayed without the explicit fixture wake: ${scenario}`)
    default: throw new Error(`Unrecognized fixture scenario: ${scenario}`)
  }
}
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    const block = await nextResponse(body, response)
    if (!block || response.destroyed) return
    requestSerial += 1
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `delegation-${requestSerial}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: block },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: block.type === 'tool_use' ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => {
    modelFailure.reject(error)
    response.destroy(error)
  })
})
model.listen(0, '127.0.0.1')
await once(model, 'listening')

function launch() {
  const child = spawn(process.execPath, ['--import', new URL('./web-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: workspace,
    env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1',
      DEEPSEEK_BASE_URL: `http://127.0.0.1:${model.address().port}` },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const pending = new Map(), notices = [], waiters = new Set()
  let serial = 0, ended = false, failure
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const lines = createInterface({ input: child.stdout })
  const failPending = error => {
    failure ??= error
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear()
    waiters.clear()
  }
  const stop = error => {
    failPending(error)
    if (!ended) child.kill('SIGKILL')
  }
  const closed = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })))
  child.once('error', error => { ended = true; failPending(error) })
  child.once('exit', (code, signal) => {
    ended = true
    failPending(new Error(`Fixture runtime exited (${code ?? signal})`))
  })
  child.stdin.on('error', stop)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (ended || failure) return
    try {
      const frame = JSON.parse(line)
      if (frame.method?.startsWith('native.')) {
        let result
        const { name, value } = frame.params ?? {}
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
      if (failure || ended) return Promise.reject(failure ?? new Error('Runtime is stopped'))
      const id = `delegation-${++serial}`
      return new Promise((resolve, reject) => { pending.set(id, { resolve, reject, method }); send({ id, method, params }) })
    },
    wait(predicate) {
      if (failure || ended) return Promise.reject(failure ?? new Error('Runtime is stopped'))
      const existing = notices.find(predicate)
      if (existing) return Promise.resolve(existing)
      return new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
    },
    async close() {
      if (!ended) child.kill('SIGKILL')
      let deadline
      try {
        return await Promise.race([closed, new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Fixture runtime did not close after SIGKILL')), 15000)
        })])
      } finally { clearTimeout(deadline); lines.close() }
    },
    diagnostics: () => ({ pid: child.pid, pending: [...pending.values()].map(call => call.method), notices: notices.length }),
  }
  runtimes.push(runtime)
  return runtime
}
const eventsOf = (runtime, sessionId) => runtime.notices.flatMap(frame =>
  frame.method === 'session.event' && frame.params.sessionId === sessionId ? [frame.params.event] : [])
function waitEvent(runtime, sessionId, predicate) {
  return runtime.wait(frame => frame.method === 'session.event' && frame.params.sessionId === sessionId
    && predicate(frame.params.event)).then(frame => frame.params.event)
}
async function poll(read, predicate, label) {
  const deadline = performance.now() + 15000
  while (true) {
    const value = await read()
    if (predicate(value)) return value
    if (performance.now() >= deadline) throw new Error(`Timed out waiting for ${label}`)
    await new Promise(resolve => setTimeout(resolve, 20))
  }
}
async function persisted(sessionId) {
  const files = await Array.fromAsync(glob(`sessions/**/${sessionId}/session.v4.jsonl`, { cwd: home }))
  if (files.length === 0) return []
  assert.equal(files.length, 1, `duplicate durable log for ${sessionId}`)
  const raw = await readFile(join(home, files[0]), 'utf8')
  return raw.split('\n').slice(0, -1).filter(Boolean).map(line => JSON.parse(line))
}
function assertChild(records, { parent, seeded, provider }) {
  const header = records[0]
  assert.equal(header.id !== parent, true)
  assert.equal(header.parentSession, parent)
  assert.equal(header.origin, 'subagent')
  assert.equal(header.delegationDepth, 1)
  assert.equal(header.agentPreset, 'android')
  assert.equal(header.isSeeded, seeded)
  const descriptor = records.find(event => event.type === 'subagent/descriptor')
  assert.equal(descriptor?.data.mode, 'continuable')
  assert.equal(descriptor.data.provider, provider)
  assert.equal(descriptor.data.agentModel, 'deepseek-flash')
  assert.ok(records.some(event => event.type === 'approval/policy'
    && event.data.policy === 'never' && event.data.source === 'delegation'))
}

let deadline
try {
  await Promise.race([(async () => {
    const first = launch()
    await first.wait(frame => frame.method === 'runtime.ready')
    checkpoint('first process ready')
    await first.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-delegation-fixture-key' })
    const prompt = (sessionId, value) => first.request('session.send', {
      sessionId, requestId: value, text: value, provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true,
    })
    const continueChild = (parentSessionId, childSessionId, value, delivery = 'queue') =>
      first.request('subagents.send', {
        address: { parentSessionId, childSessionId, mode: 'continuable' },
        requestId: value, text: value, delivery,
      }).then(receipt => { assert.equal(typeof receipt.messageId, 'string', JSON.stringify(receipt)); return receipt })
    const noAgent = sessionId => poll(() => first.request('runtime.live'),
      live => !Object.hasOwn(live.statuses, sessionId), `child ${sessionId} to release its Agent`)
    const parent = 'delegation-parent'
    await prompt(parent, marker.history)
    await waitEvent(first, parent, event => event.type === 'turn/end')
    await prompt(parent, marker.spawn)
    const freshCatalog = await waitEvent(first, parent, event =>
      event.type === 'subagent/catalog' && event.data.label === 'Check fresh Android child')
    const freshId = freshCatalog.data.childId
    const freshAddress = { parentSessionId: parent, childSessionId: freshId, mode: 'continuable' }
    await waitEvent(first, freshId, event => event.type === 'turn/end')
    await noAgent(freshId)
    const fresh = await poll(() => persisted(freshId),
      records => records.some(event => event.type === 'turn/end'), 'fresh child final log')
    assertChild(fresh, { parent, seeded: false, provider: 'spawn' })
    const asked = fresh.find(event => event.type === 'approval/asked' && event.data.toolName === 'android_shell')
    assert.ok(asked, 'the child shell must use the original approval audit')
    assert.ok(fresh.some(event => event.type === 'approval/decided'
      && event.data.id === asked.data.id && event.data.outcome === 'rejected'))
    assert.ok(fresh.some(event => event.type === 'tool/result'
      && event.data.message?.source.callId === asked.data.callId && event.data.message.isError === true))
    await assert.rejects(stat(forbiddenOutput), { code: 'ENOENT' })
    assert.equal(first.notices.some(frame => frame.method === 'interactions.changed'
      && frame.params.requests.some(request => request.sessionId === freshId)), false,
    'delegated never policy must not publish an approval request')
    checkpoint('fresh child, real shell policy rejection and five native tools')
    const freshRead = await first.request('subagents.inspect', { address: { ...freshAddress, mode: 'unknown' } })
    assert.deepEqual(freshRead.address, freshAddress)
    assert.equal(freshRead.capabilities.canPrompt, true)
    assert.equal(freshRead.capabilities.attached, false)
    assert.ok(freshRead.snapshot.records.some(row => row.event?.type === 'subagent/descriptor'))
    assert.equal(freshRead.task.history[0].status, 'completed')
    const wrongParent = await first.request('subagents.inspect', {
      address: { ...freshAddress, parentSessionId: 'different-parent' },
    })
    assert.equal(wrongParent._pocket_error.code, 'subagent/unauthorized')
    assert.deepEqual((await first.request('subagents.catalog', { parentSessionId: freshId })).entries, [])

    // Parent settlement is an ordinary original inbox message; let it complete
    // before capturing the next fork's completed-turn prefix.
    await poll(() => first.request('tasks.summary'), value => value.summary.running === 0, 'parent settlement')
    await prompt(parent, marker.fork)
    const forkCatalog = await waitEvent(first, parent, event =>
      event.type === 'subagent/catalog' && event.data.label === 'Check inherited Android child')
    const forkId = forkCatalog.data.childId
    await waitEvent(first, forkId, event => event.type === 'tool/call' && event.data.name === 'list_agents')
    await noAgent(forkId)
    const fork = await poll(() => persisted(forkId), records => {
      const descriptor = records.find(event => event.type === 'subagent/descriptor')
      const call = records.find(event => descriptor && event.seq > descriptor.seq
        && event.type === 'tool/call' && event.data.name === 'list_agents')
      return call && records.some(event => event.type === 'turn/end' && event.data.turn === call.data.turn)
    }, 'fork child own completed turn to reach the original JSONL writer')
    assertChild(fork, { parent, seeded: true, provider: 'fork' })
    const forkDescriptor = fork.find(event => event.type === 'subagent/descriptor')
    const ownList = fork.find(event => event.seq > forkDescriptor.seq
      && event.type === 'tool/call' && event.data.name === 'list_agents')
    assert.ok(ownList, 'list_agents must run after the fork child descriptor, outside its inherited prefix')
    assert.ok(fork.some(event => event.type === 'tool/result'
      && event.data.message?.source.callId === ownList.data.callId && event.data.message.isError !== true))
    assert.ok(fork.some(event => event.type === 'turn/end' && event.data.turn === ownList.data.turn))
    const forkAddress = { parentSessionId: parent, childSessionId: forkId, mode: 'continuable' }
    const firstPage = await first.request('subagents.catalog', { parentSessionId: parent, limit: 1 })
    assert.equal(firstPage.entries.length, 1)
    assert.equal(firstPage.nextOffset, 1)
    const secondPage = await first.request('subagents.catalog', { parentSessionId: parent, limit: 1, offset: firstPage.nextOffset })
    assert.equal(secondPage.entries.length, 1)
    assert.equal(secondPage.nextOffset, null)
    assert.deepEqual(new Set([...firstPage.entries, ...secondPage.entries].map(row => row.id)), new Set([freshId, forkId]))
    const full = await first.request('subagents.inspect', { address: forkAddress, maxMessages: 100 })
    const opening = await first.request('subagents.inspect', { address: forkAddress, maxMessages: 1 })
    assert.equal(full.snapshot.cursor, opening.snapshot.cursor)
    let combined = opening.snapshot.records, hasMore = opening.snapshot.hasMore, pages = 0
    while (hasMore) {
      assert.ok(++pages < 50, 'history paging must advance its exclusive cursor')
      const beforeSeq = combined[0].event.seq
      const page = await first.request('subagents.page', {
        address: forkAddress, throughSeq: opening.snapshot.cursor, beforeSeq, maxMessages: 1,
      })
      assert.ok(page.records.every(row => row.event.seq < beforeSeq))
      combined = [...page.records, ...combined]
      hasMore = page.hasMore
    }
    assert.deepEqual(combined.map(row => row.event.seq), full.snapshot.records.map(row => row.event.seq))
    assert.equal(new Set(combined.map(row => row.event.seq)).size, combined.length)
    assert.equal((await first.request('runtime.live')).statuses[forkId], undefined)
    const resumedReceipt = await continueChild(parent, forkId, marker.resumed)
    await waitEvent(first, forkId, event => event.type === 'user/message'
      && event.data.source?.rpcId === marker.resumed)
    await noAgent(forkId)
    const resumed = await poll(() => persisted(forkId), records => {
      const answer = records.find(event => event.type === 'assistant/message'
        && JSON.stringify(event.data).includes('The original child resumed explicitly.'))
      return answer && records.some(event => event.type === 'turn/end' && event.data.turn === answer.data.turn)
    }, 'cold continuation completed turn in the original child log')
    assert.equal(resumed.filter(event => event.type === 'subagent/descriptor').length, 1)
    const observed = await first.request('subagents.inspect', { address: forkAddress, requestId: marker.resumed })
    assert.deepEqual(observed.submission, { requestId: marker.resumed, state: 'observed', messageId: resumedReceipt.messageId })
    const absent = await first.request('subagents.inspect', { address: forkAddress, requestId: 'uncertain-no-proof' })
    assert.deepEqual(absent.submission, { requestId: 'uncertain-no-proof', state: 'not-observed' })
    checkpoint('balanced fork context and explicit cold continuation')

    const controlParent = 'delegation-control-parent'
    await prompt(controlParent, marker.control)
    const controlCatalog = await waitEvent(first, controlParent, event => event.type === 'subagent/catalog')
    assert.equal(controlCatalog.data.mode, 'continuable')
    const controlId = controlCatalog.data.childId
    const interrupted = await waitEvent(first, controlId, event =>
      event.type === 'turn/end' && event.data.reason.kind === 'aborted')
    assert.equal(interrupted.data.reason.reason.kind, 'parent')
    await waitEvent(first, controlParent, event => event.type === 'turn/end')
    const controlEvents = eventsOf(first, controlParent)
    for (const name of ['subagent', 'send_message', 'interrupt_agent']) {
      const call = controlEvents.find(event => event.type === 'tool/call' && event.data.name === name)
      assert.ok(call, `the model must actually invoke ${name}`)
      assert.ok(controlEvents.some(event => event.type === 'tool/result'
        && event.data.message?.source.callId === call.data.callId && event.data.message.isError !== true))
    }
    const parked = await first.request('tasks.session', { sessionId: controlId })
    assert.equal(parked.pending.length, 1)
    assert.ok(parked.pending[0].prompt.includes(marker.parked))
    assert.equal(scripts.get(marker.held), 1)
    assert.equal(scripts.has(marker.parked), false)
    checkpoint('original send_message and interrupt_agent preserve parked input')

    const appParent = 'delegation-app-parent'
    await prompt(appParent, marker.appParent)
    const appCatalog = await waitEvent(first, appParent, event => event.type === 'subagent/catalog')
    const appId = appCatalog.data.childId
    const appAddress = { parentSessionId: appParent, childSessionId: appId, mode: 'continuable' }
    await heldApp.promise
    const queuedReceipt = await continueChild(appParent, appId, marker.appQueued)
    const active = await first.request('subagents.inspect', { address: appAddress, requestId: marker.appQueued })
    assert.equal(active.capabilities.canInterrupt, true)
    assert.equal(active.capabilities.running, true)
    assert.deepEqual(active.submission, { requestId: marker.appQueued, state: 'observed', messageId: queuedReceipt.messageId })
    assert.ok(active.task.pending.some(row => row.prompt.includes(marker.appQueued)))
    const wrongInterrupt = await first.request('subagents.interrupt', {
      address: { ...appAddress, parentSessionId: parent },
    })
    assert.equal(wrongInterrupt._pocket_error.code, 'subagent/unauthorized')
    assert.deepEqual(await first.request('subagents.interrupt', { address: appAddress }), { accepted: true })
    await waitEvent(first, appId, event => event.seq > active.snapshot.cursor && event.type === 'turn/end'
      && event.data.reason.kind === 'aborted' && event.data.reason.reason.kind === 'user')
    const appStopped = await first.request('subagents.inspect', { address: appAddress, requestId: marker.appQueued })
    assert.equal(appStopped.capabilities.running, false)
    assert.ok(appStopped.task.pending.some(row => row.prompt.includes(marker.appQueued)))
    assert.equal(scripts.has(marker.appQueued), false)
    checkpoint('App original parent interrupt, positive queue receipt and preserved input')

    const controlAddress = { parentSessionId: controlParent, childSessionId: controlId, mode: 'continuable' }
    await continueChild(controlParent, controlId, marker.crash, 'steer')
    await heldCrash.promise
    await continueChild(controlParent, controlId, marker.retained)
    await poll(() => persisted(controlId), records => records.some(event =>
      event.type === 'agent/inbox/spliced' && event.data.inserted.some(message => message.source?.rpcId === marker.retained)),
    'retained child input to reach the original JSONL writer')
    await poll(() => persisted(controlParent), records => records.some(event =>
      event.type === 'subagent/catalog' && event.data.childId === controlId), 'parent catalog persistence')
    const killed = await first.close()
    assert.equal(killed.signal, 'SIGKILL')
    const beforeRestart = modelRequests.length
    const second = launch()
    await second.wait(frame => frame.method === 'runtime.ready')
    const ordinary = await second.request('sessions.list')
    assert.ok(ordinary.some(entry => entry.header.id === parent), 'the ordinary list must retain its parent conversation')
    assert.ok(ordinary.some(entry => entry.header.id === controlParent), 'the recovered parent must remain in the ordinary list')
    assert.ok(ordinary.every(entry => entry.header.origin !== 'subagent'), 'children require their parent-addressed entry point')
    assert.ok(!ordinary.some(entry => [freshId, forkId, controlId, appId].includes(entry.header.id)),
      'none of the actual child sessions may leak into the ordinary chat sidebar')
    const catalog = await second.request('subagents.catalog', { parentSessionId: controlParent })
    assert.equal(catalog.parentAvailable, false)
    assert.ok(catalog.entries.some(row => row.id === controlId && row.mode === 'continuable'))
    const cold = await second.request('subagents.inspect', {
      address: { ...controlAddress, mode: 'unknown' }, requestId: marker.retained,
    })
    assert.deepEqual(cold.address, controlAddress)
    assert.equal(cold.capabilities.parentAvailable, false)
    assert.equal(cold.capabilities.canPrompt, false)
    assert.equal(cold.capabilities.readOnlyReason, 'parent-unavailable')
    assert.equal(cold.submission.state, 'observed')
    const recovered = cold.task
    assert.equal(recovered.pending.length, 1)
    assert.ok(recovered.pending[0].prompt.includes(marker.retained))
    assert.equal(recovered.pending[0].status, 'suspended')
    assert.equal(recovered.history.find(row => row.kind === 'turn').status, 'interrupted')
    assert.ok(cold.snapshot.records.some(row => row.event?.type === 'subagent/descriptor'))
    const refused = await second.request('subagents.send', { address: controlAddress, requestId: 'no-parent',
      text: 'Do not activate the missing parent', delivery: 'queue' })
    assert.equal(refused._pocket_error.code, 'subagent/parent-unavailable')
    assert.deepEqual(await second.request('subagents.interrupt', { address: controlAddress }), { accepted: true })
    assert.deepEqual((await second.request('runtime.live')).statuses, {})
    assert.deepEqual((await second.request('tasks.summary')).active, [])
    assert.equal(modelRequests.length, beforeRestart, 'history and catalog reads must not replay child work')
    checkpoint('SIGKILL recovery retains one child message without activating or replaying')
    console.log(JSON.stringify({ realProfile: true, originalTools: delegationTools,
      freshChild: true, balancedFork: true, childMetadata: true, originalNeverPolicy: true,
      shellRejectedWithoutExecution: true, explicitColdContinuation: true,
      actualSendMessageAndInterrupt: true, interruptRetainsQueue: true,
      appCatalogAndAddressedHistory: true, exclusiveHistoryPagination: true, appPromptReceipt: true,
      appParentInterrupt: true, appTaskState: true, parentOfflineRefusal: true, ordinaryListExcludesChildren: true,
      processRecovery: true, readOnlyDoesNotReplay: true }))
  })(), modelFailure.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Delegation profile exceeded 180 seconds at ${phase}: ${
      JSON.stringify(runtimes.map(runtime => runtime.diagnostics()))}`)), 180000)
  })])
} finally {
  clearTimeout(deadline)
  heldControl.resolve()
  heldApp.resolve()
  heldCrash.resolve()
  try { await Promise.all(runtimes.map(runtime => runtime.close())) } finally {
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}
