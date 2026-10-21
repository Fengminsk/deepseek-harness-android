import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'

const bootstrap = new URL('../../../.cache/android/runtime-bundle/bootstrap.mjs', import.meta.url).href
const fixture = fileURLToPath(new URL('./smoke-package-operations.mjs', import.meta.url))

// Only the external pnpm executable differs: bootstrap, runCli, profile and manager stay original.
registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context)
    if (url !== bootstrap) return loaded
    const control = process.env.POCKET_PACKAGE_SMOKE_CONTROL
    if (!control || process.platform === 'android') throw new Error('Package-operation smoke requires a desktop fixture directory')
    const source = loaded.source.toString()
    const seam = 'const options = {}'
    if (source.split(seam).length !== 2) throw new Error('Original bootstrap packageManager option seam changed')
    const options = { packageManager: { command: process.execPath, args: [fixture, '--fixture-pnpm', control] } }
    return { ...loaded, source: source.replace(seam, `const options = ${JSON.stringify(options)}`) }
  },
})
