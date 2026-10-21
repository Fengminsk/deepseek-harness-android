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
    'android/app/src/main/java/com/minnnng/dsh_android/PackageOperationTransitions.java',
    'android/app/src/test/java/com/minnnng/dsh_android/PackageOperationTransitionsTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...sources], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.BackgroundTaskStateTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.PackageOperationTransitionsTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-background-state-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
