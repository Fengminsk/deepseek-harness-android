import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(temporaryRoot, 'isolated-approval-host-'))
try {
  const sourceRoot = join(project, 'android/app/src/main/java')
  const source = join(sourceRoot, 'com/minnnng/dsh_android/IsolatedExecutionApprovalStore.java')
  const test = join(project,
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedExecutionApprovalStoreTest.java')
  const coldRecovery = join(project,
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedExecutionColdRecoveryTest.java')
  const approvedScope = join(project,
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedApprovedRunScope.java')
  const approvedScopeTest = join(project,
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedApprovedRunScopeTest.java')
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', sourceRoot,
    '-d', output, source, test, coldRecovery, approvedScope, approvedScopeTest],
  { stdio: 'inherit', windowsHide: true })
  for (const name of ['IsolatedApprovedRunScopeTest', 'IsolatedExecutionApprovalStoreTest',
    'IsolatedExecutionColdRecoveryTest']) {
    execFileSync('java', [`-Djava.io.tmpdir=${output}`, '-cp', output,
      `com.minnnng.dsh_android.${name}`], { stdio: 'inherit', windowsHide: true })
  }
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('isolated-approval-host-')) {
    throw new Error('Refusing to remove an unrelated temporary directory')
  }
  rmSync(target, { recursive: true })
}
