import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-file-cache-compile-'))
try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output,
    ...['AttachmentCopy', 'AttachmentFileCache', 'AttachmentSaveLifecycle', 'AttachmentCacheLease'].map(name =>
      join(project, `android/app/src/main/java/com/minnnng/dsh_android/${name}.java`)),
    join(project, 'android/app/src/test/java/com/minnnng/dsh_android/AttachmentFileCacheTest.java'),
    join(project, 'android/app/src/test/java/com/minnnng/dsh_android/AttachmentCacheLeaseTest.java'),
  ], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.AttachmentFileCacheTest'], {
    stdio: 'inherit', windowsHide: true,
  })
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.AttachmentCacheLeaseTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-file-cache-compile-')) {
    throw new Error('Refusing to remove a test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
