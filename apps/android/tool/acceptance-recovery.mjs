import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-recovery-'))
function cleanup() {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-recovery-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
let failure
try {
  const classes = join(output, 'classes')
  const files = join(output, 'files')
  mkdirSync(classes)
  mkdirSync(files)
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/RecoveryFiles.java',
    'android/app/src/main/java/com/minnnng/dsh_android/RecoveryModeQueue.java',
    'android/app/src/main/java/com/minnnng/dsh_android/RecoveryProcesses.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RecoveryFilesTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RecoveryProcessesTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', classes, ...sources], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', classes, 'com.minnnng.dsh_android.RecoveryFilesTest', files], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', classes, 'com.minnnng.dsh_android.RecoveryProcessesTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} catch (error) {
  failure = error
}
try { cleanup() } catch (error) {
  if (failure !== undefined) throw new AggregateError([failure, error], 'Recovery checks and temporary-directory cleanup both failed')
  throw error
}
if (failure !== undefined) throw failure
