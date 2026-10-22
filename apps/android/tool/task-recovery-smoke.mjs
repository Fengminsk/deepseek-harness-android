import assert from 'node:assert/strict'
import { once } from 'node:events'
import { existsSync } from 'node:fs'
import { glob, mkdir, mkdtemp, readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { FixtureProcesses } from './fixture-processes.mjs'
import { launchRecoveryFixture } from './account-recovery-smoke-support.mjs'

// Real Android profile, original Agent/Session/inbox/approval owners, synthetic
// local inference only. No replacement tools, repair functions or task stores.
const root = resolve(import.meta.dirname, '../../..')
const processes = new FixtureProcesses()
const failed = Promise.withResolvers()
const generations = [], requests = [], steps = [], sockets = new Set(), heldResponses = new Set()
const streamSession = 'recovery-model-stream', shellSession = 'recovery-shell-approval'
const sessionIds = [streamSession, shellSession]
const partialText = 'PARTIAL_STREAM_ONLY'
const shellCallId = 'recovery-original-shell-call'
const marker = 'recovery-shell-must-not-run.txt'
let origin, home, phase = 'setup', deadline, failure, outcome, modelListening, stopping = false
const checkpoint = next => { phase = next; console.error(`[task-recovery] ${next}`) }
const model = createServer((request, response) => {
  void (async () => {
    const path = new URL(request.url, origin).pathname
    assert.ok(path.endsWith('/messages'), `Unexpected fixture endpoint: ${path}`)
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    if (stopping) { response.destroy(); return }
    const agent = body.tools?.some(tool => tool.name === 'android_shell') === true
    const step = agent ? steps.shift() : undefined
    requests.push({ path, agent, step: step ?? 'complete' })
    const emit = event => response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    emit({ type: 'message_start', message: { id: `task-recovery-${requests.length}`, model: body.model,
      usage: { input_tokens: 3, output_tokens: 0 } } })
    if (step === 'hold-stream') {
      // This barrier produces a consumed live prefix but no provider completion.
      heldResponses.add(response)
      response.once('close', () => heldResponses.delete(response))
      emit({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } })
      emit({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: partialText } })
      return
    }
    const tool = step === 'shell-approval'
    const block = tool
      ? { type: 'tool_use', id: shellCallId, name: 'android_shell',
        input: { command: `printf should-not-run > ${marker}` } }
      : { type: 'text', text: agent ? 'fixture completed' : 'Recovery fixture' }
    emit({ type: 'content_block_start', index: 0, content_block: block })
    emit({ type: 'content_block_stop', index: 0 })
    emit({ type: 'message_delta', delta: { stop_reason: tool ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } })
    emit({ type: 'message_stop' })
    response.end()
  })().catch(error => { if (!stopping) failed.reject(error); response.destroy(error) })
})
model.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)) })
model.on('error', error => { if (!stopping) failed.reject(error) })

async function persisted(sessionId) {
  const files = await Array.fromAsync(glob(`sessions/**/${sessionId}/session.v4.jsonl`, { cwd: home }))
  if (!files.length) return []
  assert.equal(files.length, 1)
  // Only complete published records count as durable evidence.
  return (await readFile(join(home, files[0]), 'utf8')).split('\n').slice(0, -1).filter(Boolean).map(JSON.parse)
}
async function until(read, accept, label) {
  const expires = Date.now() + 15000
  while (!stopping) {
    const value = await read()
    if (accept(value)) return value
    if (Date.now() >= expires) throw new Error(`Task recovery observation did not settle: ${label}`)
    await delay(20)
  }
  throw new Error('Task recovery fixture stopped')
}
async function launch() {
  if (stopping) throw new Error('Task recovery fixture stopped')
  const runtime = await launchRecoveryFixture({ processes, root, home, origin, fail: failed.reject,
    register: runtime => generations.push(runtime) })
  await runtime.wait(frame => frame.method === 'runtime.ready')
  assert.equal((await runtime.request('web.status')).enabled, false)
  return runtime
}
const prompt = (runtime, sessionId, requestId, text) => runtime.request('session.send', {
  sessionId, requestId, text, provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true,
})
const admissions = (rows, requestId) => rows.flatMap(row =>
  row.type === 'agent/inbox/spliced' ? row.data.inserted : []).filter(row => row.source?.rpcId === requestId)
const turns = rows => rows.filter(row => row.type === 'turn/start')
const results = rows => rows.filter(row => row.type === 'tool/result')
async function verifyNoReplay(baseline) {
  assert.equal(requests.length, baseline, 'recovery must not replay model requests, including auxiliary calls')
  for (const sessionId of sessionIds) {
    const rows = await persisted(sessionId)
    assert.equal(admissions(rows, `${sessionId}-first`).length, 1, 'submitted prompt is admitted exactly once')
    assert.equal(admissions(rows, `${sessionId}-queued`).length, 1, 'queued prompt is admitted exactly once')
    assert.equal(turns(rows).length, 1, 'recovery cannot begin another turn')
    assert.equal(rows.filter(row => row.type === 'user/message' && row.data.source?.rpcId === `${sessionId}-first`).length, 1)
    assert.equal(rows.filter(row => row.type === 'user/message' && row.data.source?.rpcId === `${sessionId}-queued`).length, 0,
      'retained queued prompt is not consumed by recovery')
  }
  assert.equal(existsSync(join(home, 'workspace', marker)), false, 'unapproved shell must not produce its side effect')
}
async function verifyDormant(runtime, beforeRows, baseline) {
  const summary = await runtime.request('tasks.summary')
  assert.deepEqual(summary.active, [])
  assert.deepEqual(summary.summary, { running: 0, queued: 0, waiting: 0, failed: 0, backgroundJobs: 0, packageOperations: 0 })
  const live = await runtime.request('runtime.live')
  assert.deepEqual(live.statuses, {})
  assert.deepEqual(live.liveMessages, {}, 'a process-local stream prefix cannot be invented after process death')
  const listing = await runtime.request('tasks.list')
  for (const sessionId of sessionIds) {
    assert.ok(listing.sessions.some(row => row.sessionId === sessionId))
    const task = await runtime.request('tasks.session', { sessionId })
    assert.equal(task.observation, 'sequenced')
    assert.equal(task.history[0].status, 'interrupted')
    assert.equal(task.history[0].cancellable, false)
    assert.equal(task.history[0].reason.kind, 'interrupted', 'original cold observation balances the turn in memory')
    assert.equal(task.pending.length, 1)
    assert.equal(task.pending[0].status, 'suspended')
    assert.equal(task.pending[0].cancellable, false)
    const read = await runtime.request('session.read', { sessionId })
    const end = read.events.filter(event => event.type === 'turn/end')
    assert.equal(end.length, 1, 'chat reads include the original in-memory interrupted-turn closure')
    assert.equal(end[0].data.reason.kind, 'interrupted')
    const storedEvents = beforeRows.get(sessionId).filter(row => Number.isSafeInteger(row.seq))
    assert.deepEqual(read.events.slice(0, storedEvents.length), storedEvents)
    if (sessionId === shellSession) {
      const result = read.events.find(event => event.type === 'tool/result')
      assert.equal(result.data.message.toolCallId, shellCallId)
      assert.equal(result.data.message.isError, true)
      assert.equal(result.data.error.code, 'TOOL_OUTCOME_UNKNOWN')
    }
    assert.deepEqual((await runtime.request('session.read', { sessionId })).events, read.events,
      'repeated cold reads produce the same balanced view')
    assert.deepEqual(await persisted(sessionId), beforeRows.get(sessionId), 'read-only recovery must not rewrite the log')
  }
  assert.deepEqual((await runtime.request('interactions.list')).requests, [], 'dead approval responder is not recreated from history')
  await verifyNoReplay(baseline)
  return summary
}

try {
  await Promise.race([(async () => {
    home = await mkdtemp(join(root, '.cache/android/task-recovery-'))
    await mkdir(join(home, 'workspace'))
    if (stopping) return
    model.listen(0, '127.0.0.1')
    modelListening = once(model, 'listening')
    await modelListening
    origin = `http://127.0.0.1:${model.address().port}`
    checkpoint('first generation: consume a real provider stream and await original android_shell approval')
    const first = await launch()
    await first.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'synthetic-task-recovery-key' })
    steps.push('hold-stream')
    await prompt(first, streamSession, `${streamSession}-first`, 'Stream one synthetic fixture reply')
    await first.wait(frame => frame.method === 'session.live' && frame.params.sessionId === streamSession
      && frame.params.value?.content.some(part => part.type === 'text' && part.text.includes(partialText)))
    assert.equal((await first.request('tasks.session', { sessionId: streamSession })).history[0].status, 'running')
    steps.push('shell-approval')
    await prompt(first, shellSession, `${shellSession}-first`, 'Request the synthetic local Shell side effect')
    const requested = await first.wait(frame => frame.method === 'interactions.changed'
      && frame.params.requests.some(row => row.sessionId === shellSession && row.kind === 'approval'))
    const approval = requested.params.requests.find(row => row.sessionId === shellSession && row.kind === 'approval')
    assert.equal((await first.request('tasks.session', { sessionId: shellSession })).history[0].status, 'waiting')
    for (const sessionId of sessionIds) {
      await prompt(first, sessionId, `${sessionId}-queued`, 'Retain this queued input without waking it after recovery')
    }
    const beforeRows = new Map()
    for (const sessionId of sessionIds) {
      beforeRows.set(sessionId, await until(() => persisted(sessionId), rows =>
        turns(rows).length === 1 && admissions(rows, `${sessionId}-queued`).length === 1
        && (sessionId !== shellSession || rows.some(row => row.type === 'tool/call' && row.data.callId === shellCallId)),
      `durable turn, queued input and Shell call for ${sessionId}`))
      assert.equal(beforeRows.get(sessionId).some(row => row.type === 'turn/end'), false)
      assert.equal(results(beforeRows.get(sessionId)).length, 0)
    }
    assert.equal(existsSync(join(home, 'workspace', marker)), false)
    const active = await first.request('tasks.summary')
    assert.equal(active.summary.running, 1)
    assert.equal(active.summary.waiting, 1)
    assert.equal(active.summary.queued, 2)
    checkpoint('SIGKILL with one open model stream, one original approval and two durable queued prompts')
    await first.stop()
    assert.equal((await processes.records.get(first.child).closed).signal, 'SIGKILL')
    await until(async () => heldResponses.size, value => value === 0, 'killed stream socket closes')
    const baseline = requests.length
    // A late title record may have flushed before the kill; capture the exact
    // committed prefix only after the writer has actually exited.
    for (const sessionId of sessionIds) beforeRows.set(sessionId, await persisted(sessionId))

    checkpoint('second generation: cold read-only observations preserve interrupted work and suspended queues')
    const second = await launch()
    assert.notEqual(second.child.pid, first.child.pid)
    const dormant = await verifyDormant(second, beforeRows, baseline)
    assert.notEqual(dormant.epoch, active.epoch)
    const stale = await second.request('interactions.reply', { id: approval.id, version: approval.version, response: 'allowed-once' })
    assert.equal(stale.accepted, false)
    assert.equal(stale.requestStillPending, false)
    await verifyNoReplay(baseline)

    checkpoint('explicit reopen: original core closes unknown outcomes without waking pending work')
    for (const sessionId of sessionIds) {
      assert.equal((await second.request('session.ensure', { sessionId })).created, false)
      const repaired = await until(() => persisted(sessionId), rows => rows.some(row => row.type === 'turn/end'), 'original repair is durable')
      assert.deepEqual(repaired.slice(0, beforeRows.get(sessionId).length), beforeRows.get(sessionId))
      assert.equal(repaired.filter(row => row.type === 'turn/end').length, 1)
      assert.equal(repaired.find(row => row.type === 'turn/end').data.reason.kind, 'interrupted')
      const task = await second.request('tasks.session', { sessionId })
      assert.equal(task.history[0].status, 'interrupted')
      assert.equal(task.history[0].cancellable, false)
      assert.equal(task.pending.length, 1)
      assert.equal(task.pending[0].status, 'queued')
      assert.equal(task.pending[0].cancellable, true)
      assert.equal(task.live.status, 'queued')
      if (sessionId === shellSession) {
        assert.equal(results(repaired).length, 1)
        const result = results(repaired)[0]
        assert.equal(result.data.message.toolCallId, shellCallId)
        assert.equal(result.data.message.isError, true)
        assert.equal(result.data.error.code, 'TOOL_OUTCOME_UNKNOWN')
        assert.deepEqual(result.sourceEventSeqs, [repaired.find(row => row.type === 'tool/call').seq])
      } else {
        assert.equal(results(repaired).length, 0)
        assert.equal(repaired.some(row => row.type === 'assistant/message'), false, 'unfinished text cannot become a completed assistant message')
      }
    }
    assert.deepEqual((await second.request('interactions.list')).requests, [])
    const resumed = await second.request('tasks.summary')
    assert.equal(resumed.summary.running, 0)
    assert.equal(resumed.summary.waiting, 0)
    assert.equal(resumed.summary.queued, 2)

    // Prove the no-replay guard catches a real extra submission, not merely a
    // fabricated counter. This intentionally failing mode is synthetic-only.
    if (process.argv.includes('--negative-control-replay')) {
      await prompt(second, streamSession, 'intentional-negative-control-write', 'Trigger a real extra model request')
      await until(async () => requests.length, value => value > baseline, 'negative-control extra inference')
    }
    await verifyNoReplay(baseline)
    await second.stop()
    const repairedRows = new Map(await Promise.all(sessionIds.map(async id => [id, await persisted(id)])))
    checkpoint('third generation: repeated original resume is idempotent and does not consume queues')
    const third = await launch()
    for (const sessionId of sessionIds) {
      await third.request('session.ensure', { sessionId })
      assert.deepEqual(await persisted(sessionId), repairedRows.get(sessionId), 'balanced recovery must append no duplicate closers')
      const task = await third.request('tasks.session', { sessionId })
      assert.equal(task.history[0].status, 'interrupted')
      assert.equal(task.pending.length, 1)
    }
    await verifyNoReplay(baseline)
    outcome = { androidProfile: true, nodeGenerations: generations.length, interruptedModelStream: true,
      originalAndroidShellApproval: true, coldReadDoesNotRewrite: true, originalRepairOutcome: 'TOOL_OUTCOME_UNKNOWN',
      oldApprovalRejected: true, queuedPromptsPreserved: 2, noInferenceOrToolReplay: true, repairIdempotent: true,
      chatColdReadShowsInterrupted: true, chatColdReadShowsUnknownToolOutcome: true,
      androidProcessGroupKillTested: false, home }
  })(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Task recovery fixture timed out at ${phase}`)), 120000)
  })])
} catch (error) { failure = error }
finally {
  stopping = true
  clearTimeout(deadline)
  const cleanup = await Promise.allSettled([
    ...generations.map(runtime => runtime.stop()), processes.close(),
    (async () => {
      await Promise.allSettled([modelListening])
      const closed = [...sockets].map(socket => {
        const done = once(socket, 'close')
        socket.destroy()
        return done
      })
      const listenerClosed = model.listening
        ? new Promise((resolve, reject) => model.close(error => error ? reject(error) : resolve())) : Promise.resolve()
      await Promise.all([...closed, listenerClosed])
      assert.equal(sockets.size, 0)
      assert.equal(heldResponses.size, 0)
    })(),
  ])
  const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) failure = new AggregateError([...(failure ? [failure] : []), ...errors], 'Task recovery cleanup did not settle')
  else console.error(`[task-recovery] cleanup complete: ${generations.length} generations; all processes and listeners closed`)
}
if (failure) { console.error(failure); process.exitCode = 1 }
else console.log(JSON.stringify(outcome))
