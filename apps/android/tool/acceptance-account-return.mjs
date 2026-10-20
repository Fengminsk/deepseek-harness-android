import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-account-return-'))
try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output,
    join(project, 'android/app/src/main/java/com/minnnng/dsh_android/AccountReturnLink.java'),
    join(project, 'android/app/src/test/java/com/minnnng/dsh_android/AccountReturnLinkTest.java'),
  ], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.AccountReturnLinkTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-account-return-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
