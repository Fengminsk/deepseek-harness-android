import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-binding-'))
try {
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/RuntimeBindingHandshake.java',
    'android/app/src/test/java/com/minnnng/dsh_android/RuntimeBindingHandshakeTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...sources], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.RuntimeBindingHandshakeTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-binding-')) {
    throw new Error('Refusing to remove a directory outside the allocated binding test root')
  }
  rmSync(target, { recursive: true })
}
