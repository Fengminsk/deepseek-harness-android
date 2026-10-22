import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { load, dump, Type, DEFAULT_SCHEMA } from 'js-yaml'
import { FixtureProcesses } from './fixture-processes.mjs'
import { stagePreset } from './stage-preset.mjs'

// Boot the shipped Android profile with the newly staged preset as its ordinary
// profile overlay. Only model HTTP and native platform services are fixtures.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/portable-tools-profile-'))
const workspace = join(home, 'workspace')
const skillDirectory = join(workspace, '.agents/skills/pocket-fixture')
const profile = join(home, 'profiles/android')
const staged = join(home, 'staged')
await Promise.all([mkdir(skillDirectory, { recursive: true }), mkdir(profile, { recursive: true }), mkdir(staged)])
// Keep the provider's ordinary repository-root discovery inside this fixture,
// rather than inheriting the checkout containing .cache.
await mkdir(join(workspace, '.git'))
await writeFile(join(skillDirectory, 'SKILL.md'), '---\nname: pocket-fixture\ndescription: Local portable skill fixture.\n---\nPOCKET_PORTABLE_SKILL_BODY\n')
const delivered = join(workspace, 'portable-delivery.txt')
await writeFile(delivered, 'POCKET_PORTABLE_DELIVERY\n')
await stagePreset(root, staged)
class JsExpression {
  constructor(source) { this.source = source }
}
const schema = DEFAULT_SCHEMA.extend(new Type('tag:yaml.org,2002:js', {
  kind: 'scalar', construct: source => new JsExpression(source),
  instanceOf: JsExpression, represent: expression => expression.source,
}))
const patch = load(await readFile(join(staged, 'cordis.patch.yml'), 'utf8'), { schema })
const preset = patch.flatMap(row => row.insert ?? []).find(row => row.id === 'preset-android')
assert.ok(preset)
await writeFile(join(profile, 'cordis.patch.yml'), dump([{ id: 'preset-android', config: preset.config }], { schema, lineWidth: -1 }))

const processes = new FixtureProcesses(), vault = new Map(), runtimes = []
const failed = Promise.withResolvers()
let modelCalls = 0, phase = 'startup', timeout
const todo = [
  { content: 'Inspect the skill fixture', status: 'in_progress' },
  { content: 'Inspect the delivery fixture', status: 'in_progress' },
]
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    const agent = body.tools?.some(tool => tool.name === 'android_shell')
    let block = { type: 'text', text: 'Portable fixture' }
    if (agent) {
      const names = body.tools.map(tool => tool.name)
      for (const name of ['skill', 'todo_write', 'present', 'subagent', 'subagent_fork',
        'glob', 'grep', 'web_search', 'web_fetch']) {
        assert.ok(names.includes(name), `real Android preset is missing ${name}`)
      }
      for (const name of ['run_code', 'workflow']) assert.ok(!names.includes(name), `${name} must stay unavailable`)
      const transcript = JSON.stringify(body)
      const step = ++modelCalls
      assert.ok(step <= 5, 'portable tools fixture must not loop')
      const call = (name, input) => ({ type: 'tool_use', id: `portable-${step}`, name, input })
      if (step === 1) {
        assert.ok(transcript.includes('pocket-fixture'), 'the original skill catalogue must discover the workspace fixture')
        assert.ok(transcript.includes('Local portable skill fixture'), 'the catalogue must include its description')
        block = call('skill', { name: 'pocket-fixture' })
      } else if (step === 2) {
        assert.match(transcript, /POCKET_PORTABLE_SKILL_BODY/)
        block = call('todo_write', { todos: todo })
      } else if (step === 3) {
        assert.match(transcript, /2 in progress/)
        block = call('present', { files: [{ path: 'portable-delivery.txt', description: 'Existing fixture delivery' }] })
      } else if (step === 4) {
        assert.match(transcript, /Presented .*portable-delivery\.txt/)
        block = call('present', { files: [{ path: 'missing-delivery.txt' }] })
      } else {
        assert.match(transcript, /file not found/)
        block = { type: 'text', text: 'POCKET_PORTABLE_TOOLS_OK' }
      }
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `portable-${modelCalls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: block },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: block.type === 'tool_use' ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => { failed.reject(error); response.destroy(error) })
})

function launch() {
  const child = processes.spawn(process.execPath, [join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
    cwd: workspace,
    env: { ...process.env, DSH_HOME: home, DSH_AGENTS_HOME: join(home, '.agents'), DSH_TELEMETRY_DISABLED: '1',
      DEEPSEEK_BASE_URL: `http://127.0.0.1:${model.address().port}` },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const pending = new Map(), notices = [], waiters = new Set()
  let serial = 0, stopping = false, ended = false
  const fail = error => {
    if (!stopping) failed.reject(error)
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear(); waiters.clear()
  }
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  child.once('error', fail)
  child.once('exit', (code, signal) => { ended = true; fail(new Error(`Fixture runtime exited: ${code ?? signal}`)) })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  const lines = createInterface({ input: child.stdout })
  lines.on('line', line => {
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
          default: throw new Error(`Unexpected native operation ${frame.method}`)
        }
        send({ id: frame.id, result })
      } else if (pending.has(frame.id)) {
        const call = pending.get(frame.id)
        pending.delete(frame.id)
        if (frame.error) call.reject(new Error(`${call.method}: ${frame.error.message}`))
        else call.resolve(frame.result)
      } else {
        notices.push(frame)
        for (const waiter of waiters) if (waiter.predicate(frame)) { waiters.delete(waiter); waiter.resolve(frame) }
      }
    } catch (error) { fail(error) }
  })
  const runtime = {
    request(method, params = {}) {
      assert.ok(!ended && !stopping, 'runtime must remain available')
      const id = `portable-${++serial}`
      return new Promise((resolve, reject) => { pending.set(id, { resolve, reject, method }); send({ id, method, params }) })
    },
    wait(predicate) {
      const found = notices.find(predicate)
      return found ? Promise.resolve(found) : new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
    },
    async close() {
      stopping = true
      try { await processes.stop(child) } finally { lines.close() }
    },
  }
  runtimes.push(runtime)
  return runtime
}

function checkEvents(events) {
  const writes = events.filter(event => event.type === 'todo/write')
  assert.equal(writes.length, 1, `missing todo event after ${modelCalls} model calls: ${JSON.stringify(events)}`)
  assert.deepEqual(writes[0].data.todos, todo)
  const deliveries = events.filter(event => event.type === 'deliverables/presented')
  assert.equal(deliveries.length, 1, 'a failed present call must not publish a delivery')
  assert.deepEqual(deliveries[0].data.files, [{ path: delivered, description: 'Existing fixture delivery' }])
  assert.match(JSON.stringify(events), /POCKET_PORTABLE_SKILL_BODY/)
  assert.match(JSON.stringify(events), /POCKET_PORTABLE_TOOLS_OK/)
}

try {
  model.listen(0, '127.0.0.1')
  await once(model, 'listening')
  await Promise.race([(async () => {
    const runtime = launch()
    await runtime.wait(frame => frame.method === 'runtime.ready')
    phase = 'real tool invocation'
    await runtime.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-fixture-only' })
    const sessionId = 'portable-tools-fixture'
    const receipt = await runtime.request('session.send', { sessionId, requestId: 'portable-tools',
      text: 'Exercise the portable fixture tools.', provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
    assert.equal(receipt.accepted, true)
    await runtime.wait(frame => frame.method === 'session.event' && frame.params.sessionId === sessionId
      && frame.params.event.type === 'turn/end')
    checkEvents((await runtime.request('session.read', { sessionId })).events)
    assert.equal(modelCalls, 5)
    assert.equal((await runtime.request('web.status')).enabled, false)
    await runtime.close()
    phase = 'cold persisted read'
    const cold = launch()
    await cold.wait(frame => frame.method === 'runtime.ready')
    checkEvents((await cold.request('session.read', { sessionId })).events)
    assert.equal(modelCalls, 5, 'cold history must not activate tools or model calls')
    assert.deepEqual((await cold.request('runtime.live')).statuses, {})
    console.log(JSON.stringify({ realAndroidProfile: true, originalSkillDiscoveryAndRead: true,
      originalParallelTodos: true, originalPresent: true, missingFileRejectedWithoutDelivery: true,
      durableEvents: true, coldReadWithoutReplay: true, webStayedDisabled: true }))
  })(), failed.promise, new Promise((_, reject) => {
    timeout = setTimeout(() => reject(new Error(`Portable tools smoke exceeded 180 seconds during ${phase}`)), 180000)
  })])
} finally {
  clearTimeout(timeout)
  try { await Promise.all(runtimes.map(runtime => runtime.close())); await processes.close() } finally {
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}
