import { registerHooks } from 'node:module'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const bundle = process.env.POCKET_UPGRADE_BUNDLE_ROOT
const origin = process.env.POCKET_ACCOUNT_FIXTURE_ORIGIN
if (!bundle || resolve(bundle) !== bundle) throw new Error('Missing absolute APK runtime extraction path')
if (!origin || new URL(origin).hostname !== '127.0.0.1') throw new Error('Missing loopback account fixture')

const carrier = pathToFileURL(join(bundle, 'node_modules/@minnnng/dsh-android-runtime/index.mjs')).href
const transport = new URL('./upgrade-runtime-transport.mjs', import.meta.url).href
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === './transport.mjs' && context.parentURL === carrier) {
      return { url: transport, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
})

const realFetch = globalThis.fetch
globalThis.fetch = (input, options) => {
  const target = new URL(input instanceof Request ? input.url : input)
  if (target.origin !== origin) throw new Error(`APK upgrade fixture refused network origin: ${target.origin}`)
  return realFetch(input, options)
}
