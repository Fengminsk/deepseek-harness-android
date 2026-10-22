import { spawn } from 'node:child_process'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { posix } from 'node:path'

function shellInvocation(command) {
  if (process.platform !== 'android') return { executable: '/bin/sh', args: ['-c', command] }
  const nativeDirectory = process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR
  if (typeof nativeDirectory !== 'string' || !posix.isAbsolute(nativeDirectory)) {
    throw new Error('Android Shell supervisor directory is unavailable')
  }
  return { executable: posix.join(nativeDirectory, 'libpocket_shell_supervisor.so'),
    args: [String(process.pid), '/system/bin/sh', '-c', command] }
}

/**
 * kill(-pgid, SIGKILL) also succeeds for an unreaped zombie-only group. Inspect
 * live members before interpreting that syscall as a timeout termination.
 * Unreadable same-UID rows remain unknown; an app cannot signal other UIDs.
 */
function groupState(pid) {
  if (process.platform !== 'android' && process.platform !== 'linux') return 'unknown'
  let entries
  try { entries = readdirSync('/proc') } catch { return 'unknown' }
  let matched = false, incomplete = false
  const uid = process.getuid?.()
  for (const entry of entries) {
    if (!/^\d+$/.test(entry)) continue
    let raw
    try { raw = readFileSync(`/proc/${entry}/stat`, 'utf8') } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ESRCH') continue
      // Android hides other apps' process details. Their unreadable rows must
      // not invalidate observation of this ordinary app-UID command's group.
      try {
        if (uid !== undefined && uid !== 0 && statSync(`/proc/${entry}`).uid !== uid) continue
      } catch { /* The row's ownership is unknown too. */ }
      incomplete = true
      continue
    }
    const close = raw.lastIndexOf(')')
    const fields = close < 0 ? [] : raw.slice(close + 1).trim().split(/\s+/)
    if (fields[0]?.length !== 1 || !/^\d+$/.test(fields[2] ?? '')) {
      incomplete = true
      continue
    }
    if (Number(fields[2]) !== pid) continue
    matched = true
    if (!/^[ZXx]$/.test(fields[0])) return 'live'
  }
  return matched && !incomplete ? 'quiescent' : 'unknown'
}

/**
 * Non-interactive app-UID shell. Android requires a native supervisor before
 * execution; cancellation, deadline and Node process death terminate its
 * detached process group. A command which creates a new session can escape
 * that group, and a process group is not a filesystem or permission sandbox.
 */
export function runShell(command, cwd, { timeoutMs = 60000, outputLimit = 65536, signal } = {}) {
  if (typeof command !== 'string' || command.length === 0) throw new TypeError('command must be non-empty')
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 3600000) throw new TypeError('Invalid timeout')
  if (!Number.isInteger(outputLimit) || outputLimit < 1024 || outputLimit > 1048576) throw new TypeError('Invalid output limit')
  const { executable, args } = shellInvocation(command)
  const android = process.platform === 'android'
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe', ...(android ? ['pipe'] : [])],
      env: Object.fromEntries(Object.entries(process.env).filter(([name]) => !/KEY|SECRET|TOKEN|PASSWORD/i.test(name))),
    })
    let stdout = Buffer.alloc(0), stderr = Buffer.alloc(0)
    let truncated = false, settled = false, stopReason, stopResult
    let supervisorReady = !android, startup = '', supervisorInvalid = false
    const stop = () => {
      if (child.pid === undefined) return { state: 'absent' }
      const observed = groupState(child.pid)
      if (observed === 'quiescent') return { state: 'absent' }
      try {
        process.kill(-child.pid, 'SIGKILL')
        return observed === 'live' ? { state: 'signalled' }
          : { state: 'unconfirmed', sent: true, code: 'GROUP_LIVENESS_UNCONFIRMED' }
      } catch (error) {
        if (error.code === 'ESRCH') return { state: 'absent' }
        // Retain the original direct-child fallback without claiming it
        // terminated descendants when the group signal was refused.
        try {
          const sent = child.kill('SIGKILL')
          return { state: 'unconfirmed', sent, code: sent
            ? 'GROUP_SIGNAL_FAILED_CHILD_SIGNALLED' : 'GROUP_SIGNAL_FAILED' }
        } catch { return { state: 'unconfirmed', code: 'GROUP_SIGNAL_FAILED' } }
      }
    }
    const requestStop = reason => {
      if (settled || stopReason !== undefined) return
      stopReason = reason
      clearTimeout(timer)
      stopResult = stop()
    }
    const abort = () => requestStop('cancelled')
    const timer = setTimeout(() => requestStop('timeout'), timeoutMs)
    const collect = (target, chunk) => {
      const remaining = Math.max(0, outputLimit - target.length)
      if (chunk.length > remaining) truncated = true
      return Buffer.concat([target, chunk.subarray(0, remaining)])
    }
    child.stdout.on('data', chunk => { stdout = collect(stdout, chunk) })
    child.stderr.on('data', chunk => { stderr = collect(stderr, chunk) })
    if (android) {
      const acknowledgement = child.stdio?.[3]
      if (!acknowledgement) {
        supervisorInvalid = true
        requestStop('infrastructure')
      } else acknowledgement.on('data', chunk => {
        startup += chunk.toString('utf8')
        if (startup === 'S\n') supervisorReady = true
        else if (!'S\n'.startsWith(startup) || startup.length > 2) {
          supervisorInvalid = true
          requestStop('infrastructure')
        }
      })
    }
    signal?.addEventListener('abort', abort, { once: true })
    if (signal?.aborted) abort()
    const cleanup = () => { clearTimeout(timer); signal?.removeEventListener('abort', abort) }
    child.once('error', error => {
      if (settled) return
      settled = true
      cleanup()
      reject(error)
    })
    child.once('close', (exitCode, exitSignal) => {
      if (settled) return
      settled = true
      cleanup()
      if (!supervisorReady || supervisorInvalid) {
        const error = new Error('Android Shell supervisor failed to confirm process ownership')
        error.code = 'SHELL_SUPERVISOR_UNAVAILABLE'
        reject(error)
        return
      }
      // Keep the deadline until close: a shell can exit successfully while a
      // descendant still holds its output pipes. Exit code 0 alone therefore
      // cannot disprove timeout termination of the remaining process group.
      const timedOut = stopReason !== 'timeout' || stopResult?.state === 'absent' ? false
        : stopResult?.state === 'signalled' || (stopResult?.sent && exitSignal === 'SIGKILL') ? true : null
      resolve({ stdout: stdout.toString('utf8'), stderr: stderr.toString('utf8'), exitCode, signal: exitSignal,
        timedOut, cancelled: stopReason === 'cancelled', truncated,
        ...(timedOut === null ? { timeoutStatus: 'unconfirmed',
          timeoutDiagnostic: stopResult?.code ?? 'GROUP_LIVENESS_UNCONFIRMED' } : {}),
        ...(stopResult?.code?.startsWith('GROUP_SIGNAL_FAILED') ? { terminationDiagnostic: stopResult.code } : {}),
      })
    })
  })
}
