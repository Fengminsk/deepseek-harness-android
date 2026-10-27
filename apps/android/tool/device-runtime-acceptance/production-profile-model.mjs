import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { createHash } from 'node:crypto'
import { isIP } from 'node:net'
import { networkInterfaces } from 'node:os'

const MAX_REQUEST_BYTES = 2 * 1024 * 1024
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const sha256 = text => createHash('sha256').update(text).digest('hex')

/** Normalize only the explicit IPv4, IPv4-mapped IPv6, and IPv6 loopback spellings. */
export function normalizeProductionLoopback(address) {
  if (address === '127.0.0.1') return address
  if (address === '::1') return address
  if (typeof address === 'string' && address.toLowerCase() === '::ffff:127.0.0.1') return '127.0.0.1'
  return null
}

function unicastAddress(value) {
  if (typeof value !== 'string' || value.length > 64) return null
  if (/^::ffff:/iu.test(value) && isIP(value.slice(7)) === 4) return unicastAddress(value.slice(7))
  if (isIP(value) === 4) {
    const first = Number(value.split('.')[0])
    return first === 0 || first >= 224 || first === 127 && value !== '127.0.0.1' ? null : value
  }
  if (isIP(value) === 6 && !value.includes('%')) {
    const normalized = new URL(`http://[${value}]`).hostname.slice(1, -1)
    return normalized === '::' || normalized === '::1' || normalized.startsWith('ff') ? null : normalized
  }
  return null
}

/** Accept an exact current interface assignment, never a subnet or a persisted device-address allowlist. */
export function authorizeProductionModelPeer(remote, local, interfaces) {
  assert.ok(normalizeProductionLoopback(local), 'Model local socket is not an explicit loopback address')
  const loopback = normalizeProductionLoopback(remote)
  if (loopback) return { kind: 'loopback', address: loopback, interface: null }
  const address = unicastAddress(remote)
  assert.ok(address, 'Model peer is not a valid unicast address')
  assert.ok(interfaces && typeof interfaces === 'object' && !Array.isArray(interfaces), 'Current interface snapshot is unavailable')
  const entries = Object.entries(interfaces)
  assert.ok(entries.length <= 64, 'Current interface snapshot exceeds the fixture limit')
  for (const [name, records] of entries) {
    assert.ok(Array.isArray(records) && records.length <= 64, 'Invalid current interface entries')
    for (const record of records) {
      if (record?.internal === false && ['IPv4', 'IPv6', 4, 6].includes(record.family)
        && unicastAddress(record.address) === address) {
        return { kind: 'current-local-interface', address, interface: name.slice(0, 64) }
      }
    }
  }
  throw new Error('Model peer is not assigned to a current local interface')
}

function socketPeer(socket) {
  const address = value => typeof value === 'string' && /^[0-9a-fA-F:.%]{1,64}$/u.test(value) ? value : null
  const family = value => ['IPv4', 'IPv6', 4, 6].includes(value) ? String(value) : null
  return { remoteAddress: address(socket.remoteAddress), remoteFamily: family(socket.remoteFamily),
    localAddress: address(socket.localAddress), localFamily: family(socket.address()?.family) }
}

/** Return bounded error identity and stack locations, excluding exception messages and request values. */
export function productionBootstrapFailure(error) {
  return {
    errorName: typeof error?.name === 'string' && /^[A-Za-z][A-Za-z0-9]{0,63}$/u.test(error.name) ? error.name : 'Error',
    errorCode: typeof error?.code === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/u.test(error.code) ? error.code : null,
    frames: typeof error?.stack === 'string' ? error.stack.split('\n').filter(line => /^\s+at /u.test(line))
      .slice(0, 10).map(line => line.trim().slice(0, 240)) : [],
  }
}
const textEvents = text => [
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
  { type: 'content_block_stop', index: 0 },
]
const callEvents = (id, name, input) => [
  { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id, name, input: {} } },
  { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(input) } },
  { type: 'content_block_stop', index: 0 },
]

function resultFor(messages, id, parse = true) {
  const results = messages.filter(message => message.role === 'user').flatMap(message =>
    Array.isArray(message.content) ? message.content : []).filter(block => block.type === 'tool_result' && block.tool_use_id === id)
  assert.equal(results.length, 1, `Expected one tool result for ${id}`)
  const result = results[0]
  assert.notEqual(result.is_error, true, `Tool ${id} failed`)
  const text = typeof result.content === 'string' ? result.content : result.content
    .filter(block => block.type === 'text').map(block => block.text).join('\n')
  return parse ? JSON.parse(text) : text
}

/**
 * A loopback Messages endpoint issuing two real production tool calls; it never registers tools.
 * @param {object} options - UUID, relative fixture filename, App UID, and serialized evidence writer.
 * @returns {Promise<object>} Local URL, read-only observations, and a joined listener disposer.
 */
export async function startProductionProfileModel({ caseId, fileName, appUid, modelKey, closeToken, expectWorkflow = false, persist = async () => {} }) {
  assert.match(caseId, uuid)
  assert.equal(fileName, `production-profile-${caseId}.txt`)
  assert.ok(Number.isSafeInteger(appUid) && appUid >= 0)
  assert.equal(typeof expectWorkflow, 'boolean')
  for (const token of [modelKey, closeToken]) assert.ok(typeof token === 'string' && /^[A-Za-z0-9_-]{43}$/u.test(token)
    && Buffer.from(token, 'base64url').length === 32 && Buffer.from(token, 'base64url').toString('base64url') === token,
  'Production fixture authentication requires independent 32-byte secrets')
  assert.ok(modelKey !== closeToken, 'Model and closure authentication must use different secrets')
  const marker = `production-profile-${caseId}`
  const ptcId = `production-ptc-${caseId}`, linuxId = `production-linux-${caseId}`
  const workflowId = `production-workflow-${caseId}`, childMarker = `production-child-${caseId}`
  const sessionId = `android-acceptance-production-${caseId}`
  let serial = Promise.resolve(), closed, port
  const handlers = new Set()
  const proof = { schema: 1, caseId, agentCalls: 0, titleCalls: 0, ptcRead: false, linuxPython: false,
    closed: false, failure: null, toolSchemaSha256: null, guestUid: null, retirementConfirmed: false,
    expectWorkflow, workflowCompleted: false, childCalls: 0, childSessionId: null,
    lastRequestStage: 'none', failureStage: null, lastSocketPeer: null, failedSocketPeer: null, lastPeerAddressCheck: null,
    lastAuthenticatedRequest: null, failedRequest: null, unownedRequestCount: 0, lastUnownedRequest: null }
  const requestDescriptor = request => {
    const target = typeof request.url === 'string' ? request.url.split(/[?#]/u, 1)[0] : ''
    const path = target.startsWith('/') && !target.startsWith('//') ? target
      .replaceAll(modelKey, '[redacted]').replaceAll(closeToken, '[redacted]')
      .replace(/[^\x20-\x7e]/gu, '?').slice(0, 192) : null
    return { method: typeof request.method === 'string' && /^[A-Z-]{1,24}$/u.test(request.method) ? request.method : null, path }
  }
  const save = () => { const snapshot = structuredClone(proof); serial = serial.then(() => persist(snapshot)); return serial }
  const close = () => closed ??= (async () => {
    await new Promise((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeAllConnections() })
    const results = await Promise.allSettled(handlers)
    const failures = results.filter(result => result.status === 'rejected').map(result => result.reason)
    if (failures.length) throw new AggregateError(failures, 'Model request handlers did not settle cleanly')
    proof.closed = true
    await save()
  })()
  const server = createServer((request, response) => {
    let requestStage = 'accepted'
    const stage = value => { requestStage = value; proof.lastRequestStage = value }
    const modelAuthenticated = request.headers['x-api-key'] === modelKey
    const closeAuthenticated = request.headers.authorization === `Bearer ${closeToken}`
    const descriptor = requestDescriptor(request)
    const operation = (async () => {
      // Unknown callers cannot mutate the authenticated run or make its proof fail.
      if (!modelAuthenticated && !closeAuthenticated) {
        proof.unownedRequestCount = Math.min(proof.unownedRequestCount + 1, Number.MAX_SAFE_INTEGER)
        proof.lastUnownedRequest = descriptor
        request.resume()
        response.writeHead(401, { 'content-type': 'application/json', connection: 'close' })
        response.end('{"error":{"type":"authentication_error","message":"Fixture authentication required"}}')
        await save()
        return
      }
      proof.lastAuthenticatedRequest = descriptor
      proof.lastSocketPeer = socketPeer(request.socket)
      proof.lastPeerAddressCheck = null
      stage('request-authentication')
      assert.ok(!(modelAuthenticated && closeAuthenticated), 'Ambiguous fixture authentication purposes')
      stage('remote-address')
      const remote = request.socket.remoteAddress, local = request.socket.localAddress
      let interfaces
      if (!normalizeProductionLoopback(remote)) {
        stage('peer-interface-query')
        interfaces = networkInterfaces()
      }
      stage('peer-interface-match')
      proof.lastPeerAddressCheck = authorizeProductionModelPeer(remote, local, interfaces)
      stage('local-address')
      assert.ok(normalizeProductionLoopback(local), 'Model local socket is not an explicit loopback address')
      stage('request-method')
      assert.equal(request.method, 'POST')
      stage(closeAuthenticated ? 'close-path' : 'model-path')
      assert.ok(request.url === (closeAuthenticated ? '/acceptance/close' : '/v1/messages'), 'Invalid authenticated fixture path')
      if (closeAuthenticated) {
        stage('close-authentication')
        assert.ok(request.headers['x-dsh-acceptance-case'] === caseId, 'Closure belongs to another fixture case')
      }
      stage('request-body')
      let size = 0
      const chunks = []
      for await (const chunk of request) {
        size += chunk.length
        assert.ok(size <= MAX_REQUEST_BYTES, 'Model request exceeded the fixture byte limit')
        chunks.push(chunk)
      }
      if (closeAuthenticated) {
        stage('close-empty-body')
        assert.equal(size, 0)
        stage('close-response')
        response.on('finish', () => { void close().catch(error => { proof.failure = String(error.message) }) })
        response.writeHead(200, { 'content-type': 'application/json', connection: 'close' })
        response.end('{"closing":true}')
        return
      }
      stage('model-body')
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
      assert.ok(Array.isArray(body.messages))
      let events = textEvents('Production profile acceptance'), stop = 'end_turn'
      const hasTools = Array.isArray(body.tools) && body.tools.length > 0
      const requestedSession = request.headers['x-deepseek-harness-session-id']
      if (hasTools && requestedSession !== sessionId) {
        stage('child-request')
        assert.equal(expectWorkflow, true, 'Unexpected child Agent request')
        assert.equal(proof.agentCalls, 3, 'Child Agent request occurred outside the workflow step')
        assert.equal(proof.childCalls, 0, 'Workflow child requested more than one model step')
        assert.ok(typeof requestedSession === 'string' && requestedSession.length > 0 && requestedSession.length <= 256)
        assert.ok(JSON.stringify(body.messages).includes(`Return exactly ${childMarker}`))
        assert.equal(body.tools.some(tool => ['android_ptc', 'workflow'].includes(tool.name)), false)
        proof.childCalls++
        proof.childSessionId = requestedSession
        events = textEvents(childMarker)
      } else if (hasTools) {
        stage('parent-tools')
        for (const name of ['android_ptc', 'linux_exec', 'linux_import', 'linux_export', 'linux_inspect']) {
          assert.equal(body.tools.filter(tool => tool.name === name).length, 1, `Production profile omitted or duplicated ${name}`)
        }
        assert.equal(body.tools.filter(tool => tool.name === 'workflow').length, expectWorkflow ? 1 : 0,
          'Production workflow registration differs from the expected build')
        const linux = body.tools.find(tool => tool.name === 'linux_exec')
        for (const field of ['networkHosts', 'networkCallLimit']) {
          assert.equal(Object.hasOwn(linux.input_schema.properties, field), false, `Offline Linux exposed ${field}`)
        }
        const schemaHash = sha256(JSON.stringify(body.tools))
        proof.toolSchemaSha256 ??= schemaHash
        assert.equal(schemaHash, proof.toolSchemaSha256, 'Tool definitions changed during the acceptance turn')
        proof.agentCalls++
        if (proof.agentCalls === 1) {
          stage('ptc-dispatch')
          events = callEvents(ptcId, 'android_ptc', {
            code: `const r = await tools.read({file_path: ${JSON.stringify(fileName)}}); return {marker: r.lines[0].text};`,
            description: 'Read the dedicated production profile fixture',
          })
          stop = 'tool_use'
        } else if (proof.agentCalls === 2) {
          stage('ptc-result')
          assert.deepEqual(resultFor(body.messages, ptcId), { marker })
          proof.ptcRead = true
          const command = ["python3 - <<'PY'", 'import hashlib, io, json, platform, sqlite3, sys, zipfile',
            `marker = ${JSON.stringify(marker)}`, 'db = sqlite3.connect(":memory:")',
            'value = db.execute("select 6 * 7").fetchone()[0]', 'db.close()', 'data = io.BytesIO()',
            'with zipfile.ZipFile(data, "w") as archive:',
            '    archive.writestr(zipfile.ZipInfo("marker.txt", (2020, 1, 1, 0, 0, 0)), marker)',
            'with zipfile.ZipFile(io.BytesIO(data.getvalue())) as archive:',
            '    restored = archive.read("marker.txt").decode()',
            'print(json.dumps({"marker": restored, "sha256": hashlib.sha256(marker.encode()).hexdigest(), "sqlite": value, "platform": sys.platform, "machine": platform.machine()}, sort_keys=True))',
            'PY'].join('\n')
          events = callEvents(linuxId, 'linux_exec', { command, timeoutMs: 120000 })
          stop = 'tool_use'
        } else if (proof.agentCalls === 3) {
          stage('linux-result')
          const receipt = resultFor(body.messages, linuxId)
          assert.equal(receipt.status, 'completed')
          assert.equal(receipt.exitCode, 0)
          assert.equal(receipt.retirementConfirmed, true)
          assert.equal(receipt.cancelled, false)
          assert.equal(receipt.timedOut, false)
          assert.equal(receipt.truncated, false)
          assert.ok(Number.isInteger(receipt.guestUid) && receipt.guestUid !== appUid)
          assert.deepEqual(JSON.parse(receipt.output.trim()), { marker, sha256: sha256(marker), sqlite: 42, platform: 'linux', machine: 'riscv64' })
          proof.linuxPython = true
          proof.guestUid = receipt.guestUid
          proof.retirementConfirmed = true
          proof.linuxRunId = receipt.id
          proof.diskCommitted = receipt.diskCommitted
          if (expectWorkflow) {
            events = callEvents(workflowId, 'workflow', {
              script: `return await agent(${JSON.stringify(`Return exactly ${childMarker}`)});`,
              meta: { name: 'production-profile-child', description: 'One production child Agent with an isolated test model' },
            })
            stop = 'tool_use'
          } else events = textEvents(`production-profile-complete-${caseId}`)
        } else {
          stage('workflow-result')
          assert.equal(expectWorkflow, true)
          assert.equal(proof.agentCalls, 4, 'Unexpected retry or additional Agent request')
          assert.equal(proof.childCalls, 1)
          assert.equal(resultFor(body.messages, workflowId, false),
            `workflow "production-profile-child" completed (1 agent).\nReturn value:\n${JSON.stringify(childMarker)}`)
          proof.workflowCompleted = true
          events = textEvents(`production-profile-complete-${caseId}`)
        }
      } else {
        stage('title-request')
        proof.titleCalls++
        assert.ok(proof.titleCalls <= 4, 'Unexpected background model activity')
      }
      await save()
      response.writeHead(200, { 'content-type': 'text/event-stream' })
      for (const event of [
        { type: 'message_start', message: { id: `production-${proof.agentCalls}`, model: body.model, usage: { input_tokens: 3, output_tokens: 0 } } },
        ...events, { type: 'message_delta', delta: { stop_reason: stop }, usage: { output_tokens: 1 } }, { type: 'message_stop' },
      ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
      response.end()
    })().catch(async error => {
      if (!modelAuthenticated && !closeAuthenticated) throw error
      proof.failureStage = requestStage
      proof.failedSocketPeer ??= socketPeer(request.socket)
      proof.failedRequest ??= descriptor
      proof.failure = String(error.message).slice(0, 2000)
      try { await save() } catch (saveError) { proof.failure += `; evidence write failed: ${saveError.message}` }
      if (!response.destroyed) {
        if (!response.headersSent) response.writeHead(400, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ error: { type: 'invalid_request_error', message: 'Production acceptance fixture rejected a request' } }))
      }
    })
    handlers.add(operation)
    operation.then(() => handlers.delete(operation), () => handlers.delete(operation))
  })
  server.requestTimeout = 15000
  server.headersTimeout = 10000
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  port = server.address().port
  proof.port = port
  try { await save() }
  catch (failure) {
    try { await close() } catch (cleanup) { throw new AggregateError([failure, cleanup], 'Model setup and cleanup failed') }
    throw failure
  }
  return { url: `http://127.0.0.1:${port}`, snapshot: () => structuredClone(proof), close }
}
