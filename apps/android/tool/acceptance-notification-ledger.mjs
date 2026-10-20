import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-approval-ledger-'))
const source = join(project, 'android/app/src/main/java/com/minnnng/dsh_android/ApprovalActionLedger.java')
const test = join(project, 'android/app/src/test/java/com/minnnng/dsh_android/ApprovalActionLedgerTest.java')
try {
  execFileSync('javac', ['-d', output, source, test], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.ApprovalActionLedgerTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-approval-ledger-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
