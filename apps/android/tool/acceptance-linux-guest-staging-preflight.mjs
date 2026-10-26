import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const cache = realpathSync(join(project, '../../.cache/android'))
const classes = mkdtempSync(join(cache, 'linux-stage-preflight-'))
const sourcePath = join(project, 'android/app/src/main/java')
const test = join(project,
  'android/app/src/test/java/com/minnnng/dsh_android/LinuxGuestStagingPreflightTest.java')

try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', sourcePath,
    '-d', classes, test], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', [`-Ddsh.test.cache=${cache}`, '-cp', classes,
    'com.minnnng.dsh_android.LinuxGuestStagingPreflightTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(classes)
  if (dirname(target) !== cache || !basename(target).startsWith('linux-stage-preflight-')) {
    throw new Error('Refusing to remove an unrelated temporary directory')
  }
  rmSync(target, { recursive: true })
}
