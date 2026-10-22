import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { test } from 'node:test'
import { load } from 'js-yaml'
import { officeRuntimeArchive, officeRuntimePackages, verifyOfficeEngine } from './stage-office-runtime.mjs'

const root = resolve(import.meta.dirname, '../../..')
const staged = join(root, '.cache/android/runtime-bundle/node_modules/@deepseek-ai/libreoffice-kit-wasm')

test('staged Office provider resolves the pinned kit CLI from its own runtime location', () => {
  const provider = join(root, '.cache/android/runtime-bundle/node_modules/@deepseek-ai/dsh-office-to-pdf/lib/index.js')
  const cli = createRequire(provider).resolve('@deepseek-ai/libreoffice-kit/cli')
  assert.equal(cli, join(root, '.cache/android/runtime-bundle/node_modules/@deepseek-ai/libreoffice-kit/lib/cli.js'))
})

test('Office Android engine is pinned to an unrestricted matching WASM release', async () => {
  const source = JSON.parse(await readFile(join(root, 'packages/document/office-to-pdf/package.json'), 'utf8'))
  const lock = load(await readFile(join(root, 'pnpm-lock.yaml'), 'utf8'))
  const packages = officeRuntimePackages(lock, source.dependencies['@deepseek-ai/libreoffice-kit'])
  assert.deepEqual(packages.map(item => item.name),
    ['@deepseek-ai/libreoffice-kit', '@deepseek-ai/libreoffice-kit-wasm'])
  assert.throws(() => officeRuntimePackages(lock, '0.1.5'), /not portable|matching WASM/)
  assert.throws(() => officeRuntimePackages(lock, '0.2.1'), /not.*pinned|matching WASM/)
})

test('tampered cached Office archives are refused before extraction', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-office-archive-test-'))
  try {
    const item = { name: '@deepseek-ai/libreoffice-kit-wasm', version: '0.2.0',
      integrity: `sha512-${createHash('sha512').update('original').digest('base64')}`,
      url: 'https://invalid.example/unused.tgz' }
    await writeFile(join(directory, 'libreoffice-kit-wasm-0.2.0.tgz'), 'tampered')
    await assert.rejects(officeRuntimeArchive(item, directory), /checksum mismatch/)
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('staged WASM asset hashes and identity match the official manifest', async () => {
  const engine = await verifyOfficeEngine(staged, '0.2.0')
  assert.equal(engine.backend, 'wasm')
  assert.equal(engine.assets.length, 5)
  await assert.rejects(verifyOfficeEngine(staged, '0.1.5'), /identity mismatch/)
})

test('engine verifier rejects changed bytes and paths outside assets', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-office-engine-test-'))
  try {
    await mkdir(join(directory, 'assets'))
    const paths = ['loader.cjs', 'engine.wasm', 'engine.data', 'engine.metadata', 'manifest.json']
    const files = Object.fromEntries(paths.map(path => [`assets/${path}`,
      createHash('sha256').update(path).digest('hex')]))
    for (const path of paths) await writeFile(join(directory, 'assets', path), path)
    const manifest = { version: '0.2.0', platform: 'wasm', status: 'built', files,
      engine: { kind: 'wasm', loader: 'assets/loader.cjs', wasm: 'assets/engine.wasm',
        data: 'assets/engine.data', metadata: 'assets/engine.metadata' } }
    await writeFile(join(directory, 'prebuilds.json'), JSON.stringify(manifest))
    await verifyOfficeEngine(directory, '0.2.0')
    await writeFile(join(directory, 'assets/engine.wasm'), 'changed')
    await assert.rejects(verifyOfficeEngine(directory, '0.2.0'), /checksum mismatch/)
    manifest.engine.wasm = '../outside.wasm'
    await writeFile(join(directory, 'prebuilds.json'), JSON.stringify(manifest))
    await assert.rejects(verifyOfficeEngine(directory, '0.2.0'), /invalid asset path/)
  } finally { await rm(directory, { recursive: true, force: true }) }
})
