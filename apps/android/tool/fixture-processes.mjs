import { spawn } from 'node:child_process'

/** One fixture's process allocator and shutdown gate; no process may start after close begins. */
export class FixtureProcesses {
  constructor({ closeTimeoutMs = 15000 } = {}) {
    if (!Number.isSafeInteger(closeTimeoutMs) || closeTimeoutMs < 1) throw new TypeError('Invalid fixture close timeout')
    this.closeTimeoutMs = closeTimeoutMs
    this.records = new Map()
    this.stopping = false
    this.closing = null
  }

  spawn(command, args, options) {
    if (this.stopping) throw Object.assign(new Error('Fixture shutdown has begun; no new process may start'),
      { code: 'FIXTURE_CLOSED' })
    const child = spawn(command, args, options)
    const record = { ended: false, closed: null, error: undefined }
    // Install ownership synchronously after spawn, before any child event can run.
    record.closed = new Promise(resolve => {
      child.once('error', error => { record.error = error })
      child.once('close', (code, signal) => {
        record.ended = true
        resolve({ code, signal, ...(record.error === undefined ? {} : { error: record.error }) })
      })
    })
    this.records.set(child, record)
    return child
  }

  /** Stop one generation without closing the allocator needed by a deliberate restart. */
  async stop(child) {
    const record = this.records.get(child)
    if (!record) throw new Error('Cannot stop a process owned by another fixture')
    if (!record.ended) child.kill('SIGKILL')
    let timer
    try {
      return await Promise.race([
        record.closed,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(`Fixture process ${child.pid ?? 'unstarted'} did not close after SIGKILL`)),
            this.closeTimeoutMs)
        }),
      ])
    } finally { clearTimeout(timer) }
  }

  close() {
    // The gate must close synchronously before capturing ownership or awaiting exit.
    this.stopping = true
    this.closing ??= this.drain()
    return this.closing
  }

  async drain() {
    const results = await Promise.allSettled([...this.records.keys()].map(child => this.stop(child)))
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
    if (errors.length) throw new AggregateError(errors, 'Fixture process cleanup did not reach quiescence')
  }
}
