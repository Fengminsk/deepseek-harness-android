import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(temporaryRoot, 'isolated-approval-inbox-'))
try {
  const sourceRoot = join(project, 'android/app/src/main/java')
  const source = join(sourceRoot,
    'com/minnnng/dsh_android/IsolatedExecutionApprovalInbox.java')
  const test = join(project,
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedExecutionApprovalInboxTest.java')
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', sourceRoot,
    '-d', output, source, test], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', [`-Djava.io.tmpdir=${output}`, '-cp', output,
    'com.minnnng.dsh_android.IsolatedExecutionApprovalInboxTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('isolated-approval-inbox-')) {
    throw new Error('Refusing to remove an unrelated temporary directory')
  }
  rmSync(target, { recursive: true })
}
