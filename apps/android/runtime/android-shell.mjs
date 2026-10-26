import { LocalBashExecutor } from '@deepseek-ai/dsh-bash-local'
import { requireSupportedShellExecution } from './shell-execution-policy.mjs'

/** Retain the legacy App-UID executor for explicit diagnostics; default policy refuses execution. */
export default class AndroidShell extends LocalBashExecutor {
  execute(spec) {
    requireSupportedShellExecution('app-uid-approved')
    return this.executeArgv(spec, [process.platform === 'android' ? '/system/bin/sh' : 'bash', '-c', spec.command])
  }
}
