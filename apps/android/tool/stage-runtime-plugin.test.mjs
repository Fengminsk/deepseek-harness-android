import assert from 'node:assert/strict'
import test from 'node:test'
import { cp, lstat, mkdir, mkdtemp, readFile, realpath, rm, symlink, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { stageRuntimePlugin } from './stage-runtime-plugin.mjs'

async function fixture(t) {
  const temporary = await realpath(await mkdtemp(join(tmpdir(), 'dsh-stage-plugin-')))
  const repositoryRoot = join(temporary, 'repository')
  const staging = join(repositoryRoot, '.cache', 'android', 'runtime-bundle')
  const source = join(repositoryRoot, 'apps', 'android', 'runtime')
  const plugin = join(staging, 'node_modules', '@minnnng', 'dsh-android-runtime')
  const links = []
  t.after(async () => {
    for (const path of links.reverse()) await unlink(path)
    assert.equal(await realpath(temporary), resolve(temporary))
    await rm(temporary, { recursive: true })
  })
  await mkdir(source, { recursive: true })
  await mkdir(join(staging, 'node_modules'), { recursive: true })
  await writeFile(join(source, 'index.mjs'), 'export const current = true\n')
  return { temporary, repositoryRoot, staging, source, plugin, links }
}

test('plugin staging removes deleted modules and stale generated files without touching adjacent dependencies', async t => {
  const f = await fixture(t)
  const sibling = join(f.staging, 'node_modules', '@minnnng', 'keep-dependency')
  await mkdir(join(f.plugin, 'removed-directory'), { recursive: true })
  await mkdir(sibling, { recursive: true })
  await writeFile(join(sibling, 'index.mjs'), 'keep')
  await writeFile(join(f.plugin, 'old-module.mjs'), 'stale')
  await writeFile(join(f.plugin, 'removed-directory', 'stale.mjs'), 'stale nested')
  await writeFile(join(f.plugin, 'package.json'), '{"oldGenerated":true}')
  const result = await stageRuntimePlugin(f)
  assert.equal(result, f.plugin)
  assert.equal(await readFile(join(f.plugin, 'index.mjs'), 'utf8'), 'export const current = true\n')
  for (const name of ['old-module.mjs', 'removed-directory', 'package.json']) {
    await assert.rejects(lstat(join(f.plugin, name)), { code: 'ENOENT' })
  }
  assert.equal(await readFile(join(sibling, 'index.mjs'), 'utf8'), 'keep')
  await unlink(join(f.source, 'index.mjs'))
  await writeFile(join(f.source, 'renamed.mjs'), 'export const renamed = true\n')
  await stageRuntimePlugin(f)
  await assert.rejects(lstat(join(f.plugin, 'index.mjs')), { code: 'ENOENT' })
  assert.equal(await readFile(join(f.plugin, 'renamed.mjs'), 'utf8'), 'export const renamed = true\n')
})

test('plugin staging refuses an alternate deletion root and relative paths', async t => {
  const f = await fixture(t)
  const outside = join(f.temporary, 'outside')
  await mkdir(outside)
  await writeFile(join(outside, 'keep.txt'), 'outside')
  await assert.rejects(stageRuntimePlugin({ ...f, staging: outside }), /restricted/u)
  await assert.rejects(stageRuntimePlugin({ ...f, repositoryRoot: '.' }), /absolute/u)
  assert.equal(await readFile(join(outside, 'keep.txt'), 'utf8'), 'outside')
})

for (const level of ['staging', 'scope', 'plugin', 'nested', 'source']) {
  test(`plugin staging refuses a directory junction at ${level} before deleting files`, async t => {
    const f = await fixture(t)
    const outside = join(f.temporary, 'outside')
    await mkdir(outside)
    await writeFile(join(outside, 'keep.txt'), 'outside')
    let link
    if (level === 'staging') {
      // All entries belong to this test fixture; preserve them in the external target.
      await cp(f.staging, outside, { recursive: true })
      assert.equal(await realpath(f.staging), resolve(f.staging))
      await rm(f.staging, { recursive: true })
      link = f.staging
    } else if (level === 'scope') link = join(f.staging, 'node_modules', '@minnnng')
    else {
      await mkdir(level === 'plugin' ? join(f.plugin, '..') : f.plugin, { recursive: true })
      link = level === 'plugin' ? f.plugin : join(level === 'source' ? f.source : f.plugin, 'linked')
    }
    await symlink(outside, link, process.platform === 'win32' ? 'junction' : 'dir')
    f.links.push(link)
    await assert.rejects(stageRuntimePlugin(f), /without links|linked entries/u)
    assert.equal(await readFile(join(outside, 'keep.txt'), 'utf8'), 'outside')
    assert.equal((await lstat(link)).isSymbolicLink(), true)
    assert.equal(await readFile(join(f.source, 'index.mjs'), 'utf8'), 'export const current = true\n')
  })
}
