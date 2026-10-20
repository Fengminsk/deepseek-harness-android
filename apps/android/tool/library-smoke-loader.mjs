import './web-smoke-loader.mjs'
import { registerHooks } from 'node:module'

const shell = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/shell.mjs', import.meta.url).href
const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
const library = new URL('../runtime/library.mjs', import.meta.url).href

// Exercise the owned adapter source without racing another agent's staging.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL === carrier && specifier === './library.mjs') return { url: library, shortCircuit: true }
    return nextResolve(specifier, context)
  },
})

// Windows has no /bin/sh. Only the test's executable path changes; the original
// shell implementation, pre-execution directory and approval flow remain intact.
if (process.platform === 'win32') registerHooks({
  load(url, context, nextLoad) {
    const result = nextLoad(url, context)
    if (url !== shell) return result
    if (!process.env.POCKET_LIBRARY_TEST_SHELL) throw new Error('Windows profile needs POCKET_LIBRARY_TEST_SHELL')
    const source = result.source.toString()
    const original = "process.platform === 'android' ? '/system/bin/sh' : '/bin/sh'"
    if (!source.includes(original)) throw new Error('Shell fixture executable seam changed')
    return { ...result, source: source.replace(original,
      "process.platform === 'android' ? '/system/bin/sh' : process.env.POCKET_LIBRARY_TEST_SHELL") }
  },
})
