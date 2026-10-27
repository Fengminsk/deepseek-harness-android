/** Compile only the two composed AndroidTest scenarios and their diagnostic checks, without Gradle or a device. */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { delimiter, dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '../../..')
const output = mkdtempSync(join(root, '.cache/android/model-transport-host-'))
const gradle = process.env.GRADLE_USER_HOME ?? join(homedir(), '.gradle')
const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT
  ?? readFileSync(join(root, 'apps/android/android/local.properties'), 'utf8').match(/^sdk\.dir=(.+)$/m)?.[1].trim().replaceAll('\\\\', '\\')
if (!sdk) throw new Error('Android SDK sources are required')
function artifact(group, name, version) {
  const directory = join(gradle, 'caches/modules-2/files-2.1', group, name, version)
  for (const hash of readdirSync(directory)) {
    const file = join(directory, hash, `${name}-${version}.jar`)
    if (existsSync(file)) return file
  }
  throw new Error(`Cached compiler dependency missing: ${name}/${version}`)
}
const kotlin = artifact('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.21')
const compiler = [artifact('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.21'), kotlin,
  artifact('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.21'),
  artifact('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
  artifact('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.2.21'),
  artifact('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
  artifact('org.jetbrains', 'annotations', '13.0')].join(delimiter)
const annotations = {
  'android/annotation/SystemApi.java': 'package android.annotation; public @interface SystemApi { Client client(); enum Client { MODULE_LIBRARIES } }',
  'android/compat/annotation/UnsupportedAppUsage.java': 'package android.compat.annotation; public @interface UnsupportedAppUsage {}',
  'libcore/util/NonNull.java': 'package libcore.util; @java.lang.annotation.Target(java.lang.annotation.ElementType.TYPE_USE) public @interface NonNull {}',
  'libcore/util/Nullable.java': 'package libcore.util; @java.lang.annotation.Target(java.lang.annotation.ElementType.TYPE_USE) public @interface Nullable {}',
}
const json = join(sdk, 'sources/android-36/org/json')
const java = readdirSync(json).filter(name => name.endsWith('.java')).map(name => join(json, name))
for (const [name, source] of Object.entries(annotations)) {
  const target = join(output, name)
  mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, source); java.push(target)
}
execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', output, ...java],
  { stdio: 'inherit', windowsHide: true, timeout: 60000 })
const scenarios = ['ProductionProfileAcceptanceScenario', 'ModelTransportRecoveryScenario']
  .map(name => join(root, `apps/android/android/app/src/androidTest/kotlin/com/minnnng/dsh_android/${name}.kt`))
execFileSync('java', ['-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
  '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [output, compiler].join(delimiter), '-d', output,
  ...scenarios, join(import.meta.dirname, 'model-transport-recovery-host/ModelTransportRecoveryScenarioTest.kt')],
{ stdio: 'inherit', windowsHide: true, timeout: 60000 })
execFileSync('java', ['-cp', [output, compiler].join(delimiter),
  'com.minnnng.dsh_android.ModelTransportRecoveryScenarioTestKt', output],
{ stdio: 'inherit', windowsHide: true, timeout: 30000 })
process.stdout.write(`Host scenario output: ${output}\n`)
