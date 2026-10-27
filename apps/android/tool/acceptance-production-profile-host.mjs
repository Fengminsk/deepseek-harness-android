/** Compile the actual scenario using Android SDK JSON sources, with annotation-only host declarations. */
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { delimiter, dirname, join, resolve } from 'node:path'

const config = JSON.parse(readFileSync(process.argv[2], 'utf8'))
if (typeof config.compilerCp !== 'string') throw new Error('Pass the Kotlin compiler configuration JSON')
const sdkSources = resolve(process.argv[3])
const root = resolve(import.meta.dirname, '../../..')
const output = mkdtempSync(join(root, '.cache/android/production-profile-host-'))
const annotations = {
  'android/annotation/SystemApi.java': 'package android.annotation; public @interface SystemApi { Client client(); enum Client { MODULE_LIBRARIES } }',
  'android/compat/annotation/UnsupportedAppUsage.java': 'package android.compat.annotation; public @interface UnsupportedAppUsage {}',
  'libcore/util/NonNull.java': 'package libcore.util; @java.lang.annotation.Target(java.lang.annotation.ElementType.TYPE_USE) public @interface NonNull {}',
  'libcore/util/Nullable.java': 'package libcore.util; @java.lang.annotation.Target(java.lang.annotation.ElementType.TYPE_USE) public @interface Nullable {}',
}
const sources = readdirSync(join(sdkSources, 'org/json')).filter(name => name.endsWith('.java'))
  .map(name => join(sdkSources, 'org/json', name))
for (const [name, source] of Object.entries(annotations)) {
  const target = join(output, name)
  mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, source); sources.push(target)
}
execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', output, ...sources],
  { stdio: 'inherit', windowsHide: true, timeout: 60000 })
execFileSync('java', ['-cp', config.compilerCp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
  '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [output, config.compilerCp].join(delimiter), '-d', output,
  join(root, 'apps/android/android/app/src/androidTest/kotlin/com/minnnng/dsh_android/ProductionProfileAcceptanceScenario.kt'),
  join(import.meta.dirname, 'production-profile-host/ProductionProfileScenarioTest.kt')],
{ stdio: 'inherit', windowsHide: true, timeout: 60000 })
execFileSync('java', ['-cp', [output, config.compilerCp].join(delimiter),
  'com.minnnng.dsh_android.ProductionProfileScenarioTestKt', output],
{ stdio: 'inherit', windowsHide: true, timeout: 30000 })
process.stdout.write(`Host scenario output: ${output}\n`)
