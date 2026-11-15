import { spawn as nodeSpawn } from 'node:child_process'
import { constants as fsConstants } from 'node:fs'
import { access } from 'node:fs/promises'
import { join } from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const MAX_TERMINALS = 8
const MAX_INPUT_BYTES = 65536
const MAX_PENDING_OUTPUT_BYTES = 262144
const MAX_PENDING_TERMINAL_REPLY_BYTES = 32768
const MAX_VIEW_LINES = 500
const MAX_VIEW_CELLS = 100000
const MAX_VIEW_RUNS = 10000
const START_TIMEOUT_MS = 3000
const CLOSE_TIMEOUT_MS = 3000
const WORKDIR_TIMEOUT_MS = 8000
const SHELL_DISCOVERY_TIMEOUT_MS = 5000
const SYSTEM_SHELLS = Object.freeze([
  Object.freeze({ id: 'system-sh', label: '系统 Shell', path: '/system/bin/sh' }),
  Object.freeze({ id: 'system-mksh', label: 'mksh', path: '/system/bin/mksh' }),
  Object.freeze({ id: 'system-bash', label: 'Bash', path: '/system/bin/bash' }),
])

async function executableShell(path) { await access(path, fsConstants.X_OK) }

function identity(value, label) {
  if (typeof value !== 'string' || !/^[\w-]{1,128}$/.test(value)) {
    throw new TypeError(`Invalid ${label}`)
  }
  return value
}

function terminalName(value) {
  const graphemes = typeof value === 'string'
    ? [...new Intl.Segmenter('und', { granularity: 'grapheme' }).segment(value)].length : 0
  if (typeof value !== 'string' || value !== value.trim()
    || !value || graphemes > 64
    || /[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/u.test(value)) {
    throw new TypeError('Terminal name must be 1–64 visible characters')
  }
  return value
}

function dimensions(cols, rows) {
  if (!Number.isSafeInteger(cols) || cols < 2 || cols > 500
    || !Number.isSafeInteger(rows) || rows < 1 || rows > 200) {
    throw new TypeError('Invalid terminal dimensions')
  }
}

function scrubbedEnvironment(sessionId) {
  const allowed = ['PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'HOME', 'USER']
  return { ...Object.fromEntries(allowed.filter(key => process.env[key] !== undefined)
    .map(key => [key, process.env[key]])), TERM: 'xterm-256color', DSH_SESSION_ID: sessionId }
}

function helperPath() {
  const directory = process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR
  if (process.platform !== 'android' || typeof directory !== 'string' || !directory) {
    throw new Error('Android PTY helper is unavailable in this runtime')
  }
  return join(directory, 'libpocket_terminal_helper.so')
}

// 桌面终端适配器复用同一套 headless xterm 投影，保证远程与本地 `terminal.read` 的形状一致。
export function screenFactory(cols, rows) {
  const { Terminal } = require('@xterm/headless')
  const { SerializeAddon } = require('@xterm/addon-serialize')
  const screen = new Terminal({ cols, rows, scrollback: 500, allowProposedApi: true })
  const serializer = new SerializeAddon()
  screen.loadAddon(serializer)
  return { screen, serializer }
}

// Observe program display controls without consuming xterm's own parser handlers.
// This state belongs to the PTY, so a detached and reopened Flutter page sees
// the same palette and cursor mode as the running program.
export function observeTerminalDisplay(screen) {
  const indexed = new Map()
  const special = new Map()
  const subscriptions = []
  let cursorVisible = true
  let cursorStyle = 'block'
  let cursorBlink = true
  let applicationCursorKeys = false
  let bracketedPaste = false
  const mouseModes = new Set()
  let sgrMouse = false

  const index = value => /^\d{1,3}$/.test(value) && Number(value) < 256 ? Number(value) : null
  const color = value => {
    const rgb = /^rgb:([\da-f]{1,4})\/([\da-f]{1,4})\/([\da-f]{1,4})$/i.exec(value)
    let channels
    if (rgb) {
      channels = rgb.slice(1)
      if (!channels.every(channel => channel.length === channels[0].length)) return null
    } else {
      if (!/^#(?:[\da-f]{3}){1,4}$/i.test(value)) return null
      const width = (value.length - 1) / 3
      channels = [value.slice(1, width + 1), value.slice(width + 1, 2 * width + 1), value.slice(2 * width + 1)]
    }
    return `#${channels.map(channel => {
      const value = Math.round(Number.parseInt(channel, 16) * 255 / (16 ** channel.length - 1))
      return value.toString(16).padStart(2, '0')
    }).join('')}`
  }
  const replyColor = (code, prefix, value) => {
    if (!value) return false
    const rgb = value.slice(1).match(/../g).map(channel => `${channel}${channel}`).join('/')
    screen.input(`\x1b]${code};${prefix}rgb:${rgb}\x07`)
    return true
  }
  const observeOsc = (code, handler) => subscriptions.push(screen.parser.registerOscHandler(code,
    data => data.length <= 4096 && handler(data) === true))
  observeOsc(4, data => {
    const parts = data.split(';')
    let answered = false
    for (let i = 0; i + 1 < parts.length; i += 2) {
      const key = index(parts[i])
      if (key !== null && parts[i + 1] === '?') {
        answered = replyColor(4, `${key};`, indexed.get(key)) || answered
        continue
      }
      const value = color(parts[i + 1])
      if (key !== null && value !== null) indexed.set(key, value)
    }
    return answered
  })
  observeOsc(104, data => {
    if (data === '') indexed.clear()
    else for (const part of data.split(';')) {
      const key = index(part)
      if (key !== null) indexed.delete(key)
    }
  })
  for (const [offset, key] of ['foreground', 'background', 'cursor'].entries()) {
    observeOsc(10 + offset, data => {
      let answered = false
      for (const [partOffset, part] of data.split(';').entries()) {
        const target = ['foreground', 'background', 'cursor'][offset + partOffset]
        if (target && part === '?') {
          answered = replyColor(10 + offset + partOffset, '', special.get(target)) || answered
          continue
        }
        const value = color(part)
        if (target && value !== null) special.set(target, value)
      }
      return answered
    })
    observeOsc(110 + offset, () => special.delete(key))
  }
  const observeCsi = (id, handler) => subscriptions.push(screen.parser.registerCsiHandler(id,
    params => { handler(params); return false }))
  observeCsi({ prefix: '?', final: 'h' }, params => {
    if (params.includes(25)) cursorVisible = true
    if (params.includes(1)) applicationCursorKeys = true
    if (params.includes(2004)) bracketedPaste = true
    for (const mode of [1000, 1002, 1003]) if (params.includes(mode)) mouseModes.add(mode)
    if (params.includes(1006)) sgrMouse = true
  })
  observeCsi({ prefix: '?', final: 'l' }, params => {
    if (params.includes(25)) cursorVisible = false
    if (params.includes(1)) applicationCursorKeys = false
    if (params.includes(2004)) bracketedPaste = false
    for (const mode of [1000, 1002, 1003]) if (params.includes(mode)) mouseModes.delete(mode)
    if (params.includes(1006)) sgrMouse = false
  })
  observeCsi({ intermediates: ' ', final: 'q' }, params => {
    if (params.length !== 1 || !Number.isInteger(params[0])) return
    switch (params[0]) {
      case 0: case 1: cursorStyle = 'block'; cursorBlink = true; break
      case 2: cursorStyle = 'block'; cursorBlink = false; break
      case 3: cursorStyle = 'underline'; cursorBlink = true; break
      case 4: cursorStyle = 'underline'; cursorBlink = false; break
      case 5: cursorStyle = 'bar'; cursorBlink = true; break
      case 6: cursorStyle = 'bar'; cursorBlink = false; break
    }
  })
  subscriptions.push(screen.parser.registerEscHandler({ final: 'c' }, () => {
    indexed.clear(); special.clear()
    cursorVisible = true; cursorStyle = 'block'; cursorBlink = true
    applicationCursorKeys = false; bracketedPaste = false
    mouseModes.clear(); sgrMouse = false
    return false
  }))
  return {
    snapshot() {
      return {
        palette: { indexed: Object.fromEntries(indexed), ...Object.fromEntries(special) },
        cursorVisible, cursorStyle, cursorBlink, applicationCursorKeys, bracketedPaste,
        mouseTracking: mouseModes.has(1003) ? 'any' : mouseModes.has(1002) ? 'drag'
          : mouseModes.has(1000) ? 'click' : 'off',
        sgrMouse,
      }
    },
    dispose() { for (const subscription of subscriptions) subscription.dispose() },
  }
}

function cellColor(cell, foreground) {
  const rgb = foreground ? cell.isFgRGB() : cell.isBgRGB()
  const palette = foreground ? cell.isFgPalette() : cell.isBgPalette()
  if (rgb) return `#${(foreground ? cell.getFgColor() : cell.getBgColor()).toString(16).padStart(6, '0')}`
  if (palette) return foreground ? cell.getFgColor() : cell.getBgColor()
  return null
}

/** Project the active xterm grid into bounded styled rows without exposing raw VT controls. */
export function projectTerminalView(screen, displayState) {
  const buffer = screen.buffer?.active
  if (!buffer) return null
  const display = displayState?.snapshot()
  const cols = screen.cols
  const rows = screen.rows
  const count = Math.min(buffer.length, MAX_VIEW_LINES,
    Math.max(rows, Math.floor(MAX_VIEW_CELLS / cols)))
  const start = Math.max(0, buffer.length - count)
  const cursor = { col: buffer.cursorX, row: buffer.baseY + buffer.cursorY - start }
  const lines = []
  let runCount = 0
  let stylesTruncated = false
  for (let y = start; y < buffer.length; y++) {
    const line = buffer.getLine(y)
    const runs = []
    let cursorCell = Math.min(cursor.col, cols - 1)
    if (y - start === cursor.row) {
      while (cursorCell > 0 && line?.getCell(cursorCell)?.getWidth() === 0) cursorCell--
    }
    let last = -1
    for (let x = 0; x < cols; x++) {
      const cell = line?.getCell(x)
      if (cell && cell.getWidth() > 0 && (cell.getChars() || !cell.isAttributeDefault()
        || (y - start === cursor.row && x === cursorCell))) last = x
    }
    for (let x = 0; x <= last; x++) {
      const cell = line?.getCell(x)
      if (!cell || cell.getWidth() === 0) continue
      let style = {
        fg: cellColor(cell, true), bg: cellColor(cell, false),
        bold: Boolean(cell.isBold()), dim: Boolean(cell.isDim()),
        inverse: Boolean(cell.isInverse()), underline: Boolean(cell.isUnderline()),
        invisible: Boolean(cell.isInvisible()),
        cursor: (display?.cursorVisible ?? true)
          && y - start === cursor.row && x === cursorCell,
      }
      if (runCount >= MAX_VIEW_RUNS && !style.cursor) {
        style = { fg: null, bg: null, bold: false, dim: false, inverse: false,
          underline: false, invisible: false, cursor: false }
        stylesTruncated = true
      }
      const text = cell.getChars() || ' '
      const previous = runs.at(-1)
      if (previous && Object.keys(style).every(key => previous[key] === style[key])) {
        previous.text += text
      } else {
        runs.push({ text, ...style })
        runCount++
      }
    }
    lines.push({ wrapped: Boolean(line?.isWrapped), runs })
  }
  return { cols, rows, start, cursor, lines, truncated: start > 0, stylesTruncated,
    ...(display ?? {}) }
}

/** One Host-generation PTY with a bounded recoverable screen; no transcript writes. */
class TerminalProcess {
  constructor({ id, sessionId, cwd, cols, rows, shell, spawn, helper, makeScreen, closeTimeoutMs }) {
    this.id = id
    this.sessionId = sessionId
    this.cwd = cwd
    this.shellId = shell.id
    this.name = '终端'
    this.cols = cols
    this.rows = rows
    this.closeTimeoutMs = closeTimeoutMs
    this.state = 'starting'
    this.exitCode = null
    this.revision = 0
    const { screen, serializer } = makeScreen(cols, rows)
    this.screen = screen
    this.serializer = serializer
    this.displayState = screen.parser ? observeTerminalDisplay(screen) : null
    this.child = spawn(helper, [cwd, String(cols), String(rows), shell.path], {
      cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'],
      env: scrubbedEnvironment(sessionId),
    })
    this._writes = Promise.resolve()
    this._pendingOutputBytes = 0
    this._control = Promise.resolve()
    this._ackBuffer = ''
    this._acks = []
    this._decoder = new TextDecoder()
    this._started = Promise.withResolvers()
    this._finished = Promise.withResolvers()
    this._started.promise.catch(() => {})
    this._pendingTerminalReplyBytes = 0
    this._terminalReplySubscription = this.screen.onData?.(reply => {
      const bytes = Buffer.byteLength(reply, 'utf8')
      if (bytes > 4096 || this._pendingTerminalReplyBytes + bytes > MAX_PENDING_TERMINAL_REPLY_BYTES) {
        this._fatal(new Error('PTY terminal response backlog exceeded its limit'))
        return
      }
      this._pendingTerminalReplyBytes += bytes
      void this._started.promise.then(() => this.write(reply)).catch(() => {}).finally(() => {
        this._pendingTerminalReplyBytes -= bytes
      })
    })
    this._startTimer = setTimeout(() => this._started.reject(new Error('PTY startup acknowledgement timed out')),
      START_TIMEOUT_MS)
    this.child.stdout.on('data', chunk => {
      this.child.stdout.pause()
      if (this.state === 'failed' || this.state === 'exited') return
      if (this._pendingOutputBytes + chunk.length > MAX_PENDING_OUTPUT_BYTES) {
        this._fatal(new Error('PTY output backlog exceeded the 256 KiB limit'))
        return
      }
      const text = this._decoder.decode(chunk, { stream: true })
      this._append(text, chunk.length, true)
    })
    this.child.stdout.once('end', () => this._append(this._decoder.decode()))
    this.child.stdio[4].on('data', chunk => this._receiveAcks(chunk))
    this.child.stderr.on('data', chunk => {
      const message = String(chunk).slice(0, 512)
      if (this.state === 'starting') this.error = message
    })
    this.child.once('error', error => {
      this.state = 'failed'
      this.error = error.message
      clearTimeout(this._startTimer)
      this._started.reject(error)
      this._rejectAcks(error)
    })
    this.child.once('close', (code, signal) => {
      this._processClosed = true
      clearTimeout(this._startTimer)
      this.exitCode = code
      this.state = this.state === 'failed' ? 'failed' : 'exited'
      this.exitSignal = signal
      this.revision++
      this._started.reject(new Error(this.error || 'PTY exited before startup'))
      this._rejectAcks(new Error('Terminal process exited'))
      this._finished.resolve()
    })
  }

  _append(text, bytes = 0, resume = false) {
    this._pendingOutputBytes += bytes
    this._writes = this._writes.then(() => text ? new Promise((resolve, reject) => {
      try { this.screen.write(text, () => { this.revision++; resolve() }) }
      catch (error) { reject(error) }
    }) : undefined).catch(error => this._fatal(error)).finally(() => {
      this._pendingOutputBytes -= bytes
      if (resume && this.state !== 'failed' && this.state !== 'exited') this.child.stdout.resume()
    })
  }

  _receiveAcks(bytes) {
    this._ackBuffer += String(bytes)
    if (this._ackBuffer.length > 4096) {
      this._fatal(new Error('Invalid PTY control response'))
      return
    }
    for (;;) {
      const end = this._ackBuffer.indexOf('\n')
      if (end < 0) return
      const line = this._ackBuffer.slice(0, end)
      this._ackBuffer = this._ackBuffer.slice(end + 1)
      if (line.startsWith('S') && /^[1-9]\d*$/.test(line.slice(1)) && this.state === 'starting') {
        this.shellPid = Number(line.slice(1))
        this.state = 'running'
        this.revision++
        clearTimeout(this._startTimer)
        this._started.resolve()
      } else if (/^[RW][01]$/.test(line)) {
        const ack = this._acks.shift()
        if (!ack || ack.type !== line[0]) {
          this._fatal(new Error('PTY control acknowledgement changed order'))
          return
        }
        if (line[1] === '0') ack.resolve()
        else ack.reject(new Error(`Terminal ${ack.type === 'R' ? 'resize' : 'input'} refused`))
      } else {
        this._fatal(new Error('Invalid PTY control response'))
      }
    }
  }

  _rejectAcks(error) {
    for (const ack of this._acks.splice(0)) ack.reject(error)
  }

  _fatal(error) {
    if (this.state === 'failed' || this.state === 'exited') return
    this.state = 'failed'
    this.error = error.message
    clearTimeout(this._startTimer)
    this._started.reject(error)
    this._rejectAcks(error)
    this.child.stdout.pause()
    this._termSent = true
    this.child.kill('SIGTERM')
  }

  async started() { await this._started.promise }

  info() {
    return { id: this.id, sessionId: this.sessionId, cwd: this.cwd, name: this.name,
      shellId: this.shellId,
      cols: this.cols, rows: this.rows, state: this.state, exitCode: this.exitCode,
      ...(this.error ? { error: this.error } : {}) }
  }

  async read() {
    await this._writes
    const buffer = this.screen.buffer?.active
    const visible = buffer ? Array.from({ length: Math.min(buffer.length, MAX_VIEW_LINES) }, (_, offset) => {
      const line = buffer.getLine(Math.max(0, buffer.length - MAX_VIEW_LINES) + offset)
      return line?.translateToString(true) ?? ''
    }).join('\n').replace(/\n+$/, '') : null
    return { ...this.info(), revision: this.revision,
      screen: this.serializer.serialize(), ...(visible === null ? {} : { display: visible }),
      ...(buffer ? { view: projectTerminalView(this.screen, this.displayState) } : {}) }
  }

  async write(data) {
    if (typeof data !== 'string' || Buffer.byteLength(data, 'utf8') > MAX_INPUT_BYTES) {
      throw new TypeError('Terminal input exceeds the 64 KiB limit')
    }
    if (this.state !== 'running') throw new Error('Terminal is not running')
    const bytes = Buffer.from(data, 'utf8')
    const frame = Buffer.allocUnsafe(5 + bytes.length)
    frame[0] = 87
    frame.writeUInt32BE(bytes.length, 1)
    bytes.copy(frame, 5)
    await this._send('W', frame)
    return { accepted: true }
  }

  _send(type, frame) {
    const command = this._control.then(async () => {
      if (this.state !== 'running') throw new Error('Terminal is not running')
      const ack = Promise.withResolvers()
      ack.type = type
      ack.promise.catch(() => {})
      this._acks.push(ack)
      let timeout
      try {
        await new Promise((resolve, reject) => this.child.stdio[3].write(frame,
          error => error ? reject(error) : resolve()))
        await Promise.race([ack.promise, new Promise((_, reject) => {
          timeout = setTimeout(() => reject(new Error('PTY control acknowledgement timed out')), START_TIMEOUT_MS)
        })])
      } catch (error) {
        this._acks = this._acks.filter(item => item !== ack)
        this._fatal(error)
        throw error
      } finally { clearTimeout(timeout) }
    })
    this._control = command.catch(() => {})
    return command
  }

  async resize(cols, rows) {
    dimensions(cols, rows)
    if (this.state !== 'running') throw new Error('Terminal is not running')
    const frame = Buffer.from(['R'.charCodeAt(0), cols >> 8, cols & 255, rows >> 8, rows & 255])
    await this._send('R', frame)
    this.cols = cols
    this.rows = rows
    this.screen.resize(cols, rows)
    this.revision++
    return this.info()
  }

  async close() {
    if (this._closing) return this._closing
    this._closing = this._close().finally(() => {
      this.displayState?.dispose()
      this._terminalReplySubscription?.dispose()
    })
    return this._closing
  }

  async _close() {
    if (this._processClosed) return this._finished.promise
    if (!this._termSent) {
      this._termSent = true
      this.child.kill('SIGTERM')
    }
    let timeout
    try {
      await Promise.race([this._finished.promise, new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('Terminal process did not exit after SIGTERM')),
          this.closeTimeoutMs)
      })])
    } catch (error) {
      this.child.kill('SIGKILL')
      clearTimeout(timeout)
      try {
        await Promise.race([this._finished.promise, new Promise((_, reject) => {
          timeout = setTimeout(() => reject(new Error('Terminal process did not exit after SIGKILL')),
            this.closeTimeoutMs)
        })])
      } catch (killError) {
        throw new AggregateError([error, killError], 'Terminal process cleanup did not complete')
      }
    } finally { clearTimeout(timeout) }
  }
}

/** App-local terminal service. Processes remain owned by the Node Host, not a page. */
export class AppTerminals {
  constructor({ resolveDirectory, spawn = nodeSpawn, helper = helperPath, makeScreen = screenFactory,
    probeShell = executableShell, workdirTimeoutMs = WORKDIR_TIMEOUT_MS,
    closeTimeoutMs = CLOSE_TIMEOUT_MS } = {}) {
    this.resolveDirectory = resolveDirectory
    this.spawn = spawn
    this.helper = helper
    this.makeScreen = makeScreen
    this.probeShell = probeShell
    this.workdirTimeoutMs = workdirTimeoutMs
    this.closeTimeoutMs = closeTimeoutMs
    this.sessions = new Map()
    this.closed = new Map()
    this.pending = new Map()
    this.pendingShells = new Map()
    this.owners = new Map()
    this.activeCreates = 0
    this.disposed = false
  }

  /** Count retained terminals and in-flight allocations before replacing the Host runtime. */
  activitySnapshot() {
    let live = 0
    for (const entries of this.sessions.values()) live += entries.size
    return { live, pending: this.activeCreates }
  }

  _session(sessionId) {
    return this.sessions.get(sessionId) ?? new Map()
  }

  list({ sessionId }) {
    identity(sessionId, 'sessionId')
    return [...this._session(sessionId).values()].map(item => item.info())
  }

  /** Discover only fixed Android system shells. Discovery never allocates a PTY. */
  async shells() {
    const available = []
    for (const shell of SYSTEM_SHELLS) {
      let timer
      try {
        await Promise.race([
          this.probeShell(shell.path),
          new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('Shell discovery timed out')),
              SHELL_DISCOVERY_TIMEOUT_MS)
          }),
        ])
      }
      catch (error) {
        if (['ENOENT', 'ENOTDIR', 'EACCES'].includes(error?.code)) continue
        throw new Error('Shell discovery failed', { cause: error })
      } finally {
        clearTimeout(timer)
      }
      available.push({ id: shell.id, label: shell.label })
    }
    return available
  }

  async _owner(sessionId, scope) {
    for (;;) {
      const current = this.owners.get(sessionId)
      if (current?.scope === scope) {
        if (current.stopped) throw new Error('Terminal Session owner has stopped')
        return current
      }
      if (current) {
        await this._disposeOwner(sessionId, current)
        continue
      }
      if (this.disposed) throw new Error('Terminal service has stopped')
      const owner = { scope, stopped: false, cleanup: null }
      scope.effect(() => async () => { await this._disposeOwner(sessionId, owner) },
        'android-terminal.owner')
      this.owners.set(sessionId, owner)
      return owner
    }
  }

  _disposeOwner(sessionId, owner) {
    if (owner.cleanup) return owner.cleanup
    owner.stopped = true
    owner.cleanup = (async () => {
      await Promise.allSettled([...this.pending].filter(([key]) => key.startsWith(`${sessionId}\0`))
        .map(([, operation]) => operation))
      const entries = this.sessions.get(sessionId)
      const ids = entries ? [...entries.keys()] : []
      const results = await Promise.allSettled(ids.map(id => this.close({ sessionId, id })))
      const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
      if (errors.length) throw new AggregateError(errors, 'Terminal Session owner cleanup failed')
      if (this.owners.get(sessionId) === owner) {
        this.sessions.delete(sessionId)
        this.closed.delete(sessionId)
        this.owners.delete(sessionId)
      }
    })().catch(error => { owner.cleanup = null; throw error })
    return owner.cleanup
  }

  async create(params) {
    this.activeCreates++
    try { return await this._create(params) }
    finally { this.activeCreates-- }
  }

  async _create({ sessionId, id, cols = 80, rows = 24, shellId = 'system-sh' }) {
    identity(sessionId, 'sessionId'); identity(id, 'terminalId'); dimensions(cols, rows)
    const shell = SYSTEM_SHELLS.find(entry => entry.id === shellId)
    if (!shell) throw new TypeError('Unsupported terminal shell')
    if (this.disposed) throw new Error('Terminal service has stopped')
    let directoryTimer
    const resolved = await Promise.race([
      this.resolveDirectory(sessionId),
      new Promise((_, reject) => {
        directoryTimer = setTimeout(() => reject(new Error('Session working directory timed out')),
          this.workdirTimeoutMs)
      }),
    ]).finally(() => clearTimeout(directoryTimer))
    if (typeof resolved?.cwd !== 'string' || !resolved.cwd.startsWith('/')
      || typeof resolved.owner?.effect !== 'function') {
      throw new Error('Session working directory or Agent owner is unavailable')
    }
    const owner = await this._owner(sessionId, resolved.owner)
    if (this.disposed || owner.stopped) throw new Error('Terminal Session owner has stopped')
    const key = `${sessionId}\0${id}`
    if (this.closed.get(sessionId)?.has(id)) throw new Error('This terminal identity was closed')
    const existing = this._session(sessionId).get(id)
    if (existing) {
      if (existing.shellId !== shellId) throw new Error('Terminal identity uses a different shell')
      return existing.info()
    }
    if (this.pending.has(key)) {
      if (this.pendingShells.get(key) !== shellId) throw new Error('Terminal identity uses a different shell')
      return this.pending.get(key)
    }
    if (this._session(sessionId).size + [...this.pending.keys()].filter(item => item.startsWith(`${sessionId}\0`)).length
      >= MAX_TERMINALS) throw new Error('Session terminal limit reached')
    const operation = (async () => {
      if (this.disposed || owner.stopped) throw new Error('Terminal Session owner has stopped')
      let shellTimer
      try {
        await Promise.race([
          this.probeShell(shell.path),
          new Promise((_, reject) => {
            shellTimer = setTimeout(() => reject(new Error('Shell discovery timed out')),
              SHELL_DISCOVERY_TIMEOUT_MS)
          }),
        ])
      }
      catch (error) {
        if (['ENOENT', 'ENOTDIR', 'EACCES'].includes(error?.code)) {
          throw new Error('Selected terminal shell is unavailable', { cause: error })
        }
        throw new Error('Selected terminal shell could not be checked', { cause: error })
      } finally { clearTimeout(shellTimer) }
      if (this.disposed || owner.stopped || this.closed.get(sessionId)?.has(id)) {
        throw new Error('Terminal closed during shell discovery')
      }
      const item = new TerminalProcess({ id, sessionId, cwd: resolved.cwd, cols, rows, shell,
        spawn: this.spawn,
        helper: this.helper(), makeScreen: this.makeScreen, closeTimeoutMs: this.closeTimeoutMs })
      try { await item.started() }
      catch (error) {
        try { await item.close() }
        catch (cleanupError) {
          throw new AggregateError([error, cleanupError], 'PTY startup and cleanup failed')
        }
        throw error
      }
      if (this.disposed || owner.stopped || this.closed.get(sessionId)?.has(id)) {
        await item.close()
        throw new Error('Terminal closed during allocation')
      }
      let entries = this.sessions.get(sessionId)
      if (!entries) { entries = new Map(); this.sessions.set(sessionId, entries) }
      entries.set(id, item)
      return item.info()
    })()
    this.pending.set(key, operation)
    this.pendingShells.set(key, shellId)
    try { return await operation }
    finally { this.pending.delete(key); this.pendingShells.delete(key) }
  }

  _get(sessionId, id) {
    identity(sessionId, 'sessionId'); identity(id, 'terminalId')
    const item = this._session(sessionId).get(id)
    if (!item) throw new Error('Terminal is unavailable')
    return item
  }

  read(params) { return this._get(params.sessionId, params.id).read() }
  write(params) { return this._get(params.sessionId, params.id).write(params.data) }
  resize(params) { return this._get(params.sessionId, params.id).resize(params.cols, params.rows) }
  rename({ sessionId, id, name }) {
    if (this.disposed || this.closed.get(sessionId)?.has(id)
      || this.owners.get(sessionId)?.stopped) {
      throw new Error('Terminal is unavailable')
    }
    const item = this._get(sessionId, id)
    const next = terminalName(name)
    if (item.name !== next) {
      item.name = next
      item.revision++
    }
    return item.info()
  }

  async close({ sessionId, id }) {
    identity(sessionId, 'sessionId'); identity(id, 'terminalId')
    let closed = this.closed.get(sessionId)
    if (!closed) { closed = new Set(); this.closed.set(sessionId, closed) }
    closed.add(id)
    const pending = this.pending.get(`${sessionId}\0${id}`)
    if (pending) await pending.catch(() => {})
    const item = this._session(sessionId).get(id)
    if (!item) return { closed: true }
    await item.close()
    this._session(sessionId).delete(id)
    return { closed: true }
  }

  async dispose() {
    this.disposed = true
    await Promise.allSettled([...this.pending.values()])
    const results = await Promise.allSettled([...this.owners]
      .map(([sessionId, owner]) => this._disposeOwner(sessionId, owner)))
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
    if (errors.length) throw new AggregateError(errors, 'Android terminal cleanup failed')
  }
}
