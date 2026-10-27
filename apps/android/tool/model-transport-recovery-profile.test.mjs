import { replyScheduleWakeupFixture } from './schedule-wakeup-native-fixture.mjs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { randomBytes, randomUUID, createHash } from 'node:crypto'
import { mkdir, mkdtemp, readFile, readdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { startTransportRecoveryModel } from './device-runtime-acceptance/model-transport-recovery-model.mjs'
import { requireTransportRecoveryEvidence } from './device-runtime-acceptance/model-transport-recovery-evidence.mjs'

const root = resolve(import.meta.dirname, '../../..')
const digest = bytes => createHash('sha256').update(bytes).digest('hex')

/** Original packaged Android profile and protocol; native services are explicit host-only storage/settings fixtures. */
test('packaged Android profile retries a consumed SSE reset and persists the same request series', { timeout: 90000 }, async t => {
  const caseId = randomUUID(), sessionId = `android-acceptance-transport-${caseId}`
  const modelKey = randomBytes(32).toString('base64url'), closeToken = randomBytes(32).toString('base64url')
  const home = await mkdtemp(join(root, '.cache/android/model-transport-profile-'))
  const workspace = join(home, 'workspace'); await mkdir(workspace)
  const runtime = join(root, '.cache/android/runtime-bundle')
  const inputNames = ['bootstrap.mjs', 'node_modules/@minnnng/dsh-android-runtime/index.mjs']
  const inputs = Object.fromEntries(await Promise.all(inputNames.map(async name => [name, digest(await readFile(join(runtime, name)))])))
  const model = await startTransportRecoveryModel({ caseId, modelKey, closeToken })
  const environment = { ...process.env, DSH_HOME: home, DEEPSEEK_BASE_URL: model.url, DSH_ANDROID_LINUX_VM_ENABLED: '1' }
  for (const key of ['DEEPSEEK_API_KEY', 'DSH_ANDROID_IPC_FD', 'NODE_OPTIONS', 'NODE_PATH']) delete environment[key]
  const child = spawn(process.execPath, ['--import', new URL('./web-smoke-loader.mjs', import.meta.url).href,
    join(runtime, 'bootstrap.mjs')], { cwd: workspace, env: environment, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true })
  const closed = Promise.withResolvers(), failed = Promise.withResolvers(), ready = Promise.withResolvers(), ended = Promise.withResolvers()
  failed.promise.catch(() => {})
  child.once('error', failed.reject)
  child.once('close', (code, signal) => { closed.resolve({ code, signal }); failed.reject(new Error('Host runtime closed')) })
  let serial = 0, partialConsumed = false, disconnect, stderrBytes = 0, lastNative = null
  const pending = new Map(), records = new Map()
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const request = async (method, params = {}) => {
    const id = `transport-host-${++serial}`, value = Promise.withResolvers()
    const timeout = setTimeout(() => value.reject(new Error(`Runtime RPC deadline: ${method}`)), 15000)
    pending.set(id, value); send({ id, method, params })
    try { return await Promise.race([value.promise, failed.promise]) }
    finally { clearTimeout(timeout); pending.delete(id) }
  }
  const control = async (action, body) => {
    const response = await fetch(`${model.url}/acceptance/${action}`, { method: 'POST', headers: {
      authorization: `Bearer ${closeToken}`, 'x-dsh-acceptance-case': caseId },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(5000) })
    assert.equal(response.status, 200); return response.json()
  }
  const lines = createInterface({ input: child.stdout })
  child.stderr.on('data', chunk => { stderrBytes += chunk.length; if (stderrBytes > 1024 * 1024) failed.reject(new Error('Host runtime diagnostics exceeded limit')) })
  lines.on('line', line => {
    try {
      assert.ok(line.length <= 2 * 1024 * 1024)
      const frame = JSON.parse(line)
      if (replyScheduleWakeupFixture(frame, send)) return
      if (pending.has(frame.id)) {
        const waiter = pending.get(frame.id)
        if (frame.error) waiter.reject(new Error('Runtime RPC rejected'))
        else waiter.resolve(frame.result)
      } else if (frame.method?.startsWith('native.')) {
        lastNative = frame.method
        let result
        if (frame.method === 'native.credentials.get') result = records.get(frame.params.name) ?? null
        else if (frame.method === 'native.credentials.names') result = [...records.keys()]
        else if (frame.method === 'native.credentials.set') { records.set(frame.params.name, frame.params.value); result = true }
        else if (frame.method === 'native.credentials.remove') result = records.delete(frame.params.name)
        else if (frame.method === 'native.storage.root') result = home
        else if (frame.method === 'native.web.preferences') result = { enabled: false, scope: 'local', port: 3080 }
        else if (frame.method === 'native.network.addresses') result = { addresses: [] }
        else if (frame.method === 'native.documents.roots') result = []
        else throw new Error('Unexpected native operation in model-only host acceptance')
        send({ id: frame.id, result })
      } else if (frame.method === 'runtime.ready') ready.resolve()
      else if (frame.method === 'runtime.status' && frame.params.phase === 'failed') failed.reject(new Error('Packaged profile startup failed'))
      else if (frame.params?.sessionId === sessionId) {
        if (frame.method === 'session.live' && !partialConsumed && frame.params.value?.turn === 1 && frame.params.value?.step === 1
          && frame.params.value.content?.filter(block => block.type === 'text').map(block => block.text).join('') === `transport-partial-${caseId}`) {
          partialConsumed = true
          disconnect = control('disconnect'); disconnect.catch(failed.reject)
        }
        if (frame.method === 'session.event' && frame.params.event.type === 'turn/end') ended.resolve(frame.params.event)
      }
    } catch (error) { failed.reject(error) }
  })
  let timer
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Packaged profile recovery deadline')), 70000) })
  try {
    await Promise.race([(async () => {
      await ready.promise
      const info = await request('runtime.info'); assert.equal(info.profile, 'android')
      assert.equal(info.workspace, workspace)
      const created = await request('session.ensure', { sessionId }); assert.equal(created.created, true)
      await request('credentials.set', { ref: 'DEEPSEEK_API_KEY', value: modelKey })
      const accepted = await request('session.send', { sessionId, requestId: `transport-${caseId}`,
        text: `Return transport-recovered-${caseId}.`, provider: 'deepseek-official', model: 'deepseek-flash', selectModel: true })
      assert.equal(accepted.accepted, true)
      const end = await ended.promise
      await disconnect
      assert.equal(partialConsumed, true, JSON.stringify({ kind: end.data.reason.kind, errorCode: end.data.reason.error?.code,
        knownErrors: [...new Set(JSON.stringify(end.data.reason).match(/\b(?:EACCES|EPERM|ENOENT|ENAMETOOLONG)\b/gu) ?? [])] }))
      assert.equal(end.data.reason.kind, 'completed')
      const { events } = await request('session.read', { sessionId, offset: 0 })
      let durable, durableFile
      for (let poll = 0; poll < 100 && !durable; poll++) {
        const files = (await readdir(join(home, 'sessions'), { recursive: true })).filter(name => name.endsWith('.jsonl')
          && name.split(/[\\/]/u).at(-2) === sessionId)
        assert.ok(files.length <= 1)
        if (files.length === 1) {
          const bytes = await readFile(join(home, 'sessions', files[0]))
          if (bytes.at(-1) === 10) {
            const [header, ...rows] = bytes.toString().trim().split('\n').map(line => JSON.parse(line))
            assert.equal(header.type, 'session'); assert.equal(header.version, 4); assert.equal(header.id, sessionId)
            if (rows.some(row => row.type === 'turn/end')) { durable = rows; durableFile = { bytes: bytes.length, sha256: digest(bytes) } }
          }
        }
        if (!durable) await delay(25)
      }
      assert.ok(durable, 'Completed retry JSONL is absent')
      const evidence = requireTransportRecoveryEvidence({ caseId, events, durableEvents: durable, proof: model.snapshot() })
      assert.equal(evidence.sessionLogContinuationChecked, true)
      assert.deepEqual(await control('verify', { events, durableEvents: durable }), evidence)
      for (const [name, mutate] of [
        ['changed model/tool/settings digest', value => { value.requestShapes[1].stableSha256 = '0'.repeat(64) }],
        ['changed existing input', value => { value.requestShapes[1].blocks[0].sha256 = '0'.repeat(64) }],
        ['foreign uploaded Session', value => { value.requestShapes[1].sessionLog.sessionId = 'foreign-session' }],
        ['changed Session header', value => { value.requestShapes[1].sessionLog.headerSha256 = '0'.repeat(64) }],
        ['regressed upload cursor', value => { value.requestShapes[1].sessionLog.afterSeq = -1 }],
        ['malformed event digest', value => { value.requestShapes[1].sessionLog.events[0].sha256 = 'invalid' }],
      ]) await t.test(`rejects ${name} against the real packaged request series`, () => {
        const proof = model.snapshot(); mutate(proof)
        assert.throws(() => requireTransportRecoveryEvidence({ caseId, events, durableEvents: durable, proof }))
      })
      await t.test('rejects a missing durable final reply from the real packaged Session', () => {
        assert.throws(() => requireTransportRecoveryEvidence({ caseId, events,
          durableEvents: durable.filter(row => row.type !== 'assistant/message'), proof: model.snapshot() }))
      })
      for (const name of inputNames) assert.equal(digest(await readFile(join(runtime, name))), inputs[name])
      console.log(JSON.stringify({ scope: 'host-packaged-android-profile', home, inputs, evidence, durableFile,
        requestDifference: model.snapshot().requestDifference }))
    })(), failed.promise, deadline])
  } catch (error) {
    const proof = model.snapshot()
    throw new Error(JSON.stringify({ failure: error.name, partialConsumed, lastNative, stderrBytes,
      modelCalls: proof.modelCalls, failureStage: proof.failureStage, failureReason: proof.failureReason,
      requestDifference: proof.requestDifference }), { cause: error })
  } finally {
    clearTimeout(timer)
    child.kill('SIGTERM')
    if (await Promise.race([closed.promise.then(() => true), delay(5000, false)]) === false) child.kill('SIGKILL')
    assert.notEqual(await Promise.race([closed.promise, delay(5000, null)]), null, 'Host runtime closure unconfirmed')
    lines.close()
    await model.close()
  }
})
