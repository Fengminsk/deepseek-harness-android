import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repository = fileURLToPath(new URL('../../../', import.meta.url))
const project = join(repository, 'apps/android')
const cache = join(repository, '.cache/android/linux-vm-recovery-tests')
mkdirSync(cache, { recursive: true })
const output = mkdtempSync(join(cache, 'classes-'))
const mainSources = join(project, 'android/app/src/main/java')
execFileSync('javac', ['-encoding', 'UTF-8', '-sourcepath', mainSources, '-d', output,
  join(mainSources, 'com/minnnng/dsh_android/LinuxVmRecoveryStore.java'),
  join(mainSources, 'com/minnnng/dsh_android/LinuxVmBlockStore.java'),
  join(project, 'android/app/src/test/java/com/minnnng/dsh_android/LinuxVmRecoveryStoreTest.java'),
], { cwd: repository, stdio: 'inherit', windowsHide: true })
execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.LinuxVmRecoveryStoreTest'], {
  cwd: repository, stdio: 'inherit', windowsHide: true,
})
