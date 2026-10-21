import { mkdirSync, existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'

// Android loads its packaged N-API library from the APK's executable library directory.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === 'node-addon-require-builtin' && process.platform === 'android') {
      return { url: new URL('./node_modules/@minnnng/dsh-android-runtime/require-builtin.cjs', import.meta.url).href, shortCircuit: true }
    }
    if (specifier === '@minnnng/dsh-android-runtime') {
      return { url: new URL('./node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (specifier === '@deepseek-ai/node-addon-system/flock' && process.platform === 'android') {
      return { url: new URL('./android/flock.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (specifier.startsWith('@deepseek-ai/')) {
      const name = specifier.split('/').slice(0, 2).join('/')
      if (existsSync(new URL(`./node_modules/${name}/package.json`, import.meta.url))) {
        return nextResolve(specifier, { ...context, parentURL: import.meta.url })
      }
    }
    return nextResolve(specifier, context)
  },
})
const profile = join(process.env.DSH_HOME, 'profiles', 'android')
mkdirSync(profile, { recursive: true, mode: 0o700 })
const { ANDROID_BUNDLES, assertAndroidHostConfiguration } = await import(
  './node_modules/@minnnng/dsh-android-runtime/host-guard.mjs')
const manifest = join(profile, 'package.json')
if (!existsSync(manifest)) {
  writeFileSync(manifest, JSON.stringify({ name: 'dsh-android-profile', private: true, type: 'module',
    dsh: { profile: { bundles: ANDROID_BUNDLES } } }, null, 2) + '\n')
}
const cli = new URL('./node_modules/@deepseek-ai/dsh/lib/bin.js', import.meta.url)
assertAndroidHostConfiguration({
  home: process.env.DSH_HOME,
  installAnchor: fileURLToPath(new URL('../package.json', cli)),
})
process.argv = [process.argv[0], fileURLToPath(cli), '--profile', 'android']
const { runCli } = await import(cli.href)
const options = {}
if (process.platform === 'android') {
  const { prepareAndroidPackageManager } = await import(
    './node_modules/@minnnng/dsh-android-runtime/package-manager.mjs')
  options.packageManager = await prepareAndroidPackageManager({
    runtimeDirectory: fileURLToPath(new URL('.', import.meta.url)),
    home: process.env.DSH_HOME,
    nativeLibraryDirectory: process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR,
  })
}
await runCli(options)
