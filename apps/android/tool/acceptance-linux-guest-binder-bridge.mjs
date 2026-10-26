import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const cache = realpathSync(join(project, '../../.cache/android'))
const output = mkdtempSync(join(cache, 'linux-binder-bridge-'))
const mainSources = join(project, 'android/app/src/main/java')
const test = join(project,
  'android/app/src/test/java/com/minnnng/dsh_android/LinuxGuestBinderBridgeTest.java')

try {
  execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', mainSources,
    '-d', output, test], { stdio: 'inherit', windowsHide: true })
  execFileSync('java', [`-Ddsh.test.cache=${cache}`, '-cp', output,
    'com.minnnng.dsh_android.LinuxGuestBinderBridgeTest'], {
    stdio: 'inherit', windowsHide: true,
  })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== cache || !basename(target).startsWith('linux-binder-bridge-')) {
    throw new Error('Refusing to remove an unrelated temporary directory')
  }
  rmSync(target, { recursive: true })
}
