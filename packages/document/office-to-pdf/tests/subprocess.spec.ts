/** Child-process Office conversion lifecycle and kit CLI option projection. */
import { ChildProcess, spawn } from 'node:child_process'
import { PassThrough } from 'node:stream'
import { afterEach, expect, it, vi } from 'vitest'
import { convertInSubprocess } from '../src/subprocess.ts'

vi.mock('node:child_process', async importOriginal => ({ ...await importOriginal<typeof import('node:child_process')>(), spawn: vi.fn() }))
const spawned = vi.mocked(spawn)

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
      queueMicrotask(() => {
        child.stdout!.emit('data', Buffer.from(JSON.stringify({ outputPath: args[args.indexOf('--output') + 1],
          missingFonts: [] })))
        child.emit('close', 0, null)
      })
      return child
    })
    await convertInSubprocess('/private/source.docx', '/private/converted.pdf', { timeoutMs: 1000 },
      new AbortController().signal)
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
  vi.stubEnv('DSH_ANDROID_NATIVE_LIBRARY_DIR', '')
  try {
    await expect(convertInSubprocess('/private/source.docx', '/private/converted.pdf', { timeoutMs: 1000 },
      new AbortController().signal)).rejects.toMatchObject({ code: 'unavailable' })
    expect(spawned).not.toHaveBeenCalled()
  } finally {
    Object.defineProperty(process, 'platform', platform)
  }
})

it('passes the same conversion limits and font roots, with no ambient credential, and parses the kit result', async () => {
  const child = fakeChild()
  spawned.mockImplementation((_command, args) => {
    queueMicrotask(() => {
      child.stdout!.emit('data', Buffer.from(JSON.stringify({ outputPath: args[args.indexOf('--output') + 1],
        backend: 'wasm', missingFonts: ['Uninstalled Font'] })))
      child.emit('close', 0, null)
    })
    return child
  })
  const before = process.env.OFFICE_TEST_SECRET_TOKEN
  process.env.OFFICE_TEST_SECRET_TOKEN = 'do-not-pass-to-child'
  try {
    const result = await convertInSubprocess('/private/source.docx', '/private/converted.pdf', {
      timeoutMs: 90_000, maxInputBytes: 10, maxOutputBytes: 20, maxImageResolution: 96,
      maxArchiveEntries: 2_000, maxUncompressedBytes: 64, maxFontFiles: 1_024,
      maxFontFileBytes: 16, maxLoadedFontBytes: 64,
      fontDirectories: ['/system/fonts'], fontFallbacks: [['sans-serif', 'Arial']],
    }, new AbortController().signal)
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
  spawned.mockImplementation(() => {
    queueMicrotask(() => {
      child.stderr!.emit('data', Buffer.from('{"code":"invalid-document","error":"corrupt input"}\n'))
      child.emit('close', 1, null)
    })
    return child
  })
  await expect(convertInSubprocess('/source.docx', '/converted.pdf', { timeoutMs: 1000 }, new AbortController().signal))
    .rejects.toMatchObject({ code: 'invalid-document' })
})

it('kills and joins the child when the last conversion reader cancels', async () => {
  const child = fakeChild()
  spawned.mockReturnValue(child)
  const controller = new AbortController()
  const reason = new Error('caller stopped')
  const work = convertInSubprocess('/source.docx', '/converted.pdf', { timeoutMs: 1000 }, controller.signal)
  controller.abort(reason)
  await expect(work).rejects.toBe(reason)
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})

it('hard-stops a child that does not settle before the configured deadline', async () => {
  vi.useFakeTimers()
  const child = fakeChild()
  spawned.mockReturnValue(child)
  const work = convertInSubprocess('/source.docx', '/converted.pdf', { timeoutMs: 5 }, new AbortController().signal)
  const rejected = expect(work).rejects.toMatchObject({ code: 'timeout' })
  await vi.advanceTimersByTimeAsync(5)
  await rejected
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})
