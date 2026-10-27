import { readFileSync, writeFileSync, mkdirSync, existsSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { registerHooks } from 'node:module'

const configuration = JSON.parse(readFileSync(new URL('./configuration.json', import.meta.url), 'utf8'))
process.chdir(configuration.workspace)
const runtime = pathToFileURL(realpathSync(configuration.runtime) + '/')
registerHooks({ resolve(specifier, context, nextResolve) {
  if (/^\.\.\/\.\.\/runtime\/[a-z0-9-]+\.mjs$/.test(specifier)
    && context.parentURL === new URL('./ptc.mjs', import.meta.url).href) {
    return { url: new URL('node_modules/@minnnng/dsh-android-runtime/' + specifier.split('/').at(-1), runtime).href, shortCircuit: true }
  }
  if (specifier === 'node-addon-require-builtin' && process.platform === 'android') {
    return { url: new URL('node_modules/@minnnng/dsh-android-runtime/require-builtin.cjs', runtime).href, shortCircuit: true }
  }
  if (specifier === '@deepseek-ai/node-addon-system/flock' && process.platform === 'android') {
    return { url: new URL('android/flock.mjs', runtime).href, shortCircuit: true }
  }
  if (specifier.startsWith('@deepseek-ai/')) {
    const name = specifier.split('/').slice(0, 2).join('/')
    if (existsSync(new URL(`node_modules/${name}/package.json`, runtime))) {
      return nextResolve(specifier, { ...context, parentURL: new URL('bootstrap.mjs', runtime).href })
    }
  }
  return nextResolve(specifier, context)
} })
const profile = join(process.env.DSH_HOME, 'profiles', 'device-acceptance')
mkdirSync(profile, { recursive: true })
writeFileSync(join(profile, 'package.json'), JSON.stringify({ name: 'dsh-device-acceptance', private: true,
  type: 'module', dsh: { profile: { bundles: [] } } }))
writeFileSync(join(profile, 'cordis.patch.yml'), '- insert:\n    - id: device-acceptance\n      name: ' +
  JSON.stringify(new URL('./index.mjs', import.meta.url).href) + '\n')
const cli = new URL('node_modules/@deepseek-ai/dsh/lib/bin.js', runtime)
process.argv = [process.argv[0], fileURLToPath(cli), '--profile', 'device-acceptance']
await (await import(cli.href)).runCli({})
