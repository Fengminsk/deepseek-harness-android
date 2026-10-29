import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import { mountAgentLoopTestDependencies, mountAgentLoopTestHarness } from '@deepseek-ai/dsh-agent-loop-testkit'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import { SessionId } from '@deepseek-ai/dsh-session'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { MockAdapter, textResponse, toolCallResponse } from '../../../packages/core/agent-loop/tests/mock-adapter.ts'
import * as AutoReview from '../runtime/auto-review.mjs'

/** Split the reviewer request into its five labelled sections. */
function sections(text) {
  const parts = text.split('\n\n')
  const result = {}
  for (let index = 0; index + 1 < parts.length; index += 2) result[parts[index]] = parts[index + 1]
  return result
}

async function fixture(t, { enabled = true, policy = 'ask', script }) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-android-auto-review-'))
  const ctx = new Context()
  const adapter = new MockAdapter(script)
  let bodyRuns = 0
  let escalationOutcome
  let plainOutcome
  t.after(async () => {
    await ctx.fiber.dispose()
    await rm(root, { recursive: true, force: true })
  })
  await mountAgentLoopTestDependencies(ctx, { workingDirectory: true })
  await ctx.plugin(ApprovalService, { policy })
  const harness = await mountAgentLoopTestHarness(ctx)
  ctx.llm.registerAdapter(['mock'], adapter)
  await ctx.plugin(AutoReview, { enabled, timeoutMs: 5000 })
  ctx.tools.register(defineTool({
    name: 'notes_rewrite',
    description: 'Rewrite one note file inside the App workspace.',
    parameters: { target: { type: 'string', required: true } },
    output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(args) {
      bodyRuns += 1
      return { target: args.target }
    },
  }))
  ctx.tools.register(defineTool({
    name: 'escalated_write',
    description: 'Rewrite one protected file after asking for a wider sandbox.',
    parameters: { file_path: { type: 'string', required: true },
      sandbox_permissions: { type: 'string' }, justification: { type: 'string' } },
    output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      escalationOutcome = await ctx.approval.request({ agent: execution.agent, toolName: 'escalated_write',
        callId: execution.callId, reason: 'this operation needs a wider sandbox', signal: execution.signal })
      return { outcome: escalationOutcome }
    },
  }))
  ctx.tools.register(defineTool({
    name: 'plain_request',
    description: 'Ask the human for one plain decision.',
    parameters: {},
    output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    async execute(_args, execution) {
      plainOutcome = await ctx.approval.request({ agent: execution.agent, toolName: 'plain_request',
        callId: execution.callId, reason: 'plain decision', signal: execution.signal })
      return { outcome: plainOutcome }
    },
  }))
  ctx.on('tools/pre-execute', async (exec, next) => {
    if (exec.name !== 'notes_rewrite') return next()
    return { kind: 'ask', reason: 'the tool rewrites a file',
      displayReason: { en: 'Rewrite this note?', zh: '改写这个笔记？' } }
  })
  const approvals = []
  ctx.on('approval/request', (request) => {
    approvals.push(request)
    return 'rejected'
  })
  const agent = await harness.create(SessionId(`auto-review-${randomUUID()}`), { provider: 'mock', model: 'mock' }, { cwd: root })
  const run = async () => {
    agent.followup(createUserMessage({
      content: [{ type: 'text', text: 'Rewrite notes.txt for the weekly summary.' }],
      source: { kind: 'user', rpcId: `rpc-${randomUUID()}` },
    }))
    await agent.whenIdle()
  }
  return { ctx, agent, root, adapter, approvals, run, bodyRuns: () => bodyRuns,
    escalationOutcome: () => escalationOutcome, plainOutcome: () => plainOutcome }
}

test('accepts only the closed risk/decision protocol', () => {
  assert.deepEqual(AutoReview.parseReviewDecision('{"risk":"low","decision":"allow"}'), { risk: 'low', decision: 'allow' })
  assert.deepEqual(AutoReview.parseReviewDecision('{"risk":"medium","decision":"allow"}'), { risk: 'medium', decision: 'allow' })
  assert.deepEqual(AutoReview.parseReviewDecision('{"risk":"high","decision":"deny"}'), { risk: 'high', decision: 'deny' })
  assert.deepEqual(AutoReview.parseReviewDecision('{"risk":"medium","decision":"deny","reason":"target is production"}'),
    { risk: 'medium', decision: 'deny', reason: 'target is production' })
  for (const text of [
    '{"risk":"low","decision":"deny"}',
    '{"risk":"high","decision":"allow"}',
    '{"risk":"low","decision":"allow","reason":"because"}',
    '{"risk":"medium","decision":"deny","reason":1}',
    '{"risk":"low","decision":"allow","extra":true}',
    '{"risk":"low","risk":"low","decision":"allow"}',
    '[]',
    'allow',
  ]) assert.throws(() => AutoReview.parseReviewDecision(text), Error, text)
})

test('a low-risk review lets the standard ask execute without a card', async (t) => {
  const { adapter, approvals, run, bodyRuns } = await fixture(t, {
    script: [
      toolCallResponse('call-notes', 'notes_rewrite', { target: 'notes.txt' }),
      textResponse('{"risk":"low","decision":"allow"}'),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(bodyRuns(), 1)
  assert.deepEqual(approvals, [])
  assert.equal(adapter.requests.length, 3)
  const review = adapter.requests[1]
  assert.match(review.system, /^REVIEW_POLICY\n/)
  const text = review.messages[0].content[0].text
  const parts = sections(text)
  assert.deepEqual(Object.keys(parts), ['ENVIRONMENT', 'PROJECT_INSTRUCTIONS', 'FILTERED_HISTORY', 'PENDING_ACTION'])
  assert.match(parts.FILTERED_HISTORY, /human-instruction/)
  // The pending native call is described only by PENDING_ACTION.
  assert.doesNotMatch(parts.FILTERED_HISTORY, /"kind": "tool-call"/)
  const action = JSON.parse(parts.PENDING_ACTION)
  assert.equal(action.name, 'notes_rewrite')
  assert.equal(action.mode, 'native')
  assert.deepEqual(action.arguments, { target: 'notes.txt' })
  assert.equal(action.description, 'Rewrite one note file inside the App workspace.')
  assert.deepEqual(action.parameters.properties, { target: { type: 'string' } })
  assert.deepEqual(action.parameters.required, ['target'])
})

test('a reviewer denial keeps the original card with the reviewer reason', async (t) => {
  const { approvals, run, bodyRuns } = await fixture(t, {
    script: [
      toolCallResponse('call-notes', 'notes_rewrite', { target: '../outside.txt' }),
      textResponse('{"risk":"high","decision":"deny","reason":"writes outside the App workspace"}'),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(bodyRuns(), 0)
  assert.equal(approvals.length, 1)
  assert.match(approvals[0].reason, /the tool rewrites a file; Auto review did not approve tool "notes_rewrite": writes outside the App workspace/)
  assert.equal(approvals[0].displayReason.en,
    'Rewrite this note? Auto review did not approve this call: writes outside the App workspace')
  assert.equal(approvals[0].displayReason.zh, '改写这个笔记？自动审批未通过：writes outside the App workspace')
})

test('a denial without a reason keeps the localized fallback', async (t) => {
  const { approvals, run, bodyRuns } = await fixture(t, {
    script: [
      toolCallResponse('call-notes', 'notes_rewrite', { target: 'notes.txt' }),
      textResponse('{"risk":"medium","decision":"deny"}'),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(bodyRuns(), 0)
  assert.equal(approvals.length, 1)
  assert.equal(approvals[0].displayReason.en, 'Rewrite this note? Auto review did not approve this call.')
  assert.equal(approvals[0].displayReason.zh, '改写这个笔记？自动审批未通过。')
})

test('a failing reviewer falls back to the human instead of allowing', async (t) => {
  const { adapter, approvals, run, bodyRuns } = await fixture(t, {
    script: [
      toolCallResponse('call-notes', 'notes_rewrite', { target: 'notes.txt' }),
      () => { throw new Error('reviewer route is offline') },
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(bodyRuns(), 0)
  assert.equal(adapter.requests.length, 3)
  assert.equal(approvals.length, 1)
  assert.equal(approvals[0].reason, 'the tool rewrites a file')
})

test('a disabled setting never consults the reviewer', async (t) => {
  const { adapter, approvals, run, bodyRuns } = await fixture(t, {
    enabled: false,
    script: [
      toolCallResponse('call-notes', 'notes_rewrite', { target: 'notes.txt' }),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(bodyRuns(), 0)
  assert.equal(adapter.requests.length, 2)
  assert.equal(approvals.length, 1)
})

test('a never-policy child keeps its final denial', async (t) => {
  const { adapter, approvals, run, bodyRuns } = await fixture(t, {
    policy: 'never',
    script: [
      toolCallResponse('call-notes', 'notes_rewrite', { target: 'notes.txt' }),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(bodyRuns(), 0)
  assert.equal(adapter.requests.length, 2)
  assert.deepEqual(approvals, [])
})

test('a reviewed sandbox escalation skips the approval card', async (t) => {
  const { adapter, approvals, run, escalationOutcome } = await fixture(t, {
    script: [
      toolCallResponse('call-escalate', 'escalated_write',
        { file_path: '.git/config', sandbox_permissions: 'danger-full-access', justification: 'update repo metadata' }),
      textResponse('{"risk":"medium","decision":"allow"}'),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(escalationOutcome(), 'allowed-once')
  assert.deepEqual(approvals, [])
  assert.equal(adapter.requests.length, 3)
  const action = JSON.parse(sections(adapter.requests[1].messages[0].content[0].text).PENDING_ACTION)
  assert.equal(action.name, 'escalated_write')
  assert.equal(action.arguments.sandbox_permissions, 'danger-full-access')
})

test('a denied sandbox escalation keeps its card', async (t) => {
  const { approvals, run, escalationOutcome } = await fixture(t, {
    script: [
      toolCallResponse('call-escalate', 'escalated_write',
        { file_path: '.git/config', sandbox_permissions: 'danger-full-access', justification: 'update repo metadata' }),
      textResponse('{"risk":"medium","decision":"deny","reason":"the task does not authorize repository metadata changes"}'),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(escalationOutcome(), 'rejected')
  assert.equal(approvals.length, 1)
  assert.equal(approvals[0].reason, 'this operation needs a wider sandbox')
})

test('an ordinary approval request bypasses the reviewer', async (t) => {
  const { adapter, approvals, run, plainOutcome } = await fixture(t, {
    script: [
      toolCallResponse('call-plain', 'plain_request', {}),
      textResponse('done'),
    ],
  })
  await run()
  assert.equal(plainOutcome(), 'rejected')
  assert.equal(approvals.length, 1)
  assert.equal(adapter.requests.length, 2)
})
