import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { load } from 'js-yaml'
import { c as createTar } from 'tar'
import { imageRuntimeArchive, imageRuntimePackages, publishImageRuntimePackage, stageImageRuntime } from './stage-image-runtime.mjs'

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

const fsError = code => Object.assign(new Error(code), { code })
const absent = async () => { throw fsError('ENOENT') }

test('Windows package publication recovers transient rename errors with bounded backoff', async () => {
  const waits = [], inspected = [], failures = ['EPERM', 'EBUSY', 'EACCES']
  let attempts = 0
  const retries = await publishImageRuntimePackage('source', 'target', {
    platform: 'win32',
    inspect: async path => { inspected.push(path); await absent() },
    move: async (source, target) => {
      assert.equal(source, 'source')
      assert.equal(target, 'target')
      if (attempts++ < failures.length) throw fsError(failures[attempts - 1])
    },
    pause: async ms => { waits.push(ms) },
  })
  assert.equal(retries, 3)
  assert.equal(attempts, 4)
  assert.deepEqual(inspected, ['target', 'target', 'target', 'target'])
  assert.deepEqual(waits, [25, 50, 100])
})

test('persistent Windows rename failures stop after seven attempts and retain the original error', async () => {
  const waits = [], failure = fsError('EPERM')
  let attempts = 0
  await assert.rejects(publishImageRuntimePackage('source', 'target', {
    platform: 'win32', inspect: absent,
    move: async () => { attempts++; throw failure },
    pause: async ms => { waits.push(ms) },
  }), error => error === failure)
  assert.equal(attempts, 7)
  assert.deepEqual(waits, [25, 50, 100, 200, 400, 800])
  assert.equal(waits.reduce((sum, ms) => sum + ms, 0), 1575)
})

test('non-Windows and non-transient rename failures are not retried', async () => {
  for (const [platform, code] of [['linux', 'EPERM'], ['darwin', 'EBUSY'], ['win32', 'ENOENT'], ['win32', 'EXDEV']]) {
    const failure = fsError(code)
    let attempts = 0
    await assert.rejects(publishImageRuntimePackage('source', 'target', {
      platform, inspect: absent,
      move: async () => { attempts++; throw failure },
      pause: async () => { assert.fail('unexpected retry') },
    }), error => error === failure)
    assert.equal(attempts, 1)
  }
})

test('publication preserves a target that reappears during rename backoff', async () => {
  await fixture(async root => {
    const temporary = join(root, 'temporary'), destination = join(root, 'target')
    await mkdir(temporary)
    await writeFile(join(temporary, 'package.json'), 'candidate')
    let attempts = 0
    await assert.rejects(publishImageRuntimePackage(temporary, destination, {
      platform: 'win32',
      move: async () => { attempts++; throw fsError('EPERM') },
      pause: async () => {
        await mkdir(destination)
        await writeFile(join(destination, 'package.json'), 'existing valid package')
      },
    }), { code: 'EEXIST' })
    assert.equal(attempts, 1)
    assert.equal(await readFile(join(destination, 'package.json'), 'utf8'), 'existing valid package')
    assert.equal(await readFile(join(temporary, 'package.json'), 'utf8'), 'candidate')
    await assert.rejects(publishImageRuntimePackage(temporary, destination), { code: 'EEXIST' })
    assert.equal(await readFile(join(destination, 'package.json'), 'utf8'), 'existing valid package')
  })
})

test('an unreadable publication target fails before rename without retry', async () => {
  const failure = fsError('EACCES')
  await assert.rejects(publishImageRuntimePackage('source', 'target', {
    platform: 'win32', inspect: async () => { throw failure },
    move: async () => { assert.fail('unverified destination must not be replaced') },
    pause: async () => { assert.fail('inspection errors must not be retried') },
  }), error => error === failure)
})

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
