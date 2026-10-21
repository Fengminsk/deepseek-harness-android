import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdir, mkdtemp } from 'node:fs/promises'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/session-presets-'))
const workspace = join(home, 'workspace')
await mkdir(workspace)
const processes = new FixtureProcesses(), records = new Map(), pending = new Map(), notices = [], waiters = new Set()
const failed = Promise.withResolvers()
let serial = 0, modelCalls = 0, ended = false, phase = 'startup', deadline
const model = createServer((request, response) => {
  void (async () => {
    const body = JSON.parse(Buffer.concat(await Array.fromAsync(request)).toString())
    assert.ok(++modelCalls < 10, 'fixture must not loop or replay a model request')
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const event of [
      { type: 'message_start', message: { id: `preset-${modelCalls}`, model: body.model, usage: { input_tokens: 1, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: 'preset fixture finished' } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
    response.end()
  })().catch(error => { failed.reject(error); response.destroy(error) })
})
model.listen(0, '127.0.0.1')
await once(model, 'listening')
const child = processes.spawn(process.execPath, ['--import', new URL('./session-presets-smoke-loader.mjs', import.meta.url).href,
  join(root, '.cache/android/runtime-bundle/bootstrap.mjs')], {
  cwd: workspace, env: { ...process.env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1',
    DEEPSEEK_BASE_URL: `http://127.0.0.1:${model.address().port}` }, stdio: ['pipe', 'pipe', 'pipe'],
})
const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
const fail = error => {
  failed.reject(error)
  for (const call of pending.values()) call.reject(error)
  for (const waiter of waiters) waiter.reject(error)
  pending.clear()
  waiters.clear()
}
child.once('error', fail)
child.once('exit', (code, signal) => { ended = true; fail(new Error(`Runtime exited: ${code ?? signal}`)) })
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
        case 'native.credentials.get': result = records.get(name) ?? null; break
        case 'native.credentials.names': result = [...records.keys()]; break
        case 'native.credentials.set': records.set(name, value); result = true; break
        case 'native.credentials.remove': records.delete(name); result = true; break
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
      if (frame.error) call.reject(new Error(frame.error.message))
      else call.resolve(frame.result)
    } else {
      notices.push(frame)
      for (const waiter of waiters) if (waiter.predicate(frame)) { waiters.delete(waiter); waiter.resolve(frame) }
    }
  } catch (error) { fail(error) }
})
const request = (method, params = {}) => {
  if (ended) return Promise.reject(new Error('Runtime is closed'))
  const id = `presets-${++serial}`
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ id, method, params }) })
}
const api = (namespace, method, args = {}) => request('api.call', { namespace, method, args })
const wait = predicate => {
  const found = notices.find(predicate)
  return found ? Promise.resolve(found) : new Promise((resolve, reject) => waiters.add({ predicate, resolve, reject }))
}
const projection = async sessionId => {
  const value = await api('session', 'projections', { request: { sessionId } })
  assert.equal(value.kind, 'sequenced')
  return value.values.agentPreset
}
try {
  await Promise.race([(async () => {
    await wait(frame => frame.method === 'runtime.ready')
    await wait(frame => frame.method === 'fixture.presetsReady')
    phase = 'original preset roster'
    const roster = await api('agentPresets', 'list')
    assert.equal(roster.presets.find(row => row.isDefault)?.id, 'android')
    assert.equal(roster.presets.find(row => row.id === 'android')?.name, 'Android 本地 Agent')
    for (const id of ['fixture-a', 'fixture-b']) assert.ok(roster.presets.some(row => row.id === id && row.broken === undefined), JSON.stringify(roster))
    assert.equal(typeof roster.presets.find(row => row.id === 'fixture-broken')?.broken, 'string')
    const declaration = await api('agentPresets', 'read', { agentPreset: 'fixture-a' })
    assert.equal(declaration.agentPreset, 'fixture-a')
    assert.equal(declaration.content.trim(), '[]')

    phase = 'creation and blank selection'
    await request('session.ensure', { sessionId: 'preset-blank', agentPreset: 'fixture-a' })
    assert.equal(await projection('preset-blank'), 'fixture-a')
    assert.equal(await request('session.selectPreset', { sessionId: 'preset-blank', agentPreset: 'fixture-b' }), 'fixture-b')
    assert.equal(await projection('preset-blank'), 'fixture-b')
    for (const [agentPreset, code] of [['missing', 'agent-preset/not-found'], ['fixture-broken', 'agent-preset/invalid']]) {
      const refusal = await request('session.selectPreset', { sessionId: 'preset-blank', agentPreset })
      assert.equal(refusal._pocket_error.code, code)
      assert.equal(refusal._pocket_error.details.agentPreset, agentPreset)
      assert.equal(await projection('preset-blank'), 'fixture-b')
    }
    const catalog = await request('library.catalog')
    const created = await request('library.sessionCreate', { workspaceId: catalog.workspaces[0].workspaceId,
      sessionId: 'workspace-preset', agentPreset: 'fixture-a' })
    assert.equal(created.agentPreset, 'fixture-a')
    assert.equal(await projection(created.sessionId), 'fixture-a')

    phase = 'shared default and stale settings revision'
    const forms = await api('settings', 'describe')
    const descriptor = forms.namespaces.find(form => form.ns === 'agent-preset-registry')
    assert.ok(descriptor && Number.isSafeInteger(descriptor.revision))
    const updated = await api('settings', 'update', { ns: descriptor.ns, expectedRevision: descriptor.revision,
      patch: { selectedDefault: 'fixture-b' } })
    assert.equal(updated.ns, descriptor.ns, 'the original namespace receipt is not replaced by an App result')
    assert.equal(updated.value.selectedDefault, 'fixture-b')
    assert.ok(updated.revision > descriptor.revision)
    assert.equal((await api('agentPresets', 'list')).presets.find(row => row.isDefault)?.id, 'fixture-b')
    await request('session.ensure', { sessionId: 'preset-default' })
    assert.equal(await projection('preset-default'), 'fixture-b')
    const conflict = await api('settings', 'update', { ns: descriptor.ns, expectedRevision: descriptor.revision,
      patch: { selectedDefault: 'fixture-a' } })
    assert.equal(conflict._pocket_error.code, 'settings/conflict')
    assert.deepEqual(conflict._pocket_error.details, { ns: descriptor.ns, expected: descriptor.revision, actual: updated.revision })
    const rejected = await api('settings', 'update', { ns: 'fixture-missing', expectedRevision: 0, patch: {} })
    assert.equal(rejected._pocket_error.code, 'settings/rejected')
    assert.deepEqual(rejected._pocket_error.details, { ns: 'fixture-missing' })
    const unavailable = await api('fixture-missing', 'list')
    assert.equal(unavailable._pocket_error.code, 'gateway/invocation-unavailable')
    assert.equal(await projection(created.sessionId), 'fixture-a', 'changing default cannot rewrite existing compositions')

    phase = 'first admission then original locked refusal'
    await request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'fixture-only-not-a-real-key' })
    const selected = request('session.selectPreset', { sessionId: 'preset-first-send', agentPreset: 'fixture-a' })
    const sent = request('session.send', { sessionId: 'preset-first-send', requestId: 'preset-single-prompt',
      provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true, text: 'preset smoke fixture' })
    assert.equal(await selected, 'fixture-a')
    await sent
    await wait(frame => frame.method === 'session.event' && frame.params.sessionId === 'preset-first-send'
      && frame.params.event.type === 'turn/end')
    const locked = await request('session.selectPreset', { sessionId: 'preset-first-send', agentPreset: 'fixture-b' })
    assert.equal(locked._pocket_error.code, 'agent-preset/locked')
    assert.equal(await projection('preset-first-send'), 'fixture-a')
    const count = notices.filter(frame => frame.method === 'session.event' && frame.params.sessionId === 'preset-first-send'
      && frame.params.event.type === 'user/message' && frame.params.event.data.source?.rpcId === 'preset-single-prompt').length
    assert.equal(count, 1, 'selection must not replay the first prompt')
    assert.ok(modelCalls > 0, 'fixture must exercise the real model route, including original title generation')
    console.log(JSON.stringify({ realAndroidProfile: true, originalGateway: true, declaredAndBrokenRoster: true,
      readOnlyDeclaration: true, ensurePreset: true, workspacePreset: true, originalDefaultAndRevisionConflict: true,
      selectionBeforeFirstPrompt: true, startedSessionLocked: true, noPromptReplay: true, home }))
  })(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Preset profile timed out at ${phase}`)), 120000)
  })])
} finally {
  clearTimeout(deadline)
  try { await processes.close() } finally {
    lines.close()
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
}
