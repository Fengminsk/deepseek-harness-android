import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, realpathSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, delimiter, dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '../../..')
const cache = realpathSync(join(root, '.cache/android'))
const gradle = process.env.GRADLE_USER_HOME ?? join(homedir(), '.gradle')
function artifact(group, name, version) {
  const directory = join(gradle, 'caches/modules-2/files-2.1', group, name, version)
  for (const hash of readdirSync(directory)) {
    const path = join(directory, hash, `${name}-${version}.jar`)
    if (existsSync(path)) return path
  }
  throw new Error(`Missing cached compiler artifact: ${group}/${name}/${version}`)
}
const kotlin = artifact('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.21')
const annotations = artifact('org.jetbrains', 'annotations', '13.0')
const compiler = [artifact('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.21'), kotlin,
  artifact('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.21'),
  artifact('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
  artifact('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.2.21'),
  artifact('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'), annotations]
const output = mkdtempSync(join(cache, 'acceptance-service-'))
try {
  const src = join(root, 'apps/android/android/app/src')
  execFileSync('java', ['-cp', compiler.join(delimiter), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', [kotlin, annotations].join(delimiter),
    '-d', output, join(src, 'acceptance/kotlin/com/minnnng/dsh_android/AcceptanceServiceOwner.kt'),
    join(root, 'apps/android/tool/acceptance-service-host/AcceptanceServiceOwnerTest.kt')],
  { stdio: 'inherit', windowsHide: true, timeout: 90_000 })
  execFileSync('java', ['-cp', [output, kotlin].join(delimiter), 'com.minnnng.dsh_android.AcceptanceServiceOwnerTest'],
    { stdio: 'inherit', windowsHide: true, timeout: 30_000 })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== cache || !basename(target).startsWith('acceptance-service-')) throw new Error('Unexpected test output path')
  rmSync(target, { recursive: true })
}
