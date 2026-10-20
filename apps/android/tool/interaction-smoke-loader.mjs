import './web-smoke-loader.mjs'
import { registerHooks } from 'node:module'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
// Fixture-only tool exercises the real approval service inside an actual Agent turn.
registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context)
    if (url !== carrier) return loaded
    const source = loaded.source.toString().replace('export function apply(ctx, config)', 'function applyCore(ctx, config)')
    return { ...loaded, source: source + `
export function apply(ctx, config) {
  applyCore(ctx, config)
  ctx.inject(['tools', 'approval'], scope => {
    scope.tools.register(defineTool({
      name: 'smoke_approval', description: 'Approval lifecycle fixture',
      parameters: { command: { type: 'string', required: true } },
      output: { schema: { type: 'json' }, render: (_args, result) => [{ type: 'text', text: JSON.stringify(result) }] },
      async execute(args, execution) {
        return { outcome: await scope.approval.request({
          agent: execution.agent, toolName: 'smoke_approval', callId: execution.callId,
          reason: 'Fixture command: ' + args.command, signal: execution.signal,
        }) }
      },
    }))
  })
}
` }
  },
})
