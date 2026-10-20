/** Assemble a symlink-free Android runtime after the ordinary DSH artifact build and CLI deploy. */
import { copyFile, cp, mkdir, readFile, writeFile, readdir, realpath, unlink, stat } from 'node:fs/promises'
import { resolve, join, sep, relative } from 'node:path'
import { existsSync } from 'node:fs'
import { deduplicateStagedWorkspacePackages } from '../../../scripts/build-exe-for-python-sdk-staging.ts'
import { restoreLegacyHoists } from '../../../scripts/executable-packaging.ts'
import { stageQuestionCarrier } from './stage-question-carrier.mjs'

const root = resolve(import.meta.dirname, '../../..')
const staging = join(root, '.cache/android/runtime-bundle')
await restoreLegacyHoists(staging, join(root, 'python/sdk-runtime/node_modules'))
const queue = [join(staging, 'node_modules')]
let links = 0
while (queue.length > 0) {
  const directory = queue.pop()!
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === '.bin') continue
    const destination = join(directory, entry.name)
    if (entry.isSymbolicLink()) {
      const source = await realpath(destination)
      await unlink(destination)
      if (source === staging || staging.startsWith(source + sep)) continue
      const nestedModules = join(source, 'node_modules')
      await cp(source, destination, { recursive: true, dereference: true,
        filter: path => path !== nestedModules && !path.startsWith(nestedModules + sep) })
      links++
      if (links % 100 === 0) console.log(`Materialized ${links} runtime package links`)
    } else if (entry.isDirectory()) queue.push(destination)
  }
}
await deduplicateStagedWorkspacePackages(staging, root)
// Every first-party package uses the one pinned repository revision. Make its
// identity available to the Android carrier as well as the ordinary CLI bundles.
const moduleQueue = [join(staging, 'node_modules')]
while (moduleQueue.length) {
  const directory = moduleQueue.pop()!
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === '.bin' || entry.name === '.pnpm') continue
    const path = join(directory, entry.name)
    if (entry.name === '@deepseek-ai') {
      for (const item of await readdir(path, { withFileTypes: true })) {
        if (!item.isDirectory()) continue
        const source = join(path, item.name)
        const target = join(staging, 'node_modules/@deepseek-ai', item.name)
        if (!existsSync(target)) await cp(source, target, { recursive: true,
          filter: file => !relative(source, file).split(sep).includes('node_modules') })
      }
    }
    moduleQueue.push(path)
  }
}
const workspaceDirectories = []
for (const area of ['vendor', 'apps']) {
  for (const entry of await readdir(join(root, area), { withFileTypes: true })) {
    if (entry.isDirectory()) workspaceDirectories.push(join(root, area, entry.name))
  }
}
for (const group of await readdir(join(root, 'packages'), { withFileTypes: true })) {
  if (!group.isDirectory()) continue
  for (const entry of await readdir(join(root, 'packages', group.name), { withFileTypes: true })) {
    if (entry.isDirectory()) workspaceDirectories.push(join(root, 'packages', group.name, entry.name))
  }
}
for (const directory of workspaceDirectories) {
  const file = join(directory, 'package.json')
  if (!existsSync(file)) continue
  const metadata = JSON.parse(await readFile(file, 'utf8')) as { name: string }
  const target = join(staging, 'node_modules', metadata.name)
  if (!existsSync(target) && metadata.name !== '@deepseek-ai/dsh-host-directory-picker') continue
  await cp(directory, target, { recursive: true,
    filter: async (path) => {
      const local = relative(directory, path)
      if (['node_modules', 'src', 'tests', 'test', '.git', '.cache', 'build'].includes(local.split(sep)[0] ?? '')) return false
      const sourceInfo = await stat(path)
      const destination = join(target, local)
      if (sourceInfo.isFile() && existsSync(destination)) {
        const destinationInfo = await stat(destination)
        if (sourceInfo.ino === destinationInfo.ino && sourceInfo.dev === destinationInfo.dev) return false
      }
      return true
    } })
}
const manifest = JSON.parse(await readFile(join(staging, 'package.json'), 'utf8')) as { version: string; dependencies: Record<string, string> }
const plugin = join(staging, 'node_modules/@minnnng/dsh-android-runtime')
await mkdir(plugin, { recursive: true })
await cp(join(root, 'apps/android/runtime'), plugin, { recursive: true })
await stageQuestionCarrier(plugin)
await writeFile(join(plugin, 'package.json'), JSON.stringify({
  name: '@minnnng/dsh-android-runtime', version: manifest.version, type: 'module', main: './index.mjs',
  exports: { '.': './index.mjs', './package.json': './package.json' },
  license: 'MIT', dsh: { bundle: { patch: './cordis.patch.yml' } }, dependencies: manifest.dependencies,
}, null, 2) + '\n')
await copyFile(join(root, 'apps/android/runtime/bootstrap.mjs'), join(staging, 'bootstrap.mjs'))
await mkdir(join(staging, 'android'), { recursive: true })
await copyFile(join(root, 'apps/android/runtime/flock.mjs'), join(staging, 'android/flock.mjs'))
console.log(`Android runtime staged: ${staging}`)
