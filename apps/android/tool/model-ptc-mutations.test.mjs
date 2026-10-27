import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { mkdtemp, mkdir, readFile, rm, readdir, glob, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { SessionId, SESSION_FORMAT_VERSION } from '@deepseek-ai/dsh-session'
import * as JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SandboxPolicy, { setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import WorkingDirectory from '@deepseek-ai/dsh-working-directory'
import AttachmentStore from '@deepseek-ai/dsh-attachment-local'
import * as FsTools from '@deepseek-ai/dsh-tool-fs'
import * as ObservationPolicy from '@deepseek-ai/dsh-fs-observation-policy'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { registerModelFileReadGuard } from '../runtime/model-file-read-guard.mjs'
import { registerAndroidAttachmentsTool } from '../runtime/tool-android-attachments.mjs'
import { NativeIsolatedToolCallbacks } from '../runtime/native-isolated-tool-callbacks.mjs'
import { IsolatedToolCallJournal } from '../runtime/isolated-tool-call-journal.mjs'
import { createNativeIsolatedExecutionBridge } from '../runtime/native-isolated-execution-bridge.mjs'
import { createAppOwnedPtcOwner } from '../runtime/model-ptc-reviewed-owner.mjs'
import { registerAndroidPtcTool } from '../runtime/tool-model-ptc.mjs'

async function fixture(t, { persistence = true } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-model-ptc-'))
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
  if (persistence) await ctx.plugin(JsonlSessionPersistence, { root: sessions, compression: 'none' })
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(AttachmentStore, { dshHome: root })
  registerModelFileReadGuard(ctx, workspace)
  registerAndroidAttachmentsTool(ctx, workspace)
  const agent = await ctx.agentLoop.create(SessionId(`model-ptc-${randomUUID()}`))
  let callbacks, current
  const AsyncFunction = (async () => {}).constructor
  const transport = { async request(method, params) {
    if (method === 'native.isolated.admit') {
      assert.equal(params.kind, 'ptc')
      assert.deepEqual(params.scope.readablePaths, [])
      assert.deepEqual(params.scope.writablePaths, [])
      current = { ...params, token: randomUUID() }
      return { runId: params.runId, token: current.token }
    }
    if (method === 'native.isolated.bindTools') return true
    if (method === 'native.isolated.execute') {
      const fn = new AsyncFunction('input', 'host', current.program)
      current.outputJson = JSON.stringify(await fn(JSON.parse(current.inputJson), {
        async callAsync({ action, ...request }) {
          assert.equal(action, 'TOOL_CALL')
          const { runId: _run, callId: _call, ...reply } = await callbacks.call({
            ...request, runId: current.runId, token: current.token,
          })
          return reply
        },
      }))
      return true
    }
    if (method === 'native.isolated.settle') return { runId: current.runId,
      state: 'COMPLETED', outputJson: current.outputJson, detail: null, guestUid: 99001 }
    if (method === 'native.isolated.release' || method === 'native.isolated.cancel') return true
    throw new Error(method)
  } }
  callbacks = new NativeIsolatedToolCallbacks(transport, new IsolatedToolCallJournal(join(root, 'journal')))
  const owner = createAppOwnedPtcOwner({ bridge: createNativeIsolatedExecutionBridge(transport),
    callbacks, runtime: ctx.tools, services: { agents: ctx.agents, sessions: ctx.sessions,
      sandboxPolicy: ctx.sandboxPolicy } })
  t.after(async () => { await owner.close(); await callbacks.dispose() })
  registerAndroidPtcTool(ctx, { owner, available: () => true })
  const invoke = code => ctx.tools.execute({ name: 'android_ptc', callId: `parent-${randomUUID()}`,
    arguments: { description: 'Model PTC mutation acceptance', code }, agent, signal: new AbortController().signal })
  const upload = async () => {
    const ref = await ctx.attachments.saveFile({ name: 'attachment.txt', data: Buffer.from('attachment data\n') })
    agent.session.append('user/message', createUserMessage({ source: { kind: 'user' },
      content: [{ type: 'file', attachment: ref }] }), { surfaceOp: 'append' })
    return JSON.stringify({ attachmentId: ref.attachmentId, name: ref.name })
  }
  return { ctx, agent, workspace, sessions, invoke, upload }
}

test('model PTC reviews original write/edit/materialize with durable actual paths and metadata', async t => {
  const f = await fixture(t), identity = await f.upload()
  const result = await f.invoke(`
    const created=await tools.write({file_path:'work.txt',content:'alpha\\n'});
    await tools.read({file_path:'work.txt'});
    const edited=await tools.edit({file_path:'work.txt',old_string:'alpha',new_string:'beta'});
    const imported=await tools.android_attachments({...${identity},action:'materialize'});
    const read=await tools.read({file_path:imported.file_path});
    return {created,edited,imported,line:read.lines[0].text};`)
  assert.equal(result.isError, false, JSON.stringify(result))
  assert.equal(await readFile(join(f.workspace, 'work.txt'), 'utf8'), 'beta\n')
  assert.equal(result.value.result.line, 'attachment data')
  assert.equal(await readFile(result.value.result.imported.file_path, 'utf8'), 'attachment data\n')
  assert.equal(result.additionalContexts.filter(value => value.source.kind === 'file-mutation-receipt').length, 3)
  const audits = f.agent.session.snapshotEvents().filter(event => event.type === 'tool/ptc-dispatch')
  assert.deepEqual(audits.map(event => event.data.name), ['write', 'read', 'edit', 'android_attachments', 'read'])
  assert.equal(audits[2].data.meta.path, join(f.workspace, 'work.txt'))
  let log = ''
  for await (const file of glob(`**/session.v${SESSION_FORMAT_VERSION}.jsonl`, { cwd: f.sessions })) log += await readFile(join(f.sessions, file), 'utf8')
  assert.ok(log.includes('file-mutation-receipt'))
  assert.ok(log.includes(JSON.stringify(result.value.result.imported.file_path).slice(1, -1)))
})

test('model PTC rechecks live policy and refuses escalations and unobserved edits', async t => {
  const f = await fixture(t), identity = await f.upload()
  await writeFile(join(f.workspace, 'keep.txt'), 'keep', { flag: 'wx' })
  const capture = async code => {
    const result = await f.invoke(`try{${code};return 'incorrect-success'}catch(e){return e.code}`)
    assert.equal(result.isError, false, JSON.stringify(result))
    return result.value.result
  }
  assert.equal(await capture("await tools.edit({file_path:'keep.txt',old_string:'keep',new_string:'lost'})"), 'ANDROID_TOOL_DISPATCH_FAILED')
  assert.equal(await capture("await tools.write({file_path:'escalated.txt',content:'no',sandbox_permissions:'require_escalated'})"), 'ANDROID_TOOL_NOT_GRANTED')
  assert.equal(await capture("await tools.write({file_path:'../escape.txt',content:'no'})"), 'ANDROID_TOOL_DISPATCH_FAILED')
  setSandboxMode(f.agent.session, 'read-only')
  assert.equal(await capture("await tools.write({file_path:'blocked.txt',content:'no'})"), 'ANDROID_TOOL_NOT_GRANTED')
  assert.equal(await capture(`await tools.android_attachments({...${identity},action:'materialize'})`), 'ANDROID_TOOL_NOT_GRANTED')
  const read = await f.invoke(`return await tools.android_attachments({...${identity},action:'read'})`)
  assert.equal(read.isError, false, JSON.stringify(read))
  assert.equal(read.value.result.content, 'attachment data\n')
  assert.equal(await readFile(join(f.workspace, 'keep.txt'), 'utf8'), 'keep')
  assert.deepEqual(await readdir(f.workspace), ['keep.txt'])
})

test('model PTC cannot start a mutation without a participating Session persistence owner', async t => {
  const f = await fixture(t, { persistence: false })
  const result = await f.invoke("return await tools.write({file_path:'unlogged.txt',content:'no'})")
  assert.equal(result.isError, true)
  await assert.rejects(readFile(join(f.workspace, 'unlogged.txt')), { code: 'ENOENT' })
})
