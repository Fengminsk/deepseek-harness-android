import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { createHash } from 'node:crypto'
import { networkInterfaces } from 'node:os'
import { authorizeProductionModelPeer, normalizeProductionLoopback, productionBootstrapFailure } from './production-profile-model.mjs'
import { requireTransportRecoveryEvidence, requireTransportRequestContinuation, transportRequestShape, transportRequestDifference } from './model-transport-recovery-evidence.mjs'

const MAX_BYTES = 2 * 1024 * 1024
const reasonKey = Symbol('fixture failure reason')
const demand = (value, reason) => {
  if (!value) throw Object.assign(new Error('Transport fixture rejected an owned request'), { [reasonKey]: reason })
}
const textEvents = text => [
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
]

/** A real held SSE socket; only an authenticated observer of the consumed prefix may disconnect it. */
export async function startTransportRecoveryModel({ caseId, modelKey, closeToken, mode = 'reset', persist = async () => {} }) {
  assert.match(caseId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u)
  assert.ok(['reset', 'eof'].includes(mode))
  for (const key of [modelKey, closeToken]) assert.ok(typeof key === 'string' && /^[A-Za-z0-9_-]{43}$/u.test(key)
    && Buffer.from(key, 'base64url').length === 32 && Buffer.from(key, 'base64url').toString('base64url') === key,
  'Fixture authentication requires a canonical 32-byte secret')
  assert.notEqual(modelKey, closeToken, 'Control and model credentials must be independent')
  const sessionId = `android-acceptance-transport-${caseId}`
  const proof = { schema: 1, caseId, sessionId, mode, modelCalls: 0, titleCalls: 0, disconnects: 0,
    requestHashes: [], requestShapes: [], connectionIds: [], partialFlushed: false, verified: false, evidence: null, closed: false,
    unauthenticatedRequests: 0, lastRequestStage: 'none', failureStage: null, failureReason: null,
    requestDifference: null, failure: null }
  const handlers = new Set(), connections = new Map()
  let serial = Promise.resolve(), closing, held, nextConnection = 1
  const save = () => { const snapshot = structuredClone(proof); serial = serial.then(() => persist(snapshot)); return serial }
  const writeEvent = (response, event) => response.write(`data: ${JSON.stringify(event)}\n\n`)
  const finish = response => {
    writeEvent(response, { type: 'content_block_stop', index: 0 })
    writeEvent(response, { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } })
    writeEvent(response, { type: 'message_stop' })
    response.end()
  }
  const close = () => closing ??= (async () => {
    const socketClosures = [...connections.values()].map(value => value.closed)
    await new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve())
      server.closeAllConnections()
    })
    await Promise.all(socketClosures)
    const results = await Promise.allSettled(handlers)
    const errors = results.filter(value => value.status === 'rejected').map(value => value.reason)
    if (errors.length) throw new AggregateError(errors, 'Transport fixture handlers failed to settle')
    assert.equal(connections.size, 0, 'Transport fixture connections did not close')
    proof.closed = true
    await save()
  })()
  const server = createServer((request, response) => {
    let requestStage = 'authenticate'
    const stage = value => { requestStage = value; proof.lastRequestStage = value }
    const operation = (async () => {
      // A local service may probe the ephemeral listener. Only possession of a
      // purpose-specific secret admits a request into this fixture's outcome.
      const modelAuthenticated = request.headers['x-api-key'] === modelKey
      const controlAuthenticated = request.headers.authorization === `Bearer ${closeToken}`
      if (!modelAuthenticated && !controlAuthenticated) {
        proof.unauthenticatedRequests = Math.min(proof.unauthenticatedRequests + 1, 1000000)
        await save()
        response.writeHead(401, { connection: 'close' })
        response.end()
        return
      }
      stage('peer')
      const peer = request.socket.remoteAddress
      authorizeProductionModelPeer(peer, request.socket.localAddress, normalizeProductionLoopback(peer) ? undefined : networkInterfaces())
      stage('method')
      demand(request.method === 'POST', 'method')
      stage('body')
      let bytes = 0
      const chunks = []
      for await (const chunk of request) { bytes += chunk.length; assert.ok(bytes <= MAX_BYTES, 'Fixture request exceeds byte limit'); chunks.push(chunk) }
      const raw = Buffer.concat(chunks)
      if (request.url.startsWith('/acceptance/')) {
        stage('control-authentication')
        demand(request.headers.authorization === `Bearer ${closeToken}`, 'control-credential')
        demand(request.headers['x-dsh-acceptance-case'] === caseId, 'control-case')
        let result
        if (request.url === '/acceptance/disconnect') {
          stage('disconnect')
          assert.equal(bytes, 0)
          assert.ok(held && !held.destroyed && proof.partialFlushed, 'No live partial SSE request to interrupt')
          assert.equal(proof.disconnects, 0, 'Disconnect is single-use')
          proof.disconnects++
          const socket = held.socket
          if (mode === 'reset') {
            const gone = once(socket, 'close')
            held.destroy()
            await gone
          } else held.end() // A normal EOF may retain HTTP keep-alive until fixture close.
          await save()
          result = { disconnected: true, mode }
        } else if (request.url === '/acceptance/verify') {
          stage('verify')
          assert.ok(bytes > 0)
          const evidence = JSON.parse(raw.toString('utf8'))
          assert.deepEqual(Object.keys(evidence).sort(), ['durableEvents', 'events'])
          try { proof.evidence = requireTransportRecoveryEvidence({ ...evidence, caseId, proof }) }
          catch (error) { error[reasonKey] = 'evidence-validation'; throw error }
          proof.verified = true
          await save()
          result = proof.evidence
        } else {
          stage('close')
          demand(request.url === '/acceptance/close', 'control-path')
          assert.equal(bytes, 0)
          response.once('finish', () => { close().catch(error => {
            if (proof.failure === null) {
              proof.failure = productionBootstrapFailure(error)
              proof.failureStage = 'close'; proof.failureReason = 'listener-close'
            }
          }) })
          result = { closing: true }
        }
        response.writeHead(200, { 'content-type': 'application/json', connection: 'close' })
        response.end(JSON.stringify(result))
        return
      }
      stage('model-authentication')
      demand(request.url === '/v1/messages', 'model-path')
      demand(request.headers['x-api-key'] === modelKey, 'model-credential')
      stage('model-json')
      const body = JSON.parse(raw.toString('utf8'))
      assert.ok(Array.isArray(body.messages))
      const isAgent = Array.isArray(body.tools) && body.tools.length > 0
      if (!isAgent) {
        stage('auxiliary-response')
        assert.ok(++proof.titleCalls <= 4, 'Unexpected auxiliary model activity')
        response.writeHead(200, { 'content-type': 'text/event-stream' })
        writeEvent(response, { type: 'message_start', message: { id: 'transport-title', model: body.model, usage: { input_tokens: 1, output_tokens: 0 } } })
        for (const event of textEvents('Transport recovery')) writeEvent(response, event)
        finish(response)
        await save()
        return
      }
      stage('agent-identity')
      demand(request.headers['x-deepseek-harness-session-id'] === sessionId, 'agent-session')
      demand(body.messages.some(message => message.role === 'user' && Array.isArray(message.content)
        && message.content.some(block => block.type === 'text' && block.text === `Return transport-recovered-${caseId}.`)), 'agent-prompt')
      demand(++proof.modelCalls <= 2, 'model-call-limit')
      proof.requestHashes.push(createHash('sha256').update(raw).digest('hex'))
      proof.connectionIds.push(connections.get(request.socket).id)
      stage('request-shape')
      proof.requestShapes.push(transportRequestShape(body))
      if (proof.modelCalls === 2) {
        stage('retry-continuation')
        demand(proof.disconnects === 1, 'retry-before-disconnect')
        const [first, second] = proof.requestShapes
        proof.requestDifference = {
          rawBodyEqual: proof.requestHashes[0] === proof.requestHashes[1],
          nonMessageFieldsEqual: first.nonMessageSha256 === second.nonMessageSha256,
          semanticNonMessageFieldsEqual: first.semanticNonMessageSha256 === second.semanticNonMessageSha256,
          stableFieldsEqual: first.stableSha256 === second.stableSha256,
          changedFields: transportRequestDifference(first, second),
          firstBlocks: first.blocks.length, retryBlocks: second.blocks.length,
          existingBlocksEqual: JSON.stringify(first.blocks) === JSON.stringify(second.blocks.slice(0, first.blocks.length)),
        }
        try { requireTransportRequestContinuation(first, second) }
        catch (error) { error[reasonKey] = 'request-continuation'; throw error }
      }
      stage(proof.modelCalls === 1 ? 'partial-response' : 'retry-response')
      response.writeHead(200, { 'content-type': 'text/event-stream' })
      response.flushHeaders()
      writeEvent(response, { type: 'message_start', message: { id: `transport-${proof.modelCalls}`, model: body.model, usage: { input_tokens: 1, output_tokens: 0 } } })
      for (const event of textEvents(`transport-${proof.modelCalls === 1 ? 'partial' : 'recovered'}-${caseId}`)) writeEvent(response, event)
      if (proof.modelCalls === 1) { held = response; proof.partialFlushed = true }
      else finish(response)
      await save()
    })().catch(async error => {
      if (proof.failure === null) {
        proof.failure = productionBootstrapFailure(error)
        proof.failureStage = requestStage
        proof.failureReason = error[reasonKey] ?? 'validation-or-io'
      }
      try { await save() } catch (failure) { throw new AggregateError([error, failure], 'Transport fixture evidence could not be saved') }
      if (!response.destroyed) {
        if (!response.headersSent) response.writeHead(400, { 'content-type': 'application/json' })
        response.end('{"error":{"type":"invalid_request_error","message":"Transport fixture rejected request"}}')
      }
    })
    handlers.add(operation)
    operation.then(() => handlers.delete(operation), () => {})
  })
  server.on('connection', socket => {
    const closed = new Promise(resolve => socket.once('close', () => { connections.delete(socket); resolve() }))
    connections.set(socket, { id: nextConnection++, closed })
  })
  server.requestTimeout = 15000
  server.headersTimeout = 10000
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  proof.port = server.address().port
  try { await save() } catch (failure) {
    try { await close() } catch (cleanup) { throw new AggregateError([failure, cleanup], 'Transport setup and cleanup failed') }
    throw failure
  }
  return { url: `http://127.0.0.1:${proof.port}`, snapshot: () => structuredClone(proof), close }
}
