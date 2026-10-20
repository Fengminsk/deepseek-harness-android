import { spawn } from 'node:child_process'

/** Non-interactive app-UID shell; cancellation also terminates its process group. */
export function runShell(command, cwd, { timeoutMs = 60000, outputLimit = 65536, signal } = {}) {
  if (typeof command !== 'string' || command.length === 0) throw new TypeError('command must be non-empty')
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 3600000) throw new TypeError('Invalid timeout')
  if (!Number.isInteger(outputLimit) || outputLimit < 1024 || outputLimit > 1048576) throw new TypeError('Invalid output limit')
  return new Promise((resolve, reject) => {
    const child = spawn(process.platform === 'android' ? '/system/bin/sh' : '/bin/sh', ['-c', command], {
      cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: Object.fromEntries(Object.entries(process.env).filter(([name]) => !/KEY|SECRET|TOKEN|PASSWORD/i.test(name))),
    })
    let stdout = Buffer.alloc(0), stderr = Buffer.alloc(0)
    let truncated = false, timedOut = false, cancelled = false
    const stop = () => {
      if (child.pid !== undefined) {
        try { process.kill(-child.pid, 'SIGKILL') } catch (error) { if (error.code !== 'ESRCH') child.kill('SIGKILL') }
      }
    }
    const abort = () => { cancelled = true; stop() }
    const timer = setTimeout(() => { timedOut = true; stop() }, timeoutMs)
    const collect = (target, chunk) => {
      const remaining = Math.max(0, outputLimit - target.length)
      if (chunk.length > remaining) truncated = true
      return Buffer.concat([target, chunk.subarray(0, remaining)])
    }
    child.stdout.on('data', chunk => { stdout = collect(stdout, chunk) })
    child.stderr.on('data', chunk => { stderr = collect(stderr, chunk) })
    signal?.addEventListener('abort', abort, { once: true })
    if (signal?.aborted) abort()
    const cleanup = () => { clearTimeout(timer); signal?.removeEventListener('abort', abort) }
    child.once('error', error => { cleanup(); reject(error) })
    child.once('close', (exitCode, exitSignal) => {
      cleanup()
      resolve({ stdout: stdout.toString('utf8'), stderr: stderr.toString('utf8'), exitCode, signal: exitSignal,
        timedOut, cancelled, truncated })
    })
  })
}
