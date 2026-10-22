import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { glob, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// Real staged Android profile and skill services; only synthetic inputs, native
// credentials and loopback model HTTP are fixtures. No user home or account is used.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/skill-catalog-profile-'))
const workspace = join(home, 'workspace')
const sessionId = 'skill-catalog-fixture'
const bodies = { ordinary: 'POCKET_ORDINARY_SKILL_BODY', user: 'POCKET_USER_ONLY_SKILL_BODY', model: 'POCKET_MODEL_ONLY_SKILL_BODY' }
const sources = [
  { name: 'pocket-ordinary', description: 'Ordinary skill fixture.', body: bodies.ordinary },
  { name: 'pocket-user-only', description: 'Human invocation fixture.', body: bodies.user, policy: 'disable-model-invocation: true\n' },
  { name: 'pocket-model-only', description: 'Model invocation fixture.', body: bodies.model, policy: 'user-invocable: false\n' },
]
for (const path of [workspace, join(home, 'other-workspace')]) await mkdir(join(path, '.git'), { recursive: true })
for (const source of sources) {
  const directory = join(workspace, '.agents/skills', source.name)
  await mkdir(directory, { recursive: true })
  await writeFile(join(directory, 'SKILL.md'), `---\nname: ${source.name}\ndescription: ${source.description}\n${source.policy ?? ''}---\n${source.body}\n`)
}
const processes = new FixtureProcesses(), vault = new Map(), runtimes = []
const failed = Promise.withResolvers()
let modelCalls = 0, agentCalls = 0, phase = 'startup', deadline
const checkpoint = value => { phase = value; console.error(`[skill-catalog-profile] ${value}`) }
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    modelCalls++
    assert.ok(modelCalls <= 4, 'bounded skill fixture must not loop')
    if (body.tools?.some(tool => tool.name === 'android_shell')) {
      agentCalls++
      assert.equal(agentCalls, 1)
      assert.ok(body.tools.some(tool => tool.name === 'skill'), 'Android preset must mount original skill tool')
      const transcript = JSON.stringify(body)
      assert.match(transcript, /POCKET_USER_ONLY_SKILL_BODY/, 'explicit user-only /name must inject original skill instructions')
      assert.doesNotMatch(transcript, /POCKET_ORDINARY_SKILL_BODY|POCKET_MODEL_ONLY_SKILL_BODY/,
        'catalog listing must not eagerly inject unrelated skill bodies')
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `skill-model-${modelCalls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: 'POCKET_SKILL_INJECTION_OK' } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => { failed.reject(error); response.destroy(error) })
})

function environment(seed) {
  const env = { ...process.env }
  for (const key of Object.keys(env)) if (/^(DSH_|DEEPSEEK_|OPENAI_|ANTHROPIC_|POCKET_)/i.test(key)) delete env[key]
  const origin = `http://127.0.0.1:${model.address().port}`
  return { ...env, DSH_HOME: home, DSH_AGENTS_HOME: join(home, '.agents'), DSH_TELEMETRY_DISABLED: '1',
    DEEPSEEK_BASE_URL: origin, POCKET_SKILL_FIXTURE_MODEL_ORIGIN: origin, POCKET_SKILL_FIXTURE_SEED: seed ? '1' : '0' }
}

function launch(seed) {
  const child = processes.spawn(process.execPath, ['--import', new URL('./skill-catalog-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')],
  { cwd: workspace, env: environment(seed), stdio: ['pipe', 'pipe', 'pipe'] })
  const pending = new Map(), notices = [], waiters = new Set()
  let serial = 0, closing = false, ended = false, failure, closeReceipt, outstandingAtClose
  const lines = createInterface({ input: child.stdout })
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const rejectAll = error => {
    failure ??= error
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear(); waiters.clear()
  }
  const fail = error => {
    rejectAll(error)
    if (!closing) failed.reject(error)
    if (!ended) child.kill('SIGKILL')
  }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    ended = true
    const error = new Error(`Skill fixture runtime exited: ${code ?? signal}`)
    rejectAll(error)
    if (!closing) failed.reject(error)
  })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (ended || failure) return
    try {
      const frame = JSON.parse(line)
      if (frame.method === 'fixture.failed') throw new Error(`Fixture failed: ${frame.params.message}`)
      if (frame.method === 'fixture.unexpectedNetwork') throw new Error('Skill fixture attempted non-fixture network access')
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
      const id = `skills-${++serial}`
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
      try { closeReceipt = await processes.stop(child); return closeReceipt } finally { lines.close() }
    },
    exitEvidence: () => ({ pid: child.pid, ended, ...closeReceipt, outstandingAtClose, pending: pending.size, waiters: waiters.size }),
  }
  runtimes.push(runtime)
  return runtime
}

async function snapshots() {
  const result = {}
  for (const path of await Array.fromAsync(glob('sessions/**/session.v*.jsonl', { cwd: home }))) {
    result[path] = createHash('sha256').update(await readFile(join(home, path))).digest('hex')
  }
  return result
}
async function ready(runtime) {
  await runtime.wait(frame => frame.method === 'runtime.ready')
  await runtime.wait(frame => frame.method === 'fixture.skillsReady')
  assert.equal((await runtime.request('runtime.info')).profile, 'android')
}
async function catalog(runtime, id = sessionId) {
  const result = await runtime.request('api.call', { namespace: 'skills', method: 'list', args: { request: { sessionId: id } } })
  assert.equal(result?._pocket_error, undefined, JSON.stringify(result))
  assert.ok(Array.isArray(result.skills))
  return result.skills
}
function verifyCatalog(skills) {
  for (const source of sources.filter(source => source.name !== 'pocket-model-only')) {
    const skill = skills.find(skill => skill.name === source.name)
    assert.ok(skill, `Missing human-invocable ${source.name}`)
    assert.equal(skill.description, source.description)
    assert.equal(skill.path, join(workspace, '.agents/skills', source.name, 'SKILL.md'))
    assert.equal(skill.modelInvocable, source.name !== 'pocket-user-only')
    assert.equal('content' in skill, false, 'catalog must return summaries, not loaded instruction bodies')
  }
  assert.equal(skills.some(skill => skill.name === 'pocket-model-only'), false)
  const virtual = skills.find(skill => skill.name === 'pocket-virtual')
  assert.ok(virtual)
  assert.equal('path' in virtual, false, 'virtual skills must not receive invented filesystem paths')
}
async function assertCold(runtime, before) {
  assert.deepEqual((await runtime.request('runtime.live')).statuses, {})
  assert.equal(runtime.notices.some(frame => frame.method === 'session.event'), false)
  assert.equal(modelCalls, 0)
  assert.deepEqual(await snapshots(), before, 'catalog reads must not rewrite persisted history')
}

async function scenario() {
  checkpoint('synthetic original storage, then cold restart')
  const initial = launch(true)
  await ready(initial)
  const before = await snapshots()
  assert.equal(Object.keys(before).length, 2)
  await assertCold(initial, before)
  await initial.close()
  const cold = launch(false)
  await ready(cold)
  checkpoint('cold skills/list: original providers, invocation policy, path and virtual entries')
  verifyCatalog(await catalog(cold))
  const other = await catalog(cold, 'skill-catalog-other')
  assert.equal(other.some(skill => sources.some(source => source.name === skill.name)), false, 'project skill discovery must use addressed Session cwd')
  assert.ok(other.some(skill => skill.name === 'pocket-virtual'))
  const malformed = await cold.request('api.call', { namespace: 'skills', method: 'list', args: { sessionId } })
  assert.ok(malformed?._pocket_error, 'missing request wrapper must be rejected')
  const absent = await cold.request('api.call', { namespace: 'skills', method: 'list', args: { request: { sessionId: 'does-not-exist' } } })
  assert.equal(absent?._pocket_error?.code, 'session/not-found')
  await assertCold(cold, before)
  assert.equal((await cold.request('web.status')).enabled, false)

  checkpoint('explicit user-only /name uses original tool-skill injection against loopback model')
  await cold.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-fixture-only' })
  const receipt = await cold.request('session.send', { sessionId, requestId: 'skill-user-invocation',
    text: '/pocket-user-only Exercise the synthetic skill.', provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
  assert.equal(receipt.accepted, true)
  await cold.wait(frame => frame.method === 'session.event' && frame.params.sessionId === sessionId && frame.params.event.type === 'turn/end')
  assert.equal(agentCalls, 1)
  const events = (await cold.request('session.read', { sessionId })).events
  assert.match(JSON.stringify(events), /POCKET_SKILL_INJECTION_OK/)
  const contexts = events.flatMap(event => [event.data?.message, event.data]).filter(message => message?.source)
  const catalogs = contexts.filter(message => message.source.kind === 'skill-catalog')
  assert.ok(catalogs.length > 0, 'original model catalog must be durably published')
  assert.equal(catalogs.some(message => message.source.entries.some(entry => entry.name === 'pocket-user-only')), false)
  for (const name of ['pocket-ordinary', 'pocket-model-only', 'pocket-virtual']) {
    assert.ok(catalogs.some(message => message.source.entries.some(entry => entry.name === name)),
      `model catalog must retain model-invocable ${name}`)
  }
  const injections = contexts.filter(message => message.source.kind === 'skill-invocation')
  assert.ok(injections.some(message => message.source.name === 'pocket-user-only' && JSON.stringify(message).includes(bodies.user)),
    'user-only instructions must be recorded with original skill-invocation metadata')
  verifyCatalog(await catalog(cold))
  await cold.close()
  return { realAndroidProfile: true, originalSkillRegistry: true, exactRequestWrapper: true,
    coldCatalogDoesNotActivateAgent: true, coldCatalogDoesNotRewriteHistory: true, addressedCwd: true,
    userOnlyRetained: true, modelOnlyExcluded: true, exactProviderPaths: true, virtualHasNoPath: true,
    originalUserSkillInjection: true, originalDurableSourceMetadata: true, localModelRequests: modelCalls,
    realModelOrUserCredentials: false, androidBinderOrUi: false, home }
}

let report
try {
  model.listen(0, '127.0.0.1')
  await once(model, 'listening')
  report = await Promise.race([scenario(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Skill catalog smoke exceeded 180 seconds during ${phase}`)), 180000)
  })])
} finally {
  clearTimeout(deadline)
  // Close the allocator before any awaited exit so a timed-out scenario cannot
  // start its second generation while cleanup is in progress.
  const closingProcesses = processes.close()
  try {
    const cleanup = await Promise.allSettled([closingProcesses, ...runtimes.map(runtime => runtime.close())])
    const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
    if (errors.length) throw new AggregateError(errors, 'Skill fixture cleanup failed')
  } finally {
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}
report.processExit = runtimes.map(runtime => runtime.exitEvidence())
assert.ok(report.processExit.every(item => item.ended && item.pending === 0 && item.waiters === 0))
await writeFile(join(home, 'report.json'), JSON.stringify(report, null, 2) + '\n')
console.log(JSON.stringify(report, null, 2))
