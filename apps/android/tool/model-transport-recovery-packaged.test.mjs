import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, copyFile, writeFile, rm, realpath, readFile, symlink, unlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve, join, relative, isAbsolute } from 'node:path'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'

const root = resolve(import.meta.dirname, '../../..')
const runtime = join(root, '.cache/android/runtime-bundle')
const digest = async path => createHash('sha256').update(await readFile(path)).digest('hex')

async function outsideFixture(t) {
  const folder = await mkdtemp(join(tmpdir(), 'dsh-transport-packaged-'))
  assert.ok(isAbsolute(relative(root, folder)) || relative(root, folder).startsWith('..'), 'Fixture must be outside the repository')
  t.after(() => rm(folder, { recursive: true, force: true }))
  const assets = ['model-transport-recovery-bootstrap.mjs', 'model-transport-recovery-model.mjs',
    'model-transport-recovery-evidence.mjs', 'production-profile-model.mjs']
  for (const asset of assets) await copyFile(join(import.meta.dirname, 'device-runtime-acceptance', asset),
    join(folder, asset === 'model-transport-recovery-bootstrap.mjs' ? 'bootstrap.mjs' : asset))
  return folder
}

async function plainNode(folder, source, args = []) {
  const script = join(folder, 'check.mjs')
  await writeFile(script, source)
  return nodeEntry(folder, script, args)
}

async function nodeEntry(folder, script, args = []) {
  const env = { ...process.env }
  delete env.NODE_OPTIONS
  delete env.NODE_PATH
  delete env.TSX_TSCONFIG_PATH
  return new Promise((resolveResult, reject) => {
    const child = spawn(process.execPath, [script, ...args], { cwd: folder, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    let stdout = '', stderr = '', failure
    const timer = setTimeout(() => { failure = new Error('Packaged import child exceeded 20 seconds'); child.kill() }, 20000)
    for (const [stream, append] of [[child.stdout, chunk => { stdout += chunk }], [child.stderr, chunk => { stderr += chunk }]]) {
      stream.on('data', data => {
        append(data.toString())
        if (stdout.length + stderr.length > 65536 && !failure) { failure = new Error('Packaged import output exceeded limit'); child.kill() }
      })
    }
    child.once('error', error => { failure = error })
    child.once('close', (code, signal) => {
      clearTimeout(timer)
      if (failure) reject(failure)
      else resolveResult({ code, signal, stdout, stderr })
    })
  })
}

test('ordinary Node resolves the copied private-home fixture only from the actual staged runtime', { timeout: 25000 }, async t => {
  const folder = await outsideFixture(t)
  const anchor = join(runtime, 'bootstrap.mjs'), entry = join(runtime, 'node_modules/@deepseek-ai/dsh-llm/lib/index.js')
  const before = [await digest(anchor), await digest(entry)]
  const result = await plainNode(folder, `
import assert from 'node:assert/strict'
import { realpath } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { loadTransportRecoveryModel } from './bootstrap.mjs'
assert.deepEqual(process.execArgv, [])
assert.equal(process.env.NODE_PATH, undefined)
assert.equal(process.env.NODE_OPTIONS, undefined)
const loaded = await loadTransportRecoveryModel(process.argv[2])
const expected = await realpath(join(process.argv[2], 'node_modules/@deepseek-ai/dsh-llm/lib/index.js'))
assert.equal(loaded.packageEntry, expected)
assert.equal(typeof loaded.startTransportRecoveryModel, 'function')
const original = await import(pathToFileURL(expected).href)
assert.deepEqual(original.expandAssistantStream([{type:'text-chunks',time0:1,index:0,dt:[],texts:['packaged']}]),
  [{time:1,chunk:{type:'text-delta',index:0,text:'packaged'}}])
await assert.rejects(import('@deepseek-ai/dsh-llm'), {code:'ERR_MODULE_NOT_FOUND'})
console.log(JSON.stringify({entry: loaded.packageEntry, ordinaryNode: true, unrelatedBareImportRejected: true}))
`, [runtime])
  assert.equal(result.code, 0, result.stderr)
  const proof = JSON.parse(result.stdout)
  assert.equal(proof.entry, await realpath(entry))
  assert.equal(proof.ordinaryNode, true)
  assert.deepEqual([await digest(anchor), await digest(entry)], before, 'Staged runtime must remain read-only')
})

test('a copied fixture with no configured packaged dependency cannot fall back to repository modules', { timeout: 25000 }, async t => {
  const folder = await outsideFixture(t)
  const result = await plainNode(folder, `
import assert from 'node:assert/strict'
import { loadTransportRecoveryModel } from './bootstrap.mjs'
await assert.rejects(loadTransportRecoveryModel(process.cwd()), {code:'ENOENT'})
console.log('missing packaged reader rejected')
`)
  assert.equal(result.code, 0, result.stderr)
  assert.equal(result.stdout.trim(), 'missing packaged reader rejected')
})

test('ordinary Node executes main through a directory symlink or Windows junction instead of silently exiting', { timeout: 25000 }, async t => {
  const folder = await outsideFixture(t)
  const aliasParent = await mkdtemp(join(tmpdir(), 'dsh-transport-entry-alias-'))
  const alias = join(aliasParent, 'fixture')
  let linked = false
  t.after(async () => {
    if (linked) await unlink(alias)
    await rm(aliasParent, { recursive: true, force: true })
  })
  await symlink(folder, alias, process.platform === 'win32' ? 'junction' : 'dir')
  linked = true
  assert.notEqual(join(alias, 'bootstrap.mjs'), await realpath(join(alias, 'bootstrap.mjs')))
  await writeFile(join(folder, 'configuration.json'), JSON.stringify({ suite: 'transport-entry-executed-marker' }))
  for (const entry of [join(folder, 'bootstrap.mjs'), join(alias, 'bootstrap.mjs')]) {
    const result = await nodeEntry(aliasParent, entry)
    assert.equal(result.code, 1, 'main must reach the deliberately rejected configuration, never exit successfully without running')
    assert.match(result.stderr, /transport-entry-executed-marker/u)
    assert.match(result.stderr, /AssertionError/u)
    assert.doesNotMatch(result.stderr, /ERR_MODULE_NOT_FOUND/u)
  }
})
