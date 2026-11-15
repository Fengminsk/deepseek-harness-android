# 远程终端设计：桌面宿主 terminal-controller ↔ App 终端页（方案 B）

状态：**已实施（2026-11-16）**——宿主适配、App 接口化、远程接线、真实宿主 e2e 与真机验收均通过；
实测记录与遗留边界见 [HANDOFF.md](HANDOFF.md) §3.2.4、§3.3（`p5c-*` 截图）、§4.10。
本文保留为设计依据；实现与本设计不一致处以 `apps/android/runtime/terminal-desktop.mjs` 与
`apps/android/lib/remote_terminal_page.dart` 的 JSDoc 为准。
上位文档：[remote-dsh-plan.md](../remote-dsh-plan.md)（P5）、[HANDOFF.md](HANDOFF.md) §4.1、[protocol.md](protocol.md)（冻结 v1）。
范围：只改 `apps/android/runtime`（宿主侧适配）与 `apps/android/lib`（App 接线）。**不改 `protocol.md`、不改 `packages/api/terminal-controller`。**

---

## 0. 结论

采用**方案 B：不加双向流**。App 继续用冻结 v1 方法表里的 `terminal.*` 发请求/收响应；宿主在门面内把 `terminal-controller` 的双工 `attach` 流适配成与本地 Android 实现完全相同的响应形状（含结构化屏幕 `view`），App 复用现有终端页。

- 冻结表已有 `terminal.list/shells/create/read/write/resize/rename/close`（protocol.md:292），本方案**不新增方法、不新增 capability、不新增帧类型**。
- `api.subscribe` 无法承载上行：门面只单向消费 `ctx.typertGateway.stream({...})`（`apps/android/runtime/streams.mjs:76-103`），协议也只允许 v1 新增 `protocol.hello`（protocol.md:268-272）、新能力必须随 v2（protocol.md:699）。
- `terminal-controller` 的上行 `TerminalInput`、`RemoteUplinkWindow` 与 `ack` 全部留在宿主适配器内部（`packages/api/terminal-controller/src/index.ts:215-220`、`packages/api/terminal-controller/src/types.ts:66-79`），手机看不到 uplink/窗口机制。
- App 侧只把终端页对 `RuntimeController` / `TerminalShellCatalog` 的两处依赖接口化；页面、渲染、输入逻辑 0 重写（轮询 450 ms、写后立即 `read` 的现有节奏见 `apps/android/lib/session_terminal.dart:665-686`、`880-941`、`943-1027`）。

不选 A（`api.push` + 上游 uplink 透传）：需要 v1→v2 协议变更（protocol.md:699），且 App 无 ANSI/xterm 解析器（`apps/android/pubspec.yaml` 无终端依赖），必须新写 Dart 模拟器，成本远大于宿主适配。
不选 C（仅本地）：远程 profile 已显式启用 `terminal-controller`（`apps/remote-host/cordis.patch.yml:21-26`），桌面终端是 DSH 既有能力，隐藏它违反「DSH 有的才做」。

---

## 1. 现状证据

| 事实 | 证据 |
|---|---|
| 远程 profile 启用真实 terminal-controller | `apps/remote-host/cordis.patch.yml:21-26` |
| App profile 关闭 terminal-controller | `apps/android/runtime/cordis.patch.yml:30-37` |
| 门面 `terminal.*` 现在路由到 Android PTY 实现，桌面必失败 | `apps/android/runtime/index.mjs:762-770` → `apps/android/runtime/terminals.mjs:58-64`（`helperPath()` 要求 `process.platform === 'android'` 且 native library 目录存在） |
| 桌面可答的方法表是静态常量 | `apps/android/runtime/index.mjs:317-425`（`FACADE_METHODS`/`FACADE_UNSUPPORTED`），`apps/remote-host/src/index.ts:129-247` 有兜底副本 |
| 门面通过 `appRuntimeFacade` 暴露给 wss 宿主 | `apps/android/runtime/index.mjs:968-978`；`apps/remote-host/src/index.ts:471-481` 调 `bind`+`dispatch` |
| 连接关闭时只解绑 sink，不回收连接级资源 | `apps/android/runtime/index.mjs:288-295`；`apps/remote-host/src/index.ts:482-497` |
| Gateway 允许宿主侧带 uplink 打开 stream | `packages/api/gateway/src/types.ts:11-29`；`packages/api/gateway/src/index.ts:453-489`、`525-542` |
| attach 必须由 Gateway 调用（读 `this.ctx.invocation`） | `packages/api/terminal-controller/src/index.ts:216-219` |
| attach 帧契约 | `packages/api/terminal-controller/src/types.ts:66-79`（snapshot/output/state/ack，inputWindow）；`packages/api/terminal-controller/src/terminal.ts:82-111`、`:113-152`（序号连续、ack/refusal）；`packages/api/terminal-controller/src/stream.ts:24-34`（follower 超限即失败，重连靠快照恢复） |
| App 本地终端就是请求/响应 + 轮询 | `apps/android/lib/session_terminal.dart:665-686`（450 ms `Timer.periodic`）、`880-941`（`terminal.read`）、`943-1027`（`terminal.write` 后立刻 `read`）、`1048-1105`、`1107-1126` |
| 本地 `terminal.read` 响应形状 | `apps/android/runtime/terminals.mjs:414-424`（`{...info, revision, screen, display, view}`） |
| 结构化屏幕契约与投影/解析 | 宿主 `apps/android/runtime/terminals.mjs:209-264`；App `apps/android/lib/terminal_screen.dart:28-177`（`TerminalScreenData.parse`，上限 500 行/10 万字符，:78-99） |
| App 的 shell 选择写死 Android 枚举 | `apps/android/lib/terminal_shells.dart:1-56`（`TerminalShell` 枚举；`discover()` 拒绝 >3 项或未知 id） |
| 远程 App 已有 `api.call`/`api.subscribe` 直呼 typert 命名空间的先例 | `apps/android/lib/remote_dsh_live_source.dart:1356-1361`；`apps/android/lib/remote_conversation_live_source.dart:9-17` |
| agent wire 标识实际按 SessionId 解析 | `packages/core/agent/src/index.ts:263-277`（`wire: 'agentId'`，`resolve: sessionId => this.get(sessionId)`） |

---

## 2. 线上契约（冻结 v1 内，0 新增）

### 2.1 方法表

沿用 protocol.md:292 的 8 个名字；**不新增 `api.push`、不新增 `terminal.attach`/`terminal.stream`**。`protocol.hello.methods` 仍由门面声明：桌面分支在提供 `appRuntimeFacade` 时检查 `ctx.get('terminalController')`，缺失则把 `terminal.*` 从 `methods` 去掉，并把 `terminal.*` 列入 `unsupported`（protocol.md:666-676、678-692；优先级规则同 §10.1）。存在时照常声明——**消灭现在「声明了却答不了」的不一致**。

### 2.2 请求/响应（App 侧看到的形状，与本地 Android 完全一致）

帧形态、帧上限、请求速率限制完全不变（protocol.md §1.2/§1.3，:60-98）；本方案只使用请求/响应，不打开 App 侧流，也不涉及 `window-ack` 窗口。

| 方法 | 请求 params | 成功 result |
|---|---|---|
| `terminal.list` | `{sessionId}` | `[{id, sessionId, cwd, name, shellId, cols, rows, state, exitCode, error?}]` |
| `terminal.shells` | `{sessionId}`（远程新增；本地无参） | `[{id, label}]`，`id` = shell 路径、`label` = shell 名 |
| `terminal.create` | `{sessionId, id, cols, rows, shellId?}` | 同 list 单项；`shellId` 在桌面被当作 `shellPath` 使用 |
| `terminal.read` | `{sessionId, id}` | `{id, sessionId, cwd, name, shellId, cols, rows, state, exitCode, error?, revision, screen, display, view}`；`view` 形状见 `apps/android/lib/terminal_screen.dart:62-177` |
| `terminal.write` | `{sessionId, id, data}`（data ≤ 64 KiB） | `{accepted: true}`（进程已接受该输入） |
| `terminal.resize` | `{sessionId, id, cols, rows}` | 映射后的 info |
| `terminal.rename` | `{sessionId, id, name}` | 映射后的 info（桌面映射到 controller 的 `title`） |
| `terminal.close` | `{sessionId, id}` | `{closed: true}` |

### 2.3 错误（走成功的 `result._pocket_error`，protocol.md:273-278、§9.2）

| 场景 | `code` | App 处理 |
|---|---|---|
| 终端不存在/已关闭/Agent 已释放 | `terminal/unavailable` | 列表刷新；页面提示「终端已不存在」 |
| 输入被拒（另一附件持输入权或进程已结束） | `terminal/control-unavailable`，`details.reason = "read-only"｜"not-running"` | 提示只读/已结束，保留输出 |
| 超过每会话终端上限 | `terminal/limit-reached`，`details.limit` | 「最多同时保留 N 个终端」 |
| 输入等待 provider ack 超时 | `gateway/timeout` | 页面既有「输入送达状态未知」分支 |
| 参数/会话不合法 | `gateway/bad-request` / `gateway/not-found` | 直接展示 message |
| 宿主没装/没启用 controller | `terminal.*` 不在 methods → 入口三态 unsupported | 隐藏入口并说明原因 |

不引入 `capabilities` 字符串；`window-ack`（protocol.md:693-699）语义完全不动，本方案不使用 App 侧流。

---

## 3. 宿主实现（`apps/android/runtime`）

新文件 **`apps/android/runtime/terminal-desktop.mjs`**，导出 `DesktopAppTerminals`，与 `AppTerminals` 同方法面：`list/shells/create/read/write/resize/rename/close/activitySnapshot/dispose/detachAll`。`apps/android/runtime/index.mjs` 两处改动（下文 `:694` 等行号均指该文件）：`:694` 改为 `android ? new AppTerminals(...) : new DesktopAppTerminals({...})`；`:762-770` 分支在桌面下走 `desktopTerminals[action](params)` 并用既有 `remoteFailure`（`:116-124`）把带 `code/details` 的异常包成 `_pocket_error`。清理处 `:956` 不变。

内部每个终端一条 attachment 记录：`{ screen, serializer, displayState, info, revision, pendingWrites: Map<seq,{resolve,reject}>, inputQueue, abort }`。

- **创建/列表/改名/关闭**：`ctx.sessionController.resolveAgent(sessionId)` 取 Agent（`packages/api/session-controller/src/index.ts:271`）；再经既有 `invoke`（`apps/android/runtime/index.mjs:531-535`，owner peer）调用 gateway：
  - `create`: `{agentId: String(agent.id), request: {id, cols, rows, shellPath}}`（wire 名取自生成的 `terminal/create` 描述符；`agentId` 实际按 SessionId 解析，见 `packages/core/agent/src/index.ts:263-277`）
  - `list`: `{sessionId}`；`shells`: `{agentId}` → 映射 `{id: shell.path, label: shell.name}`
  - `rename`: `{agentId, id, title: name}`；`close`: `{agentId, id}`
  - `create` 对同一 `id` 幂等（`packages/api/terminal-controller/src/types.ts:57`、`packages/api/terminal-controller/src/index.ts:166-172`），App 用 `mobile-<微秒>` 生成 id。
- **attach 适配（核心）**：`ctx.typertGateway.stream({namespace:'terminal', method:'attach', args:{agentId, id}, peer: peer(), uplink: inputQueue, signal})`。
  - 帧处理：`snapshot` → `screen.write(frame.screen)` 并记录 `info/writable`；`output` → `screen.write(frame.data)` 后 `revision++`；`state` → 更新 info/writable；`ack` → 按 `sequence` 结算 `pendingWrites`（`refusal` → `terminal/control-unavailable`）。
  - `read`：等屏写队列静止后返回与本地一致的形状（`projectTerminalView`，复用 `apps/android/runtime/terminals.mjs:209-264`；该文件只需把 `screenFactory` 改为导出）。
  - `write`：`sequence = ++n`，同步入队 `{type:'write', sequence, data}`（入队早于任何 `await`，同一条连接上的请求按帧到达顺序进入 dispatch，因此顺序 = 到达顺序），然后等待该序号的 `ack`（宿主侧 5 s 超时 → `gateway/timeout`）。**App 的 `send()` 串行等待，队列深度实际 ≤ 1**（`apps/android/lib/session_terminal.dart:949-957`）。`resize` 同路径（`{type:'resize', sequence, cols, rows}`），ack 后同步 `screen.resize`。
  - 输入上限：controller `maxInputBytes = 64 KiB`（`packages/api/terminal-controller/src/index.ts:88`）、follower `maxBufferedBytes = 2 MiB`（`packages/api/terminal-controller/src/index.ts:87`），超限按 §2.3 失败。
- **保留（retain）**：attach 前用 `stream({namespace:'terminal', method:'retain', args:{sessionId, id}, signal})` 开一条 hold 流并后台消费 `{type:'retained'}`（协议无关、纯宿主内部；语义见 `packages/api/terminal-controller/src/index.ts:198-206`、`packages/api/terminal-controller/src/retention.ts:43-62`）。页面/连接在时终端不会被空闲回收；`detachAll` 时释放。
- **断开回收**：`createLateBoundTransport.unbind`（`apps/android/runtime/index.mjs:293-295`）在解开 sink 时调用 `desktopTerminals.detachAll()`：abort 每条 attachment 的 attach+retain、拒绝全部 `pendingWrites`、清屏，**不结束进程**（连接关闭时在途请求由传输层统一以 `gateway/cancelled` 失败）。App 重连后第一次 `read` 重新 attach，`snapshot` 恢复屏幕（协议 §7.2 第 5 步的等价语义）。
- **限制与安全**：每 Session 8 个终端（`packages/api/terminal-controller/src/index.ts:83`）、单终端单输入权（`packages/api/terminal-controller/src/terminal.ts:197-200`）；终端以 PC 系统用户权限运行、独立于 Agent 沙箱与审批（`packages/api/terminal-controller/README.zh.md:30`），与「配对=完全信任这台电脑」（HANDOFF §6.4）一致；不新增监听/凭据；撤销设备关闭连接即 `detachAll`；v1 单设备（protocol.md:708）。
- **框架预算**：每次 `read` 一次请求，单终端约 2–3 次/秒，远低于 §1.3 的 100 次/秒（protocol.md:96）；响应受 `MAX_VIEW_LINES=500`/`MAX_VIEW_CELLS=100000`/`MAX_VIEW_RUNS=10000`（`apps/android/runtime/terminals.mjs:12-14`）与 App 解析上限约束，典型 80×24 帧 ≪ 16 MiB 下行上限（protocol.md:89-98）。

---

## 4. App 实现（`apps/android/lib`）

### 4.1 两处依赖接口化（无 UI 重写）

新文件 `apps/android/lib/terminal_runtime.dart`：

- `abstract interface class TerminalCallSurface { bool get ready; String get phase; int get connectionGeneration; Future<dynamic> call(String method, [Json params = const {}]); void addListener(VoidCallback); void removeListener(VoidCallback); }`
  - `RuntimeController implements TerminalCallSurface`：现有成员已满足（`apps/android/lib/runtime.dart:44/67/132/248/654-664`）。
- `class TerminalShellOption { final String id, label; }` + `abstract interface class TerminalShellSource { Future<List<TerminalShellOption>> discover(); Future<TerminalShellOption?> preferred(); Future<void> remember(TerminalShellOption shell); }`
  - `TerminalShellCatalog implements TerminalShellSource`（`apps/android/lib/terminal_shells.dart` 内部仍用 Android 枚举校验）。
- `apps/android/lib/session_terminal.dart` 只改类型：`SessionTerminalsPage`/`SessionTerminalView` 的 `RuntimeController` → `TerminalCallSurface`；`SessionTerminalsPage` 增加 `TerminalShellSource shellSource` 参数。本地调用点改传 `TerminalShellCatalog(runtime)`：`apps/android/lib/main.dart:275`、`apps/android/lib/resource_hub.dart:63`、`apps/android/test/terminal_screen_test.dart` 相关构造。

### 4.2 远程数据源

新文件 `apps/android/lib/remote_terminal.dart`：

- `RemoteTerminalRuntime implements TerminalCallSurface`：包一个 `RemoteConnectionController`；`call` → `transport.request` 并把 `RuntimeTransportFailure` 转 `PlatformException`（与 `RuntimeController.call` 一致）；`ready/phase/connectionGeneration` 投影连接控制器（`apps/android/lib/remote_connection.dart:101/210/224`，需公开 `generation` getter）；监听 `addListener` 转发；`dispose` 解绑。远程适配器不做参数改名：`terminal.create.shellId`、`terminal.rename.name` 由宿主适配器吸收（见 §3）。
- `RemoteTerminalShellSource(sessionId)`：`terminal.shells {sessionId}` → 动态 `{id,label}`；`preferred` = 列表首项；`remember` 只存内存（跨 PC 持久化延期）。
- `RemoteConversationSource`（`apps/android/lib/remote_conversation_source.dart:713-816`）增加 `RemoteTerminalRuntime createTerminalRuntime()`，由 `RemoteConversationLiveSource` 用同一连接实现；页面关闭时 `dispose`。

### 4.3 入口与三态

远程会话页「…」菜单新增「终端」（与「本次变更」「归档会话」同处，`apps/android/lib/remote_dsh_conversation.dart:562-600`）。终端是 Session 资源，**不放首页**。能力三态按 `terminal.list/create/read/write/resize/close` 取最弱（复用 `_capabilities([...])`，`apps/android/lib/remote_dsh_conversation.dart:607-621`）：pending →「正在连接电脑…」；unsupported →「这台电脑不支持终端」；available → push `SessionTerminalsPage(runtime: remoteRuntime, sessionId: ..., shellSource: ...)`。

### 4.4 交互、重连、生命周期

- 输入法/按键/鼠标/光标全部复用现有实现；`send` 的「输入送达状态未知」语义不变（`apps/android/lib/session_terminal.dart:990-1000`）。shell 选择器复用，选项来自 PC。
- 重连：页面已有的 generation/phase 监听（`apps/android/lib/session_terminal.dart:827-877`）在断线时清屏并置 `unconfirmed`；重连后 450 ms 轮询自然重试 `read` → 宿主重新 attach → 快照恢复。未确认输入不重放（controller 每条命令只消费一次，`packages/api/terminal-controller/src/terminal.ts:113-152`）。
- 离开页面只 detach，不结束进程（与本地一致：「离开页面后继续运行」`apps/android/lib/session_terminal.dart:1201`）；再次进入重新 attach。

---

## 5. 里程碑与验收

| 里程碑 | 交付 | 验收命令/步骤 |
|---|---|---|
| M1 宿主适配 | `apps/android/runtime/terminal-desktop.mjs` + `apps/android/runtime/index.mjs` 接线 + `apps/android/runtime/terminals.mjs` 导出 `screenFactory` + Node 单测 `apps/android/tool/terminal-desktop-runtime.test.mjs`（假 gateway/uplink/ack、快照恢复、超时、detach） | `node --test apps/android/tool/terminal-desktop-runtime.test.mjs` |
| M2 宿主 e2e | `apps/remote-host/scripts/e2e-remote-host.ts` 增加 terminal 检查：`shells` → `create` → `write 'echo E2E-TERMINAL-OK\r'` → 轮询 `read` 直到出现该串 → `resize` → `list` → `close`；`REQUIRED_METHODS`（`apps/remote-host/scripts/e2e-remote-host.ts:61-70`）加 `terminal.*` | 真实宿主下 `node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url …`，原有 16/16 不回归、新增项全 PASS |
| M3 App 接口化 | §4.1 接口提取，本地终端行为不变 | `flutter analyze`（无新增告警）+ `flutter test`（现有 1686 项全通过，含 `apps/android/test/terminal_screen_test.dart`） |
| M4 App 远程接线 | `apps/android/lib/remote_terminal.dart` + 会话页菜单 + 三态 + widget 测试（fake connection 下读取/写/重连/unsupported） | `flutter test apps/android/test/remote_terminal_test.dart` + 上述全量 |
| M5 真机验收 | ① 手机创建 PC shell 并 `echo` 看到输出；② 输入 `cd`、`dir`/`ls` 等交互；③ 旋转/软键盘弹出后自动 `resize`；④ 关闭终端后列表消失；⑤ 杀 App 重连回来仍是同一终端且屏幕恢复；⑥ 8 个上限提示；⑦ 宿主临时禁用 controller（改 patch 复跑）→ 入口三态 unsupported | `pnpm dsh --profile remote-host …` + 真机，截图存 `.cache/remote-device/p5c-*.png` |

可延期：推送式增量输出（A 方案的 v2 化）、shell 偏好跨 PC 持久化、终端分屏、滚动历史翻页（与本地同样只保留 500 行视图）、多设备并发（v1 单设备）。

---

## 6. 风险与开放问题

1. **快照保真度**：controller 的 `snapshot.screen` 是 `@xterm/addon-serialize` 输出，只覆盖部分 DEC 模式（application cursor keys/bracketed paste/mouse tracking 等；不含 SGR mouse 1006 与 DECSCUSR 光标样式）并把 alt 屏内容串接在 normal 屏之后（`.cache/android/runtime-bundle/node_modules/@xterm/addon-serialize` 的 `_serializeModes`）。**本方案在宿主再跑一个 headless xterm**，因此手机重连后整屏程序（vim/less）可能需重绘；Web 客户端使用同一快照机制，属既有语义。验收用 vim/less 实测；若不可接受，记录为已知限制或提上游在 snapshot 增加模式字段（需改 controller，超出本轮）。
2. **适配器归属**：本设计放 `apps/android/runtime`（与 `AppTerminals` 同包，可直接复用 `projectTerminalView`/`observeTerminalDisplay`，避免跨包导入无类型 `.mjs`，且 remote-host 已依赖该包）。代价是桌面专用代码随 APK runtime bundle 打包（约几十 KB）。需要 lead 在 HANDOFF §5.1 文件所有权表里明确。
3. **`methods` 时机**：`appRuntimeFacade` 提供时读 `ctx.get('terminalController')`；若 controller 晚于门面激活，可能误判为缺失。以 e2e 的 `REQUIRED_METHODS` + 真实 terminal 检查兜底；若实测不稳定，改为在 remote-host 每次握手时重算（`apps/remote-host/src/index.ts:600-619` 的 `createHandshake` 读一次 facade.methods）。
4. **冷会话创建终端**：`create` 需要 Agent，`sessionController.resolveAgent` 会恢复会话（与本地 Android 一致）。产品需确认「手机在冷会话里开终端会唤醒 PC 上的 Agent」是否可接受；建议接受并写进提示。
5. **轮询成本**：450 ms 一次全屏 JSON 在局域网可接受（本地终端同节奏）；若真机出现耗电/流量问题，升级路径是 v2 的 `stream-input` 能力 + 宿主推送屏幕增量（协议变更，不在本轮）。
