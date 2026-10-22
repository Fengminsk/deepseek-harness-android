import { registerHooks } from 'node:module'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
const carrierSource = new URL('../runtime/index.mjs', import.meta.url)
const documentSource = new URL('../runtime/document-preview.mjs', import.meta.url).href
const filesystem = new URL('../../../.cache/android/runtime-bundle/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js', import.meta.url).href

// No read-only profile scenario may contact a model, telemetry, or a Web server.
globalThis.fetch = async () => {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.unexpectedNetwork' }) + '\n')
  throw new Error('Document fixture refuses network access')
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL === carrier && specifier === './document-preview.mjs') return { url: documentSource, shortCircuit: true }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    const result = nextLoad(url, context)
    if (url === filesystem) {
      const source = result.source.toString()
      const marker = 'async readBytes(target, signal, maxBytes) {'
      if (!source.includes(marker)) throw new Error('Original fs-local readBytes fixture seam changed')
      return { ...result, source: source.replace(marker, `${marker}
        if (this.processPath(target).endsWith('cancel.bin')) await documentReadBarrier(signal);
      `) + `\nimport { documentReadBarrier } from ${JSON.stringify(import.meta.url)}\n` }
    }
    if (url !== carrier) return result
    // Keep all staged original providers; load only the owned carrier changes.
    const source = readFileSync(carrierSource, 'utf8')
    const marker = 'export function apply(ctx, config)'
    if (!source.includes(marker)) throw new Error('Android runtime fixture entry changed')
    return { ...result, source: source.replace(marker, 'function applyRuntime(ctx, config)') + `
import { prepareDocumentFixture } from ${JSON.stringify(import.meta.url)}
export function apply(ctx, config) {
  applyRuntime(ctx, config)
  ctx.inject(['sessionPersistence'], scope => prepareDocumentFixture(scope))
}
` }
  },
})

/** Deterministic timing only: original file stat, authority and scope run before this barrier. */
export async function documentReadBarrier(signal) {
  signal.throwIfAborted()
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.readEntered' }) + '\n')
  await new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true })
  })
}

/** Seed persisted headers through the original storage, without constructing live Sessions. */
export async function prepareDocumentFixture(ctx) {
  try {
    if (process.env.POCKET_DOCUMENT_FIXTURE_SEED === '1') {
      const { SESSION_FORMAT_VERSION, SessionId } = await import('@deepseek-ai/dsh-session')
      const { createUserMessage } = await import('@deepseek-ai/dsh-llm')
      for (const name of ['a', 'b']) {
        const handle = await ctx.sessionPersistence.create({ version: SESSION_FORMAT_VERSION,
          id: SessionId(`document-fixture-${name}`), createdAt: 1000, cwd: join(process.cwd(), name), isSeeded: false })
        try {
          await handle.append([{ type: 'user/message', seq: 0, time: 1001, surfaceOp: 'append',
            data: createUserMessage({ content: [{ type: 'text', text: 'Synthetic document preview history.' }], source: { kind: 'user' } }) }])
          await handle.flush()
        } finally { await handle.close() }
      }
    }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.documentsReady' }) + '\n')
  } catch (error) {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.failed', params: { message: error.message } }) + '\n')
    throw error
  }
}
