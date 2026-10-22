import './web-smoke-loader.mjs'
import { registerHooks } from 'node:module'
import { accessSync, constants } from 'node:fs'

// Windows executes real commands using Git's POSIX shell. Its bin/sh.exe may
// launch usr/bin/sh.exe, so terminate the process tree rather than only the
// launcher. Android keeps /system/bin/sh and native process-group termination.
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
      const original = "if (process.platform !== 'android') return { executable: '/bin/sh', args: ['-c', command] }"
      if (!loaded.source.toString().includes(original)) throw new Error('Shell executable adapter no longer matches the product source.')
      const groupKill = "process.kill(-child.pid, 'SIGKILL')"
      if (!loaded.source.toString().includes(groupKill)) throw new Error('Shell termination adapter no longer matches the product source.')
      return { ...loaded, source: `import { spawnSync } from 'node:child_process'\n${loaded.source.toString().replace(original,
        `if (process.platform !== 'android') return { executable: ${JSON.stringify(executable)}, args: ['-c', command] }`)
        .replace(groupKill, "smokeKillTree(child.pid)")}\nfunction smokeKillTree(pid) {
  const result = spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'],
    { windowsHide: true, stdio: 'ignore', timeout: 5000 })
  if (result.error) throw result.error
  if (result.status !== 0) {
    const error = new Error('Windows Shell smoke process tree termination failed')
    error.code = 'EPERM'
    throw error
  }
}\n` }
    },
  })
}
