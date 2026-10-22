import { registerHooks } from 'node:module'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href

// No model/network request belongs to this read-only fixture. Fail even if a
// provider catches the rejected fetch instead of allowing it to reach the RPC.
globalThis.fetch = async () => {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.unexpectedNetwork' }) + '\n')
  throw new Error('Attachment file fixture refuses network access')
}

registerHooks({
  load(url, context, nextLoad) {
    const result = nextLoad(url, context)
    if (url !== carrier || process.env.POCKET_ATTACHMENT_FIXTURE_SEED !== '1') return result
    const source = result.source.toString()
    const marker = 'export function apply(ctx, config)'
    if (!source.includes(marker)) throw new Error('Staged Android runtime fixture entry changed')
    return { ...result, source: source.replace(marker, 'function applyStagedRuntime(ctx, config)') + `
import { seedAttachmentFixture } from ${JSON.stringify(import.meta.url)}
export function apply(ctx, config) {
  applyStagedRuntime(ctx, config)
  ctx.inject(['attachments', 'sessionPersistence'], scope => seedAttachmentFixture(scope))
}
` }
  },
})

/**
 * Populate only the new fixture home through original storage services, without
 * creating a live Session or Agent. The second profile generation runs unmodified.
 */
export async function seedAttachmentFixture(ctx) {
  try {
    const { SESSION_FORMAT_VERSION, SessionId } = await import('@deepseek-ai/dsh-session')
    const { createUserMessage } = await import('@deepseek-ai/dsh-llm')
    const text = '\ufeff' + '中文🙂 attachment line\r\n'.repeat(9000)
    const textRef = await ctx.attachments.saveFile({ data: Buffer.from(text), name: '冷会话 附件🙂.txt' })
    const binaryRef = await ctx.attachments.saveFile({ data: Buffer.from([0, 255, 1, 128]), name: '原始字节.bin' })
    const emptyRef = await ctx.attachments.saveFile({ data: Buffer.alloc(0), name: '空文件.txt' })
    const orphanRef = await ctx.attachments.saveFile({ data: Buffer.from('unreferenced synthetic attachment'), name: '未引用.txt' })
    const sessionId = 'attachment-fixture-history', otherSessionId = 'attachment-fixture-other'
    for (const [id, content] of [
      [sessionId, [textRef, binaryRef, emptyRef].map(attachment => ({ type: 'file', attachment }))],
      [otherSessionId, [{ type: 'text', text: 'This synthetic session references no files.' }]],
    ]) {
      const handle = await ctx.sessionPersistence.create({
        version: SESSION_FORMAT_VERSION, id: SessionId(id), createdAt: 1000,
        cwd: process.cwd(), isSeeded: false,
      })
      try {
        await handle.append([{
          type: 'user/message', seq: 0, time: 1001, surfaceOp: 'append',
          data: createUserMessage({ content, source: { kind: 'user' } }),
        }])
        await handle.flush()
      } finally { await handle.close() }
    }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.attachmentsReady',
      params: { sessionId, otherSessionId, textRef, binaryRef, emptyRef, orphanRef } }) + '\n')
  } catch (error) {
    const causes = []
    for (let cause = error.cause; cause instanceof Error && causes.length < 4; cause = cause.cause) {
      causes.push({ name: cause.name, code: cause.code, message: cause.message })
    }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.failed',
      params: { message: error.message, causes } }) + '\n')
    throw error
  }
}
