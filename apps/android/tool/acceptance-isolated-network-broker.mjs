import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-network-broker-'))
try {
  const sourceRoot = join(project, 'android/app/src/main/java')
  const files = [
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedNetworkJournal.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedNetworkBroker.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedNetworkJournalTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedNetworkBrokerTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', sourceRoot,
    '-d', output, ...files], {
    stdio: 'inherit', windowsHide: true,
  })
  for (const test of ['IsolatedNetworkJournalTest', 'IsolatedNetworkBrokerTest']) {
    execFileSync('java', [`-Djava.io.tmpdir=${output}`, '-cp', output,
      `com.minnnng.dsh_android.${test}`], {
      stdio: 'inherit', windowsHide: true,
    })
  }
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-network-broker-')) {
    throw new Error('Refusing to remove a network-test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
