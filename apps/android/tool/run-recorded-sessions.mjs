import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { glob, lstat, readFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const toolRoot = resolve(import.meta.dirname)
const repositoryRoot = resolve(toolRoot, '../../..')
const manifestPath = join(toolRoot, 'recorded-sessions.json')
const idPattern = /^[a-z][a-z0-9-]*$/
const scriptPattern = /^[a-z][a-z0-9-]*\.mjs$/
const inputPattern = /^scenarios\/[a-z][a-z0-9-]*\.json$/
const expectedPattern = /^expected\/[a-z][a-z0-9-]*\.expected\.json$/

/** Keep this lane owner-local: canonical snapshots must launch through dsh. */
export function validateRecordedSessionManifest(value) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value))
  assert.equal(value.version, 1)
  assert.ok(Array.isArray(value.scenarios) && value.scenarios.length > 0)
  const ids = new Set()
  const scripts = new Set()
  for (const scenario of value.scenarios) {
    assert.ok(scenario && typeof scenario === 'object' && !Array.isArray(scenario))
    assert.match(scenario.id, idPattern)
    assert.match(scenario.script, scriptPattern)
    assert.match(scenario.input, inputPattern)
    assert.match(scenario.expected, expectedPattern)
    assert.ok(!ids.has(scenario.id), `Duplicate Android recorded Session ID: ${scenario.id}`)
    assert.ok(!scripts.has(scenario.script), `Duplicate Android recorded Session script: ${scenario.script}`)
    ids.add(scenario.id)
    scripts.add(scenario.script)
  }
  return value.scenarios
}

/** A test against an old staged profile would produce a misleading green result. */
export async function assertCurrentAndroidRuntimeSources(sourceRoot, stagedRoot) {
  let checked = 0
  for await (const relativePath of glob('**/*', { cwd: sourceRoot })) {
    if (relativePath === 'cordis.patch.yml') continue // stage-preset owns this generated patch
    const source = join(sourceRoot, relativePath)
    if (!(await lstat(source)).isFile()) continue
    const staged = join(stagedRoot, relativePath)
    const stagedInfo = await lstat(staged).catch(() => null)
    assert.ok(stagedInfo?.isFile(), `Staged Android profile lacks ${relativePath}; run stage-runtime.ts`)
    assert.ok((await readFile(source)).equals(await readFile(staged)),
      `Staged Android profile is stale at ${relativePath}; run stage-runtime.ts`)
    checked++
  }
  assert.ok(checked > 0, 'Android runtime source directory is empty')
  return checked
}

export async function runRecordedSessions({ refresh = false } = {}) {
  const scenarios = validateRecordedSessionManifest(JSON.parse(await readFile(manifestPath, 'utf8')))
  const stagedBootstrap = join(repositoryRoot, '.cache/android/runtime-bundle/bootstrap.mjs')
  assert.ok((await lstat(stagedBootstrap).catch(() => null))?.isFile(),
    'Android runtime is not staged; follow apps/android/README.md Build the preview before this lane')
  await assertCurrentAndroidRuntimeSources(join(repositoryRoot, 'apps/android/runtime'),
    join(repositoryRoot, '.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime'))
  for (const scenario of scenarios) {
    const script = join(toolRoot, scenario.script)
    const input = join(toolRoot, scenario.input)
    const expected = join(toolRoot, scenario.expected)
    assert.ok((await lstat(script).catch(() => null))?.isFile(), `Missing regular scenario script: ${scenario.script}`)
    assert.ok((await lstat(input).catch(() => null))?.isFile(), `Missing regular scenario input: ${scenario.input}`)
    assert.ok((await lstat(expected).catch(() => null))?.isFile(), `Missing regular expected output: ${scenario.expected}`)
    console.log(`Android recorded Session: ${scenario.id}`)
    const result = await new Promise((fulfill, reject) => {
      const child = spawn(process.execPath, [script, ...(refresh ? ['--refresh-snapshot'] : [])], {
        cwd: repositoryRoot,
        env: { ...process.env, DEEPSEEK_API_KEY: '', DSH_SNAPSHOT: 'replay' },
        stdio: 'inherit',
      })
      child.once('error', reject)
      child.once('exit', (code, signal) => fulfill({ code, signal }))
    })
    assert.equal(result.signal, null, `${scenario.id} was terminated by ${result.signal}`)
    assert.equal(result.code, 0, `${scenario.id} failed with exit ${result.code}`)
  }
  console.log(`Android recorded Sessions: ${scenarios.length} passed`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const refresh = process.argv.length === 3 && process.argv[2] === '--refresh'
  assert.ok(process.argv.length === 2 || refresh, 'Only --refresh is accepted')
  await runRecordedSessions({ refresh })
}
