/**
 * 桌面宿主（`platform: desktop`）的终端适配器：把 `terminal-controller` 的双工 `attach` 流
 * 包装成 App 本地终端使用的请求/响应方法。
 *
 * App 只看到与本地 Android 实现相同的 `terminal.*` 方法面（list/shells/create/read/write/
 * resize/rename/close）；上行输入、快照、逐条确认与 retain 保留流全部留在这里。每个终端
 * 在宿主侧保留一条 attachment 与一个 headless xterm 投影，`read` 与中断线重连后的恢复都从
 * 该投影回答（设计见 `apps/android/docs/remote-dsh/terminal-design.md` §3）。
 *
 * 本模块不引入新的 Node 内建模块：`terminals.mjs` 已随 App runtime bundle 打包，Android 上
 * 只是不会走到这个类。
 */

import { observeTerminalDisplay, projectTerminalView, screenFactory } from './terminals.mjs'

/** 单次输入上限（App 与本地 Android 终端共享的协议常量，不是部署配置）。 */
const MAX_INPUT_BYTES = 65536
/** 一条 attachment 内尚未确认的输入字节上限：与 controller follower 队列的 2 MiB 同值。 */
const MAX_PENDING_INPUT_BYTES = 2 * 1024 * 1024
/** 等待 controller 确认输入与尺寸的宿主侧上限（设计 §3）。 */
const ACK_TIMEOUT_MS = 5000
/** 打开 attachment 并收到首帧快照的等待上限；超时后下一次 read 重新 attach。 */
const ATTACH_TIMEOUT_MS = 15000
/** 关闭/卸载终端时等待 attachment 收尾的上限，避免 Agent 恢复卡住宿主清理。 */
const CLOSE_TIMEOUT_MS = 3000
/** 终端与 Session 身份的线上语法，与本地 Android 实现一致。 */
const IDENTITY_PATTERN = /^[\w-]{1,128}$/u

/**
 * 构造带 `code`/`details` 的失败。门面 `remoteFailure` 把这两个字段原样放进
 * `_pocket_error`，App 按协议 §9.2 的词汇表展示。
 * @param {string} code 协议词汇表的错误码
 * @param {string} message 可直接展示的中文说明
 * @param {object} [details] 该错误码的结构化补充
 * @returns {Error} 带 code/details 的错误
 */
function terminalFailure(code, message, details) {
  const error = new Error(message)
  error.code = code
  if (details !== undefined) error.details = details
  return error
}

/**
 * 校验线上身份字段。
 * @param {unknown} value 身份值
 * @param {string} label 失败信息里的字段名
 * @returns {string} 合法身份
 */
function identity(value, label) {
  if (typeof value !== 'string' || !IDENTITY_PATTERN.test(value)) {
    throw terminalFailure('gateway/bad-request', `Invalid ${label}`)
  }
  return value
}

/**
 * 校验终端尺寸；范围与本地 Android 终端一致。
 * @param {unknown} cols 列数
 * @param {unknown} rows 行数
 * @returns {void}
 */
function dimensions(cols, rows) {
  if (!Number.isSafeInteger(cols) || cols < 2 || cols > 500
    || !Number.isSafeInteger(rows) || rows < 1 || rows > 200) {
    throw terminalFailure('gateway/bad-request', 'Invalid terminal dimensions')
  }
}

/**
 * 校验终端显示名；规则与本地 Android 终端一致（1–64 个可见字素，无控制字符）。
 * @param {unknown} value 显示名
 * @returns {string} 合法显示名
 */
function terminalName(value) {
  const graphemes = typeof value === 'string'
    ? [...new Intl.Segmenter('und', { granularity: 'grapheme' }).segment(value)].length : 0
  if (typeof value !== 'string' || value !== value.trim()
    || !value || graphemes > 64
    || /[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/u.test(value)) {
    throw terminalFailure('gateway/bad-request', 'Terminal name must be 1–64 visible characters')
  }
  return value
}

/**
 * 把 controller 的终端信息映射成 App 本地实现返回的字段。
 * @param {object} info controller 的 `WebTerminalInfo`
 * @param {string} sessionId 所属 Session
 * @returns {object} App 看到的终端信息
 */
function appInfo(info, sessionId) {
  return {
    id: info.id,
    sessionId,
    cwd: info.cwd,
    name: info.title,
    shellId: info.shell.path,
    cols: info.cols,
    rows: info.rows,
    state: info.state,
    exitCode: info.exitCode,
    ...(info.error === undefined ? {} : { error: info.error }),
  }
}

/**
 * attachment 的上行队列：controller 通过 `invocation.uplink()` 消费，`write`/`resize` 同步入队。
 * 队列本身不设上限，调用方在入队前按 {@link MAX_PENDING_INPUT_BYTES} 拒绝积压。
 * @returns {AsyncIterable<object> & { push: (item: object) => void, end: (error?: Error) => void }} 队列
 */
function createInputQueue() {
  const items = []
  const waiters = []
  let closed = false
  let failure

  const queue = {
    push(item) {
      if (closed) throw failure ?? terminalFailure('terminal/unavailable', 'Terminal attachment has ended')
      const waiter = waiters.shift()
      if (waiter !== undefined) waiter.resolve({ done: false, value: item })
      else items.push(item)
    },
    end(error) {
      if (closed) return
      closed = true
      failure = error
      for (const waiter of waiters.splice(0)) {
        if (error === undefined) waiter.resolve({ done: true, value: undefined })
        else waiter.reject(error)
      }
    },
    [Symbol.asyncIterator]() { return this },
    next() {
      if (items.length > 0) return Promise.resolve({ done: false, value: items.shift() })
      if (closed) return failure === undefined
        ? Promise.resolve({ done: true, value: undefined }) : Promise.reject(failure)
      const waiter = Promise.withResolvers()
      waiters.push(waiter)
      return waiter.promise
    },
    return() {
      queue.end()
      return Promise.resolve({ done: true, value: undefined })
    },
  }
  return queue
}

/** 桌面终端适配器：每个 Session 的终端由 PC 上的 terminal-controller 持有。 */
export class DesktopAppTerminals {
  /**
   * @param {object} deps 宿主侧依赖
   * @param {() => boolean} deps.available 当前宿主是否启用了 `terminalController`
   * @param {(sessionId: string) => Promise<object>} deps.resolveAgent Session 到 Agent 的解析器
   * @param {(namespace: string, method: string, args: object, signal?: AbortSignal) => Promise<unknown>} deps.invoke Gateway 请求/响应调用
   * @param {(request: object) => Promise<AsyncIterable<object>>} deps.stream Gateway 流调用（已带门面 peer）
   */
  constructor({ available, resolveAgent, invoke, stream } = {}) {
    if (typeof available !== 'function' || typeof resolveAgent !== 'function'
      || typeof invoke !== 'function' || typeof stream !== 'function') {
      throw new TypeError('DesktopAppTerminals requires available, resolveAgent, invoke and stream')
    }
    this.available = available
    this.resolveAgent = resolveAgent
    this.invoke = invoke
    this.stream = stream
    this.records = new Map()
    this.creates = new Set()
    // 每次 detachAll 递增；在途创建据此判断落地时连接是否已经断开（断开后不应再挂保留流）。
    this.detachments = 0
    this.disposed = false
  }

  /** 供门面判断宿主替换是否安全的计数：已知终端与在途创建。 */
  activitySnapshot() {
    return { live: this.records.size, pending: this.creates.size }
  }

  /** 终端服务必须存在且未被卸载：缺失是能力问题，不是参数问题。 */
  _service() {
    if (this.disposed) throw terminalFailure('terminal/unavailable', '终端服务已停止')
    if (!this.available()) {
      throw terminalFailure('terminal/unavailable', '这台电脑没有启用终端服务，请检查远程宿主的 terminal-controller 配置')
    }
  }

  /**
   * 解析 Session 的 Agent。Gateway 的 `agentId` 线上字段按 SessionId 解析，所以返回
   * 的 Agent 身份就是 attach/create 等方法的 `agentId`。
   * @param {string} sessionId Session 身份
   * @returns {Promise<string>} wire 上的 `agentId`
   */
  async _agent(sessionId) {
    let found
    try {
      found = await this.resolveAgent(sessionId)
    } catch (error) {
      throw this._callFailure(error)
    }
    if (typeof found !== 'object' || found === null) {
      throw terminalFailure('gateway/internal', 'Terminal Session resolution returned no result')
    }
    if ('error' in found) {
      if (found.error?.code === 'session/not-found') {
        throw terminalFailure('gateway/not-found', String(found.error.message ?? 'Session does not exist'), found.error.details)
      }
      throw found.error
    }
    const agentId = found.agent?.id
    if (agentId === undefined) {
      throw terminalFailure('gateway/internal', 'Terminal Session resolution returned no Agent')
    }
    return String(agentId)
  }

  /**
   * 把 controller/Gateway 抛出的失败收敛到协议词汇表；已带 code 的失败原样保留。
   * @param {unknown} error 捕获的失败
   * @returns {Error} 可直接交给门面 `remoteFailure` 的失败
   */
  _callFailure(error) {
    if (typeof error?.code === 'string') return error
    if (error instanceof TypeError) return terminalFailure('gateway/bad-request', String(error.message ?? error))
    return terminalFailure('gateway/internal', String(error?.message ?? error ?? 'Terminal operation failed'))
  }

  /**
   * 把 attach/retain 流上的失败收敛到协议词汇表；取消映射成 `gateway/cancelled`。
   * @param {unknown} error 捕获的失败
   * @param {AbortSignal} signal 该流的取消信号
   * @returns {Error} 可展示的失败
   */
  _streamFailure(error, signal) {
    if (typeof error?.code === 'string') return error
    if (signal?.aborted === true) return terminalFailure('gateway/cancelled', '终端附件已分离')
    return terminalFailure('terminal/unavailable', String(error?.message ?? error ?? '终端连接已断开'))
  }

  /**
   * 取出或创建终端记录。记录只暴露给本适配器；没有 attach 时它只有已知的终端信息。
   * @param {string} sessionId Session 身份
   * @param {string} id 终端身份
   * @returns {object} 记录
   */
  _record(sessionId, id) {
    const key = JSON.stringify([sessionId, id])
    let record = this.records.get(key)
    if (record === undefined) {
      record = {
        key, sessionId, id, info: undefined, screen: undefined, serializer: undefined,
        displayState: undefined, revision: 0, attach: undefined, hold: undefined,
        applying: Promise.resolve(),
      }
      this.records.set(key, record)
    }
    return record
  }

  /** 丢弃记录并中止它的附件与保留流；终端进程本身不结束。 */
  _forget(record) {
    if (this.records.get(record.key) !== record) return
    this.records.delete(record.key)
    const failure = terminalFailure('terminal/unavailable', '终端已不可用')
    if (record.attach !== undefined) this._finishAttach(record, record.attach, failure)
    if (record.hold !== undefined) this._releaseHold(record.hold, failure)
    this._clearScreen(record)
  }

  /** 释放 headless xterm 投影与其显示状态。 */
  _clearScreen(record) {
    record.displayState?.dispose()
    record.displayState = undefined
    record.screen?.dispose?.()
    record.screen = undefined
    record.serializer = undefined
  }

  /**
   * 建立 retain 保留流并等待首帧 `retained`。同一终端只保留一条；已被释放的保留流
   * （例如 `detachAll` 同步中止后同 tick 重连的 `read`）不能复用，否则新附件会在没有
   * 保留额度的情况下运行，终端可能被空闲回收。失败时清空以便重试。
   * @param {object} record 终端记录
   * @returns {Promise<object>} 保留流记录
   */
  async _ensureHold(record) {
    this._service()
    const current = record.hold
    if (current !== undefined && !current.controller.signal.aborted) {
      await current.open.promise
      return current
    }
    const hold = { controller: new AbortController(), open: Promise.withResolvers(), task: undefined }
    hold.open.promise.catch(() => {})
    record.hold = hold
    hold.task = (async () => {
      let retained = false
      try {
        const stream = await this.stream({ namespace: 'terminal', method: 'retain',
          args: { sessionId: record.sessionId, id: record.id }, signal: hold.controller.signal })
        for await (const frame of stream) {
          if (!retained && frame?.type === 'retained') {
            retained = true
            hold.open.resolve()
          }
        }
        if (!retained) {
          throw terminalFailure('terminal/unavailable', '终端保留流没有确认，终端可能已关闭')
        }
        // 保留流正常结束说明终端已关闭：下一次 attach 会明确失败，这里无需额外动作。
      } catch (error) {
        if (!retained) hold.open.reject(this._streamFailure(error, hold.controller.signal))
      } finally {
        if (record.hold === hold) record.hold = undefined
      }
    })()
    await hold.open.promise
    return hold
  }

  /**
   * 中止保留流；打开设备时保留的额度在这里释放，终端进程继续运行。
   * @param {object} hold 保留流记录
   * @param {Error} failure 取消原因
   */
  _releaseHold(hold, failure) {
    hold.controller.abort(failure)
  }

  /**
   * 建立一条 attachment 并在后台消费它的帧。
   * @param {object} record 终端记录
   * @returns {object} attachment 记录
   */
  _beginAttach(record) {
    this._service()
    const attach = {
      controller: new AbortController(),
      open: Promise.withResolvers(),
      snapshotSettled: false,
      writable: false,
      finished: false,
      failure: undefined,
      input: { queue: createInputQueue(), sequence: 0, bytes: 0, pending: new Map() },
      task: undefined,
      watchdog: undefined,
    }
    attach.open.promise.catch(() => {})
    record.attach = attach
    // attach 打开可能包含冷 Session 的 Agent 恢复；超时后清掉这条附件，下一次 read 重试。
    attach.watchdog = setTimeout(() => {
      this._finishAttach(record, attach, terminalFailure('gateway/timeout', '等待终端快照超时，请重新读取终端'))
    }, ATTACH_TIMEOUT_MS)
    attach.watchdog.unref?.()
    attach.task = this._runAttach(record, attach)
    return attach
  }

  /**
   * attachment 的消费循环：先保留、再打开 attach 流，按到达顺序应用帧。
   * @param {object} record 终端记录
   * @param {object} attach attachment 记录
   * @returns {Promise<void>} 附件结束时兑现（失败已收敛进 attach.failure）
   */
  async _runAttach(record, attach) {
    try {
      await this._ensureHold(record)
      attach.controller.signal.throwIfAborted()
      if (record.attach !== attach) return
      const agentId = await this._agent(record.sessionId)
      if (record.attach !== attach) return
      const stream = await this.stream({ namespace: 'terminal', method: 'attach',
        args: { agentId, id: record.id }, signal: attach.controller.signal, uplink: attach.input.queue })
      if (record.attach !== attach) return
      for await (const frame of stream) {
        if (record.attach !== attach) break
        record.applying = this._applyFrame(record, attach, frame)
        await record.applying
      }
      throw terminalFailure('terminal/unavailable', '终端连接已断开，请重新读取终端')
    } catch (error) {
      this._finishAttach(record, attach, this._attachFailure(error, attach))
    }
  }

  /**
   * 捕获到的附件失败；watchdog 等先行原因的失败优先。
   * @param {unknown} error 捕获的失败
   * @param {object} attach attachment 记录
   * @returns {Error} 可展示的失败
   */
  _attachFailure(error, attach) {
    return attach.failure ?? this._streamFailure(error, attach.controller.signal)
  }

  /**
   * 结束一条 attachment：中止流、拒绝在途输入、清空上行队列。幂等。
   * @param {object} record 终端记录
   * @param {object} attach attachment 记录
   * @param {Error} failure 结束原因
   */
  _finishAttach(record, attach, failure) {
    if (attach.finished) return
    attach.finished = true
    attach.failure = failure
    if (record.attach === attach) record.attach = undefined
    clearTimeout(attach.watchdog)
    attach.open.reject(failure)
    attach.controller.abort(failure)
    attach.input.queue.end(failure)
    for (const pending of attach.input.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(failure)
    }
    attach.input.pending.clear()
  }

  /**
   * 确保终端已 attach 且首帧快照已应用。
   * @param {object} record 终端记录
   * @returns {Promise<object>} 打开完成的 attachment 记录
   */
  async _ensureAttach(record) {
    const attach = record.attach ?? this._beginAttach(record)
    await attach.open.promise
    return attach
  }

  /**
   * 应用一帧 attach 数据；输出按到达顺序串行解析，`read` 等待 `record.applying`。
   * @param {object} record 终端记录
   * @param {object} attach attachment 记录
   * @param {object} frame controller 的 `TerminalFrame`
   * @returns {Promise<void>} 帧处理完成
   */
  async _applyFrame(record, attach, frame) {
    switch (frame?.type) {
      case 'snapshot':
        await this._installSnapshot(record, attach, frame)
        return
      case 'output': {
        const screen = record.screen
        if (screen === undefined) return
        await new Promise(resolve => { screen.write(frame.data, resolve) })
        record.revision++
        return
      }
      case 'state': {
        record.info = frame.info
        attach.writable = frame.writable === true
        const screen = record.screen
        if (screen !== undefined && (screen.cols !== frame.info.cols || screen.rows !== frame.info.rows)) {
          screen.resize(frame.info.cols, frame.info.rows)
        }
        record.revision++
        return
      }
      case 'ack':
        this._settleInput(attach, frame)
        return
      default:
        throw terminalFailure('gateway/internal', '终端附件返回了未知帧')
    }
  }

  /**
   * 快照是每条 attachment 的完整屏幕基线：重建 headless 投影并唤醒等待者。
   * @param {object} record 终端记录
   * @param {object} attach attachment 记录
   * @param {object} frame `snapshot` 帧
   * @returns {Promise<void>} 屏幕解析完成
   */
  async _installSnapshot(record, attach, frame) {
    this._clearScreen(record)
    const { screen, serializer } = screenFactory(frame.info.cols, frame.info.rows)
    record.screen = screen
    record.serializer = serializer
    record.displayState = screen.parser ? observeTerminalDisplay(screen) : null
    record.info = frame.info
    attach.writable = frame.writable === true
    record.revision++
    await new Promise(resolve => { screen.write(frame.screen, resolve) })
    if (!attach.snapshotSettled && record.attach === attach) {
      attach.snapshotSettled = true
      clearTimeout(attach.watchdog)
      attach.open.resolve()
    }
  }

  /**
   * 结算一条输入确认。超时后才到的确认按未知处理，不补发输入。
   * @param {object} attach attachment 记录
   * @param {object} frame `ack` 帧
   */
  _settleInput(attach, frame) {
    const pending = attach.input.pending.get(frame.sequence)
    if (pending === undefined) return
    attach.input.pending.delete(frame.sequence)
    if (frame.refusal === undefined) {
      pending.resolve()
      return
    }
    const controlled = frame.refusal === 'read-only'
    pending.reject(terminalFailure('terminal/control-unavailable',
      controlled ? '终端输入由另一个附件控制' : '终端进程已结束', { reason: frame.refusal }))
  }

  /**
   * 在 attachment 内分配连续序号、同步入队并等待确认。
   * @param {object} attach attachment 记录
   * @param {object} command `write` 或 `resize` 命令（不含序号）
   * @param {number} bytes 该命令占用的输入字节
   * @returns {Promise<void>} controller 确认后兑现
   */
  _requestAck(attach, command, bytes) {
    if (attach.finished) throw terminalFailure('gateway/cancelled', '终端附件已分离')
    if (attach.input.bytes + bytes > MAX_PENDING_INPUT_BYTES) {
      throw terminalFailure('gateway/bad-request', '终端输入积压超过上限，请等待确认')
    }
    const sequence = ++attach.input.sequence
    const pending = Promise.withResolvers()
    pending.timer = setTimeout(() => {
      attach.input.pending.delete(sequence)
      pending.reject(terminalFailure('gateway/timeout', '终端输入等待电脑确认超时'))
    }, ACK_TIMEOUT_MS)
    pending.timer.unref?.()
    attach.input.pending.set(sequence, pending)
    attach.input.bytes += bytes
    try {
      attach.input.queue.push({ ...command, sequence })
    } catch (error) {
      this._releaseInput(attach, sequence, bytes)
      throw this._callFailure(error)
    }
    return pending.promise.finally(() => this._releaseInput(attach, sequence, bytes))
  }

  /**
   * 释放一条在途输入占用的额度；确认或拒绝后调用。
   * @param {object} attach attachment 记录
   * @param {number} sequence 输入序号
   * @param {number} bytes 该命令占用的字节
   */
  _releaseInput(attach, sequence, bytes) {
    const pending = attach.input.pending.get(sequence)
    if (pending !== undefined) {
      clearTimeout(pending.timer)
      attach.input.pending.delete(sequence)
    }
    attach.input.bytes = Math.max(0, attach.input.bytes - bytes)
  }

  /**
   * 由记录回答 `read`：投影字段与本地 Android 实现一致（`{...info, revision, screen, display, view}`）。
   * @param {object} record 终端记录
   * @returns {object} 读取结果
   */
  _project(record) {
    const info = appInfo(record.info, record.sessionId)
    const revision = record.revision
    if (record.screen === undefined) return { ...info, revision, screen: '' }
    const view = projectTerminalView(record.screen, record.displayState)
    const screen = record.serializer.serialize()
    if (view === null) return { ...info, revision, screen }
    const display = view.lines
      .map(line => line.runs.map(run => run.text).join(''))
      .join('\n').replace(/\n+$/u, '')
    return { ...info, revision, screen, display, view }
  }

  /**
   * 列出 Session 保留的终端；列表本身不需要 Agent，冷 Session 也能回答。
   * @param {object} params `{sessionId}`
   * @returns {Promise<object[]>} App 看到的终端信息
   */
  async list(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    this._service()
    let infos
    try {
      infos = await this.invoke('terminal', 'list', { sessionId })
    } catch (error) {
      throw this._callFailure(error)
    }
    if (!Array.isArray(infos)) throw terminalFailure('gateway/internal', '终端列表返回了非法结果')
    return infos.map(info => appInfo(info, sessionId))
  }

  /** 发现宿主可用的 shell：`id` 是 shell 路径，`label` 是 shell 名（与设计 §2.2 一致）。 */
  async shells({ sessionId } = {}) {
    const session = identity(sessionId, 'sessionId')
    this._service()
    const agentId = await this._agent(session)
    let found
    try {
      found = await this.invoke('terminal', 'shells', { agentId })
    } catch (error) {
      throw this._callFailure(error)
    }
    if (!Array.isArray(found)) throw terminalFailure('gateway/internal', 'Shell 发现返回了非法结果')
    return found.map(shell => ({ id: shell.path, label: shell.name }))
  }

  /**
   * 创建（或按 idempotency id 复用）宿主终端；创建成功后立即建立保留流，附着由首次 read 触发。
   * @param {object} params `{sessionId, id, cols?, rows?, shellId?}`
   * @returns {Promise<object>} App 看到的终端信息
   */
  async create(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const id = identity(params.id, 'terminalId')
    const cols = params.cols ?? 80
    const rows = params.rows ?? 24
    dimensions(cols, rows)
    const shellPath = params.shellId
    if (shellPath !== undefined && (typeof shellPath !== 'string' || shellPath.length === 0 || shellPath.length > 4096)) {
      throw terminalFailure('gateway/bad-request', 'Invalid terminal shell')
    }
    this._service()
    const detachments = this.detachments
    const operation = (async () => {
      const agentId = await this._agent(sessionId)
      let info
      try {
        info = await this.invoke('terminal', 'create', { agentId,
          request: { id, cols, rows, ...(shellPath === undefined ? {} : { shellPath }) } })
      } catch (error) {
        throw this._callFailure(error)
      }
      // 卸载会先等完在途创建再回收；这里仍要拒绝「卸载开始后才落地」的创建，避免它重新注册记录与保留流。
      this._service()
      const record = this._record(sessionId, id)
      record.info = info
      record.revision++
      // 先保留再附着：await 会拖慢创建响应，失败也不该推翻已提交的创建。连接已断开时不再挂
      // 保留流，否则没有页面的终端会一直无法被空闲回收。
      if (this.detachments === detachments) {
        void this._ensureHold(record).catch(() => { /* 首次 attach 会再次尝试保留。 */ })
      }
      return appInfo(info, sessionId)
    })()
    this.creates.add(operation)
    try {
      return await operation
    } finally {
      this.creates.delete(operation)
    }
  }

  async read(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const id = identity(params.id, 'terminalId')
    this._service()
    const record = this._record(sessionId, id)
    try {
      await this._ensureAttach(record)
    } catch (error) {
      this._forget(record)
      throw this._callFailure(error)
    }
    await record.applying.catch(() => { /* 附件失败会清掉记录，下一次 read 重新 attach。 */ })
    return this._project(record)
  }

  async write(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const id = identity(params.id, 'terminalId')
    const data = params.data
    if (typeof data !== 'string') throw terminalFailure('gateway/bad-request', 'Invalid terminal input')
    const bytes = Buffer.byteLength(data, 'utf8')
    if (bytes > MAX_INPUT_BYTES) {
      throw terminalFailure('gateway/bad-request', 'Terminal input exceeds the 64 KiB limit')
    }
    this._service()
    const record = this._record(sessionId, id)
    let attach
    try {
      attach = await this._ensureAttach(record)
    } catch (error) {
      this._forget(record)
      throw this._callFailure(error)
    }
    if (!attach.writable) {
      const running = record.info?.state === 'running'
      throw terminalFailure('terminal/control-unavailable',
        running ? '终端输入由另一个附件控制' : '终端进程已结束',
        { reason: running ? 'read-only' : 'not-running' })
    }
    await this._requestAck(attach, { type: 'write', data }, bytes)
    return { accepted: true }
  }

  async resize(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const id = identity(params.id, 'terminalId')
    const cols = params.cols
    const rows = params.rows
    dimensions(cols, rows)
    this._service()
    const record = this._record(sessionId, id)
    let attach
    try {
      attach = await this._ensureAttach(record)
    } catch (error) {
      this._forget(record)
      throw this._callFailure(error)
    }
    await this._requestAck(attach, { type: 'resize', cols, rows }, 0)
    // 成功的 resize 会先广播 state 帧（已更新投影尺寸与 info）；这里只兜底没有状态帧的路径。
    if (record.info.cols !== cols || record.info.rows !== rows) {
      record.info = { ...record.info, cols, rows }
      const screen = record.screen
      if (screen !== undefined && (screen.cols !== cols || screen.rows !== rows)) screen.resize(cols, rows)
      record.revision++
    }
    return appInfo(record.info, sessionId)
  }

  async rename(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const id = identity(params.id, 'terminalId')
    const name = terminalName(params.name)
    this._service()
    const agentId = await this._agent(sessionId)
    try {
      await this.invoke('terminal', 'rename', { agentId, id, title: name })
    } catch (error) {
      throw this._callFailure(error)
    }
    const record = this.records.get(JSON.stringify([sessionId, id]))
    if (record?.info !== undefined) {
      record.info = { ...record.info, title: name }
      record.revision++
      return appInfo(record.info, sessionId)
    }
    let infos
    try {
      infos = await this.invoke('terminal', 'list', { sessionId })
    } catch (error) {
      throw this._callFailure(error)
    }
    const info = Array.isArray(infos) ? infos.find(candidate => candidate.id === id) : undefined
    if (info === undefined) throw terminalFailure('terminal/unavailable', '终端不存在或已关闭')
    return appInfo(info, sessionId)
  }

  async close(params = {}) {
    const sessionId = identity(params.sessionId, 'sessionId')
    const id = identity(params.id, 'terminalId')
    this._service()
    const agentId = await this._agent(sessionId)
    try {
      await this.invoke('terminal', 'close', { agentId, id })
    } catch (error) {
      throw this._callFailure(error)
    }
    const record = this.records.get(JSON.stringify([sessionId, id]))
    if (record !== undefined) await this._dropRecord(record)
    return { closed: true }
  }

  /**
   * 卸载一条记录：中止附件与保留流、拒绝在途输入、清屏；不结束终端进程。
   * @param {object} record 终端记录
   * @returns {Promise<void>} 附件任务收尾（有界等待）
   */
  async _dropRecord(record) {
    if (this.records.get(record.key) === record) this.records.delete(record.key)
    const failure = terminalFailure('terminal/unavailable', '终端已关闭')
    const tasks = []
    if (record.attach !== undefined) {
      tasks.push(record.attach.task)
      this._finishAttach(record, record.attach, failure)
    }
    if (record.hold !== undefined) {
      tasks.push(record.hold.task)
      this._releaseHold(record.hold, failure)
    }
    this._clearScreen(record)
    await this._settle(tasks)
  }

  /**
   * 有界等待附件任务收尾；Agent 恢复等上游等待不应拖住宿主清理。
   * @param {Promise<unknown>[]} tasks 待等待的任务
   * @returns {Promise<void>} 全部结束或超时后兑现
   */
  async _settle(tasks) {
    if (tasks.length === 0) return
    let timer
    try {
      await Promise.race([
        Promise.allSettled(tasks),
        new Promise(resolve => { timer = setTimeout(resolve, CLOSE_TIMEOUT_MS) }),
      ])
    } finally {
      clearTimeout(timer)
    }
  }

  /**
   * 解绑设备时释放全部附件与保留流（协议 §7.2：连接断开只 detach，终端进程继续运行）。
   * 必须在 transport.unbind 的同步路径上调用。
   */
  detachAll() {
    if (this.disposed) return
    this.detachments++
    const failure = terminalFailure('gateway/cancelled', '远程连接已断开，终端附件已分离')
    for (const record of this.records.values()) {
      if (record.attach !== undefined) this._finishAttach(record, record.attach, failure)
      if (record.hold !== undefined) this._releaseHold(record.hold, failure)
      this._clearScreen(record)
    }
  }

  /** 门面卸载：释放全部附件/保留流并等待有界收尾。幂等。 */
  async dispose() {
    if (this.disposed) return
    this.disposed = true
    const failure = terminalFailure('terminal/unavailable', '终端服务已停止')
    // 在途创建会在 invoke 返回后才注册记录与保留流；先等它们收尾，再按最终记录集合释放，
    // 否则卸载返回后仍可能留下保留流或记录。
    await this._settle([...this.creates])
    const tasks = []
    for (const record of [...this.records.values()]) {
      this.records.delete(record.key)
      if (record.attach !== undefined) {
        tasks.push(record.attach.task)
        this._finishAttach(record, record.attach, failure)
      }
      if (record.hold !== undefined) {
        tasks.push(record.hold.task)
        this._releaseHold(record.hold, failure)
      }
      this._clearScreen(record)
    }
    await this._settle(tasks)
  }
}
