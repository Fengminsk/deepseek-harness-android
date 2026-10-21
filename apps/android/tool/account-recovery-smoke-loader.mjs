import './web-smoke-loader.mjs'
import { registerHooks } from 'node:module'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === './transport.mjs' && context.parentURL === carrier) {
      return { url: new URL('./account-recovery-smoke-transport.mjs', import.meta.url).href, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
})

// This subprocess may contact only its allocated fake Platform/inference server.
// Keep the shipped account and model providers, including their real caches.
const origin = process.env.POCKET_ACCOUNT_FIXTURE_ORIGIN
if (!origin || new URL(origin).hostname !== '127.0.0.1') throw new Error('Missing loopback account fixture')
const fetch = globalThis.fetch
globalThis.fetch = async (input, options) => {
  const url = new URL(input instanceof Request ? input.url : input)
  if (url.origin !== origin) {
    console.error('[account-recovery] refused network origin', url.origin)
    throw new Error('Account recovery fixture refused non-fixture network access')
  }
  try { return await fetch(input, options) }
  catch (error) {
    console.error('[account-recovery] fixture request failed', error.name, error.message, error.cause?.code)
    throw error
  }
}
