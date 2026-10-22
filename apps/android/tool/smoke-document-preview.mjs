import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { copyFile, glob, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// Real Android profile, original Gateway/workspaceFiles/fs/storage, Web off.
// Native Binder identity and the one cancellation timing barrier are fixtures.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/document-preview-profile-'))
const workspace = join(home, 'workspace')
const processes = new FixtureProcesses(), runtimes = [], vault = new Map()
const failed = Promise.withResolvers()
let phase = 'starting', deadline
const checkpoint = value => { phase = value; console.error(`[document-preview-profile] ${value}`) }
const hash = data => createHash('sha256').update(data).digest('hex')
const value = result => { assert.equal(result.ok, true, JSON.stringify(result)); return result.value }
const rejected = (result, code) => { assert.equal(result.ok, false, JSON.stringify(result)); if (code) assert.equal(result.error.code, code) }

function fixtureEnvironment(seed) {
  const env = { ...process.env }
  for (const key of Object.keys(env)) if (/^(DSH_|DEEPSEEK_|OPENAI_|ANTHROPIC_|POCKET_)/i.test(key)) delete env[key]
  return { ...env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1', POCKET_DOCUMENT_FIXTURE_SEED: seed ? '1' : '0' }
}

function launch(seed) {
  const child = processes.spawn(process.execPath, ['--import', new URL('./document-preview-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')],
  { cwd: workspace, env: fixtureEnvironment(seed), stdio: ['pipe', 'pipe', 'pipe'] })
  const pending = new Map(), notices = [], waiters = new Set()
  let ended = false, closing = false, failure, serial = 0, closeReceipt, outstandingAtClose
  const lines = createInterface({ input: child.stdout })
  const send = frame => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...frame }) + '\n')
  const rejectAll = error => {
    failure ??= error
    for (const call of pending.values()) call.reject(error)
    for (const waiter of waiters) waiter.reject(error)
    pending.clear()
    waiters.clear()
  }
  const fail = error => { rejectAll(error); if (!closing) failed.reject(error); if (!ended) child.kill('SIGKILL') }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    ended = true
    const error = new Error(`Document runtime exited: ${code ?? signal}`)
    rejectAll(error)
    if (!closing) failed.reject(error)
  })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (failure || ended) return
    try {
      const frame = JSON.parse(line)
      if (frame.method === 'fixture.failed') throw new Error(`Document fixture failed: ${frame.params.message}`)
      if (frame.method === 'fixture.unexpectedNetwork') throw new Error('Read-only document preview requested network access')
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
        const call = pending.get(frame.id)
        pending.delete(frame.id)
        if (frame.error) call.reject(new Error(`${call.method}: ${frame.error.message}`))
        else if (frame.result?._pocket_error) call.reject(new Error(`${call.method}: ${frame.result._pocket_error.message}`))
        else call.resolve(frame.result)
      } else {
        notices.push(frame)
        for (const waiter of waiters) if (waiter.predicate(frame)) {
          waiters.delete(waiter)
          waiter.resolve(frame)
        }
      }
    } catch (error) { fail(error) }
  })
  const runtime = {
    notices, send,
    request(method, params = {}) {
      if (ended || failure) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const id = `document-preview-${++serial}`
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
    diagnostics: () => ({ pid: child.pid, pending: [...pending.values()].map(call => call.method), notices: notices.length }),
    exitEvidence: () => ({ pid: child.pid, ended, ...closeReceipt, outstandingAtClose,
      pendingRequests: pending.size, pendingWaiters: waiters.size }),
  }
  runtimes.push(runtime)
  return runtime
}

async function snapshotLogs() {
  const logs = {}
  for (const path of await Array.fromAsync(glob('sessions/**/session.v*.jsonl', { cwd: home }))) logs[path] = hash(await readFile(join(home, path)))
  return logs
}

async function assertCold(runtime) {
  assert.deepEqual((await runtime.request('runtime.live')).statuses, {}, 'preview must not activate an Agent')
  const catalog = await runtime.request('library.catalog')
  for (const id of ['document-fixture-a', 'document-fixture-b']) {
    const session = catalog.sessions.find(item => item.sessionId === id)
    assert.ok(session, `cold persisted Session missing: ${id}`)
    assert.equal(session.agentAvailable, false)
    assert.equal(session.running, false)
  }
  assert.equal(runtime.notices.some(frame => frame.method === 'session.event'), false, 'preview must not append or replay history')
  assert.equal((await runtime.request('web.status')).phase, 'disabled')
}

async function scenario() {
  const source = Buffer.alloc(600000)
  for (let i = 0; i < source.length; i++) source[i] = i % 251
  for (const name of ['a', 'b']) {
    await mkdir(join(workspace, name, 'nested'), { recursive: true })
    await writeFile(join(workspace, name, 'same.txt'), `Workspace ${name}\nSecond line\n`)
  }
  await writeFile(join(workspace, 'a', 'image.bin'), source)
  await writeFile(join(workspace, 'a', 'empty.bin'), Buffer.alloc(0))
  await writeFile(join(workspace, 'a', 'cancel.bin'), Buffer.from([1, 2, 3]))
  await writeFile(join(workspace, 'a', 'nested', 'readme.md'), '# Original resource base\n')
  await copyFile(join(root, 'packages/bundle/web-app/tests/fixtures/document-conversion.docx'),
    join(workspace, 'a', 'document.docx'))

  checkpoint('persisted Session headers and cold profile restart')
  const first = launch(true)
  await first.wait(frame => frame.method === 'runtime.ready')
  await first.wait(frame => frame.method === 'fixture.documentsReady')
  assert.equal((await first.request('runtime.info')).profile, 'android')
  const before = await snapshotLogs()
  assert.equal(Object.keys(before).length, 2)
  await first.close()

  const runtime = launch(false)
  await runtime.wait(frame => frame.method === 'runtime.ready')
  await runtime.wait(frame => frame.method === 'fixture.documentsReady')
  await assertCold(runtime)
  const owner = randomUUID()
  const request = (method, args, extra = {}) => ({ owner, requestId: randomUUID(), sessionId: 'document-fixture-a',
    namespace: 'workspaceFiles', method, args, ...extra })
  const call = (method, args, extra) => runtime.request('document.call', request(method, args, extra))
  const release = async id => assert.deepEqual(value(await runtime.request('document.release', { owner, id })), { released: true })

  checkpoint('original media limit and MIME policy without a Web listener')
  const media = value(await runtime.request('document.mediaPolicy', { owner, path: join(workspace, 'a', 'picture.svg') }))
  assert.equal(media.mimeType, 'image/svg+xml')
  assert.ok(Number.isSafeInteger(media.maxBytes) && media.maxBytes > 0)
  assert.equal(value(await runtime.request('document.mediaPolicy', { owner, path: join(workspace, 'a', 'unknown.zzzextension') })).mimeType,
    'application/octet-stream')

  checkpoint('Session cwd, original listings, text and authority refusals')
  for (const name of ['a', 'b']) {
    const text = value(await call('read', { path: 'same.txt', range: { offset: 1, limit: 1 } }, { sessionId: `document-fixture-${name}` }))
    assert.equal(text.text, `Workspace ${name}`)
    assert.equal(text.offset, 1)
    assert.equal(text.lines, 1)
    assert.equal(text.eof, false)
    assert.equal(resolve(text.absolutePath), join(workspace, name, 'same.txt'))
  }
  const listing = value(await call('list', { path: '.' }))
  assert.equal(listing.path, '')
  assert.equal(listing.entries.find(entry => entry.name === 'nested').type, 'directory')
  assert.equal(listing.entries.find(entry => entry.name === 'image.bin').size, source.length)
  rejected(await call('list', { path: '..' }), 'workspace-file/outside-workspace')
  const outside = value(await call('read', { path: '../b/same.txt' }))
  assert.ok(outside.text.startsWith('Workspace b'), 'file reads must retain original composed fs authority')
  rejected(await call('read', { path: 'image.bin' }), 'workspace-file/not-text')
  rejected(await call('read', { path: 'same.txt', workspaceFileScopeId: 'document-fixture-b' }), 'gateway/bad-request')
  rejected(await call('stat', { path: 'same.txt' }, { sessionId: 'missing-session' }))

  checkpoint('full binary and byte windows transfer through bounded owned leases')
  const full = value(await call('readBytes', { path: 'image.bin' }))
  const stat = value(await call('stat', { path: 'image.bin' }))
  assert.equal(full.version, stat.version)
  assert.equal(full.offset, 0)
  assert.equal(full.eof, true)
  assert.equal(full.bytes, source.length)
  assert.equal(full.data.encoding, 'android-byte-lease')
  const chunks = []
  for (let offset = 0; offset < full.data.length;) {
    const chunk = value(await runtime.request('document.bytes', { owner, id: full.data.id, offset, length: 262144 }))
    assert.equal(chunk.offset, offset)
    const data = Buffer.from(chunk.data, 'base64')
    assert.ok(data.length > 0 && data.length <= 262144)
    offset += data.length
    assert.equal(chunk.eof, offset === full.data.length)
    chunks.push(data)
  }
  assert.deepEqual(Buffer.concat(chunks), source)
  rejected(await runtime.request('document.bytes', { owner: 'foreign-owner', id: full.data.id, offset: 0, length: 16 }), 'document-preview/lease-unavailable')
  rejected(await runtime.request('document.release', { owner: 'foreign-owner', id: full.data.id }), 'document-preview/lease-unavailable')
  await release(full.data.id)
  rejected(await runtime.request('document.bytes', { owner, id: full.data.id, offset: 0, length: 16 }), 'document-preview/lease-unavailable')
  const window = value(await call('readBytes', { path: '../image.bin', options: { baseFile: 'nested/readme.md', range: { offset: 257, length: 23 } } }))
  assert.equal(window.offset, 257)
  assert.equal(window.eof, false)
  assert.equal(window.version, stat.version)
  const part = value(await runtime.request('document.bytes', { owner, id: window.data.id, offset: 0, length: 23 }))
  assert.deepEqual(Buffer.from(part.data, 'base64'), source.subarray(257, 280))
  assert.equal(part.eof, true, 'lease eof differs from original file eof')
  await release(window.data.id)
  const empty = value(await call('readBytes', { path: 'empty.bin' }))
  assert.equal(empty.data.length, 0)
  assert.deepEqual(value(await runtime.request('document.bytes', { owner, id: empty.data.id, offset: 0, length: 1 })), { offset: 0, data: '', eof: true })
  await release(empty.data.id)

  checkpoint('App-private document scope reads original renderer bytes without Session authority')
  const privateOwner = randomUUID()
  const privateCall = (method, args, extra = {}) => runtime.request('document.call', {
    owner: privateOwner, requestId: randomUUID(), sessionId: 'pocket-private-workspace',
    privateWorkspace: true, namespace: 'workspaceFiles', method, args, ...extra,
  })
  const privateStat = value(await privateCall('stat', { path: 'a/image.bin' }))
  assert.equal(privateStat.absolutePath, join(workspace, 'a', 'image.bin'))
  const privateBytes = value(await privateCall('readBytes', { path: privateStat.absolutePath,
    options: { range: { offset: 250, length: 10 } } }))
  assert.equal(privateBytes.version, privateStat.version)
  assert.equal(privateBytes.offset, 250)
  const privateFrame = value(await runtime.request('document.bytes', {
    owner: privateOwner, id: privateBytes.data.id, offset: 0, length: 10,
  }))
  assert.deepEqual(Buffer.from(privateFrame.data, 'base64'), source.subarray(250, 260))
  await runtime.request('document.release', { owner: privateOwner, id: privateBytes.data.id })
  rejected(await privateCall('stat', { path: '../outside.txt' }), 'workspace-files/invalid-path')
  rejected(await privateCall('stat', { path: join(home, 'outside.txt') }), 'workspace-files/outside-workspace')
  rejected(await runtime.request('document.call', { owner: privateOwner, requestId: randomUUID(),
    sessionId: 'pocket-private-workspace', namespace: 'workspaceFiles', method: 'stat',
    args: { path: 'a/image.bin' } }), 'gateway/bad-request')
  const privateOffice = value(await privateCall('render', { path: 'a/document.docx', priority: 'foreground' },
    { namespace: 'officeToPdf' }))
  assert.ok(privateOffice.bytes > 1000)
  const privatePdf = value(await runtime.request('document.bytes', { owner: privateOwner,
    id: privateOffice.data.id, offset: 0, length: 128 }))
  assert.equal(Buffer.from(privatePdf.data, 'base64').subarray(0, 5).toString(), '%PDF-')
  await runtime.request('document.release', { owner: privateOwner, id: privateOffice.data.id })

  checkpoint('real original filesystem read cancellation and owner disconnect')
  const cancelledRequest = request('readBytes', { path: 'cancel.bin' })
  const pending = runtime.request('document.call', cancelledRequest)
  await runtime.wait(frame => frame.method === 'fixture.readEntered')
  const cancelled = runtime.request('document.cancel', { owner, requestId: cancelledRequest.requestId })
  rejected(await pending, 'gateway/cancelled')
  assert.deepEqual(value(await cancelled), { cancelled: true })
  const held = value(await call('readBytes', { path: 'image.bin' }))
  runtime.send({ method: 'native.appDisconnected', params: { owner } })
  rejected(await runtime.request('document.bytes', { owner, id: held.data.id, offset: 0, length: 1 }), 'gateway/cancelled')
  rejected(await runtime.request('document.bytes', { owner: 'new-owner', id: held.data.id, offset: 0, length: 1 }), 'document-preview/lease-unavailable')

  checkpoint('existing stream carrier and original Office provider')
  const subscriptionId = randomUUID(), streamOwner = randomUUID()
  const subscription = await runtime.request('api.subscribe', { owner: streamOwner, subscriptionId,
    namespace: 'workspaceFiles', method: 'changes', args: { workspaceFileScopeId: 'document-fixture-a', path: 'same.txt' } })
  const ready = (await runtime.wait(frame => frame.method === 'api.stream' && frame.params.subscriptionId === subscriptionId)).params
  assert.equal(ready.type, 'item', JSON.stringify(ready))
  assert.equal(ready.value.kind, 'ready')
  await runtime.request('api.ack', { owner: streamOwner, subscriptionId, generation: subscription.generation, sequence: ready.sequence })
  await runtime.request('api.unsubscribe', { owner: streamOwner, subscriptionId, generation: subscription.generation })
  const office = await call('generation', {}, { owner: 'new-owner', namespace: 'officeToPdf' })
  assert.ok(typeof value(office) === 'string')
  const rendered = value(await call('render', { path: 'document.docx', priority: 'foreground' },
    { owner: 'new-owner', namespace: 'officeToPdf' }))
  assert.ok(rendered.bytes > 1000)
  const pdf = value(await runtime.request('document.bytes', { owner: 'new-owner', id: rendered.data.id,
    offset: 0, length: 256 }))
  assert.equal(Buffer.from(pdf.data, 'base64').subarray(0, 5).toString(), '%PDF-')
  assert.deepEqual(value(await runtime.request('document.release', { owner: 'new-owner', id: rendered.data.id })),
    { released: true })
  rejected(await call('render', { path: 'same.txt', priority: 'foreground' },
    { owner: 'new-owner', namespace: 'officeToPdf' }), 'document-render/failed')
  await assertCold(runtime)
  assert.deepEqual(await snapshotLogs(), before, 'preview must not change original history')
  await runtime.close()
  return { realAndroidProfile: true, webEnabled: false, sessionCwd: true, originalReadAuthority: true,
    binaryChunks: chunks.length, binarySha256: hash(source), originalRangeAndBaseFile: true, emptyFile: true,
    cancellation: true, cancellationTiming: 'fixture barrier inside original fs-local readBytes', ownerIsolation: true,
    ownerDisconnect: true, existingChangesStream: true, coldReadDoesNotActivateOrRewrite: true,
    officeWasmPdfBytes: rendered.bytes, privateWorkspacePreview: true,
    androidBinderAndWebView: false, home }
}

let report
try {
  report = await Promise.race([scenario(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Document preview profile timed out at ${phase}: ${
      JSON.stringify(runtimes.map(runtime => runtime.diagnostics()))}`)), 120000)
  })])
} finally {
  clearTimeout(deadline)
  const closed = processes.close()
  const results = await Promise.allSettled([closed, ...runtimes.map(runtime => runtime.close())])
  const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) throw new AggregateError(errors, 'Document fixture cleanup did not reach quiescence')
}
const processExits = runtimes.map(runtime => runtime.exitEvidence())
assert.equal(processExits.length, 2)
for (const exit of processExits) {
  assert.equal(exit.ended, true)
  assert.equal(exit.error, undefined)
  assert.equal(exit.pendingRequests, 0)
  assert.equal(exit.pendingWaiters, 0)
  assert.deepEqual(exit.outstandingAtClose, { requests: 0, waiters: 0 })
}
assert.ok([...processes.records.values()].every(record => record.ended))
console.log(JSON.stringify({ ...report, processExits }))
