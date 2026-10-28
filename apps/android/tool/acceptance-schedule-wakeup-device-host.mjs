/** Compile only the natural-wake test carrier and run its evidence checks, without Gradle or a device. */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { delimiter, dirname, join, resolve } from 'node:path'
import { renderReminderFraming } from '../../../packages/schedule/schedule/lib/index.js'
import { createToolResultMessage, createUserMessage } from '../../../packages/llm/llm/lib/index.js'

const root = resolve(import.meta.dirname, '../../..')
const output = mkdtempSync(join(root, '.cache/android/schedule-wake-device-host-'))
const id = '42b1d2e3-1234-4567-8abc-123456789012'
const record = { id: 'acceptance-reminder', kind: 'after', title: `schedule-acceptance-${id}`,
  prompt: `请只回复这一行：schedule-delivered-${id}。不要调用工具，不要读取文件，不要添加解释。`,
  afterSeconds: 180, scheduledAt: '2030-01-01T00:03:00.000Z' }
writeFileSync(join(output, 'original-messages.json'), JSON.stringify({
  record,
  input: createUserMessage({ content: [{ type: 'text', text: renderReminderFraming(record) }], source: { kind: 'schedule' } }),
  result: createToolResultMessage({ callId: 'create-call', content: [{ type: 'text', text: JSON.stringify(record) }], isError: false }),
}))
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
const sources = ['AgentServiceTaskEvidence', 'AgentServiceProgrammaticEvidence',
  'ScheduleWakeupAcceptanceEvidence', 'ScheduleWakeupAcceptanceInstrumentation']
  .map(name => join(root, `apps/android/android/app/src/androidTest/kotlin/com/minnnng/dsh_android/${name}.kt`))
execFileSync('java', ['-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
  '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [output, compiler, join(sdk, 'platforms/android-36/android.jar')].join(delimiter), '-d', output,
  ...sources, join(root, 'apps/android/android/app/src/main/kotlin/com/minnnng/dsh_android/WirePayload.kt'),
  join(import.meta.dirname, 'schedule-wakeup-host/ScheduleWakeupAcceptanceEvidenceTest.kt')],
{ stdio: 'inherit', windowsHide: true, timeout: 60000 })
execFileSync('java', ['-cp', [output, compiler].join(delimiter),
  'com.minnnng.dsh_android.ScheduleWakeupAcceptanceEvidenceTestKt', output],
{ stdio: 'inherit', windowsHide: true, timeout: 30000 })
process.stdout.write(`Natural-wake host evidence: ${output}\n`)
