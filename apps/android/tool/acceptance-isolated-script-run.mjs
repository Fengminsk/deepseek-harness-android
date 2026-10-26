import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(temporaryRoot, 'isolated-script-host-'))
try {
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/PtcScriptEngine.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerInput.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedScriptWire.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedScriptReceipt.java',
    'android/app/src/main/java/com/minnnng/dsh_android/IsolatedScriptRetirement.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedScriptWireTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedScriptReceiptTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/IsolatedScriptRetirementTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', join(project, 'android/app/src/main/java'), '-d', output, ...sources], {
    stdio: 'inherit', windowsHide: true,
  })
  for (const test of ['IsolatedScriptWireTest', 'IsolatedScriptReceiptTest', 'IsolatedScriptRetirementTest']) {
    execFileSync('java', [`-Djava.io.tmpdir=${output}`, '-cp', output, `com.minnnng.dsh_android.${test}`], {
      stdio: 'inherit', windowsHide: true,
    })
  }
  process.stdout.write('Isolated script wire and no-replay receipt host acceptance passed.\n')
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('isolated-script-host-')) {
    throw new Error('Refusing to remove an unrelated temporary directory')
  }
  rmSync(target, { recursive: true })
}
