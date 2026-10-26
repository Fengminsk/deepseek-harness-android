import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import { AppPackageOperations } from '../runtime/package-operations.mjs'

function harness(t, manager = { packageOperationsSnapshot: () => [] }, activity = {}) {
  const listeners = new Set()
  const agents = activity.agents ?? []
  const jobs = activity.jobs ?? []
  const ctx = {
    agents: activity.missingAgents ? undefined : { list: () => agents },
    get: name => name === 'pluginManager' ? manager : name === 'jobs'
      ? activity.missingJobs ? undefined : { snapshot: () => jobs } : undefined,
    on(name, callback) {
      assert.equal(name, 'plugin-manager/before-package-operation')
      listeners.add(callback)
      return () => listeners.delete(callback)
    },
  }
  const gate = new AppPackageOperations(ctx, {
    pendingAppSessions: activity.pendingAppSessions ?? (() => 0),
    terminalActivity: activity.terminalActivity ?? (() => ({ live: 0, pending: 0 })),
  })
  t.after(() => gate.close())
  return { gate, agents, jobs,
    before: kind => { for (const listener of listeners) listener({ id: randomUUID(), kind }) } }
}

function idleAgent() { return { status: 'idle', inbox: { nextTurn: [], nextStep: [] } } }

test('every original package operation blocks maintenance without changing Agent or job state', t => {
  const operations = []
  const { gate, before } = harness(t, { packageOperationsSnapshot: () => operations })
  for (const kind of ['inspect', 'registries', 'install', 'remove']) {
    const operation = { id: randomUUID(), kind }
    before(kind)
    operations.push(operation)
    assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/package-busy')
    assert.deepEqual(operations, [operation])
    operations.pop()
  }
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, true)
})

test('reservation synchronously rejects App, Web and direct package admission until released', t => {
  const { gate, before } = harness(t)
  const token = randomUUID()
  const reserved = gate.reserve({ token })
  assert.equal(reserved.state, 'reserved')
  for (const kind of ['inspect', 'registries', 'install', 'remove']) {
    assert.throws(() => before(kind), { code: 'ANDROID_RUNTIME_TRANSITION' })
  }
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, false)
  gate.release({ token: randomUUID(), epoch: reserved.epoch })
  assert.throws(() => before('install'), { code: 'ANDROID_RUNTIME_TRANSITION' })
  gate.release({ token, epoch: reserved.epoch })
  assert.doesNotThrow(() => before('install'))
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).accepted, false)
})

test('expiration releases an uncommitted reservation and cannot later authorize termination', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { gate, before } = harness(t)
  const token = randomUUID(), reserved = gate.reserve({ token })
  t.mock.timers.tick(15_000)
  assert.doesNotThrow(() => before('remove'))
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).accepted, false)
})

test('committed admission remains sealed after the reservation deadline until explicit release or exit', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { gate, before } = harness(t)
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).state, 'committed')
  t.mock.timers.tick(60_000)
  assert.throws(() => before('registries'), { code: 'ANDROID_RUNTIME_TRANSITION' })
  gate.release({ token, epoch: reserved.epoch })
  assert.doesNotThrow(() => before('registries'))
})

test('mode-save failure and a lost reserve acknowledgment can both release the Node reservation', t => {
  const { gate, before } = harness(t)
  const savedFailure = randomUUID(), reserved = gate.reserve({ token: savedFailure })
  gate.release({ token: savedFailure, epoch: reserved.epoch })
  const lostReply = randomUUID()
  gate.reserve({ token: lostReply })
  gate.release({ token: lostReply })
  assert.doesNotThrow(() => before('inspect'))
})

test('unknown package provider, failed snapshots and disposed runtime never authorize maintenance', t => {
  const missing = harness(t, {}).gate
  assert.equal(missing.reserve({ token: randomUUID() }).code, 'runtime/package-state-unknown')
  const failed = harness(t, { packageOperationsSnapshot() { throw new Error('provider unavailable') } }).gate
  assert.equal(failed.reserve({ token: randomUUID() }).code, 'runtime/package-state-unknown')
  missing.close()
  assert.equal(missing.reserve({ token: randomUUID() }).accepted, false)
})

test('old epochs cannot commit or release reservations in a replacement runtime', t => {
  const old = harness(t).gate
  const token = randomUUID(), previous = old.reserve({ token })
  old.close()
  const { gate, before } = harness(t)
  const replacement = gate.reserve({ token })
  assert.notEqual(previous.epoch, replacement.epoch)
  assert.equal(gate.commit({ token, epoch: previous.epoch }).accepted, false)
  gate.release({ token, epoch: previous.epoch })
  assert.throws(() => before('install'), { code: 'ANDROID_RUNTIME_TRANSITION' })
  assert.equal(gate.commit({ token, epoch: replacement.epoch }).accepted, true)
})

test('service switch never terminates a live Agent turn or accepted queued input', t => {
  const agent = idleAgent()
  const { gate, agents, before } = harness(t, undefined, { agents: [agent] })
  agent.status = 'running'
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  agent.status = 'idle'
  agent.inbox.nextTurn.push({ id: 'accepted' })
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  agent.inbox.nextTurn.pop()
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(reserved.accepted, true)
  agent.status = 'running'
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).code, 'runtime/task-busy',
    'a turn that began while maintenance was being saved must prevent process exit')
  assert.doesNotThrow(() => before('inspect'), 'refused transition must reopen package admission')
  agents.pop()
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, true,
    'safely ended activity must not permanently block maintenance')
})

test('accepted App session operations are observed before they reach the Agent inbox', t => {
  let pending = 1
  const { gate } = harness(t, undefined, { pendingAppSessions: () => pending })
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  pending = 0
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(reserved.accepted, true)
  pending = 1
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).code, 'runtime/task-busy')
  pending = 0
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, true)
})

test('new App work is sealed after reservation until release, including committed state', t => {
  const { gate } = harness(t)
  assert.doesNotThrow(() => gate.assertWorkAllowed())
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.throws(() => gate.assertWorkAllowed(), { code: 'ANDROID_RUNTIME_TRANSITION' })
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).state, 'committed')
  assert.throws(() => gate.assertWorkAllowed(), { code: 'ANDROID_RUNTIME_TRANSITION' })
  gate.release({ token, epoch: reserved.epoch })
  assert.doesNotThrow(() => gate.assertWorkAllowed())
})

test('unreadable App pending state prevents a process switch', t => {
  const { gate } = harness(t, undefined, { pendingAppSessions() { throw new Error('unavailable') } })
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-state-unknown')
})

test('in-flight App Gateway request holds service admission until it settles', async t => {
  const { gate } = harness(t)
  let resolve
  let started = false
  const work = gate.runWork(() => {
    started = true
    return new Promise(complete => { resolve = complete })
  })
  assert.equal(started, true)
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  resolve('completed')
  assert.equal(await work, 'completed')
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(reserved.accepted, true)
  await assert.rejects(gate.runWork(() => { throw new Error('must not run') }),
    { code: 'ANDROID_RUNTIME_TRANSITION' })
  gate.release({ token, epoch: reserved.epoch })
  await assert.rejects(gate.runWork(() => { throw new Error('operation failed') }),
    { message: 'operation failed' })
  assert.equal(gate.activity(), 'idle', 'failed work must release its admission receipt')
})

test('live or opening terminal refuses maintenance even when Agents are idle', t => {
  const terminal = { live: 1, pending: 0 }
  const { gate } = harness(t, undefined, { terminalActivity: () => terminal })
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  terminal.live = 0
  terminal.pending = 1
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  terminal.pending = 0
  const token = randomUUID(), reserved = gate.reserve({ token })
  terminal.live = 1
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).code, 'runtime/task-busy')
  terminal.live = 0
  terminal.pending = Number.NaN
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-state-unknown')
})

test('service switch rechecks all background jobs and permits only settled work', t => {
  const job = { status: 'running' }
  const { gate, jobs } = harness(t, undefined, { jobs: [job] })
  assert.equal(gate.reserve({ token: randomUUID() }).code, 'runtime/task-busy')
  job.status = 'completed'
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(reserved.accepted, true)
  job.status = 'stopping'
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).code, 'runtime/task-busy')
  job.status = 'failed'
  const nextToken = randomUUID(), next = gate.reserve({ token: nextToken })
  assert.equal(next.accepted, true)
  job.status = 'running'
  assert.equal(gate.activity(), 'busy')
  job.status = 'completed'
  assert.equal(gate.commit({ token: nextToken, epoch: next.epoch }).accepted, true,
    'work safely settled before final acknowledgment must not strand maintenance')
  assert.deepEqual(jobs, [job], 'inspection and refusal must never settle a producer')
})

test('late package registration also rejects final process exit', t => {
  const operations = []
  const { gate } = harness(t, { packageOperationsSnapshot: () => operations })
  const token = randomUUID(), reserved = gate.reserve({ token })
  assert.equal(reserved.accepted, true)
  operations.push({ id: 'already-admitted', kind: 'install' })
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).code, 'runtime/package-busy')
  operations.pop()
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, true)
})

test('missing or damaged Agent and job observations fail closed at reserve and commit', t => {
  assert.equal(harness(t, undefined, { missingAgents: true }).gate.reserve({ token: randomUUID() }).code,
    'runtime/task-state-unknown')
  assert.equal(harness(t, undefined, { missingJobs: true }).gate.reserve({ token: randomUUID() }).code,
    'runtime/task-state-unknown')
  const brokenJobs = harness(t, undefined, { jobs: [{ status: 'unrecognized' }] }).gate
  assert.equal(brokenJobs.reserve({ token: randomUUID() }).code, 'runtime/task-state-unknown')
  const unreadableInbox = harness(t, undefined, { agents: [{ status: 'idle', inbox: {
    get nextTurn() { throw new Error('inbox unavailable') }, nextStep: [],
  } }] }).gate
  assert.equal(unreadableInbox.reserve({ token: randomUUID() }).code, 'runtime/task-state-unknown')
  const agent = idleAgent()
  const { gate } = harness(t, undefined, { agents: [agent] })
  const token = randomUUID(), reserved = gate.reserve({ token })
  agent.status = 'unknown'
  assert.equal(gate.commit({ token, epoch: reserved.epoch }).code, 'runtime/task-state-unknown')
  agent.status = 'idle'
  assert.equal(gate.reserve({ token: randomUUID() }).accepted, true)
})
