import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { load } from 'js-yaml'
import { c as createTar } from 'tar'
import { imageRuntimeArchive, imageRuntimePackages, stageImageRuntime } from './stage-image-runtime.mjs'

const integrityOf = bytes => `sha512-${createHash('sha512').update(bytes).digest('base64')}`

test('official WASM closure stays on the repository Sharp version and complete locked dependencies', async () => {
  const lock = load(await readFile(new URL('../../../pnpm-lock.yaml', import.meta.url), 'utf8'))
  const metadata = JSON.parse(await readFile(new URL('../../../packages/attachment/attachment-local/package.json', import.meta.url), 'utf8'))
  const version = metadata.dependencies.sharp
  const plan = imageRuntimePackages(lock, version)
  assert.deepEqual(plan.map(item => `${item.name}@${item.version}`), ['@img/sharp-wasm32@0.35.5', '@emnapi/runtime@1.11.3', 'tslib@2.8.1'])
  assert.throws(() => imageRuntimePackages(lock, '0.0.0'), /not pinned/)
  const incomplete = structuredClone(lock)
  delete incomplete.snapshots['tslib@2.8.1']
  assert.throws(() => imageRuntimePackages(incomplete, version), /not pinned/)
})

async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'pocket-image-stage-'))
  try { await run(root) }
  finally { await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 30 }) }
}

test('cached bytes are checked before archive extraction', async () => {
  await fixture(async root => {
    const item = { name: '@img/sharp-wasm32', version: '0.35.5', integrity: integrityOf(Buffer.from('expected')) }
    await writeFile(join(root, 'img-sharp-wasm32-0.35.5.tgz'), 'corrupt')
    await assert.rejects(imageRuntimeArchive(item, root), /checksum mismatch/)
  })
})

test('private staging retains original worker, WASM and license files and rejects changed archive identity', async () => {
  await fixture(async root => {
    const source = join(root, 'source'), staging = join(root, 'staging'), cache = join(root, 'archives')
    await mkdir(source)
    await mkdir(cache)
    await mkdir(join(staging, 'node_modules/sharp'), { recursive: true })
    await writeFile(join(staging, 'node_modules/sharp/package.json'), JSON.stringify({ name: 'sharp', version: '0.35.5' }))
    const metadata = { name: '@img/sharp-wasm32', version: '0.35.5', dependencies: {} }
    await writeFile(join(source, 'package.json'), JSON.stringify(metadata))
    await writeFile(join(source, 'worker.js'), 'original worker')
    await writeFile(join(source, 'sharp.wasm'), Buffer.from([0, 97, 115, 109]))
    await writeFile(join(source, 'LICENSE'), 'original license')
    const archive = join(cache, 'img-sharp-wasm32-0.35.5.tgz')
    await createTar({ file: archive, cwd: root, gzip: true }, ['source'])
    const lock = { packages: { '@img/sharp-wasm32@0.35.5': { resolution: { integrity: integrityOf(await readFile(archive)) } } }, snapshots: { '@img/sharp-wasm32@0.35.5': {} } }
    await writeFile(join(root, 'pnpm-lock.yaml'), JSON.stringify(lock))
    await stageImageRuntime({ repositoryRoot: root, staging, cacheDirectory: cache })
    const installed = join(staging, 'node_modules/@img/sharp-wasm32')
    assert.equal(await readFile(join(installed, 'worker.js'), 'utf8'), 'original worker')
    assert.deepEqual(await readFile(join(installed, 'sharp.wasm')), Buffer.from([0, 97, 115, 109]))
    assert.equal(await readFile(join(installed, 'LICENSE'), 'utf8'), 'original license')
    await writeFile(join(source, 'package.json'), JSON.stringify({ ...metadata, version: '0.35.4' }))
    await createTar({ file: archive, cwd: root, gzip: true }, ['source'])
    lock.packages['@img/sharp-wasm32@0.35.5'].resolution.integrity = integrityOf(await readFile(archive))
    await writeFile(join(root, 'pnpm-lock.yaml'), JSON.stringify(lock))
    await assert.rejects(stageImageRuntime({ repositoryRoot: root, staging, cacheDirectory: cache }), /differ from lock/)
    assert.equal(JSON.parse(await readFile(join(installed, 'package.json'), 'utf8')).version, '0.35.5')
  })
})
