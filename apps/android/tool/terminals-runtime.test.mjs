import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { once } from 'node:events'
import { createRequire } from 'node:module'
import { AppTerminals, observeTerminalDisplay, projectTerminalView } from '../runtime/terminals.mjs'

const terminalRequire = createRequire(new URL('../../../packages/terminal/terminal-bash/package.json', import.meta.url))
const { Terminal } = terminalRequire('@xterm/headless')

async function interpretedScreen(cols, rows, text) {
  const screen = new Terminal({ cols, rows, scrollback: 500, allowProposedApi: true })
  await new Promise(resolve => screen.write(text, resolve))
  return screen
}

test('headless projection retains ANSI styles, cursor cell and wide characters', async () => {
  const screen = await interpretedScreen(12, 3,
    'A\x1b[1;31mB\x1b[0m\x1b[7;38;2;18;52;86mC\x1b[0m你\x1b[2G')
  const view = projectTerminalView(screen)
  assert.equal(view.cols, 12)
  assert.deepEqual(view.cursor, { col: 1, row: 0 })
  assert.equal(view.lines[0].runs.map(run => run.text).join(''), 'ABC你')
  assert.equal(view.lines[0].runs[1].fg, 1)
  assert.equal(view.lines[0].runs[1].bold, true)
  assert.equal(view.lines[0].runs[1].cursor, true)
  assert.equal(view.lines[0].runs[2].fg, '#123456')
  assert.equal(view.lines[0].runs[2].inverse, true)
  assert.equal(JSON.stringify(view).includes('\x1b'), false)
  screen.dispose()
})

test('projection changes to alternate buffer and bounds scrollback by cells', async () => {
  const screen = await interpretedScreen(500, 2, `${'x\n'.repeat(250)}\x1b[44mEnd`)
  const normal = projectTerminalView(screen)
  assert.ok(normal.lines.length <= 200)
  assert.equal(normal.truncated, true)
  assert.ok(normal.lines.at(-1).runs.some(run => run.bg === 4))
  await new Promise(resolve => screen.write('\x1b[?1049hALT', resolve))
  const alternate = projectTerminalView(screen)
  assert.equal(screen.buffer.active.type, 'alternate')
  assert.equal(alternate.lines.length, 2)
  assert.ok(alternate.lines.some(line => line.runs.some(run => run.text.includes('ALT'))))
  assert.equal(alternate.lines.some(line => line.runs.some(run => run.text.includes('End'))), false)
  screen.dispose()
})

test('pathological per-cell styling keeps text while capping styled runs', async () => {
  const source = '\x1b[31ma\x1b[32mb'.repeat(10050)
  const screen = await interpretedScreen(120, 200, source)
  const view = projectTerminalView(screen)
  assert.equal(view.stylesTruncated, true)
  assert.ok(view.lines.reduce((sum, line) => sum + line.runs.length, 0) < 10500)
  assert.ok(view.lines.map(line => line.runs.map(run => run.text).join('')).join('').includes('abab'))
  screen.dispose()
})

test('program OSC palette and cursor modes survive projection and reset', async () => {
  const screen = await interpretedScreen(12, 2, 'A')
  const display = observeTerminalDisplay(screen)
  const write = source => new Promise(resolve => screen.write(source, resolve))
  await write('\x1b]4;1;rgb:f/0/8;240;#abc\x07\x1b]10;#123456\x07\x1b]11;#111111\x07'
    + '\x1b]12;#abcdef\x07\x1b[?25l\x1b[3 q')
  let view = projectTerminalView(screen, display)
  assert.deepEqual(view.palette, {
    indexed: { 1: '#ff0088', 240: '#a0b0c0' },
    foreground: '#123456', background: '#111111', cursor: '#abcdef',
  })
  assert.equal(view.cursorVisible, false)
  assert.equal(view.cursorStyle, 'underline')
  assert.equal(view.cursorBlink, true)
  assert.equal(view.lines[0].runs.some(run => run.cursor), false)
  await write('\x1b[?25h\x1b[6 q\x1b]104;1\x07\x1b]110\x07\x1b]112\x07')
  view = projectTerminalView(screen, display)
  assert.equal(view.cursorVisible, true)
  assert.equal(view.cursorStyle, 'bar')
  assert.equal(view.cursorBlink, false)
  assert.deepEqual(view.palette, { indexed: { 240: '#a0b0c0' }, background: '#111111' })
  assert.equal(view.lines[0].runs.some(run => run.cursor), true)
  await write('\x1bc')
  view = projectTerminalView(screen, display)
  assert.deepEqual(view.palette, { indexed: {} })
  assert.equal(view.cursorVisible, true)
  assert.equal(view.cursorStyle, 'block')
  display.dispose()
  screen.dispose()
})

test('malformed and query OSC colors cannot change projected palette', async () => {
  const screen = await interpretedScreen(8, 2, '')
  const display = observeTerminalDisplay(screen)
  await new Promise(resolve => screen.write('\x1b]4;256;#fff;0;?;2;rgb:ff/0/f\x07'
    + '\x1b]12;rgb:aaaa/bb/cccc\x07\x1b[999 q', resolve))
  const view = projectTerminalView(screen, display)
  assert.deepEqual(view.palette, { indexed: {} })
  assert.equal(view.cursorStyle, 'block')
  display.dispose()
  screen.dispose()
})

test('terminal.read delivers a styled projection after consuming PTY bytes', async () => {
  const { service, children } = fixture({ makeScreen: (cols, rows) => {
    const screen = new Terminal({ cols, rows, scrollback: 500, allowProposedApi: true })
    return { screen, serializer: { serialize: () => '' } }
  } })
  await service.create({ sessionId: 'session-A', id: 'styled', cols: 8, rows: 2 })
  children[0].child.stdout.write('\x1b[32mgreen\x1b[0m')
  const result = await service.read({ sessionId: 'session-A', id: 'styled' })
  assert.equal(result.display, 'green')
  assert.equal(result.view.lines[0].runs[0].fg, 2)
  assert.equal(result.view.lines[0].runs[0].text, 'green')
  await service.dispose()
})

test('terminal.read restores program palette and cursor state after page detachment', async () => {
  const { service, children } = fixture({ makeScreen: (cols, rows) => {
    const screen = new Terminal({ cols, rows, scrollback: 500, allowProposedApi: true })
    return { screen, serializer: { serialize: () => '' } }
  } })
  await service.create({ sessionId: 'session-A', id: 'persist', cols: 8, rows: 2 })
  children[0].child.stdout.write('\x1b]4;2;#123456\x07\x1b[?25l\x1b[4 q\x1b[32mgreen')
  const first = await service.read({ sessionId: 'session-A', id: 'persist' })
  assert.equal(first.view.palette.indexed[2], '#123456')
  assert.equal(first.view.cursorVisible, false)
  assert.equal(first.view.cursorStyle, 'underline')
  // A fresh reader uses the same Host-owned PTY; no Flutter page-local state is required.
  const reopened = await service.read({ sessionId: 'session-A', id: 'persist' })
  assert.deepEqual(reopened.view, first.view)
  assert.equal(children.length, 1)
  await service.dispose()
})

function fixture({ acknowledge = true, resolveDirectory, workdirTimeoutMs, closeTimeoutMs, onKill,
  makeScreen } = {}) {
  const children = []
  const owners = new Map()
  const scope = sessionId => {
    let owner = owners.get(sessionId)
    if (!owner) {
      const effects = []
      owner = {
        effect: register => { effects.push(register()) },
        dispose: async () => {
          const results = await Promise.allSettled(effects.map(cleanup => cleanup()))
          const errors = results.filter(result => result.status === 'rejected').map(result => result.reason)
          if (errors.length) throw new AggregateError(errors, 'Agent scope cleanup failed')
        },
      }
      owners.set(sessionId, owner)
    }
    return owner
  }
  const spawn = (path, args, options) => {
    const child = new EventEmitter()
    child.stdin = new PassThrough()
    child.stdout = new PassThrough()
    child.stderr = new PassThrough()
    child.stdio = [child.stdin, child.stdout, child.stderr, new PassThrough(), new PassThrough()]
    child.killed = false
    child.kill = signal => {
      if (onKill?.(child, signal) === false) return true
      if (child.killed) return false
      child.killed = true
      queueMicrotask(() => {
        child.stdout.end()
        child.emit('close', signal === 'SIGKILL' ? null : 143, signal)
      })
      return true
    }
    children.push({ child, path, args, options })
    if (acknowledge) queueMicrotask(() => child.stdio[4].write('S123\n'))
    return child
  }
  const service = new AppTerminals({
    resolveDirectory: resolveDirectory ?? (async id => ({
      cwd: id === 'session-A' ? '/app/workspace' : '/app/second', owner: scope(id),
    })),
    spawn,
    helper: () => '/app/libpocket_terminal_helper.so',
    workdirTimeoutMs, closeTimeoutMs,
    makeScreen: makeScreen ?? (() => {
      let output = ''
      return { screen: {
        write(text, done) { output += text; done() },
        resize() {},
      }, serializer: { serialize: () => output } }
    }),
  })
  return { service, children, owners, scope }
}

test('one Session owns its PTY and reconnecting reads a complete screen', async () => {
  const { service, children } = fixture()
  const opened = await service.create({ sessionId: 'session-A', id: 'terminal-1', cols: 80, rows: 24 })
  assert.equal(opened.state, 'running')
  assert.equal(children[0].path, '/app/libpocket_terminal_helper.so')
  assert.deepEqual(children[0].args, ['/app/workspace', '80', '24', '/system/bin/sh'])
  assert.equal(children[0].options.env.TERM, 'xterm-256color')
  assert.deepEqual(Object.keys(children[0].options.env).filter(key => /TOKEN|KEY|PASSWORD/.test(key)), [])
  children[0].child.stdout.write(Buffer.from([0xe4, 0xbd]))
  children[0].child.stdout.write(Buffer.from([0xa0]))
  await new Promise(resolve => setImmediate(resolve))
  const first = await service.read({ sessionId: 'session-A', id: 'terminal-1' })
  assert.equal(first.screen, '你')
  assert.equal((await service.create({ sessionId: 'session-A', id: 'terminal-1' })).state, 'running')
  assert.equal(children.length, 1)
  assert.deepEqual(service.list({ sessionId: 'session-B' }), [])
  assert.throws(() => service.read({ sessionId: 'session-B', id: 'terminal-1' }), /unavailable/)
  await service.close({ sessionId: 'session-A', id: 'terminal-1' })
  assert.equal(children[0].child.killed, true)
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
  await assert.rejects(service.create({ sessionId: 'session-A', id: 'terminal-1' }), /closed/)
})

test('raw input is bounded and resize waits for native acceptance', async () => {
  const { service, children } = fixture()
  await service.create({ sessionId: 'session-A', id: 't' })
  const child = children[0].child
  const inputFrame = new Promise(resolve => child.stdio[3].once('data', resolve))
  const input = service.write({ sessionId: 'session-A', id: 't', data: '\t' })
  assert.deepEqual([...await inputFrame], [87, 0, 0, 0, 1, 9])
  child.stdio[4].write('W0\n')
  assert.deepEqual(await input, { accepted: true })
  await assert.rejects(service.write({ sessionId: 'session-A', id: 't', data: 'x'.repeat(65537) }), /64 KiB/)
  const frame = new Promise(resolve => child.stdio[3].once('data', resolve))
  const resized = service.resize({ sessionId: 'session-A', id: 't', cols: 120, rows: 35 })
  assert.deepEqual([...await frame], [82, 0, 120, 0, 35])
  child.stdio[4].write('R0\n')
  assert.equal((await resized).cols, 120)
  const refused = service.resize({ sessionId: 'session-A', id: 't', cols: 130, rows: 40 })
  await new Promise(resolve => child.stdio[3].once('data', resolve))
  child.stdio[4].write('R1\n')
  await assert.rejects(refused, /refused/)
  assert.equal((await service.read({ sessionId: 'session-A', id: 't' })).cols, 120)
  await service.dispose()
})

test('startup failure does not leave an exposed terminal', async () => {
  const { service, children } = fixture({ acknowledge: false })
  const opening = service.create({ sessionId: 'session-A', id: 'bad' })
  await new Promise(resolve => setImmediate(resolve))
  children[0].child.stderr.write('forkpty denied')
  children[0].child.kill('SIGTERM')
  await assert.rejects(opening)
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
})

test('closing pending allocation and Host disposal cannot publish a late process', async () => {
  let release
  const deferred = new Promise(resolve => { release = resolve })
  const { service, children } = fixture({ resolveDirectory: () => deferred })
  const opening = service.create({ sessionId: 'session-A', id: 'late' })
  const closing = service.close({ sessionId: 'session-A', id: 'late' })
  release({ cwd: '/app/workspace', owner: { effect: () => {} } })
  await assert.rejects(opening, /closed/)
  await closing
  assert.equal(children.length, 0)
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
  await service.dispose()
  await assert.rejects(service.create({ sessionId: 'session-A', id: 'new' }), /stopped/)
})

test('unresponsive Session directory lookup fails without spawning or blocking disposal', async () => {
  const { service, children } = fixture({
    resolveDirectory: () => new Promise(() => {}), workdirTimeoutMs: 10,
  })
  await assert.rejects(service.create({ sessionId: 'session-A', id: 'missing' }), /timed out/)
  assert.equal(children.length, 0)
  await service.dispose()
})

test('page detachment keeps the PTY, while Agent owner disposal closes only its Session', async () => {
  const { service, children, owners } = fixture()
  await service.create({ sessionId: 'session-A', id: 'terminal-1' })
  await service.create({ sessionId: 'session-B', id: 'terminal-2' })
  assert.equal(service.list({ sessionId: 'session-A' }).length, 1)
  // The page has no teardown call; reconnecting the same Session reuses its process.
  assert.equal((await service.create({ sessionId: 'session-A', id: 'terminal-1' })).state, 'running')
  assert.equal(children.length, 2)
  await owners.get('session-A').dispose()
  assert.equal(children[0].child.killed, true)
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
  assert.equal(children[1].child.killed, false)
  assert.equal(service.list({ sessionId: 'session-B' }).length, 1)
  await service.dispose()
})

test('Agent teardown during pending PTY startup cannot publish a late terminal', async () => {
  const { service, children, owners } = fixture({ acknowledge: false })
  const opening = service.create({ sessionId: 'session-A', id: 'late' })
  await new Promise(resolve => setImmediate(resolve))
  const teardown = owners.get('session-A').dispose()
  children[0].child.stdio[4].write('S123\n')
  await assert.rejects(opening, /closed during allocation/)
  await teardown
  assert.equal(children[0].child.killed, true)
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
  await service.dispose()
})

test('a replacement Agent scope can use its Session identity after old owner teardown', async () => {
  const { service, children, owners, scope } = fixture()
  await service.create({ sessionId: 'session-A', id: 'terminal-1' })
  await owners.get('session-A').dispose()
  owners.delete('session-A')
  const reopened = await service.create({ sessionId: 'session-A', id: 'terminal-1' })
  assert.equal(reopened.state, 'running')
  assert.notEqual(scope('session-A'), undefined)
  assert.equal(children.length, 2)
  assert.equal(children[0].child.killed, true)
  assert.equal(children[1].child.killed, false)
  await service.dispose()
})

test('owner disposal waits for process exit after escalating an unresponsive SIGTERM', async () => {
  const signals = []
  const { service, children, owners } = fixture({ closeTimeoutMs: 10,
    onKill: (_child, signal) => {
      signals.push(signal)
      return signal !== 'SIGTERM'
    },
  })
  await service.create({ sessionId: 'session-A', id: 'stubborn' })
  await owners.get('session-A').dispose()
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
  assert.equal(children[0].child.killed, true)
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
  await service.dispose()
})

test('inactive Agent scope refuses terminal creation before spawning', async () => {
  const { service, children } = fixture({ resolveDirectory: async () => ({
    cwd: '/app/workspace', owner: { effect: () => { throw new Error('inactive Agent scope') } },
  }) })
  await assert.rejects(service.create({ sessionId: 'session-A', id: 'no-owner' }), /inactive Agent scope/)
  assert.equal(children.length, 0)
  await service.dispose()
})

test('failed control acknowledgement still escalates an unresponsive PTY on owner disposal', async () => {
  const signals = []
  const { service, children, owners } = fixture({ closeTimeoutMs: 10,
    onKill: (_child, signal) => {
      signals.push(signal)
      return signal !== 'SIGTERM'
    },
  })
  await service.create({ sessionId: 'session-A', id: 'bad-control' })
  children[0].child.stdio[4].write('invalid\n')
  assert.equal(service.list({ sessionId: 'session-A' })[0].state, 'failed')
  await owners.get('session-A').dispose()
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
  assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
})

test('failed PTY close returns an error after both bounded termination deadlines', async () => {
  const signals = []
  const { service, children } = fixture({ closeTimeoutMs: 10,
    onKill: (_child, signal) => { signals.push(signal); return false },
  })
  await service.create({ sessionId: 'session-A', id: 'stuck' })
  children[0].child.stdio[4].write('invalid\n')
  await assert.rejects(service.close({ sessionId: 'session-A', id: 'stuck' }),
    /Terminal process cleanup did not complete/)
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
})

test('spawn error cleanup finishes whether close has fired or the child is still alive', async () => {
  for (const alreadyClosed of [false, true]) {
    const signals = []
    const { service, children } = fixture({ acknowledge: false, closeTimeoutMs: 10,
      onKill: (_child, signal) => {
        signals.push(signal)
        return signal !== 'SIGTERM'
      },
    })
    const opening = service.create({ sessionId: 'session-A', id: 'spawn-error' })
    await new Promise(resolve => setImmediate(resolve))
    const child = children[0].child
    child.emit('error', new Error('spawn failed'))
    if (alreadyClosed) child.emit('close', null, null)
    await assert.rejects(opening, /spawn failed/)
    assert.deepEqual(signals, alreadyClosed ? [] : ['SIGTERM', 'SIGKILL'])
    assert.deepEqual(service.list({ sessionId: 'session-A' }), [])
    await service.dispose()
  }
})

test('fast stdout producer waits for xterm consumption instead of queuing writes', async () => {
  const callbacks = []
  let accepted = 0
  const { service, children } = fixture({ makeScreen: () => ({
    screen: { write(_text, done) { accepted++; callbacks.push(done) }, resize() {} },
    serializer: { serialize: () => '' },
  }) })
  await service.create({ sessionId: 'session-A', id: 'noisy' })
  const stdout = children[0].child.stdout
  const producer = (async () => {
    for (let index = 0; index < 64; index++) {
      if (!stdout.write(Buffer.alloc(4096, 0x78))) await once(stdout, 'drain')
    }
  })()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(stdout.isPaused(), true)
  assert.equal(accepted, 1)
  assert.equal(service._get('session-A', 'noisy')._pendingOutputBytes, 4096)
  for (let index = 0; index < 64; index++) {
    while (callbacks.length === 0) await new Promise(resolve => setImmediate(resolve))
    assert.equal(service._get('session-A', 'noisy')._pendingOutputBytes, 4096)
    callbacks.shift()()
    await new Promise(resolve => setImmediate(resolve))
  }
  await producer
  assert.equal(accepted, 64)
  assert.equal(service._get('session-A', 'noisy')._pendingOutputBytes, 0)
  await service.dispose()
})

test('output that evades stream pause fails at a bounded pending byte limit', async () => {
  const signals = []
  const { service, children } = fixture({
    onKill: (_child, signal) => { signals.push(signal) },
    makeScreen: () => ({
      screen: { write(_text, _done) {}, resize() {} },
      serializer: { serialize: () => '' },
    }),
  })
  await service.create({ sessionId: 'session-A', id: 'overflow' })
  const child = children[0].child
  child.stdout.emit('data', Buffer.alloc(200000, 0x78))
  child.stdout.emit('data', Buffer.alloc(200000, 0x78))
  assert.match(service.list({ sessionId: 'session-A' })[0].error, /256 KiB/)
  assert.deepEqual(signals, ['SIGTERM'])
  await service.dispose()
})
