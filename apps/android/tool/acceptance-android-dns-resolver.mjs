import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-dns-resolver-'))
try {
  const files = [
    'android/app/src/main/java/com/minnnng/dsh_android/DeadlineDnsQuery.java',
    'android/app/src/main/java/com/minnnng/dsh_android/DeadlineNetworkGate.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DeadlineDnsQueryTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...files], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DeadlineDnsQueryTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-dns-resolver-')) {
    throw new Error('Refusing to remove a DNS-test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
