import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { mkdtemp, mkdir, readFile, rm, glob } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { SessionId, SESSION_FORMAT_VERSION } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import * as ObservationPolicy from '@deepseek-ai/dsh-fs-observation-policy'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { registerModelFileReadGuard } from '../runtime/model-file-read-guard.mjs'
import { IsolatedToolCallPort } from '../runtime/isolated-tool-call-port.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-ptc-mutations-'))
  const workspace = join(root, 'workspace'), sessions = join(root, 'sessions')
  await mkdir(workspace)
  const ctx = new Context()
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }) })
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(SandboxPolicy, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  await ctx.plugin(WorkingDirectory, { defaultDirectory: workspace })
  await ctx.plugin(FsTools, { readImage: false })
  await ctx.plugin(ObservationPolicy)
  await ctx.plugin(JsonlSessionPersistence, { root: sessions, compression: 'none' })
  await ctx.plugin(AgentLoop, { agents: [] })
  registerModelFileReadGuard(ctx, workspace)
  const agent = await ctx.agentLoop.create(SessionId(`ptc-${randomUUID()}`))
  const runId = randomUUID(), journal = new IsolatedToolCallJournal(join(root, 'journal'))
  const prepared = { kind: 'ptc', runId, sessionId: agent.session.id, scope: {
    ownerId: 'host-review', sessionId: agent.session.id, version: 1, workspaceId: null,
    readablePaths: [], writablePaths: [], exactHosts: [], fileCallLimit: 0, networkCallLimit: 0, leaseMillis: 5000,
  } }
  let port, counter = 0, flushes = 0
  const controller = new AbortController()
  const diskLog = async () => {
    let text = ''
    for await (const path of glob(`**/session.v${SESSION_FORMAT_VERSION}.jsonl`, { cwd: sessions })) {
      text += await readFile(join(sessions, path), 'utf8')
    }
    return text
  }
  const invoke = async work => {
    ctx.tools.register(defineTool({ name: 'mutation_probe', description: 'Host-owned mutation test', parameters: {},
      output: { schema: { type: 'json' }, render: () => [] },
      async execute(_args, parent) {
        port = new IsolatedToolCallPort({ prepared, admission: { runId, token: 'host-test' },
          runtime: ctx.tools, parent, allowedToolNames: ['read', 'write', 'edit'], journal,
          authorizeTool: async input => ({ definition: input.definition,
            effect: input.name === 'read' ? 'read-only' : 'workspace-write',
            ...(input.name === 'read' ? {} : {
              projectResult: value => ({ path: value.path }),
              async flushSession() {
                flushes++
                if (options.flush) return options.flush(flushes, ctx, agent)
                return ctx.sessions.flush(agent.session)
              },
            }),
          }),
        })
        let failed = false
        try {
          return await work((name, args) => port.call({ runId, callId: ++counter, name, arguments: args }), parent)
        } catch (error) { failed = true; throw error }
        finally { try { await port.close() } catch (error) { if (!failed) throw error } }
      },
    }))
    const batch = await ctx.tools.execute({
      calls: [{ type: 'tool-call', id: 'outer', name: 'mutation_probe', arguments: '{}' }],
      agent, signal: controller.signal })
    return batch.results[0].result
  }
  return { ctx, agent, workspace, journal, runId, controller, invoke, diskLog,
    get flushes() { return flushes } }
}

test('real original read/write/edit share observation state and durable paired Session audit', async t => {
  const f = await fixture(t)
  const result = await f.invoke(async call => {
    const created = await call('write', { file_path: 'work.txt', content: 'alpha\n' })
    await call('read', { file_path: 'work.txt' })
    const changed = await call('edit', { file_path: 'work.txt', old_string: 'alpha', new_string: 'beta' })
    return { created, changed }
  })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(await readFile(join(f.workspace, 'work.txt'), 'utf8'), 'beta\n')
  assert.equal(result.value.created.path, join(f.workspace, 'work.txt'))
  assert.equal(result.value.changed.path, result.value.created.path)
  assert.equal(f.flushes, 4)
  const audit = f.agent.session.snapshotEvents().filter(event => event.type === 'tool/ptc-dispatch')
  assert.equal(audit.length, 3)
  assert.equal(audit[2].data.meta.path, result.value.changed.path)
  const log = await f.diskLog()
  assert.ok(log.includes('tool/ptc-dispatch-start'))
  assert.ok(log.includes('tool/ptc-dispatch'))
  assert.ok(log.includes('outer:ptc:3'))
  assert.equal((await f.journal.inspect({ runId: f.runId, callId: 3 })).outcome, 'success')
})

test('a queued original mutation obeys the current read-only policy without writing', async t => {
  const f = await fixture(t)
  const result = await f.invoke(async call => {
    await call('write', { file_path: 'existing.txt', content: 'keep\n' })
    setSandboxMode(f.agent.session, 'read-only')
    let code
    try { await call('write', { file_path: 'blocked.txt', content: 'no' }) } catch (error) { code = error.code }
    return { code }
  })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.code, 'ANDROID_TOOL_DISPATCH_FAILED')
  await assert.rejects(readFile(join(f.workspace, 'blocked.txt')), { code: 'ENOENT' })
  assert.equal(await readFile(join(f.workspace, 'existing.txt'), 'utf8'), 'keep\n')
})

test('an original mutation can commit before an observation failure, preserving its actual file receipt', async t => {
  const f = await fixture(t)
  f.ctx.on('fs/observed', (_target, _observation, exec) => {
    if (exec?.name === 'write') throw new Error('observation listener failed after commit')
  })
  const result = await f.invoke(async call => {
    try { await call('write', { file_path: 'committed.txt', content: 'durable\n' }) }
    catch (error) { return { code: error.code, message: error.message } }
  })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.code, 'ANDROID_TOOL_DISPATCH_FAILED')
  assert.match(result.value.message, /Verify.*before any retry/u)
  assert.equal(await readFile(join(f.workspace, 'committed.txt'), 'utf8'), 'durable\n')
  assert.ok(result.additionalContexts.some(context => context.source.kind === 'file-mutation-receipt'))
  const log = await f.diskLog()
  assert.ok(log.includes('file-mutation-receipt'))
  assert.ok(log.includes('committed.txt'))
  assert.equal((await f.journal.inspect({ runId: f.runId, callId: 1 })).outcome, 'tool-error')
})

test('late cancellation retains the committed original file receipt through both ToolRuntime layers', async t => {
  const f = await fixture(t)
  f.ctx.on('fs/observed', (_target, _observation, exec) => {
    if (exec?.name === 'write') f.controller.abort('cancel after file commit')
  })
  const result = await f.invoke(call => call('write', { file_path: 'late.txt', content: 'committed\n' }))
  assert.equal(result.isError, true)
  assert.equal(await readFile(join(f.workspace, 'late.txt'), 'utf8'), 'committed\n')
  assert.ok(result.additionalContexts.some(context => context.source.kind === 'file-mutation-receipt'))
  assert.ok(result.additionalContexts.some(context => context.source.kind === 'android-ptc-mutation'))
  assert.equal(f.flushes, 2)
  assert.ok((await f.diskLog()).includes('file-mutation-receipt'))
  // The outcome was materialized and audited before the late cancellation, so\n  // the journal state is confirmed; only the guest reply is withheld.\n  assert.equal((await f.journal.inspect({ runId: f.runId, callId: 1 })).state, 'confirmed')
})

test('post-execute host contexts survive nested failure and enter the outer ToolRuntime result', async t => {
  const f = await fixture(t)
  const context = createUserMessage({ source: { kind: 'test-policy' }, content: [{ type: 'text', text: 'Review the committed output' }] })
  f.ctx.on('tools/post-execute', async (exec, result, next) => exec.name === 'write'
    ? { kind: 'block', feedback: [{ type: 'text', text: 'policy withheld the result' }], additionalContexts: [context] }
    : next())
  const result = await f.invoke(async call => {
    try { await call('write', { file_path: 'policy.txt', content: 'committed\n' }) }
    catch (error) { return { code: error.code } }
  })
  assert.equal(result.isError, false, JSON.stringify(result.error))
  assert.equal(result.value.code, 'ANDROID_TOOL_DISPATCH_FAILED')
  assert.equal(await readFile(join(f.workspace, 'policy.txt'), 'utf8'), 'committed\n')
  assert.ok(result.additionalContexts.some(value => value.id === context.id))
  assert.ok(result.additionalContexts.every(value => value.source.kind !== 'file-mutation-receipt'))
  const terminal = f.agent.session.snapshotEvents().find(event => event.type === 'tool/ptc-dispatch')
  assert.equal(terminal.data.mutation.requestedPath, 'policy.txt')
  assert.equal(terminal.data.mutation.canonicalPath, undefined)
  assert.equal(terminal.data.mutation.status, 'verify-before-retry')
  assert.ok((await f.diskLog()).includes('Review the committed output'))
})

