import { execFileSync } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { delimiter, resolve } from 'node:path'

const platform = process.argv[2]
if (!platform?.endsWith('android.jar')) throw new Error('Pass the Android SDK android.jar path')
const output = mkdtempSync(resolve(import.meta.dirname, '../../../.cache/android/saf-control-host-'))
const source = resolve(import.meta.dirname, '../android/app/src/androidTest/java/com/minnnng/dsh_android')
execFileSync('javac', ['--release', '17', '-classpath', platform, '-d', output,
  resolve(source, 'PtcSafAcceptanceProvider.java'), resolve(source, 'PtcSafAcceptanceControlService.java'),
  resolve(source, 'PtcSafBootstrapInstrumentation.java'),
  resolve(import.meta.dirname, 'saf-control-host/PtcSafControlPolicyTest.java')],
{ stdio: 'inherit', windowsHide: true, timeout: 60_000 })
execFileSync('java', ['-cp', [output, platform].join(delimiter), 'com.minnnng.dsh_android.PtcSafControlPolicyTest'],
  { stdio: 'inherit', windowsHide: true, timeout: 20_000 })
process.stdout.write(`Compiled without main App or Kotlin dependencies: ${output}\n`)
