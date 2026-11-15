#!/usr/bin/env node
/**
 * 远程附件上传真机验收驱动（A4）。
 *
 * 本机 OnePlus6/Android 11（ColorOS）的系统文件选择器对本 App 的所有文件行都不可选
 * （`shouldRestrictStorageAccessFramework=true`，HANDOFF §3.2.5），因此 debug 构建提供
 * 启动 Intent 暂存旁路：
 * - extra 名称：`dshStageAttachment`（可传一个路径、JSON 数组、或 `--esa` 的 String[]）；
 * - 路径白名单：`/sdcard/Download/` 或 `/sdcard/Android/data/<包名>/files/` 之下，
 *   App 侧再按 `canonicalFile` 校验，其它路径以 `attachment.pick` 的 `failures` 返回；
 * - 一次性：一次启动 Intent 只登记一次挑选，第一次 `attachment.pick` 消费后即清空；
 * - release 不生效：`AttachmentTransfers.stage` 用 `BuildConfig.DEBUG` 门控，release
 *   编译期该方法体被折叠为空，`MainActivity` 里的调用点也不存在（字节码证据见交付报告）。
 *
 * 脚本把测试文件推进白名单目录、带暂存参数启动 App，再驱动
 * 「首页 → 侧栏 → 远程 DSH → 会话 → + → 文件 → 已就绪 → 输入并发送」，
 * 断言 rail 字节数与发送后的消息气泡，并把截图落到 `.cache/remote-device/p5c-a*.png`。
 *
 * 前提：手机已安装 **debug** APK（`BuildConfig.DEBUG=true`），已与 PC 上的远程宿主配对，
 * 且该宿主正在运行（本机 4777 由 lead 管理；脚本不启动、不重启、不占用宿主端口）。
 *
 * 用法（仓库根）：
 *   node apps/android/tool/acceptance-remote-attachments.mjs --adb D:\Programs\adb\adb.exe --dry-run
 *   node apps/android/tool/acceptance-remote-attachments.mjs --adb D:\Programs\adb\adb.exe
 *
 * `--dry-run` 只探测导航选择器（启动、进入远程首页、可选打开指定会话并展开 `+` 弹层），
 * 不推送文件、不挑选附件、不输入/发送消息；真实运行时默认在远程首页新建一个会话。
 *
 * 暂存目录默认 `/sdcard/Android/data/<包名>/files/p5c-a`：本机 targetSdk 36（Android 11）
 * 的 scoped storage 下，App 能按路径读取的共享位置只有自己的 app-specific 外部 files/
 * （App 未申请任何外部存储权限，`/sdcard/Download` 的路径直读会被拒）。`/sdcard/Download/`
 * 仍在旁路白名单内，只在旧 ROM / 有全盘访问权限的验收机上用 `--staging-dir /sdcard/Download`。
 */

import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, relative, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../../..')
const APP_DIR = resolve(ROOT, 'apps/android')
const PACKAGE = 'com.minnnng.dsh_android'
const ACTIVITY = `${PACKAGE}/.MainActivity`
/** 启动 Intent 的 debug-only 暂存参数（`AttachmentTransfers.EXTRA_STAGED_ATTACHMENT`）。 */
const STAGE_EXTRA = 'dshStageAttachment'
const DEFAULT_STAGING_DIR = `/sdcard/Android/data/${PACKAGE}/files/p5c-a`
const DEFAULT_SHOT_DIR = resolve(ROOT, '.cache/remote-device')
const DEFAULT_FIXTURE = resolve(DEFAULT_SHOT_DIR, 'fixtures/p5c-a-attachment.pdf')
const DEFAULT_APK = resolve(APP_DIR, 'build/app/outputs/flutter-apk/app-debug.apk')
/** A4 的「3 MiB PDF」场景：内容确定，重复运行时手机上上传的字节完全一致。 */
const FIXTURE_BYTES = 3 * 1024 * 1024
const DEFAULT_TIMEOUT_MS = 180_000
const SHOT_REMOTE = '/sdcard/dsh-acceptance-shot.png'

/** 命令行用法。 */
function usage () {
  return [
    'Usage:',
    '  node apps/android/tool/acceptance-remote-attachments.mjs [options]',
    '',
    'Options:',
    '  --dry-run               只探测导航选择器：不推送文件、不挑选附件、不输入/发送消息',
    '  --adb <path>            adb 可执行文件（默认 $env:ADB，否则 PATH 里的 adb）',
    '  --device <serial>       adb 设备序列号（默认唯一在线设备）',
    '  --file <path>           测试文件，可重复（默认生成 3 MiB 的 .cache/remote-device/fixtures/p5c-a-attachment.pdf）',
    '  --staging-dir <dir>     手机暂存目录（默认 /sdcard/Android/data/<包名>/files/p5c-a；须在白名单内）',
    '  --session <title>       打开已有会话（标题片段）；缺省在远程首页新建会话',
    '  --input <text>          发送的 ASCII 标记（默认 P5C-A-OK-<时间戳>）',
    '  --apk <path>            debug APK（默认 build/app/outputs/flutter-apk/app-debug.apk）',
    '  --install               先 adb install -r 安装 --apk（默认不安装，由 lead 构建/安装）',
    '  --timeout <ms>          单步等待上限（默认 180000）',
    '  --output <dir>          截图目录（默认 .cache/remote-device）',
    '  --help                  打印本用法',
    '',
  ].join('\n')
}

/** 解析命令行。 */
function parseArgs (argv) {
  const options = {
    dryRun: false,
    adb: process.env.ADB ?? 'adb',
    device: undefined,
    files: [],
    stagingDir: DEFAULT_STAGING_DIR,
    session: undefined,
    input: undefined,
    apk: DEFAULT_APK,
    install: false,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    output: DEFAULT_SHOT_DIR,
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
      case '--file': options.files.push(resolve(take(argument))); break
      case '--staging-dir': options.stagingDir = take(argument).replace(/\/+$/u, ''); break
      case '--session': options.session = take(argument); break
      case '--input': options.input = take(argument); break
      case '--apk': options.apk = resolve(take(argument)); break
      case '--install': options.install = true; break
      case '--timeout': options.timeoutMs = Number(take(argument)); break
      case '--output': options.output = resolve(take(argument)); break
      case '--help': options.help = true; break
      default: throw new Error(`unknown option ${argument}`)
    }
  }
  if (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 10_000) {
    throw new Error('--timeout must be an integer >= 10000')
  }
  if (options.input !== undefined && !/^[\x20-\x7e]+$/u.test(options.input)) {
    throw new Error('--input must be printable ASCII (adb `input text` cannot type other scripts)')
  }
  if (options.session !== undefined && options.session.trim() === '') throw new Error('--session must not be empty')
  return options
}

/** 可复用的等待。 */
function sleep (ms) { return new Promise(resolveSleep => setTimeout(resolveSleep, ms)) }

/** 解码 uiautomator XML 属性里的实体。 */
function decodeXml (value) {
  return value
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#10;', '\n')
    .replaceAll('&amp;', '&')
}

/** 解析 uiautomator dump 的节点列表。 */
function parseNodes (xml) {
  const nodes = []
  for (const match of xml.matchAll(/<node\b([^>]*)>/gu)) {
    const attributes = match[1]
    const attribute = (name) => {
      const found = new RegExp(`${name}="([^"]*)"`, 'u').exec(attributes)
      return found === null ? '' : decodeXml(found[1])
    }
    const bounds = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/u.exec(attribute('bounds'))
    if (bounds === null) continue
    nodes.push({
      desc: attribute('content-desc'),
      text: attribute('text'),
      class: attribute('class'),
      clickable: attribute('clickable') === 'true',
      x: Math.round((Number(bounds[1]) + Number(bounds[3])) / 2),
      y: Math.round((Number(bounds[2]) + Number(bounds[4])) / 2),
    })
  }
  return nodes
}

/** 当前界面可见文本，失败报告用来定位。 */
function visibleTexts (nodes) {
  return nodes.map(node => node.desc || node.text).filter(Boolean).slice(0, 40)
}

/** 设备操作封装：所有 adb 交互集中在这里，失败时带上下文。 */
class Device {
  constructor (adbPath, serial, shotDir) {
    this.adbPath = adbPath
    this.serial = serial
    this.shotDir = shotDir
    this.screen = undefined
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

  /** 屏幕尺寸（`wm size` 的物理分辨率）。 */
  size () {
    if (this.screen === undefined) {
      const found = /(\d+)x(\d+)/u.exec(this.sh('wm', 'size'))
      if (found === null) throw new Error('无法读取设备分辨率（adb shell wm size）')
      this.screen = { width: Number(found[1]), height: Number(found[2]) }
    }
    return this.screen
  }

  /** 读取当前界面的节点。 */
  nodes () {
    this.sh('uiautomator', 'dump', '/sdcard/dsh-acceptance-ui.xml')
    return parseNodes(this.sh('cat', '/sdcard/dsh-acceptance-ui.xml'))
  }

  /** 在节点里找第一个 content-desc 或 text 包含目标串的节点。 */
  find (match, nodes = this.nodes()) {
    return nodes.find(node => node.desc.includes(match) || node.text.includes(match))
  }

  /** 等待节点出现；失败时输出当前可见文本方便定位。 */
  async wait (match, timeoutMs, label = match) {
    return this.waitFor(nodes => nodes.find(node => node.desc.includes(match) || node.text.includes(match)),
      timeoutMs, label)
  }

  /** 等待任意一个目标出现。 */
  async waitAny (matches, timeoutMs, label = matches.join('|')) {
    return this.waitFor(nodes => nodes.find(node => matches.some(match =>
      node.desc.includes(match) || node.text.includes(match))), timeoutMs, label)
  }

  /** 按谓词等待节点出现；超时错误带上当前可见文本。 */
  async waitFor (predicate, timeoutMs, label) {
    const deadline = Date.now() + timeoutMs
    let nodes = []
    while (Date.now() < deadline) {
      nodes = this.nodes()
      const found = predicate(nodes)
      if (found !== undefined) return found
      await sleep(400)
    }
    throw new Error(`等待超时：${label}；当前可见文本：${JSON.stringify(visibleTexts(nodes))}`)
  }

  tap (x, y) { this.sh('input', 'tap', String(x), String(y)) }

  /** 点按第一个匹配节点。 */
  async tapMatch (match, timeoutMs = 8000) {
    const node = await this.wait(match, timeoutMs)
    this.tap(node.x, node.y)
    return node
  }

  /** 滑动一次（坐标按当前屏幕尺寸取比例）。 */
  swipeRatio (xRatio, y1Ratio, xRatio2, y2Ratio, durationMs = 300) {
    const { width, height } = this.size()
    this.sh('input', 'swipe',
      String(Math.round(width * xRatio)), String(Math.round(height * y1Ratio)),
      String(Math.round(width * xRatio2)), String(Math.round(height * y2Ratio)), String(durationMs))
  }

  /** 输入 ASCII 文本；空格用 adb 的 `%s` 转义。 */
  inputText (text) { this.sh('input', 'text', text.replaceAll(' ', '%s')) }

  /** 返回键。 */
  back () { this.sh('input', 'keyevent', '4') }

  /** 截屏并拉到本地；失败时抛出（调用方决定是否吞掉）。 */
  screenshot (name) {
    mkdirSync(this.shotDir, { recursive: true })
    this.sh('screencap', '-p', SHOT_REMOTE)
    const target = resolve(this.shotDir, `${name}.png`)
    this.adb('pull', SHOT_REMOTE, target)
    this.sh('rm', '-f', SHOT_REMOTE)
    console.log(`  截图：${relative(ROOT, target)}`)
    return target
  }
}

/** 连接唯一在线设备或指定序列号的设备。 */
function connectDevice (options) {
  const result = spawnSync(options.adb, ['devices'], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 })
  if (result.error !== undefined || result.status !== 0) {
    throw new Error(`无法执行 adb（${options.adb}）：${result.error?.message ?? (result.stderr ?? '').trim()}` +
      '；用 --adb 指定 adb.exe 路径')
  }
  const serials = result.stdout.split(/\r?\n/u).slice(1)
    .map(line => /^(\S+)\s+device$/u.exec(line.trim())?.[1])
    .filter(Boolean)
  if (options.device !== undefined) {
    if (!serials.includes(options.device)) throw new Error(`设备 ${options.device} 不在线：${JSON.stringify(serials)}`)
    return new Device(options.adb, options.device, options.output)
  }
  if (serials.length === 0) throw new Error('没有在线 adb 设备')
  if (serials.length > 1) throw new Error(`有多台在线设备（${JSON.stringify(serials)}），用 --device 指定`)
  return new Device(options.adb, serials[0], options.output)
}

/** App 是否已安装。 */
function installed (device) {
  try {
    return device.sh('pm', 'path', PACKAGE).trim().length > 0
  } catch {
    return false
  }
}

/** debug 构建检查：暂存旁路只在 `BuildConfig.DEBUG=true` 的包里有代码。 */
function ensureDebugInstall (device) {
  if (!installed(device)) throw new Error(`手机上没有安装 ${PACKAGE}`)
  const dump = device.sh('dumpsys', 'package', PACKAGE)
  if (!dump.includes('DEBUGGABLE')) {
    throw new Error('已安装的 App 不是 debug 构建（BuildConfig.DEBUG=false），暂存旁路不生效；' +
      '先安装 app-debug.apk')
  }
}

/** 安装 debug APK（可选，默认由 lead 负责）。 */
function installApk (device, apk) {
  if (!existsSync(apk)) throw new Error(`APK 不存在：${apk}；先 flutter build apk --debug`)
  console.log(`安装：${relative(ROOT, apk)}`)
  device.adb('install', '-r', apk)
}

/** 生成 3 MiB 确定性 PDF 夹具（内容一致，便于重复验收对账）。 */
function ensureFixture (path) {
  if (existsSync(path) && statSync(path).size === FIXTURE_BYTES) return path
  mkdirSync(dirname(path), { recursive: true })
  const buffer = Buffer.alloc(FIXTURE_BYTES)
  const header = Buffer.from('%PDF-1.7\n% P5C-A remote attachment acceptance fixture\n')
  header.copy(buffer)
  let seed = 0x5a5a5a5a
  for (let index = header.length; index < buffer.length; index += 1) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0
    buffer[index] = seed >>> 24
  }
  writeFileSync(path, buffer)
  console.log(`夹具：${relative(ROOT, path)}（${buffer.length} B）`)
  return path
}

/** 暂存目录必须是 App 侧 canonical 白名单内的根：本包 Android/data files/ 或 /sdcard/Download。 */
function validateStagingDir (dir) {
  const roots = [`/sdcard/Android/data/${PACKAGE}/files`, '/sdcard/Download']
  if (dir.split('/').includes('..')) throw new Error(`--staging-dir 不能包含 .. 段：${dir}`)
  const accepted = roots.some(root => dir === root || dir.startsWith(`${root}/`))
  if (!accepted) {
    throw new Error(`--staging-dir 必须落在 ${roots.join(' 或 ')} 之下` +
      `（与 Kotlin 旁路的 canonical 白名单同一份规则）：${dir}`)
  }
  return dir
}

/** 本次运行推到手机上的暂存文件；无论成败，结束前都从手机删除。 */
const stagedRemotePaths = []

/** 删除本次推到手机的暂存文件；清理失败不掩盖验收结论。 */
function cleanupStaged (device, options) {
  if (options.dryRun) return
  for (const remote of stagedRemotePaths) {
    try {
      device.sh('rm', '-f', remote)
    } catch {
      // 设备已断开时清理失败不改变验收结论。
    }
  }
  stagedRemotePaths.length = 0
  if (options.stagingDir !== '/sdcard/Download') {
    try {
      device.sh('rmdir', options.stagingDir)
    } catch {
      // 目录非空或已被移除都不影响验收。
    }
  }
}

/** 把夹具推到手机暂存目录，并确认推送后的文件大小可读（App 侧可读性由 rail 状态断言）。 */
function pushFixtures (device, options, files) {
  device.sh('mkdir', '-p', options.stagingDir)
  const remotePaths = []
  for (const file of files) {
    const remote = `${options.stagingDir}/${basename(file)}`
    device.adb('push', file, remote)
    // 不用 run-as 校验 App 可读性：run-as 的 runas_app 域连本包自己的 /sdcard 目录都会被拒，
    // 不能代表真实 App 进程。App 是否读到由随后 rail 的「已就绪 / 暂存附件不可用」断言。
    let observed
    try {
      observed = Number(device.sh('stat', '-c', '%s', remote).trim())
    } catch (error) {
      throw new Error(`暂存文件推送后不可读：${remote}：` +
        `${error instanceof Error ? error.message : String(error)}；` +
        '如果本机不允许 adb 写入该目录，换 --staging-dir（见 --help）')
    }
    const expected = statSync(file).size
    if (observed !== expected) throw new Error(`暂存文件大小不符：${remote} = ${observed} B，期望 ${expected} B`)
    stagedRemotePaths.push(remote)
    remotePaths.push(remote)
  }
  return remotePaths
}

/** 启动 App；暂存路径经 debug-only extra 传给 Activity。 */
async function launchApp (device, options, stagedPaths) {
  device.sh('am', 'force-stop', PACKAGE)
  await sleep(600)
  const args = ['am', 'start', '-W', '-n', ACTIVITY]
  if (stagedPaths.length === 1) args.push('--es', STAGE_EXTRA, stagedPaths[0])
  else if (stagedPaths.length > 1) args.push('--esa', STAGE_EXTRA, stagedPaths.join(','))
  device.sh(...args)
  await device.wait('打开侧栏', options.timeoutMs, 'App 首页（打开侧栏）')
}

/** 打开侧栏进入远程 DSH 首页，并确认已配对的电脑在线。 */
async function openRemoteHome (device, options) {
  await device.tapMatch('打开侧栏', options.timeoutMs)
  await device.tapMatch('远程 DSH', options.timeoutMs)
  const state = await device.waitAny(['在线', '连接中', '离线', '添加连接'], options.timeoutMs, '远程首页连接状态')
  if (state.desc.includes('添加连接') || state.text.includes('添加连接')) {
    throw new Error('没有已配对的电脑（远程首页显示「添加连接」）；先在本机 4777 宿主上配对手机')
  }
  const online = device.find('在线')
  if (online === undefined) {
    await device.wait('在线', options.timeoutMs, '电脑在线')
  }
  // 项目/会话列表与底部输入条在连接就绪后还要一次渲染。
  await device.waitFor(nodes => nodes.find(node => node.class === 'android.widget.EditText') ??
    undefined, options.timeoutMs, '远程首页输入条')
}

/** 空闲时最靠下的 EditText：远程首页与会话页的输入框都在底部。 */
function bottomEditor (nodes) {
  return nodes
    .filter(node => node.class === 'android.widget.EditText')
    .sort((left, right) => right.y - left.y)[0]
}

/** 点进底部输入框使其获得焦点。 */
async function focusComposer (device, options, label) {
  const editor = await device.waitFor(nodes => bottomEditor(nodes), options.timeoutMs, label)
  device.tap(editor.x, editor.y)
  await sleep(500)
  return editor
}

/** 在远程首页新建会话并打开（新建请求会等到会话页推入后返回）。 */
async function createRemoteSession (device, options) {
  await focusComposer(device, options, '远程首页输入条')
  device.inputText(options.input.replaceAll(/[^A-Za-z0-9-]/gu, '-'))
  await sleep(500)
  await device.tapMatch('新建会话', options.timeoutMs)
  await device.wait('返回远程会话', options.timeoutMs, '远程会话页（返回远程会话）')
}

/** 打开标题匹配的已有会话；必要时向上滚动项目列表再找。 */
async function openExistingSession (device, options) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const found = device.find(options.session)
    if (found !== undefined) {
      device.tap(found.x, found.y)
      await device.wait('返回远程会话', options.timeoutMs, '远程会话页（返回远程会话）')
      return
    }
    device.swipeRatio(0.5, 0.72, 0.5, 0.42)
    await sleep(600)
  }
  throw new Error(`远程首页找不到标题包含 ${JSON.stringify(options.session)} 的会话；` +
    `当前可见文本：${JSON.stringify(visibleTexts(device.nodes()))}`)
}

/** 在会话页点开「+」弹层里的「文件」项。 */
async function pickFileMenuItem (device, options) {
  const adds = (await device.waitFor(nodes => {
    const buttons = nodes.filter(node => node.desc.includes('添加与指令') || node.text.includes('添加与指令'))
    return buttons.length > 0 ? buttons : undefined
  }, options.timeoutMs, '会话输入区「添加与指令」'))
    .sort((left, right) => right.y - left.y)
  device.tap(adds[0].x, adds[0].y)
  const row = await device.waitAny(['添加文件到当前消息', '文件  file'], 60_000, '「+」弹层里的「文件」项')
  device.tap(row.x, row.y)
}

/** 等 rail 出现「已就绪」，并断言每个夹具的名称与字节数。 */
async function waitAttachmentsReady (device, options, files) {
  const expected = files.map(file => ({ name: basename(file), bytes: statSync(file).size }))
  const failureTexts = ['上传失败', '无法读取所选文件', '附件导入未完成', '暂存附件不可用', '添加附件未完成']
  const nodes = await device.waitFor(current => {
    const failed = current.find(node => failureTexts.some(match =>
      node.desc.includes(match) || node.text.includes(match)))
    if (failed !== undefined) {
      throw new Error(`附件准备失败：${failed.desc || failed.text}；当前可见文本：${JSON.stringify(visibleTexts(current))}`)
    }
    const ready = current.some(node => node.text.includes('已就绪') || node.desc.includes('已就绪'))
    return ready ? current : undefined
  }, options.timeoutMs, '附件 rail「已就绪」')
  for (const file of expected) {
    if (!nodes.some(node => node.text.includes(file.name) || node.desc.includes(file.name))) {
      throw new Error(`rail 里看不到附件 ${file.name}；当前可见文本：${JSON.stringify(visibleTexts(nodes))}`)
    }
    const bytes = new RegExp(`${file.bytes} B`, 'u')
    if (!nodes.some(node => bytes.test(node.text) || bytes.test(node.desc))) {
      throw new Error(`rail 里的字节数不是 ${file.bytes} B（夹具大小）；` +
        `当前可见文本：${JSON.stringify(visibleTexts(nodes))}`)
    }
  }
  return nodes
}

/** 发送标记文本，并断言发送后的消息气泡（排除仍留在输入框里的情况）。 */
async function sendMarker (device, options) {
  await focusComposer(device, options, '会话页输入条')
  device.inputText(options.input)
  await sleep(500)
  await device.tapMatch('发送', 30_000)
  const nodes = await device.waitFor(current => {
    const failed = current.find(node => (node.text.includes('发送失败') || node.desc.includes('发送失败')))
    if (failed !== undefined) {
      throw new Error(`发送失败：${failed.text || failed.desc}；当前可见文本：${JSON.stringify(visibleTexts(current))}`)
    }
    return current.find(node => node.class !== 'android.widget.EditText' &&
      (node.text.includes(options.input) || node.desc.includes(options.input)))
  }, 60_000, '发送后的消息气泡')
  return nodes
}

/** 发送受理后草稿会被 consume，rail 应随之消失；超时不致命（发送已经成功）。 */
async function waitRailConsumed (device, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const nodes = device.nodes()
    if (!nodes.some(node => node.text.includes('已就绪') || node.desc.includes('已就绪'))) return
    await sleep(500)
  }
  console.warn('  提示：发送成功后 rail 在超时内仍显示「已就绪」（发送已成功，草稿回收可能延迟）')
}

/** 真实验收：暂存 → 启动 → 远程首页 → 会话 → 文件 → 已就绪 → 发送。 */
async function runAcceptance (device, options) {
  const fixtures = options.files.length > 0 ? options.files : [ensureFixture(DEFAULT_FIXTURE)]
  for (const file of fixtures) {
    if (!existsSync(file)) throw new Error(`测试文件不存在：${file}`)
  }
  if (options.install) installApk(device, options.apk)
  ensureDebugInstall(device)
  const staged = pushFixtures(device, options, fixtures)
  console.log(`暂存：${staged.length} 个文件 → ${options.stagingDir}`)
  await launchApp(device, options, staged)
  console.log('App 已带 dshStageAttachment 启动')
  await openRemoteHome(device, options)
  console.log('远程 DSH 已连接')
  await device.screenshot('p5c-a1-remote-home')
  if (options.session !== undefined) await openExistingSession(device, options)
  else await createRemoteSession(device, options)
  console.log('远程会话页已打开')
  await pickFileMenuItem(device, options)
  await waitAttachmentsReady(device, options, fixtures)
  console.log(`附件已就绪：${fixtures.map(file => basename(file)).join(', ')}`)
  await device.screenshot('p5c-a2-rail-ready')
  await sendMarker(device, options)
  await waitRailConsumed(device, 30_000)
  await device.screenshot('p5c-a3-sent')
  console.log(`\nPASS: ${fixtures.length} 个附件经 debug 暂存旁路准备为「已就绪」，` +
    `随消息 ${JSON.stringify(options.input)} 发送成功`)
  return 0
}

/** dry-run：只探测导航选择器，不推送、不挑选、不发送。 */
async function runDryRun (device, options) {
  if (!installed(device)) throw new Error(`手机上没有安装 ${PACKAGE}`)
  await launchApp(device, options, [])
  await device.screenshot('p5c-a0-dry-home')
  const probes = []
  const record = (label, node) => {
    probes.push(label)
    console.log(`[dry-run] ${label}：OK（${node.x},${node.y}）`)
  }
  record('首页「打开侧栏」', await device.wait('打开侧栏', options.timeoutMs))
  await device.tapMatch('打开侧栏', options.timeoutMs)
  record('侧栏「远程 DSH」', await device.wait('远程 DSH', options.timeoutMs))
  await device.tapMatch('远程 DSH', options.timeoutMs)
  record('远程首页头部（打开菜单）', await device.waitAny(['打开菜单', '添加连接'], options.timeoutMs))
  const connected = await device.waitAny(['在线', '连接中', '离线', '添加连接'], options.timeoutMs, '远程首页连接状态')
  if (connected.desc.includes('添加连接') || connected.text.includes('添加连接')) {
    throw new Error('没有已配对的电脑（远程首页显示「添加连接」）；先在本机 4777 宿主上配对手机')
  }
  record('设备「在线」', await device.wait('在线', options.timeoutMs, '电脑在线'))
  record('远程首页输入条', await focusComposer(device, options, '远程首页输入条'))
  record('远程首页「添加与指令」', await device.wait('添加与指令', 20_000))
  await device.screenshot('p5c-a0-dry-remote-home')
  if (options.session !== undefined) {
    await openExistingSession(device, options)
    record('会话页「返回远程会话」', await device.wait('返回远程会话', options.timeoutMs))
    record('会话页「添加与指令」', await device.wait('添加与指令', 20_000))
    await device.screenshot('p5c-a0-dry-session')
    const adds = device.nodes()
      .filter(node => node.desc.includes('添加与指令') || node.text.includes('添加与指令'))
      .sort((left, right) => right.y - left.y)
    device.tap(adds[0].x, adds[0].y)
    record('「+」弹层「文件」项', await device.waitAny(['添加文件到当前消息', '文件  file'], 60_000))
    await device.screenshot('p5c-a0-dry-add-sheet')
    device.back()
    await sleep(600)
    device.back()
  } else {
    console.log('[dry-run] 未指定 --session：跳过会话页与「+」弹层选择器探测（真实运行默认新建会话）')
  }
  console.log(`\n[dry-run] PASS: ${probes.length} 个导航选择器通过；未发送消息、未挑选附件`)
  return 0
}

/** 主流程；失败时打印可见文本并尽力截图。 */
async function main (argv) {
  const options = parseArgs(argv)
  if (options.help) {
    process.stdout.write(`${usage()}\n`)
    return 0
  }
  options.stagingDir = validateStagingDir(options.stagingDir)
  if (options.input === undefined) options.input = `P5C-A-OK-${Math.floor(Date.now() / 1000)}`
  const device = connectDevice(options)
  const model = device.sh('getprop', 'ro.product.model').trim()
  const release = device.sh('getprop', 'ro.build.version.release').trim()
  console.log(`device: ${model}（Android ${release}） serial=${device.serial}`)
  console.log(`mode: ${options.dryRun ? 'dry-run（仅导航选择器）' : 'acceptance'}；` +
    `输入标记：${options.input}`)
  try {
    const code = options.dryRun ? await runDryRun(device, options) : await runAcceptance(device, options)
    return code
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error(`\nFAIL: ${message}`)
    try {
      device.screenshot('p5c-a4-error')
    } catch (screenshotFailure) {
      console.error(`失败截图未完成：${screenshotFailure instanceof Error ? screenshotFailure.message : String(screenshotFailure)}`)
    }
    try {
      console.error(`当前可见文本：${JSON.stringify(visibleTexts(device.nodes()))}`)
    } catch (nodesFailure) {
      console.error(`界面读取失败：${nodesFailure instanceof Error ? nodesFailure.message : String(nodesFailure)}`)
    }
    return 1
  } finally {
    cleanupStaged(device, options)
  }
}

main(process.argv.slice(2)).then((code) => {
  process.exitCode = code
}).catch((error) => {
  console.error(`acceptance-remote-attachments: ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
})
