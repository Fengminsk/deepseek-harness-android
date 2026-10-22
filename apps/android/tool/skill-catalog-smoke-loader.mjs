import { registerHooks } from 'node:module'
import { join } from 'node:path'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
const originalFetch = globalThis.fetch
const modelOrigin = process.env.POCKET_SKILL_FIXTURE_MODEL_ORIGIN
globalThis.fetch = (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url)
  if (url.origin !== modelOrigin) {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.unexpectedNetwork' }) + '\n')
    return Promise.reject(new Error('Skill fixture allows only its loopback model endpoint'))
  }
  return originalFetch(input, init)
}

// Add synthetic registry input and persisted headers only. The original skill
// registry, SessionSkillCatalog, providers and tool-skill remain unmodified.
registerHooks({
  load(url, context, nextLoad) {
    const result = nextLoad(url, context)
    if (url !== carrier) return result
    const source = result.source.toString()
    const marker = 'export function apply(ctx, config)'
    if (!source.includes(marker)) throw new Error('Staged Android runtime fixture seam changed')
    return { ...result, source: source.replace(marker, 'function applyStagedRuntime(ctx, config)') + `
import { prepareSkillFixture } from ${JSON.stringify(import.meta.url)}
export function apply(ctx, config) {
  applyStagedRuntime(ctx, config)
  ctx.inject(['skills', 'sessionPersistence'], scope => prepareSkillFixture(scope))
}
` }
  },
})

export async function prepareSkillFixture(ctx) {
  try {
    ctx.skills.register({ name: 'pocket-virtual', description: 'Synthetic virtual skill without a file path.',
      source: 'runtime', content: 'POCKET_VIRTUAL_SKILL_BODY',
      invocation: { userInvocable: true, modelInvocable: true },
      resourceBase: { kind: 'opaque', description: 'Synthetic smoke fixture' } })
    if (process.env.POCKET_SKILL_FIXTURE_SEED === '1') {
      const { SESSION_FORMAT_VERSION, SessionId } = await import('@deepseek-ai/dsh-session')
      const { createUserMessage } = await import('@deepseek-ai/dsh-llm')
      for (const [id, cwd] of [
        ['skill-catalog-fixture', process.cwd()],
        ['skill-catalog-other', join(process.env.DSH_HOME, 'other-workspace')],
      ]) {
        const handle = await ctx.sessionPersistence.create({ version: SESSION_FORMAT_VERSION,
          id: SessionId(id), createdAt: 1000, cwd, agentPreset: 'android', isSeeded: false })
        try {
          await handle.append([{ type: 'user/message', seq: 0, time: 1001, surfaceOp: 'append',
            data: createUserMessage({ content: [{ type: 'text', text: 'Synthetic skill catalog history.' }],
              source: { kind: 'user' } }) }])
          await handle.flush()
        } finally { await handle.close() }
      }
    }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.skillsReady' }) + '\n')
  } catch (error) {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.failed', params: { message: error.message } }) + '\n')
    throw error
  }
}
