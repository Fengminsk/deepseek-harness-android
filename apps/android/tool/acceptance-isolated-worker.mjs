import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Pure-Java admission checks for the descriptor boundary. Android UID and
// Binder behavior require device evidence and are not represented by this run.
const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-isolated-worker-'))
try {
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerInput.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerWriteback.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedWorkerInputTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedWorkerWritebackTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...sources], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.IsolatedWorkerInputTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', [`-Djava.io.tmpdir=${output}`, '-cp', output, 'com.minnnng.dsh_android.IsolatedWorkerWritebackTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-isolated-worker-')) {
    throw new Error('Refusing to remove an isolated-worker test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
