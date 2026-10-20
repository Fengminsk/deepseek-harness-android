import { registerHooks } from 'node:module'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
const fixture = new URL('./web-smoke-port.mjs', import.meta.url).href

// The smoke owns ephemeral listeners; only its port allocation differs from the APK.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === './web-access.mjs' && context.parentURL === carrier) {
      return { url: fixture, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
})
