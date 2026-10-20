import { LocalBashExecutor } from '@deepseek-ai/dsh-bash-local'

/** Reuse DSH process ownership, deadlines and job output with Android's available shell. */
export default class AndroidShell extends LocalBashExecutor {
  execute(spec) {
    return this.executeArgv(spec, [process.platform === 'android' ? '/system/bin/sh' : 'bash', '-c', spec.command])
  }
}
