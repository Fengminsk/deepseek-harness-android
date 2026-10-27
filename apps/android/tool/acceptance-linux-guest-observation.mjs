import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(temporaryRoot, 'linux-guest-observation-'))
try {
  const source = join(project, 'android/app/src/androidTest/java/com/minnnng/dsh_android/LinuxVmGuestObservation.java')
  const reader = join(project, 'android/app/src/androidTest/java/com/minnnng/dsh_android/LinuxVmObservationReader.java')
  const test = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/LinuxVmGuestObservationTest.java')
  const readerTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/LinuxVmObservationReaderTest.java')
  execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', output, source, reader, test, readerTest],
    { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.LinuxVmGuestObservationTest'],
    { stdio: 'inherit', windowsHide: true, timeout: 10_000 })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.LinuxVmObservationReaderTest'],
    { stdio: 'inherit', windowsHide: true, timeout: 10_000 })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('linux-guest-observation-'))
    throw new Error('Refusing to remove an unrelated temporary directory')
  rmSync(target, { recursive: true })
}
