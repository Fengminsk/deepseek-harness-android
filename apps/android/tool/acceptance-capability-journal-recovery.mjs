import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-capability-recovery-'))
try {
  const files = [
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerInput.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerTextEdit.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerTextSearch.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerWriteback.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedCapabilityBroker.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedCapabilityJournal.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedCapabilityJournalRecoveryTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', join(project, 'android/app/src/main/java'), '-d', output, ...files], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.IsolatedCapabilityJournalRecoveryTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-capability-recovery-')) {
    throw new Error('Refusing to remove a capability-test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
