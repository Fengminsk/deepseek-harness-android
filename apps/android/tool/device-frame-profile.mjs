#!/usr/bin/env node
/**
 * 真机 60 fps 帧耗时验收驱动。
 *
 * 用 `--target=lib/main_perf.dart` 构建 profile 测量包（生产入口 + 帧统计），
 * 通过 adb 驱动真实远程 DSH 流程，采集 `DSH_FRAME` 日志里的 FrameTiming，
 * 按 60 fps 帧预算（16.667 ms）输出分位数、掉帧比例与 PASS/FAIL。
 *
 * 用法（仓库根）：
 *   node apps/android/tool/device-frame-profile.mjs --build --install
 *   node apps/android/tool/device-frame-profile.mjs --skip-build --scenario remote-session-stream
 *
 * 环境：ANDROID_HOME / GRADLE_USER_HOME 在 --build 时提供给 flutter；adb 需在 PATH
 * 或用 --adb 指定。设备需已与远程宿主配对（场景会直接打开远程会话）。
 */

import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../../..')
const APP_DIR = resolve(ROOT, 'apps/android')
const DEFAULT_APK = resolve(APP_DIR, 'build/app/outputs/flutter-apk/app-profile.apk')
const FLUTTER = resolve(ROOT, '.cache/flutter/bin/flutter.bat')
const PACKAGE = 'com.minnnng.dsh_android'
const ACTIVITY = `${PACKAGE}/.MainActivity`
const DEFAULT_BUDGET_MS = 16.667
/** 采集窗口与场景时间戳的容差：窗口按 1 s 批量上报，边界可能各差一个窗口。 */
const WINDOW_MARGIN_MS = 1500

/** 命令行用法。 */
function usage () {
  return [
    'Usage:',
    '  node apps/android/tool/device-frame-profile.mjs [options]',
    '',
    'Options:',
    '  --build                 构建 lib/main_perf.dart 的 profile APK（默认不构建）',
    '  --install               安装 APK（默认安装，--skip-install 可跳过）',
    '  --skip-build            跳过构建（与 --build 互斥）',
    '  --skip-install          跳过安装',
    '  --apk <path>            APK 路径（默认 build/app/outputs/flutter-apk/app-profile.apk）',
    '  --adb <path>            adb 路径（默认 PATH 里的 adb）',
    '  --device <serial>       adb 设备序列号（默认唯一在线设备）',
    '  --scenario <names>      逗号分隔场景名，默认全部；见 SCENARIOS',
    '  --budget-ms <ms>        帧预算（默认 16.667，即 60 fps）',
    '  --allow-hot             热状态 >=2 时仍继续测量（仅用于厂商热状态误报；报告会标注）',
    '  --output <path>         JSON 报告输出路径（默认 .cache/ui-perf-device/device-frame-profile-<time>.json）',
    '  --help                  打印本用法',
    '',
    'Scenarios:',
    ...Object.entries(SCENARIOS).map(([name, scenario]) => `  ${name.padEnd(22)} ${scenario.description}`),
    '',
  ].join('\n')
}

/** 解析命令行。 */
function parseArgs (argv) {
  const options = {
    build: false,
    install: true,
    apk: DEFAULT_APK,
    adb: 'adb',
    device: undefined,
    scenarios: undefined,
    budgetMs: DEFAULT_BUDGET_MS,
    allowHot: false,
    output: undefined,
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
      case '--build': options.build = true; break
      case '--install': options.install = true; break
      case '--skip-build': options.build = false; break
      case '--skip-install': options.install = false; break
      case '--apk': options.apk = resolve(take(argument)); break
      case '--adb': options.adb = take(argument); break
      case '--device': options.device = take(argument); break
      case '--scenario': options.scenarios = take(argument).split(',').map(name => name.trim()).filter(Boolean); break
      case '--budget-ms': options.budgetMs = Number(take(argument)); break
      case '--allow-hot': options.allowHot = true; break
      case '--output': options.output = resolve(take(argument)); break
      case '--help': options.help = true; break
      default: throw new Error(`unknown option ${argument}`)
    }
  }
  if (!Number.isFinite(options.budgetMs) || options.budgetMs <= 0) throw new Error('--budget-ms must be a positive number')
  for (const name of options.scenarios ?? []) {
    if (!(name in SCENARIOS)) throw new Error(`unknown scenario ${name}`)
  }
  return options
}

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

  /** 设备侧毫秒时间戳（与 App 内 `DateTime.now()` 同源）。 */
  nowMs () { return Number(this.sh('date', '+%s%3N').trim()) }

  /**
   * 读取 Android 热状态（0 none / 1 light / 2 moderate / 3 severe / 4 critical…）。
   * 机型降频会显著抬高帧耗时，测量前必须记录；>=2 时结果不可用于验收。
   */
  thermalStatus () {
    const dump = this.sh('dumpsys', 'thermalservice')
    const match = /Thermal Status:\s*(\d+)/u.exec(dump)
    return match === null ? null : Number(match[1])
  }

  /**
   * 电池温度（摄氏度，一位小数）。部分 ROM 的 Thermal Status 与实测温度不一致，
   * 报告里同时记录原始温度，便于判断能不能把这次测量当作有效数据。
   */
  batteryTemperature () {
    const dump = this.sh('dumpsys', 'battery')
    const match = /temperature:\s*(\d+)/u.exec(dump)
    return match === null ? null : Number(match[1]) / 10
  }

  /** 读取当前界面的节点。 */
  nodes () {
    this.sh('uiautomator', 'dump', '/sdcard/dsh-frame-ui.xml')
    return parseNodes(this.sh('cat', '/sdcard/dsh-frame-ui.xml'))
  }

  /** 在节点里找第一个 content-desc 或 text 包含目标串的节点。 */
  find (match, nodes = this.nodes()) {
    return nodes.find(node => node.desc.includes(match) || node.text.includes(match))
  }

  /** 等待节点出现；失败时输出当前可见文本方便定位。 */
  async wait (match, timeoutMs, label = match) {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      const found = this.find(match)
      if (found !== undefined) return found
      await sleep(400)
    }
    const visible = this.nodes().map(node => node.desc || node.text).filter(Boolean).slice(0, 40)
    throw new Error(`timed out waiting for ${JSON.stringify(label)}; visible: ${JSON.stringify(visible)}`)
  }

  /** 等待任意一个目标出现。 */
  async waitAny (matches, timeoutMs, label = matches.join('|')) {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      const nodes = this.nodes()
      for (const match of matches) {
        const found = nodes.find(node => node.desc.includes(match) || node.text.includes(match))
        if (found !== undefined) return found
      }
      await sleep(400)
    }
    throw new Error(`timed out waiting for any of ${JSON.stringify(label)}`)
  }

  tap (x, y) { this.sh('input', 'tap', String(x), String(y)) }

  /** 点按第一个匹配节点。 */
  async tapMatch (match, timeoutMs = 8000) {
    const node = await this.wait(match, timeoutMs)
    this.tap(node.x, node.y)
    return node
  }

  /** 滑动一次。 */
  swipe (x1, y1, x2, y2, durationMs = 300) {
    this.sh('input', 'swipe', String(x1), String(y1), String(x2), String(y2), String(durationMs))
  }

  /** 输入 ASCII 文本（URL/英文命令）；中文场景不要用本方法。 */
  inputText (text) { this.sh('input', 'text', text) }

  /** 返回键。 */
  back () { this.sh('input', 'keyevent', '4') }
}

/** 可复用的等待。 */
function sleep (ms) { return new Promise(resolveSleep => setTimeout(resolveSleep, ms)) }

/** 启动 App 并等待首页可交互；返回设备时间戳。 */
async function launchApp (device) {
  device.sh('am', 'force-stop', PACKAGE)
  await sleep(500)
  device.adb('logcat', '-c')
  device.sh('am', 'start', '-W', '-n', ACTIVITY)
  await device.wait('打开侧栏', 180_000, 'App 首页')
  return device.nowMs()
}

/** 打开侧栏并进入远程 DSH 首页，等待连接就绪。 */
async function openRemoteHome (device) {
  await device.tapMatch('打开侧栏')
  await device.tapMatch('远程 DSH')
  await device.waitAny(['在线', '添加连接'], 120_000, '远程连接就绪')
}

/** 从远程首页打开指定会话。 */
async function openRemoteSession (device, titleFragment) {
  await device.tapMatch(titleFragment)
  await device.wait('返回远程会话', 30_000, '远程会话页')
}

/** 找到会话输入框并聚焦。 */
async function focusComposer (device) {
  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    const nodes = device.nodes()
    const field = nodes.find(node => node.class === 'android.widget.EditText' && node.y > 1200)
    if (field !== undefined) {
      device.tap(field.x, field.y)
      await sleep(600)
      return
    }
    await sleep(300)
  }
  throw new Error('remote session composer not found')
}

/** 场景：远程首页滚动。 */
const remoteHomeScenario = {
  description: '远程 DSH 首页：项目/会话列表上下滚动',
  // 连续滚动场景以「是否跑满 60 fps」判定；消息流式/终端这类按需渲染的场景
  // 只按帧耗时与掉帧比例判定（静止时本来就不出帧）。
  requireFps: true,
  async prepare (device) {
    await openRemoteHome(device)
    await sleep(1500)
  },
  async run (device) {
    for (let i = 0; i < 8; i += 1) {
      device.swipe(540, 1700, 540, 900, 260)
      await sleep(160)
    }
    for (let i = 0; i < 8; i += 1) {
      device.swipe(540, 900, 540, 1700, 260)
      await sleep(160)
    }
  },
}

/** 场景：远程会话流式回复。 */
const remoteSessionScenario = {
  description: '远程会话：发送消息并测量流式回复渲染',
  async prepare (device) {
    await openRemoteHome(device)
    await openRemoteSession(device, 'OK')
    await focusComposer(device)
    device.inputText('Write a 400 word English essay about rendering performance.')
    await sleep(1200)
  },
  async run (device) {
    await device.tapMatch('发送', 10_000)
    await sleep(18_000)
  },
}

/** 场景：远程终端滚动输出。 */
const remoteTerminalScenario = {
  description: '远程终端：在 PC shell 连续执行 dir 并测量输出渲染',
  async prepare (device) {
    await openRemoteHome(device)
    await openRemoteSession(device, 'OK')
    await device.tapMatch('更多会话操作')
    await device.tapMatch('终端', 10_000)
    await device.wait('新建终端', 30_000, '终端页')
    await device.tapMatch('新建终端')
    await device.waitAny(['运行中', '选择 Shell'], 30_000, '终端已创建')
    await focusComposer(device)
  },
  async run (device) {
    for (let i = 0; i < 3; i += 1) {
      device.inputText('dir')
      await sleep(300)
      const nodes = device.nodes()
      const send = nodes.find(node => node.desc.includes('发送回车'))
      if (send !== undefined) device.tap(send.x, send.y)
      await sleep(1500)
    }
    await sleep(1000)
  },
}

/** 场景：远程电脑文件浏览滚动。 */
const remoteFilesScenario = {
  description: '远程电脑文件：从首页菜单进入并滚动文件列表',
  requireFps: true,
  async prepare (device) {
    await openRemoteHome(device)
    await device.tapMatch('远程 DSH，排序与设置菜单')
    await sleep(800)
    const menu = device.nodes()
    const files = menu.find(node => node.desc.includes('电脑文件') || node.text.includes('电脑文件'))
    // 菜单项可能以文本节点呈现，回退：关闭菜单并直接用内容描述。
    if (files === undefined) {
      device.back()
      throw new Error('电脑文件 menu item not found')
    }
    device.tap(files.x, files.y)
    await device.wait('返回上级', 30_000, '电脑文件页')
    await sleep(1200)
  },
  async run (device) {
    for (let i = 0; i < 6; i += 1) {
      device.swipe(540, 1700, 540, 900, 260)
      await sleep(160)
    }
    for (let i = 0; i < 6; i += 1) {
      device.swipe(540, 900, 540, 1700, 260)
      await sleep(160)
    }
  },
}

/** 全部场景。 */
const SCENARIOS = {
  'remote-home': remoteHomeScenario,
  'remote-session-stream': remoteSessionScenario,
  'remote-terminal': remoteTerminalScenario,
  'remote-files': remoteFilesScenario,
}

/** 计算分位数（输入会被排序）。 */
function percentile (values, ratio) {
  if (values.length === 0) return 0
  const sorted = [...values].sort((left, right) => left - right)
  return sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * ratio))]
}

/** 从 logcat 里解析 DSH_FRAME 窗口。 */
function parseFrameWindows (logcat) {
  const windows = []
  let ready = false
  for (const line of logcat.split(/\r?\n/u)) {
    if (line.includes('DSH_FRAME_READY')) {
      ready = true
      continue
    }
    const marker = line.indexOf('DSH_FRAME {')
    if (marker < 0) continue
    const payload = line.slice(marker + 'DSH_FRAME '.length).trim()
    try {
      windows.push(JSON.parse(payload))
    } catch {
      // 截断/混入其它日志的行直接丢弃：下一次窗口会覆盖同一段时间。
    }
  }
  return { windows, ready }
}

/** 汇总一个场景时间窗内的帧统计。 */
function summarizeScenario (windows, startMs, endMs, budgetMs) {
  const build = []
  const raster = []
  const total = []
  let observedFrom = Number.POSITIVE_INFINITY
  let observedTo = 0
  let activeWindows = 0
  for (const window of windows) {
    const at = Number(window.at)
    if (!Number.isFinite(at) || at < startMs - WINDOW_MARGIN_MS || at > endMs + WINDOW_MARGIN_MS) continue
    observedFrom = Math.min(observedFrom, at - 1000)
    observedTo = Math.max(observedTo, at)
    const frameCount = Array.isArray(window.s) ? window.s.length : 0
    if (frameCount > 0) activeWindows += 1
    for (const value of window.b ?? []) build.push(Number(value))
    for (const value of window.r ?? []) raster.push(Number(value))
    for (const value of window.s ?? []) total.push(Number(value))
  }
  const budgetMicros = budgetMs * 1000
  const over = total.filter(value => value > budgetMicros).length
  const buildOver = build.filter(value => value > budgetMicros).length
  const rasterOver = raster.filter(value => value > budgetMicros).length
  const durationMs = Number.isFinite(observedFrom) ? Math.max(0, observedTo - observedFrom) : 0
  // 交互期间的实际帧率：只统计有渲染的窗口（空闲窗口不渲染是正常的，不该拉低 fps）。
  const activeFps = activeWindows === 0 ? 0 : total.length / activeWindows
  return {
    frames: total.length,
    durationMs,
    activeWindows,
    activeFps,
    fps: durationMs === 0 ? 0 : total.length / (durationMs / 1000),
    buildP50: percentile(build, 0.5),
    buildP95: percentile(build, 0.95),
    buildMax: Math.max(0, ...build),
    rasterP50: percentile(raster, 0.5),
    rasterP95: percentile(raster, 0.95),
    rasterMax: Math.max(0, ...raster),
    totalP50: percentile(total, 0.5),
    totalP95: percentile(total, 0.95),
    totalP99: percentile(total, 0.99),
    totalMax: Math.max(0, ...total),
    overBudget: over,
    overBudgetRatio: total.length === 0 ? 0 : over / total.length,
    buildOver,
    rasterOver,
  }
}

/** 构建测量包（profile + main_perf.dart）。 */
function buildApk (options) {
  if (options.build) {
    const result = spawnSync(FLUTTER, [
      'build', 'apk', '--profile', '--target', 'lib/main_perf.dart',
      '--target-platform', 'android-arm64', '--no-pub',
    ], { cwd: APP_DIR, stdio: 'inherit', env: process.env })
    if (result.status !== 0) throw new Error(`flutter build failed with ${result.status}`)
  }
  if (!existsSync(options.apk)) {
    throw new Error(`APK not found: ${options.apk}; pass --build or --apk`)
  }
}

/** 安装测量包。 */
function installApk (device, options) {
  device.adb('install', '-r', options.apk)
}

/** 跑一个场景并返回结果。 */
async function runScenario (device, name, scenario, budgetMs) {
  await launchApp(device)
  await scenario.prepare(device)
  // 场景准备常伴随导航动画/键盘弹出/首次布局；先静置到稳定再开始计时。
  await sleep(2000)
  const startedAt = device.nowMs()
  await scenario.run(device)
  await sleep(1200)
  const endedAt = device.nowMs()
  const logcat = device.adb('logcat', '-d')
  const { windows, ready } = parseFrameWindows(logcat)
  if (!ready) throw new Error(`${name}: DSH_FRAME_READY missing from logcat (is this the perf APK?)`)
  const summary = summarizeScenario(windows, startedAt, endedAt, budgetMs)
  return { name, description: scenario.description, startedAt, endedAt, summary }
}

/** 主流程。 */
async function main (argv) {
  const options = parseArgs(argv)
  if (options.help === true) {
    process.stdout.write(`${usage()}\n`)
    return 0
  }
  buildApk(options)
  const device = new Device(options.adb, options.device)
  console.log(`device: ${device.adb('shell', 'getprop', 'ro.product.model').trim()} ` +
    `(${device.adb('shell', 'getprop', 'ro.build.version.release').trim()})`)
  // 降频会让帧耗时整体抬高，测量前先记录；>=2（moderate/severe）的结果默认不用于验收，
  // `--allow-hot` 仅供「厂商热状态误报但实测温度正常」的现场诊断使用。
  const thermalBefore = device.thermalStatus()
  const batteryTemperatureBefore = device.batteryTemperature()
  if (thermalBefore !== null && thermalBefore >= 2 && options.allowHot !== true) {
    console.log(`WARN: device thermal status is ${thermalBefore} (>=2) — 结果不可用于验收，请先熄屏冷却`
      + '（确认是厂商误报可加 --allow-hot 并人工核对报告里的电池温度）')
  }
  if (options.install) installApk(device, options)
  const names = options.scenarios ?? Object.keys(SCENARIOS)
  const results = []
  for (const name of names) {
    process.stdout.write(`\n▶ ${name}: ${SCENARIOS[name].description}\n`)
    const result = await runScenario(device, name, SCENARIOS[name], options.budgetMs)
    results.push(result)
    const summary = result.summary
    console.log(`  frames=${summary.frames} activeFps=${summary.activeFps.toFixed(1)} ` +
      `(interactive windows ${summary.activeWindows}/${Math.round(summary.durationMs / 1000)}) ` +
      `total p50/p95/p99=${(summary.totalP50 / 1000).toFixed(2)}/${(summary.totalP95 / 1000).toFixed(2)}/` +
      `${(summary.totalP99 / 1000).toFixed(2)} ms (max ${(summary.totalMax / 1000).toFixed(2)}) ` +
      `build p95=${(summary.buildP95 / 1000).toFixed(2)} raster p95=${(summary.rasterP95 / 1000).toFixed(2)} ` +
      `over=${summary.overBudget} (${(summary.overBudgetRatio * 100).toFixed(1)}%)`)
  }
  const stamp = new Date().toISOString().replaceAll(/[:.]/gu, '-')
  const output = options.output ?? resolve(ROOT, `.cache/ui-perf-device/device-frame-profile-${stamp}.json`)
  mkdirSync(dirname(output), { recursive: true })
  const thermalAfter = device.thermalStatus()
  const batteryTemperatureAfter = device.batteryTemperature()
  const report = {
    measuredAt: new Date().toISOString(),
    device: device.adb('shell', 'getprop', 'ro.product.model').trim(),
    thermalBefore,
    thermalAfter,
    batteryTemperatureBefore,
    batteryTemperatureAfter,
    thermalOverride: options.allowHot === true,
    apk: options.apk,
    budgetMs: options.budgetMs,
    scenarios: results,
  }
  writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`)
  console.log(`\nreport: ${output}`)
  if (thermalBefore !== null && thermalBefore >= 2 && options.allowHot !== true) {
    console.log(`FAIL: 设备热状态 ${thermalBefore} >= 2（降频中），本次测量不作为验收依据；熄屏冷却后重跑`)
    return 1
  }
  if (options.allowHot === true && thermalBefore !== null && thermalBefore >= 2) {
    console.log(`WARN: --allow-hot 覆盖了热状态 ${thermalBefore}；电池温度 ${batteryTemperatureBefore}°C，`
      + '仅在没有其它测量手段时参考')
  }
  const failed = results.filter((result) => {
    const scenario = SCENARIOS[result.name]
    return result.summary.frames === 0 ||
      result.summary.totalP95 > options.budgetMs * 1000 ||
      result.summary.overBudgetRatio > 0.01 ||
      (scenario.requireFps === true && result.summary.frames >= 120 &&
        result.summary.activeFps < 55)
  })
  if (failed.length > 0) {
    console.log(`FAIL: ${failed.map(result => result.name).join(', ')} ` +
      `(预算 ${options.budgetMs} ms；p95 超预算或掉帧 >1%；连续滚动场景还要求交互帧率 ≥55 fps)`)
    return 1
  }
  console.log(`PASS: 全部场景 p95 ≤ ${options.budgetMs} ms、掉帧 ≤ 1%；滚动场景 ≥55 fps`)
  return 0
}

main(process.argv.slice(2)).then((code) => {
  process.exitCode = code
}).catch((error) => {
  console.error(`device-frame-profile: ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
})
