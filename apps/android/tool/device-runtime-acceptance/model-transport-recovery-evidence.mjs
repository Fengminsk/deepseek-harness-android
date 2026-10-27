import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { expandAssistantStream } from '@deepseek-ai/dsh-llm'

const TYPES = new Set(['user/message', 'turn/start', 'step/start', 'assistant/attempt', 'llm/retry',
  'llm/retry-started', 'assistant/message', 'step/end', 'turn/end'])
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex')
const FIELD_NAMES = new Set(['model', 'stream', 'messages', 'max_tokens', 'thinking', 'output_config', 'system',
  'temperature', 'stop_sequences', 'tools', 'metadata', 'tool_choice', 'dsh_session_log', 'dsh_plugin_packages'])
const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value !== null && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value
const semanticDigest = value => digest(canonical(value))

function transportSessionLogShape(value) {
  if (value === undefined) return null
  assert.ok(value && typeof value === 'object' && !Array.isArray(value))
  assert.deepEqual(Object.keys(value).sort(), ['afterSeq', 'events', 'session', 'sessionFormatVersion', 'throughSeq', 'version'])
  assert.equal(value.version, 1)
  assert.equal(value.sessionFormatVersion, 4)
  assert.equal(value.session.version, 4)
  assert.equal(typeof value.session.id, 'string')
  assert.ok(Number.isSafeInteger(value.afterSeq) && value.afterSeq >= -1)
  assert.ok(Number.isSafeInteger(value.throughSeq) && value.throughSeq > value.afterSeq)
  assert.ok(Array.isArray(value.events) && value.events.length <= 256
    && value.events.length === value.throughSeq - value.afterSeq)
  const events = value.events.map((event, i) => {
    assert.equal(event.seq, value.afterSeq + 1 + i)
    return { seq: event.seq, sha256: semanticDigest(event) }
  })
  return { sessionId: value.session.id, headerSha256: semanticDigest(value.session),
    afterSeq: value.afterSeq, throughSeq: value.throughSeq, events }
}

function requireSessionLogShape(value) {
  if (value === null) return
  assert.deepEqual(Object.keys(value).sort(), ['afterSeq', 'events', 'headerSha256', 'sessionId', 'throughSeq'])
  assert.ok(typeof value.sessionId === 'string' && value.sessionId.length > 0 && value.sessionId.length <= 256)
  assert.match(value.headerSha256, /^[0-9a-f]{64}$/u)
  assert.ok(Number.isSafeInteger(value.afterSeq) && value.afterSeq >= -1)
  assert.ok(Number.isSafeInteger(value.throughSeq) && value.throughSeq > value.afterSeq)
  assert.ok(Array.isArray(value.events) && value.events.length <= 256 && value.events.length === value.throughSeq - value.afterSeq)
  for (const [i, event] of value.events.entries()) {
    assert.deepEqual(Object.keys(event).sort(), ['seq', 'sha256'])
    assert.equal(event.seq, value.afterSeq + 1 + i)
    assert.match(event.sha256, /^[0-9a-f]{64}$/u)
  }
}

/** Safe complete top-level comparison: unknown names and all values are represented only by hashes and sizes. */
export function transportRequestDifference(first, second) {
  const left = new Map(first.fields.map(field => [field.nameSha256, field]))
  const right = new Map(second.fields.map(field => [field.nameSha256, field]))
  const fields = [...new Set([...left.keys(), ...right.keys()])].sort().flatMap(key => {
    const before = left.get(key) ?? null, after = right.get(key) ?? null
    if (before?.sha256 === after?.sha256) return []
    return [{ name: (after ?? before).name, nameSha256: key,
      semanticChanged: before?.semanticSha256 !== after?.semanticSha256, before, after }]
  })
  return fields
}

/** Retain only digests and fixed role/type labels, never request content or credentials. */
export function transportRequestShape(body) {
  assert.ok(body && typeof body === 'object' && !Array.isArray(body))
  const { messages, ...rest } = body
  assert.ok(Array.isArray(messages) && messages.length <= 256)
  const blocks = messages.flatMap(message => {
    assert.ok(['user', 'assistant', 'system'].includes(message.role) && Array.isArray(message.content))
    assert.deepEqual(Object.keys(message).sort(), ['content', 'role'])
    return message.content.map(block => {
      assert.ok(block && typeof block === 'object' && !Array.isArray(block))
      return { role: message.role, type: block.type === 'text' ? 'text' : 'other', sha256: digest(block) }
    })
  })
  assert.ok(blocks.length <= 256)
  assert.ok(Object.keys(body).length <= 32)
  const fields = Object.keys(body).sort().map(name => {
    const value = body[name]
    return { name: FIELD_NAMES.has(name) ? name : 'other', nameSha256: digest(name),
      type: value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value,
      bytes: Buffer.byteLength(JSON.stringify(value)),
      entries: value !== null && typeof value === 'object' ? Object.keys(value).length : null,
      sha256: digest(value), semanticSha256: digest(canonical(value)) }
  })
  const { dsh_session_log: sessionLog, ...stable } = rest
  return { nonMessageSha256: digest(rest), semanticNonMessageSha256: semanticDigest(rest),
    stableSha256: semanticDigest(stable), sessionLog: transportSessionLogShape(sessionLog), fields, blocks }
}

/** Retries may append live context, but may neither change history nor model/tool settings. */
export function requireTransportRequestContinuation(first, second) {
  for (const shape of [first, second]) {
    assert.deepEqual(Object.keys(shape).sort(), ['blocks', 'fields', 'nonMessageSha256', 'semanticNonMessageSha256', 'sessionLog', 'stableSha256'])
    assert.match(shape.nonMessageSha256, /^[0-9a-f]{64}$/u)
    assert.match(shape.semanticNonMessageSha256, /^[0-9a-f]{64}$/u)
    assert.match(shape.stableSha256, /^[0-9a-f]{64}$/u)
    requireSessionLogShape(shape.sessionLog)
    assert.ok(Array.isArray(shape.blocks) && shape.blocks.length <= 256)
    for (const block of shape.blocks) {
      assert.deepEqual(Object.keys(block).sort(), ['role', 'sha256', 'type'])
      assert.ok(['user', 'assistant', 'system'].includes(block.role) && ['text', 'other'].includes(block.type))
      assert.match(block.sha256, /^[0-9a-f]{64}$/u)
    }
  }
  assert.equal(second.stableSha256, first.stableSha256, 'Retry changed model, tools or another stable request field')
  assert.equal(first.sessionLog === null, second.sessionLog === null, 'Retry changed Session-log availability')
  if (first.sessionLog !== null) {
    assert.equal(second.sessionLog.sessionId, first.sessionLog.sessionId, 'Retry changed uploaded Session')
    assert.equal(second.sessionLog.headerSha256, first.sessionLog.headerSha256, 'Retry changed Session metadata')
    assert.ok(second.sessionLog.afterSeq >= first.sessionLog.throughSeq, 'Retry went behind the accepted upload cursor')
  }
  assert.ok(second.blocks.length >= first.blocks.length, 'Retry removed message blocks')
  assert.deepEqual(second.blocks.slice(0, first.blocks.length), first.blocks, 'Retry changed existing message blocks')
  const added = second.blocks.slice(first.blocks.length)
  assert.ok(added.every(block => block.role === 'user' && block.type === 'text'), 'Retry appended non-context blocks')
  return added
}

/** Validate the same completed retry in the public history and the actual dedicated JSONL log. */
export function requireTransportRecoveryEvidence({ caseId, events, durableEvents, proof }) {
  assert.match(caseId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u)
  for (const rows of [events, durableEvents]) {
    assert.ok(Array.isArray(rows) && rows.length > 0 && rows.length <= 256, 'Session event evidence is missing or oversized')
    assert.ok(rows.every(row => row && typeof row.type === 'string' && Number.isSafeInteger(row.seq)), 'Invalid Session event')
  }
  const project = rows => rows.filter(row => TYPES.has(row.type)).map(({ type, seq, data }) => ({ type, seq, data }))
  assert.deepEqual(project(events), project(durableEvents), 'Public history differs from the persisted retry')
  const all = type => events.filter(row => row.type === type)
  const one = type => { const rows = all(type); assert.equal(rows.length, 1, `Expected exactly one ${type}`); return rows[0] }
  // The shipped profile also records time/runtime context as user-role events;
  // only source.kind=user represents the caller's one submitted message.
  const users = all('user/message').filter(row => row.data.source.kind === 'user')
  assert.equal(users.length, 1, 'Expected one human submission')
  const user = users[0], turn = one('turn/start'), step = one('step/start')
  assert.equal(user.data.source.kind, 'user')
  assert.deepEqual(user.data.content, [{ type: 'text', text: `Return transport-recovered-${caseId}.` }])
  const attempt = one('assistant/attempt'), retry = one('llm/retry'), started = one('llm/retry-started')
  const message = one('assistant/message'), end = one('turn/end')
  one('step/end')
  assert.equal(turn.data.turn, 1)
  assert.equal(step.data.step, 1)
  for (const event of [step, attempt, retry, started, message]) {
    assert.equal(event.data.turn, 1, 'Recovery changed the original turn')
    assert.equal(event.data.step, 1, 'Recovery replayed or replaced the original step')
  }
  assert.equal(retry.data.failure.code, 'TRANSPORT')
  assert.equal(retry.data.provider, 'deepseek-official')
  assert.equal(retry.data.mode, 'normal')
  assert.equal(retry.data.maxRetries, 5, 'The shipped normal retry budget was replaced')
  assert.equal(retry.data.retry, 1)
  assert.ok(retry.data.delayMs >= 450 && retry.data.delayMs <= 550, 'The shipped initial retry delay was replaced')
  assert.equal(started.data.retry, 1)
  assert.equal(typeof retry.data.retryId, 'string')
  assert.ok(retry.data.retryId.length > 0)
  assert.equal(started.data.retryId, retry.data.retryId)
  assert.ok(attempt.seq < retry.seq && retry.seq < started.seq && started.seq < message.seq && message.seq < end.seq)
  const partial = expandAssistantStream(attempt.data.stream).filter(value => value.chunk.type === 'text-delta')
    .map(value => value.chunk.text).join('')
  assert.equal(partial, `transport-partial-${caseId}`, 'The first request was not consumed before the real disconnect')
  assert.deepEqual(message.data.message.content, [{ type: 'text', text: `transport-recovered-${caseId}` }])
  assert.notEqual(message.data.interrupted, true)
  assert.equal(end.data.reason.kind, 'completed')
  assert.ok(events.every(row => !row.type.startsWith('tool/')), 'This recovery fixture must not execute tools')
  assert.equal(proof.caseId, caseId)
  assert.equal(proof.failure, null)
  assert.equal(proof.modelCalls, 2)
  assert.equal(proof.disconnects, 1)
  assert.equal(proof.mode, 'reset')
  assert.equal(proof.requestHashes.length, 2)
  assert.ok(proof.requestHashes.every(value => /^[0-9a-f]{64}$/u.test(value)))
  assert.equal(proof.requestShapes.length, 2)
  const added = requireTransportRequestContinuation(...proof.requestShapes)
  const refreshed = all('user/message').filter(row => row.data.source.kind === 'runtime-context'
    && row.seq > started.seq && row.seq < message.seq)
  const expected = refreshed.flatMap(row => {
    assert.ok(Array.isArray(row.data.content) && row.data.content.length > 0)
    return row.data.content.map(block => {
      assert.deepEqual(Object.keys(block).sort(), ['text', 'type'])
      assert.ok(block.type === 'text' && typeof block.text === 'string')
      return { role: 'user', type: 'text', sha256: digest(block) }
    })
  })
  assert.deepEqual(added, expected, 'Retry additions do not match the durable runtime-context refresh')
  const uploads = proof.requestShapes.map(shape => shape.sessionLog).filter(value => value !== null)
  if (uploads.length > 0) {
    assert.equal(uploads.length, 2)
    for (const [i, upload] of uploads.entries()) {
      assert.equal(upload.sessionId, `android-acceptance-transport-${caseId}`)
      assert.ok(upload.throughSeq < (i === 0 ? attempt.seq : message.seq))
      if (i === 1) assert.ok(upload.throughSeq >= started.seq)
    }
  }
  assert.equal(proof.connectionIds.length, 2)
  assert.notEqual(proof.connectionIds[0], proof.connectionIds[1], 'The retry did not reconnect')
  return { turn: 1, step: 1, modelCalls: 2, retryCount: 1, failureCode: 'TRANSPORT',
    retryId: retry.data.retryId, failedAttemptSeq: attempt.seq, retrySeq: retry.seq,
    retryStartedSeq: started.seq, finalMessageSeq: message.seq, turnEndSeq: end.seq,
    partialConsumed: true, requestBodyUnchanged: proof.requestHashes[0] === proof.requestHashes[1],
    requestChangesAccountedFor: true, runtimeContextUpdates: refreshed.length,
    sessionLogContinuationChecked: uploads.length === 2,
    sessionLogSnapshots: uploads.map(upload => ({ afterSeq: upload.afterSeq, throughSeq: upload.throughSeq,
      eventCount: upload.events.length, headerSha256: upload.headerSha256, eventsSha256: semanticDigest(upload.events) })),
    reconnected: true, durableRetryMatched: true,
    requestSha256: proof.requestHashes[0], retryRequestSha256: proof.requestHashes[1] }
}
