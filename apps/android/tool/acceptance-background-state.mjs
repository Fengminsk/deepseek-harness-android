import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-background-state-'))
try {
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/BackgroundTaskState.java',
    'android/app/src/test/java/com/minnnng/dsh_android/BackgroundTaskStateTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/NetworkChangeDispatch.java',
    'android/app/src/test/java/com/minnnng/dsh_android/NetworkChangeDispatchTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/PackageOperationTransitions.java',
    'android/app/src/test/java/com/minnnng/dsh_android/PackageOperationTransitionsTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/RuntimeLifecycle.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RuntimeLifecycleTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/RuntimeProcessLease.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RuntimeProcessLeaseTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/RuntimeInterruptionRecord.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RuntimeInterruptionRecordTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/RuntimeTransport.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RuntimeTransportTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/ProcessSuspensionWatch.java',
    'android/app/src/test/java/com/minnnng/dsh_android/ProcessSuspensionWatchTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', join(project, 'android/app/src/main/java'), '-d', output, ...sources], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.BackgroundTaskStateTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.NetworkChangeDispatchTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.PackageOperationTransitionsTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.RuntimeLifecycleTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.RuntimeProcessLeaseTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.RuntimeInterruptionRecordTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.RuntimeTransportTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.ProcessSuspensionWatchTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-background-state-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
