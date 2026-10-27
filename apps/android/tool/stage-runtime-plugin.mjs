import { cp, lstat, mkdir, readdir, realpath, rm } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'

async function directory(path, optional = false) {
  let info
  try { info = await lstat(path) }
  catch (error) {
    if (optional && error.code === 'ENOENT') return false
    throw error
  }
  if (info.isSymbolicLink() || !info.isDirectory() || relative(path, await realpath(path)) !== '') {
    throw new Error(`Runtime staging requires a real directory without links: ${path}`)
  }
  return true
}

async function treeWithoutLinks(path) {
  await directory(path)
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const child = join(path, entry.name)
    const info = await lstat(child)
    if (info.isSymbolicLink()) throw new Error(`Runtime staging refuses linked entries: ${child}`)
    if (info.isDirectory()) await treeWithoutLinks(child)
    else if (!info.isFile()) throw new Error(`Runtime staging requires regular files: ${child}`)
  }
}

/**
 * Replace only this repository's generated Android plugin directory. Removed or
 * renamed source modules must not survive in the next runtime archive.
 * Parent directories and both trees must be real directories; links and junctions
 * are refused before removing any prior plugin. Other staged packages are untouched.
 */
export async function stageRuntimePlugin({ repositoryRoot, staging }) {
  if (typeof repositoryRoot !== 'string' || !isAbsolute(repositoryRoot)
    || typeof staging !== 'string' || !isAbsolute(staging)) {
    throw new Error('Runtime staging requires absolute repository and staging paths')
  }
  const root = resolve(repositoryRoot)
  const expectedStaging = join(root, '.cache', 'android', 'runtime-bundle')
  if (relative(expectedStaging, resolve(staging)) !== '') {
    throw new Error('Runtime plugin cleanup is restricted to the repository runtime-bundle')
  }
  const source = join(root, 'apps', 'android', 'runtime')
  const plugin = join(expectedStaging, 'node_modules', '@minnnng', 'dsh-android-runtime')
  const local = relative(expectedStaging, plugin)
  if (local !== join('node_modules', '@minnnng', 'dsh-android-runtime')
    || isAbsolute(local) || local.split(sep).includes('..')) {
    throw new Error('Runtime plugin cleanup target is outside its generated directory')
  }
  const parents = [root, join(root, '.cache'), join(root, '.cache', 'android'), expectedStaging,
    join(expectedStaging, 'node_modules')]
  for (const parent of parents) await directory(parent)
  for (const parent of [join(root, 'apps'), join(root, 'apps', 'android')]) await directory(parent)
  await treeWithoutLinks(source)
  const scope = join(expectedStaging, 'node_modules', '@minnnng')
  if (!await directory(scope, true)) await mkdir(scope)
  if (await directory(plugin, true)) {
    await treeWithoutLinks(plugin)
    // Recheck the exact absolute deletion path and every parent immediately before removal.
    for (const parent of [...parents, scope, plugin]) await directory(parent)
    await rm(plugin, { recursive: true })
  }
  for (const parent of [...parents, scope]) await directory(parent)
  await cp(source, plugin, { recursive: true, errorOnExist: true, force: false })
  return plugin
}
