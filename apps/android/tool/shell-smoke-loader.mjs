import './web-smoke-loader.mjs'
import { registerHooks } from 'node:module'
import { accessSync, constants } from 'node:fs'

// Windows executes real commands using Git's POSIX shell and terminates that
// process directly (negative POSIX process-group ids are unavailable). Fixtures
// use shell builtins only. Android keeps /system/bin/sh and group termination.
// No tool, pre-execute gate or answerer is replaced.
if (process.platform === 'win32') {
  const executable = process.env.POCKET_SMOKE_SHELL
  if (!executable) throw new Error('Set POCKET_SMOKE_SHELL to an installed POSIX sh executable.')
  accessSync(executable, constants.F_OK)
  const sourceUrl = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/shell.mjs', import.meta.url).href
  registerHooks({
    load(url, context, nextLoad) {
      const loaded = nextLoad(url, context)
      if (url !== sourceUrl) return loaded
      const original = "process.platform === 'android' ? '/system/bin/sh' : '/bin/sh'"
      if (!loaded.source.toString().includes(original)) throw new Error('Shell executable adapter no longer matches the product source.')
      const groupKill = "process.kill(-child.pid, 'SIGKILL')"
      if (!loaded.source.toString().includes(groupKill)) throw new Error('Shell termination adapter no longer matches the product source.')
      return { ...loaded, source: loaded.source.toString().replace(original, JSON.stringify(executable))
        .replace(groupKill, "child.kill('SIGKILL')") }
    },
  })
}
