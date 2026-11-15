#!/usr/bin/env node
/**
 * 扫码配对真机验收驱动。
 *
 * 相机流程需要人手持手机对准二维码，自动化只能验证「解码链路 + 页面接线」：
 * 1. 用宿主同一个编码器（`apps/remote-host/src/pairing-qr.ts`）把一条配对链接
 *    编码成二维码矩阵，再零依赖手写灰度 PNG（node:zlib 压 IDAT，不自带依赖）；
 * 2. 把 PNG `adb push` 到手机上本 App 的 files 目录；
 * 3. `am start` 带 debug-only extra `dshPairingScanImage`，App 用与相机流程完全
 *    相同的 ZXing 解码实现读出文本，并以 logcat 标签 `DshPairingScan` 记录结果；
 * 4. 断言解出的文本逐字等于配对链接。
 *
 * 前提：手机已安装 **debug** APK（`BuildConfig.DEBUG=true`；脚本会检查
 * `dumpsys package` 的 DEBUGGABLE 标志）。release 构建里解码调用点被编译期折叠，
 * 这个通道不会存在（证据见交付报告的 javap 输出）。
 *
 * 用法（仓库根）：
 *   node apps/android/tool/acceptance-pairing-scan.mjs --dry-run
 *   node apps/android/tool/acceptance-pairing-scan.mjs --adb D:\Programs\adb\adb.exe
 *   node apps/android/tool/acceptance-pairing-scan.mjs --link "wss://192.168.5.21:4777#instance=…&token=…"
 *
 * `--dry-run` 只生成二维码 PNG 并检查 adb/设备状态，不推送文件、不启动 App。
 * 真实验收默认用合成链接（形状合法、无真实配对效果）；要复验宿主刚打印的链接时
 * 用 `--link` 传入。
 *
 * 依赖：Node ≥ 22.18（直接 import `.ts` 编码器需要原生 TypeScript 类型剥离）。
 * 不需要 `pnpm install`，不启动、不占用宿主端口。
 */

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { deflateSync } from 'node:zlib'

const ROOT = resolve(import.meta.dirname, '../../..')
const PACKAGE = 'com.minnnng.dsh_android'
const ACTIVITY = `${PACKAGE}/.MainActivity`
/** 启动 Intent 的 debug-only 解码参数（`PairingQrScan.EXTRA_SCAN_IMAGE`）。 */
const EXTRA_SCAN_IMAGE = 'dshPairingScanImage'
/** `PairingQrScan` 写解码结果的 logcat 标签。 */
const LOG_TAG = 'DshPairingScan'
const DEFAULT_OUTPUT = resolve(ROOT, '.cache/remote-device/pairing-scan')
const DEFAULT_PHONE_DIR = `/sdcard/Android/data/${PACKAGE}/files/pairing-scan`
const DEFAULT_TIMEOUT_MS = 60_000
/** 二维码模块边长与安静区（模块数）：8 px/模块、4 模块安静区是通用相机可读的下限以上。 */
const DEFAULT_PIXEL_SIZE = 8
const DEFAULT_QUIET_ZONE = 4
/** 配对链接的形状：与 `PairingDescriptor.parse` 接受的一致。 */
const LINK_PATTERN = /^wss:\/\/[^\s#]+#instance=[0-9a-f]{64}&token=[A-Za-z0-9_-]{43}$/u

/** 命令行用法。 */
function usage () {
  return [
    'Usage:',
    '  node apps/android/tool/acceptance-pairing-scan.mjs [options]',
    '',
    'Options:',
    '  --dry-run              只生成二维码 PNG 并检查 adb/设备状态（不推送、不启动 App）',
    '  --adb <path>           adb 可执行文件（默认 $env:ADB，否则 PATH 里的 adb）',
    '  --device <serial>      adb 设备序列号（默认唯一在线设备）',
    '  --link <pairing-url>   二维码内容（默认合成一条形状合法的配对链接）',
    '  --output <dir>         PNG 输出目录（默认 .cache/remote-device/pairing-scan）',
    '  --phone-dir <dir>      手机上的暂存目录（默认 /sdcard/Android/data/<包名>/files/pairing-scan）',
    '  --pixel-size <n>       每个二维码模块的像素数（默认 8）',
    '  --quiet-zone <n>       安静区模块数（默认 4）',
    '  --timeout <ms>         等待解码日志的上限（默认 60000）',
    '  --keep                 不删除手机上推送的 PNG（默认解码后删除）',
    '  --help                 打印本用法',
    '',
  ].join('\n')
}

/** 解析命令行。 */
function parseArgs (argv) {
  const options = {
    dryRun: false,
    adb: process.env.ADB ?? 'adb',
    device: undefined,
    link: undefined,
    output: DEFAULT_OUTPUT,
    phoneDir: DEFAULT_PHONE_DIR,
    pixelSize: DEFAULT_PIXEL_SIZE,
    quietZone: DEFAULT_QUIET_ZONE,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    keep: false,
    help: false,
  }
  let index = 0
  const take = (flag) => {
    const value = argv[index]
    if (value === undefined) throw new Error(`${flag} requires a value`)
    index += 1
    return value
  }
  while (index < argv.length) {
    const argument = argv[index]
    index += 1
    switch (argument) {
      case '--dry-run': options.dryRun = true; break
      case '--adb': options.adb = take(argument); break
      case '--device': options.device = take(argument); break
      case '--link': options.link = take(argument); break
      case '--output': options.output = resolve(take(argument)); break
      case '--phone-dir': options.phoneDir = take(argument).replace(/\/+$/u, ''); break
      case '--pixel-size': options.pixelSize = Number(take(argument)); break
      case '--quiet-zone': options.quietZone = Number(take(argument)); break
      case '--timeout': options.timeoutMs = Number(take(argument)); break
      case '--keep': options.keep = true; break
      case '--help': options.help = true; break
      default: throw new Error(`unknown option ${argument}`)
    }
  }
  if (!Number.isSafeInteger(options.pixelSize) || options.pixelSize < 2 || options.pixelSize > 32) {
    throw new Error('--pixel-size must be an integer in [2, 32]')
  }
  if (!Number.isSafeInteger(options.quietZone) || options.quietZone < 0 || options.quietZone > 16) {
    throw new Error('--quiet-zone must be an integer in [0, 16]')
  }
  if (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 5_000) {
    throw new Error('--timeout must be an integer >= 5000')
  }
  if (options.link !== undefined && !LINK_PATTERN.test(options.link)) {
    throw new Error('--link must look like wss://host:port#instance=<64 lowercase hex>&token=<43 base64url>')
  }
  return options
}

/** 可复用的等待。 */
function sleep (ms) { return new Promise(resolveSleep => setTimeout(resolveSleep, ms)) }

/** 合成一条形状合法的配对链接：解码验收不需要真实宿主，形状与产品链接一致。 */
function syntheticLink () {
  const instance = createHash('sha256').update('dsh-pairing-scan-acceptance').digest('hex')
  const token = 'A'.repeat(43)
  return `wss://192.168.5.21:4777#instance=${instance}&token=${token}`
}

/** CRC-32（PNG 每个 chunk 的校验）。 */
const CRC_TABLE = (() => {
  const table = new Int32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let value = n
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
    }
    table[n] = value
  }
  return table
})()

/** 计算一段字节的 CRC-32。 */
function crc32 (buffer) {
  let value = 0xffffffff
  for (const byte of buffer) value = CRC_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8)
  return (value ^ 0xffffffff) >>> 0
}

/** 组装一个 PNG chunk：长度 + 类型 + 数据 + CRC。 */
function pngChunk (type, data) {
  const length = Buffer.alloc(4)
  length.writeUInt32BE(data.length, 0)
  const typeBytes = Buffer.from(type, 'ascii')
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 0)
  return Buffer.concat([length, typeBytes, data, crc])
}

/** 把 8 位灰度像素写成最小合法 PNG（无过滤器、zlib 压缩）。 */
function encodeGrayscalePng (width, height, pixels) {
  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0)
  header.writeUInt32BE(height, 4)
  header[8] = 8 // bit depth
  header[9] = 0 // color type: grayscale
  header[10] = 0 // compression
  header[11] = 0 // filter
  header[12] = 0 // interlace
  const stride = width + 1
  const raw = Buffer.alloc(stride * height)
  for (let row = 0; row < height; row += 1) {
    raw[row * stride] = 0 // filter type: none
    pixels.copy(raw, row * stride + 1, row * width, (row + 1) * width)
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', header),
    pngChunk('IDAT', deflateSync(raw, { level: 9 })),
    pngChunk('IEND', Buffer.alloc(0)),
  ])
}

/** 把二维码矩阵渲染成灰度像素：深色模块 0、浅色模块与安静区 255。 */
function renderMatrix (matrix, pixelSize, quietZone) {
  const totalModules = matrix.size + quietZone * 2
  const dimension = totalModules * pixelSize
  const pixels = Buffer.alloc(dimension * dimension, 0xff)
  for (let row = 0; row < matrix.size; row += 1) {
    for (let column = 0; column < matrix.size; column += 1) {
      if (matrix.modules[row][column] !== true) continue
      for (let y = 0; y < pixelSize; y += 1) {
        const offset = (quietZone + row) * pixelSize + y
        const start = offset * dimension + (quietZone + column) * pixelSize
        pixels.fill(0, start, start + pixelSize)
      }
    }
  }
  return { width: dimension, height: dimension, pixels }
}

/** 加载宿主同一个二维码编码器（Node 原生 TypeScript 类型剥离）。 */
async function loadEncoder () {
  const encoderPath = resolve(import.meta.dirname, '../../remote-host/src/pairing-qr.ts')
  if (!existsSync(encoderPath)) throw new Error(`找不到二维码编码器：${encoderPath}`)
  try {
    return await import(pathToFileURL(encoderPath).href)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(`无法加载二维码编码器 ${encoderPath}：${message}。` +
      '需要 Node >= 22.18（原生 TypeScript 类型剥离）')
  }
}

/** 生成二维码 PNG 与配对链接，返回落盘路径与事实信息。 */
async function renderFixture (options) {
  const link = options.link ?? syntheticLink()
  const encoder = await loadEncoder()
  const matrix = encoder.encodeQrMatrix(link)
  const { width, height, pixels } = renderMatrix(matrix, options.pixelSize, options.quietZone)
  const png = encodeGrayscalePng(width, height, pixels)
  mkdirSync(options.output, { recursive: true })
  const imagePath = resolve(options.output, 'pairing-qr.png')
  const linkPath = resolve(options.output, 'pairing-qr.txt')
  writeFileSync(imagePath, png)
  writeFileSync(linkPath, link)
  return {
    link,
    matrix,
    imagePath,
    linkPath,
    width,
    height,
    bytes: png.length,
    sha256: createHash('sha256').update(png).digest('hex'),
  }
}

/** 设备操作封装：所有 adb 交互集中在这里，失败时带上下文。 */
class Device {
  constructor (adbPath, serial) {
    this.adbPath = adbPath
    this.serial = serial
  }

  /** 执行 adb 命令并返回 stdout。 */
  adb (...args) {
    const full = this.serial === undefined ? args : ['-s', this.serial, ...args]
    const result = spawnSync(this.adbPath, full, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    if (result.error !== undefined) throw result.error
    if (result.status !== 0) {
      throw new Error(`adb ${full.join(' ')} failed (${result.status}): ${(result.stderr ?? '').trim()}`)
    }
    return result.stdout
  }

  /** shell 快捷方式。 */
  sh (...args) { return this.adb('shell', ...args) }
}

/** 只读探测 adb 状态：返回 { ok, reason, deviceLines }。 */
function probeAdb (options) {
  const result = spawnSync(options.adb, ['devices'], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 })
  if (result.error !== undefined) {
    return { ok: false, reason: `无法执行 adb（${options.adb}）：${result.error.message}` }
  }
  if (result.status !== 0) {
    return { ok: false, reason: `adb devices 失败（${result.status}）：${(result.stderr ?? '').trim()}` }
  }
  const lines = result.stdout.split(/\r?\n/u).map(line => line.trim()).filter(Boolean)
  const devices = lines
    .filter(line => !line.startsWith('List of devices'))
    .map(line => line.split(/\s+/u))
    .filter(parts => parts.length >= 2 && parts[1] === 'device')
    .map(parts => parts[0])
  return { ok: true, devices, raw: lines.join('; ') }
}

/** 连接唯一在线设备或指定序列号的设备。 */
function connectDevice (options) {
  const probe = probeAdb(options)
  if (!probe.ok) throw new Error(probe.reason)
  const devices = probe.devices
  const serial = options.device ?? (devices.length === 1 ? devices[0] : undefined)
  if (serial === undefined) {
    throw new Error(devices.length === 0
      ? `没有在线设备（adb devices：${probe.raw}）`
      : `有多台在线设备，需要 --device 指定：${devices.join(', ')}`)
  }
  if (!devices.includes(serial)) throw new Error(`设备 ${serial} 不在 adb devices 列表里：${devices.join(', ')}`)
  return new Device(options.adb, serial)
}

/** 断言装的是 debug APK（debug-only 解码通道只存在于 debug 构建）。 */
function ensureDebugInstall (device) {
  const dump = device.sh('dumpsys', 'package', PACKAGE)
  if (!dump.includes(`Package [${PACKAGE}]`)) throw new Error(`手机上没有安装 ${PACKAGE}`)
  if (!/flags=\[[^\]]*DEBUGGABLE/u.test(dump)) {
    throw new Error(`${PACKAGE} 不是 debug 构建（dumpsys 无 DEBUGGABLE）：` +
      'release 里 dshPairingScanImage 解码通道被编译期折叠，无法用本脚本验收')
  }
}

/** 等待 App 打出解码日志行。 */
async function waitForScanLog (device, options) {
  const deadline = Date.now() + options.timeoutMs
  let last = ''
  while (Date.now() < deadline) {
    last = device.adb('logcat', '-d', '-s', `${LOG_TAG}:I`)
    const line = last.split(/\r?\n/u).find(value => value.includes('pairing-scan-image'))
    if (line !== undefined) return line
    await sleep(500)
  }
  throw new Error(`等待 ${LOG_TAG} 解码日志超时（${options.timeoutMs} ms）；` +
    `最后 logcat 输出：${last.trim().slice(-2000)}`)
}

/** 真实验收：生成 PNG → push → am start 带 extra → 断言 logcat 里的解码文本。 */
async function runAcceptance (options) {
  const fixture = await renderFixture(options)
  console.log(`配对链接：${fixture.link}`)
  console.log(`二维码：版本 ${fixture.matrix.version}，${fixture.matrix.size}×${fixture.matrix.size} 模块，` +
    `掩码 ${fixture.matrix.mask}`)
  console.log(`图片：${relative(ROOT, fixture.imagePath)}（${fixture.width}×${fixture.height}，` +
    `${fixture.bytes} B，sha256 ${fixture.sha256}）`)

  const device = connectDevice(options)
  const model = device.sh('getprop', 'ro.product.model').trim()
  const release = device.sh('getprop', 'ro.build.version.release').trim()
  console.log(`device: ${model}（Android ${release}） serial=${device.serial}`)
  ensureDebugInstall(device)

  const phonePath = `${options.phoneDir}/pairing-scan.png`
  device.sh('mkdir', '-p', options.phoneDir)
  device.adb('push', fixture.imagePath, phonePath)
  console.log(`已推送：${phonePath}`)

  device.adb('logcat', '-c')
  device.sh('am', 'force-stop', PACKAGE)
  const started = device.sh('am', 'start', '-W', '-n', ACTIVITY, '--es', EXTRA_SCAN_IMAGE, phonePath)
  if (!/Status:\s*ok/u.test(started)) {
    console.warn(`提示：am start 没有报告 Status: ok：${started.trim()}`)
  }

  try {
    const line = await waitForScanLog(device, options)
    const failed = /pairing-scan-image error code=(\S+)/u.exec(line)
    if (failed !== null) throw new Error(`App 解码失败（${failed[1]}）：${line.trim()}`)
    const decoded = /pairing-scan-image ok text=(.*)$/u.exec(line)
    if (decoded === null) throw new Error(`解码日志无法识别：${line.trim()}`)
    if (decoded[1] !== fixture.link) {
      throw new Error(`解码文本与配对链接不一致：\n  期望：${fixture.link}\n  实际：${decoded[1]}`)
    }
    console.log(`解码日志：${line.trim()}`)
    console.log('\nPASS: 二维码经 ZXing 解出的文本与配对链接逐字一致' +
      '（debug-only 图片通道；相机流程需人手持手机验收）')
    return 0
  } finally {
    if (!options.keep) {
      try {
        device.sh('rm', '-f', phonePath)
      } catch (cleanupFailure) {
        console.warn(`提示：清理 ${phonePath} 失败：${cleanupFailure instanceof Error ? cleanupFailure.message : String(cleanupFailure)}`)
      }
    }
  }
}

/** dry-run：只生成二维码 PNG 并检查 adb/设备状态（没有设备也算通过）。 */
async function runDryRun (options) {
  const fixture = await renderFixture(options)
  console.log(`[dry-run] 配对链接：${fixture.link}`)
  console.log(`[dry-run] 二维码：版本 ${fixture.matrix.version}，` +
    `${fixture.matrix.size}×${fixture.matrix.size} 模块，掩码 ${fixture.matrix.mask}`)
  console.log(`[dry-run] PNG：${fixture.width}×${fixture.height}，${fixture.bytes} B，` +
    `sha256 ${fixture.sha256}`)
  console.log(`[dry-run] 图片：${relative(ROOT, fixture.imagePath)}`)
  console.log(`[dry-run] 文本：${relative(ROOT, fixture.linkPath)}`)

  const probe = probeAdb(options)
  if (!probe.ok) {
    console.warn(`[dry-run] adb 不可用：${probe.reason}`)
    console.warn('[dry-run] 真实运行前安装 adb 或用 --adb <path> 指定')
    console.log('\n[dry-run] PASS: 二维码图片已生成；未推送文件、未启动 App')
    return 0
  }
  if (probe.devices.length === 0) {
    console.warn(`[dry-run] adb 可用，但没有在线设备（${probe.raw}）`)
    console.log('\n[dry-run] PASS: 二维码图片已生成；未推送文件、未启动 App')
    return 0
  }
  const device = new Device(options.adb, options.device ?? probe.devices[0])
  const model = device.sh('getprop', 'ro.product.model').trim()
  const release = device.sh('getprop', 'ro.build.version.release').trim()
  console.log(`[dry-run] 设备：${model}（Android ${release}） serial=${device.serial}`)
  const installed = device.sh('dumpsys', 'package', PACKAGE)
  if (!installed.includes(`Package [${PACKAGE}]`)) {
    console.warn(`[dry-run] 设备上没有安装 ${PACKAGE}`)
  } else if (!/flags=\[[^\]]*DEBUGGABLE/u.test(installed)) {
    console.warn(`[dry-run] 已安装的 ${PACKAGE} 不是 debug 构建，真实验收会被拒绝`)
  } else {
    console.log('[dry-run] 已安装 debug 构建：dshPairingScanImage 通道可用')
  }
  console.log(`[dry-run] 将推送：${options.phoneDir}/pairing-scan.png`)
  console.log('\n[dry-run] PASS: 二维码图片已生成；adb/设备状态已检查（未推送、未启动 App）')
  return 0
}

/** 主流程。 */
async function main (argv) {
  const options = parseArgs(argv)
  if (options.help) {
    process.stdout.write(`${usage()}\n`)
    return 0
  }
  try {
    return options.dryRun ? await runDryRun(options) : await runAcceptance(options)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error(`\nFAIL: ${message}`)
    return 1
  }
}

main(process.argv.slice(2)).then((code) => {
  process.exitCode = code
}).catch((error) => {
  console.error(`acceptance-pairing-scan: ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
})
