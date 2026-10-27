import assert from 'node:assert/strict'
import { readFile, writeFile, rename, realpath } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
import { basename, join, relative, isAbsolute, sep } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { registerHooks } from 'node:module'
import { createHash } from 'node:crypto'

/** Resolve only this fixture's stream reader from the exact packaged runtime, then remove the temporary hook. */
export async function loadTransportRecoveryModel(runtimeDirectory) {
  const runtime = await realpath(runtimeDirectory)
  const packageRoot = await realpath(join(runtime, 'node_modules/@deepseek-ai/dsh-llm'))
  const contains = (root, path) => { const name = relative(root, path); return name !== '' && !isAbsolute(name) && name !== '..' && !name.startsWith(`..${sep}`) }
  assert.ok(contains(runtime, packageRoot), 'The stream reader must belong to the packaged runtime')
  const anchor = pathToFileURL(join(runtime, 'bootstrap.mjs')).href
  const evidence = new URL('./model-transport-recovery-evidence.mjs', import.meta.url).href
  let packageEntry
  const hook = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier !== '@deepseek-ai/dsh-llm' || context.parentURL !== evidence) return nextResolve(specifier, context)
      const result = nextResolve(specifier, { ...context, parentURL: anchor })
      const actual = realpathSync(fileURLToPath(result.url))
      assert.ok(contains(packageRoot, actual), 'The stream reader resolved outside the packaged package')
      packageEntry = actual
      return result
    },
  })
  try {
    const model = await import('./model-transport-recovery-model.mjs')
    assert.ok(packageEntry, 'The fixture stream reader was not resolved by its packaged runtime owner')
    return { ...model, packageEntry }
  } finally { hook.deregister() }
}

// Credentials/native isolation and proof closure reuse the production-profile
// scenario; the Android bootstrap and original retry policy remain unchanged.
async function main() {
const configuration = JSON.parse(await readFile(new URL('./configuration.json', import.meta.url), 'utf8'))
assert.equal(configuration.suite, 'model-transport-recovery')
const home = await realpath(process.env.DSH_HOME), caseId = basename(home)
assert.match(caseId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u)
const authentication = JSON.parse(await readFile(join(home, 'production-profile-auth.json'), 'utf8'))
assert.ok(authentication.schema === 1 && authentication.caseId === caseId)
const workspace = await realpath(configuration.workspace), appWorkspace = await realpath(configuration.appWorkspaceRoot)
assert.equal(relative(appWorkspace, workspace), `.device-acceptance-${caseId}`)
const runtime = await realpath(configuration.runtime)
assert.ok(isAbsolute(runtime))
const { startTransportRecoveryModel } = await loadTransportRecoveryModel(runtime)
const inputs = {}
for (const name of ['bootstrap.mjs', 'node_modules/@minnnng/dsh-android-runtime/index.mjs']) {
  inputs[name] = createHash('sha256').update(await readFile(join(runtime, name))).digest('hex')
}
const model = await startTransportRecoveryModel({ caseId, modelKey: authentication.modelKey, closeToken: authentication.closeToken,
  async persist(proof) {
    const target = join(home, 'production-profile-proof.json'), temporary = `${target}.tmp`
    await writeFile(temporary, JSON.stringify({ ...proof, inputs }), { mode: 0o600 })
    await rename(temporary, target)
  },
})
try {
  process.chdir(workspace)
  process.env.DEEPSEEK_BASE_URL = model.url
  delete process.env.DEEPSEEK_API_KEY
  await import(pathToFileURL(join(runtime, 'bootstrap.mjs')).href)
} catch (failure) {
  try { await model.close() } catch (cleanup) { throw new AggregateError([failure, cleanup], 'Transport bootstrap and cleanup failed') }
  throw failure
}
}

// Importing this test entry only exposes its loader for a plain-Node packaged-path
// regression. The native carrier executes this same file directly as bootstrap.mjs.
if (process.argv[1] && await realpath(process.argv[1]) === await realpath(fileURLToPath(import.meta.url))) await main()
