import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { glob, mkdir, mkdtemp, readFile, unlink, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// Original staged Android composition, instruction/time plugins and jobs-local.
// Only model responses, native callbacks and a deferred job producer are fixtures.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/portable-context-profile-'))
const workspace = join(home, 'workspace'), scratch = join(home, 'runtime-temp')
const sessionId = 'portable-context-main', foreignSession = 'portable-context-foreign'
for (const path of [workspace, scratch, join(workspace, 'nested')]) await mkdir(path, { recursive: true })
await writeFile(join(workspace, '.git'), 'gitdir: ../not-a-repository\n')
await writeFile(join(workspace, 'AGENTS.md'), 'ROOT_RULE_V1\n')
await writeFile(join(workspace, 'CLAUDE.md'), 'ROOT_RULE_V1\n')
await writeFile(join(workspace, 'AGENTS.local.md'), 'LOCAL_OVERLAY_RULE\n')
await writeFile(join(workspace, 'nested', 'AGENTS.md'), 'NESTED_RULE_V1\n')
await writeFile(join(workspace, 'nested', 'data.txt'), 'NESTED_DOCUMENT\n')
const processes = new FixtureProcesses(), runtimes = [], vault = new Map(), failed = Promise.withResolvers()
let phase = 'setup', deadline, mode = 'instructions', agentCalls = 0, totalCalls = 0, ownJob, foreignJob, wakeJob
const counts = {}, requests = []
const checkpoint = value => { phase = value; console.error(`[portable-context-profile] ${value}`) }
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    assert.ok(++totalCalls <= 32, 'Synthetic model requests must remain bounded')
    let block = { type: 'text', text: 'Synthetic portable context title' }
    if (body.tools?.some(tool => tool.name === 'android_shell')) {
      agentCalls++
      const names = body.tools.map(tool => tool.name)
      for (const name of ['read', 'job_list', 'job_output', 'job_kill']) assert.ok(names.includes(name), `Missing original ${name}`)
      const number = counts[mode] = (counts[mode] ?? 0) + 1
      requests.push({ mode, number, body })
      const call = (name, input) => ({ type: 'tool_use', id: `portable-${mode}-${number}`, name, input })
      if (mode === 'instructions') {
        assert.ok(number <= 2)
        assert.match(JSON.stringify(body.messages), /ROOT_RULE_V1/)
        assert.match(JSON.stringify(body.messages), /LOCAL_OVERLAY_RULE/)
        assert.match(JSON.stringify(body.messages), /Asia\/Shanghai/)
        if (number === 2) assert.match(JSON.stringify(body.messages), /NESTED_RULE_V1/)
        block = number === 1 ? call('read', { file_path: 'nested/data.txt' }) : { type: 'text', text: 'CONTEXT_READY' }
      } else if (mode === 'jobs') {
        const steps = [
          ['job_list', {}], ['job_output', { job_id: ownJob }], ['job_output', { job_id: ownJob }],
          ['job_output', { job_id: ownJob, wait: true, timeout_ms: 1 }],
          ['job_output', { job_id: foreignJob }], ['job_kill', { job_id: foreignJob }],
          ['job_kill', { job_id: ownJob, reason: 'fixture explicit cancellation' }],
          ['job_output', { job_id: ownJob, wait: true, timeout_ms: 5000 }], ['job_list', {}],
        ]
        assert.ok(number <= steps.length + 1)
        block = number <= steps.length ? call(...steps[number - 1]) : { type: 'text', text: 'JOBS_READY' }
      } else if (mode === 'wake') {
        assert.ok(number <= 3)
        if (number === 1) assert.match(JSON.stringify(body.messages.at(-1)), /completion wake.*finished/)
        if (number === 2) assert.match(JSON.stringify(body.messages.at(-1)), /FIXTURE_JOB_COMPLETE/)
        if (number === 3) assert.doesNotMatch(JSON.stringify(body.messages.at(-1)), /FIXTURE_JOB_COMPLETE|FIRST_OUTPUT|FINAL_OUTPUT/)
        block = number <= 2 ? call('job_output', { job_id: wakeJob }) : { type: 'text', text: 'CONTEXT_WAKE' }
      } else {
        assert.equal(number, 1)
        if (mode === 'changed') assert.match(JSON.stringify(body.messages), /ROOT_RULE_V2/)
        if (mode === 'cold') assert.match(JSON.stringify(body.messages), /ROOT_RULE_OFFLINE/)
        block = { type: 'text', text: `CONTEXT_${mode.toUpperCase()}` }
      }
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `portable-${totalCalls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
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
    DEEPSEEK_BASE_URL: origin, POCKET_CONTEXT_MODEL_ORIGIN: origin, TMP: scratch, TEMP: scratch, TMPDIR: scratch }
}

function launch() {
  const child = processes.spawn(process.execPath, ['--import', new URL('./portable-context-smoke-loader.mjs', import.meta.url).href,
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
    const error = new Error(`Portable context runtime exited: ${code ?? signal}`)
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
      const id = `portable-${++serial}`
      return new Promise((resolve, reject) => { pending.set(id, { resolve, reject, method }); send({ id, method, params }) })
    },
    wait(predicate, after = 0) {
      if (ended || failure) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const existing = notices.slice(after).find(predicate)
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

const sourceEvents = (events, kind) => events.filter(event => event.type === 'user/message' && event.data.source.kind === kind)
const eventOf = (frame, type, turn) => frame.method === 'session.event' && frame.params.sessionId === sessionId
  && frame.params.event.type === type && frame.params.event.data.turn === turn
const resultFor = (events, number) => {
  const result = events.find(event => event.type === 'tool/result' && event.data.message.toolCallId === `portable-jobs-${number}`)
  assert.ok(result, `Missing original job result ${number}`)
  return result.data
}
async function ready(runtime) {
  await runtime.wait(frame => frame.method === 'runtime.ready')
  await runtime.wait(frame => frame.method === 'fixture.portableContextReady')
  assert.equal((await runtime.request('web.status')).phase, 'disabled')
}
async function send(runtime, text, turn, selectModel = false, clientTimeZone = 'Asia/Shanghai') {
  const from = runtime.notices.length
  const receipt = await runtime.request('session.send', { sessionId, requestId: randomUUID(), text,
    provider: 'deepseek-official', model: 'deepseek-flash', selectModel, clientTimeZone })
  assert.equal(receipt.accepted, true, JSON.stringify(receipt))
  await runtime.wait(frame => eventOf(frame, 'turn/end', turn), from)
  await runtime.wait(frame => frame.method === 'session.status' && frame.params.sessionId === sessionId
    && frame.params.status === 'idle', from)
}
async function logHashes() {
  const hashes = {}
  for (const path of await Array.fromAsync(glob('sessions/**/session.v*.jsonl', { cwd: home }))) {
    hashes[path] = createHash('sha256').update(await readFile(join(home, path))).digest('hex')
  }
  return hashes
}

async function scenario() {
  const runtime = launch()
  await ready(runtime)
  await runtime.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-portable-fixture-only' })
  checkpoint('original instruction baseline, nested discovery and durable request time zone')
  await send(runtime, 'PORTABLE_CONTEXT_FIRST', 1, true)
  const first = (await runtime.request('session.read', { sessionId })).events
  await writeFile(join(home, 'first-turn.json'), JSON.stringify({ first, errors: runtime.notices.filter(frame => frame.method === 'session.error') }, null, 2))
  const instructionEvents = sourceEvents(first, 'agent-instructions')
  assert.equal(instructionEvents.length, 2)
  assert.equal(instructionEvents.filter(event => event.data.source.baseline === true).length, 1)
  assert.equal(instructionEvents[0].data.content.map(part => part.text ?? '').join('').match(/ROOT_RULE_V1/g).length, 1,
    'same-directory AGENTS/CLAUDE duplicates must remain deduplicated by the original loader')
  assert.match(JSON.stringify(instructionEvents[1]), /NESTED_RULE_V1/)
  assert.equal(sourceEvents(first, 'time-context').length, 1, 'the original 10-minute refresh avoids injecting on every tool step')
  assert.match(JSON.stringify(sourceEvents(first, 'time-context')), /Asia\/Shanghai/)
  assert.equal(sourceEvents(first, 'user').find(event => event.data.source.rpcId).data.source.clientTimeZone, 'Asia/Shanghai')

  checkpoint('live instruction replacement/removal without rewriting earlier events')
  await writeFile(join(workspace, 'AGENTS.md'), 'ROOT_RULE_V2\n')
  await writeFile(join(workspace, 'CLAUDE.md'), 'ROOT_RULE_V2\n')
  await unlink(join(workspace, 'nested', 'AGENTS.md'))
  mode = 'changed'
  await send(runtime, 'PORTABLE_CONTEXT_CHANGED', 2)
  const changed = (await runtime.request('session.read', { sessionId })).events
  assert.deepEqual(changed.slice(0, first.length), first)
  const delta = sourceEvents(changed, 'agent-instructions').at(-1)
  assert.ok(delta.data.source.changes.some(change => change.action === 'replace' && change.path === 'AGENTS.md'))
  assert.ok(delta.data.source.changes.some(change => change.action === 'remove' && /nested[/\\]AGENTS\.md/.test(change.path)))

  checkpoint('original job tools, output cursor, timeout, owner fencing and cancellation')
  await runtime.request('session.ensure', { sessionId: foreignSession })
  ownJob = (await runtime.request('fixture.startJob', { owner: sessionId, label: 'owned synthetic work' })).id
  foreignJob = (await runtime.request('fixture.startJob', { owner: foreignSession, label: 'foreign synthetic work' })).id
  mode = 'jobs'
  await send(runtime, 'PORTABLE_JOBS', 3)
  const jobs = (await runtime.request('session.read', { sessionId })).events
  assert.match(JSON.stringify(resultFor(jobs, 1)), new RegExp(ownJob))
  assert.doesNotMatch(JSON.stringify(resultFor(jobs, 1)), new RegExp(foreignJob))
  assert.match(JSON.stringify(resultFor(jobs, 2)), /FIRST_OUTPUT/)
  assert.doesNotMatch(JSON.stringify(resultFor(jobs, 3)), /FIRST_OUTPUT/)
  assert.match(JSON.stringify(resultFor(jobs, 4)), /running/)
  for (const number of [5, 6]) assert.equal(resultFor(jobs, number).message.isError, true)
  for (const number of [1, 2, 3, 4, 7, 8, 9]) assert.equal(resultFor(jobs, number).message.isError, false)
  assert.match(JSON.stringify(resultFor(jobs, 8)), /killed/)
  const state = await runtime.request('fixture.inspectJobs')
  assert.equal(state.jobs.find(job => job.id === ownJob).status, 'killed')
  assert.equal(state.jobs.find(job => job.id === foreignJob).status, 'running')
  assert.equal(state.producers.find(job => job.id === ownJob).cancelled, 1)
  assert.equal(state.producers.find(job => job.id === foreignJob).cancelled, 0)
  assert.equal(sourceEvents(jobs, 'tool-jobs').length, 0, 'a model-requested kill must not generate a second completion wake')

  checkpoint('uncollected original completion wakes its owning idle Agent once')
  const wake = await runtime.request('fixture.startJob', { owner: sessionId, label: 'completion wake' })
  wakeJob = wake.id
  mode = 'wake'
  const from = runtime.notices.length
  await runtime.request('fixture.settleJob', { id: wake.id })
  await runtime.wait(frame => eventOf(frame, 'turn/end', 4), from)
  await runtime.wait(frame => frame.method === 'session.status' && frame.params.sessionId === sessionId && frame.params.status === 'idle', from)
  const afterWake = (await runtime.request('session.read', { sessionId })).events
  assert.equal(sourceEvents(afterWake, 'tool-jobs').length, 1)
  assert.match(JSON.stringify(sourceEvents(afterWake, 'tool-jobs')), /completion wake.*finished/)
  const jobEvents = afterWake.filter(event => event.type === 'job/registered' || event.type === 'job/settled')
  assert.equal(jobEvents.length, 4)

  checkpoint('pending producer cleanup settles through the original registry before process shutdown')
  const foreignDisposed = await runtime.request('fixture.cleanupJobs', { owner: foreignSession })
  assert.ok(foreignDisposed.jobs.every(job => job.status === 'killed'))
  assert.equal(foreignDisposed.producers.find(job => job.id === foreignJob).cancelled, 1)
  const mainDisposed = await runtime.request('fixture.cleanupJobs', { owner: sessionId })
  assert.ok(mainDisposed.jobs.every(job => job.status === 'completed' || job.status === 'killed'))
  assert.ok(mainDisposed.producers.every(producer => producer.settled))
  const before = await logHashes(), callsBeforeRestart = agentCalls
  await runtime.close()

  checkpoint('cold read preserves history; resume reconciles offline instructions and validates zones')
  await writeFile(join(workspace, 'AGENTS.md'), 'ROOT_RULE_OFFLINE\n')
  await writeFile(join(workspace, 'CLAUDE.md'), 'ROOT_RULE_OFFLINE\n')
  const cold = launch()
  await ready(cold)
  assert.deepEqual((await cold.request('session.read', { sessionId })).events, afterWake)
  assert.deepEqual(await logHashes(), before)
  assert.equal(agentCalls, callsBeforeRestart)
  assert.deepEqual((await cold.request('runtime.live')).statuses, {})
  await assert.rejects(cold.request('session.send', { sessionId, requestId: randomUUID(), text: 'INVALID_ZONE',
    provider: 'deepseek-official', model: 'deepseek-flash', clientTimeZone: 'Not/A_Real_Zone' }), /valid IANA/)
  assert.equal(agentCalls, callsBeforeRestart)
  mode = 'cold'
  await send(cold, 'PORTABLE_CONTEXT_COLD', 5, false, 'UTC')
  const resumed = (await cold.request('session.read', { sessionId })).events
  assert.deepEqual(resumed.slice(0, afterWake.length), afterWake)
  const lastInstruction = sourceEvents(resumed, 'agent-instructions').at(-1)
  assert.match(JSON.stringify(lastInstruction), /ROOT_RULE_OFFLINE/)
  assert.equal(lastInstruction.data.source.baseline, undefined, 'same workspace resume reconciles instead of replaying a baseline')
  assert.equal(sourceEvents(resumed, 'user').at(-1).data.source.clientTimeZone, 'UTC')
  assert.equal(sourceEvents(resumed, 'time-context').length, 1, 'time projection survives a cold resume inside refresh interval')
  await cold.request('fixture.cleanupJobs', { owner: sessionId })
  await cold.close()
  return { home, realAndroidProfile: true, originalPlugins: ['agent-instructions', 'time-context', 'tool-jobs'],
    baselineDedupAndLocalOverlay: true, nestedInstructionTouch: true, instructionReplacementAndRemoval: true,
    durableClientTimeZone: true, originalInvalidZoneRejection: true, originalClockRefreshAndColdProjection: true,
    originalJobRegistry: true, originalJobTools: true, outputCursorAndWaitTimeout: true, foreignJobAccessDenied: true,
    modelKillNotDuplicated: true, uncollectedCompletionWake: true, producerCleanupSettled: true,
    coldReadNoReplayOrRewrite: true, offlineInstructionReconciliation: true, webEnabled: false,
    modelProvider: 'local synthetic SSE through original adapter and Agent loop',
    jobProducer: 'owned deferred fixture through original JobRegistry.start; no Android Shell background claim',
    androidBinderOrDevice: false, agentCalls, totalCalls, counts, durableJobEvents: jobEvents.length }
}

let report
try {
  model.listen(0, '127.0.0.1')
  await once(model, 'listening')
  report = await Promise.race([scenario(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Portable context smoke exceeded 180 seconds during ${phase}`)), 180000)
  })])
} finally {
  clearTimeout(deadline)
  const cleanup = await Promise.allSettled([processes.close(), ...runtimes.map(runtime => runtime.close())])
  model.closeAllConnections()
  await new Promise(resolve => model.close(resolve))
  const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) throw new AggregateError(errors, 'Portable context fixture cleanup failed')
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
