import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { glob, mkdir, mkdtemp, readFile, readdir, stat } from 'node:fs/promises'
import { basename, join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// The real staged Android profile owns SessionQuery, attachment verification,
// pagination and cleanup. Binder identity and the native cache directory are
// fixture inputs; this host check does not exercise Android Save As or OS leases.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/attachment-files-profile-'))
const workspace = join(home, 'workspace')
await mkdir(workspace)
const processes = new FixtureProcesses(), runtimes = [], vault = new Map()
const failed = Promise.withResolvers()
let phase = 'starting', deadline
const checkpoint = value => { phase = value; console.error(`[attachment-files-profile] ${value}`) }
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

function fixtureEnvironment(seed) {
  const env = { ...process.env }
  for (const key of Object.keys(env)) {
    if (/^(DSH_|DEEPSEEK_|OPENAI_|ANTHROPIC_|POCKET_)/i.test(key)) delete env[key]
  }
  return { ...env, DSH_HOME: home, DSH_TELEMETRY_DISABLED: '1', POCKET_ATTACHMENT_FIXTURE_SEED: seed ? '1' : '0' }
}

async function launch(seed) {
  const cache = join(home, 'native-cache', randomUUID())
  await mkdir(cache, { recursive: true })
  const child = processes.spawn(process.execPath, [
    '--import', new URL('./attachment-files-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs'),
  ], { cwd: workspace, env: fixtureEnvironment(seed), stdio: ['pipe', 'pipe', 'pipe'] })
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
  const fail = error => {
    rejectAll(error)
    if (!closing) failed.reject(error)
    if (!ended) child.kill('SIGKILL')
  }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    ended = true
    const error = new Error(`Attachment fixture runtime exited: ${code ?? signal}`)
    rejectAll(error)
    if (!closing) failed.reject(error)
  })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (failure || ended) return
    try {
      const frame = JSON.parse(line)
      if (frame.method === 'fixture.failed') throw new Error(`Fixture seed failed: ${frame.params.message}; ${JSON.stringify(frame.params.causes)}`)
      if (frame.method === 'fixture.unexpectedNetwork') throw new Error('Attachment read unexpectedly requested network access')
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
          case 'native.attachmentFiles.directory': result = cache; break
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
    cache, notices, send,
    request(method, params = {}) {
      if (ended || failure) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const id = `attachment-files-${++serial}`
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
      try {
        closeReceipt = await processes.stop(child)
        return closeReceipt
      } finally { lines.close() }
    },
    diagnostics: () => ({ pid: child.pid, pending: [...pending.values()].map(call => call.method), notices: notices.length }),
    exitEvidence: () => ({ pid: child.pid, ended, ...closeReceipt, outstandingAtClose,
      pendingRequests: pending.size, pendingWaiters: waiters.size }),
  }
  runtimes.push(runtime)
  return runtime
}

async function snapshots() {
  const result = { logs: {}, originals: {} }
  for (const path of await Array.fromAsync(glob('sessions/**/session.v*.jsonl', { cwd: home }))) {
    result.logs[path] = hash(await readFile(join(home, path)))
  }
  for (const path of await Array.fromAsync(glob('attachments/**/*', { cwd: home }))) {
    if ((await stat(join(home, path))).isFile()) result.originals[path] = hash(await readFile(join(home, path)))
  }
  return result
}

async function assertCold(runtime, fixture) {
  assert.deepEqual((await runtime.request('runtime.live')).statuses, {}, 'attachment inspection must not activate an Agent')
  const catalog = await runtime.request('library.catalog')
  for (const id of [fixture.sessionId, fixture.otherSessionId]) {
    const session = catalog.sessions.find(item => item.sessionId === id)
    assert.ok(session, `persisted fixture session missing: ${id}`)
    assert.equal(session.agentAvailable, false)
    assert.equal(session.running, false)
  }
  assert.equal(runtime.notices.some(frame => frame.method === 'session.event'), false,
    'attachment inspection must not append or replay events')
}

async function scenario() {
  checkpoint('original synthetic storage and cold profile restart')
  const first = await launch(true)
  await first.wait(frame => frame.method === 'runtime.ready')
  const fixture = (await first.wait(frame => frame.method === 'fixture.attachmentsReady')).params
  assert.equal((await first.request('runtime.info')).profile, 'android')
  assert.deepEqual((await first.request('runtime.live')).statuses, {})
  const before = await snapshots()
  assert.equal(Object.keys(before.logs).length, 2, 'both histories must be durably published')
  assert.ok(Object.keys(before.originals).length >= 4, 'original store must hold every synthetic file')
  await first.close()

  const runtime = await launch(false)
  await runtime.wait(frame => frame.method === 'runtime.ready')
  await assertCold(runtime, fixture)
  const owner = randomUUID()
  const params = (ref, extra = {}) => ({ id: randomUUID(), owner, sessionId: fixture.sessionId,
    attachmentId: ref.attachmentId, name: ref.name, ...extra })
  const call = (method, value) => runtime.request(`session.attachmentFile.${method}`, value)
  const release = async request => {
    assert.deepEqual(await call('release', request), { released: true })
    await assert.rejects(call('info', request), /失效/)
    assert.equal((await readdir(runtime.cache)).includes(`${request.id}.file`), false)
    assert.equal((await readdir(runtime.cache)).includes(`${request.id}.partial`), false)
  }

  checkpoint('verified text, byte-accurate UTF-8 pages and native save metadata')
  const request = params(fixture.textRef)
  const prepared = await call('prepare', request)
  assert.deepEqual(prepared, { id: request.id, filename: fixture.textRef.name, size: fixture.textRef.bytes, previewKind: 'text' })
  assert.deepEqual(await call('info', request), { ...prepared, attachmentId: fixture.textRef.attachmentId,
    cacheInstance: basename(runtime.cache) })
  const copy = await readFile(join(runtime.cache, `${request.id}.file`))
  assert.equal(`sha256:${hash(copy)}`, fixture.textRef.attachmentId, 'only fully verified original bytes may be published')
  assert.deepEqual(await readdir(runtime.cache), [`${request.id}.file`])
  let offset = 0, text = '', pages = 0
  while (true) {
    const page = await call('read', { id: request.id, owner, offset })
    assert.equal(page.offset, offset)
    assert.equal(page.size, copy.length)
    assert.ok(Number.isSafeInteger(page.nextOffset) && page.nextOffset > offset && page.nextOffset <= copy.length)
    assert.ok(page.nextOffset - offset <= 1048576, 'profile page limit must remain bounded')
    assert.equal(page.eof, page.nextOffset === copy.length)
    assert.equal(Buffer.byteLength(page.text), page.nextOffset - offset - (offset === 0 ? 3 : 0),
      'byte cursors count the initial BOM even though it is hidden from the preview')
    text += page.text
    pages++
    offset = page.nextOffset
    if (page.eof) break
  }
  assert.ok(pages > 1, 'fixture must cross a real profile page boundary')
  assert.equal(text, copy.toString('utf8').slice(1))
  await assert.rejects(call('read', { id: request.id, owner, offset: 1 }), /完整字符/)
  const foreign = { ...request, owner: randomUUID() }
  await assert.rejects(call('info', foreign), /失效/)
  await assert.rejects(call('read', foreign), /失效/)
  await assert.rejects(call('release', foreign), /不属于/)
  assert.equal((await call('info', request)).attachmentId, fixture.textRef.attachmentId)
  await release(request)

  checkpoint('empty and binary files retain original semantics')
  const empty = params(fixture.emptyRef)
  assert.equal((await call('prepare', empty)).previewKind, 'text')
  assert.deepEqual(await call('read', empty), { text: '', offset: 0, nextOffset: 0, eof: true, size: 0 })
  await release(empty)
  const binary = params(fixture.binaryRef)
  assert.equal((await call('prepare', binary)).previewKind, 'binary')
  assert.equal((await call('info', binary)).attachmentId, fixture.binaryRef.attachmentId)
  await assert.rejects(call('read', binary), /不是可预览/)
  assert.deepEqual(await readFile(join(runtime.cache, `${binary.id}.file`)), Buffer.from([0, 255, 1, 128]))
  await release(binary)

  checkpoint('session/name/reference rejection and explicit cleanup')
  for (const rejected of [
    params(fixture.textRef, { sessionId: fixture.otherSessionId }),
    params(fixture.textRef, { name: '另一个文件名.txt' }),
    params(fixture.orphanRef),
  ]) {
    await assert.rejects(call('prepare', rejected), /没有引用/)
    await release(rejected)
  }
  assert.deepEqual(await readdir(runtime.cache), [], 'release must remove all owned partial and completed copies')
  await assertCold(runtime, fixture)
  assert.deepEqual(await snapshots(), before, 'reads and refusals must preserve exact session logs and original attachment bytes')
  await runtime.close()
  assert.deepEqual(await readdir(runtime.cache), [], 'no successful copy may remain after the fixture runtime ends')
  return { realStagedProfile: true, originalSessionQuery: true, originalAttachmentStore: true,
    coldRestartDoesNotActivateOrRewrite: true, utf8Pages: pages, emptyAndBinaryFiles: true,
    sessionAndFilenameReferenceEnforced: true, ownerIsolation: true, completeCopyCleanup: true,
    nativeSaveMetadata: true, nativeBinder: 'fixture', androidSaveAsAndOsLease: false, home }
}

let report
try {
  report = await Promise.race([scenario(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Attachment profile timed out at ${phase}: ${
      JSON.stringify(runtimes.map(runtime => runtime.diagnostics()))}`)), 120000)
  })])
} finally {
  clearTimeout(deadline)
  // Close allocation before awaiting exits so a timed-out scenario cannot launch
  // another generation after the process ownership snapshot has been taken.
  const closed = processes.close()
  const results = await Promise.allSettled([closed, ...runtimes.map(runtime => runtime.close())])
  const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) throw new AggregateError(errors, 'Attachment fixture cleanup did not reach quiescence')
}
assert.equal(runtimes.length, 2, 'the fixture must close both profile generations')
const processExits = runtimes.map(runtime => runtime.exitEvidence())
for (const exit of processExits) {
  assert.equal(exit.ended, true)
  assert.equal(exit.error, undefined)
  assert.equal(exit.pendingRequests, 0)
  assert.equal(exit.pendingWaiters, 0)
  assert.deepEqual(exit.outstandingAtClose, { requests: 0, waiters: 0 })
}
assert.ok([...processes.records.values()].every(record => record.ended), 'fixture allocator must own no running process')
const remainingCacheFiles = await Promise.all(runtimes.map(runtime => readdir(runtime.cache)))
assert.deepEqual(remainingCacheFiles, [[], []], 'neither runtime may leave a prepared copy')
console.log(JSON.stringify({ ...report, processExits, remainingCacheFiles }))
