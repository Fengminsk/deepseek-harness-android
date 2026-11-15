# 远程 DSH · 接力手册

> 这份文件是**唯一的入口**：新会话、新 Agent、或工作区被还原之后，先读它再动手。
> 每完成一轮交付，在 §9 追加一条记录；状态变化就改 §3，不要把过时结论留在正文里。
>
> 关键事实（2026-11-16 02:20）：**M1 已在真机成立**（配对 → 列真实项目/会话 → 发消息 → 流式回复 →
> 冷启动自动重连）。**P5 六批全部完成并在真机通过**：审批与模型选择、首页搜索/新建/归档、电脑文件、
> 远程设置、workspace diff、能力三态、远程终端、附件上行（App/宿主/真实 e2e + **debug 旁路真机验收**）、
> 输入区 `+`/方案模式、模型路由前置提示（**C3 真机验证：发送前出现不可用提示并可进模型 sheet**）、
> **B3 审批预设（宿主启用 permission，手机端真实 preset 列表/二次确认，真机切换成功）**、
> 首页输入条文案与 goal 行置灰。真实宿主 e2e **23/23 PASS**；终端适配器 29 项、附件适配器 33 项 Node 单测。
> P6 已启动：反代/隧道可达性文档 + 配对终端二维码（`pairing-qr.ts`，自检 16/16）+ 后台通知设计。
> 下一步见 §4。
>
> 最后更新：2026-11-16 02:20（lead）
> 分支 `android`，最近提交见 `git log --oneline -8`（远程 DSH 功能/文档/性能测量基建已入库）
> 真机：`8a044bba`（adb 在线，OnePlus6 / Android 11，Wi-Fi 192.168.5.140）
> 真机 App：debug APK（含 B3/③/附件验收旁路）；性能测量用 `--target=lib/main_perf.dart` 的 profile 包，
> 见 [performance.md](../performance.md)

---

## 0. 目标与验收

**目标**：手机上原生地使用 PC 上的 DSH 干活——不走 WebView，不重写对话内核。

**M1（技术可行性证伪点）**：真机连上 PC，列出真实项目与会话，发一条消息并看到流式回复。
M1 不成立，整条路线作废，回到 `remote-dsh-plan.md` §4 重新选型。

设计与协议不在本文重复：

- 选型、路线、阶段、风险：[remote-dsh-plan.md](../remote-dsh-plan.md)
- 线上协议（帧、鉴权、握手、方法表、流控、错误码）：[protocol.md](protocol.md)
- 设计参照截图：`docs/设计参照截图/远程DSH功能/`

---

## 1. 五分钟上手

```powershell
# 仓库（本会话工作目录）
D:\JOB\CODE\Lab\deepseek-harness-android

# Flutter 不在 PATH 上，SDK 缓存在仓库里：
D:\JOB\CODE\Lab\deepseek-harness-android\.cache\flutter\bin\flutter.bat

# 常用验证（都在 apps/android 下执行前先 cd）
cd apps\android
& 'D:\JOB\CODE\Lab\deepseek-harness-android\.cache\flutter\bin\flutter.bat' analyze
& 'D:\JOB\CODE\Lab\deepseek-harness-android\.cache\flutter\bin\flutter.bat' test

# PC 宿主的类型检查、冒烟与真实端到端（仓库根目录）
pnpm exec tsc -p apps/remote-host/tsconfig.json
pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts
node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url "<宿主日志里的配对链接>" --send "请只回复两个字：收到"

# 启动 PC 宿主（真机验收用；临时 DSH_HOME 与局域网地址覆盖层见 §3.3）
$env:DSH_HOME = "$env:TEMP\dsh-remote-m1"
pnpm dsh --profile remote-host --patch .cache/remote-m1-host.overlay.yml --no-open

# 构建 App 的运行时与 APK（环境变量见 §8.2；首次或依赖变化时先 build:artifacts + deploy）
pnpm run build:artifacts
node node_modules/tsx/dist/cli.mjs apps/android/tool/stage-runtime.ts
node apps/android/tool/smoke-runtime.mjs
./apps/android/tool/pack-runtime.ps1
cd apps/android
& '..\..\.cache\flutter\bin\flutter.bat' build apk --debug --target-platform android-arm64 --no-pub
```

`analyze` 允许存在的既有告警：`lib/files.dart`、`test/acceptance_files_test.dart` 共 11 条，
全部是本次改动之前就有的。新增告警一律视为失败。

---

## 2. 代码地图

| 层 | 位置 | 说明 |
|---|---|---|
| 协议契约 | `apps/android/docs/remote-dsh/protocol.md` | 冻结的 v1；改它要先想清楚两端 |
| PC 宿主 | `apps/remote-host/src/` | `index.ts` 装配、`server.ts` 传输/鉴权/配对 HTTP 面、`tls.ts` 证书、`identity.ts` 身份、`devices.ts` 设备表、`pairing.ts` 配对窗口、`native-desktop.ts` 桌面反向应答 |
| 宿主组合 | `apps/remote-host/cordis.patch.yml` | 把 Android 组合换成桌面实现、挂 `remote-host` 插件、恢复 shell/PTC 服务、换回桌面预设与账号模型路由 |
| 宿主冒烟 | `apps/remote-host/scripts/smoke-remote-host.ts` | 真实 TLS + 真实 wss + 真实帧，用桩代替完整 DSH（14 项） |
| 宿主端到端 | `apps/remote-host/scripts/e2e-remote-host.ts` | 对真实运行的宿主：配对链接 → CA 指纹 → /pair → wss → hello → 就绪 → 列表/窗口/follow → **终端全链路** → 可选发消息取证（20 项；`--send` 时 20，无 `--send` 时 19） |
| App 门面 | `apps/android/runtime/` | 同一套 JSON-RPC 方法表，既是 workspace 包（`@minnnng/dsh-android-runtime`）也是 Android 打包产物；`platform: desktop` 走晚绑定传输 |
| 宿主终端适配 | `apps/android/runtime/terminal-desktop.mjs`（新）+ `runtime/terminals.mjs` 的投影函数 | 把桌面 `terminal-controller` 的双工 attach 流投影成与本地 Android 同形的 `terminal.*` 请求/响应；29 项 Node 单测 `tool/terminal-desktop-runtime.test.mjs` |
| 宿主附件上行 | `apps/android/runtime/attachments-desktop.mjs`（新）+ `runtime/index.mjs` 接线 | 桌面 `attachments.prepare` 经反向请求 `native.attachments.read` 分页向手机要字节，流式写进 `ctx.fileUploads.uploadStream`；28 项 Node 单测 `tool/attachments-desktop.test.mjs` |
| 门面生成物 | `apps/android/runtime/question-carrier.mjs`、`runtime/secret-mask/` | 由 `tool/stage-question-carrier.mjs`、`tool/stage-secret-mask.mjs` 从 Web 源生成；**PC 宿主直接加载该包，所以生成物也随包提交**，改生成器后跑 `--write` |
| App 传输 | `apps/android/lib/runtime_transport.dart`、`remote_transport.dart` | 传输缝；远端是 wss + 固定 CA + 握手 + 退避重连；请求 id 两侧已是 `a-<uuid v4>` / `h-<uuid v4>`（协议 §1.2） |
| App 连接 | `apps/android/lib/remote_connection.dart` | 设备表 → 连接 → 阶段机（握手 ∧ 宿主 phase=ready） |
| App 配对 | `apps/android/lib/remote_pairing.dart`、`remote_pairing_page.dart`、`remote_pairing_flow.dart` | 配对链接解析、取 CA、换设备令牌 |
| App 设备存储 | `apps/android/lib/remote_device_store.dart` | 设备列表进 SharedPreferences，令牌进 Keystore |
| App 界面 | `apps/android/lib/remote_dsh_page.dart`、`remote_dsh_widgets.dart`、`remote_dsh_conversation.dart`、`remote_dsh_live_source.dart` | 侧栏外壳、组件、会话页、实时数据源 |
| App 会话数据源 | `apps/android/lib/remote_conversation_source.dart`、`remote_conversation_live_source.dart` | 会话页只认数据源契约；真实实现走 `session.readWindow` / `session.send` / `session.follow` |
| App 远程终端 | `apps/android/lib/remote_terminal_page.dart`、`terminal_runtime.dart`、`session_terminal.dart`、`terminal_shells.dart` | 终端页只依赖 `TerminalCallSurface`/`TerminalShellSource` 两个接口；本地与远程共用同一渲染与输入逻辑 |
| P5 剩余设计 | `apps/android/docs/remote-dsh/p5-remaining-design.md` | 附件上行（方案②反向拉取，D1–D8 已决策）、输入区 `+`/方案模式/审批预设、模型路由前置提示；施工图 |
| 性能测量 | `apps/android/lib/main_perf.dart`、`apps/android/tool/device-frame-profile.mjs`、`apps/android/docs/performance.md` | 真机 60 fps 目标的测量入口与 adb 驱动；基线、热点与优化计划见 performance.md |

---

## 3. 当前状态

### 3.1 阶段

| 阶段 | 状态 | 证据 |
|---|---|---|
| P0 协议冻结 | 完成 | `protocol.md` 48 KB |
| P1 PC 宿主 | **完成：真实启动 + Node 端到端 20/20** | §3.2；`apps/remote-host/scripts/e2e-remote-host.ts`（`workspace.files.*`、`workspaceChanges.summary` 能力探测、native 本机应答、`terminal.*` 全链路） |
| P2 App 传输 | 完成（本地零回归） | `flutter test` 全通过；窗口化 ack 在远程会话数据源里已按握手能力开启；请求 id 已是 `a-<uuid>`/`h-<uuid>` |
| P3 配对与设备 | **完成：真机配对契约 + 单次令牌 + 撤销 + 配对窗口重开** | 宿主 `/ca.cer` `/pair`，冒烟 14/14，端到端 20/20；`remoteHost.pair()` 与撤销后自动重开 |
| P4a 侧栏入口与组件 | 完成（含重复进入修复与回归测试） | `test/destination_navigation_test.dart` |
| P4b 远程页面 | 完成：真实设备/项目/会话 + 真实会话页（读窗口/发消息/流式/审批/模型选择/变更/归档/终端入口） + 首页搜索/新建/归档/电脑文件/设置 | `remote_*` 数据源与页面 + 测试；真机证据见 §3.3 |
| P5 能力补齐 | **六批完成**：审批与模型选择、搜索、新建、归档、电脑文件、远程设置、workspace diff、归档动作、能力三态、模型路由兜底、远程终端、附件上行（含 debug 旁路真机验收）、输入区 `+`/方案模式、模型路由前置提示（C3 真机）、**B3 审批预设（真机切换通过）**、首页输入条文案 + goal 行置灰 | §3.3 `p5-*`/`p5b-*`/`p5c-*` 截图；§3.2.2–§3.2.8 |
| P6 可达性 | **启动**：可达性文档（反代/隧道/组网）、配对终端二维码（自检 16/16）、后台通知设计与缺口记录；待做 App 扫码/PC 配对界面、§8 通知实现、前台服务持 WS | `remote-dsh/reachability.md`、`pairing-qr-design.md` |

### 3.2 已核验的通过项（本轮）

- `pnpm exec tsc -p apps/remote-host/tsconfig.json` → exit 0
- `pnpm exec tsc -p tsconfig.host.json` → exit 0（host scripts 已纳入聚合，见 §4.7）
- `pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts` → **14/14 PASS**
- `node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url … --send …` → **23/23 PASS**
  （真实宿主、真实 facade；`methods=93` 来自门面声明、`session.modelCatalog` 可读、
  `workspace.files.list/read` 返回宿主工作区、`workspaceChanges.summary` 能力探测、
  **`terminal.shells/create/write/read/resize/rename/close` 真实链路 4 项**、
  **附件 `prepare`（3 页反向拉取 614400 B）→ 错误翻译 → `session.send` 带 attachmentIds 3 项**、
  `native.*` 本机应答后客户端侧仅设计允许的 `native.attachments.read` 反向请求、
  `session.send` 收到 assistant/message）
- `pnpm run build:artifacts` → 8/8 gates PASS；`pnpm run build:check` → 2/2 gates PASS
- `pnpm exec vitest run packages/sdk/protocol` → 22/22 PASS（含 `requestIdPrefix` 三例）
- `pnpm exec vitest run packages/util/official-bundles` → 2/2 PASS
- `node --test apps/android/tool/terminal-desktop-runtime.test.mjs` → **29/29 PASS**
- `node --test apps/android/tool/attachments-desktop.test.mjs` → **33/33 PASS**
  （邻接 `terminals-runtime` + `attachments-runtime` 回归 85/85 PASS）
- `flutter analyze` → 11 条既有告警，无新增
- `flutter test` → **1787 项全通过**（最终一轮冻结改动后跑）
- 生成物同步：`node apps/android/tool/stage-question-carrier.mjs --write`、`stage-secret-mask.mjs --write`

#### 3.2.2 本批新增能力（P5 第一批）

- **远程审批**：宿主 `AppInteractions` 通过 `interactions.changed` 把 pending approval 推给手机；
  远程会话页在输入条上方渲染「需要授权：<tool>」卡片（工具名 + 一行输入摘要 + 拒绝/允许一次）。
  拒绝对应 `rejected`，允许对应一次性 `allowed-once`。真机已验证：允许后宿主执行命令并回传输出。
- **会话模型选择**：远程会话页模型按钮打开目录（`api.call session.modelCatalog`），可选模型与推理强度，
  `session.selectModel` 应用后输入条与请求路由立即更新；发送遇到凭据类失败时给出「选择模型」指引。
- **首页搜索**：头部搜索按钮原地切换搜索框，按项目名/会话标题本地过滤，空结果有清除入口。
- **新建会话**：连接就绪后输入条可用，提交后按 `library.catalog` 选工作区 → `library.sessionCreate`
  → 刷新并打开新会话页；没有项目时给可见提示。
- **已归档任务**：独立全屏目的地列出电脑上归档的会话，可「恢复」（`library.sessionArchive archived:false`），
  返回首页时自动刷新列表。
- **宿主完整性**：`native.web.preferences` / `native.web.save` / `native.network.addresses` /
  `native.scheduleWakeup.begin/update` 改为宿主机本机应答（协议 §5.2）；门面声明 `methods`/`unsupported`
  消掉握手兜底警告；`remoteHost.pair()` 可重开配对窗口，撤销设备后自动重开并打日志。

#### 3.2.3 本批新增能力（P5 第二批）

- **电脑文件（只读）**：首页菜单「电脑文件」推入独立目的地（`RemoteWorkspaceFilesPage`），
  经门面 `workspace.files.info/list/read` 浏览电脑工作区：目录优先、面包屑/返回上级、
  文本查看器按 `nextOffset` 分页「加载更多」、刷新与错误态；非 UTF-8 文件给「不能作为文本预览」。
  根目录是宿主进程的 cwd（单一工作区，见 §4.9）。真机已验证浏览根目录并打开 `vitest.config.ts`。
- **远程设置（默认模型路由）**：首页「设置」页（`RemoteDshSettingsPage`）读 `settings.describe`，
  置顶显示宿主默认模型路由并可用 `settings.mutate` 更换（带 revision 冲突重读）；其它节只读、
  密钥只显示已配置/未配置。真机已验证把宿主默认模型从 V4-Pro 改为 V4.1-Flash（revision 0→1）。
- **本次变更（workspace diff）**：会话页「…」菜单新增「本次变更」，独立目的地
  `RemoteWorkspaceDiffPage`。宿主只在它发出的 `workspace/changes` 事件序号上保留快照；
  页面先 `session.readWindow` 重新取窗口、用最后一条 `workspace/changes` 的 `seq` 调
  `workspaceChanges.summary`，再按 index 读 `workspaceChanges.diff`，复用本地
  `WorkspaceChangesSummary/WorkspaceFileDiff` 解析与 `WorkspaceDiffBody` 渲染。
  快照只存在宿主当前进程内（重启后旧轮次降级为「不可用」），页面有本轮未结束/无变更/
  降级/失败四态与取消在途请求。真机已验证：发一轮用 `write` 工具的对话后立即打开，
  看到「第 N 轮 · 1 个文件」并能读 `+hello` 差异。
- **会话页归档**：同一菜单提供「归档会话」（确认对话框 → `library.sessionArchive {archived:true}`
  → 返回首页并刷新；首页「已归档任务」可恢复）。真机已验证归档→首页消失→归档页出现→恢复回列表。
- **模型路由自动兜底**：发送失败且错误属于凭据类时，读 `settings.describe` 的
  `agent-default-model`；与当前路由不同则 `session.selectModel` 后**重试一次**，并给常驻提示。
- **能力三态**：会话页的模型/重命名/变更/归档入口与首页文件/设置入口都按握手
  `methods`/`unsupported` 显示 available / unsupported（带原因）/ pending，不再是死按钮。
- **宿主 plumbing**：`apps/remote-host/scripts/**/*.ts` 纳入 host 聚合 typecheck；
  e2e 新增 `workspace.files.list`、`workspace.files.read`、`workspaceChanges.summary`
  三项检查（16 项）。

#### 3.2.4 本批新增能力（P5 第三批：远程终端，M1–M5 完成）

- **宿主适配**：`apps/android/runtime/terminal-desktop.mjs` 把桌面 `terminal-controller` 的
  双工 attach 流投影成与本地 Android 完全同形的 `terminal.*` 请求/响应（含结构化屏幕 `view`、
  `revision`、`display`），不新增方法/能力/帧类型；`terminal.shells` 返回 PC 上真实 shell 路径。
  retain 流保证页面在时不回收；断连 `detachAll` 只分离附件、不结束进程；每会话 8 个上限、
  单终端单输入权、2 MiB 在途输入、5 s ack 超时、15 s attach 看门狗全部覆盖。
  `terminal-desktop-runtime.test.mjs` **29 项**；修掉 3 个真实缺陷（detachAll 后同 tick 重连丢 retain、
  dispose 在途 create 泄漏、detachAll 后落地的 create 留下无主 retain）。
- **App 接口化**：`terminal_runtime.dart` 抽出 `TerminalCallSurface` / `TerminalShellSource`，
  `session_terminal.dart` 只依赖两个接口；`RuntimeController` 与本地 `TerminalShellCatalog` 实现它们，
  本地终端行为/测试不变（全量 1722 项通过）。
- **App 远程接线**：`remote_terminal_page.dart` 提供 `RemoteTerminalRuntime`（`terminal.*` 走 wss）、
  `RemoteTerminalShellSource`（`terminal.shells`）与三态（available/pending/unsupported），
  直接复用本地 `SessionTerminalsPage`；会话页「…」菜单新增「终端」（同一 `RemoteTerminalCapability`
  判定入口与页内一致，连接未就绪/不支持时置灰带原因）；连接由首页持有、终端页只读，不新建连接。
  新增 `remote_terminal_page_test.dart`（7 项）与 `remote_conversation_terminal_entry_test.dart`（5 项）。
- **宿主 e2e**：真实宿主新增 4 项终端检查（shells → create → write `echo E2E-TERMINAL-OK` →
  轮询 read 直到屏幕出现标记 → resize/list/rename/close → 列表不含该终端），
  `REQUIRED_METHODS` 覆盖全部 8 个 `terminal.*`；清理链保证失败也不留孤儿终端（20/20 PASS）。

#### 3.2.5 本批新增能力（P5 第四批：附件上行）

- **协议**：`protocol.md` §5.2 反向请求表只追加一行 `native.attachments.read`（转发给 App，
  分页读取手机附件草稿的私有副本；旧 App 回 `-32601` 时宿主以 `attachment-file/unsupported` 失败）。
  方法表、帧格式、能力协商、版本号均未改动。
- **宿主实现**：`apps/android/runtime/attachments-desktop.mjs` 与 `AppAttachments` 同方法面；
  `prepare` 经 `native.attachments.read`（256 KiB/页、base64）拉取手机字节，流式写入既有
  `ctx.fileUploads.uploadStream`；短读按 `nextOffset` 推进、`eof`/`size`/声明 `bytes` 三方对账；
  图片整图读入并沿用 `validateImage` 与 digest 校验；`preview` 远程上限 8 MiB（16 MiB 下行帧余量）；
  `release` 只清记录不删宿主文件；`detachAll` 中止在途拉取。错误码按设计 §3.4.3 翻译。
- **门面接线**：`index.mjs` 按平台二选一构造；桌面分支错误统一 `remoteFailure` 包成 `_pocket_error`
  （本地分支形状不变）；`unbind` 追加 `attachments.detachAll()`。
- **测试**：`attachments-desktop.test.mjs` **33 项**（分页/短读/对账失败/`-32601`/断连中止/图片/
  release/close/参数校验/无 gateway 流量泄漏 + 5 项「真实 store 两层包装后仍保留映射 code」）。
  真实宿主 e2e 暴露并修掉一个包装缺陷：`fileUploads.uploadStream` 会把流内失败包成
  `session/attachment-invalid`，现在 `pull()` 记录映射后的失败并在 store 包装之后原样重抛
  （见 §7 #25）。
- **App 侧（已完成，待真机）**：`attachment_surface.dart`（`AttachmentCallSurface` 接口化，
  `AttachmentDrafts` 构造参数改为接口，本地零回归）、`remote_attachments.dart`
  （`RemoteAttachmentSurface` + 错误码翻译）、`remote_native_bridge.dart`（连接建好即安装
  `native.attachments.read` 应答，其它方法回 `-32601`；草稿集合准入）、Kotlin
  `attachment.read/discard`（仅本 App 私有缓存、uuid 正则 + canonical 父目录、256 KiB 分页）、
  会话页附件 rail + `snapshotIds`/`consume`/失败保留 + `attachmentIds` 透传（含 `/` 指令与凭据兜底重发）。
  测试：`remote_attachments_test.dart` **20 项** + 会话页 3 项；受影响面 237 项通过。
- **真实宿主 e2e（23/23 PASS）**：新增 `attachments.prepare` 文件收据（fake App 应答 3 页
  `native.attachments.read`，offsets 0→614400 + eof 断言）、`attachments.prepare` missing-draft
  错误翻译（`_pocket_error.code=attachment-file/not-found`，message「文件已不在手机上，请重新选择。」）、
  `session.send` 带 `attachmentIds` 受理；`native-local` 检查把 `native.attachments.read` 视为
  设计允许转发；cleanup 对附件与探针 id 都 `release`。
- **真机阻塞**：本机 OnePlus6/Android 11（ColorOS）的系统文件选择器对本 App 的 SAF 选择项
  **全部 disabled**（`uiautomator` 读到列表项 `clickable=false`，点行/预览按钮均无事件；
  DocumentsUI 日志 `shouldRestrictStorageAccessFramework = true, packageName = com.minnnng.dsh_android`），
  因此 A4 真机附件验收无法在本机完成；App 侧行为由 20 项 widget/单测与宿主 e2e（fake App 应答）
  覆盖。换一台非 ColorOS ROM 或换用其他选择器来源后可继续 A4。


#### 3.2.6 本批新增能力（P5 第五批：输入区 `+` 弹层 + 方案模式 + 模型路由提示判定）

- **`+` 弹层（B1）**：`composer_commands.dart` 抽出 `ComposerCommandSurface`（ready/ensureSession/call），
  `ComposerCommands`/`loadComposerCatalog` 改为依赖接口（本地调用点与文案逐字不变）；新增
  `remote_commands.dart`（`RemoteComposerCommandSurface`，`session.ensure` + `api.call commands/list`）；
  远程会话页 `+` 改为底部弹层承载本地 `ComposerCommands` 数据驱动菜单：文件 → 附件
  `drafts.pick`、模型 → 既有模型 sheet、计划 → 方案模式、其它宿主指令 → `session.command '/name'`、
  export/skills 置灰写原因；`remote_dsh_widgets.dart` 删除六项 Codex 占位与远程麦克风按钮（语音不做），
  `+` 文案「添加与指令」；`RuntimeController` 补实现 `ComposerCommandSurface`。
- **方案模式（B2）**：新增 `remote_goal_plan.dart`（`RemoteGoalPlanController implements ChatPlanSurface`，
  只做 plan）：`session.projections` 读基线 + `session/control` 流增量 + 重连重读；写
  `session.command '/plan'|'/plan off'`；`chat_plan.dart` 的 `ChatPlanDock`/`ChatPlanModePage` 参数改为
  `ChatPlanSurface` 接口（本地行为不变）；会话页输入区上方复用 `ChatPlanDock`；计划审核卡片复用
  `planReviewOf`/`planReviewPreview`（`RemoteQuestion` 补 `intent`），批准走 `intent.approve`、
  请求修改走 `interactions.dismiss`、原文推既有 `ChatPlanDocumentPage`。
- **模型路由前置提示（C1/C2）**：`RemoteModelCatalog` 增加 `routableProviders`，
  `RemoteConversationModelAvailability.failedProviders` → `unavailableProviders`
  （= 目录 failures ∪ 当前路由不在 routableProviders）；目录读失败仍不提示；旧宿主返回无该字段时
  用非空 group id 兜底。数据源 4 项新用例 + 3 项 widget 用例通过（页面未改）。
- **测试**：`remote_composer_commands_test.dart` 11 项、`remote_goal_plan_test.dart` 14 项、
  `remote_conversation_page_test.dart` +11 项、`composer_commands_test.dart` +2 项、
  `remote_conversation_live_source_test.dart` +4 项、`remote_model_route_hint_test.dart` 3 项。
- **已知取舍**：`+` 用本页底部弹层容器而非设计字面的 `CommonPopupBox`（避免重构共享
  `RemoteComposer` 并牵动首页）；首页输入条文案未改；goal 行按「其它宿主指令」处理（D6 延期）；
  审批预设（B3）未做，盾牌仍为旧四项文案。

#### 3.2.7 本批新增能力（P5 第六批：B3 审批预设 + 首页/goal 收尾）

- **宿主**：`apps/remote-host/cordis.patch.yml` 启用 `permission`（`disabled: false` 一行；`auto`
  仍随 auto-review 单独决定；`ui-permission` 不启用——远程宿主无 Web 前端）。宿主自测（隔离 4779）：
  `runtime.permissions.presets.available=true`、catalog 3 项（read-only/workspace-write/danger-full-access）、
  `/permission` 命令成功、`session.projections.permissions.currentValue` 随切换更新。
- **App**：`composer_commands.dart` 抽出 `PermissionCallSurface`（= `ComposerCommandSurface` 别名）与
  共用件（`permissionPresetNeedsConfirmation`/`permissionPresetLabel`/`SessionPermissionRiskConfirmation`），
  本地 `SessionPermissionPage` 行为/文案不变；新增 `remote_permissions.dart`
  （`RemotePermissionSurface`/`RemotePermissionCatalog.parse`/`RemotePermissionController` 三态 +
  每次打开重读 + 失败可重试 + `/permission <值>` 写回后重读投影）；`RemoteComposer` 盾牌改为真实
  preset 列表（当前项打勾、`danger-full-access` 二次确认、未启用/未连接置灰带原因）；删除
  `RemoteApprovalSheet` 四项 Codex 占位；会话页输入区上方显示「权限预设：<当前值>」。一次性审批卡片
  不变（预设只影响新请求）。
- **③ 收尾**：首页输入条三个入口（`+`/权限预设/模型）置灰并给出统一可操作说明
  「进入会话后可添加附件与指令、切换权限预设与选择模型」（未连接时「连接后可输入消息并新建会话」）；
  `+` 弹层 `goal` 行置灰「远程会话暂不支持设置长期目标」，不执行也不插草稿；其余宿主指令路径不变。
- **测试**：`remote_permissions_test.dart` 18 项、会话页 +6 项、首页 +2 项、`+` 弹层 +1 项；
  受影响面 315 项通过；`flutter analyze` 11 条基线。

#### 3.2.8 真机验收（B3 / C3 / 附件旁路 / ③，2026-11-16 02:05–02:15）

设备：OnePlus6 / Android 11（ColorOS），debug APK（含 B3/③/附件验收旁路），宿主 4777 已加载
permission patch（`git` 未提交状态）。

| 项 | 操作 | 结果 | 证据 |
|---|---|---|---|
| B3-1 | 打开远程会话 | 输入区上方与盾牌均显示「权限预设：工作区内修改」 | `p5c-b1-permission-presets.png` |
| B3-2 | 点盾牌 | 弹层列出 3 个真实 preset（仅可查看/工作区内修改/完全权限） | 同上 |
| B3-3 | 选「完全权限」 | 出现风险确认面板；未勾选「我已了解风险」时点「启用」无副作用 | `p5c-b2-permission-risk-confirm.png` |
| B3-4 | 勾选并启用 | 弹层收起，输入区上方与盾牌变为「权限预设：完全权限」（宿主 `/permission` 受理 + 投影重读） | `p5c-b3-permission-applied.png` |
| B3-5 | 切回「工作区内修改」 | 回显恢复，无需二次确认（非危险 preset） | — |
| C3-1 | 打开桌面创建的 `deepseek-official/deepseek-chat` 会话（宿主无该 provider 凭据） | 发送前出现「当前会话绑定的模型在电脑上不可用，发送时会自动改用电脑默认模型」+「选择模型」 | `p5c-c1-model-route-notice.png` |
| C3-2 | 点「选择模型」 | 打开模型 sheet（DeepSeek Account 目录；当前路由显示 unavailable） | `p5c-c2-model-sheet-from-notice.png` |
| ③-1 | 远程首页 | 输入条下方显示「进入会话后可添加附件与指令、切换权限预设与选择模型」；+ / 权限 / 模型均置灰不可点；无语音死按钮 | `p5c-c01-home-composer-hint.png` |
| ③-2 | 会话页 `+` →「目标 goal」 | 置灰并显示「远程会话暂不支持设置长期目标」；点按无副作用；其它指令仍可用 | `p5c-c2-goal-disabled.png` |
| ②-1 | debug 旁路附件验收脚本（3 MiB PDF 经 `dshStageAttachment` 暂存） | rail「已就绪」→ 发送成功；宿主会话记录 `user/message` 带 `file` 附件（`p5c-a-attachment.pdf`，3145728 B，sha256 attachmentId），模型回复确认收到 | `p5c-a1..a3-*.png`、`.cache/attachment-acceptance.log` |

**附件真机旁路**：系统 SAF picker 在本机 ColorOS 上仍无法选择文件（debug/profile 构建均复现，
`shouldRestrictStorageAccessFramework=true`）。为完成 App 侧真机取证，新增 **debug-only**
暂存入口：`MainActivity` 读取启动 Intent 的 `dshStageAttachment`（仅 `/sdcard/Download` 或本包
`files/` 白名单、canonical 校验、一次性消费），`AttachmentTransfers.pick` 有暂存结果时直接返回
与 picker 同形的结果，不启动系统 picker。release 字节码验证：`stage()` 方法体为空、`takeStaged()`
恒 null、MainActivity 无调用点。验收脚本
`apps/android/tool/acceptance-remote-attachments.mjs`（零新依赖，支持 `--dry-run`）。
**release/profile 的 SAF 限制仍存在**，产品侧换文件来源（系统文件管理器/相机等）与 App 扫码
一样留待后续评估。

#### 3.2.9 P6 第一批（可达性文档 + 配对终端二维码 + 通知取证）

- `apps/android/docs/remote-dsh/reachability.md`（390 行）：拓扑/端口/固定 CA 语义；只有「组网直连」
  与「L4/TCP 直通反代/隧道」可行，**任何终止 TLS 的中间层都会导致固定 CA 校验失败**；给出
  Tailscale/WireGuard、自有域名+端口转发、frp/nginx stream/HAProxy/socat/netsh 示例；明确
  Cloudflare Tunnel/HTTPS 反代/Tailscale Serve/ngrok 默认不可用；含换地址/换 CA/撤销设备对照表与安全清单。
- 新增 `apps/remote-host/src/pairing-qr.ts`（703 行，零依赖 QR 编码器，字节模式/EC M/版本 1–10）+
  `scripts/qr-selfcheck.ts`（16/16：KAT 与 qr 3.0.2 逐位一致、独立 RS 回读、TTY 分支）；配对日志在
  **stderr 是 TTY** 时打印字符画二维码 + 明文链接（重定向/CI 不打印）；`index.ts` 只留接线。
- `pairing-qr-design.md`：App 扫码（推荐长期解，需依赖批准）/PC 配对界面/短码三路线评估。
- 后台通知取证：宿主当前只发 `remote.deviceRevoked`，§8 的 taskCompleted/approvalPending/sessionChanged
  未实现；App 通知通道仅本地模式。最小实现 3 步（宿主映射 §8 → 复用 Kotlin 通知 → 前台服务持 WS）
  记录在 §4。
- 两个新发现记录在 §4：`publicOrigin` 不能用 443（WHATWG URL 归一化导致链接无端口）、WS 升级
  缺 per-IP 限速（protocol §2.2 声称的 429 未实现）。


`pnpm run hygiene` 在本机仍会失败，但逐条核对后都不是本功能引入的（改动前就存在或来自本机环境）：

| 失败门禁 | 原因 |
|---|---|
| vendor rescope | 仓库里 `docs/tool-catalog*`、`scripts/gen-tool-catalog.ts` 等上游同步残留，本轮未改这些文件 |
| application entrypoints / client packages / constraints | 本机存在被 `.gitignore` 排除的设计参考 checkout `apps/dsh-mobile/`，门禁把它当仓库应用扫描；另有若干空包目录（`packages/client/ui-deepseek-model-label-1017` 等）是历史遗留 |
| no new unknown casts | 报的是未改动的 `packages/api/session-controller/src/model-selection-projection.ts`，相对基线漂移 |
| Cordis config | 报的是未改动的 `apps/cli/tests/profiles/acp/cordis.yml` 测试夹具 |
| node-next types | 只扫 `packages/*/*` 与 `vendor/*`，不含 app 包；失败与新增包无关 |

本轮新增的包 / profile 引起的 `constraints`、`verify-product-use`、`verify-default-product-isolation`
三条失败已经通过 §3.4 的几处门禁支持改掉（现在这三条在本机只剩上表的既有噪声）。

### 3.3 真机验收（M1）

环境：PC `192.168.5.21`（局域网；默认路由是 VPN，所以配对链接地址用覆盖层显式指定），
手机 OnePlus6 / Android 11 `192.168.5.140`。

启动宿主（临时复制一份真实 DSH home，不动正在运行的桌面 App 数据）：

```powershell
$env:DSH_HOME = "$env:TEMP\dsh-remote-m1"   # 复制了 .credentials.yaml / sessions / storages
pnpm dsh --profile remote-host --patch .cache/remote-m1-host.overlay.yml --no-open
```

`.cache/remote-m1-host.overlay.yml` 只是测试覆盖层：配对窗口 15 分钟、`publicHost: 192.168.5.21`；
产品默认仍是 120 s 与自动选路。

验收步骤与结果（2026-11-15 17:07–17:12，全部通过）：

| 步 | 操作 | 结果 | 证据 |
|---|---|---|---|
| 1 | 启动宿主（复制 home + 覆盖层） | `wss://192.168.5.21:4777/app` 监听，日志给出配对链接 | 宿主日志 listening |
| 2 | 安装新 APK（先卸载旧包：debug 签名不匹配）并启动 | 冷启动后本地 runtime 就绪 | — |
| 3 | 侧栏 → 远程 DSH → 添加连接 → 粘贴链接 → 连接 | 配对成功（宿主日志 `pair-issued`），自动连上（`handshake-complete`，192.168.5.140） | `m1-01-pair-link.png` |
| 4 | 远程首页 | 设备胶囊 `DESKTOP-DCVQ…` 绿点；项目 `deepseek-harness-android` 展开 2 个真实会话 | `m1-02-remote-home-projects.png` |
| 5 | 点开会话「只回复两个字：收到」 | 真实历史窗口渲染（含此前 Node 端到端产生的轮次） | `m1-03-session-history.png` |
| 6 | 输入 `Reply with exactly: M1` 并发送 | 用户消息落位，出现「正在思考」流式行 | `m1-04-sending-thinking.png` |
| 7 | 等待回复 | 助手消息 `M1` 渲染完成（账号路由 `deepseek-account/deepseek-flash`） | `m1-05-stream-reply.png` |
| 8 | 杀进程重开 App → 再进远程页 | **自动连接**（无需点设备胶囊），设备名显示电脑名 `DESKTOP-DCVQ…` | `m1-06-reconnect-auto-connect.png` |

真机驱动方式（可复现）：`adb shell uiautomator dump` 读节点的 `content-desc`/`bounds`，
再用 `adb shell input tap` 点按；文本输入前先把输入法切到
`com.google.android.inputmethod.latin/.com.android.inputmethod.latin.LatinIME`
（中文输入法会把 `input text` 当成拼音组合，URL 进不去输入框），URL 整段用单引号包住发送。
Gboard 仍是中文拼音时，长按输入框会弹出「更改键盘」对话框，可在里面切到 English (US)；
纯数字查询不经过拼音组合，可用来验证搜索过滤。

**P5 第一批验收（2026-11-15 20:03–20:12，全部在真机通过）**：

| 步 | 操作 | 结果 | 证据 |
|---|---|---|---|
| 9 | PC 侧客户端在电脑上新建会话并播下一条需要越界写文件的请求（审批挂起） | 宿主 `interactions.changed` 推来 approval 请求 | 宿主日志 |
| 10 | 手机打开该会话 | 输入条上方出现「需要授权：pwsh」+ 输入摘要 + 拒绝/允许一次 | `p5-01-approval-card.png` |
| 11 | 点「允许一次」 | 宿主机执行命令，`remote-approval-device.txt` 写入 `APPROVAL-OK`；手机渲染完整回复与输出 | `p5-02-approval-result.png` |
| 12 | 点模型按钮 | 弹出会话模型目录（DeepSeek-V4.1-Flash / DeepSeek-V4-Pro + 推理强度） | `p5-03-model-sheet.png` |
| 13 | 选 DeepSeek-V4-Pro → 应用此模型 | 输入条显示 `deepseek-account/deepseek-v4-pro`，后续发送使用新路由 | `p5-04-model-applied.png` |
| 14 | PC 侧归档一个会话 → 手机菜单「已归档任务」 | 列出「只回复两个字：收到」，行内「恢复」 | `p5-05-archived-list.png` |
| 15 | 点「恢复」→ 返回首页 | 归档页变空态；首页刷新后该会话回到项目列表 | `p5-06-archived-restored.png` |
| 16 | 点头部搜索，输入 `1` | 进入搜索模式并过滤，空结果显示「没有项目和会话匹配…」+「清除搜索」 | `p5-07-search-filter.png` |
| 17 | 首页输入条输入草稿 → 点新建会话 | 打开新建的「未命名会话」；在其中发送首条消息收到 `OK`，模型路由为 V4-Pro | `p5-08-new-session-reply.png` |

**M1 结论：成立。** 手机原生连 PC、列真实项目会话、发消息并看到流式回复，全程不走 WebView。
P5 第一批（审批、模型选择、搜索、新建、归档）同样在真机通过。

**P5 第二批验收（2026-11-15 20:52–21:23，全部在真机通过）**：

| 步 | 操作 | 结果 | 证据 |
|---|---|---|---|
| 18 | 首页菜单 →「电脑文件」 | 打开宿主工作区根目录：共 72 项，目录优先（`.agents`/`apps`/…） | `p5b-01-file-browser-root.png` |
| 19 | 打开 `vitest.config.ts` | 文本查看器显示 24.8 KB、「已读 25372 个字符 · 文件末尾」与文件内容 | `p5b-02-file-text-viewer.png` |
| 20 | 首页菜单 →「设置」 | 「默认模型：deepseek-account/deepseek-v4-pro · 版本 0」；选 DeepSeek-V4.1-Flash 应用 | `p5b-03-settings-default-model.png` |
| 21 | 在会话里发一轮用 `write` 工具建文件的对话，然后立即「…」→「本次变更」 | 「第 6 轮 · 1 个文件 `.cache/device-diff5.txt`」，点文件看到差异（+hello5 行） | `p5b-04-workspace-changes-list.png` |
| 22 | 「…」→「归档会话」→ 确认 | 返回首页且该会话从项目列表消失；「已归档任务」列出它，点「恢复」后回到列表 | `p5b-05-home-after-archive.png` |
| 23 | 打开能力/锁定路由的边界 | 模型/重命名/变更/归档入口按握手方法表置灰带原因；已归档页从首页返回会刷新 | — |

本批修复的回归：真机第一次验证「发完一轮立刻打开本次变更」时拿到空窗口缓存
（`workspaceChanges.summary` 的 announcement 来自 follow 增量，而页面缓存停在发送前）。
修复是让「本次变更」数据源每次先用 `session.readWindow` 重新取权威窗口，缓存只作读失败兜底；
真机复验通过（步骤 21）。

**P5 第三批验收（远程终端，2026-11-16 00:12–00:18，真机全部通过）**：

前置：本机 `~/.android/debug.keystore` 丢失导致 debug 签名与已装 App 不一致，卸载重装并重新配对
（新 keystore 已备份到 `.cache/android/debug.keystore`；之后增量安装可 `adb install -r`）。宿主已重启
加载当前门面（`methods=93`，握手日志 `handshake-complete`）。

| 步 | 操作 | 结果 | 证据 |
|---|---|---|---|
| 24 | 远程会话页「…」→「终端」 | 打开终端页（stable destination），显示「还没有终端。点右上角新建。」 | `p5c-01-terminal-empty.png` |
| 25 | 点「新建终端」 | 手机屏幕出现 PC 的 cmd.exe banner：「运行中 · 离开页面后继续运行」+ Windows 版本行 | `p5c-02-terminal-pc-banner.png` |
| 26 | 输入 `echo TERMINAL-PHONE-OK` → 发送回车 | 屏幕出现 `TERMINAL-PHONE-OK`，命令在 PC 上执行 | `p5c-03-terminal-echo.png` |
| 27 | 输入 `dir` | 手机渲染 PC 工作区目录列表（`vendor`/`web`/`vitest.*` 等） | `p5c-04-terminal-dir.png` |
| 28 | 返回会话页再重新进入终端页 | 列表显示 `cmd.exe · D:\…\deepseek-harness-android · 运行中`；重进后屏幕快照恢复 | `p5c-05-terminal-list-running.png`、`p5c-06-terminal-reopen-restored.png` |
| 29 | 杀 App → 冷启动 → 自动重连 → 同一会话「…」→「终端」 | 仍是同一终端（PC 进程未中断），重进后 `dir` 输出快照恢复 | `p5c-07-terminal-after-restart.png` |
| 30 | 终端内「关闭终端进程」→ 返回列表 | 列表清空（「还没有终端。点右上角新建。」） | `p5c-08-terminal-closed-empty.png` |

**P5 第三批结论：远程终端真机成立**——手机创建并操作 PC shell、命令执行与输出渲染、离开页面后
进程继续、App 冷启动后自动重连并恢复同一终端屏幕、关闭后列表释放；同时验证了卸载重装后的
重新配对全链路（`device-issued` → `connection-opened` → `handshake-complete`）。

已知的 M1 范围外残留（见 §4）：附件上行 App 侧收尾与真机、输入区其余控件、审批预设、P6。

### 3.4 远程宿主为什么能跑起来（三个非显然事实）

1. **profile 是 shipped 模板**：`packages/util/official-bundles/src/bundles.ts` 的
   `remote-host` 模板 + `apps/remote-host/package.json` 的 `dsh.bundle`；`apps/cli` 必须把
   `@deepseek-ai/dsh-remote-host` 与 `@minnnng/dsh-android-runtime` 声明为依赖，否则加载器
   无法从安装锚点解析这两个 bundle（会报 `Cannot find package … imported from profiles/remote-host`）。
   为了让仓库级源码门禁认识这两个 app 侧包，另外补了三处：
   `tsconfig.base.json` 的 `paths` 映射、`check-workspace-constraints.ts` 的 app 发布文件策略、
   `verify-product-use.ts` / `verify-default-product-isolation.ts` 的包发现（`apps/android/runtime`）。
2. **facade 有生成物**：`apps/android/runtime/index.mjs` 依赖 `./question-carrier.mjs` 与
   `./secret-mask/*`；Android 打包时由 staging 脚本生成，PC 宿主直接加载该包，所以生成物
   随包提交（文件头标明生成器与 `--write`）。
3. **门面服务由 desktop 分支提供**：`platform: desktop` 走晚绑定传输，`appRuntimeFacade`
   在依赖集齐后才 provide；初始化异常会记日志并重新抛出（避免插件看似加载、实际永远等不到服务）。

### 3.5 模型路由（真机联调的关键）

远程宿主的会话默认模型路由由 `apps/remote-host/cordis.patch.yml` 设为
`deepseek-account/deepseek-flash`（账号登录，和桌面/App 一致）。**已存在的会话会沿用自己
上一次的 `request/header` 路由**：桌面 App 里创建的会话通常记着 `deepseek-official`
（需要 `DEEPSEEK_API_KEY`），这种会话在只带了账号凭据的宿主机上发送会以
`llm-deepseek: no API key for provider route "deepseek-official"` 失败。

现在有三层兜底：① 会话页模型按钮可切到宿主可用的模型；② 凭据类发送失败会自动读
`settings.describe` 的 `agent-default-model`，不同则 `session.selectModel` 后重试一次（带常驻提示）；
③ 首页「设置」可直接改宿主的默认模型（revision 冲突会重读）。真机上已把宿主默认模型从
V4-Pro 改成 V4.1-Flash 验证写入链路。剩下的产品决定只剩「桌面创建会话的锁定路由要不要在
创建时前置提示」，记录在 §4.2。

---

## 4. 剩余工作（按优先级；已完成项见 §9）

1. **附件上行（App/宿主/真实 e2e/真机旁路验收全部完成）**：宿主 `attachments-desktop.mjs` + App
   反向应答/分页读/rail/`attachmentIds` 全部落地；真实 e2e 3 项附件检查 PASS；真机端因本机 ColorOS
   的 SAF picker 全禁用，用 **debug-only 暂存旁路**完成真机验收（3 MiB PDF → rail 已就绪 → 发送 →
   宿主会话记录 file 附件，见 §3.2.8）。剩余产品化项：release 包没有旁路，本机 ROM 上仍无法从系统
   文件选择器选文件——需要换文件来源（自带文件浏览/相机/分享入口）或换 ROM 验证，属产品决策。
2. **输入区能力（B1/B2/B3 与收尾全部完成）**：`+` 弹层数据驱动、方案模式、B3 审批预设
   （宿主 `permission` 已启用、手机真实 preset 列表 + 二次确认、真机切换通过，见 §3.2.7/§3.2.8）、
   首页输入条文案与 goal 行置灰均已完成。语音与 goal 按 D6/D7 不做。
3. **模型路由前置提示（C3 真机通过）**：`routableProviders` 判定 + `unavailableProviders` 语义；
   真机打开 `deepseek-official` 会话在发送前出现提示并可进模型 sheet（§3.2.8）。
4. **反向请求 id 格式**：**已修**——`JsonRpcLineTransport` 增加可选 `requestIdPrefix`（默认不变，
   `packages/sdk/protocol/tests/transport.spec.ts` 3 例覆盖），宿主传 `h-`，App 改 `a-<uuid v4>`；
   协议测试 22/22 通过。
5. **`remote.status` 超时 15 s**：宿主初始化慢时可能被误判为失败；真机未复现，保留观察。
6. **配对输入（终端二维码已落地；App 扫码 / PC 配对界面待做）**：宿主在 stderr 是真终端时
   额外打印字符画二维码 + 明文链接（`apps/remote-host/src/index.ts:568`、`:1645-1662`；
   日志重定向时不打印，现有日志字段与 e2e 行为未改），手机用能复制原文的扫码工具扫出链接
   再粘贴。仍缺：① App 内扫码（需批准新增相机/解码依赖，1–2 天）；② PC 侧配对界面
   （`remoteHost.pair()` 已可用，留给 PC 端 UI，2–3 天）。路线评估、校验证据与真机验收清单见
   [pairing-qr-design.md](pairing-qr-design.md)，外网接入见 [reachability.md](reachability.md)。
7. **PC 分发**：`@minnnng/dsh-android-runtime` 仍是 `private`，远程宿主作为产品分发前要决定
   它的发布身份（P6）。
8. **workspace 变更快照的保留语义**（已知限制）：`workspaceChanges` 只在宿主**当前进程**
   保留本轮快照，宿主重启后旧会话的「本次变更」会降级为「不可用」；快照还包含 git 工作区
   里并发的其它改动（并发 agent 同时改文件时会出现在同一份 summary 里）。这是宿主服务语义，
   App 已按可见降级处理；如果产品要求跨重启回看，需要在宿主侧持久化。
9. **电脑文件浏览的范围**：门面 `workspace.files.*` 的根是宿主进程 cwd（单一工作区），
   不是 App 首页选中的项目目录；后续若要按项目浏览，需要在宿主侧按 workspace/project 暴露根。
10. **终端已知边界**：`read` 只等待正在应用的屏帧（App 450 ms 轮询会在下一轮收敛）；
    create 后立即挂 retain 使「创建后从未 read」的终端在连接存续期间不被空闲回收（断连释放）；
    `display` 行尾可能多一个空格（App 有 `view` 时不使用 `display`）。记录在
    terminal-design.md 与适配器注释里，不阻塞。
11. **真机 debug 签名**：本机 `~/.android/debug.keystore` 曾丢失，重装后新 keystore 备份在
    `.cache/android/debug.keystore`；换机/清缓存前先确认它还在，否则又要卸载重装并重新配对。
12. **真机 60 fps 性能目标（新，进行中）**：目标与验收判据、测量方法、当前基线（4 个场景）、
    热点结论与优化计划见 [performance.md](../performance.md)。现状：首页滚动栅格成本主要来自
    液态玻璃背景捕获（关闭玻璃 p95 17.26→9.61 ms）；流式会话与远程终端的瓶颈在 UI 线程重建
    （build p95 21–45 ms，与栅格无关）；文件列表仍有首帧栅格尖峰。下一步按 performance.md §4
    的收益顺序优化并复跑同一套场景。
13. **后台通知（本轮只取证 + 设计，未实现）**：取证结论是「宿主确实发 notifications，但不是
    protocol §8 那四条」——宿主只发 `remote.deviceRevoked`（`apps/remote-host/src/server.ts:1500-1548`）；
    `task.completed` 与 `interactions.changed` 已经在线上（`apps/android/runtime/task-completion.mjs`
    的 `transport.notify('task.completed', …)`、`apps/android/runtime/interactions.mjs:277`），
    但它们属页面投影线（protocol §7.3、§8.1 明确 `remote.*` 是另一条线）。App 侧收到 `remote.*`
    只处理了 `remote.deviceRevoked`（`apps/android/lib/remote_connection.dart:498-501`）；系统通知
    通道只在本地模式生效：Kotlin `AgentService` 把本地 runtime 的 `task.completed` /审批帧交给
    `TaskCompletionNotifications.completed()` / `ApprovalNotifications.sync()`（`apps/android/android/app/src/main/kotlin/com/minnnng/dsh_android/AgentService.kt:821`、`:828`），
    另有前台服务在 `BackgroundExecution.kt`。远程模式不启动这些通道，也没有把 WS 放进前台服务，
    App 退后台/被杀连接即断。**最小实现分三步**：(1) 宿主 side 把 `task.completed`/`interactions.changed`
    映射成 §8 的 `remote.taskCompleted`/`remote.approvalPending`（只加发帧，不改协议、不动方法表，
    ~0.5–1 天 + e2e 断言）；(2) App 收到 `remote.*` 时经既有 `dsh/runtime` MethodChannel 调 Kotlin
    既有通知类（复用渠道与点击路由，~1–2 天）；(3) 真后台送达需要把远程连接放进前台服务
    （Kotlin 服务持 WS，或把 transport 移进 Node runtime，~3–5 天，属架构改动）。建议先做 (1)+(2)
    覆盖「App 在前台/刚退后台」，(3) 等 App 侧后台架构与产品决定；不要半实现。
14. **`publicOrigin` 不能用 443（新发现）**：WHATWG URL 会把 wss 的默认端口 443 归一化掉
    （`new URL('wss://h:443').origin === 'wss://h'`），配对链接因此不带端口，而 App 缺省补 4777
    （`apps/android/lib/remote_pairing.dart:163`）→ 连到错误端口。修法二选一：`normalizePublicOrigin`
    保留 443，或 App 按 scheme 补默认端口；在此之前公网入口用 8443 等非 443 端口。详见
    [reachability.md](reachability.md) §3.5。
15. **WS 升级鉴权没有 per-IP 限速**：protocol §2.2 写的是「同一源地址 5 秒内最多 5 次尝试，超出
    HTTP 429」，当前只有 `/pair` 有对端限速（`apps/remote-host/src/pairing.ts:176-195`），升级路径
    没有限速分支（`apps/remote-host/src/server.ts` 无 429 逻辑）。公网暴露时用网络层兜底；要补的话
    在 `handleUpgrade` 前加对端计数。43 字符随机令牌下实际不可爆破，属资源占用/日志噪音风险。

---

## 5. 工作方式

### 5.1 Agent 分工与文件所有权

并行开工时**一个文件同一时间只能有一个 Agent 在改**。当前分工：

| 角色 | 拥有文件 | 产出 |
|---|---|---|
| host-launch | `apps/remote-host/package.json`、`packages/util/official-bundles/src/bundles.ts` | `dsh --profile remote-host` 能起监听 |
| host-pairing | `apps/remote-host/src/server.ts`、`index.ts`、`pairing.ts`、`devices.ts`、`apps/remote-host/scripts/*` | `/ca.cer`、`/pair`、设备表写入与撤销、握手门禁、桌面 `native.*` 装配 |
| app-pairing | `apps/android/lib/remote_pairing.dart`、`remote_connection.dart`、`remote_transport.dart`、`api_streams.dart` | 配对可成功、TLS 失败终止、协议常量对齐 |
| app-conversation | `apps/android/lib/remote_dsh_page.dart`、`remote_dsh_live_source.dart`、`remote_dsh_conversation.dart` | 会话页接真实 `session.readWindow` / `session.send` |
| lead | `apps/android/lib/ui.dart`、`chat_sidebar.dart`、`main.dart`、此手册、`AGENTS.md` | 导航与外壳、评审、合并 |

`host-pairing` 独占 `server.ts`/`index.ts`：握手门禁与 `native.*` 装配都在它手里，其他 Agent 不要碰这两个文件。

### 5.2 并发纪律

- 不要在并行 Agent 之间跑 `pnpm install`（会同时改 lockfile）。需要装依赖先跟 lead 说。
- 每个 Agent 结束前自查：`analyze` 无新增告警、相关测试通过、`git status` 里只有自己的文件。
- 交付时报告**跑过的命令与结果**，不要只写「已完成」。

### 5.3 验证分层

| 改了什么 | 至少跑什么 |
|---|---|
| host 的 TS | `pnpm exec tsc -p apps/remote-host/tsconfig.json` + 冒烟（改了传输/鉴权时） |
| App 的 Dart | `flutter analyze`（只看新增）+ 受影响测试文件 |
| 协议常量 | 对应测试 + 真机过一次 |
| UI 导航 | `test/destination_navigation_test.dart` + 真机 |

---

## 6. 硬约束

1. **全屏目的地不能套娃**：入口用页面自己的 `routeDestination` 常量，推入走 `ui.dart` 的 `openDestination`；已经在栈顶时只收起菜单。回归测试在 `test/destination_navigation_test.dart`。
2. **DSH 有的才做**：新增控件前先回答「数据源是哪个门面方法」。答不出就不做（「剩余用量」「云端设备」已经因此砍掉）。
3. **协议唯一来源是 `protocol.md`**：实现与协议不一致时，要么改实现，要么先改协议并说明理由，不允许「代码里先这样」。
4. **配对 = 完全信任那台电脑**：任何削弱 TLS、凭证保管、撤销语义的改动都不接受；明文只允许 debug 构建且必须显眼标识。
5. **本地模式零回归**：所有传输/流控改动必须同时通过本地测试；App 的本地链路是既有产品的生命线。
6. **不引 WebView、不 fork dsh-mobile**：那个仓库只当设计参考（`.gitignore` 已排除 `apps/dsh-mobile/`）。

---

## 7. 已知缺陷清单

状态列：`已修` / `待修` / `已知偏差（接受）`。

| # | 缺陷 | 位置 | 状态 |
|---|---|---|---|
| 1 | 侧栏重复进入远程 DSH 叠层 | `chat_sidebar.dart` / `ui.dart` | 已修（`openDestination` + 回归测试 + AGENTS.md 约束） |
| 2 | 未知方法回 `-32603`，协议要 `-32601` | 共享包 `JsonRpcLineTransport` | 已知偏差（plan §12.5 记录） |
| 3 | `session.follow` 的 `args` 少了 `request` 包装，订阅被网关拒绝 | `remote_conversation_live_source.dart` | 已修（本轮；测试同步） |
| 4 | 远程会话声明 `window-ack` 却从未启用窗口化回执 | `remote_conversation_live_source.dart` / `api_streams.dart` | 已修（本轮：握手能力 → `setWindowAck`） |
| 5 | 远程首页按每条入站通知重读设备表 + `sessions.list`（流式时 ~20 次/秒） | `remote_dsh_page.dart` | 已修（本轮：只在阶段/宿主身份变化时重读） |
| 6 | 已配对电脑存在时首页不会自动连接，需手点设备胶囊 | `remote_dsh_page.dart` | 已修（本轮：仅一台且 idle 时自动连） |
| 7 | 桌面创建、路由为 `deepseek-official` 的会话在只有账号凭据的宿主上发送失败 | 宿主 profile / `sessions.mjs` | 已修（本轮：远程会话页可切换模型 + 失败指引；见 §3.5/§4.2） |
| 8 | `remote.status` 超时 15 s；宿主初始化慢时可能误判 | `remote_connection.dart` | 已知偏差（真机未复现，保留观察） |
| 9 | 配对被 403 时的文案写成「来源校验未通过」，宿主语义是窗口过期 | `remote_pairing.dart` | 已修（文案） |
| 10 | 配对窗口消费后不可重开，只能重启宿主 | `apps/remote-host/src/index.ts` | 已修（本轮：`remoteHost.pair()` + 撤销后自动重开） |
| 11 | 宿主 `native.*` 拦截表缺 `web.*` / `scheduleWakeup.*`（协议 §5.2 要求本机应答） | `native-desktop.ts` | 已修（本轮：4 组方法本机应答，e2e 断言反向请求 0） |
| 12 | facade 未声明 `methods`/`unsupported`，宿主退回手写表并 warn | `apps/android/runtime/index.mjs` | 已修（本轮：93 项方法表 + 4 个 unsupported 由门面声明） |
| 13 | 远程审批只提供一次性 `allowed-once`/`rejected`，没有「本会话总是允许」 | 远程会话审批卡片 | 已知限制（与协议的一次性授权一致；预设策略留给 P5） |
| 14 | 反向请求 id 是 `req_…` / `a-<计数>`，协议要 `h-…`/`a-<uuid>` | 共享 transport / `remote_transport.dart` | **已修**（`JsonRpcLineTransport` 可选 `requestIdPrefix`；宿主 `h-`、App `a-<uuid v4>`；协议测试 22/22） |
| 15 | 远程会话「…」菜单只有重命名，没有从手机归档会话 | `remote_dsh_conversation.dart` | 已修（本轮：「归档会话」确认后写 `library.sessionArchive`，首页刷新，归档页可恢复） |
| 16 | 发完一轮立即打开「本次变更」时读到空窗口（announcement 来自 follow 增量，页面缓存停在发送前） | `remote_conversation_live_source.dart` | 已修（本轮：变更数据源每次先 `session.readWindow` 取权威窗口，缓存仅读失败兜底；真机复验） |
| 17 | workspace 变更快照只在宿主当前进程保留，且并发工作区改动会混进同一份 summary | 宿主 `workspace-changes` 服务语义 | 已知限制（App 已按「不可用」可见降级；见 §4.8） |
| 18 | 电脑文件浏览的根是宿主进程 cwd，不是首页选中的项目目录 | `workspace.files.*` 门面 | 已知限制（§4.9；需要宿主按 workspace/project 暴露根） |
| 19 | 配对只有粘贴链接，没有二维码/扫码与 PC 侧配对界面 | 宿主日志 / 配对页 | 待做（P6；`remoteHost.pair()` 已可用） |
| 20 | `detachAll` 同步中止 hold 后，同一 tick 的重连 `read` 复用已中止的 retain，新附件无保留额度 | `terminal-desktop.mjs` | 已修（本轮：hold 已 abort 时重开；单测覆盖） |
| 21 | `dispose()` 先扫记录后等在途 create，卸载期间落地的 create 会重新注册记录/挂 retain | `terminal-desktop.mjs` | 已修（本轮：先等完在途 create 再按最终记录释放；单测覆盖） |
| 22 | 连接断开后落地的 create 仍 eager retain，没有页面的终端在连接存续期间无法被空闲回收 | `terminal-desktop.mjs` | 已修（本轮：`detachments` 计数，断连后只缓存记录不挂 retain；单测覆盖） |
| 23 | 桌面宿主 `attachments.prepare` 在远程组合必然以 ENOENT 失败（宿主目录里没有手机附件的 `.bin`） | `attachments.mjs` / `native-desktop.ts` | 已修（本轮：新增 `DesktopAppAttachments` + 反向请求 `native.attachments.read`；协议 §5.2 一行；宿主单测 28 项。App 侧真机验收待完成） |
| 24 | 旧版 App 没有 `native.attachments.read` handler，附件 prepare 只能拿到 `-32601` | 协议 §5.3 / 宿主适配 | 设计语义（宿主映射 `attachment-file/unsupported`，手机显示「App 版本不支持」；升级 App 即恢复） |
| 25 | 文件附件在 `fileUploads.uploadStream` 流式上传期间的 `attachment-file/*`/`gateway/cancelled` 失败被 store 包成 `session/attachment-invalid`，App 拿不到可分类 code | `attachments-desktop.mjs` | 已修（`pull()` 记录映射后失败并在 store 包装之后原样重抛；33 项单测含 5 项真实包装模拟；真实宿主 e2e 第 18 项 PASS） |


---

## 8. 环境已知问题

### 8.1 本机工具链（2026-11-15 更新）

- **Flutter**：不在 PATH；用 `D:\JOB\CODE\Lab\deepseek-harness-android\.cache\flutter\bin\flutter.bat`。
- **Android SDK**：`D:\Android\android-sdk`（`ANDROID_HOME` / `ANDROID_SDK_ROOT` 必须显式设置）。
  NDK `28.2.13676358` 与 CMake `3.22.1` 已用 `sdkmanager` 安装并接受全部许可。
- **Gradle**：`GRADLE_USER_HOME=D:\JOB\CODE\Lab\deepseek-harness-android\.cache\gradle-user-home`。
  该缓存里已有依赖，但 **Gradle 发行包曾经缺失**；本轮用 PowerShell 直接下载
  `gradle-9.3.1-all.zip` 放进 `wrapper/dists/gradle-9.3.1-all/9ot9r568e8zfvvd4mn8rbu1j0/`。
  Gradle 还会按需下载 Android SDK Platform 36（`cmdline-tools` 直连网络可用）。
- **网络**：本仓库开发机的直连 HTTPS 可用；`127.0.0.1:7897` 的代理偶尔可用，Gradle 不要依赖它。
- **默认路由是 VPN**：`os.networkInterfaces()` 的第一个非回环 IPv4 通常是 `172.30.x`，
  手机连不上。远程宿主已支持 `Config.publicHost` 显式指定配对地址（默认自动取默认路由地址）。

### 8.2 Windows / 沙箱

- **Windows 文件权限**：工作区曾因 ACL 缺 `WRITE_OWNER` 导致沙箱无法授予写权限，表现为所有命令 `sandbox-local: windows-acl workspace grant failed`。已修复，备份与撤销命令在 `D:\JOB\CODE\Lab\dsh-acl-recovery\`。若再次出现，用 `diagnose-windows-sandbox-acl` skill 的那条命令，对失败的**深层路径**再跑一次。
- **`tsx` 在受限沙箱下 `spawn EPERM`**：esbuild 需要命名管道。要么把会话切到完全权限，要么用 Node 原生的类型剥离跑脚本。

---

## 9. 变更日志（append-only，最新在最上面）

### 2026-11-16 02:30 · lead（P5 收尾 + P6 第一批：B3 审批预设、真机验收批次、可达性文档与配对二维码）

**B3 审批预设（真机通过）**

- 宿主 `apps/remote-host/cordis.patch.yml` 启用 `permission`（一行；`auto` 仍随 auto-review 单独决定；
  `ui-permission` 不启用）。真实宿主 e2e 23/23 无回归。
- App：`composer_commands.dart` 抽出 `PermissionCallSurface` 与共用件（本地行为/文案不变）；
  新增 `remote_permissions.dart`（真实 catalog 解析、三态、`/permission` 写回 + 投影刷新、失败可重试）；
  `RemoteComposer` 盾牌改为 DSH 真实 preset 列表（当前项打勾、`danger-full-access` 二次确认、
  未启用/未连接置灰带原因）；删除 Codex 式四项 `RemoteApprovalSheet`；会话页输入区上方显示
  「权限预设：<当前值>」。一次性审批卡片不变。
- 测试：`remote_permissions_test.dart` 18 项、会话页 +6、首页 +2、`+` 弹层 +1；全量 `flutter test`
  **1815 项全通过**，analyze 11 条基线。
- 真机：打开会话 → 盾牌 → 3 个真实 preset → 选「完全权限」→ 未勾选风险确认时「启用」无副作用 →
  勾选启用后回显「权限预设：完全权限」；再切回「工作区内修改」（§3.2.8、`p5c-b*.png`）。

**③ 首页输入条 + goal 行收尾**

- 首页 `+`/权限预设/模型三入口置灰，输入条下方统一说明「进入会话后可添加附件与指令、切换权限预设与
  选择模型」（未连接时「连接后可输入消息并新建会话」）；无语音死按钮；会话页 `+` 的 `goal` 行置灰
  「远程会话暂不支持设置长期目标」，不执行/不插草稿。真机截图 `p5c-c01/c2`。

**② 附件真机验收（debug-only 旁路）**

- `AttachmentTransfers.kt` 新增 debug-only 暂存入口（`dshStageAttachment`，白名单 + canonical 校验 +
  一次性消费，复用 picker 同一条复制/登记实现）；`MainActivity.kt` 仅 `BuildConfig.DEBUG` 读取；
  release 字节码实测 `stage()` 空体、`takeStaged()` 恒 null、无调用点。Dart 产品代码零改动。
- 新增验收脚本 `apps/android/tool/acceptance-remote-attachments.mjs`（零依赖，`--dry-run` 9 个选择器通过）。
  真机验收 PASS：3 MiB PDF → rail「已就绪」→ 发送 → 宿主会话 `user/message` 记录 `file` 附件
  （`p5c-a-attachment.pdf`、3145728 B、sha256 attachmentId），模型回复确认收到（§3.2.8）。

**P6 第一批**

- 新增 `apps/android/docs/remote-dsh/reachability.md`（可达性/反代/隧道/安全清单，含 `publicOrigin`
  443 与 WS 限速两个新发现的记录）与 `pairing-qr-design.md`（App 扫码/PC 界面/短码三路线评估）。
- 新增 `apps/remote-host/src/pairing-qr.ts`（零依赖 QR 编码器）+ `scripts/qr-selfcheck.ts`（16/16）；
  配对日志在 stderr TTY 时打印字符画二维码 + 明文链接，`index.ts` 只留接线（1662→971 行）。
- 后台通知：取证结论与三步最小实现写入 §4 第 13 项（宿主只发 `remote.deviceRevoked`）。

**验证（本机全部跑过）**

- `flutter test` → **1815 项全通过**；`flutter analyze` → 11 条既有基线
- 真实宿主 e2e **23/23 PASS**（B3 patch 后；显式 `--session` 账号会话）
- 二维码自检 16/16；`tsc -p apps/remote-host` 与 `-p tsconfig.host.json` exit 0；宿主冒烟 14/14
- Kotlin `compileDebugKotlin` + `compileReleaseKotlin` BUILD SUCCESSFUL（release 旁路已证明折叠）
- 真机验收证据：`.cache/remote-device/p5c-b*/p5c-c*/p5c-a*`（B3/C3/③/附件）

### 2026-11-16 01:50 · agent-p6（P6 可达性：外网接入文档 + 终端配对二维码 + 通知取证）

**新增文档**

- [reachability.md](reachability.md)（新）：面向用户写清「局域网之外怎么连」。结论先行表 +
  三档可用做法（Tailscale/WireGuard 组网后直连；自有域名 + 公网 IP/端口转发；自有 L4 直通反代
  frp/nginx stream/HAProxy/socat）+ 明确不兼容清单（Cloudflare Tunnel、HTTPS 反代、
  Tailscale Serve/Funnel、ngrok 默认、反代只转发 `/app`）。逐项写清 Origin/Host/SNI/证书链/路径/
  空闲超时要求，附「换地址 / 换 CA / 撤销设备 / 令牌到期」行为对照表、安全清单（与 protocol §2
  逐条对照）、已知缺口、排障表，全部带 file:line 证据。两条重要事实：① App 固定 CA 是端到端的，
  **任何终止 TLS 的中间层都不可用**；② `publicOrigin` 不能用 443（见 §4 第 14 项）。
- [pairing-qr-design.md](pairing-qr-design.md)（新）：配对输入三条路线评估（① App 内扫码
  1–2 天、需批准相机/解码依赖；② PC 侧配对界面 2–3 天、依赖 ①；③ 短码手输 3–5 天、改协议且
  弱化信任模型，不做），推荐顺序；已落地终端二维码的实现/校验/限制；扫码工具兼容性清单与
  真机验收清单。

**宿主（只改 `apps/remote-host/src/index.ts` 的打印逻辑 + 一个新自检脚本）**

- 配对窗口打开处（启动、撤销后自动重开、`remoteHost.pair()`）在 **stderr 是 TTY** 时额外打印
  提示 + 字符画二维码 + 明文配对链接（`apps/remote-host/src/index.ts:568`、`:1645-1662`）；
  日志重定向（日志文件、e2e 捕获）时不打印；原有结构化日志的 `event`/`fields` 与 e2e 行为未改。
- 纯 Node QR 编码（字节模式、纠错等级 M、版本 1–10）+ 终端渲染，无新增依赖：
  `pairingQrMatrix()` / `renderPairingQrBlock()` / `writePairingQr()`（`apps/remote-host/src/index.ts:937-1662`）。
  掩码打分刻意对齐 App 已在用的 `qr 3.0.2`，同一段文本得到逐模块相同的矩阵。
- 新自检 `apps/remote-host/scripts/qr-selfcheck.ts`：14 组 KAT（版本 1–10 全覆盖 + 三种真实链接形态；
  期望摘要由 `qr 3.0.2` 生成并逐模块对照，另用 `qrcode@1.5.4` 复核数据区）+ 结构
  （定位/定时/格式 BCH/版本信息）+ Reed-Solomon 独立回读 + 终端渲染 + TTY 分支，**16/16 PASS**。

**后台通知（只取证 + 记设计，未写代码）**

- 结论：宿主只发 `remote.deviceRevoked`；`task.completed`/`interactions.changed` 已上线但属页面
  投影线；App 侧 `remote.*` 仅处理 deviceRevoked，系统通知只服务本地模式（Kotlin `AgentService`
  → `TaskCompletionNotifications`/`ApprovalNotifications`），远程模式没有前台服务持连接。
  最小实现三步（宿主映射 §8 通知 → App 经 MethodChannel 复用 Kotlin 通知 → 前台服务持 WS）与工期
  见 §4 第 13 项。

**验证（本机跑过）**

- `node --import tsx/esm apps/remote-host/scripts/qr-selfcheck.ts` → **16/16 PASS**
- `node <pnpm.mjs> exec tsc -p apps/remote-host/tsconfig.json` → exit 0；`-p tsconfig.host.json` → exit 0
- `node <pnpm.mjs> exec oxlint apps/remote-host/src/index.ts apps/remote-host/scripts/qr-selfcheck.ts`
  → 0 warning / 0 error
- `node <pnpm.mjs> exec tsx apps/remote-host/scripts/smoke-remote-host.ts` → **14/14 PASS**
  （传输/鉴权/配对/撤销链路未受改动影响）
- 矩阵交叉验证：14 段文本与 `qr 3.0.2` 矩阵摘要逐位一致；与 `qrcode@1.5.4` 去掩码后数据区一致
  （仅掩码选择不同，均合法；`HELLO` 这类输入后者会自动分段，属另一种合法编码）
- **未做**：真机扫码验收（需要人拿手机对终端，清单在 pairing-qr-design.md §4.3）；真实宿主
  TTY 启动验收（本机命令环境不是 TTY，打印分支由自检脚本伪装 TTY 覆盖）。

### 2026-11-16 01:00 · lead（P5 第四/五批收尾：附件 App 侧 + 真实 e2e 23/23、输入区 `+`/方案模式、模型路由判定）

**附件上行（App 侧完成）**

- `attachment_surface.dart`（接口化 `AttachmentDrafts`，本地零回归）、`remote_attachments.dart`
  （远程 surface + 错误码中文翻译）、`remote_native_bridge.dart`（连接建好即安装 `native.attachments.read`
  应答、草稿集合准入、其余方法回 `-32601`）；Kotlin `AttachmentTransfers.kt` 新增
  `attachment.read`（uuid 正则 + canonical 父目录 + 256 KiB 分页 + stat 对账）/`attachment.discard`；
  `MainActivity.kt` 注册；会话页附件 rail + `snapshotIds`/`consume`/发送失败保留 +
  `send/command` 的 `attachmentIds` 透传（含凭据兜底重发）。
- 新测试 `remote_attachments_test.dart` 20 项、会话页 +3 项；受影响面 237 项通过。
- 宿主缺陷修复（真实 e2e 暴露）：`fileUploads.uploadStream` 会把流内失败包成
  `session/attachment-invalid`；`attachments-desktop.mjs` 现在记录映射后的失败并在 store 包装后
  原样重抛（单测 28→33 项，含 5 项真实包装模拟 + 真实 store 复核）。
- **真实宿主 e2e 扩到 23 项并 PASS 23/23**：附件 `prepare` 3 页反向拉取 614400 B + eof 断言、
  missing-draft → `attachment-file/not-found` 中文、`session.send` 带 `attachmentIds`；
  cleanup release；`native-local` 只放行设计允许的 `native.attachments.read`。
- **真机阻塞（记录在案）**：本机 ColorOS 系统选择器对本 App SAF 选择项全部 disabled，
  附件真机验收换 ROM/来源再做（§3.2.5）。

**输入区（B1/B2）**

- `+` 弹层数据驱动：`ComposerCommandSurface` 接口化 + `remote_commands.dart` + 会话页底部弹层承载
  `ComposerCommands`（文件/模型/计划/宿主指令；export/skills 置灰写原因）；删除六项 Codex 占位与
  远程麦克风（语音不做）；`RuntimeController` 补 `ComposerCommandSurface`。
- 方案模式：`remote_goal_plan.dart`（`ChatPlanSurface` 接口 + `session.projections`/`session/control`/
  `session.command '/plan'`）+ 会话页 `ChatPlanDock` + 计划审核卡片（`intent.approve` /
  `interactions.dismiss` / `ChatPlanDocumentPage`）；`chat_plan.dart` 本地复用接口化（行为不变）。
- 测试：`remote_composer_commands_test.dart` 11 项、`remote_goal_plan_test.dart` 14 项、
  会话页 +11 项、本地 `composer_commands_test.dart` +2 项；受影响面全绿。

**模型路由前置提示判定（C1/C2）**

- `RemoteModelCatalog.routableProviders` 解析（旧宿主非空 group 兜底）、
  `RemoteConversationModelAvailability.unavailableProviders`（failures ∪ 不在 routableProviders
  的当前路由）；页面未改。数据源 +4 项、widget +3 项用例通过。C3 真机待做。

**验证（本机最终一轮）**

- `flutter analyze` → 11 条既有告警，无新增；`flutter test` → 见 §3.2 最终数字（全量在冻结改动后跑）
- `tsc -p tsconfig.host.json` exit 0；`pnpm run build:check` 2/2 gates
- 宿主真实 e2e **23/23 PASS**；Node 适配器测试 119 项全 PASS（终端 29 + 附件 33 + 邻接回归）
- APK 已重建（runtime archive SHA256 `ab5aea3cf1758781813c88c74b1e46c951332864dd3adb0fe4deb593ca980618`），
  含终端 + 附件宿主适配；真机安装后终端验收通过

### 2026-11-16 00:25 · lead（P5 第三批：远程终端 M1–M5 真机通过 + 附件上行宿主侧 + 反向请求 id 收尾）

**远程终端（新能力，真机验收通过）**

- 宿主：新文件 `apps/android/runtime/terminal-desktop.mjs`（桌面 `terminal-controller` ↔ 门面
  `terminal.*` 请求/响应适配，含 retain/attach/write-ack/上限/错误翻译/断连 detach）；
  `apps/android/runtime/index.mjs` 按平台二选一装配、`methods`/`unsupported` 按
  `terminalController` 实际存在与否声明、解绑时 `detachAll`。新单测
  `apps/android/tool/terminal-desktop-runtime.test.mjs` **29 项**，修掉 3 个真实缺陷（见 §7 #20–#22）。
- App：`terminal_runtime.dart`（`TerminalCallSurface`/`TerminalShellSource` 接口）、
  `remote_terminal_page.dart`（`RemoteTerminalRuntime`/`RemoteTerminalShellSource`/
  `RemoteSessionTerminalPage` 三态）；`session_terminal.dart`/`terminal_shells.dart` 只改依赖类型；
  会话页「…」菜单新增「终端」（与页内共用 `RemoteTerminalCapability` 判定），
  首页把同一条连接以 `RemoteControllerTerminalConnection` 交给会话页。新测试
  `remote_terminal_page_test.dart`（7 项）+ `remote_conversation_terminal_entry_test.dart`（5 项）。
- 真机：创建 PC shell → `echo`/`dir` → 离开页面进程继续 → 杀 App 冷启动自动重连后同一终端
  屏幕快照恢复 → 关闭后列表清空（`p5c-01…08` 截图，见 §3.3）。

**附件上行（宿主侧完成，App 侧施工中）**

- 协议：`protocol.md` §5.2 反向请求表追加 `native.attachments.read`（只加一行；方法表/帧/能力/版本未动）。
- 宿主：新文件 `apps/android/runtime/attachments-desktop.mjs`（`attachments.prepare` 经反向请求
  256 KiB/页拉取手机字节 → `fileUploads.uploadStream`；短读/对账/图片 digest/8 MiB 预览上限/
  release 不删宿主文件/detachAll 中止）；`index.mjs` 桌面分支接线与 `_pocket_error` 包装。
  新单测 `apps/android/tool/attachments-desktop.test.mjs` **28 项**。
- 设计：新文档 `apps/android/docs/remote-dsh/p5-remaining-design.md`（附件上行 D1–D8 决策、
  输入区 `+`/方案模式/审批预设、模型路由前置提示；D1–D8 全部按推荐值采纳）。
- App 侧（`attachment_surface.dart` / `remote_attachments.dart` / `remote_native_bridge.dart` /
  Kotlin `attachment.read/discard` / 会话页附件 rail）仍在施工，尚未计入本条的验收。

**反向请求 id（协议偏差收尾）**

- `packages/sdk/protocol/src/transport.ts`：`JsonRpcLineTransport` 增加可选
  `requestIdPrefix`（省略时保持 `req_<uuid>`），校验与 3 项新测试。
- `apps/remote-host/src/server.ts` 传 `h-`；`apps/android/lib/remote_transport.dart` 改成
  `a-<uuid v4>`；`vitest packages/sdk/protocol` 22/22 PASS。HANDOFF §7 #14 从「已知偏差」改为已修。

**宿主 e2e**

- `e2e-remote-host.ts` 扩到 **20 项**：新增 `terminal.shells`、`terminal.read` 错误码翻译、
  `terminal.create + write + read`（轮询到屏幕标记）、`terminal.resize/list/rename/close`；
  `REQUIRED_METHODS` 覆盖 8 个 `terminal.*`；cleanup 增加终端兜底 close。
- 真实宿主 `--send` 全跑：**PASS 20/20**（终端真实链路 4 项一次通过）。

**验证（本机全部跑过）**

- `flutter analyze` → 11 条既有告警，无新增；`flutter test` → **1722 项全通过**
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` / `-p tsconfig.host.json` → exit 0
- 宿主冒烟 14/14；真实端到端 **20/20 PASS**；协议 transport 22/22 PASS
- `node --test apps/android/tool/terminal-desktop-runtime.test.mjs` 29/29、
  `attachments-desktop.test.mjs` 28/28、邻接回归 85/85
- `pnpm run build:artifacts` 8/8 gates；`stage-runtime.ts` + `smoke-runtime.mjs` + `pack-runtime.ps1` 通过；
  APK 重新构建（runtime archive SHA256 `b8f80d9780b7c86c06da8f3816fd12f7bd2364bf8f55d628011083a6971691e9`）

**环境**

- 本机 `~/.android/debug.keystore` 丢失 → 卸载重装并重新配对；新 keystore 备份在
  `.cache/android/debug.keystore`。`~/ .android` 之外的 `D:\JOB\CODE\Lab\.dsh-cache\.android-home`
  旧 keystore 与已装包签名不符，不再是真机安装的默认来源。

### 2026-11-15 21:30 · lead（P5 第二批：文件浏览 / 远程设置 / 本次变更 / 归档动作 / 能力三态 + host plumbing）

**App（首页与独立页面）**

- 电脑文件：新目的地 `RemoteWorkspaceFilesPage`（+ 文本查看器 `RemoteWorkspaceTextPage`），经
  `workspace.files.info/list/read` 只读浏览宿主工作区；目录优先、面包屑、`nextOffset` 分页、
  刷新与错误态、非文本降级；首页菜单入口按能力三态置灰并显示原因。
- 远程设置：新目的地 `RemoteDshSettingsPage`，`settings.describe` 列出各节（其余只读、密钥不展示），
  置顶默认模型（`agent-default-model`）可用 `settings.mutate` 更换（revision 冲突重读）；
  真机把宿主默认模型 V4-Pro → V4.1-Flash 验证通过。
- 首页返回刷新：打开会话/归档/设置返回后重读列表。
- 新增文件：`remote_workspace_files_page.dart`、`remote_dsh_settings_page.dart`、
  测试 `remote_workspace_files_page_test.dart`、`remote_dsh_settings_page_test.dart`、
  `remote_dsh_home_capabilities_test.dart`、`remote_dsh_files_settings_facade_test.dart`、
  `test/support/remote_home_fakes.dart`。

**App（会话页）**

- 「本次变更」：新目的地 `RemoteWorkspaceDiffPage`，读 `workspaceChanges.summary/diff`，
  复用本地摘要/差异解析与 `WorkspaceDiffBody` 渲染；owner=每个页面一个、requestId=每请求 uuid v4，
  离开页面 `workspaceChanges.cancel`；本轮未结束/无变更/快照不可用/失败四态。
  **修关键回归**：数据源每次先 `session.readWindow` 重新取权威窗口再找 `workspace/changes` 序号
  （此前只读会话页缓存，发完消息立刻打开会读到空窗口）；真机复验通过。
- 「归档会话」：确认后 `library.sessionArchive {archived:true}`，返回首页并刷新。
- 能力三态：模型/重命名/变更/归档按握手 `methods`/`unsupported` 置灰带原因。
- 模型路由自动兜底：凭据类发送失败 → 读宿主默认模型 → 不同则 `selectModel` 后重试一次，
  常驻提示；无法自动切换时保留「选择模型」提示。
- 测试：`remote_workspace_diff_page_test.dart`、扩写 live source 与会话页测试。

**宿主 / 工具链**

- `tsconfig.host.json` 纳入 `apps/remote-host/scripts/**/*.ts`；`smoke-remote-host.ts` 做类型修正
  （`ensure` asserts、请求体类型），行为不变。
- e2e 扩到 16 项：`workspace.files.list`（根目录含 apps/packages）、`workspace.files.read`
  （AGENTS.md 全文）、`workspaceChanges.summary` 能力探测（有 `workspace/changes` 声明时严格
  `ok:true`，否则接受 `workspace-changes/unavailable` 降级——快照保留是进程内的，重启后属预期）。
- 反向请求 id：根因定位到共享 transport 硬编码 `req_…`，宿主侧无干净修法；给出上游
  「可选 id 前缀 + Dart 侧 uuid」的协调改法（§4.3），本轮不改代码。

**验证（本机全部跑过）**

- `flutter analyze` → 11 条既有告警，无新增；`flutter test` → **1686 项全通过**
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` / `-p tsconfig.host.json` → exit 0
- `pnpm exec oxlint`（改动文件）→ 0 error；宿主冒烟 **14/14**
- 真实宿主端到端 **16/16 PASS**；`pnpm run build:check` → 2/2
- **真机 P5 第二批**：文件浏览（根目录 72 项 + `vitest.config.ts` 全文）、设置改默认模型
  （revision 0→1）、发一轮 write 工具对话后「本次变更」显示「第 6 轮 · 1 个文件」及 +hello5 差异、
  归档 → 首页消失 → 归档页恢复；截图 `p5b-01…p5b-05`（见 §3.3）。

### 2026-11-15 20:20 · lead（P5 第一批：审批 / 模型选择 / 搜索 / 新建 / 归档 + 宿主完整性）

**App（远程会话页）**

- 远程审批：`interactions.list` + `interactions.changed` 投影为待处理交互；会话页输入条上方渲染审批卡片
  （`需要授权：<tool>` + toolCall 参数首行摘要 + 拒绝 / 允许一次），`interactions.reply`
  → `rejected` / `allowed-once`；提问按 `multiSelect` 渲染选项并提交 `{answers:[{id, selected}]}`，
  版本冲突/请求失效时回读快照。真机：允许一次后宿主机执行 `pwsh` 命令并回传输出。
- 远程模型选择：`api.call session.modelCatalog` → 底栏模型 sheet（模型 + 推理强度），
  `session.selectModel` 应用后输入条路由立即更新；发送遇到凭据类失败给出「选择模型」指引。
- 远程会话数据源新增：`RemoteConversationInteractions` / `RemoteConversationModel` 更新类型、
  `replyApproval` / `answerQuestion` / `fetchModelCatalog` / `selectModel` 方法、重连后重读
  `interactions.list`；页面新增审批卡片与模型 sheet。

**App（远程首页）**

- 搜索：头部原地切换搜索框，按项目名/会话标题过滤，空结果有清除入口。
- 新建会话：连接就绪后输入条可用；`library.catalog` 选工作区 → `library.sessionCreate` → 刷新并打开
  新会话页（输入条右侧新增发送按钮，有草稿才出现）。
- 已归档任务：新全屏目的地 `RemoteDshArchivedPage`（稳定 routeDestination），列出归档会话并可
  `library.sessionArchive archived:false` 恢复；从归档页返回首页时重读列表。
- 新增 `remote_dsh_live_source.dart` 的 `RemoteDshFacade`（catalog 缓存、sessionCreate、
  sessionArchive）与三组首页测试。

**宿主（PC）**

- `DesktopNativeProvider` 本机应答协议 §5.2 的四组方法：`native.web.preferences` / `native.web.save`
  （原子写入 `$DSH_HOME/remote-host/web-preferences.json`）/ `native.network.addresses`（默认路由 IPv4 优先）/
  `native.scheduleWakeup.begin/update`；e2e 断言客户端侧反向请求为 0。
- 门面在 `appRuntimeFacade` 声明 `methods`（93 项，协议 §4.2）与 `unsupported`；握手噪音消除。
- `remoteHost.pair()` 可重开配对窗口；撤销设备后自动重开并在日志给出新配对链接。
- 端到端脚本扩到 13 项（新增 `session.modelCatalog` 与 native 本机应答取证）。

**验证（全部在本机跑过）**

- `flutter analyze` → 11 条既有告警，无新增；`flutter test` → **1606 项全通过**
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` → exit 0；`pnpm exec oxlint`（改动文件）→ 0 error
- 宿主冒烟 **14/14 PASS**；真实端到端 **13/13 PASS**
- `pnpm run build:artifacts` 8/8；`pnpm run build:check` 2/2
- **真机 P5 验收**：审批卡片 → 允许一次 → 命令执行回传；模型切换到 `deepseek-v4-pro` 后正常发送；
  归档 → 恢复回首页；搜索过滤；首页新建会话 → 首条消息收到回复（`p5-01…p5-08` 截图，
  见 §3.3）

### 2026-11-15 17:15 · lead（M1 端到端完成）

**宿主启动接线**

- `apps/remote-host/package.json` 补 `dsh.bundle`、`files` 带上 `cordis.patch.yml`；`bundles.ts` 增
  `remote-host` 出厂 profile 模板；`apps/cli/package.json` 增 `@deepseek-ai/dsh-remote-host` 与
  `@minnnng/dsh-android-runtime` 依赖（否则加载器无法从安装锚点解析 bundle）；`tsdown.config.ts`
  把 `apps/remote-host` 纳入 Host bundle；`tsconfig.host.json` 增加 project reference。
- 修 facade 生成物缺失：`apps/android/runtime/question-carrier.mjs` 与 `runtime/secret-mask/` 随包提交
  （`stage-question-carrier.mjs` / `stage-secret-mask.mjs` 新增 `--write`），PC 宿主可直接加载该包。
- 修 facade 依赖：`apps/android/runtime/package.json` 补 `@deepseek-ai/dsh-api-session-controller`、
  `@xterm/headless`、`@xterm/addon-serialize`、`js-yaml`、`zod`。
- 修 `remote-host` 配置：`deviceTtlMs` 上限单位错误（3 153 600 000 → 3 153 600 000 000 ms）；
  新增 `Config.publicHost`（多网卡/VPN 机器上显式指定配对地址），默认用 UDP 选路取默认路由 IPv4；
  `cordis.patch.yml` 恢复 `bash-sandbox`/`pwsh-sandbox`/`ptc-runtime`（否则恢复已有会话时 preset
  子作用域等 `shell`/`ptcRuntime` 永远失败），默认预设改 standard、默认模型路由改
  `deepseek-account/deepseek-flash`（桌面/App 一致的账号登录）。
- 修 facade 可诊断性：desktop 分支初始化异常现在记日志并重新抛出，不再"插件看似加载、实际永远
  等不到 `appRuntimeFacade`"；`AppStreams` 在远程连接缺 `owner` 时用协议 §6.4 的固定 owner。
- 新增真实宿主端到端脚本 `apps/remote-host/scripts/e2e-remote-host.ts`（11 项：配对链接 → CA 指纹 →
  /pair 单次令牌 → 固定 CA 的 wss → hello → 就绪 → 列表/读窗口/follow 快照 → 可选发消息取证 → 清理）。

**仓库门禁接线（让新增 app 包被仓库脚本认识）**

- `tsconfig.base.json`：`paths` 增 `@deepseek-ai/dsh-remote-host` 与 `@minnnng/dsh-android-runtime`。
- `scripts/check-workspace-constraints.ts`：`appPackageFiles` 增远端宿主的发布文件策略。
- `scripts/verify-product-use.ts` / `scripts/verify-default-product-isolation.ts`：包发现增加
  `apps/android/runtime/package.json`。改完后 `constraints` / `verify-product-use` /
  `verify-default-product-isolation` 三条门禁里由本功能引起的失败清零（剩余的既有失败见 §3.2.1）。

**App 侧**

- 修 `session.follow` 线上参数：typert 网关要 `args.request`（含 `address`、`activate`），原来少了包装，
  订阅会被 `gateway/bad-request` 拒绝；同步改测试。
- 修 `api.stream` 帧解析：AppApiStreams 交付的是 `type:"item"` + `value.type`，数据源原来按顶层
  `type` 判断，snapshot/增量全部被丢弃。
- 修窗口化回执：握手后按宿主 `window-ack` 能力调用 `setWindowAck(true)`（协议 §6.2/§6.4），
  数据源契约加 `windowAck`，测试覆盖 `upTo` 回执。
- 修首页刷新风暴：只在连接阶段/宿主身份变化时重读设备表与 `sessions.list`（原来每条入站通知都重读，
  流式期间 ~20 次/秒）。
- 首页自动连接：已配对电脑只有一台且空闲时自动连上（重启 App 后无需手点设备胶囊）。
- 设备显示名：连接后用宿主 `host.name` 作为电脑名（原来显示的是配对时上报的手机型号）。
- 配对 403 文案改为"配对窗口已关闭或过期"（宿主语义）。

**验证（全部在本机跑过）**

- `flutter analyze` → 11 条既有告警，无新增；`flutter test` → **1558 项全通过**
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` → exit 0
- `pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts` → **14/14 PASS**
- `node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url … --send "…"` → **11/11 PASS**
- `pnpm run build:artifacts` → 8/8 gates PASS；`pnpm run build:check` → 2/2 gates PASS
- `pnpm exec vitest run packages/util/official-bundles` → 2/2 PASS
- `pnpm exec oxlint`（本轮改动的 TS/JS 文件）→ 0 error
- **真机 M1 端到端通过**：配对 → 列真实项目/会话 → 发送消息 → 流式回复（截图 §3.3），
  App 冷启动后自动重连

### 2026-11-15 · lead（第一轮）

- 修复侧栏重复进入「远程 DSH」导致页面叠层：新增 `destinationRouteName` / `isCurrentDestination` / `openDestination`，侧栏全部目的地与 `main.dart` 的 `navigate` 统一走它；`RemoteDshPage.routeDestination` 作为唯一标识。新增回归测试 `test/destination_navigation_test.dart`（3 项）。
- 在 `AGENTS.md` 的 Conventions 里落了一条长期约束：全屏目的地不得叠层。
- 建立本手册。
- 验证：`flutter analyze` 无新增告警；`flutter test` 1520 项全通过；`tsc -p apps/remote-host` 通过；宿主冒烟 7/7。
