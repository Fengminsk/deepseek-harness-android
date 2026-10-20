import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-document-search-'))
try {
  const java = 'android/app/src/main/java/com/minnnng/dsh_android'
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output,
    join(project, java, 'DocumentTextSearch.java'), join(project, java, 'DocumentSearchJob.java'),
    join(project, 'android/app/src/test/java/com/minnnng/dsh_android/DocumentTextSearchTest.java')],
  { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentTextSearchTest'],
    { stdio: 'inherit', windowsHide: true })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-document-search-')) {
    throw new Error('Refusing cleanup outside allocated search test directory')
  }
  rmSync(target, { recursive: true })
}
