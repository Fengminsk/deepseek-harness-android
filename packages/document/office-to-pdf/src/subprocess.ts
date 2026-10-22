/** Isolate one kit CLI conversion so its WASM heap leaves the Host on exit. */
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { dirname, posix } from 'node:path'
import type { ConverterOptions } from '@deepseek-ai/libreoffice-kit'
import { OfficeToPdfError } from './errors.ts'
import type { OfficeToPdfErrorCode } from './types.ts'

const maxDiagnosticBytes = 64 * 1024
const allowedEnvironment = [
  'HOME', 'TMPDIR', 'TEMP', 'TMP', 'PATH', 'LANG', 'LC_ALL', 'TZ', 'LD_LIBRARY_PATH',
  'ANDROID_ROOT', 'ANDROID_DATA', 'ANDROID_RUNTIME_ROOT', 'SYSTEMROOT', 'WINDIR',
  'LOCALAPPDATA', 'USERPROFILE',
] as const
const codes = new Set<OfficeToPdfErrorCode>([
  'input-too-large', 'output-too-large', 'invalid-document', 'unsupported-format',
  'invalid-output', 'timeout', 'unavailable', 'failed',
])

function kitArguments(inputPath: string, outputPath: string, options: ConverterOptions): string[] {
  const args = ['convert', '--input', inputPath, '--output', outputPath]
  const numeric: ReadonlyArray<readonly [string, number | undefined]> = [
    ['timeout-ms', options.timeoutMs], ['max-input-bytes', options.maxInputBytes],
    ['max-output-bytes', options.maxOutputBytes], ['max-image-resolution', options.maxImageResolution],
    ['max-archive-entries', options.maxArchiveEntries], ['max-uncompressed-bytes', options.maxUncompressedBytes],
    ['max-font-files', options.maxFontFiles], ['max-font-file-bytes', options.maxFontFileBytes],
    ['max-loaded-font-bytes', options.maxLoadedFontBytes],
  ]
  for (const [name, value] of numeric) if (value !== undefined) args.push(`--${name}`, String(value))
  for (const path of options.fontDirectories ?? []) args.push('--font-directory', path)
  if (options.fontFallbacks !== undefined) args.push('--font-fallbacks', JSON.stringify(options.fontFallbacks))
  return args
}

function childEnvironment(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { NO_COLOR: '1' }
  for (const key of allowedEnvironment) if (process.env[key] !== undefined) env[key] = process.env[key]
  return env
}

function nodeLauncher(env: NodeJS.ProcessEnv): string {
  if (process.platform !== 'android') return process.execPath
  const directory = process.env.DSH_ANDROID_NATIVE_LIBRARY_DIR
  if (directory === undefined || !posix.isAbsolute(directory)) {
    throw new OfficeToPdfError('unavailable', 'Android Node CLI launcher directory is unavailable.')
  }
  env.LD_LIBRARY_PATH = [directory, env.LD_LIBRARY_PATH].filter(Boolean).join(':')
  return posix.join(directory, 'libpocket_node_cli.so')
}

function codeFromFailure(stderr: string): OfficeToPdfErrorCode {
  try {
    const parsed: unknown = JSON.parse(stderr.trim())
    if (typeof parsed === 'object' && parsed !== null && 'code' in parsed
      && typeof parsed.code === 'string' && codes.has(parsed.code as OfficeToPdfErrorCode)) {
      return parsed.code as OfficeToPdfErrorCode
    }
  } catch { /* Child may be killed before it can write structured diagnostics. */ }
  return 'failed'
}

/**
 * Run the pinned kit's CLI with the provider's same rendering options.
 * @param inputPath - private authorized source file.
 * @param outputPath - fresh exclusive PDF path.
 * @param options - resolved kit limits and font roots.
 * @param signal - conversion lifetime; abort kills and joins the whole child.
 * @returns original kit missing-font report after a clean child exit.
 */
export async function convertInSubprocess(
  inputPath: string, outputPath: string, options: ConverterOptions, signal: AbortSignal,
): Promise<{ readonly missingFonts: string[] }> {
  signal.throwIfAborted()
  const cli = createRequire(import.meta.url).resolve('@deepseek-ai/libreoffice-kit/cli')
  const env = childEnvironment()
  const child = spawn(nodeLauncher(env), [cli, ...kitArguments(inputPath, outputPath, options)], {
    cwd: dirname(inputPath), env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
  })
  const stdoutChunks: Buffer[] = []
  const stderrChunks: Buffer[] = []
  let stdoutBytes = 0
  let stderrBytes = 0
  let overflow = false
  let spawnError: Error | undefined
  let timedOut = false
  const stop = (): void => { child.kill('SIGKILL') }
  const deadline = setTimeout(() => { timedOut = true; stop() }, options.timeoutMs)
  const abort = (): void => { stop() }
  const capture = (part: 'stdout' | 'stderr', chunk: Buffer): void => {
    const bytes = part === 'stdout' ? stdoutBytes : stderrBytes
    if (bytes + chunk.length > maxDiagnosticBytes) { overflow = true; stop(); return }
    if (part === 'stdout') { stdoutBytes += chunk.length; stdoutChunks.push(chunk) }
    else { stderrBytes += chunk.length; stderrChunks.push(chunk) }
  }
  child.stdout.on('data', (chunk: Buffer) => { capture('stdout', chunk) })
  child.stderr.on('data', (chunk: Buffer) => { capture('stderr', chunk) })
  child.once('error', (error) => { spawnError = error })
  signal.addEventListener('abort', abort, { once: true })
  if (signal.aborted) stop()
  let exitCode: number | null
  let exitSignal: NodeJS.Signals | null
  try {
    [exitCode, exitSignal] = await new Promise((resolve) => {
      child.once('close', (code, signalName) => resolve([code, signalName]))
    })
  } finally {
    clearTimeout(deadline)
    signal.removeEventListener('abort', abort)
  }
  const stdout = Buffer.concat(stdoutChunks).toString('utf8')
  const stderr = Buffer.concat(stderrChunks).toString('utf8')
  signal.throwIfAborted()
  if (timedOut) throw new OfficeToPdfError('timeout', 'LibreOffice conversion timed out.')
  if (spawnError !== undefined) throw new OfficeToPdfError('unavailable', 'LibreOffice child could not start.', { cause: spawnError })
  if (overflow) throw new OfficeToPdfError('failed', 'LibreOffice child exceeded its diagnostic limit.')
  if (exitCode !== 0 || exitSignal !== null) {
    throw new OfficeToPdfError(codeFromFailure(stderr), 'LibreOffice child conversion failed.', { cause: new Error(stderr || `exit ${exitCode ?? exitSignal}`) })
  }
  let result: unknown
  try { result = JSON.parse(stdout.trim()) }
  catch (cause) { throw new OfficeToPdfError('failed', 'LibreOffice child returned invalid metadata.', { cause }) }
  if (typeof result !== 'object' || result === null || !('outputPath' in result) || result.outputPath !== outputPath
    || !('missingFonts' in result) || !Array.isArray(result.missingFonts)
    || !result.missingFonts.every(font => typeof font === 'string')) {
    throw new OfficeToPdfError('failed', 'LibreOffice child returned invalid metadata.')
  }
  return { missingFonts: result.missingFonts }
}
