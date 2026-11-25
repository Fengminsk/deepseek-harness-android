/** Child-process PDF conversion lifecycle, kit CLI option projection, and failure classification. */
import { ChildProcess, spawn } from 'node:child_process'
import { PassThrough } from 'node:stream'
import { afterEach, expect, it, vi } from 'vitest'
import { convertInSubprocess } from '../src/subprocess.ts'

vi.mock('node:child_process', async importOriginal => ({ ...await importOriginal<typeof import('node:child_process')>(), spawn: vi.fn() }))
const spawned = vi.mocked(spawn)
const input = '/private/source.docx'
const output = '/private/converted.pdf'
const signal = (): AbortSignal => new AbortController().signal

function fakeChild(): ChildProcess {
  const child = new ChildProcess()
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.kill = vi.fn(() => {
    queueMicrotask(() => { child.emit('close', null, 'SIGKILL') })
    return true
  })
  return child
}

/** Settle a fake child on a later microtask, after the conversion registers its listeners. */
function settle(child: ChildProcess, exit: { code?: number | null; signal?: NodeJS.Signals | null } = {},
  streams: { stdout?: string; stderr?: string } = {}): void {
  queueMicrotask(() => {
    if (streams.stdout !== undefined) child.stdout!.emit('data', Buffer.from(streams.stdout))
    if (streams.stderr !== undefined) child.stderr!.emit('data', Buffer.from(streams.stderr))
    child.emit('close', 'code' in exit ? exit.code ?? null : 0, exit.signal ?? null)
  })
}

afterEach(() => {
  spawned.mockReset()
  vi.useRealTimers()
  vi.unstubAllEnvs()
})

it('uses the packaged Android Node CLI and native library search path for the kit CLI', async () => {
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' })
  vi.stubEnv('DSH_ANDROID_NATIVE_LIBRARY_DIR', '/data/app/example/lib/arm64')
  vi.stubEnv('LD_LIBRARY_PATH', '/system/lib64')
  try {
    const child = fakeChild()
    spawned.mockImplementation((_command, args) => {
      settle(child, {}, { stdout: JSON.stringify({ outputPath: args[args.indexOf('--output') + 1], missingFonts: [] }) })
      return child
    })
    await convertInSubprocess(input, output, { timeoutMs: 1000 }, signal())
    const [command, args, options] = spawned.mock.calls[0]!
    expect(command).toBe('/data/app/example/lib/arm64/libpocket_node_cli.so')
    expect(args[0]).toMatch(/libreoffice-kit[/\\]lib[/\\]cli\.(?:js|mjs)$/)
    expect(options?.env?.LD_LIBRARY_PATH).toBe('/data/app/example/lib/arm64:/system/lib64')
    expect(options?.env).not.toHaveProperty('DSH_ANDROID_NATIVE_LIBRARY_DIR')
  } finally {
    Object.defineProperty(process, 'platform', platform)
  }
})

it('refuses an Android conversion without a native CLI directory', async () => {
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' })
  const directory = process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR
  delete process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR
  try {
    await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
      .rejects.toMatchObject({ code: 'unavailable' })
    expect(spawned).not.toHaveBeenCalled()
  } finally {
    if (directory !== undefined) process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR = directory
    Object.defineProperty(process, 'platform', platform)
  }
})

it('refuses an Android conversion with a relative CLI directory', async () => {
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!
  Object.defineProperty(process, 'platform', { ...platform, value: 'android' })
  vi.stubEnv('DSH_ANDROID_NATIVE_LIBRARY_DIR', 'lib/arm64')
  try {
    await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
      .rejects.toMatchObject({ code: 'unavailable' })
    expect(spawned).not.toHaveBeenCalled()
  } finally {
    Object.defineProperty(process, 'platform', platform)
  }
})

it('passes the same conversion limits and font roots, with no ambient credential, and parses the kit result', async () => {
  const child = fakeChild()
  spawned.mockImplementation((_command, args) => {
    settle(child, {}, { stdout: JSON.stringify({ outputPath: args[args.indexOf('--output') + 1],
      backend: 'wasm', missingFonts: ['Uninstalled Font'] }) })
    return child
  })
  const before = process.env.OFFICE_TEST_SECRET_TOKEN
  process.env.OFFICE_TEST_SECRET_TOKEN = 'do-not-pass-to-child'
  try {
    const result = await convertInSubprocess(input, output, {
      timeoutMs: 90_000, maxInputBytes: 10, maxOutputBytes: 20, maxImageResolution: 96,
      maxArchiveEntries: 2_000, maxUncompressedBytes: 64, maxFontFiles: 1_024,
      maxFontFileBytes: 16, maxLoadedFontBytes: 64,
      fontDirectories: ['/system/fonts'], fontFallbacks: [['sans-serif', 'Arial']],
    }, signal())
    expect(result.missingFonts).toEqual(['Uninstalled Font'])
    expect(spawned).toHaveBeenCalledOnce()
    const [command, args, options] = spawned.mock.calls[0]!
    expect(command).toBe(process.execPath)
    expect(args).toContain('--max-font-files')
    expect(args).toContain('1024')
    expect(args).toContain('/system/fonts')
    expect(args).toContain('[["sans-serif","Arial"]]')
    expect(options?.env).not.toHaveProperty('OFFICE_TEST_SECRET_TOKEN')
    expect(options?.stdio).toEqual(['ignore', 'pipe', 'pipe'])
  } finally {
    if (before === undefined) delete process.env.OFFICE_TEST_SECRET_TOKEN
    else process.env.OFFICE_TEST_SECRET_TOKEN = before
  }
})

it('preserves a classified kit failure when the child exits nonzero', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, { code: 1 }, { stderr: '{"code":"invalid-document","error":"corrupt input"}\n' })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
    .rejects.toMatchObject({ code: 'invalid-document' })
})

const unpublishedFailures: ReadonlyArray<readonly [string, string]> = [
  ['an unpublished category', '{"code":"busy"}\n'],
  ['a non-object payload', '"failed"\n'],
  ['a null payload', 'null\n'],
  ['an absent category', '{}\n'],
  ['a non-string category', '{"code":7}\n'],
  ['unstructured diagnostics', 'LibreOffice crashed\n'],
]

it.each(unpublishedFailures)('reports %s as failed', async (_case, stderr) => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, { code: 1 }, { stderr })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
    .rejects.toMatchObject({ name: 'OfficeKitError', code: 'failed' })
})

it('reports an exited child without diagnostics or a category as failed', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, { code: 3 })
  const error = await convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()).catch((cause: unknown) => cause)
  expect(error).toMatchObject({ name: 'OfficeKitError', code: 'failed' })
  expect(error).toHaveProperty('cause.message', 'exit 3')
})

it('rejects a signaled child that exited zero', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, { code: 0, signal: 'SIGKILL' })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
    .rejects.toMatchObject({ code: 'failed' })
})

it('reports an externally killed child as failed', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, { code: null, signal: 'SIGKILL' })
  const error = await convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()).catch((cause: unknown) => cause)
  expect(error).toMatchObject({ name: 'OfficeKitError', code: 'failed' })
  expect(error).toHaveProperty('cause.message', 'exit SIGKILL')
})

const invalidMetadata: ReadonlyArray<readonly [string, string]> = [
  ['not JSON', 'not json'],
  ['a JSON array', '[]'],
  ['JSON null', 'null'],
  ['a JSON string', '"metadata"'],
  ['no output path', JSON.stringify({ missingFonts: [] })],
  ['a different output path', JSON.stringify({ outputPath: '/private/other.pdf', missingFonts: [] })],
  ['no font report', JSON.stringify({ outputPath: output })],
  ['a non-array font report', JSON.stringify({ outputPath: output, missingFonts: 'Arial' })],
  ['a non-string font family', JSON.stringify({ outputPath: output, missingFonts: [7] })],
]

it.each(invalidMetadata)('rejects child metadata that is %s', async (_case, stdout) => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, {}, { stdout })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
    .rejects.toMatchObject({ name: 'OfficeKitError', code: 'failed' })
})

it('refuses to start a child for an already cancelled conversion', async () => {
  const controller = new AbortController()
  const reason = new Error('caller stopped')
  controller.abort(reason)
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, controller.signal)).rejects.toBe(reason)
  expect(spawned).not.toHaveBeenCalled()
})

it('kills and joins a child cancelled while the process starts', async () => {
  const child = fakeChild()
  const controller = new AbortController()
  const reason = new Error('caller stopped')
  spawned.mockImplementation(() => { controller.abort(reason); return child })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, controller.signal)).rejects.toBe(reason)
  // oxlint-disable-next-line typescript/unbound-method -- fakeChild replaces the prototype method with a spy that never uses `this`.
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})

it('kills and joins the child when the last conversion reader cancels', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  const controller = new AbortController()
  const reason = new Error('caller stopped')
  const work = convertInSubprocess(input, output, { timeoutMs: 1000 }, controller.signal)
  controller.abort(reason)
  await expect(work).rejects.toBe(reason)
  // oxlint-disable-next-line typescript/unbound-method -- fakeChild replaces the prototype method with a spy that never uses `this`.
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})

it('hard-stops a child that does not settle before the configured deadline', async () => {
  vi.useFakeTimers()
  const child = fakeChild()
  spawned.mockReturnValue(child)
  const work = convertInSubprocess(input, output, { timeoutMs: 5 }, signal())
  const rejected = expect(work).rejects.toMatchObject({ code: 'timeout' })
  await vi.advanceTimersByTimeAsync(5)
  await rejected
  // oxlint-disable-next-line typescript/unbound-method -- fakeChild replaces the prototype method with a spy that never uses `this`.
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})

it('reports a child that cannot start as unavailable', async () => {
  const child = fakeChild()
  const cause = Object.assign(new Error('spawn EACCES'), { code: 'EACCES' })
  spawned.mockReturnValue(child)
  queueMicrotask(() => { child.emit('error', cause); child.emit('close', null, null) })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
    .rejects.toMatchObject({ code: 'unavailable', cause })
})

it('stops a child whose diagnostics exceed their limit', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  settle(child, {}, { stdout: 'x'.repeat(64 * 1024 + 1) })
  await expect(convertInSubprocess(input, output, { timeoutMs: 1000 }, signal()))
    .rejects.toMatchObject({ code: 'failed' })
  // oxlint-disable-next-line typescript/unbound-method -- fakeChild replaces the prototype method with a spy that never uses `this`.
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})
