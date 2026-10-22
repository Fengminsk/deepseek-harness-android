import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { InteractionReceipts, approvalAuditIdentity, interactionReceiptIdentity, originalInteractionSettled } from '../runtime/interaction-receipts.mjs'

const testHome = fileURLToPath(new URL('../../../.cache/android/', import.meta.url))
await mkdir(testHome, { recursive: true })

test('write-ahead receipt survives a Host restart and never equates pending with non-delivery', async t => {
  const root = await mkdtemp(join(testHome, 'dsh-interaction-receipt-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const identity = ['question', 'session-1', 'call-1']
  const first = new InteractionReceipts()
  await first.initialize(root)
  assert.equal(await first.begin(identity), true)
  assert.equal(first.phase(identity), 'started')
  const restarted = new InteractionReceipts()
  await restarted.initialize(root)
  assert.equal(restarted.phase(identity), 'started')
  assert.equal(await restarted.begin(identity), false)
  await restarted.accepted(identity)
  const restartedAgain = new InteractionReceipts()
  await restartedAgain.initialize(root)
  assert.equal(restartedAgain.phase(identity), 'accepted')
  assert.equal(await restartedAgain.begin(identity), false)
})

test('a torn marker fails closed for its identity without blocking unrelated requests', async t => {
  const root = await mkdtemp(join(testHome, 'dsh-interaction-receipt-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const identity = ['question', 'session-1', 'call-1']
  const first = new InteractionReceipts()
  await first.initialize(root)
  assert.equal(await first.begin(identity), true)
  const directory = join(root, 'interaction-replies-v1')
  const [name] = await readdir(directory)
  await writeFile(join(directory, name), '{')
  const restored = new InteractionReceipts()
  await restored.initialize(root)
  assert.equal(restored.phase(identity), 'started')
  assert.equal(await restored.begin(identity), false)
  assert.equal(await restored.begin(['question', 'session-1', 'call-2']), true)
})

test('approval receipt uses only one matching original undecided audit id', () => {
  const events = [
    { type: 'approval/asked', data: { id: 'old', toolName: 'android_shell', callId: 'call-1', reason: 'Run' } },
    { type: 'approval/decided', data: { id: 'old', outcome: 'rejected' } },
    { type: 'approval/asked', data: { id: 'new', toolName: 'android_shell', callId: 'call-1', reason: 'Run' } },
  ]
  const agent = { session: { seq: events.length, eventAt: seq => events[seq] } }
  const request = { toolName: 'android_shell', callId: 'call-1', reason: 'Run' }
  assert.equal(approvalAuditIdentity(agent, request), 'new')
  assert.deepEqual(interactionReceiptIdentity({ kind: 'approval', sessionId: 'session-1', approvalAuditId: 'new' }),
    ['approval', 'session-1', 'new'])
  events.push({ type: 'approval/asked', data: { id: 'ambiguous', ...request } })
  agent.session.seq++
  assert.equal(approvalAuditIdentity(agent, request), undefined)
  assert.equal(interactionReceiptIdentity({ kind: 'approval', sessionId: 'session-1' }), undefined)
  assert.deepEqual(interactionReceiptIdentity({ kind: 'question', sessionId: 'session-1', callId: 'call-1' }),
    ['question', 'session-1', 'call-1'])
})

test('original settled approval and question are distinguished from pending observations', () => {
  const events = [
    { type: 'approval/asked', data: { id: 'audit-1' } },
    { type: 'approval/decided', data: { id: 'audit-1', outcome: 'cancelled' } },
  ]
  const agent = { session: { seq: events.length, eventAt: seq => events[seq] } }
  assert.equal(originalInteractionSettled({ kind: 'approval', approvalAuditId: 'audit-1' }, agent), true)
  assert.equal(originalInteractionSettled({ kind: 'approval', approvalAuditId: 'audit-2' }, agent), false)
  const projections = { stateOf: () => ({ questions: {
    active: [{ callId: 'still-open', state: 'continued' }],
    settled: [{ callId: 'answered', answers: [] }],
  } }) }
  assert.equal(originalInteractionSettled({ kind: 'question', callId: 'answered' }, agent, projections), true)
  assert.equal(originalInteractionSettled({ kind: 'question', callId: 'still-open' }, agent, projections), false)
  assert.equal(originalInteractionSettled({ kind: 'question', callId: 'answered' }, agent), false)
  events.push({ type: 'tool/result', data: { message: { toolCallId: 'failed-call' }, error: { code: 'FAILED' } } })
  agent.session.seq++
  assert.equal(originalInteractionSettled({ kind: 'question', callId: 'failed-call' }, agent, projections), true)
  assert.equal(originalInteractionSettled({ kind: 'question', callId: 'failed-call' }, agent), false)
})

test('a verified original settlement is durable without claiming which client answered', async t => {
  const root = await mkdtemp(join(testHome, 'dsh-interaction-receipt-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const identity = ['question', 'session-1', 'call-1']
  const receipt = new InteractionReceipts()
  await receipt.initialize(root)
  await receipt.begin(identity)
  assert.deepEqual(receipt.startedIdentities(), [identity])
  await receipt.settled(identity)
  assert.equal(receipt.phase(identity), 'settled')
  assert.equal(await receipt.begin(identity), false)
  await receipt.accepted(identity)
  const restored = new InteractionReceipts()
  await restored.initialize(root)
  assert.equal(restored.phase(identity), 'settled')
  assert.deepEqual(restored.startedIdentities(), [])
})
