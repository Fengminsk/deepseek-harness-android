import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { glob, mkdtemp, mkdir, readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'

// Real built Android profile, original Session/inbox/approval owners, local model fixture.
// Process restart reuses only this test's home and encrypted-vault stand-in.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/tasks-profile-'))
await mkdir(join(home, 'workspace'))
const vault = new Map(), steps = []
let requests = 0
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    const isAgent = body.tools?.some(tool => tool.name === 'smoke_approval')
    const step = isAgent ? steps.shift() : undefined
    if (isAgent) requests++
    if (step === 'fail') {
      response.writeHead(400, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'task fixture failure' } }))
      return
    }
    const block = step === 'approval'
      ? { type: 'tool_use', id: `approval-${requests}`, name: 'smoke_approval', input: { command: 'fixture' } }
      : { type: 'text', text: 'task completed' }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `task-${requests}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: block },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: step === 'approval' ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => response.destroy(error))
})
model.listen(0, '127.0.0.1')
await once(model, 'listening')

const runtimes = []
function launch() {
  const child = spawn(process.execPath, ['--import', new URL('./interaction-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: join(home, 'workspace'),
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
    try { receive(line) } catch (error) { stop(error) }
  })
  function receive(line) {
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
        default:
          send({ id: frame.id, error: { code: -32601, message: `Unexpected native request ${frame.method}` } })
          return
      }
      send({ id: frame.id, result })
    } else if (pending.has(frame.id)) {
      const call = pending.get(frame.id)
      pending.delete(frame.id)
      if (frame.error) call.reject(new Error(frame.error.message))
      else call.resolve(frame.result)
    } else {
      notices.push(frame)
      for (const waiter of waiters) if (waiter.predicate(frame)) {
        waiters.delete(waiter)
        waiter.resolve(frame)
      }
    }
  }
  const runtime = {
    notices,
    request(method, params = {}) {
      if (failure || ended) return Promise.reject(failure ?? new Error('Runtime is stopped'))
      const id = `tasks-${++serial}`
      return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ id, method, params }) })
    },
    wait(predicate) {
      if (failure || ended) return Promise.reject(failure ?? new Error('Runtime is stopped'))
      const existing = notices.find(predicate)
      if (existing) return Promise.resolve(existing)
      return new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
    },
    async close() {
      if (!ended) child.kill('SIGKILL')
      let closeDeadline
      try {
        return await Promise.race([closed, new Promise((_, reject) => {
          closeDeadline = setTimeout(() => reject(new Error('Fixture runtime did not close after SIGKILL')), 15000)
        })])
      } finally {
        clearTimeout(closeDeadline)
        lines.close()
      }
    },
  }
  runtimes.push(runtime)
  return runtime
}
const started = performance.now()
const checkpoint = label => console.error(`[tasks-profile ${Math.round(performance.now() - started)}ms] ${label}`)
let deadline
try {
  await Promise.race([(async () => {
    const first = launch()
    const request = (...args) => first.request(...args)
    await first.wait(frame => frame.method === 'runtime.ready')
    checkpoint('first process ready')
    const baseline = await request('tasks.summary')
    assert.equal(baseline.summary.backgroundJobs, 0, 'real profile must have a ready JobRegistry baseline')
    assert.deepEqual(baseline.active, [])
    const exported = await request('configuration.transfer.export')
    assert.ok(exported.sections.some(section => section.fields.length > 0))
    assert.ok(exported.excluded.some(item => item.ns === 'android-runtime'))
    assert.equal(exported.text.includes('local-task-fixture-key'), false)
    const preview = await request('configuration.transfer.preview', { text: exported.text })
    assert.equal(preview.issues.length, 0)
    assert.ok(preview.sections.every(section => section.changes.length === 0))
    await request('configuration.transfer.release', { id: preview.id })
    checkpoint('actual configuration export and preview')
    await request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-task-fixture-key' })
    const prompt = (sessionId, requestId, text) => request('session.send', { sessionId, requestId, text,
      provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
    const finish = id => first.wait(frame => frame.method === 'session.event'
      && frame.params.sessionId === id && frame.params.event.type === 'turn/end')
    const approval = id => first.wait(frame => frame.method === 'interactions.changed'
      && frame.params.requests.some(row => row.sessionId === id))

    steps.push('approval')
    await prompt('queue', 'first', 'Wait for the fixture approval')
    await approval('queue')
    await prompt('queue', 'second', 'Retained followup')
    const queued = await request('tasks.session', { sessionId: 'queue' })
    assert.equal(queued.pending.length, 1)
    assert.equal(queued.history[0].status, 'waiting')
    const waiting = await request('tasks.summary')
    assert.equal(waiting.summary.waiting, 1)
    assert.equal(waiting.summary.running, 0)
    assert.equal(waiting.summary.queued, 1)
    await request('tasks.cancel', { sessionId: 'queue' })
    await finish('queue')
    const stopped = await request('tasks.session', { sessionId: 'queue' })
    assert.equal(stopped.history.find(row => row.kind === 'turn').status, 'cancelled')
    assert.equal(stopped.pending.length, 1, 'stop must retain the original inbox')
    await request('tasks.removeQueued', { sessionId: 'queue', itemId: stopped.pending[0].itemId })
    const removed = await request('tasks.session', { sessionId: 'queue' })
    assert.equal(removed.pending.length, 0)
    assert.ok(removed.history.some(row => row.kind === 'discarded'))
    checkpoint('real approval, queue, cancel and explicit removal')

    steps.push('fail')
    await prompt('failure', 'failure', 'Cause one local provider failure')
    await finish('failure')
    const failed = await request('tasks.session', { sessionId: 'failure' })
    assert.equal(failed.history[0].status, 'failed', JSON.stringify(failed.history[0]))
    assert.match(failed.history[0].reason.error.message, /task fixture failure/)
    await prompt('completed', 'completed', 'Complete one turn')
    await finish('completed')
    assert.equal((await request('tasks.session', { sessionId: 'completed' })).history[0].status, 'completed')
    checkpoint('durable failure and completed turn')

    steps.push('approval')
    await prompt('crashed', 'crashed', 'Leave a pending approval at process loss')
    await approval('crashed')
    await prompt('crashed', 'retained', 'Keep this inbox item after process loss')
    assert.equal((await request('tasks.session', { sessionId: 'crashed' })).pending.length, 1)
    // Prompt acknowledgement is admission, not a persistence flush. Only claim
    // recovery of this occurrence once the original writer has published it.
    const durableDeadline = performance.now() + 10000
    while (true) {
      const files = await Array.fromAsync(glob('sessions/**/crashed/session.v4.jsonl', { cwd: home }))
      const persisted = files.length === 1 ? await readFile(join(home, files[0]), 'utf8') : ''
      const queued = persisted.split('\n').slice(0, -1).filter(Boolean).some(line => {
        const record = JSON.parse(line)
        return record.type === 'agent/inbox/spliced'
          && record.data.inserted.some(message => message.source?.rpcId === 'retained')
      })
      if (queued) break
      if (performance.now() > durableDeadline) throw new Error('Fixture queued input was not persisted within 10 seconds')
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    const stoppedProcess = await first.close()
    assert.equal(stoppedProcess.signal, 'SIGKILL', 'recovery must follow abrupt process loss, not graceful shutdown')
    const beforeRestartRequests = requests
    const second = launch()
    await second.wait(frame => frame.method === 'runtime.ready')
    checkpoint('replacement process ready')
    const current = await second.request('tasks.summary')
    assert.notEqual(current.epoch, baseline.epoch)
    assert.deepEqual(current.summary, { running: 0, queued: 0, waiting: 0, failed: 0, backgroundJobs: 0 })
    const list = await second.request('tasks.list')
    assert.ok(list.sessions.some(row => row.sessionId === 'failure'))
    const recoveredFailure = await second.request('tasks.session', { sessionId: 'failure' })
    assert.equal(recoveredFailure.history[0].status, 'failed')
    const recovered = await second.request('tasks.session', { sessionId: 'crashed' })
    assert.equal(recovered.history.find(row => row.kind === 'turn').status, 'interrupted')
    assert.equal(recovered.pending.length, 1)
    assert.equal(recovered.pending[0].status, 'suspended')
    assert.equal(recovered.pending[0].cancellable, false)
    assert.equal(requests, beforeRestartRequests, 'observation must never replay queued prompts')
    assert.deepEqual((await second.request('tasks.summary')).active, [])
    console.log(JSON.stringify({ realProfile: true, jobsBaseline: true, configurationExportPreview: true,
      waitingApproval: true, cancelRetainsQueue: true, explicitRemoval: true, durableFailure: true,
      completedTurn: true, processRecovery: true, noAutomaticReplay: true }))
  })(), new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error('Task profile smoke exceeded 120 seconds')), 120000) })])
} finally {
  clearTimeout(deadline)
  try {
    await Promise.all(runtimes.map(runtime => runtime.close()))
  } finally {
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}
