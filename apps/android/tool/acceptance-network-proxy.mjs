import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = fileURLToPath(new URL('../', import.meta.url))
const temporaryRoot = realpathSync(tmpdir())
const output = mkdtempSync(join(temporaryRoot, 'pocket-network-proxy-'))
try {
  const files = [
    'android/app/src/main/java/com/minnnng/dsh_android/NetworkProxyPolicy.java',
    'android/app/src/test/java/com/minnnng/dsh_android/NetworkProxyPolicyTest.java',
  ].map(path => join(project, path))
  execFileSync('javac', ['-encoding', 'UTF-8', '-d', output, ...files], { stdio: 'inherit', windowsHide: true })
  const manifest = readFileSync(join(project, 'android/app/src/main/AndroidManifest.xml'), 'utf8')
  const visiblePackages = [...manifest.matchAll(/<package\s+android:name="([^"]+)"/g)].map(match => match[1])
  execFileSync('java', ['-cp', output, 'com.minnnng.dsh_android.NetworkProxyPolicyTest', ...visiblePackages], { stdio: 'inherit', windowsHide: true })
} finally {
  const target = realpathSync(output)
  if (dirname(target) !== temporaryRoot || !basename(target).startsWith('pocket-network-proxy-')) {
    throw new Error('Refusing to remove a proxy-test directory outside its allocated temporary root')
  }
  rmSync(target, { recursive: true })
}
