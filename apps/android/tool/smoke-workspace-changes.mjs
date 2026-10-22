import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { glob, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { FixtureProcesses } from './fixture-processes.mjs'

// Original staged Android profile/providers; latest owned native carrier modules.
// Only synthetic turns/native callbacks and one cancellation barrier are fixtures.
const root = resolve(import.meta.dirname, '../../..')
const home = await mkdtemp(join(root, '.cache/android/workspace-changes-profile-'))
const workspace = await mkdtemp(join(tmpdir(), 'pocket-changes-workspace-'))
const allocatedTempRoot = await realpath(tmpdir())
const scratch = join(home, 'runtime-temp')
const processes = new FixtureProcesses(), runtimes = [], vault = new Map()
const failed = Promise.withResolvers()
let phase = 'setup', deadline
const checkpoint = value => { phase = value; console.error(`[workspace-changes-profile] ${value}`) }
const value = result => { assert.equal(result.ok, true, JSON.stringify(result)); return result.value }
const rejected = (result, code) => { assert.equal(result.ok, false, JSON.stringify(result)); assert.equal(result.error.code, code) }
const coordinate = entry => ({ owner: randomUUID(), requestId: randomUUID(), sessionId: entry.sessionId, seq: entry.seq })

async function git(...args) {
  const child = processes.spawn('git', ['-c', 'user.email=fixture@example.invalid', '-c', 'user.name=Fixture',
    '-c', 'commit.gpgsign=false', ...args], { cwd: join(workspace, 'repo'), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
  let stdout = '', stderr = ''
  child.stdout.on('data', data => { stdout += data })
  child.stderr.on('data', data => { stderr += data })
  const result = await processes.records.get(child).closed
  assert.equal(result.error, undefined)
  assert.equal(result.code, 0, stderr)
  return stdout.trim()
}

function environment(seed) {
  const env = { ...process.env }
  for (const key of Object.keys(env)) if (/^(DSH_|DEEPSEEK_|OPENAI_|ANTHROPIC_|POCKET_)/i.test(key)) delete env[key]
  return { ...env, DSH_HOME: home, DSH_AGENTS_HOME: join(home, '.agents'), DSH_TELEMETRY_DISABLED: '1',
    POCKET_CHANGES_SEED: seed ? '1' : '0', TMP: scratch, TEMP: scratch, TMPDIR: scratch }
}

function launch(seed) {
  const child = processes.spawn(process.execPath, ['--import', new URL('./workspace-changes-smoke-loader.mjs', import.meta.url).href,
    join(root, '.cache/android/runtime-bundle/bootstrap.mjs')],
  { cwd: workspace, env: environment(seed), windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
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
  const fail = error => { rejectAll(error); if (!closing) failed.reject(error); if (!ended) child.kill('SIGKILL') }
  child.once('error', fail)
  child.once('exit', (code, signal) => {
    ended = true
    const error = new Error(`Changes runtime exited: ${code ?? signal}`)
    rejectAll(error)
    if (!closing) failed.reject(error)
  })
  child.stdin.on('error', fail)
  child.stderr.pipe(process.stderr)
  lines.on('line', line => {
    if (ended || failure) return
    try {
      const frame = JSON.parse(line)
      if (frame.method === 'fixture.failed') throw new Error(frame.params.message)
      if (frame.method === 'fixture.unexpectedNetwork') throw new Error('Changes fixture attempted network access')
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
    notices, send,
    request(method, params = {}) {
      if (ended || failure || closing) return Promise.reject(failure ?? new Error('Runtime stopped'))
      const id = `changes-${++serial}`
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
    diagnostics: () => ({ pid: child.pid, phase, pending: [...pending.values()].map(call => call.method), notices: notices.length }),
    exitEvidence: () => ({ pid: child.pid, ended, ...closeReceipt, outstandingAtClose, pending: pending.size, waiters: waiters.size }),
  }
  runtimes.push(runtime)
  return runtime
}

async function snapshotLogs() {
  const result = {}
  for (const path of await Array.fromAsync(glob('sessions/**/session.v*.jsonl', { cwd: home }))) {
    result[path] = createHash('sha256').update(await readFile(join(home, path))).digest('hex')
  }
  return result
}

async function ready(runtime) {
  await runtime.wait(frame => frame.method === 'runtime.ready')
  const ready = await runtime.wait(frame => frame.method === 'fixture.changesReady')
  assert.equal((await runtime.request('runtime.info')).profile, 'android')
  assert.equal((await runtime.request('web.status')).phase, 'disabled')
  return ready.params.entries
}

async function scenario() {
  for (const path of [join(workspace, 'repo'), join(workspace, 'plain'), scratch, join(home, 'profiles/android')]) await mkdir(path, { recursive: true })
  // One exclusive fixture overlay sets the original recorder's byte cap. No
  // service, route, filesystem implementation or App-owned listener is replaced.
  await writeFile(join(home, 'profiles/android/cordis.patch.yml'), '- id: workspace-changes\n  config:\n    maxFileBytes: 256\n')
  for (const name of ['repo', 'plain']) for (const path of ['captured.txt', 'cancel.txt']) await writeFile(join(workspace, name, path), 'before\n')
  await writeFile(join(workspace, 'repo/tracked.txt'), 'first\nbefore\nlast\n')
  await writeFile(join(workspace, 'repo/user-only.txt'), 'unchanged baseline\n')
  await git('init', '-q', '-b', 'main')
  await git('add', '-A')
  await git('commit', '-qm', 'Synthetic workspace changes baseline')
  await writeFile(join(workspace, 'repo/user-only.txt'), 'prior user edit must not enter turn diff\n')
  const gitObjectsBefore = await git('count-objects')
  checkpoint('original recorder publishes real Git and plain filesystem captures')
  const first = launch(true), entries = await ready(first)
  assert.equal(entries.length, 2)
  assert.equal(entries.find(entry => entry.sessionId.endsWith('-repo')).gitSnapshot, true)
  assert.equal(entries.find(entry => entry.sessionId.endsWith('-plain')).gitSnapshot, false)
  assert.deepEqual((await first.request('runtime.live')).statuses, {}, 'Reading snapshots must not need an Agent')
  const before = await snapshotLogs(), summaries = {}
  for (const entry of entries) {
    const summary = value(await first.request('workspaceChanges.summary', coordinate(entry)))
    summaries[entry.sessionId] = summary
    assert.deepEqual(Object.keys(summary).sort(), ['added', 'deleted', 'files', 'total', 'turn'])
    assert.equal(summary.turn, 1)
    assert.equal(summary.total, entry.gitSnapshot ? 5 : 4)
    assert.ok(summary.files.every(file => !['user-only.txt', 'shell-only.txt'].includes(file.path)))
    assert.equal((await first.request('fixture.permission', entry)).status, 403)
    for (const [index, file] of summary.files.entries()) {
      const diff = value(await first.request('workspaceChanges.diff', { ...coordinate(entry), index }))
      assert.equal(diff.path, file.path)
      if (file.path === 'binary.dat') assert.equal(diff.kind, 'binary')
      else if (file.path === 'oversized.txt') assert.equal(diff.kind, 'oversized')
      else {
        assert.equal(diff.kind, 'text')
        assert.equal(diff.coarse, false)
        assert.ok(diff.hunks.flatMap(hunk => hunk.lines).some(line => line.startsWith('+')))
      }
    }
    rejected(await first.request('workspaceChanges.diff', { ...coordinate(entry), index: 999 }), 'workspace-changes/unavailable')
    rejected(await first.request('workspaceChanges.summary', { ...coordinate(entry), seq: entry.seq + 1000 }), 'workspace-changes/unavailable')
    rejected(await first.request('workspaceChanges.summary', { ...coordinate(entry), path: '/untrusted' }), 'gateway/bad-request')
  }
  const selected = entries.find(entry => entry.sessionId.endsWith('-repo'))
  const selectedSummary = summaries[selected.sessionId]
  const trackedIndex = selectedSummary.files.findIndex(file => file.path === 'tracked.txt')
  await writeFile(join(workspace, 'repo/tracked.txt'), 'later user edit after the turn\n')
  const captured = value(await first.request('workspaceChanges.diff', { ...coordinate(selected), index: trackedIndex }))
  assert.ok(captured.hunks.flatMap(hunk => hunk.lines).includes('+model edit'))
  assert.ok(!JSON.stringify(captured).includes('later user edit'))
  assert.equal(await git('count-objects'), gitObjectsBefore, 'Snapshots must use original isolated object directories')
  assert.deepEqual(await snapshotLogs(), before, 'Snapshot reads must not rewrite session history')

  checkpoint('original route cancellation, owner disconnect and no late results')
  const cancelIndex = selectedSummary.files.findIndex(file => file.path === 'cancel.txt')
  for (const disconnect of [false, true]) {
    const { next } = await first.request('fixture.arm')
    const params = { ...coordinate(selected), index: cancelIndex }
    const pending = first.request('workspaceChanges.diff', params)
    await first.wait(frame => frame.method === 'fixture.readEntered' && frame.params.number === next)
    if (disconnect) {
      first.send({ method: 'native.appDisconnected', params: { owner: params.owner } })
      rejected(await pending, 'gateway/cancelled')
      rejected(await first.request('workspaceChanges.summary', { ...params, index: undefined, requestId: randomUUID() }), 'gateway/cancelled')
    } else {
      const cancellation = first.request('workspaceChanges.cancel', { owner: params.owner, requestId: params.requestId })
      rejected(await pending, 'gateway/cancelled')
      assert.equal(value(await cancellation).cancelled, true)
    }
  }
  assert.equal(value(await first.request('workspaceChanges.summary', coordinate(selected))).total, 5)
  checkpoint('Session disposal removes original snapshot/capture directories')
  assert.ok((await readdir(scratch)).some(name => name.startsWith('dsh-workspace-changes-')))
  assert.deepEqual(await first.request('fixture.dispose'), { remaining: [], live: false })
  rejected(await first.request('workspaceChanges.summary', coordinate(selected)), 'workspace-changes/unavailable')
  assert.deepEqual(await snapshotLogs(), before)
  await first.close()

  checkpoint('cold restart preserves events while original ephemeral snapshots remain missing')
  const second = launch(false)
  await ready(second)
  const afterRestart = await snapshotLogs()
  assert.deepEqual(afterRestart, before)
  for (const entry of entries) {
    const historical = await second.request('fixture.history', entry)
    assert.ok(historical.events.some(event => event.seq === entry.seq && event.data.turn === 1))
    rejected(await second.request('workspaceChanges.summary', coordinate(entry)), 'workspace-changes/unavailable')
    rejected(await second.request('workspaceChanges.diff', { ...coordinate(entry), index: 0 }), 'workspace-changes/unavailable')
  }
  assert.deepEqual((await second.request('runtime.live')).statuses, {})
  assert.deepEqual(await snapshotLogs(), afterRestart)
  assert.equal((await readdir(scratch)).some(name => name.startsWith('dsh-workspace-changes-')), false)

  checkpoint('original @ file and Session discovery with explicit Agent coordinates')
  const referenceParams = { owner: randomUUID(), requestId: randomUUID(), sessionId: 'reference-fixture', query: '', quoted: false }
  const references = await second.request('references.list', referenceParams)
  const files = value(references.files), sessions = value(references.sessions)
  assert.ok(files.some(file => file.path === 'tracked.txt'), JSON.stringify(files))
  assert.ok(sessions.some(session => session.sessionId === 'reference-candidate'), JSON.stringify(sessions))
  const quoted = await second.request('references.list', { ...referenceParams, requestId: randomUUID(), quoted: true })
  assert.deepEqual(value(quoted.sessions), [])
  assert.deepEqual(value(quoted.files), files)
  assert.equal((await second.request('web.status')).phase, 'disabled')
  await second.close()
  return { originalAndroidProfile: true, originalServiceAndRoutes: true, nativeCarrierFromWorkingTree: true,
    realGitSnapshots: true, plainFileIntentCaptures: true, shellWithoutRepositoryExcluded: true,
    priorUserEditsExcluded: true, snapshotStableAfterLaterEdit: true, binaryAndOversized: true,
    noAddedGitObjects: true, ownerOnlyRoute: true, cancellationAndDisconnect: true,
    cancellationTiming: 'test-only barrier after original recorder record lookup',
    disposalNoRecorderFiles: true, coldRestartUnavailable: true, noHistoryRewriteByReads: true,
    referenceFileCandidates: files.length, referenceSessionCandidates: sessions.length,
    quotedSuppressesSessions: true, webEnabled: false, realModelRequests: 0, androidBinderOrDevice: false,
    home, workspace, summaries }
}

let report
try {
  report = await Promise.race([scenario(), failed.promise, new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`Changes fixture timeout: ${JSON.stringify(runtimes.map(runtime => runtime.diagnostics()))}`)), 120000)
  })])
} finally {
  clearTimeout(deadline)
  const cleanup = await Promise.allSettled([processes.close(), ...runtimes.map(runtime => runtime.close())])
  const errors = cleanup.filter(result => result.status === 'rejected').map(result => result.reason)
  if (errors.length) throw new AggregateError(errors, 'Changes fixture processes failed to close')
  // Delete only this invocation's exclusive temporary workspace, after all
  // owned children closed. Keep the separate profile/report directory as evidence.
  const ownedWorkspace = await realpath(workspace)
  assert.equal(dirname(ownedWorkspace), allocatedTempRoot)
  assert.ok(basename(ownedWorkspace).startsWith('pocket-changes-workspace-'))
  await rm(ownedWorkspace, { recursive: true })
}
const processExits = runtimes.map(runtime => runtime.exitEvidence())
for (const exit of processExits) {
  assert.equal(exit.ended, true)
  assert.equal(exit.error, undefined)
  assert.deepEqual(exit.outstandingAtClose, { requests: 0, waiters: 0 })
  assert.equal(exit.pending, 0)
  assert.equal(exit.waiters, 0)
}
assert.ok([...processes.records.values()].every(record => record.ended))
report = { ...report, processExits, ownedProcessesClosed: processes.records.size, temporaryWorkspaceRemoved: true }
await writeFile(join(home, 'report.json'), JSON.stringify(report, null, 2) + '\n')
console.log(JSON.stringify(report))
