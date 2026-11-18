# 远程 DSH · 接力手册

> 这份文件是**唯一的入口**：新会话、新 Agent、或工作区被还原之后，先读它再动手。
> 每完成一轮交付，在 §9 追加一条记录；状态变化就改 §3，不要把过时结论留在正文里。
>
> 关键事实（2026-11-16 12:35）：**支持多种连接 DSH 的方式**已落地并完成真机验收：
> ① 粘贴配对链接（原有）；② **扫码配对**（应用内连续取景：CameraX 预览 + ZXing 3.5.3 逐帧解码；相机不可用时回退系统相机拍照，相册图片可识别；真机连续扫码验收待补）；
> ③ **局域网自动发现**（宿主 UDP 4778 广播应答，App「搜索局域网」一键配对；宿主侧 PC 探测 PASS，
> 真机因 Wi-Fi AP 客户端隔离未拿到广播，UI/空态/回退已在真机验证）；④ **USB/adb reverse**（真机连接
> PASS：host 日志 `peer/remoteAddress=127.0.0.1`）；⑤ **手动地址覆盖**（完整链接 + 可达地址，供反代/USB）。
> 多台电脑：设备胶囊显示电脑名与状态、切换失败保留 failed + 重试/切换、冷启动自动连上次成功设备、
> 菜单「移除已配对电脑」（均真机 PASS）。
> **P6 第三批完成**：宿主按协议 §8 发送 `remote.taskCompleted/approvalPending/sessionChanged` + App 系统通知
> （退后台弹、前台抑制、断开清理）并支持**点击通知直达远程会话**；**PC 配对设置页**（宿主内嵌回环 HTTP：
> 二维码/倒计时/USB 链接/设备列表/撤销，浏览器验收）；**App 拨号超时 12s**；**wss 443 修复**；
> 通知/配对界面/分发评估见 `pc-pairing-distribution.md`。
> **新增：远程会话「会话洞察」**——悬浮任务卡片（可展开 todos）+ 底部统计条（轮/步、tok/缓存命中%、
> 上下文%，点按详情弹层），数据来自 `session.projections`，已真机验证（§3.2.15）。
> 下一步见 §4（当前优先：修复 App stream limit 泄漏、PC 分发决策、60fps 优化暂停中）。
>
> 最后更新：2026-11-16 12:35（lead）
> 分支 `android`，最近提交见 `git log --oneline -10`
> 真机：`8a044bba`（adb 在线，OnePlus6 / Android 11；当前开发机 WLAN 已换到 `192.168.1.81`，
> 手机 Wi-Fi 处于断开状态，因此当前主用 **USB + adb reverse**；局域网直连/发现真机验证仍待换到
> 同一网段后补测。宿主覆盖层 `.cache/remote-m1-host.overlay.yml` 的 `publicHost` 已同步为新地址）
> 真机 App：debug APK（含扫码/发现/多设备/附件验收旁路）；性能测量用 `--target=lib/main_perf.dart`
> 的 profile 包，见 [performance.md](../performance.md)

---

## 0. 目标与验收

**目标**：手机上原生地使用 PC 上的 DSH 干活——不走 WebView，不重写对话内核。

**M1（技术可行性证伪点）**：真机连上 PC，列出真实项目与会话，发一条消息并看到流式回复。
M1 不成立，整条路线作废，回到 `remote-dsh-plan.md` §4 重新选型。

设计与协议不在本文重复：

- 选型、路线、阶段、风险：[remote-dsh-plan.md](../remote-dsh-plan.md)
- 线上协议（帧、鉴权、握手、方法表、流控、错误码）：[protocol.md](protocol.md)
- 设计参照截图：`docs/设计参照截图/远程DSH功能/`（用户提供，未入库）
  - 2026-11-15 的 1–8 号：远程 DSH 首页/菜单/设备列表/会话加载/输入区 `+` 弹层/权限审批等早期参照。
  - 2026-11-16 新增 3 张（`拉起键盘准备对话` / `聊天调整推理强度` / `浏览对话内容`）：官方 App 的
    对话页参照——键盘弹起时的输入区工具条（`+`/手/推理强度/麦克风/语音）、键盘上方的模型与推理强度
    选择条（「6.1 Sol 高」+ 4 档滑块）、对话内容里的工具调用摘要行（「已运行 N 条命令 · 调用了 N 个
    工具 >」）与回到底部按钮。
  - **差距备注**（下一轮候选，用户要求沿用 App 视觉语言、只借形式）：① 远程会话页已有「+ / 权限预设 /
    模型」三入口，缺「推理强度/模型」在键盘上方的快速选择条（当前在模型 sheet 内）；② 远程会话里的
    工具调用目前展开为调用内容行，可评估合并成「已运行 N 条命令 · 调用了 N 个工具」摘要行；
    ③ 键盘弹起时输入区工具条布局可对照优化（当前是输入框 + 三图标）。

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
| P6 可达性 | **第三批完成**：扫码配对（应用内连续取景；真机解码链路 PASS，连续扫码待验收）、局域网自动发现（PC 探测 PASS）、USB/adb reverse（真机连接 PASS）、手动地址覆盖、多台电脑管理与切换（真机 PASS）、后台通知步骤 (1)+(2)（宿主 §8 发送 + App 系统通知/点击深链，真机验证）、PC 配对设置页（浏览器验收）、App 拨号超时、wss 443 修复 | 待做：真机连续扫码验收、无隔离网络发现直连、approvalPending 真机链路、步骤 (3) 前台服务持 WS、PC 分发决策。见 §3.2.10–§3.2.14、`reachability.md`、`discovery.md`、`pc-pairing-page.md` |
| 会话洞察 UI | **完成（真机验证）**：远程会话页悬浮任务卡片（可展开 todos）+ 底部统计条（轮/步、tok 与缓存命中%、上下文%，点按详情弹层），数据来自 `session.projections` 四类投影，事件驱动刷新 | `remote_session_insights.dart`、`remote_todo_card.dart`、`remote_stats_bar.dart`；§3.2.15 |
| 输入区重构（新） | **完成（真机验证）**：按官方 App 参照重做悬浮输入卡——缩小/展开/推理面板三态，**首页与远程会话页共用**，本地聊天页也接入；修复键盘不弹、picker 进不去、计划状态误报、模型页 debug 断言等问题 | `pocket_composer.dart`、`remote_dsh_widgets.dart`、`remote_dsh_conversation.dart`、`remote_dsh_page.dart`、`main.dart`；§3.2.16–§3.2.17 |
| 设备互联插件（新） | **已实现并在本机官方 DSH 安装验证**：`packages/experimental/device-interconnect`（Settings→「设备互联」Tab；Host 以独立子进程托管 our-fork `remote-host`，通过本机配对页控制面 API 管理）；**长期配对**（30 天窗口、配对成功后自动续开、无倒计时）、端口/域名配置、设备列表/撤销、日志与运行器配置；配套 remote-host 控制面 JSON API 与 `/qr.svg` | 见 §3.2.18、`packages/experimental/device-interconnect/README.md`、`apps/remote-host/scripts/pairing-page-selfcheck.ts` |

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

#### 3.2.10 P6 第二批：多种连接方式（扫码 / 局域网发现 / USB / 手动地址 / 多台电脑，真机验收）

**入口**：远程 DSH →「添加连接」页现在是「连接电脑」三段式（粘贴链接 / 扫码配对 / 搜索局域网）+
可展开「手动地址与令牌（高级）」；三种方式最终都交给同一条 `RemotePairingFlow`（解析 → 取 CA →
指纹校验 → `/pair` → 保存设备），协议与信任语义零改动。

- **扫码配对**（2026-11-16 首批实现；2026-11-18 已改为应用内连续取景，见 §3.2.20）：系统相机 intent（FileProvider 授权缓存文件）+ ZXing core 3.5.3（Gradle 依赖，
  按最长边 1600/4096 两轮采样 + 0/90/180/270 旋转尝试，QR-only + TRY_HARDER + ALSO_INVERTED），
  Kotlin 侧解码后回填链接、由用户点「连接」；相机不可用/解码失败/取消都有可读降级文案。
  debug-only 图片解码通道（`dshPairingScanImage` 启动 extra + `remote.pairing.scanImage`）用于自动化；
  release 字节码已证明折叠。**真机验收**：生成的版本 8 QR 图经 debug 通道解码，文本与配对链接逐字一致
  （`.cache/remote-device/pairing-scan/`）；相机 intent 在 ColorOS 上能正常启动（截图 `p6-conn-scan-camera`），
  拍照扫码需人手持手机对屏，未自动完成。
- **局域网自动发现**：宿主新 `apps/remote-host/src/discovery.ts`（UDP 4778，`discoveryEnabled`/
  `discoveryPort` Config；探测 JSON `{v:1,probe:"DSH-REMOTE-DISCOVER",nonce}` → 单播应答
  `{kind,name,origin,instanceId,pairing:{open,pairUrl,expiresAt},nonce}`；只有配对窗口打开才带 pairUrl；
  同源 1s 限速、坏帧静默、端口占用降级 warn 不影响宿主）。App `remote_discovery.dart` 严格校验、
  instanceId 去重、2.5s 窗口、懒加载（只在搜索时启动）；发现到窗口打开的电脑可一键配对。
  **验证**：宿主自检 11/11、PC 端 UDP 探测拿到完整应答（含 nonce 回显）；真机「搜索局域网」空态
  （当前 Wi-Fi 被 AP 客户端隔离，手机到 PC 不通）与回退提示、重新搜索、扫码/粘贴入口均在真机验证；
  真机发现→一键配对待换到无隔离网络后补测。
- **USB / adb reverse**：宿主配对日志新增 `usbPairUrl`（`wss://127.0.0.1:<port>#instance=…&token=…`，
  与局域网链接同一张票据；叶子证书 SAN 恒含 127.0.0.1/localhost，固定 CA 校验不受影响）；TTY 下同时打印
  `adb reverse` 步骤。App 侧用「粘贴链接」直接粘回环链接即可（本机 ROM 上无需手动地址覆盖）。
  **真机验收**：`adb reverse tcp:4777 tcp:4777` 后配对成功（host 日志 `peer/remoteAddress=127.0.0.1`）、
  连接 ready、首页列出 8 个真实会话与项目。证据 `p6-conn-*`。
- **手动地址覆盖**：完整配对链接 + 可选地址覆盖（只换连接路径，instanceId/token 仍来自链接）；
  只给 host:port/token 时明确提示需要完整链接（没有 instanceId 无法验证 CA 指纹，不弱化校验）。
- **多台电脑**：设备胶囊条显示电脑名（连接成功时用 `protocol.hello` 的 host.name 回写）、当前连接高亮、
  点另一台切换（先彻底关闭旧连接再拨号）、点当前不重连、切换失败停 failed 并给「重试 / 切换设备」不静默回退；
  冷启动自动连「上次成功连接的电脑」（多台也生效）；菜单「管理 → 移除已配对电脑」仅删本机记录与令牌
  （不撤销宿主授权，二次确认写明）。**真机验收**：两台（LAN 旧设备 + USB 新设备）胶囊与在线/离线状态、
  切换失败态、移除旧设备后收敛为单台、冷启动自动连上次设备（USB）均通过；截图 `p6-conn-1/2`。
- **已知环境限制**：本次真机验收期间手机（192.168.5.140）与 PC（192.168.5.21）Wi-Fi 互 ping 不通
  （AP 客户端隔离/漫游到隔离 SSID），因此局域网直连与 UDP 发现只在 PC 侧验证到协议正确，
  真机上的「发现→直连配对」需换网络环境补测；USB 方式完全不受影响，可作为开发机常驻连接方式。
- **顺带发现**：切换到不可达电脑时「正在连接」持续时间较长（TCP 连接超时，无 App 侧连接超时），
  已记录为下一批优化项（给 `RemoteRuntimeTransport` 拨号加超时，失败态更快可见）。


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

#### 3.2.11 P6 后台通知①：宿主按协议 §8 发送 `remote.*` 系统通知线

**实现**：新 `apps/remote-host/src/notifications.ts`（`RemoteNotifications`，每条 ready 连接一个实例）
在 `createFacadeSink` 的 `notify` 上加一层观察：页面线照旧先写，随后按协议 §8 追加 `remote.*` 帧；
`index.ts` 在 bind/连接替换、`onClose`、宿主 `stop` 时创建/释放实例，并把门面 `library.catalog` 读到的
会话标题与所属项目注入。只在 ready 连接发送；发送失败只记一条 `remote-notify-failed` warn，不影响页面线。

**字段映射**（页面线来源 → §8 字段）：

| §8 帧 | 页面线来源 | 映射 |
|---|---|---|
| `remote.taskCompleted`（§8.2） | `task.completed {sessionId, turn?, endSeq?, preview?}` | `taskId`=`turn:<sessionId>:<turn>`（无 turn 时 `end-<endSeq>`，按 128 截断）、`sessionId`、`title`=会话标题（`library.catalog` 的 `projections.values.title`/行标题，取不到用 sessionId）、`workspaceId`=workspace 行 `sessionIds` 归属（拿不到就省略）、`status`=`completed`（运行时只在投影判定该轮 completed 时发页面线，失败/取消不发）、`turn`、`completedAt`=宿主时钟、`summary`=preview 压成单段纯文本（512） |
| `remote.approvalPending`（§8.3） | `interactions.changed {revision, requests[]}` 中新出现的 pending 交互 | `interactionId`=请求 `id`、`sessionId`、`kind`=`approval`/`plan`/`question`（计划审核按 App `planReviewOf` 规则识别）、`title`=工具名/首题首行、`summary`=审批 reason（≤1024；计划正文可能含代码块，不塞 summary）、`toolName`、`createdAt`=首次观察到的宿主时钟 |
| `remote.sessionChanged`（§8.5） | `session.event` 里 `type === 'session/title'` | `sessionId`、`revision`（每连接每会话从 0 单调 +1）、`title`、`updatedAt`=事件 `time`；`workspaceId`/`archived`/`removed` 不发（见下） |

**截断 / 上限 / 去重 / ready**：字段按 §8 表上限截断（id 128、title 200、summary 512/1024）并置
`truncated: true`；序列化后仍超帧（8/16/4 KiB）时按可选字段顺序整体丢弃（summary →
workspaceId/toolName），再逐级缩短 title，仍装不下就丢弃整条（绝不发超限帧）。同一
`interactionId` 每连接只发一次；未 ready 的观察直接丢弃且不消耗去重集合。**§8.5 为部分实现**：
标题变化已映射；归档/删除要 `sessions.changed`（无 payload）触发 `library.catalog` diff，
本批不做，App 仍靠页面线重读。

**验证**（原样摘录）：`notification-selfcheck` **PASS 11/11**（映射/截断/帧上限/去重/ready/降级/§8.5）；
`tsc -p apps/remote-host/tsconfig.json` 与 `-p tsconfig.host.json` exit 0；`oxlint` 改动 4 文件
0 error 0 warning；宿主冒烟 **14/14**；隔离宿主（4788 + 临时 DSH_HOME 副本，未动 lead 的 4777/PID 19168）
真实 e2e **PASS 23/23**，send 项附加断言原文：`remote.taskCompleted matches §8.2 (335 bytes,
title=4 chars, turn=4, truncated=false); page line task.completed observed`，cleanup 复验
`remote.* frames observed and validated: remote.taskCompleted×1`。默认首行 session 带 active goal 时
运行时会抑制 `task.completed`，该断言按设计降级为 SKIP（打印原因）；用 `--session <无 goal 的会话>`
可获得严格断言。`remote.approvalPending` 的真实审批链路不由 e2e 触发（需要模型发起需审批的工具，
噪声大、会挂起等待），由 selfcheck 覆盖映射，真机验收由 §4 第 18 条的 App 侧任务负责。

**lead 重启 4777 后的验证命令**（只重启宿主，App 不必参与）：

```powershell
# 1) 由 lead 停掉当前 4777 宿主（本任务未触碰该进程）
Stop-Process -Id 19168
# 2) 用既有覆盖层重启（加载 notifications.ts）
$env:PATH='C:\Users\JZ_Colin\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin;'+$env:PATH
node --import tsx/esm apps/cli/src/bin.ts --profile remote-host --patch .cache/remote-m1-host.overlay.yml --no-open
# 3) 从新日志取 pairUrl，跑 e2e（send 项含 §8.2 子断言）
node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url "<新日志里的 pairUrl>" --send "请只回复：收到" --timeout-ms 240000
# 若首行 session 带 active goal（断言显示 SKIP），换一个无 goal 的会话重跑：
#   --session <sessionId> 同上
# 4) 宿主日志应出现：remote-notify-sent {"method":"remote.taskCompleted",...}
```

#### 3.2.12 P6 后台通知②：App 消费 `remote.*` 并弹系统通知（真机验证）

**实现**：新 `apps/android/lib/remote_notifications.dart`（`RemoteNotification` 解析 + `RemoteNotificationDispatcher`
+ `RemoteNotificationBridge` 抽象）：按 protocol §8.2/§8.3/§8.5 严格解析（必填/类型/枚举/字段上限 + 帧字节
上限 8/16/4 KiB，坏帧整帧丢弃并 debugPrint）；`truncated` 只在正文来自 `summary` 时补「…」；去重
（审批按 `interactionId`、完成按 `sessionId+turn`，表上限 256）；**前台抑制在消费处**
（`WidgetsBinding.instance.lifecycleState == resumed` 时不弹系统通知，页面线照旧更新）；断连/切设备/
deviceRevoked 全部经 `_closeTransport()` 统一 `clear()`（清去重表 + `cancelAll`）并清 sessionChanged 水位。
`remote_connection.dart` 增加三条 `remote.*` 分支与 `remoteNotifications` 流、`lastSessionChange`、
`sessionRevision()` 暴露给页面层。

**Kotlin**：新 `RemoteNotifications.kt`，复用既有渠道 `task-completed`「任务完成」/`agent-requests`
「任务授权与提问」（IMPORTANCE_HIGH，幂等创建），notification tag = `pocket-remote:<kind>:<协议 id>`、
id 21/22；`cancelAll()` 只取消 `pocket-remote:` 前缀的项（不误清本地 `pocket-completed:`/`pocket-interaction:`）；
点击 Intent 打开 `MainActivity`（`pocket.route=remote`、`pocket.sessionId`、`pocket.remoteKind`、`pocket.remoteTag`，
**点击深链已接**，实现与失败分支见 §3.2.13）；Android 13+ 未授权/渠道关闭/通知总开关关闭时静默降级，不新增权限弹窗。

**真机验收（OnePlus6 / Android 11，debug APK + 4777 宿主重启后）**：

| 项 | 操作 | 结果 | 证据 |
|---|---|---|---|
| N1 完成通知 | 远程会话（session-1bada031）发消息后立即 Home 退后台，等宿主轮次完成 | `dumpsys notification` 出现 `id=21 tag=pocket-remote:taskCompleted:turn:<session>:11 channel=task-completed`（IMPORTANCE 4），宿主日志 `remote-notify-sent {"method":"remote.taskCompleted","bytes":292}` | 会话内 `dumpsys notification --noredact` 输出（含 channel/key/groupKey/sound 字段） |
| N2 前台抑制 | 前台再发一轮（OK2），宿主发送 turn 13/14 通知 | 宿主日志有 `remote-notify-sent`，但通知列表**只有** N1 的 tag（前台不弹，页面线正常显示回复） | 同上 |
| N3 清理 | 返回键退出远程 DSH 页（连接 `client-closed` 关闭） | 所有 `pocket-remote:*` 通知被 `cancelAll()` 清除，tag 列表为空 | 同上 |
| N4 审批通知 | 需要模型发起真实审批（本轮尝试 read-only 预设下执行命令、工作区外写文件均被沙箱直接拒绝/工具报错，未产生审批交互） | **未在真机触发**；映射与渲染由宿主 selfcheck（§3.2.11）与 App 单元测试（23 项）覆盖 | — |
| N5 点击通知 | 点击完成通知 | **已接远程会话深链**（§3.2.13）：打开对应远程会话；会话已归档/不在该电脑上、连接失败或无配对时落到远程首页并给出可见提示。本轮由单测覆盖，真机点击验收待 lead（命令见 §3.2.13） | 未截图（通知已在 N3 清理） |

**已知边界**：WS 仍由 Flutter 进程持有（未上前台服务），按 Home 后只在进程存活期间能收到并弹通知；
进程被杀/长时间后台会漏。真正的后台送达需要评估文档 §3 的前台服务架构（
[pc-pairing-distribution.md](pc-pairing-distribution.md) §3）。

**验证（原样）**：`flutter test` **1913 项全通过**（新增 23 项通知测试 + 连接层 8 项）；
`flutter analyze` 11 条基线；Kotlin `compileDebugKotlin`/`compileReleaseKotlin` BUILD SUCCESSFUL；
宿主 e2e **23/23**（send 项严格断言 `remote.taskCompleted matches §8.2 (292 bytes, title=22 chars,
turn=5, truncated=false); page line task.completed observed`，cleanup 复验 `remote.* frames observed
and validated: remote.taskCompleted×1`）。

#### 3.2.13 P6 后台通知③：点击通知深链打开对应远程会话

**平台层**：`MainActivity` 在 `configureFlutterEngine`（冷启动，含进程被杀后由通知拉起）与 `onNewIntent`
（App 存活）里用 `RemoteNotifications.takeLaunch` 校验并记录 `pocket.route=remote` + `pocket.sessionId` +
`pocket.remoteKind` + `pocket.remoteTag`。只接受本类 `OPEN_ACTION`、`route=remote`、非空且 ≤128 字符的
`sessionId` 与两种已知 kind；未知/损坏 extra 丢弃，取过的 extra 立即从 Intent 移除（Activity 重建不会
重复投递）。新方法 `dsh/runtime` → `notifications.launch.take` 返回 pending 的 JSON（无 pending 回 null），
**取一次即清空**；本地通知的 `session`/`tasks`/`approval` 路由仍由既有 `deliverNavigation` 经 `dsh/events`
分发，未改行为。

**Dart**：新 `remote_notification_navigation.dart`（`RemoteNotificationLaunch.parse` 严格解析 +
`RemoteNotificationLaunchSource` 抽象 + `RemoteNotificationNavigation` 消费器）；`main.dart` 在 App 启动
首帧后与每次 `resumed` 调 `consume()`（根页面未挂载时保留 pending，下次重试；读取失败静默降级）。
`RemoteDshPage` 新增 `notificationLaunch`：连接就绪且项目列表读完后按 `sessionId` 走既有
`_openSessionById` 打开会话（同一目的地标识，不叠层）。失败分支全部留在远程首页且可见：会话不在当前
列表 → SnackBar「会话已归档或不在该电脑上。」；连接失败 → 既有失败态 + 重试/切换设备 + SnackBar；本机
无已配对电脑 → 配对空态 + SnackBar；多台电脑且无「上次连接」记录 → 不猜测设备，提示先选择电脑；
读取设备表/会话列表失败 → 页面读取失败态 + SnackBar，不把用户留在 loading。

**设备归属限制**：协议 §8.2/§8.3 的通知负载没有来源 `deviceId`，多台已配对电脑时 App 无法判断通知来自
哪一台。深链因此与首页冷启动一致：只连「上次成功连接」的电脑（没有记录时恰好一台才连），不为了猜测
自动切换设备；若通知实际来自另一台电脑，会落在当前这台电脑的远程首页并提示「会话已归档或不在该电脑
上」，用户可在设备胶囊条手动切换后从列表打开。要做精确归位需要宿主在通知里带来源设备标识（协议变更，
不在本轮范围）。

**真机复验修复（lead 验收回馈，2026-11-16 11:37–11:52）**：

1. **冷启动深链抢跑连接**：原实现页面一挂载就自动连接，而设备令牌经本机凭据服务读取
   （`credentials.read`），`runtime.ready` 之前 AgentService 直接回「运行时正在启动」，界面因此先落在
   「本机凭据服务拒绝了这次操作…」失败态。现 `RemoteDshPage` 监听 `widget.runtime`：`runtime.ready`
   之前不发起自动连接、也不消耗「只自动连一次」的机会，就绪后补一次 `_load` 完成自动连接；设备胶囊 /
   失败页「重试」/「添加连接」在本机服务启动期间先给可见提示，不把连接层错误暴露给用户。
2. **连接失败清空了 pending**：原失败分支把 pending 清空，用户点「重试」连上后停在首页、不再打开通知
   会话。现 pending 只在**成功打开**、**明确不存在**（已归档/删除/属于别的电脑）或**离开页面**时清空；
   连接失败/本地运行时就绪前/读取失败都保留，失败原因按原因键去重、只弹一次 SnackBar，重试成功后仍会
   打开通知里的会话。新增 3 项 widget 用例覆盖：运行时未就绪→ready、失败→重试成功打开、pending 只
   消费一次。

**真机复验（2026-11-16 11:48–11:49，OnePlus6 / Android 11，debug APK 重装后）**：

| 项 | 命令/操作 | 结果 |
|---|---|---|
| 冷启动深链 | `am force-stop` 后 `am start -a …OPEN_REMOTE_NOTIFICATION -f 0x24000000 --es pocket.route remote --es pocket.sessionId session-1bada031-… --es pocket.remoteKind taskCompleted --es pocket.remoteTag turn:3` | **PASS**：约 8 s 自动进入该会话页（标题 `OK`，副标题 `DESKTOP-DCVQRNS · deepseek-harness-android`），无「凭据服务拒绝/运行时正在启动」，不再停在远程首页 |
| 无效 sessionId | 同上，sessionId 换成不存在的 `session-does-not-exist-…` | **PASS**：停在远程首页（`已连接「DESKTOP-DCVQRNS」` + 项目列表），底部 SnackBar「会话已归档或不在该电脑上。」 |

证据：两张 adb 截图（冷启动会话页 / 无效会话首页+SnackBar）随本轮任务报告提交，未入库。

**验证（原样）**：`flutter analyze` 11 条既有告警；Kotlin `compileDebugKotlin`/`compileReleaseKotlin`
`BUILD SUCCESSFUL`（exit 0）；新增 `test/remote_notification_navigation_test.dart` 15 项、扩展
`test/remote_dsh_home_page_test.dart` 5+3 项（该文件 33 项）全通过；相关既有测试
（remote_notifications / approval_navigation / destination_navigation / task_history_recovery 35 项、
main_chat_flow / widget / remote_connection / remote_conversation_navigation / remote_dsh_archived 56 项）全通过。

**真机验收（lead）**：debug APK + 已配对宿主，先进入远程会话发一条消息并立即 Home 退后台，等系统通知
出现后二选一：

1. **真实点按**（推荐，验证 PendingIntent 全链路）：在通知栏点该通知，App 回到前台后应直接进入那条
   远程会话（目的地面包屑为会话标题，不是远程首页）。
2. **用相同 Intent 模拟**（可复现；进程被杀=冷启动，App 存活=onNewIntent）：
   ```powershell
   # 冷启动：先杀进程，再带通知 extra 拉起（会话应自动连接并打开）
   adb shell am force-stop com.minnnng.dsh_android
   adb shell am start -n com.minnnng.dsh_android/.MainActivity `
     -a com.minnnng.dsh_android.OPEN_REMOTE_NOTIFICATION -f 0x24000000 `
     --es pocket.route remote --es pocket.sessionId <sessionId> `
     --es pocket.remoteKind taskCompleted --es pocket.remoteTag turn:3
   # App 存活：先打开 App 并 Home 退后台，再执行同一条 am start（走 onNewIntent）
   ```
   失败分支验收：把 `<sessionId>` 换成已归档/不存在的 id → 停在远程首页并出现「会话已归档或不在该电脑
   上。」SnackBar；断开电脑网络后再点通知 → 远程首页失败态 + 「通知里的会话没能打开」SnackBar；
   移除全部已配对电脑后模拟 → 远程首页配对空态 + 可见提示。



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

#### 3.2.14 P6 A1：宿主内嵌 PC 配对设置页（回环 HTTP + 二维码 + 设备管理）

**实现**：新 `apps/remote-host/src/pairing-page.ts`（零新依赖，`node:http`）：`PairingPageServer` 只绑
`127.0.0.1`（`Config.pagesPort` 默认 4780，0=临时端口），服务端渲染单页 HTML + `GET /api/state` JSON：
配对窗口状态/剩余秒数/过期时间、`encodeQrMatrix` → 内联 SVG 二维码、明文配对链接、USB
`adb reverse tcp:<port> tcp:<port>` + `usbPairUrl`、已配对设备（label/id 前 8 位/createdAt/lastSeenAt/
状态）、「重新打开配对窗口」与每行「撤销」（303 → `/`）。`apps/remote-host/src/index.ts` 接线：
`RemotePairingTicket` 增加 `usbPairUrl`（评估 §1.2 的接口增补 1）、`RemoteHostHandle.pages()` 数据源
（当前窗口/重开/设备列表/撤销/宿主身份）、`apply()` 在服务挂载后 start、effect 卸载时 stop；
`Config` 新增 `pagesEnabled`（默认 true，schema 校验）与 `pagesPort`（默认 4780）。页面端口绑定失败
只记 `pairing-page-failed` warn，宿主照常启动（与 UDP 发现同一降级语义）。

**安全**：只绑回环；所有请求校验 `Host` ∈ {`127.0.0.1:<port>`, `localhost:<port>`}（DNS rebinding）；
带 `Origin` 的请求必须同源（无 CORS 头）；POST 必须带进程启动时随机 CSRF token（隐藏表单字段，
`timingSafeEqual`，缺/错/重复 403）；`nosniff` + `no-store` + CSP（`default-src 'none'`、`connect-src
'self'`、`frame-ancestors 'none'`）+ `X-Frame-Options: DENY`；设备名 HTML 转义；JSON 只含
`DeviceSummary`（无令牌摘要）；token 只在窗口打开期间渲染/返回。日志 `pairing-page-ready`（URL）、
`pairing-page-failed`、`pairing-page-action`（action/method/result）不含 token 与 CSRF。威胁模型
（同机其它进程可读页面/日志属已接受、不要反代暴露本页）写在 [pc-pairing-page.md](pc-pairing-page.md) §5。

**与评估（[pc-pairing-distribution.md](pc-pairing-distribution.md) §1）的差异**：未采用一次性
`uiToken`，改为 Host+CSRF+Origin（页面 URL 不含 token，浏览器打开即用）；`status()` 增补未做
（页面只需要当前窗口 + 设备摘要，设备在线状态仍看 `lastSeenAt`）；二维码按评估结论只出 SVG。

**验证（原样）**：`node --import tsx/esm apps/remote-host/scripts/pairing-page-selfcheck.ts` →
**PASS 24/24**（HTML 契约/QR SVG/CSRF、`/api/state` 形状与窗口开关、reopen 换令牌、revoke 调用并模拟
`remote.deviceRevoked`、Host/Origin/CSRF/Content-Type/超大体积/方法错误 4xx、日志无 token、stop 释放
端口、端口占用降级）；`tsc -p apps/remote-host/tsconfig.json` 与 `tsc -p tsconfig.host.json` 均
exit 0；oxlint 改动 3 文件 0 error；宿主冒烟 **14/14**。本轮未截图（[pc-pairing-page.md](pc-pairing-page.md) §2 位置已定），真机/浏览器验收
（页面扫码配对 → 设备列表 → 撤销 → 自动重开）由 lead 在 4777 宿主上补；命令见
[pc-pairing-page.md](pc-pairing-page.md) §7.2。

#### 3.2.15 会话洞察：悬浮任务卡片 + 底部统计条（P6 后新增，真机验证）

**动机**：用户对照 DSH Web GUI 截图要求远程会话页也展示「悬浮/可展开的任务」以及「底部步数、缓存命中、上下文占用」，但**沿用 App 自己的视觉语言**（glass/Pocket 组件，中文），不照搬 Web 样式。

- **数据层**：新 `apps/android/lib/remote_session_insights.dart` 从 `session.projections` 的 `values` 解析四类投影
  （真机探针确认 values 有 23 个 key，目标 4 个全部存在）：`todos`（`TodoItem[]|null`）、`sessionStats`
  （turns/steps/llmMs/toolMs/ttftMs/decodeMs/decodeTokens）、`tokenUsage`（uncachedInputTokens/cacheReadTokens/
  cacheWriteTokens/outputTokens）、`contextPressure`（pressureTokens/projectedTokens/contextWindow）。
  派生缓存命中率对齐 Web `StatsPills`（整数%，四舍五入到 100% 时提高精度保持 <100 的真实性）、上下文占用
  `round(used/window*100)`；任何缺失/坏类型都不抛，只隐藏对应读数。
- **刷新**：`RemoteConversationSource.readInsights()` 默认实现复用 `session.projections`；live source 在首屏、
  重连、reload、`turn/start`/`turn/end`/`todo/write` 事件后单飞重读（无轮询、内容不变不推、失败保留上次读数）；
  页面持有 `_insights` 状态。
- **UI**：新 `remote_todo_card.dart`（收起行「任务 + 已完成/进行中/待处理」，展开为状态图标+文本清单、已完成划掉、
  限高滚动、展开状态由页面持有且轮次刷新不收起）与 `remote_stats_bar.dart`（输入区下方一行：`轮 X · 步 Y`、
  `N tok · 缓存命中 P%`、`上下文 Q%`，逐段缺失隐藏、一行放不下折叠成胶囊；点按 `showRemoteStatsSheet`
  查看进度与用时/TTFT/TPS、Token 四桶与合计、上下文口径）。只在 insights 变化时重建，无逐帧动画。
- **真机验收**（OnePlus6 / Android 11，debug APK + 4777 宿主，先让会话 `Write approval file with pwsh`
  用 `todo_write` 建 alpha/beta/gamma）：收起「任务 待处理 3」、展开三项「待处理：alpha/beta/gamma」；
  统计条「轮 16 · 步 25 · 481K tok · 缓存命中 96% · 上下文 2%」；详情弹层显示轮次/步数/模型用时/工具调用用时/
  首 token 平均 1.9 秒/输出速度 218 tok/s 与 token 四桶（合计 481,082 tok）。证据
  `.cache/remote-device/p7-insights-collapsed.png`、`p7-insights-todo-expanded2.png`、`p7-insights-stats-sheet.png`。
- **测试**：insights 解析 19 项、todo/stats widget 6+7 项、页面集成 61 项；全量 `flutter test` 1982 项通过；
  `flutter analyze` 11 条基线。
- **顺带发现并修复中的缺陷**：真机页出现「App stream limit reached」——宿主 `AppStreams` 以固定 owner
  `remote` 跨连接累积、连接关闭未清理，多次重连后触顶；修复见 §4 新条目。

#### 3.2.16 输入区重构：悬浮卡 + 缩小/展开/推理面板三态（用户参照官方 App 截图，真机验证）

**动机**：用户对照官方 App 对话页 3 张截图（`docs/设计参照截图/远程DSH功能/` 的「拉起键盘准备对话」「聊天调整推理强度」「浏览对话内容」）指出输入区形式不对：应为**悬浮输入框**，有**浏览时缩小 / 触发时展开**两种基础状态，以及**点按钮切换**的第三态（模型+推理强度面板）；但视觉沿用 App 自己的 glass/Pocket 语言。

- **共享组件** `apps/android/lib/pocket_composer.dart`：悬浮圆角玻璃卡（左右 16、底部 12、轻阴影）；
  - `browse`：缩小单行（`+` / 占位「在 <device> 上工作」 / 权限 / 右侧发送圆钮）；
  - `composing`：输入区 + 工具条一行（`+`、权限、推理表盘、发送/停止），高度一次 `AnimatedSize`
    200ms 过渡（减少动态效果时不挂动画）；
  - `picker`：输入行用 `Opacity+IgnorePointer` 常驻（保持焦点与 IME 连接，键盘不收起），
    面板「模型名 + 当前强度 › + 强度滑杆」叠在输入行上方；档位由调用方数据决定（有 2 档画 2 档，
    无档位只显示模型名）；再次点表盘/点聊天区退出。
- **远程会话页**：保留 `+` 弹层、权限预设、附件 rail、方案 dock、统计条（移到卡上方）、错误提示；
  模型按钮改为打开推理强度面板（复用 `RemoteModelCatalog` + `session.selectModel`）。
- **本地聊天页**：同一组件/三态；`+` 改为与远程一致的底部弹层承载 `ComposerCommands`；权限盾牌接
  真实 `SessionPermissionPage`；推理面板数据 `session.modelCatalog` + `session.selectModel`，模型行
  打开 `SessionModelPage`。
- **真机验收发现的缺陷及修复**：
  1. 点输入框不聚焦/不弹键盘（聚焦时 IME 尚未显示前的 metrics 抖动被误判成键盘收起 → 解焦 → IME
     取消 → 循环，logcat 出现 0.7s 内多次 viewport metrics）：改为**键盘显隐闩锁**（同值 metrics 直接
     返回）、键盘收起不解焦、点卡片 `requestFocus` + 下一帧 `TextInput.show`；
  2. 点推理强度进不了面板（`Visibility/Offstage` 会断开输入连接）：改为透明覆盖、metrics 不折叠 picker。
- **真机验收（OnePlus6/Android 11，debug APK）**：远程会话页缩小态单行悬浮卡；点卡片一次即展开 +
  键盘（`mInputShown=true`）；点推理表盘出现「DeepSeek-V4-Pro 高 ›」+ 4 档滑杆（App 绿色 accent），
  点「低」后状态条「推理强度已改为「低」」、卡上方回显变 `· 低`；再点表盘回输入态、按返回收键盘后卡片
  缩回单行；本地新对话页同样三态（缩小/展开/picker、`+` 弹层、权限盾牌）。证据
  `.cache/remote-device/p9-fix-browse.png`、`p9-fix-composing3.png`、`p9-fix-picker.png`、
  `p9-fix-picker-low.png`、`p9-local-browse2.png`、`p9-local-composing4.png`、`p9-local-picker.png`。
- **顺带修复**：远程会话页「无法确认计划模式状态：FormatException: 会话尚未提供可用的状态快照」
  常驻横幅——`session.control` 基线块没有 `kind`（只有 projections 应答有），旧 `_baseline` 把合法基线
  当错误；现区分「未就绪（有限重试后静默）」与「真失败（保留错误+重试）」。
  本地聊天页打开模型页时 debug 构建的 `setState() during build`——`plugins.load()` 首次通知微任务化。
- **已知差异/未做**：远程无取消接口，停止按钮暂不出现（组件已支持 `onStop`，协议/数据源后续补）；
  手形/麦克风/语音不做（无实现，组件留接口）；picker 为保留退出入口比参照多一行工具条；卡片目前
  在 Column 中不覆盖聊天内容（真正浮层需 Stack+列表底部留白，后续视觉 polish）。
- **测试**：pocket_composer 18、remote_conversation_page 71、main_chat_flow 24（含三态/键盘抖动/
  IME 请求）、plan 24、plugins_publish 4 等；全量 `flutter test` **2025 项通过**；analyze 11 条基线。

#### 3.2.17 输入区三态扩展到远程首页 + 视觉收敛（两台真机验证）

用户反馈「远程 DSH 首页输入条还是旧的一行、不悬浮、没有三态」「未展开时没有审核权限」「展开后按钮太大」后完成：

- **远程首页输入条重做**（`remote_dsh_page.dart`）：也改为悬浮卡三态——
  `browse`（紧凑 `+`、占位「与 <设备名> 新对话」、置灰发送圆钮）；`composing`（输入区 + 工具条：
  `+` 打开「添加与指令」说明弹层、推理按钮、发送；发送走既有 `library.sessionCreate` 新建并打开会话，
  创建中进度、失败保留草稿）；`picker`（电脑默认模型 + 默认强度**只读**面板，数据 `settings.describe`
  + 模型目录，第一行/说明行进入远程设置页，点表盘/点列表退出）。旧说明行删除，语义并入占位与弹层。
- **共享组件视觉收敛**（`pocket_composer.dart`）：缩小态去掉权限按钮（只剩 `+`/占位/发送圆钮）；
  工具条动作改为小图标（20dp 图标、40dp 热区、默认无大圆底，按下极淡底）；发送圆钮保持 44dp 强调色；
  picker 增加可选说明行。
- **会话页缩小态**（`remote_dsh_conversation.dart`）：权限预设与模型回显行只在展开态
  （composing/picker）渲染，缩小态只剩悬浮卡与会话读数；展开后两个入口行为不变。
- **首页 picker 真机缺陷修复**：点推理按钮后键盘收起/卡片缩回 browse 的竞态——增加 picker 粘滞标记
  与 effective mode，键盘/insets/metrics 事件不再折叠面板；进入面板不再扰动 IME。
- **真机验证（两台）**：
  - OnePlus6（`8a044bba`，Android 11）：首页/会话页三态、picker 滑杆、强度切换与回显、键盘收起缩回
    均通过；证据 `.cache/remote-device/p10b-home-browse.png`、`p10d-home-composing.png`、
    `p10d-home-picker.png`、`p10d-session-browse.png`、`p10d-session-composing.png`、`p10d-session-picker.png`。
  - OnePlus PLP110（`3B162D00E1K00000`，Android 17）：重新配对（USB adb reverse + 粘贴 `usbPairUrl`）
    后复验同一批状态，另测暗色主题；证据 `.cache/remote-device/p11-newdev-remote-home-browse.png`、
    `p11-newdev-remote-home-composing.png`、`p11-newdev-remote-home-picker.png`、
    `p11-newdev-remote-session-browse.png`、`p11-newdev-remote-session-composing.png`、
    `p11-newdev-remote-session-picker.png`、`p11-newdev-session-picker-dark.png`。
- **新机注意**：该机原有同包名 App 签名不同，`adb install -r` 报
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，需先 `adb uninstall` 再装（会清掉旧 App 数据）；
  `adb install` 流式安装在 Android 17 上偶发 `Failure [-99]`，改用「push 到 /data/local/tmp +
  `pm install -r -t`」成功；该机无英文输入法，中文 IME 下用 `adb shell input text` 会把 ASCII 转成中文，
  配对链接需先关 IME（`ime disable`）再用带单引号保护的 `input text`。
- **测试**：首页 page/capabilities 51 项、page 73 项、组件 21 项及邻接批次全绿；全量 `flutter test`
  **2041+ 项通过**；analyze 11 条基线。改动提交 `7f814b1278`、`8da0e7493d`。

#### 3.2.18 设备互联 DSH 插件 + 长期配对（官方 DSH 安装验证）

用户要求把远程接入做成 PC 上的「插件」、在 DSH **设置**里开「设备互联」Tab，并且配对不要倒计时、要长期可用。

- **新包** `packages/experimental/device-interconnect`（`@deepseek-ai/dsh-device-interconnect`，单包 host+client+bundle，`listedByDefault:false`）：Settings 注册 `settings.section` id `device-interconnect` / 标签「设备互联/Devices」，页面含运行状态与开关、长期配对二维码/链接（无倒计时）+ 重新生成、端口/对外域名/UDP 发现/配对页配置、已配对设备列表与撤销、运行器高级配置与子进程日志；文案 8 语言、原创 icon、中英 README。
- **占用形态**：插件 Host 只做**独立子进程托管**（`<node> <pnpm.mjs> dsh --profile remote-host --patch <生成的 overlay> --no-open`，可配 runner 路径/DSH_HOME），通过 remote-host 的本机配对页控制面 `GET /api/state`、`POST /api/pair`、`POST /api/devices/revoke`、`GET /qr.svg` 通信；插件与 DSH 主进程同生命周期，子进程崩溃/退出可观测并重启，关闭开关即停子进程。插件不 import 我们 fork 的运行时，装到官方 DSH 即可用（子进程仍要求本机存在我们的 fork checkout，README 已注明分发边界）。
- **长期配对**（remote-host）：`pairingTtlMs` 上限 900s → 90 天（默认仍 120s）；新增 `pairingLongTerm`：窗口按配置 TTL 保持、**每配对成功一台自动打开下一个窗口**（新 token），日志 warn 安全提示；配对页/控制 API 显示「长期有效」而非秒级倒计时；撤销设备仍自动重开。插件默认 `longTerm:true`、`pairingTtlMs:30 天`。
- **控制面**（仅 127.0.0.1 配对页）：`GET /api/state` 增加 `host{port,origin,listening}` 与完整 `pairing{pairUrl,usbPairUrl,expiresAt}`；`POST /api/pair`、`POST /api/devices/revoke`（需 `x-dsh-pairing-control: 1`，同源 Host 守卫）；`GET /qr.svg` 返回当前窗口二维码 SVG；响应无 CORS、no-store、不含令牌/私钥。
- **本机验证**（已安装到官方 DSH desktop profile）：`plugin_manager install_bundle` 从本地目录安装并 enable → Settings Tab 已注册；runner 指向本机 fork（node/pnpm/`repoDir`/profile=`remote-host`/`DSH_HOME=…\Temp\dsh-remote-m1`），开启后子进程启动，`/device-interconnect/api/state` 返回 running、`pairing.open=true`、`expiresAt≈30 天`、`qr.svg` 200（9.7KB SVG），子进程日志出现 `pairing-longterm-enabled`。设备列表沿用了原 remote-host 身份（34 台历史设备）。
- **已知边界**：长窗口=长期可配对入口（仅个人可信网络），需配合撤销/不用时关闭；插件控制面只允许本机回环；官方 DSH 分发仍需把 fork 运行时打包（当前 runner 指向本机 checkout）。
- **测试**：插件包 7 个测试文件 104 项、双 face tsc；remote-host `pairing-page-selfcheck` 30/30、`pairing-longterm-selfcheck` 8/8、`qr-selfcheck` 16/16、smoke 14/14；仓库 `typecheck` 5/5；`build:artifacts` 8/8；`pnpm run build:check` 待 lead 收尾。

#### 3.2.19 设备互联插件接入 SakuraFrp TCP 隧道

- 插件设置页新增「内网穿透（SakuraFrp）」卡：配置 frpc 路径（用户自备，不自动下载）、访问密钥（写-only：state 只回 `tokenConfigured`、不回显明文）、隧道 ID（逗号分隔多隧道）、公网地址（`节点域名:远程端口`）、可选自定义 `frpc.ini` 与附加参数；支持启动/停止/重试，展示子进程状态与最近日志。
- 隧道以**独立 frpc 子进程**托管（`frpc -f <token>:<tunnelIds> -n --disable_log_color`，或 `-c frpc.ini`），在 remote-host 就绪后启动、停止时先停隧道；隧道失败不影响 remote-host。
- **只支持 TCP 隧道**：我们的宿主固定自签 CA、端到端 TLS，HTTP/HTTPS 隧道在 frps 侧终止 TLS 会让固定证书校验失败；公网地址填 `https://` 会被拒绝/提示。
- 保存/启动时由公网地址推导 `publicOrigin = wss://<节点域名>:<远程端口>`（显式 443 保留）写入 remote-host overlay，运行中自动重启宿主，使配对链接与叶子证书 SAN 直接可用。
- 测试：插件包 9 文件 **185 tests**（config/tunnel/supervisor/routes/bridge/client 等）、双 face tsc、`verify-client-ui-i18n`/`verify-export-jsdoc`/`verify-package-meta`/README 摘要与 translation-pairing 均绿；仓库 `typecheck` 5/5；`build:artifacts`/`build:check` 见提交记录。
- 使用前需**完全重启 DSH**（宿主插件 JS 在启动时加载）才能看到新卡片；配置完成后用手机扫长期配对二维码（链接会变成 SakuraFrp 节点域名地址）。
- **一键自动接入**（task-40）：用户只填 SakuraFrp 访问密钥（token），插件调用 SakuraFrp **API v4**（Bearer token：`GET /user/info` 校验账号/冻结/实名/额度 → `GET /nodes` 自动选节点（flag&4 允许创建、非离线、非 BETA、非 VIP）→ `GET /tunnels` 复用同名 TCP 隧道或 `POST /tunnels` 创建 → `POST /tunnel/edit` 对齐 `127.0.0.1:<host端口>` → 由节点 `host`+隧道 `remote` 推导 `publicAddress`/`publicOrigin` → 必要时下载 frpc（用户点击触发，`frpc -V` 校验含 `sakura`）→ 重启 remote-host → 启动隧道）；写回 `tunnelId/nodeId/publicAddress`，在页面展示步骤进度、账号/额度/节点/隧道 ID/生效地址、API `important_warning_for_ai`；手动模式保留为高级折叠。API 调用/错误映射/额度与 token 边界见 README。

#### 3.2.20 扫码配对改为应用内连续取景（2026-11-18，用户反馈修复）

用户反馈：App「扫码配对」只是调用系统相机拍一张照片，没有持续取景；拍下的二维码照片也识别失败。已替换为应用内连续扫码：

- 新增 `PairingScanActivity.kt`：CameraX 后置相机连续预览 + ImageAnalysis 逐帧（350ms 限速、KEEP_ONLY_LATEST、RGBA_8888 帧折算灰度，分析帧请求 1280×720 以保证屏幕二维码像素）交给解码器；识别到即返回，用户不需要按快门，模糊/反光帧只算未命中并继续下一帧。
- 新增 `PairingQrDecoder.kt`：实时帧、相册图片、调试图片文件共用 ZXing 提示（QR-only、TRY_HARDER、ALSO_INVERTED）；图片额外尝试 0/90/180/270 方向、两轮采样，整图未命中再解中央 66%/50% 裁切。
- `PairingQrScan.kt`：优先启动应用内扫码页；相机初始化失败（无相机硬件/驱动异常）才退回系统相机 intent 拍照；`CAMERA` 权限在扫码页运行时请求，拒绝时回 `pairing/permission-denied` 且不自动改拍照；`remote.pairing.scan` 的 Dart 约定不变。
- 扫码页内有「从相册选择」，可识别截图/照片里的二维码；识别失败时留在扫码页给提示，可继续对准或换图。
- Manifest 增 `CAMERA` 权限（`uses-feature` 均为 `required=false`，无相机设备仍可安装并粘贴配对）与 `PairingScanActivity`；Gradle 增 CameraX 四个 artifact（`androidx.camera:*:1.4.2`），未新增 Flutter pub 依赖。
- Dart：`remote_pairing_scan.dart` 增加 `pairing/permission-denied` 映射与兜底文案；扫码中提示改为「正在打开相机…识别后自动填入」。
- 测试：`flutter analyze` 11 条既有告警无新增；`flutter test test/remote_pairing_scan_test.dart` 19 项通过（新增权限拒绝映射；页面取消/失败/覆盖确认等既有行为不回归）。**真机验收待 lead 构建 debug APK 后实际扫电脑屏幕二维码验证**（连续取景、相册选图、拒绝权限文案）。
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
6. **配对输入（扫码/发现/USB/手动地址已完成，PC 配对界面待做）**：App「添加连接」现支持四种方式
   （粘贴链接 / 扫码配对 / 搜索局域网 / 手动地址覆盖），宿主在 TTY 下打印二维码 + `adb reverse` 的
   回环配对链接。仍缺 PC 侧配对界面（`remoteHost.pair()` 已可用，留给 PC 端 UI，2–3 天）；
   真机拍照扫码与「发现→直连配对」需人手持/无隔离网络环境补测。实现与真机证据见 §3.2.10、
   [pairing-qr-design.md](pairing-qr-design.md)、[discovery.md](discovery.md)、[reachability.md](reachability.md)。
   **PC 侧配对界面评估完成**：推荐宿主本地回环设置页（二维码 + 窗口倒计时 + 设备列表 + 撤销/重开），
   方案、接口增补、依赖与工期见 [pc-pairing-distribution.md](pc-pairing-distribution.md) §1。
7. **PC 分发**：`@minnnng/dsh-android-runtime` 仍是 `private`，远程宿主作为产品分发前要决定
   它的发布身份（P6）。**评估完成**：现状（实测 tarball 依赖 `0.0.0`、registry 404、release/Desktop
   工具链阻断）、三条路线与发布前检查清单见 [pc-pairing-distribution.md](pc-pairing-distribution.md) §2；
   推荐升为 dsh 发布家族成员（改名 `@deepseek-ai/dsh-android-runtime`、目录不动），包名/受众决策在 §2.4。
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
12. **真机 60 fps 性能目标（进行中）**：目标与验收判据、测量方法、基线（4 个场景）、
    热点结论与优化计划见 [performance.md](../performance.md)。现状：首页/文件页栅格成本主要来自
    液态玻璃背景捕获（关闭玻璃 p95 17.26→9.61 ms）；流式会话与远程终端的瓶颈在 UI 线程重建
    （build p95 9 / 25 ms）。**2026-11-16 11:xx 冷机有效测量**（电池 25.9–28.8°C，
    `post-p6-cold-perf.json`）：home p95 28.76 ms/51.7%、session 30.40/32.9%、
    terminal 38.10/47.4%、files 29.80/100%，**全部仍未达门禁**；home 在不同冷机时段有
    17.4–28.8 ms 波动，最佳值与基线一致（说明无回归）。已尝试「长流式文本纯文本渲染」实验
    （build 9.03→7.74 ms、total 无变化）后回滚。**下一步**：玻璃捕获改造依赖 pub 包
    `material_ui 1.7.0`（不在仓库内），需要用户决定是否 fork/vendor 或降低默认玻璃质量；
    terminal 构建成本（App 侧）是无需产品决策的下一优化点。
13. **后台通知（步骤 (1)+(2) 已实现并真机验证；步骤 (3) 待产品决策）**：取证结论是「宿主确实发
    notifications，但不是 protocol §8 那四条」——宿主原先只发 `remote.deviceRevoked`
    （`apps/remote-host/src/server.ts`）；`task.completed` 与 `interactions.changed` 已经在线上
    （`apps/android/runtime/task-completion.mjs` 的 `transport.notify('task.completed', …)`、
    `apps/android/runtime/interactions.mjs`），属页面投影线。**已落地**：宿主
    `apps/remote-host/src/notifications.ts` 映射出 §8.2/§8.3/§8.5（标题线）并经 `createFacadeSink`
    观察发送（§3.2.11）；App `remote_notifications.dart` 严格解析 + 去重 + 前台抑制 +
    `RemoteNotifications.kt` 系统通知/`cancelAll`（§3.2.12）。**真机验证**：退后台收到
    `task-completed` 通知（tag `pocket-remote:taskCompleted:turn:<session>:<turn>`）、前台不弹、
    退出远程页连接关闭后通知清空。**剩余**：(a) `remote.approvalPending` 真机链路未触发（需模型发起
    真实审批；映射/渲染由 selfcheck+单测覆盖）；(b) **点击深链已接**（§3.2.13）：点击通知直达对应
    远程会话，失败分支（会话已归档/不在该电脑上、连接失败、无配对、多台无法判断来源设备）都落到远程
    首页并给出可见提示，单测覆盖、真机点击验收待 lead；(c) 真后台送达（进程被杀/长时间后台）需要
    步骤 (3)：前台服务持 WS 或 transport 移出 UI 进程，架构对比与推荐见
    [pc-pairing-distribution.md](pc-pairing-distribution.md) §3。
    (d) §8.5 归档/删除事件未发（需 `library.catalog` diff 与删除/归档歧义判定）。
14. **`publicOrigin` 不能用 443（已修）**：WHATWG URL 会把 wss 的默认端口 443 归一化掉
    （`new URL('wss://h:443').origin === 'wss://h'`），配对链接因此不带端口，而 App 缺省补 4777
    （`apps/android/lib/remote_pairing.dart:163`）→ 连到错误端口。
    **已修（2026-11-16）**：`normalizePublicOrigin` 检测输入里显式写的 `:443` 并保留端口，
    未写端口的地址行为不变；自检 `node --import tsx/esm apps/remote-host/scripts/public-origin-selfcheck.ts`
    （13/13：显式 443 保留、无端口不变、8443 不变、IPv6、大小写、非法输入）。详见
    [reachability.md](reachability.md) §3.5。
15. **WS 升级鉴权没有 per-IP 限速**：protocol §2.2 写的是「同一源地址 5 秒内最多 5 次尝试，超出
    HTTP 429」，当前只有 `/pair` 有对端限速（`apps/remote-host/src/pairing.ts:176-195`），升级路径
    没有限速分支（`apps/remote-host/src/server.ts` 无 429 逻辑）。公网暴露时用网络层兜底；要补的话
    在 `handleUpgrade` 前加对端计数。43 字符随机令牌下实际不可爆破，属资源占用/日志噪音风险。
16. **局域网自动发现（App 侧已接，真机广播待换网络验证）**：宿主在 UDP **4778** 上应答同网段手机的探测
    （`apps/remote-host/src/discovery.ts`，自检 11/11）；配对窗口打开时返回与日志/二维码同一条
    `pairUrl`，关闭时只回 `{open:false}`；坏帧静默、按来源 1 s 限速、TTL=1。App 侧 `remote_discovery.dart`
    已接「搜索局域网」入口（严格校验、instanceId 去重、2.5 s 窗口、懒加载）。剩余：① 真机阶段验证广播
    可达性（Windows 防火墙需放行专用网络 UDP 4778，AP 隔离会拦广播；本次验收环境手机/PC 被 AP 隔离，
    未能真机发现）；② 发现端口被占用时不自动重试绑定（重启宿主才恢复）。协议与排障见
    [discovery.md](discovery.md)。
17. **连接失败可见性（新发现）**：切换到不可达电脑（IP 不通）时页面可停在「正在连接」较长时间
    （TCP 连接超时，未给拨号设 App 侧超时）。建议给 `RemoteRuntimeTransport.connect` 加超时
    （例如 10–15 s）并映射到 `gateway/timeout`，让失败态与「重试/切换设备」更快出现。
    **已修（2026-11-16，默认 12s，错误码 `remote/connect-timeout`）**：拨号阶段由
    `RemoteRuntimeTransport` 自己计时（`defaultConnectTimeout = 12s`，可配置常量、不新增用户
    设置），超时按终止性失败处理（不自动重连），先 `HttpClient.close(force: true)` 拆掉在途
    socket/流、再关掉竞态里晚到的连接，并取消超时定时器；`RemoteConnectionController` 把它
    映射为 `phase=failed` +「连接电脑超时，请检查地址与网络后重试。」，可直接重试/切换设备。
    验证：`flutter analyze`（11 条基线）、
    `flutter test test/remote_transport_test.dart test/remote_connection_test.dart`（40 项全绿）。
18. **后台通知宿主发送端（本轮已落地，App 侧待真机验收）**：宿主 `apps/remote-host/src/notifications.ts`
    已按协议 §8 发送 `remote.taskCompleted`（§8.2）、`remote.approvalPending`（§8.3）与
    `remote.sessionChanged`（§8.5，仅标题变化；归档/删除待目录 diff）；selfcheck 11/11、隔离宿主
    e2e 23/23（send 项严格校验 §8.2）。App 侧消费（前台不弹 / 退后台弹 / 点击路由）由 task-21
    落地后需真机验收；系统通知仍只在 App 进程存活时可达（见第 13 条）。详见 §3.2.11 与 §9。
19. **PC 配对设置页（A1 已落地，浏览器/真机验收待补）**：宿主内嵌回环页
    `apps/remote-host/src/pairing-page.ts`（`http://127.0.0.1:4780/`，`Config.pagesEnabled`/
    `pagesPort`）已提供二维码 + 窗口倒计时 + 明文链接 + USB `adb reverse` 段落 + 设备列表 +
    重开/撤销；selfcheck 24/24、两个 tsc exit 0、oxlint 0 error、冒烟 14/14。剩余：① 在真实宿主
    （lead 的 4777 重启后）用浏览器走一遍「扫码配对 → 设备列表 → 撤销 → 自动重开」并按
    [pc-pairing-page.md](pc-pairing-page.md) §2 截图；② 设备在线状态未展示（需要宿主暴露当前绑定
    连接，评估 §1.2 的 `status()` 增补，本轮未改 `server.ts`）；③ 页面中文单语，是否双语待产品决定。
    契约、威胁模型、排障与验证命令见 [pc-pairing-page.md](pc-pairing-page.md)、§3.2.14。
20. **App stream 跨重连泄漏（真机 `App stream limit reached`，已修，真机复验待 lead）**：真机远程
    会话页出现「无法确认计划模式状态：…App stream limit reached; close an unused page before
    subscribing」，多次 App 重启/重连后触顶 `appStreamMaxSubscriptions=32`。
    **根因**：门面每个进程只建一个 `AppStreams`，远程连接又恒用固定 owner `'remote'`
    （`apps/android/runtime/streams.mjs`），记录的清理只挂在 `native.appDisconnected` 上；协议
    §6.6 要求“连接关闭 → 该连接全部流终止”，但远程宿主从不发 `native.appDisconnected`，
    `facade.unbind` 当时只 detach 终端/附件，不清理流 → App 进程被杀/网络断掉时没发
    `api.unsubscribe`，订阅记录与上游生产者（`session.follow`/`session.control`）永久累积。
    **多连接语义**：`server.ts` 的连接表允许多条已鉴权连接并存，但 `index.ts` 按协议 §11
    **同一时刻只服务一台设备**：新连接到达时先 `unbind` 旧连接再 `bind` 新连接，并异步关闭旧
    socket。因此“每条连接一个 owner”成立；替换窗口里旧连接在途请求仍带旧 owner，不会污染新连接。
    **修复（宿主侧，协议未变、App 未改）**：`apps/android/runtime/index.mjs` 新增
    `RemoteConnectionOwners` + `createRemoteFacadeService`：宿主给每条连接分配 `randomUUID()` owner，
    `bind(sink, owner)` 记住映射、`dispatch(method, params, owner)` 对
    `api.subscribe/ack/unsubscribe`、`references.*`、`workspaceChanges.*`、`document(s).*`、
    `session.attachmentFile.*` 注入 owner（客户端自带 owner 时保留，例如 App「本次变更」页面的
    `remote-<uuid>`——连接关闭不代页面释放，否则页面重连后同一 owner 会被资源的已关闭集合永久
    拒绝），`unbind` 释放该 owner 的流、references/documentPreview/attachmentFiles 等资源与会话
    历史租约；清理失败只 warn，不变成连接关闭失败/未处理 rejection。`native.appDisconnected`
    改为复用同一条 release 路径。`apps/remote-host/src/index.ts` 每连接生成 owner 并在
    `connection-ready` 日志中输出（仅宿主进程内使用的 UUID，不上线）。
    **App 侧核查**：`AppApiStreams.close()`/页面 `dispose()` 本来就会显式 `api.unsubscribe`
    （无缺陷，未改 `lib/`）；新增测试固化该行为（`api_streams_test.dart` close 退订全部在途观察
    且关闭后不再订阅；`remote_conversation_live_source_test.dart` 页面 dispose 后连接再 ready
    不重新订阅）。
    **验证（原样）**：新 `apps/remote-host/scripts/stream-lifecycle-selfcheck.ts` **PASS 11/11**
    （owner 逐连接唯一/上限与回执按 owner 隔离/关闭释放且不误伤其它连接/客户端 owner 保留/
    清理失败降级/40 轮 连接→订阅→关闭 回归 + 旧共享 owner 第 33 次订阅触顶夹具）；
    `tsc -p apps/remote-host/tsconfig.json` exit 0；`tsc -p tsconfig.host.json` exit 0；oxlint 改动
    2 个 TS 文件 `0 warnings and 0 errors`；宿主冒烟 **14/14**；隔离宿主（4789 + 临时 DSH_HOME
    副本，未动 lead 的 4777/PID 14796）真实 e2e **22/22 PASS**，宿主日志出现
    `connection-ready {…,"owner":"1c4d3a3e-…"}` 与干净的 `connection-closed`，无
    `facade-unbind-failed`/清理失败；App `flutter test test/api_streams_test.dart
    test/remote_conversation_live_source_test.dart` **31 项全绿**；`flutter analyze` 11 条基线。
    **lead 重启 4777 后的真机复验**：① 用同一源码启动命令重启宿主（`node --import tsx/esm
    apps/cli/src/bin.ts --profile remote-host --patch .cache/remote-m1-host.overlay.yml --no-open`，
    PC 宿主直接加载 workspace 里的 `apps/android/runtime/*.mjs`，不需要重新构建）；② App 打开远程
    会话页，宿主日志应出现带新 `owner` 的 `connection-ready`；③ **稳定复现旧 bug**：每次杀掉
    App 进程再重开同一会话（一次打开 = `session.follow` + `session.control` 两条流），重复 ≥17 次
    （旧实现第 33 条订阅触顶）；④ 修复后同样的 17 次循环不再出现「App stream limit reached」横幅，
    每次重连宿主日志的 `owner` 都是新值，且旧连接的 `connection-closed` 之后没有清理失败日志。

    **lead 真机复验结果（2026-11-16 13:0x）**：修复后重启 4777 宿主，App 冷启动/重连共建立
    **19 条连接、19 个互不相同的 owner**（宿主日志 `connection-ready {"owner":"<UUID>"}` 每条都变），
    全程 **零** `facade-unbind-failed` / `App stream cleanup failed`；修复前的 `App stream limit
    reached` 横幅在旧宿主上可稳定看到、重启后不再出现。另：同一宿主的真实 e2e 在修复后 **PASS
    23/23**（含 §8.2 `remote.taskCompleted` 断言与清理复验），宿主 6 个 selfcheck 全 PASS、
    `build:check` 2/2。开发机 WLAN 地址已从 192.168.5.21 变为 192.168.1.81（`publicHost` 已同步），
    手机当前走 USB/adb reverse，故 e2e/验证均以 192.168.1.81 进行。
    **风险/边界**：客户端页面自带的 owner（`workspaceChanges.*`）不在连接关闭时释放，其在途读取
    由自身超时收口（避免把页面 owner 记进已关闭集合导致重连后被拒）；owner 注入会让此前必失败
    的远程 `session.attachmentFile.*`/`document.*` 路径开始可用（这些方法本来就在
    `FACADE_METHODS` 里）；宿主若未传 owner 则退回旧的固定 owner 行为（兼容兜底）。

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
| 19 | 配对只有粘贴链接，没有二维码/扫码与 PC 侧配对界面 | 宿主日志 / 配对页 | **已修（2026-11-16）**：App 支持扫码（相机+ZXing）、局域网发现（UDP 4778）、USB/adb reverse、手动地址覆盖，宿主终端打印二维码与 USB 链接；仍缺 PC 侧配对界面（P6） |
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

### 2026-11-18 18:06 · lead（聊天 markdown 排版对齐 DSH Web token，已装真机）

- 用户反馈：手机远程会话正文排版乱/阅读费劲，要求参考 DSH 手机尺寸的 markdown 排版。
- 从 `MarkdownText.module.css`/`AssistantMarkdown.module.css`/`MessageItem.module.css`/`CodeBlock.module.css` 抽取 token 并对齐：正文 14/24、块间距 16、h1 21/30 h2 19/28 h3 18/26 h4 14/24（h1–h3 上 32 下 16）、列表 indent 18/marker secondary、引用左 2px 线 padding 14 无底色、hr 0.5px、行内 code 0.875em chip、代码块 radius 12/padding 16/**自动换行**（移除横向滚动）、表格单元格 16/10 横向滚动、链接 link 色 500 点状下划线、辅助文字 13/18 secondary、assistant 全宽 + 16px gutter、用户气泡右对齐 max 82%。标题不再用 Material 巨大 headline。
- 测试：chat_messages 24/24（新增 token 断言/窄屏代码换行无横向滚动/宽表格滚动不溢出）、邻接 142/142、analyze 仅既有 11 条基线告警；APK 18:04 构建并安装到 3B162D00E1K00000（lastUpdate 18:05）。
- 边界：flutter_markdown_plus 不暴露 li 6px/嵌套 4px/li>p 8px 等逐元素间距，本轮做到块节奏/行高/缩进对齐，未伪称精确。
- **提交**：见本次 commit。
### 2026-11-18 17:52 · lead（推送优先：长连接有推送时不再轮询，已装真机）

- 用户问「不是长连接推送吗」：确认手机↔remote-host 是持久 WSS；desktop 事件经本机 relay 到 remote-host 后立即经 WSS 页面线推送，App 收到 session.event/status 立即 setState（无节流）。
- 优化：会话页记录最近实时推送时间（snapshot/events/live/running），inferred 2.5s 定时器在 8s 内有推送时直接跳过 readNewer；静默超 8s 才兜底增量拉一次并在完成后重置窗口（静默期最多每 8s 一次，非 2.5s）；turn/end 后停止；退后台/dispose 不变。
- 测试：增量分页 6/6、相关回归 166/166、analyze 仅既有 11 条基线告警；APK 17:50 构建并安装到 3B162D00E1K00000（lastUpdate 17:50）。
- **提交**：见本次 commit。
### 2026-11-18 17:38 · lead（增量分页 + desktop 实时事件中继 + App 去缓存提示/错误脱敏/统计折叠持久化，已装真机）

- 用户反馈：卡顿/未响应、接收要分段、同步不即时、首页看不到哪些会话在工作、不要「已显示本地缓存」、不要显示 `session "session-..."` 原始错误、统计 bar 收起后要保持。
- **增量/分页**（task-54）：宿主 `session.readWindow` 新增 `afterSeq`/`maxEvents`/`maxBytes`（缺省不变；afterSeq 返回最早连续较新段，truncated/resetRequired 语义）；App 首屏小页（120 事件/1 MiB）、`readNewer/readOlder`、inferred 轮询改 2.5s 增量（无新事件不 setState）、「加载更早」前插不跳、内存上限 1200 事件。Node 16/16、live source 27/27、会话页 100/100。
- **desktop 实时事件中继**（task-55）：插件 `desktop-session-events.ts` 订阅 desktop `session/event`、`agent/status`，150ms 批/≤32 条/≤64KiB/积压 512 投递到 remote-host 新 `POST /api/session/events/relay`；remote-host 广播页面线 `session.event`（presentSessionEvent）、`session.status`、`sessions.changed`（500ms 节流），双端 seq 去重；`sessions.list` 合并 desktop `running:true`、`tasks.session` 补 live，首页绿点与进入会话即时显示。插件 297 tests、selfcheck 62/62、typecheck 5/5、build:artifacts 8/8、build:check 2/2。
- **App UI**（task-56）：删除「已显示本地缓存…」banner（仅瞬时转圈）；新增 `sanitizeRemoteUiMessage`（写句柄冲突→中文，移除 `session-`/原始英文 ID；所有会话页 notice/错误统一脱敏）；统计 bar 受控 + 缓存 `statsExpanded` 按设备+会话持久化（收起后重进保持，首次默认展开）；确认 `session.event` 无节流立即 setState（单帧测试）。
- 已安装最新 APK（17:02 构建，adb lastUpdate 17:36）到 3B162D00E1K00000；插件重载后 child/control/tunnel 正常、relay available、事件端点存在、桌面稳定。
- **提交**：见本次 commit。
### 2026-11-18 16:35 · lead（方案 B 桌面中继实现并实机启用验证）

- 方案 A 已安全回滚（c4eee2e880）；本轮实现 B：**不加载 App runtime/remote-host 进 desktop**，desktop 插件只做本机回环中继。
- 桌面中继（插件 `desktop-relay.ts`）：127.0.0.1 随机端口 + 32 字节 token，descriptor `<DSH_HOME>/device-interconnect/relay.json`（0600 意图，原子写，dispose 删除）；端点 `/relay/health`、`/relay/session/send`（纯文本、无附件；写冲突时在 desktop 进程用 typertGateway/connection 以 owner peer 执行 session prompt，queue 模式）、`/relay/session/status`、`/relay/sessions/status`；所有 handler try/catch，异常不逃逸 desktop。
- child 接入：remote-host 新增 `desktopRelayFile` 配置（overlay 自动写入）+ `desktop-relay-client.ts`/`session-relay.ts`；`session.send` 先本地，只有写句柄冲突且纯文本才中继一次，本地成功绝不中继；relay 失败保留原错误。通知：插件 `desktop-notifications.ts` 监听 desktop 事件映射 §8，经配对页控制 API 新端点 `POST /api/notifications/relay` 推给已认证手机连接；无连接安全丢弃。
- 实机验证：插件重载后 `relay.available=true`（http://127.0.0.1:60741）、`/relay/health` ok、`/relay/sessions/status` 返回 desktop 正在运行的 `session-35a17f25...` status=running、overlay 含 desktopRelayFile、child/control/tunnel 正常；桌面稳定（未加载任何 runtime 进 desktop）。
- 门禁：插件包 15 files **274 tests**、remote-host `relay-selfcheck` 全绿、typecheck 5/5、build:check 2/2、插件 bundle 与 remote-host lib 重建通过；README 中英更新。
- 边界：附件不中继；审批目前只覆盖工具审批（ask_user/计划审核后续）；状态 relay 端点已提供但 App 仍用事件推导（后续可合并）；relay token 明文文件（同机读取威胁模型）。
- **提交**：见本次 commit。
### 2026-11-18 16:17 · lead（安全回滚内嵌宿主实验；改走进程间中继方案 B）

- **崩溃事故**：lead 在真实 desktop DSH 实测 embedded 模式时，同进程加载的 App 运行时调用 `this.ctx.agents.roots()`（apps/android/runtime/interactions.mjs）在官方 desktop Host 上不存在，未捕获异常导致桌面 host 退出（用户看到「应用无法启动或已意外停止」）。DSH 重启后恢复；无数据丢失。
- **回滚**：撤销 embedded 实验提交（2300cee9f8）与安全闸提交（50cf46d53f），删除 `src/host/embedded.ts`、`runner.mode` 配置/UI/状态/测试及运行时诊断改动；配置 `runner.mode` 已改回/忽略，插件重载后以 child 模式运行（child/control/tunnel 正常，桌面稳定）。包级 262 tests 全绿、bundle 重建。
- **结论**：方案 A（同进程加载 App 运行时）不满足“不影响 PC 客户端”要求，**不再采用**；未适配前不会再次在真实桌面进程加载该运行时。
- **后续：方案 B（进程间中继）**：保留 child 宿主，在 desktop 进程内的 device-interconnect 插件加本机回环中继，只转发三类最小能力——①desktop 占用会话的文字发送/排队（session controller 在 desktop 进程执行，解决 `already owned by an active write handle`）；②desktop 任务完成/审批通知（插件监听桌面事件 → remote-host → 手机推送）；③桌面会话实时运行状态与工具进度。其它操作仍走现有子进程链路；中继失败只影响远程功能、不崩溃桌面；DSH 升级最多使中继失效并可回退当前 child 行为。
- **提交**：见本次 commit。### 2026-11-18 15:33 · lead（手机端从日志推导电脑正在执行并显示工具进度，已推送真机）

- 用户反馈：PC 在「正在调用工具 · wait_agent」，手机却显示「工作异常结束」。
- 根因：desktop DSH 进程运行该会话，remote-host 子进程没有 Agent，session.status/tasks.live 均不报 running；App 依据事件窗口把未结算工具调用当成中断。
- 实现：`inferRemoteExecution(events)` 从 `turn/start`/`step/start`/`tool/call` 与对应 end/result 推导运行态与当前未结算工具名；无 live 时置 `_running=true`，ChatTimeline 走运行中分支；状态条显示「电脑正在工作… · 正在调用工具 <name>」；仅明确 turn/end interrupted/error 才显示中断。inferredRunning 且无 live 时每 1.5s 左右补拉窗口合并，turn/end 或 result 到达后停止；dispose/退后台停止。
- 验证：会话页 97/97 测试通过（新增未结算工具→运行中不出中断、结算→停止、明确中断仍显示、销毁停轮询）；flutter analyze 仅既有 11 条告警；debug APK 构建成功并安装到 3B162D00E1K00000（15:29）。
- 备注：该轮 agent 中断但改动完整、测试/构建已由 lead 补齐验证；跨进程写句柄/桌面任务通知仍需架构级修复（用户已批准内嵌宿主方向，待实施）。
- **提交**：见本次 commit。
### 2026-11-18 15:16 · lead（App 动画平滑 + 通知权限修复/诊断 + 写句柄冲突文案，APK 待安装）

- 用户反馈：消息/项目展开折叠/排队坞动画一闪；手机收不到 DSH 通知；发送报 `session "..." is already owned by an active write handle`。
- 动画：项目分组改为稳定挂载 + ClipRect + AnimatedSize(200ms easeInOutCubic)，折叠态零高，保留滚动与折叠记忆；队列坞 AnimatedSize(190ms) + chevron AnimatedRotation；工作状态条/队列计数放稳定槽位，输入卡平滑移动；时间线外包 RepaintBoundary + 稳定 key；减少动态效果时瞬时。
- 通知：发现远程 ready 路径从未申请 Android 13 `POST_NOTIFICATIONS`；新增 `RemoteNotificationPermission`（复用 `notifications.request`，每进程最多请求一次，拒绝不再自动弹；busy/closed 静默降级），在远程首页 ready+启动后台同步时申请；`RemoteNotificationDispatcher` 增加 kDebugMode `[remote-notify]` 日志（received/duplicate/foreground decision/bridge show），便于真机区分帧未到 vs 权限抑制；前台抑制/深链不变。
- 写句柄：新增 `remoteWriteHandleConflictMessage` 映射原始英文为「这个会话正在电脑上使用（电脑端持有写入），手机暂时不能发送；请在电脑上结束/关闭该会话后重试。」，失败保留草稿；不做跨进程抢锁。
- 验证：flutter analyze 仅既有 11 条告警；会话页 92/92、首页 52/52、通知 25/25 全绿；debug APK 构建成功（15:14）。
- **待安装**：手机 USB 仍断开；待重连安装最新 APK。
- 架构边界（重要）：desktop DSH 与 remote-host 是**两个进程共用真实 DSH_HOME**；desktop 持有会话写句柄时手机无法写入；desktop 进程跑的任务也不会发 `remote.taskCompleted` 给手机。真正“原生客户端体验”需把远程宿主搬到 desktop DSH 进程内（或建立进程间会话/通知中继），待用户确认方向。
- **提交**：见本次 commit。
### 2026-11-18 14:48 · lead（队列消息编辑/删除/插话发送 + 复用 DSH 图标，APK 待安装）

- 用户要求排队待执行消息与 PC 一致：可再次编辑、删除、插话发送（steer），图标复用 DSH。
- 运行时：`tasks.session.pending` 增加 `editable`（live+active agent 且内容纯文本）/`steerable`（另需 agent running），`cancellable` 保持；新增 `tasks.editQueued {sessionId,itemId,text}` → updateQueue edit、`tasks.steerQueued {sessionId,itemId}` → updateQueue steer，加入方法表/dispatch/协议文档；非 live、非 running、空文本、非纯文本均给可读拒绝；Node 15/15 通过。
- App：队列坞行内编辑（TextField 预填、保存/取消、空文本提示、失败保留）、删除保留、插话发送（仅 running+steerable 可点，失败提示）；>1 折叠/suspended/不插时间线等保持。图标从 `packages/client/ui-primitives/src/icons/artwork.ts` 提取 queue/edit/trash/send SVG 到 `apps/android/assets/icons/dsh/`，pubspec 注册，flutter_svg 渲染、跟随文字色（14/16px）。
- 验证：flutter analyze 仅既有 11 条基线告警；会话页 90/90、新增队列能力 12/12 通过；debug APK 构建成功（14:46，847,221,359 bytes）。
- **待安装**：手机 USB 再次断开（adb devices 为空）；待重连后安装最新 APK。插件 remote-host 需重启一次以加载新运行时方法（lead 将重载插件）。
- **提交**：见本次 commit。
### 2026-11-18 14:36 · lead（大文件附件传输加固 + 插件托管高可用，APK 构建待安装）

- 用户要求远程体验等同原生、PC 会话高可用；几十~上百 MB 附件发 PC DSH 不能掉链子。
- 附件：宿主 `attachments-desktop.mjs` 分页拉取增加可取消指数退避重试（300/600/1200/2400ms，5 次；`gateway/timeout|unavailable` 可重试，`gateway/cancelled`、`attachment-file/*`、对账失败立即失败，offset 只在整页校验后推进）；App `attachments.prepare` 改用按字节长超时 `max(90s, 30s + ceil(bytes/64KiB)*1s)` 上限 2h（普通请求仍 90s）；插件 overlay 增加 `android-runtime` 配置（重述 platform: desktop + `attachmentFileMaxBytes: 2GiB`，loader patch 为整对象替换）；App >2GiB 前置拒绝并提示；保持流式 generator→uploadStream，32MiB/128 页单测验证；e2e fixture 600KiB→16MiB（未实跑）。
- 高可用：Bridge 监听 remote-host/frpc 异常退出，enabled 且非用户主动 stop 时自动重启（2/4/8/16/30s 退避、最多 5 次，耗尽写 state.problems；host ready 后才起 frpc）；`state.recovery.host/tunnel` 暴露 restartCount/nextRetryAt；插件包 262 tests、host 附件 38 tests、App 37 tests 全绿；typecheck 5/5、build:check 2/2。
- 已重载插件并确认 overlay 含 android-runtime 2GiB、child/control/tunnel 正常、recovery 结构可读。
- **待安装**：手机 USB 仍未连接；APK 14:33 已构建，重连后 push+install。遗留：无逐页百分比进度、无挂起健康探针、e2e 16MiB 未实跑、build:artifacts 本环境卡在 Host Typert。
- **提交**：见本次 commit。
### 2026-11-18 14:20 · lead（后台同步提升到远程首页生命周期，APK 已构建待安装）

- 反馈：上一轮后台保活挂在会话页，从会话页返回首页即停服务，停在首页退后台会错过任务完成/询问推送。
- 修复：`RemoteSyncLifecycle` 控制上移到 `RemoteDshPage`（持有连接控制器的远程首页）：连接 `ready` 时启动前台服务（前台时机满足 FGS 限制）；`connecting/reconnecting/lost` 保持；`failed/idle`、首页 dispose 时停止；App 退后台不停止。会话页移除 start/stop 接线，仅保留缓存逻辑；首页新增 `syncLifecycle` 测试注入入口。
- 验证：flutter analyze 仅既有 11 条基线告警；首页 51 项（新增 4 项生命周期）、会话页 86 项、缓存 5 项、邻接 155 项全绿；debug APK 构建成功（14:18）。
- **尚未安装**：安装时手机 USB 已断开（adb devices 为空），待设备重新连接后 push+install。上一轮 13:56 版本已含会话缓存+会话页后台保活，可先使用。
- **提交**：见本次 commit。
### 2026-11-18 13:58 · lead（App 远程会话本地缓存 + 后台同步服务 + 推送，已推送真机）

- 用户反馈：每次点开对话先「正在读取会话」；要求本地缓存、点开先显示并持续拉最新；PC 连接在后台也要同步消息流；任务完成/询问要有推送。
- 缓存：新增 `RemoteConversationCache`（deviceId+sessionId；窗口 events/throughSeq/firstSeq/hasMore；version 1；单会话 256KB、单设备 2MB/10 会话 LRU；不存附件字节/令牌）；原生 `dsh/runtime` 新增 `remote.conversation.read/save`（MainActivity，SharedPreferences `device:<id>`，≤2MB）。会话页先读缓存立即渲染（顶部细提示「已显示本地缓存，正在同步最新内容…」），缓存空才回退原加载态；实时快照覆盖并仅在接近底部时滚动；1s 节流写回 + dispose 刷盘；断线仍可看缓存。
- 后台/推送：新增主进程前台服务 `RemoteSyncService`（specialUse、低优先级「与电脑保持同步」、START_STICKY；无 UI 时自停防假同步）+ `remote.sync.start/stop/status` 通道；Dart `RemoteSyncLifecycle` 在会话页 mounted 且连接 ready（前台）时 start，dispose/failed/idle/切设备时 stop；结合既有 `RemoteNotificationDispatcher`（remote.taskCompleted/approvalPending 解析/去重/前台抑制/深链）实现后台任务完成与询问推送。
- 验证：flutter analyze 仅既有 11 条基线告警；缓存 5 + 会话页 88（新增缓存/同步 5）+ 邻接 98 项全绿；debug APK 构建成功并安装到 3B162D00E1K00000（lastUpdate 13:56）。
- 边界：后台保活按会话页生命周期（从首页退回会 dispose 并停服务）；系统强杀后 START_STICKY 不重建 Flutter 引擎，服务检测无 UI 自停，重开 App 后恢复。全局级常驻（首页/多会话后台同步）留待后续。
- **提交**：见本次 commit。
### 2026-11-18 13:46 · lead（App 远程会话页：工作状态条 + 排队消息同步/删除，已推送真机）

- 用户反馈：点进正在工作的远程会话看不到工作状态；待发送/待执行的排队消息没有同步。
- 协议：宿主已有 `tasks.session`（live.status running/waiting/queued/idle + queued/blockingRequests + pending 列表：target next-turn/next-step、prompt、status、cancellable）与 `tasks.removeQueued`；`RemoteConversationSource.request()` 可直接透传。
- 实现：会话页进入 ready 后立即读一次并每 2s 轮询 `tasks.session`（前台才跑、dispose 停止、失败静默、unsupported 隐藏）；用 `live.status` 补 `_running` 初始值，修复「进入已在运行会话没有状态」；输入卡上方显示紧凑状态条（running「电脑正在工作…」+小转圈；waiting「等待你在电脑上的操作」；queued「N 条消息排队中」）与队列坞（0 条不渲染；1 条直出；>1 折叠「N 条排队消息」，next-turn「排队 · 待执行」/next-step「插话 · 待发送」，suspended 标记；cancellable 删除→确认→`tasks.removeQueued`→刷新+提示，失败保留列表）；排队消息不插入时间线；断线/旧宿主隐藏面板不阻断。
- 验证：flutter analyze 仅既有 11 条基线告警；会话页测试 83 项（新增 8：running 状态、队列折叠/删除、断线降级、空队列等）+ 邻接 47 项全绿；debug APK 构建成功并 push+`pm install -r -t` 到 3B162D00E1K00000（lastUpdate 13:45）。
- **提交**：见本次 commit。
### 2026-11-18 13:35 · lead（App 远程首页：running 绿点 + 项目折叠记忆 + 折叠密度，已推送真机）

- 用户反馈：正在工作的会话应点亮绿点；项目折叠要有记忆（现在刷新又全展开）；折叠态列表间距太大。
- running：`sessions.list` 行已有 `running:true`，App 现解析到 `RemoteDshSession.running`/catalog；`RemoteSessionRow` 在标题前显示 8px 绿点（`Semantics('正在工作')`），plain/卡片两种形态支持；`RemoteHomeCache` 不缓存 running，避免离线显示旧绿点。
- 折叠记忆：折叠状态提升到页面级 `Map<deviceId+'\0'+projectId,bool>`，`RemoteProjectGroup` 支持受控 `expanded/onExpandedChanged`，外层 Padding 补稳定 key（根因：内层 state 被列表重排重置）；轮询/搜索/切换设备保持；写回 `RemoteHomeCache`（schema v2，兼容 v1）实现 App 重启后恢复。
- 密度：折叠态项目头 padding 16/10→10/8、图标 22→20、项目外层 vertical 4→2；实测项目组高度 178→66 px（仅头部），外层槽 186→70 px，点击区仍 66px。
- 验证：flutter analyze 仅 11 条既有基线告警；相关测试 68+49 项全绿（新增绿点、折叠刷新/切换/缓存、密度断言）；debug APK 构建成功并 push+`pm install -r -t` 到 3B162D00E1K00000（lastUpdate 13:32）。
- **提交**：见本次 commit。
### 2026-11-18 13:20 · lead（App 连接加载转圈 + 扫码拍照识别，已推送真机）

- 用户反馈：连接新 PC 获取信息时应转圈，不要先显示“没有工作内容”；扫码要优化，拍完二维码照片也能识别，并推送到手机。
- 加载态：远程首页对 per-device 首次数据加载增加状态——`connecting` 且无缓存时显示 `CircularProgressIndicator` +「正在连接…」；`connected` 但 `listProjects` 未返回且该设备从未成功读过项目时显示转圈 +「正在获取电脑上的项目…」，不再提前渲染「这台电脑上还没有项目」；只有成功返回（含空列表）后才记该设备已加载并允许空态；失败/切换设备/dispose 正确清理，已有缓存仍显示上次同步内容。
- 扫码：`PairingScanActivity` 新增「拍照识别」主按钮（CameraX ImageCapture 最高分辨率拍照 → `PairingQrDecoder.decodePhoto` 两轮采样/四方向/中心裁切/反色解码），识别中/失败/重拍文案齐全，临时照片自动清理；有闪光灯时显示「手电筒」；保留连续取景、相册、取消；CameraX 三路绑定失败降级为取景+相册，完全不可用仍回退系统相机拍照。配对协议/CA 校验不变。
- 验证：`flutter analyze` 11 条既有基线告警、相关测试 +93 项全绿；`flutter build apk --debug --target-platform android-arm64` 成功；APK 已 push+`pm install -r -t` 到 3B162D00E1K00000（versionCode 120、lastUpdate 13:19），启动截图正常。
- **提交**：见本次 commit。
### 2026-11-18 12:30 · sakurafrp-tunnel（扫码配对改为应用内连续取景 + 相册识别，用户反馈修复）

- 用户反馈：App「扫码配对」只是调用系统相机拍一张照片、没有持续取景；拍下的二维码照片也识别失败。根因：原实现用 `MediaStore.ACTION_IMAGE_CAPTURE` 一次性拍照后等相机应用回执，真实照片质量/回执不可控，且自动化验收只覆盖 debug 图片解码通道、真实相机路径未验证。
- 改为应用内连续扫码：新增 `PairingScanActivity.kt`（CameraX 后置相机连续预览 + ImageAnalysis 逐帧 350ms 限速，RGBA 帧转灰度后 ZXing 解码，命中即回传、无需按快门）与 `PairingQrDecoder.kt`（实时帧/相册/调试图片共用 ZXing；图片多方向 + 两轮采样 + 整图未命中再解中央 66%/50% 裁切）；`PairingQrScan.kt` 优先打开应用内扫码页，相机初始化失败才回退系统相机拍照，`CAMERA` 权限在扫码页运行时请求、拒绝返回 `pairing/permission-denied` 并保留粘贴入口。
- Manifest 增 `CAMERA` 权限（相机 feature 均 `required=false`）与 `PairingScanActivity`；Gradle 增 `androidx.camera:*:1.4.2` 四个 artifact（未新增 Flutter pub 依赖）。Dart 增 `pairing/permission-denied` 映射与文案，扫码中提示改为「正在打开相机…」。
- 验证：`flutter analyze` → 11 条既有告警、无新增；`flutter test` → **2076 项全通过**（含扫码 19 项）；`flutter build apk --debug --target-platform android-arm64` → **BUILD SUCCESSFUL**（APK `build/app/outputs/flutter-apk/app-debug.apk`；aapt2 确认 CAMERA 权限、`PairingScanActivity`、CameraX `MetadataHolderService` 已合入 manifest）。
- 真机验收待 lead：安装该 debug APK → 添加连接 →「扫码配对」→ 对准电脑屏幕二维码应持续取景并自动填入；「从相册选择」可解截图/照片；首次使用授权相机；拒绝权限时应提示粘贴入口。
- 边界：实时帧不做旋转尝试（QR 与旋转无关）；相册图片受采样上限（最长边 4096）与内存限制；扫码页保持亮屏；本轮未加手电筒/前后摄切换。

### 2026-11-18 12:15 · lead（SakuraFrp 去重审计 + 就近/VIP 节点选择 + 并发实测）

- 去重审计：常规重试不会重复（先 saved tunnelId、再 type=tcp+同名复用；实测连续 provision 隧道数 12 不变、#29890068 复用）。修复两个缺口：①`Bridge.provisionTunnel` 增加 single-flight，并发/连点不会各建一条；②provision 确定 tunnelId 后通过 `onTunnelResolved` **立即**持久化 tunnelId/nodeId/tunnelIds，创建后后续步骤失败（甚至改名重试）仍复用、不留孤儿。
- 就近/VIP：解析 `user/info.group.level`（jackWei=3 青铜VIP）作为 VIP 上限；节点可用条件加 `node.vip <= maxVip`；新增 `node-latency.ts`（TCP connect host:7000，超时 1.2s、并发 32、可注入）按实测延迟选最近可达节点，自动模式重新测速（不再被持久化 nodeId 锁死），显式 nodeId 才强制；steps 显示节点/VIP/延迟；复用旧隧道节点更远时只给 `node-distance` 提示，不自动迁移/删除。
- 真机实测：provision 选中 长沙电信PLUS2（普通节点 84–120ms），复用 #29890068；两个并发 provision 请求均返回同一隧道 #29890068，SakuraFrp 隧道数前后均为 12（未重复）；当前隧道保持在天津联通PLUS1（约 83ms），未受扰动。
- 门禁：插件 13 文件 **258 tests**、双 face tsc、typecheck 5/5、build:check 2/2、bundle、i18n/README/translation-pairing 绿。
- **提交**：见本次 commit。
### 2026-11-18 11:35 · lead（SakuraFrp 公网链路端到端验证 + 桥接错误码修正）

- 用当前 SakuraFrp 公网配对链接跑 `apps/remote-host/scripts/e2e-remote-host.ts --pair-url wss://frp-act.com:35530/...`：**22/22 PASS**——解析配对链接、GET /ca.cer CA 指纹、POST /pair 单次令牌、wss 固定 CA 校验、protocol.hello（93 methods）、sessions.list/session.readWindow、workspace.files、terminal 全流程、附件 prepare/read、session.send + follow 流、host-local native 方法、清理；证明经 SakuraFrp TCP 隧道 + 自有 CA 的远端 DSH 手机链路可用。
- e2e 产生的测试设备已用插件的**永久删除**接口清理（devices 35 → 34），实测删除链路 200。
- 桥接错误映射修正：ControlPlaneError 携带控制面 HTTP status（如 404 device-not-found），routes 对 4xx 透传、其余 502，未知设备删除不再被抹成 502；新增 routes 单测；包级 241 tests、双 face tsc、bundle 通过。
- **提交**：见本次 commit。
### 2026-11-18 11:35 · lead（设备互联页对齐 DSH + 设备底部折叠/删除 + 一键 SakuraFrp 真机跑通）

- 用户反馈：设备互联页上下段没有间隙、不像 DSH 设计；已配对设备 34 台太多；需删除/折叠设备；frpc 路径点开关后丢失；口令需水平居中 `*` 掩码。
- UI：页面根节点此前**没有挂上 `.page` 类**（裸 fragment），导致卡片无间距；现按 `ui-settings-models/plugins` 基准重写：section gap 12/max-width 720、标题 16/24 500、intro 14/22、卡片 0.5px stroke + settings-card-fill + radius-xl + padding 12×14、卡片列表 gap 8/12，控件换用 primitives。设备卡移到最底部，可折叠（N>6 默认收起），active 在前、revoked/expired 在后，行间 hairline；保留撤销，并新增**永久删除**（active 先断连再删），撤销/删除各自确认。
- 状态机：修复 frpc 路径丢失（provision 漏传路径 + 响应覆盖未保存 draft + 自动模式字段被藏进折叠区）；现在切换开关/2s 轮询/一键刷新都保留未保存输入，frpc 路径在自动/手动模式主区域可见。口令字段改为水平居中 `*` 掩码（已保存显示固定 `********`，输入逐字符 `*`，真实值只在内存/提交）。
- frpc 下载：本机无法解析 `getfr.sh`；下载器增加 Nyatwork CDN 版本镜像回退（`nya.globalslb.net/natfrp/client/frpc/<version>/frpc_windows_amd64.exe`，读取目录选最新，失败用 pinned `0.51.0-sakura-15.1`），并复用已安装且 `frpc -V` 含 `sakura` 的二进制；已把官方 CDN 下载的 frpc 15.1 安装到 `~/.dsh/device-interconnect/bin/frpc.exe`。
- **真机一键验证**：用面板已保存访问密钥成功执行 provision——账号 `jackWei`、自动选节点「天津联通PLUS1（frp-act.com）」、复用隧道 `DSH_CC #29890068` 并对齐 `127.0.0.1:4777`、公网 `frp-act.com:35530`、对外 `wss://frp-act.com:35530`、frpc 运行中；TLS 端口从本机可达，配对链接已切换为公网地址。
- 测试/门禁：插件 12 文件（含新增 frpc 下载/复用/CDN 回退用例）237+ 全绿；remote-host selfcheck 33/33；typecheck 5/5、build:check 2/2；README/i18n/translation-pairing 绿。
- **提交**：见本次 commit。
### 2026-11-18 10:45 · lead（修复设备互联冷启动时设置页桥接未注册）

- 用户反馈：重启 DSH 后设置→设备互联显示「设备互联接口处理失败，详情见 DSH 宿主日志」。
- 根因：Host 插件在冷启动时可能先于 `webServer` 服务激活；旧实现用 `ctx.get('webServer')` 一次性读取，服务尚未出现时直接跳过注册（仅 warn），整个进程生命周期内 `/device-interconnect/api/*` 都是 404，客户端页面因此报接口失败。
- 修复：改为 `ctx.inject(['webServer'], scope => scope.effect(register…))` 声明式等待，服务出现后再注册路由（无 browser surface 的 profile 仍可加载插件）；新增回归测试「web server 后出现时仍注册/随 fiber 释放」；已通过 plugin_manager 对当前实例执行 disable/enable 触发重载，`/device-interconnect/api/state` 已恢复 200（无需重启 DSH，页面刷新即可）；插件 223 tests、host tsc、bundle 重建通过。
- **提交**：见本次 commit。
### 2026-11-17 21:30 · lead（SakuraFrp 一键接入：token → 自动建隧道 → 启动）

- 设备互联插件内网穿透升级：只填 SakuraFrp 访问密钥即自动完成「校验账号 → 选节点 → 创建/复用 TCP 隧道 → 对齐本地端口 → 推导公网地址/publicOrigin → 下载并校验 frpc → 重启 remote-host → 启动隧道」；手动模式保留为高级项。
- 新增 `sakurafrp-api.ts`（API v4 Bearer 认证，错误映射）、`provision.ts`（6 步流程、节点选择、复用/创建、步骤化失败）、`frpc-download.ts`（用户点击触发、`-V` 含 sakura 校验）；`POST /api/tunnel/provision` 路由与 state 扩展；页面一键卡（确认 Modal、步骤、账号/额度/节点/隧道、警告展示）。
- 验证：插件 **12 文件 223 tests**、双 face tsc、typecheck 5/5、build:check 2/2、i18n/README/translation-pairing 门禁绿；未真实调用 SakuraFrp API（fake）。
- 使用前需重启 DSH 加载新插件；仅支持 TCP 隧道（固定 CA）。
- **提交**：见本次 commit。
### 2026-11-17 21:10 · lead（设备互联插件接入 SakuraFrp TCP 隧道）

- 插件 `packages/experimental/device-interconnect` 新增 SakuraFrp 隧道托管：frpc 子进程管理、长期配对、公网地址自动推导 publicOrigin；仅支持 TCP 隧道（固定 CA 需要端到端 TLS）。
- 验证：插件 185 tests、双 face tsc、typecheck 5/5、README/i18n 门禁绿；需重启 DSH 加载新 host 插件。
- 边界：frpc 用户自备、token 明文存于插件 config.json；HTTPS 隧道不可用。
- **提交**：见本次 commit。
### 2026-11-17 12:45 · lead（设备互联 DSH 插件 + 长期配对 + 官方 DSH 安装验证）

- **用户反馈**：要把远程接入做成 PC 上的 DSH 插件，在设置里开「设备互联」Tab；配对不要倒计时，要长期可用。
- **交付**：新增 `packages/experimental/device-interconnect`（opt-in bundle，Settings→设备互联；独立子进程托管 remote-host；通过本机配对页控制面管理）；remote-host 支持 `pairingLongTerm` + TTL 上限 90 天 + `/api/state`/`/api/pair`/`/api/devices/revoke`/`/qr.svg`；配对页显示「长期有效」。
- **验证**：本机官方 DSH desktop profile 安装并 enable，子进程 running、长期窗口 open、qr.svg 200；插件 104 tests、remote-host selfcheck 30/30+8/8+16/16、smoke 14/14、typecheck 5/5、build:artifacts 8/8、build:check 2/2。
- **边界**：插件控制面仅本机回环；官方发行仍需打包 fork 运行时；长期窗口=长期可配对入口（配合撤销/关闭宿主）。
- **提交**：`14efcf996a`。
### 2026-11-16 17:00 · lead（首页输入条三态 + 视觉收敛 + 新机复验）

- **用户反馈**：远程 DSH 首页输入条仍是旧的一行、不悬浮、无三态；缩小态不应出现审核权限；展开后的
  按钮过大；随后又要求换设备测试。
- **交付**：首页输入条重做为悬浮卡三态（browse/composing/picker，picker 为电脑默认模型只读面板，
  发送走 `library.sessionCreate` 新建并打开会话）；组件视觉收敛（缩小态无权限按钮、工具条小图标
  20dp/40dp 热区、发送 44dp）；会话页缩小态隐藏权限/模型回显行，只在展开态显示。
- **修复**：首页 picker 点开后被键盘 metrics 折叠回 browse 的真机竞态（粘滞标记 + 不扰动 IME）。
- **真机**：OnePlus6（Android 11）与 OnePlus PLP110（Android 17）双机复验三态与暗色主题；新机重新配对
  （USB reverse + 粘贴配对链接）。证据 `.cache/remote-device/p10d-*`、`p11-newdev-*`。
- **测试**：全量 `flutter test` 2041+ 项通过；analyze 11 条基线。提交 `7f814b1278`、`8da0e7493d`。

### 2026-11-16 15:15 · lead（输入区重构：悬浮卡三态 + 用户参照对齐 + 三个缺陷修复）

- **新需求**：按用户提供的官方 App 3 张对话页参照重做输入区——悬浮玻璃卡、浏览时缩小/触发时展开、
  点「推理强度」切换第三态（模型名+强度滑杆），沿用 App 视觉语言（远程与本地聊天页共用 `PocketComposer`）。
- **交付**：`pocket_composer.dart` 共享三态组件；远程会话页接入（模型按钮→推理面板、保留全部既有入口、
  统计条移到卡上方）；本地聊天页接入（`+` 弹层、权限盾牌、推理面板、发送/停止）；`pocket_composer` 增加
  可选 margin 参数（默认不变）。
- **真机缺陷修复**：① 点输入卡不聚焦/不弹键盘与 viewport metrics 风暴（键盘显隐闩锁 + 收起不解焦 +
  点卡 requestFocus/TextInput.show）；② 点推理强度进不了面板（透明覆盖替代 Visibility，保持输入连接）；
  ③ 远程会话页「无法确认计划模式状态：会话尚未提供可用的状态快照」误报（session.control 基线无 kind，
  改为未就绪有限重试/真失败才可见）；④ 本地打开模型页 debug 构建 setState-during-build（plugins 首通知
  微任务化）。
- **真机验收**：远程缩小/展开/picker/强度切换（低→高回显）与本地三态均通过；证据 `.cache/remote-device/
  p9-*.png`。全量 `flutter test` **2025 项通过**；analyze 11 条基线；Kotlin 未改（无需重编译验证）。
- **已知差异**：远程停止按钮暂缺（无取消接口）、手形/麦克风/语音不做、picker 保留工具条、卡片未真正
  浮层覆盖内容（后续 polish）。

### 2026-11-16 12:57 · stream-lifecycle（修复宿主 AppStreams 跨重连泄漏，宿主侧）

- **根因复核**：`AppStreams` 每个门面进程只建一次，远程连接恒用固定 owner `'remote'`
  （协议 §6.4 的 owner 不上线，远程侧缺省成同一个值）；记录清理只挂在
  `native.appDisconnected` 上，而远程宿主从不发它，`facade.unbind` 只 detach 终端/附件。
  协议 §6.6 要求“连接关闭 → 该连接全部流终止”，旧实现没有履行；App 进程被杀/网络断掉时
  不会发 `api.unsubscribe`，订阅记录与上游生产者跨重连累积，触顶 32 后报
  `App stream limit reached`。
- **多连接语义**：`server.ts` 允许多条连接并存，但 `index.ts` 按协议 §11 同一时刻只服务
  一台设备（新连接先 unbind 旧连接再 bind 新连接并关闭旧 socket），因此按连接分配独立
  owner 是成立的；替换窗口内旧连接的在途请求仍带旧 owner，不会串到新连接。
- **修复**：`apps/android/runtime/index.mjs` 新增 `RemoteConnectionOwners` +
  `createRemoteFacadeService`（按 owner 注入参数、bind/unbind 维护 owner 生命周期、
  unbind 释放流/references/workspaceChanges/documentPreview/documentReads/documentSearch/
  attachmentFiles/历史租约，清理失败只 warn）；`apps/remote-host/src/index.ts` 每条连接
  `randomUUID()` 作 owner，`bind(sink, owner)`/`dispatch(method, params, owner)` 接线，
  `connection-ready` 日志带 owner，unbind 的同步异常与异步拒绝都记 `facade-unbind-failed`
  而不产生未处理 rejection。协议未变、`protocol.md` 未改、App `lib/` 未改。
- **测试**：新 `apps/remote-host/scripts/stream-lifecycle-selfcheck.ts` 11/11 PASS；
  `api_streams_test.dart` 新增 close 退订断言、`remote_conversation_live_source_test.dart`
  补页面 dispose 后不得重新订阅；App 相关 31 项全绿。
- **验证（原样）**：selfcheck 11/11；`tsc -p apps/remote-host/tsconfig.json` exit 0；
  `tsc -p tsconfig.host.json` exit 0；oxlint 改动 2 文件 `0 warnings and 0 errors`；
  宿主冒烟 **14/14**；隔离宿主（4789 + 临时 DSH_HOME 副本）真实 e2e **22/22 PASS**，
  日志 `connection-ready … "owner":"1c4d3a3e-…"`，无清理失败；`flutter analyze` 11 条基线。
  真机复验步骤与风险见 §4 第 20 条（lead 重启 4777 后执行）。

### 2026-11-16 12:35 · lead（会话洞察 UI：悬浮任务卡片 + 底部统计条，真机验证）

- **新需求落地**：远程会话页接入 `session.projections` 四类数据（`todos`/`sessionStats`/`tokenUsage`/
  `contextPressure`，真机探针确认 values 23 个 key 中目标 key 全部存在）；新增 `remote_session_insights.dart`
  容错解析与派生（缓存命中率对齐 Web `StatsPills`、上下文占用对齐 `ContextMeter`），live source 在首屏/重连/
  reload/轮次边界/`todo/write` 后单飞刷新（无轮询）；新增 `RemoteTodoCard` 悬浮任务卡片与 `RemoteStatsBar`
  统计条 + 统计详情弹层，沿用 App 的 glass/Pocket 视觉语言（用户要求「UI 依旧采用我们的」）。
- **真机验收**：会话 `Write approval file with pwsh`（已用 todo_write 建 alpha/beta/gamma）显示收起「待处理 3」、
  展开三项、统计条「轮 16 · 步 25 · 481K tok · 缓存命中 96% · 上下文 2%」、详情弹层含 TTFT 1.9 秒/TPS 218 与
  Token 四桶（合计 481,082 tok）；证据 `p7-insights-*.png`。
- **发现缺陷**：真机页出现 `App stream limit reached` 横幅——宿主 `AppStreams` 固定 owner `remote` 跨连接累积、
  关闭未清理，多次重连后触顶 32；已立项修复（§4 新条目）。
- 验证：全量 `flutter test` **1982 项通过**；`flutter analyze` 11 条基线。

### 2026-11-16 12:10 · lead（P6 补强：PC 配对设置页、通知深链、拨号超时、wss 443）

- **PC 配对设置页**（P6 A1）：宿主内嵌回环 HTTP 页（二维码/倒计时/USB 链接/设备列表/撤销/重开窗口），
  Host+CSRF+Origin 防护；selfcheck 24/24；浏览器验收（headless Edge 截图 `pairing-page-lan.png`、HTTP 200/
  安全头/SVG/CSRF/reopen 303/Host 403/revoke 触发 device-revoked）。
- **通知点击深链**：系统通知点击直达对应远程会话；修复冷启动凭据时序与失败清空 pending 两个真机缺陷；
  真机复验冷启动 8s 进会话、无效 sessionId 回首页+提示。
- **拨号超时**：12s 终止性失败（`remote/connect-timeout`），不可达电脑快速显示失败+重试。
- **wss 443**：`normalizePublicOrigin` 保留显式 `:443`，selfcheck 13/13。

### 2026-11-16 11:52 · app-notify-deeplink（修复冷启动深链两处真机缺陷）

- **冷启动抢跑连接**：远程页在 `runtime.ready` 之前不发起自动连接（设备令牌经本机凭据服务读取，未就绪
  会被拒「运行时正在启动」），监听本机运行时 ready 后补连；设备胶囊/失败页重试/添加连接在服务启动期间
  先给可见提示。
- **连接失败不再清空 pending**：pending 只在成功打开、明确不存在（已归档/删除/属于别的电脑）或离开页面
  时清空；失败原因按原因去重只提示一次，用户重试连上后仍会打开通知里的会话。
- 测试：`test/remote_dsh_home_page_test.dart` 新增 3 项（运行时未就绪→ready、失败→重试成功、pending 只
  消费一次），该文件 33 项全绿；`flutter analyze` 11 条基线。详见 §3.2.13「真机复验修复」。
- **真机复验 PASS**（重装 debug APK）：冷启动深链 ~8 s 自动进入目标会话页；无效 sessionId 停在远程首页
  并显示「会话已归档或不在该电脑上。」SnackBar。

### 2026-11-16 11:30 · app-notify-deeplink（P6 后台通知③：点击深链打开远程会话）

- 平台层：`MainActivity` 在启动 Intent 与 `onNewIntent` 里用 `RemoteNotifications.takeLaunch` 校验
  `pocket.route=remote` 等 extra 并存成 pending；`dsh/runtime` 新增 `notifications.launch.take`
  （取一次即清空，损坏/未知 extra 丢弃）；本地通知 `session`/`tasks`/`approval` 路由未改。
- App：新 `remote_notification_navigation.dart`（严格解析 + 可注入读取口 + 消费器）；`main.dart`
  在启动首帧后与每次回前台消费；`RemoteDshPage` 连接就绪后按 `sessionId` 打开会话。失败分支
  （会话已归档/不在该电脑上、连接失败、本机无配对、多台无法判断来源设备）全部落到远程首页并
  给出可见提示。限制：通知负载不带来源设备，按「上次连接设备」处理（§3.2.13）。
- 验证：`flutter analyze` 11 条基线；Kotlin debug/release 编译 exit 0；新增 20 项测试与相关既有
  91 项测试全绿。详见 §3.2.13、§4 第 13 项。

### 2026-11-16 11:27 · host-pairing-page（P6 A1：宿主内嵌 PC 配对设置页）

- 新 `apps/remote-host/src/pairing-page.ts`：`PairingPageServer` 只绑 `127.0.0.1`，服务端渲染
  单页 HTML（中文、内联 CSS/JS、无外部资源）+ `GET /api/state`：窗口状态/倒计时/过期时间、
  `encodeQrMatrix` → 内联 SVG 二维码、明文链接、USB `adb reverse` + `usbPairUrl`、设备列表
  （label/id 前缀/时间/状态/撤销）、「重新打开配对窗口」；POST 动作 303 回 `/`。端口默认 4780
  （`Config.pagesPort`，0=临时）、`Config.pagesEnabled` 默认 true；绑定失败只记 warn、宿主照常启动。
- `apps/remote-host/src/index.ts`：`RemotePairingTicket` 加 `usbPairUrl`、`RemoteHostHandle.pages()`
  数据源（当前窗口/重开/设备列表/撤销/宿主身份，过期/已消费窗口如实返回 undefined）、`apply()`
  装配与 effect 清理（页面先于 wss 监听停止）；`Config` 两个新字段走 schemastery 校验。
- 安全：Host 白名单（防 DNS rebinding）+ Origin 同源 + 进程级随机 CSRF（POST 必须带，缺/错/重复
  403）+ `nosniff`/`no-store`/CSP/`frame-ancestors 'none'`，无 CORS；token 只在窗口打开时渲染/返回；
  页面三类日志不含 token/CSRF（自检断言）。威胁模型与排障写进新
  `apps/android/docs/remote-dsh/pc-pairing-page.md`；[pc-pairing-distribution.md](pc-pairing-distribution.md)
  §1 已补「已落地」指针。与评估差异：未用一次性 `uiToken`（改 Host+CSRF+Origin）、`status()` 增补未做。
- 新 `apps/remote-host/scripts/pairing-page-selfcheck.ts`：零依赖、真实回环 HTTP + 内存假数据源。
- **验证（原样）**：selfcheck **24/24 PASS**；`tsc -p apps/remote-host/tsconfig.json` exit 0；
  `tsc -p tsconfig.host.json` exit 0；oxlint 改动 3 文件 `0 warnings and 0 errors`；宿主冒烟 **14/14**。
  未截图/未真机：浏览器侧验收由 lead 在 4777 宿主重启后按 pc-pairing-page.md §7.2 补。

### 2026-11-16 11:15 · lead（第六轮：60fps 冷机有效复测 + 优化实验与结论）

- **冷机有效复测**（电池 25.9→28.8°C，`post-p6-cold-perf.json`）：home p95 28.76 ms/51.7%、
  session 30.40/32.9%（build 9.03）、terminal 38.10/47.4%（build 25.21）、files 29.80/100%
  （raster 15.52）——全部仍超 16.667 ms 预算；home 在不同冷机时段波动 17.4–28.8 ms，最佳与基线一致
  （无回归）。测量驱动新增每场景电池温度记录（>34°C WARN）与滚动场景预热，见 performance.md §2。
- **优化实验（已回滚）**：长流式文本（>1200 字符）流式期间改纯文本渲染 —— build p95 9.03→7.74 ms，
  total p95 30.24→30.24（无变化，帧调度/栅格主导），且会让长回复流式期间失去 markdown 格式；
  收益不足，回滚代码，仅保留结论在 performance.md §2/§4。
- **结论**：60fps 门禁仍未达成；home/files 的 raster 成本（12–16 ms）来自 pub 包
  `material_ui 1.7.0` 的液态玻璃背景捕获（不在本仓库内，需 fork/vendor 或降低默认玻璃质量的
  产品决策）；terminal build（25 ms，App 侧）是无需产品决策的下一优化点。

### 2026-11-16 04:20 · lead（P6 后台通知落地 + PC 配对/分发评估 + 通知真机验收）

**后台通知（协议 §8，步骤 (1)+(2) 完成）**

- 宿主：`apps/remote-host/src/notifications.ts`（`RemoteNotifications`，每条 ready 连接一个）已在
  `createFacadeSink` 的 `notify` 上加观察层（§3.2.11）：`task.completed` → `remote.taskCompleted`、
  `interactions.changed` 新增 pending → `remote.approvalPending`、`session/title` →
  `remote.sessionChanged`（标题线）；截断/帧上限/去重/ready/告警降级按 §8 实现。
  `notification-selfcheck` **11/11**；隔离宿主 e2e **23/23**（send 项严格断言 `remote.taskCompleted
  matches §8.2 (335 bytes, title=4 chars, turn=4)`）。
- App：`remote_notifications.dart`（严格解析/去重/前台抑制/bridge）+ `RemoteNotifications.kt`
  （复用 `task-completed`/`agent-requests` 渠道、tag `pocket-remote:*`、点击打开 App、`cancelAll`
  只清远程项、Android 13+ 静默降级）；`remote_connection.dart` 增加三条 `remote.*` 分支、
  通知流、sessionChanged 水位；断连/切设备/撤销统一清通知与去重表（§3.2.12）。
- **真机验收**（debug APK + 重启后的 4777，e2e 同时 PASS 23/23 且 send 项严格断言
  `remote.taskCompleted matches §8.2 (292 bytes, title=22 chars, turn=5)`）：退后台收到
  `pocket-remote:taskCompleted:turn:<session>:11`（channel `task-completed`，IMPORTANCE 4）；
  前台再完成两轮宿主有 `remote-notify-sent` 但不弹；退出远程页连接 `client-closed` 后通知全部清空。
  `approvalPending` 真机链路未触发（沙箱直接拒绝写入，未产生审批交互），由宿主 selfcheck 与 App
  23 项单测覆盖；通知点击目前只打开 App（远程深链待接）。

**P6 剩余评估**

- 新增 `apps/android/docs/remote-dsh/pc-pairing-distribution.md`（266 行，结论先行）：
  PC 配对界面推荐 **A1 宿主内嵌本地回环设置页**（`node:http` 只绑 127.0.0.1；配对按钮 + 倒计时 +
  SVG 二维码 + USB/`adb reverse` + 已配对设备列表 + 撤销；`pairing-qr.ts` 可直接出 SVG；2–4 天）；
  PC 分发实测：`pnpm pack` 出的 tarball 依赖写成 `@minnnng/dsh-android-runtime: 0.0.0`，
  registry 上该包与 `@deepseek-ai/dsh-remote-host` 均 **404**，release family 规则不收该包
  （只扫 `apps/*` 一层、跳过 private、必须 `@deepseek-ai/` 家族版本）→ 下一轮 release 会带断依赖；
  推荐改名 `@deepseek-ai/dsh-android-runtime` 并入发布家族（待用户决策 scope/受众/版本策略）。
- HANDOFF §4 第 6/7/13 项、reachability.md、pairing-qr-design.md 已加指针。

**验证（原样）**：`flutter test` **1913 项全通过**；`flutter analyze` 11 条基线；
宿主 e2e **23/23**、冒烟 14/14、通知自检 11/11；Kotlin debug/release 编译 BUILD SUCCESSFUL；
`tsc` 两个工程 exit 0。

### 2026-11-16 03:58 · host-notify（P6 后台通知①：宿主 `remote.*` 发送端）

**实现**

- 新 `apps/remote-host/src/notifications.ts`：`RemoteNotifications` 在门面 sink 的 `notify` 上观察
  页面线，按 protocol §8 追加 `remote.taskCompleted`（§8.2）、`remote.approvalPending`（§8.3，
  审批/提问/计划）与 `remote.sessionChanged`（§8.5，仅标题变化）；字段按 §8 上限截断 + `truncated`，
  序列化超帧时先丢可选字段、再缩 title、装不下丢弃整条；同一 interactionId 每连接只发一次；
  只在 ready 连接发送，写失败只记一条 `remote-notify-failed` warn（不影响页面线）。
- `apps/remote-host/src/index.ts`：每条连接创建/释放观察者（连接替换、`onClose`、宿主 `stop`），
  注入门面 `library.catalog` 的会话标题/所属项目查询；新增日志事件 `remote-notify-sent` /
  `remote-notify-failed` / `remote-notify-lookup-failed` / `remote-notify-lookup-timeout` /
  `remote-notify-ignored`，既有启动/连接日志字段不变。
- 新 `apps/remote-host/scripts/notification-selfcheck.ts`：零依赖，**11/11 PASS**。
- `apps/remote-host/scripts/e2e-remote-host.ts`：send 项附加 §8.2 观察（页面线 `task.completed` →
  `remote.taskCompleted` 严格校验），cleanup 复验整轮 `remote.*` 帧；既有 23 项语义/编号不变。
  顺带修掉本文件 8 条既有 oxlint 风格错误（模板字符串引号、一处缩进），否则「改动文件 0 error」不成立。

**验证**：selfcheck 11/11；`tsc` 两个工程 exit 0；`oxlint` 改动 4 文件 0 error；宿主冒烟 14/14；
隔离宿主（4788 + 临时 DSH_HOME，未触碰 lead 的 4777/PID 19168）真实 e2e **PASS 23/23**，
send 项原文 `remote.taskCompleted matches §8.2 (335 bytes, title=4 chars, turn=4, truncated=false);
page line task.completed observed`。

**边界**：§8.5 只做标题变化（归档/删除需 `sessions.changed` + 目录 diff，延期，见 §3.2.11）；
App 侧消费由 task-21；真后台送达仍需前台服务（§4 第 13 条）。

### 2026-11-16 03:30 · lead（P6 第三批收口：多种连接方式 + 多台电脑 + 真机验收）

**多种连接方式（真机验收）**

- 扫码配对：Kotlin `PairingQrScan`（系统相机 intent + FileProvider + ZXing 3.5.3 解码，
  QR-only/TRY_HARDER/ALSO_INVERTED、两轮采样 + 四向旋转、错误码 `pairing/scan-*`）+ Dart
  `remote_pairing_scan.dart` + 配对页「扫码配对」入口；debug-only 图片解码通道供自动化，
  release 字节码证明折叠。真机：生成版本 8 QR 图解码文本与配对链接逐字一致；相机 intent 正常启动。
- 局域网发现：宿主 `discovery.ts`（UDP 4778，配对窗口打开才回 pairUrl，1s 限速、坏帧静默、
  端口占用降级）+ App `remote_discovery.dart`（严格校验、instanceId 去重、2.5s 窗口、懒加载、
  空态/失败/回退文案）。PC 侧 UDP 探测 PASS；真机因 AP 客户端隔离未拿到广播，UI 与回退已验证。
- USB：宿主配对日志新增 `usbPairUrl`（回环地址同一票据）+ TTY 下 `adb reverse` 说明；真机
  `adb reverse tcp:4777 tcp:4777` 后配对/连接成功（host 日志 peer/remoteAddress=127.0.0.1）。
- 手动地址覆盖：完整链接 + 可达地址（只换连接路径，instanceId/token 仍来自链接），不弱化 CA 校验。
- 多台电脑：设备胶囊显示电脑名/在线状态、切换先关旧连接、切换失败停 failed + 重试/切换设备、
  冷启动自动连上次成功设备（真机 PASS）、菜单「移除已配对电脑」（本机删除 + 二次确认，真机 PASS）。

**验证（本机）**

- `flutter test` → **1882 项全通过**（本批新增扫码 17、发现 13、多方式 14、多设备 17 等）
- `flutter analyze` → 11 条既有基线；Kotlin debug/release 编译 BUILD SUCCESSFUL；宿主冒烟 14/14、
  发现自检 11/11、QR 自检 16/16、qr-e2e?（见 task-16 报告）；`tsc` 两个工程 exit 0
- 真机证据：`.cache/remote-device/p6-conn-*.png` 与 `.cache/remote-device/pairing-scan/`
- 真机环境限制：本次手机 Wi-Fi 与 PC 互 ping 不通（AP 客户端隔离），局域网直连/发现真机验证留待
  换网络；USB 方式不受影响，已可作开发机常驻连接

### 2026-11-16 02:50 · app-pair-scan（P6 第三批：App 侧「添加连接」四入口 + 局域网发现 UI）

**四入口（`apps/android/lib/remote_pairing_page.dart` 重构）**

- 添加连接页改为三段式 + 高级入口：**粘贴链接 / 扫码配对 / 搜索局域网**，外加可展开的
  **手动地址与令牌（高级）**。四种方式都把同一条配对链接交给既有 `RemotePairingFlow`
  （解析 → `/ca.cer` 校验 instanceId → `/pair` → 设备令牌进 Keystore），协议与信任语义零改动。
- 扫码：沿用 task-16 的原生相机 + ZXing 通道；扫到链接后校验（既有 `PairingDescriptor.parse`）
  并回到粘贴视图，覆盖已有内容前先确认；相机不可用/取消/解码失败给可读提示并保留粘贴入口。
- 局域网发现：首次切到「搜索局域网」或点「重新搜索」才发起，默认 2.5 s 窗口，结束即关闭
  套接字（不在 `initState` 轮询、页面静置无 UDP 流量）；结果三态：`open=true` 行内「连接」
  直接用宿主回的 `pairUrl`；`open=false` 提示去电脑重开配对窗口 + 重试；空结果给
  同网段/防火墙/UDP 4778/AP 隔离说明；失败给中文原因并保留扫码/粘贴回退。
- 手动地址（高级）：**必须粘贴完整配对链接**，地址只做覆盖（USB adb reverse 填
  `127.0.0.1:4777`，反代填可达域名:端口）；`instanceId`/token 仍取自链接，不把「从该地址现取
  的证书」当信任锚。只给 host:port 或 43 字符 token 时明确提示粘贴完整链接（不弱化校验）。
  宿主叶子 SAN 恒含 `127.0.0.1`/`localhost`，USB adb reverse 的固定 CA 校验可通过。

**新模块与测试**

- 新增 `apps/android/lib/remote_discovery.dart`（零 Flutter 插件依赖，`dart:io` UDP）：
  广播探测/单播收集、严格解析（`v`/`kind`/`nonce` 回显/`origin`/`instanceId`/`pairUrl` 走
  `PairingDescriptor.parse` 且 instance 一致）、按 `instanceId` 去重、坏帧静默、绑定/发送失败
  翻译成可展示原因、`dispose` 结束进行中的窗口。
- 新增 `apps/android/test/remote_discovery_test.dart`（解析/坏帧/nonce/去重/超时/dispose/
  绑定失败/重入）与 `apps/android/test/remote_pairing_methods_test.dart`（懒加载、发现三态、
  手动地址合成与非法输入、扫码入口保留）；`remote_pairing_scan_test.dart` 随三段式入口改为
  先切「扫码配对」（断言不变）。
- 文档：`reachability.md` 追加 §11「手机侧连接方式」（四入口、USB adb reverse 步骤、反代地址
  覆盖、地址变化处理）；`discovery.md` 追加 §11「App 侧实现」。

**验证（本机）**

- `flutter analyze` → **11 条既有基线**（无新增）
- `flutter test test/remote_discovery_test.dart test/remote_pairing_methods_test.dart
  test/remote_pairing_test.dart test/remote_pairing_scan_test.dart` → **全绿**
- 真机验收待 lead：宿主重启后打开配对窗口，手机「添加连接 → 搜索局域网」应发现电脑并可直接
  配对（UDP 4778 专用网络放行；收不到时用扫码/粘贴回退，不改防火墙配置换用回环自测）

### 2026-11-16 02:32 · host-discovery（P6 第二批：局域网 UDP 自动发现，宿主侧完成）

**新协议与实现（App 侧待接）**

- 新增 [discovery.md](discovery.md)（协议 v1 契约）：UDP **4778**。App 广播
  `{v:1, probe:"DSH-REMOTE-DISCOVER", nonce}`；宿主单播回
  `{v, kind:"dsh-remote-host", name, origin, instanceId, pairing:{open:true, pairUrl, expiresAt}|{open:false}, nonce}`。
  配对窗口关闭只回 `{open:false}`；坏帧静默、按来源 1 s 限速（来源表 256、表满失败关闭）、TTL=1、
  无应答缓存。发现只是把**现有配对链接**递给手机，不建立信任、不改 protocol/wss/配对语义。
- 新增 `apps/remote-host/src/discovery.ts`（`DiscoveryResponder` + 可注入 `DiscoverySocket`）：
  `start()` 把端口占用/权限不足降级成一条 warn（宿主照常启动、不自动重试），`stop()` 幂等，
  套接字 `unref()` 不阻塞进程退出；日志新增 `discovery-listening` / `discovery-failed` /
  `discovery-disabled`。
- `apps/remote-host/src/index.ts`：Config 新增 `discoveryEnabled`（默认 true）与 `discoveryPort`
  （默认 4778，schemastery 校验）；初始配对窗口打开后再启动发现；`POST /pair` 成功后立即清空当前
  票据（后续应答不再宣传可配对）；卸载时先停发现、再关窗口与监听。
- 新增 `apps/remote-host/scripts/discovery-selfcheck.ts`：**11/11 PASS**（真实回环 UDP 协议字段/
  窗口关闭/坏帧/限速恢复/stop-start + 假套接字 TTL/unref/最坏 802 B 单包 + 端口占用降级）。

**与二维码、反代的关系**

- 发现返回的 `pairUrl` 与 PC 日志、终端二维码里的是**同一条**链接：二维码解决「PC → 手机」的
  传递，发现解决「手机 → PC」的自动寻址；配对仍走 protocol §2 的一次性令牌。
- 跨网段/反代/Tailscale 场景发现无用（广播不跨网段），继续扫码或粘贴；可达性结论见
  [reachability.md](reachability.md)，本次不改 TLS 固定 CA 与协议要求。

**验证（本机全部跑过）**

- `node --import tsx/esm apps/remote-host/scripts/discovery-selfcheck.ts` → **11/11 PASS**
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` 与 `-p tsconfig.host.json` → 均 exit 0
- `pnpm exec oxlint` 三个改动文件 → 0 warnings / 0 errors
- 宿主冒烟 `smoke-remote-host.ts` → **14/14 PASS**（无回归）
- 真实宿主演练（独立 `DSH_HOME` + 端口 4797 / 发现端口 4798）：回环探测得到的 `pairUrl` 与日志
  一致；`POST /pair` 成功后同源再探测 → `{open:false}`；100 ms 内两次探测只回 1 帧（限速）；
  4 种坏帧 0 应答；停止后 TCP/UDP 端口均释放
- 待 lead：重启 4777 宿主后真机验证广播（Windows 防火墙需放行**专用网络** UDP 4778，AP 隔离会
  拦广播）；可先按 discovery.md §5.3 跑 PC 侧广播自测确认宿主在应答（该自测证明不了防火墙，不要为自测改防火墙设置；回环自检已覆盖协议结论）

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
