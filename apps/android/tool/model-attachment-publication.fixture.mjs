import fs from 'node:fs'
import { mkdtemp, mkdir, readFile, readdir, rm } from 'node:fs/promises'
import { syncBuiltinESMExports } from 'node:module'
import { join, resolve, sep } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import SessionProjections from '@deepseek-ai/dsh-session-projection'
import SandboxPolicy from '@deepseek-ai/dsh-sandbox-policy'
import AttachmentStore from '@deepseek-ai/dsh-attachment-local'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import { Session, SessionId } from '@deepseek-ai/dsh-session'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import AndroidFileSystem from '../runtime/android-filesystem.mjs'
import { registerAndroidAttachmentsTool } from '../runtime/tool-android-attachments.mjs'

async function removeOwnedFixture(directory) {
  if (!resolve(directory).startsWith(resolve(tmpdir()) + sep)) throw new Error('Unexpected fixture cleanup directory')
  await rm(directory, { recursive: true, force: true })
}

// This process owns all builtin I/O injection. Publication itself still uses
// the real publisher and filesystem; only cleanup failure or abort is injected.
const scenario = process.argv[2]
if (!['cleanup-failure', 'cancel-after-publication', 'cancel-before-publication'].includes(scenario)) {
  throw new TypeError('Unknown attachment publication fixture')
}
const home = await mkdtemp(join(tmpdir(), 'dsh-attachment-publication-'))
const workspace = join(home, 'workspace')
await mkdir(workspace)
const ctx = new Context()
const originalUnlink = fs.promises.unlink
const originalRealpath = fs.promises.realpath
const controller = new AbortController()
let injected = false
try {
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(NativeToolExecutor)
  await ctx.plugin(SessionProjections)
  await ctx.plugin(SandboxPolicy, { mode: 'workspace-write', workspaceRoot: workspace })
  await ctx.plugin(AndroidFileSystem, { cwd: workspace })
  const store = new AttachmentStore(ctx, { dshHome: home })
  ctx.provide('workingDirectory', { ensure: async () => workspace })
  registerAndroidAttachmentsTool(ctx, workspace)
  const session = Session.create(SessionId('attachment-publication-fixture'))
  const agent = { session, id: session.id }
  ctx.provide('agents', { get: id => id === agent.id ? agent : undefined })
  const data = Buffer.from('verified attachment publication\n')
  const ref = await store.saveFile({ name: 'review.txt', data })
  session.append('user/message', createUserMessage({ source: { kind: 'user' },
    content: [{ type: 'file', attachment: ref }] }), { surfaceOp: 'append' })

  const owned = path => resolve(String(path)).startsWith(resolve(workspace) + sep)
  fs.promises.unlink = async path => {
    if (scenario === 'cleanup-failure' && owned(path) && String(path).endsWith('.partial')
      && fs.existsSync(join(String(path), '..', ref.name))) {
      injected = true
      throw Object.assign(new Error('Injected post-publication cleanup I/O failure'), { code: 'EIO' })
    }
    return originalUnlink(path)
  }
  fs.promises.realpath = async (...args) => {
    const value = await originalRealpath(...args)
    if (!injected && owned(args[0]) && String(args[0]).split(sep).at(-1).startsWith('attachment-')) {
      const published = fs.existsSync(join(String(args[0]), ref.name))
      if (scenario === 'cancel-after-publication' && published
        || scenario === 'cancel-before-publication' && !published) {
        injected = true
        controller.abort(new Error('Injected publication-boundary cancellation'))
      }
    }
    return value
  }
  syncBuiltinESMExports()
  const batch = await ctx.tools.execute({
    calls: [{ type: 'tool-call', id: 'publication-fixture', name: 'android_attachments',
      arguments: JSON.stringify({ action: 'materialize', attachmentId: ref.attachmentId, name: ref.name }) }],
    agent, signal: controller.signal })
  const result = batch.results[0].result
  const receipts = (result.additionalContexts ?? batch.additionalContexts ?? []).filter(value => value.source.kind === 'file-mutation-receipt')
    .map(value => JSON.parse(value.content[0].text))
  const [directory] = await readdir(workspace)
  const publishedPath = receipts[0]?.file_path ?? (directory && join(workspace, directory, ref.name))
  let actual = null
  if (publishedPath) {
    try { actual = (await readFile(publishedPath)).toString('utf8') }
    catch (error) { if (error.code !== 'ENOENT') throw error }
  }
  console.log(JSON.stringify({ injected, isError: result.isError, cancelled: controller.signal.aborted,
    errorMessage: result.error?.message,
    expected: { attachmentId: ref.attachmentId, bytes: ref.bytes, content: data.toString('utf8') },
    receipts, publishedPath, actual, remainingEntries: await readdir(workspace) }))
} finally {
  fs.promises.unlink = originalUnlink
  fs.promises.realpath = originalRealpath
  syncBuiltinESMExports()
  await ctx.fiber.dispose()
  // Only this process's mkdtemp tree is removed after all readers have retired.
  await removeOwnedFixture(home)
}
