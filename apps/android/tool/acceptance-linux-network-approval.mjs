import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, delimiter, dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '../../..')
const android = join(root, 'apps/android/android')
const cache = realpathSync(join(root, '.cache/android'))
const output = mkdtempSync(join(cache, 'linux-network-approval-'))
const gradle = process.env.GRADLE_USER_HOME ?? join(homedir(), '.gradle')
const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT
  ?? readFileSync(join(android, 'local.properties'), 'utf8').match(/^sdk\.dir=(.+)$/m)?.[1].trim().replaceAll('\\\\', '\\')
if (!sdk) throw new Error('ANDROID_HOME or local.properties sdk.dir is required')
function artifact(group, name, version) {
  const directory = join(gradle, 'caches/modules-2/files-2.1', group, name, version)
  for (const hash of readdirSync(directory)) {
    const file = join(directory, hash, `${name}-${version}.jar`)
    if (existsSync(file)) return file
  }
  throw new Error(`Cached compiler dependency missing: ${group}/${name}/${version}`)
}
const kotlin = artifact('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.21')
const annotations = artifact('org.jetbrains', 'annotations', '13.0')
const compiler = [artifact('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.21'), kotlin,
  artifact('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.21'),
  artifact('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
  artifact('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.2.21'),
  artifact('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'), annotations]
try {
  const sourceRoot = join(android, 'app/src/main/java')
  const java = join(sourceRoot, 'com/minnnng/dsh_android')
  const sdkJson = join(sdk, 'sources/android-36/org/json')
  const typeAnnotations = {
    'android/compat/annotation/UnsupportedAppUsage.java': 'package android.compat.annotation; public @interface UnsupportedAppUsage { int maxTargetSdk() default 0; long trackingBug() default 0; }',
    'android/annotation/SystemApi.java': 'package android.annotation; public @interface SystemApi { enum Client { MODULE_LIBRARIES } Client client(); }',
    'libcore/util/NonNull.java': 'package libcore.util; @java.lang.annotation.Target({java.lang.annotation.ElementType.TYPE_USE,java.lang.annotation.ElementType.PARAMETER,java.lang.annotation.ElementType.METHOD}) public @interface NonNull {}',
    'libcore/util/Nullable.java': 'package libcore.util; @java.lang.annotation.Target({java.lang.annotation.ElementType.TYPE_USE,java.lang.annotation.ElementType.PARAMETER,java.lang.annotation.ElementType.METHOD}) public @interface Nullable {}',
  }
  // SDK JSON implementation is compiled unchanged; only annotation metadata is substituted for a host JVM.
  const annotationFiles = Object.entries(typeAnnotations).map(([name, content]) => {
    const path = join(output, name); mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, content); return path
  })
  execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-sourcepath', sourceRoot, '-d', output,
    ...annotationFiles, ...readdirSync(sdkJson).filter(name => name.endsWith('.java')).map(name => join(sdkJson, name)),
    ...['IsolatedExecutionApprovalInbox', 'IsolatedExecutionApprovalStore', 'LinuxVmConsole'].map(name => join(java, `${name}.java`))],
  { stdio: 'inherit', windowsHide: true })
  const production = join(android, 'app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmNetworkApprovalCoordinator.kt')
  const test = join(android, 'app/src/test/kotlin/com/minnnng/dsh_android/LinuxVmNetworkApprovalCoordinatorTest.kt')
  execFileSync('java', ['-cp', compiler.join(delimiter), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [output, kotlin, annotations].join(delimiter),
    '-d', output, production, test], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', [`-Djava.io.tmpdir=${output}`, '-cp', [output, kotlin].join(delimiter),
    'com.minnnng.dsh_android.LinuxVmNetworkApprovalCoordinatorTest'], { stdio: 'inherit', windowsHide: true, timeout: 45_000 })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== cache || !basename(target).startsWith('linux-network-approval-')) throw new Error('Unexpected test output path')
  rmSync(target, { recursive: true })
}
