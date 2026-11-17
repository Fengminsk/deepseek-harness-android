/**
 * 长期配对自检：证明 `../src/pairing.ts` 的有效期上限、`Config` 的 `pairingLongTerm`，
 * 以及 `../src/index.ts` 的长期配对自动续开组合函数成立。
 *
 * 运行：`node --import tsx/esm apps/remote-host/scripts/pairing-longterm-selfcheck.ts`
 * 退出码：全部通过 0，任一断言失败 1。脚本不监听端口、不写文件、不需要 DSH_HOME 或 TLS
 * 材料：窗口用 `PairingWindow` 的真实实现（假时钟），配对面用内存假实现。
 *
 * 覆盖：
 * 1. `Config.pairingTtlMs` 默认值不变（120 s）、接受 90 天上限与插件用的 30 天值，
 *    拒绝超过上限、过小与非整数；`Config.pairingLongTerm` 默认 false、接受 boolean；
 * 2. `PairingWindow.open` 硬上限与 `Config` 一致：90 天可开、90 天 + 1 ms 拒绝、非正整数拒绝；
 *    90 天窗口仍是单次有效（兑换一次后关闭）；
 * 3. `withLongTermPairingReopen`：配对成功 → 先清旧票据再自动开下一个窗口（同 TTL、新 token），
 *    新 token 能继续配对下一台，旧 token 失效；
 * 4. 失败不续开：兑换失败时既不重开窗口也不清票据；
 * 5. 非长期模式不续开：兑换成功只清票据，保持既有单次语义；
 * 6. 重开失败不影响已经成功的配对：仍然返回成功结果，只记一条 `pairing-longterm-reopen-failed` warn；
 * 7. 宿主包根导出的 `renderPairingQrSvg` 是纯函数：返回与矩阵尺寸一致的内联 SVG。
 *
 * 为什么不用真实宿主：`startRemoteHost` 需要 TLS 材料、设备表与运行时门面；这里验证的
 * 是长期配对与 TTL 上限本身的逻辑，宿主装配只把该组合函数接在配对上。wss/TLS 全链路由
 * `smoke-remote-host.ts` 覆盖。
 * @module @deepseek-ai/dsh-remote-host/scripts/pairing-longterm-selfcheck
 */

import { randomBytes } from 'node:crypto'
import {
  Config,
  renderPairingQrSvg,
  withLongTermPairingReopen,
  type LongTermPairingReopenOptions,
} from '../src/index.ts'
import { MAXIMUM_PAIRING_TTL_MS, PairingWindow, pairUrl } from '../src/pairing.ts'
import { encodeQrMatrix } from '../src/pairing-qr.ts'
import type { RemoteLogRecord, RemotePairOutcome, RemotePairRequest, RemotePairingSurface } from '../src/server.ts'

/** 自检的起始时钟（Unix 毫秒）。 */
const START_TIME = 1_700_000_000_000

/** 插件（设备互联）实际会写进 overlay 的 30 天窗口。 */
const PLUGIN_PAIRING_TTL_MS = 30 * 24 * 60 * 60 * 1000

/** 设备令牌形态（43 字符 base64url）；假实现只用于断言返回值原样透传。 */
const SAMPLE_DEVICE_TOKEN = 'A'.repeat(43)

/** 一个配对请求的固定内容；只有 token 会影响结论。 */
function pairingRequest(token: string): RemotePairRequest {
  return { token, deviceLabel: '自检手机', appVersion: '0.1.0+selfcheck', peer: '127.0.0.1' }
}

/** 一条断言失败。 */
class SelfCheckFailure extends Error {}

/**
 * 断言为真；调用点之后的类型收窄继续生效。
 * @param condition - 断言条件，任意真值表达式。
 * @param message - 失败时写进输出的中文说明。
 * @throws 条件不成立时抛出。
 */
function check(condition: unknown, message: string): asserts condition {
  if (condition) return
  throw new SelfCheckFailure(message)
}

/**
 * 把任意抛出值收敛成一行描述。
 * @param error - 任意抛出值。
 * @returns `name: message`；非 Error 直接字符串化。
 */
function describeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`
  return String(error)
}

/**
 * 断言一次调用抛错，且错误文本包含指定片段。
 * @param run - 待执行的调用。
 * @param fragment - 期望出现在错误文本里的片段。
 * @param label - 失败说明里的场景名。
 */
function checkThrows(run: () => unknown, fragment: string, label: string): void {
  try {
    run()
  } catch (error) {
    const message = describeError(error)
    check(message.includes(fragment), `${label} 的错误文本里没有「${fragment}」：${message}`)
    return
  }
  throw new SelfCheckFailure(`${label} 没有抛错（期望拒绝）`)
}

/**
 * 从 `unknown` 收窄成声明类型，用于构造「配置里写错类型」的输入。
 *
 * 配置是加载期边界：schema 必须拒绝与声明类型不符的值，所以这里刻意绕开静态类型构造非法输入。
 * @param value - 测试注入的值。
 * @returns 同一份值，按 `boolean` 交给 `Config`。
 */
function untrustedBoolean(value: unknown): boolean {
  return value as boolean
}

/** 逐项结果统计。 */
let passed = 0
let total = 0
const failures: string[] = []

/**
 * 跑一项断言并打印结果。失败不中断后续项，但会计入退出码。
 * @param label - 中文说明。
 * @param run - 断言本体，返回通过时展示的细节。
 */
async function step(label: string, run: () => Promise<string>): Promise<void> {
  total += 1
  try {
    const detail = await run()
    passed += 1
    console.log(`PASS  ${total}. ${label}：${detail}`)
  } catch (error) {
    const detail = describeError(error)
    failures.push(`${label}：${detail}`)
    console.log(`FAIL  ${total}. ${label}：${detail}`)
  }
}

/**
 * 构造一个基于真实 `PairingWindow` 的假配对面。
 *
 * 兑换成功时签发一个占位设备 id / 令牌，让 `withLongTermPairingReopen` 能走真实成功分支；
 * 失败映射成 403，与宿主 `createPairingSurface` 的状态码语义一致。
 * @param window - 真实配对窗口。
 * @param now - 假时钟。
 * @returns 只依赖窗口的配对面。
 */
function createWindowSurface(window: PairingWindow, now: () => number): RemotePairingSurface {
  let issued = 0
  return {
    caCertificateDer: Buffer.from([0x30, 0x82, 0x00, 0x01]),
    async redeem(request: RemotePairRequest): Promise<RemotePairOutcome> {
      const redemption = window.redeem(request.token, request.peer)
      if (!redemption.ok) {
        return { ok: false, status: 403, message: '配对窗口已经关闭或过期。' }
      }
      issued += 1
      return {
        ok: true,
        deviceId: issued.toString(16).padStart(32, '0'),
        deviceToken: SAMPLE_DEVICE_TOKEN,
        expiresAt: now() + 60_000,
      }
    },
  }
}

/**
 * 自检主体：Config 边界 → PairingWindow 上限 → 长期配对组合函数 → 导出纯函数。
 * @returns 进程退出码：全部通过为 0。
 */
async function main(): Promise<number> {
  const fakeNow = START_TIME
  const clock = (): number => fakeNow

  await step('Config 默认值不变，并接受 90 天 / 30 天窗口与 pairingLongTerm', async () => {
    // `Config` 的类型是「已解析配置」（字段必填）：无参调用得到默认值，再以完整对象覆盖字段。
    const defaults = Config()
    check(defaults.pairingTtlMs === 120_000, `pairingTtlMs 默认值期望 120000，实际 ${defaults.pairingTtlMs}`)
    check(defaults.pairingLongTerm === false, `pairingLongTerm 默认值期望 false，实际 ${String(defaults.pairingLongTerm)}`)
    const maximum = Config({ ...defaults, pairingTtlMs: MAXIMUM_PAIRING_TTL_MS })
    check(maximum.pairingTtlMs === MAXIMUM_PAIRING_TTL_MS, 'Config 不接受 90 天窗口')
    const plugin = Config({ ...defaults, pairingTtlMs: PLUGIN_PAIRING_TTL_MS, pairingLongTerm: true })
    check(plugin.pairingTtlMs === PLUGIN_PAIRING_TTL_MS, 'Config 不接受插件用的 30 天窗口')
    check(plugin.pairingLongTerm === true, 'Config 不接受 pairingLongTerm: true')
    return `默认 ${defaults.pairingTtlMs} ms / longTerm=${String(defaults.pairingLongTerm)}；90 天与 30 天都合法`
  })

  await step('Config 拒绝越界窗口与非法 pairingLongTerm', async () => {
    const defaults = Config()
    checkThrows(() => Config({ ...defaults, pairingTtlMs: MAXIMUM_PAIRING_TTL_MS + 1 }), 'pairingTtlMs', '超过 90 天上限')
    checkThrows(() => Config({ ...defaults, pairingTtlMs: 999 }), 'pairingTtlMs', '小于 1 s 下限')
    checkThrows(() => Config({ ...defaults, pairingTtlMs: 1_000.5 }), 'pairingTtlMs', '非整数窗口')
    const injectedLongTerm = untrustedBoolean('yes')
    checkThrows(
      () => Config({ ...defaults, pairingLongTerm: injectedLongTerm }),
      'pairingLongTerm',
      '非 boolean 的 pairingLongTerm',
    )
    return `上限 ${MAXIMUM_PAIRING_TTL_MS} ms 之外、< 1 s 与非法类型都在加载期失败`
  })

  await step('PairingWindow 硬上限同步放宽到 90 天，窗口仍单次有效', async () => {
    const window = new PairingWindow({ now: clock })
    const opened = window.open(MAXIMUM_PAIRING_TTL_MS)
    check(opened.expiresAt === fakeNow + MAXIMUM_PAIRING_TTL_MS, '90 天窗口的过期时间不符')
    check(window.redeem(opened.token).ok, '90 天窗口的令牌第一次兑换失败')
    check(!window.redeem(opened.token).ok, '90 天窗口的令牌可以被兑换第二次（应单次有效）')
    checkThrows(() => window.open(MAXIMUM_PAIRING_TTL_MS + 1), String(MAXIMUM_PAIRING_TTL_MS), '超过 90 天的窗口')
    checkThrows(() => window.open(0), '有效期', '0 毫秒窗口')
    checkThrows(() => window.open(1.5), '有效期', '小数窗口')
    return `open(${MAXIMUM_PAIRING_TTL_MS}) 可开且单次有效；+1 ms / 0 / 1.5 都被拒绝`
  })

  await step('长期配对：成功后自动开下一个窗口（新 token 能继续配对，旧 token 失效）', async () => {
    const window = new PairingWindow({ now: clock })
    const openedTokens: string[] = [window.open(MAXIMUM_PAIRING_TTL_MS).token]
    // 通过函数读取长度：`reopen` 回调会在其它调用期间追加 token，静态收窄会误判后续比较。
    const openedCount = (): number => openedTokens.length
    const events: string[] = []
    const logs: RemoteLogRecord[] = []
    const surface = withLongTermPairingReopen(createWindowSurface(window, clock), {
      longTerm: true,
      onRedemptionConsumed: () => {
        events.push('consumed')
      },
      reopen: () => {
        events.push('reopen')
        openedTokens.push(window.open(MAXIMUM_PAIRING_TTL_MS).token)
      },
      log: (record) => {
        logs.push(record)
      },
    })
    const firstToken = openedTokens[0]
    check(firstToken !== undefined, '没有拿到第一张令牌')
    const first = await surface.redeem(pairingRequest(firstToken))
    check(first.ok, `第一次配对失败：${first.ok ? '' : first.message}`)
    check(events.join(',') === 'consumed,reopen', `成功后的事件顺序期望 consumed,reopen，实际 ${events.join(',')}`)
    check(openedCount() === 2, `配对成功后应自动开出第 2 个窗口，实际 ${openedCount()} 个`)
    const secondToken = openedTokens[1]
    check(secondToken !== undefined && secondToken !== firstToken, '自动重开的窗口没有换新 token')
    const second = await surface.redeem(pairingRequest(secondToken))
    check(second.ok, `用自动重开的新 token 配第二台设备失败：${second.ok ? '' : second.message}`)
    check(openedCount() === 3, '第二台设备配对成功后没有继续自动开窗口')
    const stale = await surface.redeem(pairingRequest(firstToken))
    check(!stale.ok, '旧 token 在长期模式下仍能兑换（应随窗口消费失效）')
    check(openedCount() === 3, '失败的兑换不应再开窗口')
    check(logs.length === 0, `成功路径不应写日志，实际 ${logs.length} 条`)
    return '成功 2 次 → 自动开出 3 个窗口（token 各不同），旧 token 失效且失败不续开'
  })

  await step('长期配对：兑换失败不重开、不清票据', async () => {
    const window = new PairingWindow({ now: clock })
    const opened = window.open(MAXIMUM_PAIRING_TTL_MS)
    const events: string[] = []
    const surface = withLongTermPairingReopen(createWindowSurface(window, clock), {
      longTerm: true,
      onRedemptionConsumed: () => {
        events.push('consumed')
      },
      reopen: () => {
        events.push('reopen')
      },
      log: () => undefined,
    })
    const rejected = await surface.redeem(pairingRequest('z'.repeat(43)))
    check(!rejected.ok, '错误令牌的兑换没有被拒绝')
    check(events.length === 0, `失败的兑换产生了副作用：${events.join(',')}`)
    check(window.redeem(opened.token).ok, '兑换失败后原窗口的令牌反而不可用了')
    return '错误令牌 → 403 语义，未清票据、未开新窗口；原 ticket 仍可兑换一次'
  })

  await step('非长期模式：成功后只清票据，不自动重开', async () => {
    const window = new PairingWindow({ now: clock })
    const opened = window.open(MAXIMUM_PAIRING_TTL_MS)
    const events: string[] = []
    const surface = withLongTermPairingReopen(createWindowSurface(window, clock), {
      longTerm: false,
      onRedemptionConsumed: () => {
        events.push('consumed')
      },
      reopen: () => {
        events.push('reopen')
      },
      log: () => undefined,
    })
    const outcome = await surface.redeem(pairingRequest(opened.token))
    check(outcome.ok, '非长期模式的正常兑换失败')
    check(events.join(',') === 'consumed', `非长期模式的事件期望只有 consumed，实际 ${events.join(',')}`)
    check(!window.redeem(opened.token).ok, '非长期模式兑换后窗口没有被消费')
    return '兑换成功 → 只调 onRedemptionConsumed，窗口保持单次有效语义'
  })

  await step('重开失败不影响已成功的配对，只记 warn', async () => {
    const window = new PairingWindow({ now: clock })
    const opened = window.open(MAXIMUM_PAIRING_TTL_MS)
    const logs: RemoteLogRecord[] = []
    const options: LongTermPairingReopenOptions = {
      longTerm: true,
      onRedemptionConsumed: () => undefined,
      reopen: () => {
        throw new Error('自检注入的重开失败')
      },
      log: (record) => {
        logs.push(record)
      },
    }
    const issued = await withLongTermPairingReopen(createWindowSurface(window, clock), options)
      .redeem(pairingRequest(opened.token))
    check(issued.ok, '重开失败把已经成功的配对也变成了失败')
    const warn = logs.find(record => record.event === 'pairing-longterm-reopen-failed')
    check(warn !== undefined, '重开失败没有写 pairing-longterm-reopen-failed 日志')
    check(warn.level === 'warn', `重开失败日志级别期望 warn，实际 ${warn.level}`)
    check(String(warn.fields?.error).includes('自检注入的重开失败'), '重开失败日志没有记录错误原因')
    return '重开抛错 → 配对结果仍成功（设备已签发）+ 一条 warn'
  })

  await step('包根导出的 renderPairingQrSvg 是纯函数，SVG 与矩阵尺寸一致', async () => {
    const instanceId = randomBytes(32).toString('hex')
    const token = randomBytes(32).toString('base64url')
    const url = pairUrl('wss://192.168.5.21:4777', instanceId, token)
    const svg = renderPairingQrSvg(url)
    check(svg.startsWith('<svg '), 'renderPairingQrSvg 没有返回内联 SVG')
    check(svg.includes('shape-rendering="crispEdges"'), 'renderPairingQrSvg 的 SVG 缺少 crispEdges')
    check(svg.includes('aria-label="配对二维码"'), 'renderPairingQrSvg 的 SVG 缺少无障碍标签')
    // 与页面内联二维码同一份渲染：安静区 4 个模块，viewBox 边长 = 矩阵边长 + 8。
    const side = encodeQrMatrix(url).size + 8
    check(svg.includes(`viewBox="0 0 ${side} ${side}"`), `renderPairingQrSvg 的 viewBox 不是 0 0 ${side} ${side}`)
    check(svg === renderPairingQrSvg(url), '同一链接两次渲染结果不一致（应确定性）')
    return `${url.length} 字符配对链接 → SVG ${svg.length} 字节，viewBox 边长 ${side}`
  })

  console.log('')
  if (failures.length > 0) {
    console.log(`FAIL  ${passed}/${total} 项通过，${failures.length} 项失败`)
    for (const failure of failures) console.log(`  - ${failure}`)
    return 1
  }
  console.log(`PASS  ${passed}/${passed} 项全部通过（TTL 上限 + pairingLongTerm 自动续开 + 二维码导出）`)
  return 0
}

// 兜底看门狗：任何一步把句柄留在事件循环里时，不能让自检一直挂着。
const watchdog = setTimeout(() => {
  console.error('FAIL  长期配对自检在 60 s 内没有结束，判定有定时器未收尾。')
  process.exit(1)
}, 60_000)
watchdog.unref()

process.exitCode = await main().catch((error: unknown) => {
  console.error(`FAIL  自检主体抛出：${describeError(error)}`)
  return 1
})
