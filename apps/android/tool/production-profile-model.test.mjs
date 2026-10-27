import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID, randomBytes, createHash } from 'node:crypto'
import { startProductionProfileModel, productionBootstrapFailure, normalizeProductionLoopback,
  authorizeProductionModelPeer } from './device-runtime-acceptance/production-profile-model.mjs'

const tools = () => ['android_ptc', 'linux_exec', 'linux_import', 'linux_export', 'linux_inspect']
  .map(name => ({ name, description: name, input_schema: { type: 'object', properties: {} } }))
const result = (id, value, extra = {}) => ({ role: 'user', content: [{ type: 'tool_result',
  tool_use_id: id, content: [{ type: 'text', text: JSON.stringify(value) }], ...extra }] })
async function fixture(t, expectWorkflow = false) {
  const caseId = randomUUID(), persisted = []
  const modelKey = randomBytes(32).toString('base64url'), closeToken = randomBytes(32).toString('base64url')
  const model = await startProductionProfileModel({ caseId, fileName: `production-profile-${caseId}.txt`, appUid: 1234, expectWorkflow,
    modelKey, closeToken,
    persist: async row => { persisted.push(row) } })
  t.after(() => model.close())
  const post = async (body, key = modelKey, sessionId = `android-acceptance-production-${caseId}`) => {
    const response = await fetch(`${model.url}/v1/messages`, { method: 'POST', headers: {
      'content-type': 'application/json', 'x-api-key': key, 'x-deepseek-harness-session-id': sessionId }, body: JSON.stringify(body) })
    const text = await response.text()
    const events = response.ok ? text.trim().split('\n\n').map(line => JSON.parse(line.slice(6))) : []
    const input = events.find(event => event.delta?.type === 'input_json_delta')?.delta.partial_json
    return { status: response.status, events, input: input && JSON.parse(input) }
  }
  return { ...model, caseId, modelKey, closeToken, post, persisted }
}
const request = (messages = [], definitions = tools()) => ({ model: 'deepseek-flash', tools: definitions, messages })

test('the local Messages protocol requests real PTC read then Python and waits for matching tool results', async t => {
  const f = await fixture(t), marker = `production-profile-${f.caseId}`
  const first = await f.post(request())
  assert.equal(first.status, 200)
  assert.deepEqual(f.snapshot().lastSocketPeer, { remoteAddress: '127.0.0.1', remoteFamily: 'IPv4',
    localAddress: '127.0.0.1', localFamily: 'IPv4' })
  assert.equal(first.events.find(event => event.content_block?.type === 'tool_use').content_block.name, 'android_ptc')
  assert.ok(first.input.code.includes(`production-profile-${f.caseId}.txt`))
  const ptc = result(`production-ptc-${f.caseId}`, { marker })
  const second = await f.post(request([ptc]))
  assert.equal(second.status, 200)
  assert.match(second.input.command, /import hashlib, io, json, platform, sqlite3, sys, zipfile/u)
  assert.equal(second.input.timeoutMs, 120000)
  const linux = result(`production-linux-${f.caseId}`, { id: randomUUID(), status: 'completed', exitCode: 0,
    retirementConfirmed: true, cancelled: false, timedOut: false, truncated: false, guestUid: 99001,
    diskCommitted: true, output: JSON.stringify({ marker, sha256: createHash('sha256').update(marker).digest('hex'),
      sqlite: 42, platform: 'linux', machine: 'riscv64' }) + '\n' })
  const last = await f.post(request([ptc, linux]))
  assert.equal(last.status, 200)
  assert.ok(last.events.some(event => event.delta?.text === `production-profile-complete-${f.caseId}`))
  assert.equal(f.snapshot().linuxPython, true)
  const closing = await fetch(`${f.url}/acceptance/close`, { method: 'POST', headers: {
    authorization: `Bearer ${f.closeToken}`, 'x-dsh-acceptance-case': f.caseId } })
  assert.equal(closing.status, 200)
  await closing.text()
  await f.close()
  assert.equal(f.persisted.at(-1).closed, true)
  await assert.rejects(fetch(f.url))
})

for (const missing of ['android_ptc', 'linux_exec']) test(`missing production ${missing} registration fails rather than using a fixture tool`, async t => {
  const f = await fixture(t)
  assert.equal((await f.post(request([], tools().filter(tool => tool.name !== missing)))).status, 400)
  assert.equal(f.snapshot().agentCalls, 0)
  assert.match(f.snapshot().failure, /omitted/u)
})

for (const field of ['networkHosts', 'networkCallLimit']) test(`offline production schema rejects ${field}`, async t => {
  const f = await fixture(t), definitions = tools()
  definitions.find(tool => tool.name === 'linux_exec').input_schema.properties[field] = { type: 'string' }
  assert.equal((await f.post(request([], definitions))).status, 400)
  assert.match(f.snapshot().failure, /Offline Linux exposed/u)
})

test('prompt text, wrong call IDs and tool errors cannot substitute for a successful PTC read', async t => {
  for (const form of ['echo', 'wrong-id', 'error']) {
    const f = await fixture(t), marker = `production-profile-${f.caseId}`
    assert.equal((await f.post(request())).status, 200)
    const messages = form === 'echo' ? [{ role: 'user', content: marker }]
      : [result(form === 'wrong-id' ? 'unrelated' : `production-ptc-${f.caseId}`, { marker }, { is_error: form === 'error' })]
    assert.equal((await f.post(request(messages))).status, 400)
    assert.equal(f.snapshot().ptcRead, false)
  }
})

test('an unretired or App-UID Linux receipt cannot produce a passing model observation', async t => {
  for (const delta of [{ retirementConfirmed: false }, { guestUid: 1234 }]) {
    const f = await fixture(t), marker = `production-profile-${f.caseId}`
    const ptc = result(`production-ptc-${f.caseId}`, { marker })
    await f.post(request())
    await f.post(request([ptc]))
    const response = await f.post(request([ptc, result(`production-linux-${f.caseId}`, {
      status: 'completed', exitCode: 0, retirementConfirmed: true, cancelled: false, timedOut: false,
      truncated: false, guestUid: 99001, ...delta,
    })]))
    assert.equal(response.status, 400)
    assert.equal(f.snapshot().linuxPython, false)
  }
})

test('non-fixture credentials fail without storing their value in evidence', async t => {
  const f = await fixture(t)
  const secret = 'not-an-acceptance-credential'
  assert.equal((await f.post(request(), secret)).status, 401)
  assert.equal(JSON.stringify(f.persisted).includes(secret), false)
  assert.equal(f.snapshot().failureStage, null)
  assert.equal(f.snapshot().unownedRequestCount, 1)
  assert.equal(f.snapshot().agentCalls, 0)
  assert.equal(f.snapshot().titleCalls, 0)
})

test('startup diagnostics omit error messages and cap stack locations', () => {
  const secret = 'private-credential-value'
  const failure = productionBootstrapFailure({ name: 'Error', code: 'EACCES',
    stack: `Error: ${secret}\n` + Array.from({ length: 40 }, (_, n) => `    at module${n} (file:///fixture/start.mjs:4:2)`).join('\n') })
  assert.equal(failure.errorCode, 'EACCES')
  assert.equal(failure.frames.length, 10)
  assert.equal(JSON.stringify(failure).includes(secret), false)
  assert.deepEqual(productionBootstrapFailure({ name: secret, code: secret, stack: secret }),
    { errorName: 'Error', errorCode: null, frames: [] })
})

test('only explicit IPv4, mapped IPv6 and IPv6 loopback addresses are accepted', () => {
  assert.equal(normalizeProductionLoopback('127.0.0.1'), '127.0.0.1')
  assert.equal(normalizeProductionLoopback('::ffff:127.0.0.1'), '127.0.0.1')
  assert.equal(normalizeProductionLoopback('::FFFF:127.0.0.1'), '127.0.0.1')
  assert.equal(normalizeProductionLoopback('::1'), '::1')
  for (const value of [undefined, null, 127001, {}, '', 'localhost', '127.0.0.2', '127.1', '0.0.0.0',
    '::', '192.168.1.1', '203.0.113.1', '::ffff:192.168.1.1', '::ffff:127.0.0.2', '::127.0.0.1',
    '0:0:0:0:0:0:0:1', '::1%lo', '127.0.0.1 ', ' 127.0.0.1', '127.0.0.1\0', '::1\n']) {
    assert.equal(normalizeProductionLoopback(value), null, `Must reject ${String(value)}`)
  }
})

test('non-loopback peers must match a current local interface exactly and terminate at loopback', () => {
  const interfaces = { cellular: [{ address: '10.22.33.44', family: 'IPv4', internal: false }],
    wifi: [{ address: '192.168.1.3', family: 'IPv4', internal: false }],
    ipv6: [{ address: '2001:db8::2', family: 'IPv6', internal: false }] }
  assert.deepEqual(authorizeProductionModelPeer('10.22.33.44', '127.0.0.1', interfaces),
    { kind: 'current-local-interface', address: '10.22.33.44', interface: 'cellular' })
  assert.equal(authorizeProductionModelPeer('::ffff:10.22.33.44', '127.0.0.1', interfaces).interface, 'cellular')
  assert.equal(authorizeProductionModelPeer('2001:db8::2', '::1', interfaces).interface, 'ipv6')
  for (const remote of ['10.22.33.45', '192.168.1.4', '203.0.113.1', '2001:db8::3', undefined, null,
    '0.0.0.0', '::', '224.0.0.1', '255.255.255.255', 'ff02::1', '127.0.0.2']) {
    assert.throws(() => authorizeProductionModelPeer(remote, '127.0.0.1', interfaces))
  }
  assert.throws(() => authorizeProductionModelPeer('10.22.33.44', '0.0.0.0', interfaces))
  assert.throws(() => authorizeProductionModelPeer('10.22.33.44', '10.22.33.44', interfaces))
  assert.throws(() => authorizeProductionModelPeer('10.22.33.44', '127.0.0.1', {}), /not assigned/u)
  assert.throws(() => authorizeProductionModelPeer('10.22.33.44', '127.0.0.1', undefined), /unavailable/u)
})

test('case IDs and model secrets cannot authenticate closure, and secrets never enter proof', async t => {
  for (const tokenName of ['caseId', 'modelKey']) {
    const f = await fixture(t)
    const response = await fetch(`${f.url}/acceptance/close`, { method: 'POST', headers: {
      authorization: `Bearer ${f[tokenName]}`, 'x-dsh-acceptance-case': f.caseId } })
    assert.equal(response.status, 401)
    await response.text()
    assert.equal(f.snapshot().closed, false)
    assert.equal(f.snapshot().failureStage, null)
    assert.equal(f.snapshot().unownedRequestCount, 1)
    assert.equal(JSON.stringify(f.persisted).includes(f.modelKey), false)
    assert.equal(JSON.stringify(f.persisted).includes(f.closeToken), false)
  }
  const f = await fixture(t)
  const mismatch = await fetch(`${f.url}/acceptance/close`, { method: 'POST', headers: {
    authorization: `Bearer ${f.closeToken}`, 'x-dsh-acceptance-case': randomUUID() } })
  assert.equal(mismatch.status, 400)
  await mismatch.text()
  assert.equal(f.snapshot().closed, false)
  assert.equal(f.snapshot().failureStage, 'close-authentication')
})

test('unowned requests cannot poison or advance an authenticated PTC and Linux turn', async t => {
  const f = await fixture(t), marker = `production-profile-${f.caseId}`
  const get = await fetch(`${f.url}/probe?credential=${f.modelKey}`)
  assert.equal(get.status, 401)
  await get.text()
  assert.deepEqual(f.snapshot().lastUnownedRequest, { method: 'GET', path: '/probe' })
  assert.equal((await f.post(request())).status, 200)
  const owned = f.snapshot()
  const rejected = await fetch(`${f.url}/acceptance/close`, { method: 'POST', headers: {
    authorization: `Bearer ${f.modelKey}`, 'x-dsh-acceptance-case': f.caseId }, body: 'not JSON' })
  assert.equal(rejected.status, 401)
  await rejected.text()
  const after = f.snapshot()
  for (const field of ['failure', 'failureStage', 'lastRequestStage', 'lastAuthenticatedRequest',
    'lastSocketPeer', 'lastPeerAddressCheck', 'agentCalls', 'titleCalls', 'closed']) {
    assert.deepEqual(after[field], owned[field], `Unowned request changed ${field}`)
  }
  assert.equal(after.unownedRequestCount, 2)
  const ptc = result(`production-ptc-${f.caseId}`, { marker })
  assert.equal((await f.post(request([ptc]))).status, 200)
  const linux = result(`production-linux-${f.caseId}`, { id: randomUUID(), status: 'completed', exitCode: 0,
    retirementConfirmed: true, cancelled: false, timedOut: false, truncated: false, guestUid: 99001,
    diskCommitted: true, output: JSON.stringify({ marker, sha256: createHash('sha256').update(marker).digest('hex'),
      sqlite: 42, platform: 'linux', machine: 'riscv64' }) })
  assert.equal((await f.post(request([ptc, linux]))).status, 200)
  assert.equal(f.snapshot().linuxPython, true)
  assert.equal(f.snapshot().failure, null)
  assert.equal(JSON.stringify(f.persisted).includes(f.modelKey), false)
  const close = await fetch(`${f.url}/acceptance/close`, { method: 'POST', headers: {
    authorization: `Bearer ${f.closeToken}`, 'x-dsh-acceptance-case': f.caseId } })
  assert.equal(close.status, 200)
  await close.text()
  await f.close()
  assert.equal(f.snapshot().closed, true)
})

test('authenticated invalid methods and paths fail and expose only bounded method and path', async t => {
  for (const [method, path, stage] of [['GET', '/v1/messages', 'request-method'],
    ['POST', '/wrong', 'model-path'], ['POST', '/acceptance/close', 'model-path']]) {
    const f = await fixture(t)
    const response = await fetch(`${f.url}${path}?secret=${f.closeToken}`, { method, headers: { 'x-api-key': f.modelKey } })
    assert.equal(response.status, 400)
    await response.text()
    assert.equal(f.snapshot().failureStage, stage)
    assert.deepEqual(f.snapshot().failedRequest, { method, path })
    assert.equal(f.snapshot().agentCalls, 0)
    assert.equal(f.snapshot().closed, false)
    assert.equal(f.snapshot().unownedRequestCount, 0)
    assert.equal(JSON.stringify(f.persisted).includes(f.closeToken), false)
  }
  const f = await fixture(t)
  const response = await fetch(`${f.url}/${f.modelKey}/${'x'.repeat(512)}?hidden=value`)
  assert.equal(response.status, 401)
  await response.text()
  assert.equal(f.snapshot().lastUnownedRequest.path.length, 192)
  assert.equal(JSON.stringify(f.persisted).includes(f.modelKey), false)
  assert.equal(JSON.stringify(f.persisted).includes('hidden'), false)
})

test('title-only requests do not count as Agent tool evidence', async t => {
  const f = await fixture(t)
  assert.equal((await f.post({ model: 'deepseek-flash', messages: [], tools: [] })).status, 200)
  assert.equal(f.snapshot().agentCalls, 0)
  assert.equal(f.snapshot().linuxPython, false)
})

test('optional workflow waits for one child model call and its matching parent result', async t => {
  const f = await fixture(t, true), marker = `production-profile-${f.caseId}`, child = `production-child-${f.caseId}`
  const definitions = [...tools(), { name: 'workflow', input_schema: { type: 'object', properties: {} } }]
  const ptc = result(`production-ptc-${f.caseId}`, { marker })
  const linux = result(`production-linux-${f.caseId}`, { id: randomUUID(), status: 'completed', exitCode: 0,
    retirementConfirmed: true, cancelled: false, timedOut: false, truncated: false, guestUid: 99001,
    diskCommitted: true, output: JSON.stringify({ marker, sha256: createHash('sha256').update(marker).digest('hex'),
      sqlite: 42, platform: 'linux', machine: 'riscv64' }) })
  await f.post(request([], definitions))
  await f.post(request([ptc], definitions))
  const call = await f.post(request([ptc, linux], definitions))
  assert.equal(call.events.find(event => event.content_block?.type === 'tool_use').content_block.name, 'workflow')
  const childSession = randomUUID()
  const childResponse = await f.post(request([{ role: 'user', content: `Return exactly ${child}` }],
    tools().filter(tool => tool.name !== 'android_ptc')), undefined, childSession)
  assert.equal(childResponse.status, 200)
  const workflow = { role: 'user', content: [{ type: 'tool_result', tool_use_id: `production-workflow-${f.caseId}`,
    content: `workflow "production-profile-child" completed (1 agent).\nReturn value:\n${JSON.stringify(child)}` }] }
  assert.equal((await f.post(request([ptc, linux, workflow], definitions))).status, 200)
  assert.equal(f.snapshot().workflowCompleted, true)
  assert.equal(f.snapshot().childCalls, 1)
  assert.equal(f.snapshot().childSessionId, childSession)
})

test('workflow expectation cannot open a missing product registration or accept an unexpected registration', async t => {
  const missing = await fixture(t, true)
  assert.equal((await missing.post(request())).status, 400)
  const unexpected = await fixture(t)
  assert.equal((await unexpected.post(request([], [...tools(), { name: 'workflow' }]))).status, 400)
})

test('model disposal joins an in-flight evidence write before reporting listener retirement', async () => {
  const caseId = randomUUID(), entered = Promise.withResolvers(), release = Promise.withResolvers()
  const modelKey = randomBytes(32).toString('base64url'), closeToken = randomBytes(32).toString('base64url')
  const model = await startProductionProfileModel({ caseId, fileName: `production-profile-${caseId}.txt`, appUid: 1234,
    modelKey, closeToken,
    async persist(proof) { if (proof.agentCalls === 1 && !proof.closed) { entered.resolve(); await release.promise } } })
  const pending = fetch(`${model.url}/v1/messages`, { method: 'POST', headers: {
    'content-type': 'application/json', 'x-api-key': modelKey,
    'x-deepseek-harness-session-id': `android-acceptance-production-${caseId}` }, body: JSON.stringify(request()) })
    .then(response => response.text(), () => 'connection closed')
  let settled = false
  try {
    await entered.promise
    const closing = model.close().then(() => { settled = true })
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(settled, false)
    release.resolve()
    await closing
    assert.equal(model.snapshot().closed, true)
  } finally { release.resolve(); await model.close(); await pending }
})
