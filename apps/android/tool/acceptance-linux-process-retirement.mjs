import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(temporaryRoot, 'linux-process-retirement-'))
try {
  const main = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/IsolatedLinuxProcessRetirement.java')
  const test = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/IsolatedLinuxProcessRetirementTest.java')
  const admission = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/LinuxCommandAdmission.java')
  const admissionTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/LinuxCommandAdmissionTest.java')
  const tracees = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/LinuxTraceeRetirementLedger.java')
  const traceesTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/LinuxTraceeRetirementLedgerTest.java')
  const eventWire = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/LinuxTraceeEventWire.java')
  const eventWireTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/LinuxTraceeEventWireTest.java')
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output,
    main, test, admission, admissionTest, tracees, traceesTest, eventWire, eventWireTest], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.IsolatedLinuxProcessRetirementTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.LinuxCommandAdmissionTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.LinuxTraceeRetirementLedgerTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.LinuxTraceeEventWireTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('linux-process-retirement-')) {
    throw new Error('Refusing to remove an unrelated temporary directory')
  }
  rmSync(target, { recursive: true })
}
