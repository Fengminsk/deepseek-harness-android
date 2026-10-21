import { readFileSync } from 'node:fs'
import { registerHooks } from 'node:module'

const staged = new URL('../../../.cache/android/runtime-bundle/', import.meta.url)
const bootstrap = new URL('bootstrap.mjs', staged).href
const guard = new URL('node_modules/@minnnng/dsh-android-runtime/host-guard.mjs', staged).href

// Exercise current Android source against built DSH packages without changing
// the shared staging tree or the packaged runtime.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === guard || (specifier === './node_modules/@minnnng/dsh-android-runtime/host-guard.mjs'
      && context.parentURL === bootstrap)) {
      return { url: new URL('../runtime/host-guard.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (specifier.startsWith('@deepseek-ai/')) {
      return nextResolve(specifier, { ...context, parentURL: new URL('package.json', staged).href })
    }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    if (url === bootstrap) return {
      format: 'module', source: readFileSync(new URL('../runtime/bootstrap.mjs', import.meta.url)), shortCircuit: true,
    }
    return nextLoad(url, context)
  },
})
