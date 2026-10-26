import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-documents-'))
const source = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/DocumentReadAccess.java')
const test = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentReadAccessTest.java')
const revision = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/DocumentRevision.java')
const revisionTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentRevisionTest.java')
const snapshot = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/DocumentSnapshotStore.java')
const snapshotTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentSnapshotStoreTest.java')
const traversal = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/DocumentTraversalBudget.java')
const traversalTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentTraversalBudgetTest.java')
const columns = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/DocumentColumns.java')
const columnsTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentColumnsTest.java')
const binary = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/DocumentBinaryReadAccess.java')
const binaryTest = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentBinaryReadAccessTest.java')
try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', join(project, 'android/app/src/main/java'), '-d', output, source, test, revision, revisionTest, snapshot, snapshotTest, traversal, traversalTest, columns, columnsTest, binary, binaryTest], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentReadAccessTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentRevisionTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentSnapshotStoreTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentTraversalBudgetTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentColumnsTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentBinaryReadAccessTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-documents-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
