import './web-smoke-loader.mjs'
import { readFileSync } from 'node:fs'
import { registerHooks } from 'node:module'

const staged = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/', import.meta.url)
const owned = new Map(['index.mjs', 'sessions.mjs', 'library.mjs'].map(name => [
  new URL(name, staged).href, new URL(`../runtime/${name}`, import.meta.url),
]))

// Real profile and Gateway, with two empty fixture compositions and one broken
// declaration. Load owned carrier source without mutating shared staging.
registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context)
    const sourceFile = owned.get(url)
    if (sourceFile === undefined) return loaded
    let source = readFileSync(sourceFile, 'utf8')
    if (url === new URL('index.mjs', staged).href) {
      const marker = 'export function apply(ctx, config)'
      if (!source.includes(marker)) throw new Error('Android carrier fixture entry changed')
      source = source.replace(marker, 'function applyCore(ctx, config)') + `
export function apply(ctx, config) {
  applyCore(ctx, config)
  ctx.inject(['agentPresets'], async scope => {
    for (const id of ['fixture-a', 'fixture-b']) {
      const dispose = await scope.agentPresets.register({ id, name: id, plugins: [] })
      scope.effect(() => dispose)
    }
    const disposeBroken = await scope.agentPresets.register({ id: 'fixture-broken', plugins: [
      { name: '' },
    ] })
    scope.effect(() => disposeBroken)
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.presetsReady' }) + '\\n')
  })
}
`
    }
    return { ...loaded, source }
  },
})
