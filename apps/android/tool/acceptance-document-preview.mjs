import { execFileSync } from 'node:child_process'
import { readFileSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import assert from 'node:assert/strict'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-document-policy-'))
try {
  const native = readFileSync(join(project, 'android/app/src/main/kotlin/com/minnnng/dsh_android/DocumentPreview.kt'), 'utf8')
  assert.match(native, /if \(!DocumentPreviewPolicy\.asset\(request\.url\.toString\(\)\)\) return denied\(\)/,
    'the document WebView must continue to deny every non-packaged resource')
  const sources = [
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentPreviewPolicy.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentPreviewPolicyTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentPreviewMediaPolicy.java',
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentPreviewMediaStream.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentPreviewMediaPolicyTest.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentPreviewMediaStreamTest.java',
    'android/app/src/main/java/com/minnnng/dsh_android/DocumentRemoteResourcePolicy.java',
    'android/app/src/test/java/com/minnnng/dsh_android/DocumentRemoteResourcePolicyTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', join(project, 'android/app/src/main/java'), '-d', output, ...sources], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentPreviewPolicyTest'], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentPreviewMediaPolicyTest'], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentPreviewMediaStreamTest'], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.DocumentRemoteResourcePolicyTest'], { stdio: 'inherit', windowsHide: true })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-document-policy-')) {
    throw new Error('Refusing to remove a directory outside the allocated document test root')
  }
  rmSync(target, { recursive: true })
}
