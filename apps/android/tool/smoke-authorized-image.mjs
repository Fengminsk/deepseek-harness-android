import { replyScheduleWakeupFixture } from './schedule-wakeup-native-fixture.mjs'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { createServer } from 'node:http'
import { glob, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { basename, dirname, join, resolve, sep } from 'node:path'
import { createInterface } from 'node:readline'

// Run after stage-runtime.ts. The staged native image codec is the APK's package.
const root = resolve(import.meta.dirname, '../../..')
const staged = join(root, '.cache/android/runtime-bundle')
const requireStaged = createRequire(join(staged, 'bootstrap.mjs'))
const sharp = requireStaged('sharp')
const png = await sharp({ create: { width: 1, height: 1, channels: 4,
  background: { r: 255, g: 0, b: 0, alpha: 1 } } }).png().toBuffer()
const digest = createHash('sha256').update(png).digest('hex')
const snapshotPath = join(root, 'apps/android/tool/expected/saf-image-session.expected.json')
const inputPath = join(root, 'apps/android/tool/scenarios/saf-image.json')
const refreshSnapshot = process.argv.length === 3 && process.argv[2] === '--refresh-snapshot'
assert.ok(process.argv.length === 2 || refreshSnapshot, 'Only --refresh-snapshot is accepted')
const expected = JSON.parse(await readFile(snapshotPath, 'utf8'))
assert.equal(expected.format, 'android-profile-recorded-session-projection/v1')
const scenario = JSON.parse(await readFile(inputPath, 'utf8'))
const sessionId = scenario.sessionId
assert.match(sessionId, /^android-[a-z0-9-]+$/)
const prompt = scenario.userText
const toolInput = scenario.toolInput
const finalReply = scenario.modelReply
assert.equal(typeof prompt, 'string')
assert.deepEqual(toolInput, { action: 'read_image', root: 'saf-image-root', path: 'red.png' })
assert.equal(typeof finalReply, 'string')
assert.match(scenario.toolCallId, /^[a-z][a-z0-9-]*$/)
const home = await mkdtemp(join(root, '.cache/android/saf-image-smoke-'))
let model
try {
await mkdir(join(home, 'workspace'))

async function persistedSession() {
  const files = await Array.fromAsync(glob(`sessions/**/${sessionId}/session.v4.jsonl`, { cwd: home }))
  assert.equal(files.length, 1, 'exactly one current-writer Session log must exist')
  return readFile(join(home, files[0]), 'utf8')
}

function message(response, events, stop, serial) {
  response.writeHead(200, { 'content-type': 'text/event-stream' })
  for (const event of [
    { type: 'message_start', message: { id: `saf-image-${serial}`, model: 'deepseek-flash',
      usage: { input_tokens: 3, output_tokens: 0 } } },
    ...events,
    { type: 'message_delta', delta: { stop_reason: stop }, usage: { output_tokens: 1 } },
    { type: 'message_stop' },
  ]) response.write(`data: ${JSON.stringify(event)}\n\n`)
  response.end()
}

const textEvents = text => [
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
  { type: 'content_block_stop', index: 0 },
]
let modelCalls = 0, modelSawImage = false, nativeReads = 0
const credentials = new Map()
const modelFailure = Promise.withResolvers()
model = createServer((request, response) => {
  void (async () => {
    const wire = Buffer.concat(await Array.fromAsync(request))
    if (request.method === 'POST' && request.url?.endsWith('/files')) {
      assert.match(request.headers['content-type'] ?? '', /^multipart\/form-data;/)
      assert.ok(wire.includes(png), 'the model upload must use the authorized image bytes')
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ id: 'saf-image-file', type: 'file', mime_type: 'image/png',
        size_bytes: png.length, created_at: new Date().toISOString(), filename: 'red.png' }))
      return
    }
    assert.equal(request.method, 'POST')
    assert.ok(request.url?.endsWith('/messages'), `Unexpected model URL: ${request.url}`)
    const body = JSON.parse(wire.toString('utf8'))
    if (!body.tools?.some(tool => tool.name === 'android_files')) {
      message(response, textEvents('image smoke'), 'end_turn', modelCalls)
    } else if (++modelCalls === 1) {
      const input = JSON.stringify(toolInput)
      message(response, [
        { type: 'content_block_start', index: 0,
          content_block: { type: 'tool_use', id: scenario.toolCallId, name: 'android_files', input: {} } },
        { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: input } },
        { type: 'content_block_stop', index: 0 },
      ], 'tool_use', modelCalls)
    } else {
      const input = JSON.stringify(body.messages)
      modelSawImage = input.includes('"file_id":"saf-image-file"')
        && !input.includes(png.toString('base64'))
      assert.equal(modelSawImage, true, 'the resumed model must receive the uploaded image file')
      message(response, textEvents(finalReply), 'end_turn', modelCalls)
    }
  })().catch(error => { response.destroy(error); modelFailure.reject(error) })
})
model.listen(0, '127.0.0.1')
await once(model, 'listening')
const modelUrl = `http://127.0.0.1:${model.address().port}`

function launch() {
  const child = spawn(process.execPath, [join(staged, 'bootstrap.mjs')], {
    cwd: join(home, 'workspace'), env: { ...process.env, DSH_HOME: home, DEEPSEEK_BASE_URL: modelUrl },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const pending = new Map()
  const ready = Promise.withResolvers()
  const ended = Promise.withResolvers()
  let serial = 0
  const send = frame => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...frame })}\n`)
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = `saf-image-${++serial}`
    pending.set(id, { resolve, reject })
    send({ id, method, params })
  })
  const lines = createInterface({ input: child.stdout })
  child.stderr.pipe(process.stderr)
  child.once('error', ready.reject)
  child.once('exit', () => {
    const error = new Error('Android image smoke runtime exited')
    ready.reject(error)
    for (const waiter of pending.values()) waiter.reject(error)
    pending.clear()
  })
  lines.on('line', line => {
    const frame = JSON.parse(line)
    if (replyScheduleWakeupFixture(frame, send)) return
    if (frame.method === 'native.storage.root') send({ id: frame.id, result: home })
    else if (frame.method === 'native.credentials.get') send({ id: frame.id,
      result: credentials.get(frame.params.name) ?? null })
    else if (frame.method === 'native.credentials.names') send({ id: frame.id,
      result: [...credentials.keys()] })
    else if (frame.method === 'native.credentials.set') {
      credentials.set(frame.params.name, frame.params.value)
      send({ id: frame.id, result: true })
    } else if (frame.method === 'native.credentials.remove') {
      credentials.delete(frame.params.name)
      send({ id: frame.id, result: true })
    }
    else if (frame.method === 'native.web.preferences') send({ id: frame.id,
      result: { enabled: false, scope: 'local', port: 3080 } })
    else if (frame.method === 'native.network.addresses') send({ id: frame.id, result: { addresses: [] } })
    else if (frame.method === 'native.documents.image.read') {
      nativeReads++
      assert.equal(frame.params.root, toolInput.root)
      assert.equal(frame.params.path, toolInput.path)
      send({ id: frame.id, result: { data: png.toString('base64'), bytes: png.length,
        sha256: digest, version: 'a'.repeat(64), name: 'red.png', mimeType: 'image/png' } })
    } else if (frame.method === 'runtime.ready') ready.resolve()
    else if (frame.method === 'session.event' && frame.params.sessionId === sessionId
      && frame.params.event.type === 'turn/end') ended.resolve()
    else if (pending.has(frame.id)) {
      const waiter = pending.get(frame.id)
      pending.delete(frame.id)
      if (frame.error) waiter.reject(new Error(frame.error.message))
      else waiter.resolve(frame.result)
    } else if (frame.method?.startsWith('native.') && frame.id) {
      send({ id: frame.id, error: { code: -32601, message: `Unsupported native call: ${frame.method}` } })
    }
  })
  return { child, ready: ready.promise, ended: ended.promise, request,
    async close() {
      if (child.exitCode === null && child.signalCode === null) {
        const exit = once(child, 'exit')
        child.kill()
        await exit
      }
      lines.close()
    } }
}

function imageEvent(events) {
  const event = events.find(item => item.type === 'tool/result'
    && item.data?.message?.toolCallId === scenario.toolCallId)
  assert.ok(event, 'durable tool result is missing')
  const content = event.data.message.content
  assert.equal(content[1]?.type, 'image')
  assert.equal(content[1].attachment.mediaType, 'image/png')
  assert.equal(content[1].attachment.bytes, png.length)
  assert.ok(!JSON.stringify(event).includes(png.toString('base64')),
    'raw image bytes must not be persisted in the Session event')
  return content[1].attachment.attachmentId
}

function recordedProjection(events) {
  const relevant = []
  for (const event of events) {
    const data = event.data
    if (event.type === 'request/header' && data?.reason === 'initial') {
      relevant.push({ type: event.type, provider: data.header.config.provider,
        model: data.header.config.model,
        androidFilesTool: data.header.tools.some(tool => tool.name === 'android_files') })
    } else if (event.type === 'user/message' && data?.source?.kind === 'user') {
      relevant.push({ type: event.type, content: data.content })
    } else if (event.type === 'assistant/message') {
      relevant.push({ type: event.type, step: data.step,
        content: data.message.content.map(block => block.type === 'tool-call'
          ? { type: block.type, name: block.name, arguments: JSON.parse(block.arguments) }
          : block) })
    } else if (event.type === 'tool/call') {
      relevant.push({ type: event.type, step: data.step, name: data.name,
        arguments: JSON.parse(data.arguments) })
    } else if (event.type === 'tool/result') {
      relevant.push({ type: event.type, step: data.step, isError: data.message.isError,
        content: data.message.content.map(block => block.type === 'image'
          ? { type: 'image', attachment: { id: '{{image}}', mediaType: block.attachment.mediaType,
            bytes: block.attachment.bytes, width: block.attachment.width,
            height: block.attachment.height, name: block.attachment.name } }
          : block) })
    } else if (event.type === 'turn/end') {
      relevant.push({ type: event.type, reason: data.reason.kind })
    }
  }
  assert.ok(relevant.some(row => row.type === 'request/header' && row.androidFilesTool))
  assert.equal(relevant.filter(row => row.type === 'tool/result').length, 1)
  return { format: 'android-profile-recorded-session-projection/v1', sessionId, events: relevant,
    modelInputUsedUploadedFile: modelSawImage }
}

const timeout = Promise.withResolvers()
const deadline = setTimeout(() => timeout.reject(new Error('Android SAF image smoke timed out')), 60000)
let first, reopened
try {
  await Promise.race([(async () => {
    first = launch()
    await first.ready
    await first.request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: 'local-image-smoke-only' })
    await first.request('api.call', { namespace: 'session', method: 'create',
      args: { request: { sessionId } } })
    const receipt = await first.request('session.send', { sessionId, requestId: 'saf-image-smoke',
      text: prompt, provider: 'deepseek-official',
      model: 'deepseek-flash', selectModel: true })
    assert.equal(receipt.accepted, true)
    await first.ended
    const before = imageEvent((await first.request('session.read', { sessionId })).events)
    await first.close()
    first = undefined
    const rawBefore = await persistedSession()
    assert.ok(rawBefore.includes(before), 'image attachment reference is absent from persisted JSONL')
    assert.ok(!rawBefore.includes(png.toString('base64')), 'persisted JSONL contains raw image bytes')
    reopened = launch()
    await reopened.ready
    const reopenedEvents = (await reopened.request('session.read', { sessionId })).events
    const after = imageEvent(reopenedEvents)
    assert.equal(after, before)
    assert.equal(await persistedSession(), rawBefore, 'cold Session read rewrote the persisted log')
    assert.equal(modelSawImage, true)
    assert.equal(nativeReads, 1)
    assert.equal(modelCalls, 2)
    const projection = recordedProjection(reopenedEvents)
    if (refreshSnapshot) {
      await mkdir(dirname(snapshotPath), { recursive: true })
      await writeFile(snapshotPath, `${JSON.stringify(projection, null, 2)}\n`, { flag: 'w' })
    } else {
      assert.deepEqual(projection, expected,
        'Android image session changed; review and explicitly refresh the recorded projection')
    }
    console.log(JSON.stringify({ realAndroidProfile: true, modelSawImage: true,
      durableImageResultReopened: true, recordedSessionProjection: true, nativeReads }))
  })(), modelFailure.promise, timeout.promise])
} finally {
  clearTimeout(deadline)
  if (first) await first.close()
  if (reopened) await reopened.close()
}
} finally {
  if (model?.listening) {
    model.closeAllConnections()
    await new Promise(resolve => model.close(resolve))
  }
  const cacheRoot = resolve(root, '.cache/android')
  const target = resolve(home)
  assert.ok(target.startsWith(cacheRoot + sep)
    && /^saf-image-smoke-[A-Za-z0-9]{6}$/.test(basename(target)),
  'refusing to remove an unexpected image smoke fixture path')
  await rm(home, { recursive: true, force: true })
}
