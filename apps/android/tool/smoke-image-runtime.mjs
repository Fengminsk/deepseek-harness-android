/** Exercise original DSH image admission with only the packaged official WASM codec available. */
import assert from 'node:assert/strict'
import { cp, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import { createRequire, registerHooks } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const repositoryRoot = resolve(import.meta.dirname, '../../..')
const staging = resolve(process.argv[2] ?? join(repositoryRoot, '.cache/android/runtime-bundle'))
const descriptor = JSON.parse(await readFile(join(staging, 'android/image-runtime.json'), 'utf8'))
const root = await mkdtemp(join(tmpdir(), 'pocket-image-wasm-'))
let hook, ctx
try {
  const modules = join(root, 'node_modules')
  await mkdir(modules)
  for (const name of ['sharp', '@img/colour', 'detect-libc', 'semver', ...descriptor.packages.map(item => item.name)]) {
    await cp(join(staging, 'node_modules', name), join(modules, name), { recursive: true, dereference: true })
  }
  // Isolate Sharp from host-native optional dependencies. Its unmodified loader
  // must reach the official WASM fallback also used by Android.
  const codec = pathToFileURL(join(modules, 'sharp/dist/index.cjs')).href
  hook = registerHooks({ resolve(specifier, context, next) {
    return specifier === 'sharp' ? { url: codec, shortCircuit: true } : next(specifier, context)
  } })
  const require = createRequire(join(root, 'fixture.cjs'))
  const sharp = require('sharp')
  assert.equal(sharp.versions.sharp, descriptor.sharp)
  const coreRequire = createRequire(join(repositoryRoot, 'packages/attachment/attachment-local/package.json'))
  const { Context } = await import(pathToFileURL(coreRequire.resolve('@deepseek-ai/cordis')).href)
  const { LocalAttachmentStore } = await import(pathToFileURL(join(repositoryRoot, 'packages/attachment/attachment-local/lib/index.js')).href)
  ctx = new Context()
  const store = new LocalAttachmentStore(ctx, { dshHome: join(root, 'home'), normalizedImageMaxPixels: 4096, maxImagesPerMessage: 4 })
  const started = performance.now()
  const formats = ['png', 'jpeg', 'webp', 'gif']
  const inputs = await Promise.all(formats.map(async format => ({
    data: await sharp({ create: { width: 96, height: 64, channels: 3, background: '#3078de' } })[format]().toBuffer(),
    mediaType: `image/${format}`, name: `synthetic.${format}`,
  })))
  const admitted = await store.admitPromptContent(inputs.map(input => ({ type: 'image', ...input, data: input.data.toString('base64') })))
  assert.equal(admitted.length, 4)
  for (const part of admitted) {
    assert.equal(part.type, 'image')
    const ref = part.attachment
    assert.ok(ref.width * ref.height <= 4096)
    assert.ok(ref.mediaType !== 'image/gif', 'animated-capable inputs are normalized by the original store')
    const stored = await store.readImage(ref)
    const metadata = await sharp(stored.data).metadata()
    assert.equal(metadata.width, ref.width)
    assert.equal(metadata.height, ref.height)
    assert.equal(metadata.exif, undefined)
    assert.equal(metadata.icc, undefined)
  }
  const oriented = await sharp({ create: { width: 64, height: 32, channels: 3, background: '#ea9140' } }).withMetadata({ orientation: 6 }).jpeg().toBuffer()
  const rotated = await store.saveImage({ data: oriented, mediaType: 'image/jpeg' })
  assert.equal(rotated.width, 32)
  assert.equal(rotated.height, 64)
  await assert.rejects(store.validateImage({ data: Buffer.from('corrupt synthetic image'), mediaType: 'image/png' }))
  await assert.rejects(store.validateImage({ ...inputs[0], mediaType: 'image/jpeg' }))
  await assert.rejects(store.saveImages([...inputs, inputs[0]]), error => error.code === 'TOO_MANY_IMAGES')
  await assert.rejects(store.admitPromptContent([{ type: 'image', mediaType: 'image/png', data: 'invalid base64' }]), error => error.code === 'INVALID_IMAGE_BASE64')
  console.log(JSON.stringify({ ok: true, sharp: sharp.versions.sharp, vips: sharp.versions.vips,
    formats, originalStoreAdmission: true, orientationAndMetadata: true,
    corruptAndMismatchedImagesRejected: true, batchLimitsPreserved: true,
    elapsedMs: Math.round(performance.now() - started), rss: process.memoryUsage().rss }))
} finally {
  if (ctx) await ctx.fiber.dispose()
  hook?.deregister()
  await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 30 })
}
