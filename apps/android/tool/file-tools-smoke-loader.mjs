import assert from 'node:assert/strict'
import { registerHooks } from 'node:module'
import { basename } from 'node:path'

const carrier = new URL('../../../.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime/index.mjs', import.meta.url).href
const filesystem = new URL('./android-filesystem.mjs', carrier).href
const publisher = new URL('./immutable-file-publisher.mjs', carrier).href
const copiedFixture = `${publisher}?file-tools-copied-publication`
const originalFetch = globalThis.fetch
const origin = process.env.POCKET_FILES_MODEL_ORIGIN
const notify = (method, params) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n')
let fixture

globalThis.fetch = (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url)
  if (url.origin !== origin) {
    notify('fixture.unexpectedNetwork')
    return Promise.reject(new Error('File tools fixture permits only its loopback model'))
  }
  return originalFetch(input, init)
}

// Leave every original service and filesystem call intact. Only expose fixture
// capability observations and the fs-local provider's public atomic-write test
// hook, so cancellation can be delivered before its real publication boundary.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL === filesystem && specifier === './immutable-file-publisher.mjs') {
      return { url: copiedFixture, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    if (url === copiedFixture) return { format: 'module', shortCircuit: true, source: `
import { createCopiedFilePublisher } from ${JSON.stringify(publisher)}
import { link, unlink } from 'node:fs/promises'
// Adapt only renameat2 on Windows. The staged Android publisher copies, syncs,
// preserves source/mode and cleans its temporary file exactly as on Android.
const copy = createCopiedFilePublisher(async (source, target) => { await link(source, target); await unlink(source) })
export async function publishImmutableFile(source, target) {
  await copy(source, target)
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'fixture.filePublished', params: { target } }) + '\\n')
}
publishImmutableFile.copiedPublicationFixture = true
` }
    const result = nextLoad(url, context)
    if (url !== carrier) return result
    let source = result.source.toString()
    const entry = 'export function apply(ctx, config)', dispatch = 'transport.onRequest(async (method, params) => {'
    assert.ok(source.includes(entry) && source.includes(dispatch), 'Staged Android carrier fixture seam changed')
    source = source.replace(entry, 'function applyStagedRuntime(ctx, config)').replace(dispatch,
      dispatch + "\nif (method.startsWith('fixture.')) return fileToolsFixtureCall(method, params);")
    return { ...result, source: source + `
import { prepareFileToolsFixture, fileToolsFixtureCall } from ${JSON.stringify(import.meta.url)}
export function apply(ctx, config) {
  applyStagedRuntime(ctx, config)
  ctx.inject(['fs', 'sandboxPolicy', 'tools', 'workspaceChanges'], scope => prepareFileToolsFixture(scope))
}
` }
  },
})

export function prepareFileToolsFixture(ctx) {
  assert.equal(ctx.fs.sandboxMode, 'workspace-write', 'Stage the current Android file-tools profile before this smoke')
  assert.equal(ctx.fs.internals.linkFile?.copiedPublicationFixture, true,
    'Stage AndroidFileSystem with the existing Android copied publisher before this smoke')
  assert.equal(ctx.get('permissionPresets'), undefined, 'Do not advertise nonexistent Shell confinement')
  fixture = { ctx, gate: null, signal: null, inspections: 0, aborts: 0 }
  ctx.on('tools/pre-execute', async (exec, next) => {
    if (fixture.gate && exec.name === 'write' && exec.arguments.file_path === 'cancel-commit.txt') {
      fixture.signal = exec.signal
      const aborted = () => { fixture.aborts++; notify('fixture.writeAborted') }
      exec.signal.addEventListener('abort', aborted, { once: true })
      ctx.effect(() => () => exec.signal.removeEventListener('abort', aborted))
    }
    return next()
  })
  ctx.fs.internals.inspectTemp = async ({ stagingDir, tempPath }) => {
    if (!fixture.gate || basename(tempPath) !== 'cancel-commit.txt.tmp') return
    assert.ok(fixture.signal, 'Original execution signal must be available')
    fixture.inspections++
    notify('fixture.writeStaged', { stagingDir, tempPath })
    await fixture.gate.promise
  }
  ctx.effect(() => () => { fixture.gate?.resolve(); ctx.fs.internals.inspectTemp = undefined })
  notify('fixture.fileToolsReady', { mode: ctx.fs.sandboxMode, permissionPresets: false })
}

export function fileToolsFixtureCall(method) {
  assert.ok(fixture, 'File tools fixture must be ready')
  if (method === 'fixture.armWrite') {
    assert.equal(fixture.gate, null)
    fixture.gate = Promise.withResolvers()
    return true
  }
  if (method === 'fixture.releaseWrite') {
    assert.ok(fixture.signal?.aborted, 'Release only after the original execution was cancelled')
    fixture.gate.resolve()
    return { inspections: fixture.inspections, aborts: fixture.aborts }
  }
  throw new Error(`Unknown file tools fixture method ${method}`)
}
