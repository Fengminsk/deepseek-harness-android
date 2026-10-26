import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { strict as assert } from 'node:assert'
import { createContext, runInContext } from 'node:vm'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(temporaryRoot, 'ptc-script-host-'))
try {
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/PtcScriptEngine.java',
    'android/app/src/test/java/com/minnnng/dsh_android/PtcScriptEngineTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...sources], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.PtcScriptEngineTest'], {
    stdio: 'inherit', windowsHide: true,
  })

  // Evaluate the exact native-held JSON snapshot source before guest code in a
  // V8 context with string-code generation disabled. This checks lossless-JSON
  // behavior against the original Node PTC's completion-value fixtures;
  // Android JNI loading, Binder isolation and watchdog still require a device.
  const nativeSource = readFileSync(join(project, 'android/app/src/main/cpp/ptc_script_engine.cpp'), 'utf8')
  const snapshotSource = nativeSource.match(/R"PTC_JSON\(([\s\S]*?)\)PTC_JSON"/)?.[1]
  assert.ok(snapshotSource, 'native JSON validator source missing')
  const runExpression = async (source, input = {}) => {
    const context = createContext(Object.create(null), {
      codeGeneration: { strings: false, wasm: false },
    })
    const snapshot = runInContext(snapshotSource, context, { timeout: 1000 })
    const fn = runInContext(`(${source})`, context, { timeout: 1000 })
    return snapshot(await fn(input, undefined))
  }
  assert.deepEqual(JSON.parse(JSON.stringify(await runExpression(
    'async input => { const n = await Promise.resolve(input.n); return { n: n * 7 }; }', { n: 6 },
  ))), { n: 42 })
  assert.deepEqual(JSON.parse(JSON.stringify(await runExpression(
    '(input, host) => ({ process: typeof process, require: typeof require, fetch: typeof fetch, host: typeof host })',
  ))), { process: 'undefined', require: 'undefined', fetch: 'undefined', host: 'undefined' })
  assert.deepEqual(JSON.parse(JSON.stringify(await runExpression(
    '() => { Object.prototype.toJSON = () => ({ injected: true }); return { value: [1, 2] }; }',
  ))), { value: [1, 2] })
  for (const expression of [
    '() => ({ missing: undefined })',
    '() => ({ wrong: Number.POSITIVE_INFINITY })',
    '() => -0',
    '() => [1,,3]',
    '() => new Date()',
    '() => Object.defineProperty({}, "hidden", { value: 1 })',
    '() => Object.defineProperty({}, "computed", { enumerable: true, get() { return 1 } })',
    '() => { const o = Object.defineProperty({}, "computed", { enumerable: true, get() { return 1 } }); Object.prototype.value = "forged"; return o; }',
    '() => { const a = Object.defineProperty([0], "0", { enumerable: true, get() { return 1 } }); Object.prototype.value = "forged"; return a; }',
    '() => { Number.isFinite = () => true; return Infinity; }',
  ]) assert.equal(await runExpression(expression), undefined, `lossy output accepted: ${expression}`)

  // The native implementation passes body source as one AsyncFunction constructor
  // argument. This host fixture checks the same grammar: a body cannot close an
  // enclosing wrapper because there is no wrapper in the supplied source text.
  // Android JNI still owns proof that code generation is disabled before call.
  const AsyncFunction = (async () => {}).constructor
  const compileBody = body => new AsyncFunction('input', 'host', "'use strict';\n" + body)
  assert.deepEqual(await compileBody(
    'const value = await Promise.resolve(input.n); return { answer: value * 7 };',
  )({ n: 6 }, undefined), { answer: 42 })
  for (const escape of [
    '}; return {forged:1}; const x=async()=>{',
    '}, (()=>{globalThis.marker=1})(), async()=>{',
  ]) assert.throws(() => compileBody(escape), SyntaxError)
  assert.match(nativeSource, /nativeRunFunctionBody\(/)
  assert.match(nativeSource, /consoleCall\(/)
  assert.match(nativeSource, /kMaxLogBytes = 16 \* 1024/)
  const constructorBranch = nativeSource.slice(nativeSource.indexOf(
    'format == ProgramFormat::kAsyncFunctionBody'))
  const enableAt = constructorBranch.indexOf('AllowCodeGenerationFromStrings(true)')
  const disableAt = constructorBranch.indexOf('AllowCodeGenerationFromStrings(false)', enableAt)
  const guestCallAt = constructorBranch.indexOf('function->Call(', disableAt)
  assert.ok(enableAt >= 0 && disableAt > enableAt && guestCallAt > disableAt,
    'guest call reached V8 before string code generation was disabled')
  process.stdout.write('PTC native snapshot semantics and Java request bounds passed; JNI execution requires Android device evidence.\n')
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('ptc-script-host-')) {
    throw new Error('Refusing to remove a PTC test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
