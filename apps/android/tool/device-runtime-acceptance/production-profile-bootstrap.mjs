import assert from 'node:assert/strict'
import { readFile, writeFile, rename, realpath, mkdir } from 'node:fs/promises'
import { appendFileSync, existsSync } from 'node:fs'
import { registerHooks } from 'node:module'
import { basename, join, relative, isAbsolute } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createHash } from 'node:crypto'
import { startProductionProfileModel, productionBootstrapFailure } from './production-profile-model.mjs'

// The only fixture replacement is the model endpoint. Tool registration and the
// Android profile manifest remain owned by the shipped runtime/bootstrap.mjs.
const started = performance.now()
const nativeHome = process.env.DSH_HOME
assert.ok(typeof nativeHome === 'string' && isAbsolute(nativeHome))
const checkpoint = (stage, extra = {}) => {
  const row = { stage, elapsedMs: Math.round(performance.now() - started), ...extra }
  appendFileSync(join(nativeHome, 'production-profile-startup.jsonl'), JSON.stringify(row) + '\n', { mode: 0o600 })
  process.stderr.write(`[production-profile] ${stage} ${row.elapsedMs}ms\n`)
}
checkpoint('fixture-entered')

// Observe module loading, not evaluation or internal CLI/Loader awaits.
function observeStartup(runtime, home) {
  const cpu = process.cpuUsage()
  const target = join(home, 'production-profile-node-pulse.json')
  const modules = new Map([
    ['node_modules/@deepseek-ai/dsh/lib/bin.js', 'cli-module'],
    ['node_modules/@deepseek-ai/dsh/lib/profile-boot.js', 'profile-module'],
    ['node_modules/@minnnng/dsh-android-runtime/index.mjs', 'android-module'],
  ].map(([path, label]) => [pathToFileURL(join(runtime, path)).href, label]))
  const state = { schema: 1, active: true, pulseCount: 0, lastPulseElapsedMs: null, maxPulseGapMs: 0,
    elapsedMs: 0, cpuUserMicros: 0, cpuSystemMicros: 0, modules: {}, artifacts: {} }
  let writes = Promise.resolve(), writeFailure
  const save = () => {
    const used = process.cpuUsage(cpu)
    state.elapsedMs = Math.round(performance.now() - started)
    state.cpuUserMicros = used.user
    state.cpuSystemMicros = used.system
    state.artifacts = {
      packageManagerState: existsSync(join(home, 'profiles/android/android-package-manager.json')),
      nodeLauncher: existsSync(join(home, 'package-manager/bin/node')),
      profileRoot: existsSync(join(home, 'profiles/android/cordis.yml')),
    }
    const serialized = JSON.stringify(state)
    writes = writes.then(async () => {
      if (writeFailure) return
      await writeFile(`${target}.tmp`, serialized, { mode: 0o600 })
      const until = performance.now() + 500
      for (;;) {
        try { await rename(`${target}.tmp`, target); break }
        catch (failure) {
          if (process.platform !== 'win32' || !['EPERM', 'EACCES', 'EBUSY'].includes(failure.code)
            || performance.now() >= until) throw failure
          await new Promise(resolve => setTimeout(resolve, 10))
        }
      }
    }).catch(failure => { writeFailure ??= failure })
  }
  const hooks = registerHooks({ load(url, context, nextLoad) {
    const label = modules.get(url)
    if (!label) return nextLoad(url, context)
    state.modules[label] = 'loading'
    checkpoint(`${label}-load-start`)
    save()
    try {
      const result = nextLoad(url, context)
      state.modules[label] = 'loaded'
      checkpoint(`${label}-load-returned`)
      return result
    } catch (failure) {
      state.modules[label] = 'failed'
      checkpoint(`${label}-load-failed`, productionBootstrapFailure(failure))
      throw failure
    } finally { save() }
  } })
  let pulseFailure
  const sample = () => {
    const elapsed = Math.round(performance.now() - started)
    if (state.lastPulseElapsedMs !== null) state.maxPulseGapMs = Math.max(state.maxPulseGapMs, elapsed - state.lastPulseElapsedMs)
    state.lastPulseElapsedMs = elapsed
    state.pulseCount++
    save()
  }
  const timer = setInterval(() => {
    try { sample() } catch (failure) { pulseFailure = failure; clearInterval(timer) }
  }, 1000).unref()
  try { sample() } catch (failure) { clearInterval(timer); hooks.deregister(); throw failure }
  return async () => {
    clearInterval(timer)
    hooks.deregister()
    state.active = false
    save()
    await writes
    if (writeFailure) throw writeFailure
    if (pulseFailure) throw pulseFailure
  }
}
let model
try {
const configuration = JSON.parse(await readFile(new URL('./configuration.json', import.meta.url), 'utf8'))
assert.equal(configuration.suite, 'production-profile')
assert.equal(typeof configuration.expectWorkflow, 'boolean')
checkpoint('configuration-validated')
const home = await realpath(process.env.DSH_HOME)
const caseId = basename(home)
assert.match(caseId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u)
const authentication = JSON.parse(await readFile(join(home, 'production-profile-auth.json'), 'utf8'))
assert.ok(authentication.schema === 1 && authentication.caseId === caseId, 'Fixture authentication belongs to another case')
assert.equal(basename(new URL('.', import.meta.url).pathname.replace(/\/$/u, '')), 'fixture')
await mkdir(configuration.workspace, { recursive: true })
const workspace = await realpath(configuration.workspace), appWorkspace = await realpath(configuration.appWorkspaceRoot)
assert.equal(relative(appWorkspace, workspace), `.device-acceptance-${caseId}`)
const runtime = await realpath(configuration.runtime)
assert.ok(isAbsolute(runtime))
checkpoint('directories-validated')
const fileName = `production-profile-${caseId}.txt`
await writeFile(join(workspace, fileName), `production-profile-${caseId}\n`, { flag: 'wx', mode: 0o600 })
const inputs = {}
for (const name of ['bootstrap.mjs', 'node_modules/@minnnng/dsh-android-runtime/index.mjs']) {
  inputs[name] = createHash('sha256').update(await readFile(join(runtime, name))).digest('hex')
}
checkpoint('runtime-inputs-hashed')
model = await startProductionProfileModel({ caseId, fileName, appUid: process.getuid(),
  modelKey: authentication.modelKey, closeToken: authentication.closeToken,
  expectWorkflow: configuration.expectWorkflow,
  async persist(proof) {
    const target = join(home, 'production-profile-proof.json'), temporary = `${target}.tmp`
    await writeFile(temporary, JSON.stringify({ ...proof, inputs }), { mode: 0o600 })
    await rename(temporary, target)
  },
})
checkpoint('model-listening')
process.chdir(workspace)
process.env.DEEPSEEK_BASE_URL = model.url
delete process.env.DEEPSEEK_API_KEY
checkpoint('production-bootstrap-import-start')
const stopObserving = observeStartup(runtime, home)
let importFailure
try { await import(pathToFileURL(join(runtime, 'bootstrap.mjs')).href) }
catch (failure) { importFailure = failure }
try { await stopObserving() }
catch (cleanup) { importFailure = importFailure ? new AggregateError([importFailure, cleanup], 'Startup and observation cleanup failed') : cleanup }
if (importFailure) throw importFailure
checkpoint('production-bootstrap-import-returned')
}
catch (failure) {
  checkpoint('bootstrap-failed', productionBootstrapFailure(failure))
  try { await model?.close() } catch (cleanup) {
    checkpoint('bootstrap-cleanup-failed', productionBootstrapFailure(cleanup))
    throw new AggregateError([failure, cleanup], 'Production bootstrap and model cleanup failed')
  }
  throw failure
}
