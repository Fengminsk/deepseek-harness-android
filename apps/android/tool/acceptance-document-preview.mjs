import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-document-policy-'))
try {
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentPreviewPolicy.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentPreviewPolicyTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentPreviewMediaPolicy.java',
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentPreviewMediaStream.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentPreviewMediaPolicyTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentPreviewMediaStreamTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...sources], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentPreviewPolicyTest'], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentPreviewMediaPolicyTest'], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentPreviewMediaStreamTest'], { stdio: 'inherit', windowsHide: true })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-document-policy-')) {
    throw new Error('Refusing to remove a directory outside the allocated document test root')
  }
  rmSync(target, { recursive: true })
}
