import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-external-file-'))
try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output,
    join(project, 'android/app/src/main/java/com/minnnng/dsh_android/ExternalFilePolicy.java'),
    join(project, 'android/app/src/main/java/com/minnnng/dsh_android/ExternalStageCache.java'),
    join(project, 'android/app/src/test/java/com/minnnng/dsh_android/ExternalFilePolicyTest.java'),
    join(project, 'android/app/src/test/java/com/minnnng/dsh_android/ExternalStageCacheTest.java')],
  { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.ExternalFilePolicyTest'],
    { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.ExternalStageCacheTest'],
    { stdio: 'inherit', windowsHide: true })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-external-file-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
