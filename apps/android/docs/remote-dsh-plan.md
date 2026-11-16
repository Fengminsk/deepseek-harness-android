# 远程 DSH · 开发线路规划

状态：已实施到 M1（真机端到端通过，2026-11-15）；剩余项与当前状态见 §12 与
[remote-dsh/HANDOFF.md](remote-dsh/HANDOFF.md)
范围：`apps/android`（App）+ PC 侧远程宿主 + 二者之间的协议
参照实现：`apps/dsh-mobile`（第三方，Apache-2.0，仅作设计参考，不引入依赖）

> 接手开发先读 [remote-dsh/HANDOFF.md](remote-dsh/HANDOFF.md)：它是当前状态的唯一入口（环境、代码地图、分工、剩余项、变更日志）。本文是选型与阶段设计，进度以手册为准。

---

## 0. 结论先行

**走 A 路线：复用 App 自己的 App-RPC 门面，把传输从本地 socketpair 换成 `wss://`。**

三条被评估过的路线：

| | 路线 | 判定 |
|---|---|---|
| A | PC 侧运行 App 已有的 runtime 门面，通过 TLS WebSocket 提供同一套 JSON-RPC 方法表 | **采用** |
| B | App 直接改说 DSH 的 Web 协议（`POST /api/<ns>/<method>` + `WS /api/remote.mux`） | 否决 |
| C | App 内嵌 WebView 打开 PC 的 DSH 网页 | 否决（与"原生体验"前提冲突） |

A 之所以成立，是因为三个已经存在的事实：

1. App 的 UI **全部**建立在 `RuntimeController` 这一个传输缝上（`lib/runtime.dart:34`），且该缝只有两个原语：`request(method, params)` 与通知流。
2. 该方法表是 `apps/android/runtime/index.mjs` 实现的一个 Cordis 插件（`name='android-runtime'`），**纯 Node ESM、无 Android 编译依赖**，可以被 PC 上的 DSH 加载。
3. 底层帧协议 `JsonRpcLineTransport` 是对**任意 `Readable`/`Writable`** 工作的（`packages/sdk/protocol/src/transport.ts:65-77`），换物理通道不需要改语义。

也就是说：**工作量不在 UI，也不在协议，而在四处**——门面的平台拆分、原生反请求、流控背压、身份与配对。

初步估时：单人 11–15 周；两名开发者（PC 宿主 ∥ App 传输）可压到 6–8 周。**技术可行性证伪点在第 4–5 周**（§6 M1）。

---

## 1. 需求与设计参照

### 1.1 需求原文拆解

- 侧栏新增一个"远程 DSH"入口按钮。
- 点进去的交互与 UI 对齐 Codex（已提供 8 张截图）。
- 手机连 PC 上的 DSH 干活（PC 比手机利索时）。
- 原生体验，不要 WebView。
- 借助网络上的开源项目（已指定 `saya-ch/dsh-mobile`）。

### 1.2 八张截图逐张解读与映射

参照图存放在 `docs/设计参照截图/远程DSH功能/`（注意：这 8 个文件实际是 JPEG 字节，扩展名标成了 `.png`；用于查看时需按 JPEG 解码）。

| # | 截图内容 | 控件语义 | 现有实现对应物 | 性质 |
|---|---|---|---|---|
| 1 | 侧栏顶部组多出「远程DSH」，鲸鱼图标，选中态 | 入口 | `chat_sidebar.dart:526-558` 的 destinations 列表 | **新增 6 行** |
| 2 | 远程首页：☰ / 标题+▾ / 搜索；设备 chips（全部·云端·lumosUltra·公司笔记本，带状态点）；「项目」分组 + 会话行；底部悬浮输入条 | 设备维度的会话浏览 | chips=新概念；项目=`library.workspaces`；会话行=现有 `_SessionRow` 语义 | **新页面** |
| 3 | 点标题展开菜单：优先级 / 按项目✓ / 按时间倒序 / 优先显示"最近" / 管理(已归档任务·添加连接·设置) / 剩余用量 | 排序与设置菜单 | 排序=新；已归档=`session/` 归档能力；剩余用量=`account/getBalance`（已有 `account_quota_notice.dart`） | **新弹出层** |
| 4 | chips 横向滚动，选中项高亮，其余设备灰态 | 设备切换 | 新 | 小 |
| 5 | 会话页：返回 / 标题+「设备 · 项目」副标题 / 编辑+「…」胶囊；用户气泡；「用时 56分钟22秒 ›」折叠行；正文 markdown；复制·赞·踩·转发·时间；底部加载指示；输入条「在 lumosUltra 上工作」 | 会话视图 | 对话内核已有；「用时」需从 turn 事件推导；副标题需设备+workspace 名称 | **外壳 + 少量新数据** |
| 6 | 输入框聚焦、键盘弹起：`+`、盾牌（审批）、模型/推理强度、麦克风、语音 | 输入区控件 | 均有对应：附件、`permission_policy`、模型选择、语音 | 重组 |
| 7 | 审批策略底部弹层：请求批准 / 替我批准 / 完全访问(风险较高) / 自定义(config.toml) | 权限预设 | DSH `permissionPresets` 目录 + App 的 `auto_review_settings`、`permission_policy` | **换皮为主** |
| 8 | `+` 展开：相机 / 照片 / 文件 / 插件 / 方案模式 / 追求目标 | 输入区能力清单 | 附件、`plugins`、`plan`、`goal`——DSH 与 App 均已实现 | **换皮为主** |

**关键判断：截图里每一个控件在 DSH 与 App 里都已经有对应物。** 所以这不是"造一个新产品"，而是"给既有能力换一套编排与外观"。这决定了估时——UI 是重排与换皮，不是从零实现 tool cards、diff、审批表单。

### 1.3 需要用户确认的三件事

见 §10。若三件事的答案不同，P4 的排期会变，P1–P3 不受影响。

---

## 2. 现状：我们的 App 是怎么跑起来的

### 2.1 五跳链路

```
Dart  RuntimeController.call(method, params)
 └─ MethodChannel('dsh/runtime')  invokeMethod('call', json)
     └─ MainActivity.kt:549  注入 jsonrpc/id → Binder Messenger
         └─ AgentService.kt:227-263  约 40 个方法原生拦截；其余写入 socketpair fd
             └─ Node transport.mjs  JsonRpcLineTransport(fd)
                 └─ runtime/index.mjs  transport.onRequest 大表分发
```

回程：Node `notify` → socket 行 → `MainActivity.createReplies` → **带 `id` 的帧结算 MethodChannel 结果，其余帧原样推给 `EventChannel('dsh/events')`**。

### 2.2 唯一的传输缝

`RuntimeController`（`lib/runtime.dart:34`）在 `main.dart:65` 构造一次，构造注入到所有页面。它提供：

- `call(method, params)` — 唯一请求原语（`lib/runtime.dart:608-623`）
- `watchApi(...)` — 唯一流订阅原语（`lib/api_streams.dart`）
- `EventChannel` 单订阅 + 巨型 `switch` 分发（`lib/runtime.dart:313-397`）

**好消息**：业务代码从不绕过它去碰工作区文件。整个 `lib/` 只有两处 `dart:io`，都是取头像（`account_avatar.dart:3`、`network_proxy.dart:2`）。没有任何对工作区/会话文件的直接 `File` 读写。

这是本项目**最有利的一条事实**：App 天然就是个"瘦客户端 + 富渲染"的结构，远程化不需要重写任何数据获取路径。

**坏消息**：`RuntimeController.channel` 是 `static const`（`lib/runtime.dart:36`），且另有约 25 个文件直接用它做**纯原生**的事（选择器、分享、偏好、WebView、通知）。这些留在本地是对的，但意味着"换传输"必须是**替换一个内部对象**，而不是把整个类复制一份。

### 2.3 门面方法表（`apps/android/runtime/index.mjs:409` 起）

单 `transport.onRequest` 分发：68 个 `case` 方法名 + 6 组命名空间前缀（`workspaceChanges.`、`references.`、`library.`、`workspace.files.`、`document.`、`terminal.`）。

| 组 | 代表方法 | 远程语义 |
|---|---|---|
| 运行时 | `runtime.info` / `runtime.permissions` / `runtime.live` / `runtime.transition.*` | 需按平台重写 |
| 会话读 | `session.readWindow` / `session.read` / `session.turnOutline` | 随宿主走，天然可用 |
| 会话写 | `session.send` / `session.ensure` / `session.command` / `session.cancel` / `session.selectPreset` | 随宿主走 |
| 通用 RPC | `api.call` / `api.subscribe` / `api.ack` / `api.unsubscribe` | 随宿主走（本质是 `typertGateway` 的透传） |
| 文件 | `workspace.files.*` / `session.attachmentFile.*` / `document.*` / `chat.image.preview` | 随宿主走；`document.*` 的渲染端在设备侧 |
| 变更 | `workspaceChanges.summary` / `.diff` / `.cancel` | 随宿主走 |
| 任务 | `tasks.*` / `subagents.*` | 随宿主走 |
| 交互 | `interactions.list` / `.reply` / `.dismiss` / `.wait` | 随宿主走 |
| 设置 | `settings.describe` / `settings.mutate` / `configuration.transfer.*` | 随宿主走 |
| 凭据 | `credentials.describe` / `.set` / `.unset` | 远程时必须改为 PC 侧保管 |
| 附件/导出 | `attachments.*` / `session.export.*` | 一半随宿主、一半在设备 |
| 网页 | `web.status` / `.configure` / `.rotate` | 远程无意义 |

### 2.4 真正的裂缝：`native.*` 反向请求

runtime 不是只被动应答，它会**反向**向设备发请求（`transport.request('native.…')`），由 `AgentService.kt` 原生应答：

| 反向方法 | 用途 | 远程时归属 |
|---|---|---|
| `native.storage.root` | 应用私有根目录 | **PC** |
| `native.attachments.directory` | 附件落盘目录 | **PC** |
| `native.exports.directory` / `native.attachmentFiles.directory` | 导出目录 | **PC** |
| `native.credentials.*` | Keystore 取密钥 | **PC**（改用 DSH 凭据服务） |
| `native.documents.roots/list/read/search/revoke` | SAF 用户授权文档 | **手机**（语义是"手机上的文件"） |
| `native.toolCallback` / `native.workflowCallback` | 受限执行的跨进程回调 | v1 不支持 |
| `native.linuxVm.*` / `native.scheduleWake.*` / `native.networkChanged` / `native.appDisconnected` | Android 专属 | v1 不支持 |

**这条决定了协议必须是双向的，而不是纯"客户端调服务端"。** JSON-RPC 天然支持双向，但两侧都要新增 `onRequest` 处理，这一点必须在 P0 就写进协议。

---

## 3. dsh-mobile 项目分析

### 3.1 它到底是什么

`dsh-mobile` v0.8.9，Apache-2.0，单 commit 浅克隆（`8184d79`），约 90 MB。三层结构：

```
手机（Android App = WebView 壳 / 手机浏览器）
   │ 局域网 HTTPS 或 远程 HTTPS
   ▼
DSH Mobile Gateway（插件自己起的第二个 TLS 监听）
   │ 回环反向代理 + 设备认证
   ▼
DSH 原生 Web 与 Host（127.0.0.1:3080，未被改动）
```

插件不改 DSH 安装目录里的任何文件；它**反向代理**上游，并重写 index HTML 注入移动布局。

### 3.2 最重要的发现：它没有自己的客户端协议

它有 229 KB 的 `gateway.ts`、409 KB 的 `client.ts`，但**客户端↔宿主协议完全属于 DSH 自己**：

| 能力 | 归属 | 证据 |
|---|---|---|
| 一元 RPC `POST /api/<ns>/<method>` | DSH `@deepseek-ai/dsh-client-connection` | `packages/client/connection/src/rpc-host.ts:316-405` |
| 复用流 `WS /api/remote.mux` | DSH `@deepseek-ai/dsh-api-gateway` | `packages/api/gateway/src/stream-protocol.ts:7` |
| 认证 / 配对 / TLS / 隧道 | dsh-mobile | `apps/dsh-mobile/src/gateway.ts:1960-2091` |

它自己的 WebSocket 白名单直接引用 DSH 路径（`apps/dsh-mobile/src/http-security.ts:11-18`），其中 `/api/events.mux`、`/api/events.host` 在现版本 DSH 里已是死路径。

**推论**：想"借用 dsh-mobile 的协议"这件事本身不成立——它没有协议可借。能借的是**手法**，不是协议。

### 3.3 值得吸收的八处设计

| # | 手法 | 证据 | 我们怎么用 |
|---|---|---|---|
| 1 | 每设备不透明令牌，**落盘只存 SHA-256 摘要**，比较用 `timingSafeEqual` | `src/access.ts:142-156, 413` | 直接照搬 |
| 2 | 配对码 43 字符 base64url、120 s TTL、单次有效、按对端限速且**失败关闭** | `src/access.ts:299-341` | 直接照搬 |
| 3 | 私有 CA，**CA 指纹 == instanceId**，配对链接携带 instanceId，App 拉到 CA 后校验指纹才固定 | `src/managed-setup.ts:534`、`src/pairing-trust` | 直接照搬（TOFU 的正确做法） |
| 4 | 发现三条路：mDNS `_dsh-mobile._tcp` + UDP 广播 + `/24` HTTPS 扫描兜底 | `apps/mobile/.../NsdDiscovery.kt`、`LanDiscovery.kt` | v2 采纳；v1 先 QR + 手输 |
| 5 | 用 `/health` 探测**驱动重连**，并伪造 `online/offline` 事件，而不是信 `navigator.onLine` | `src/gateway.ts:349-399` | 采纳其思想 |
| 6 | 会话到期用 **WS Close 1000** 优雅收尾，客户端据此续期而不是 1006 | `src/gateway.ts:4456-4487` | 采纳其思想 |
| 7 | 设备撤销：先落盘删除、再终止该设备全部会话、最后推 `device-revoked` | `src/access.ts:451-467` | 直接照搬 |
| 8 | 可达性做成**单选 provider 槽位**（tailscale/cpolar/cloudflared/frp/origin/iroh），局域网恒独立 | `src/remote.ts:10, 135-153` | 只借"槽位"思路，v1 不做实现 |

另外两条工程约束值得记住：远端一条 `pairingCaFile` 的私钥从不落地为客户端证书（`requestCert: false`），以及**不要**把 `addJavascriptInterface` 用于桥接（他们用 `addWebMessageListener` + 逐条精确 Origin 校验）。

### 3.4 不能用的部分

| 部分 | 为什么不适用 |
|---|---|
| `src/mobile-layout.ts`（71 KB，1318 行） | 纯 React/DOM/CSS：注册 `root` slot、写 `<style>`、`matchMedia`、`useLayoutEffect`。对原生零价值。 |
| `src/client.ts`（409 KB）、`src/client-messages.ts`（187 KB） | 浏览器侧补丁与布局逻辑 |
| bootstrap 图 / `/plugins/events` / `__DSH_BOOT__` / 客户端模块注入 | 只服务于"把 Web 客户端加载进 WebView" |
| Android 壳的 4 400 行 `MainActivity` | 我们可以直接参考其信任模型，但代码不可复用 |
| Web Push / VAPID | 只对 Safari 主屏幕 App 有效；Android 后台通知靠"前台服务 + SSE"，见 `src/gateway.ts:4284-4330` |

### 3.5 结论

> **把 dsh-mobile 当"设计参考与手法库"，不做依赖、不做 fork。**

理由：它的价值 90% 在宿主的认证/配对/TLS/隧道层，而那层服务的协议是 DSH 的 *Web* 协议——与我们原生 App 使用的 App-RPC 门面是两套东西。直接采纳它意味着 App 要改说 Web 协议，也就是 B 路线，见 §4。

---

## 4. 技术选型

### 4.1 三条路线的实质差别

**A. 门面搬过去（推荐）**

PC 上跑一个 DSH 实例，加载与 App 相同的 runtime 门面插件，把传输接到 TLS WebSocket。App 只换物理通道。

**B. 改说 DSH Web 协议**

App 直接实现 `POST /api/<ns>/<method>` 与 `WS /api/remote.mux`。

**C. WebView**

明确违背需求前提，且 App 现有 `BrowserUrlPolicy` 直接在代码层拒绝私有/LAN 主机（`lib/browser_url.dart:64-76`）。

### 4.2 对比

| 维度 | A | B | C |
|---|---|---|---|
| UI 改动 | 只加远程外壳 | 只加远程外壳 | 几乎为零 |
| 需要重指向的门面方法 | **0** | **~30 个无 Web 对应物** | 0 |
| 会话历史窗口 `session.readWindow` | 直接可用 | **无 Remote 等价物**（使用进程内 `ctx.sessionController`） | 可用 |
| 终端 | 可用（桌面 `terminal-controller` 反而更完整） | 需逐个对齐 | 可用 |
| Office/PDF 预览 | 可用（`officeToPdf` 走宿主） | 需迁移 | 可用 |
| 协议数量 | 1 套 | 2 套（本地门面 + Web 协议），永久双维护 | 1 套 |
| 依赖 DSH 内部实现 | 是（本仓库就是上游，可控） | 是，且更深（typert 生成物 + React 侧的推导逻辑） | — |
| 原生体验 | 是 | 是 | **否** |
| 主要风险 | 门面平台拆分 | 无对应物的方法 | 需求不成立 |

### 4.3 为什么 B 比看上去贵

Web 协议本身是干净的 JSON 契约，但它只提供**原始事件与状态**。让这些状态变成"一个聊天应用"的那部分——事件关联、assistant chunk 折叠、tool card 推导、分页窗口、审批呈现——全部在 `packages/client/ui-*` 与 `packages/api/*-controller/src/client/` 的 TypeScript 里，没有协议,没有规格。参考项目的独立评估结论是：照此重写一个会话模型需 2–3 个月。

而我们已经拥有这一切（Dart 侧 `chat_projection.dart`、`chat_messages.dart`、`tool_activity*.dart` 等），它们建立在门面之上。**放着已有的不走，去重写一份，是把最贵的部分重做一遍。**

### 4.4 一个必须承认的代价

A 路线意味着**把 App 的运行时代码搬到 PC**。需要在仓库层面对 `apps/android/runtime` 的平台归属做出决定（§5.3）。这不是免费的：该目录下有 30 多个测试文件。

---

## 5. 目标架构

### 5.1 全景

```
┌─────────────────────────────────────────────────────────┐
│ Flutter App                                              │
│                                                          │
│  RuntimeController(kind: local)                          │
│    └─ LocalTransport ─ MethodChannel ─ AgentService ─ fd ─┐│
│                                                          ││
│  RuntimeController(kind: remote)   ← 新增                 ││
│    └─ RemoteTransport ─ dart:io WebSocket + TLS 固定 ─────┼┼─┐
│                                                          ││ │
│  RemoteDshPage / 设备列表 / 配对扫描   ← 新增              ││ │
└─────────────────────────────────────────────────────────┘│ │
                                                            │ │
┌───────────────────────────────────────────────────────────┘ │
│ Node（本地 profile android）                                   │
└───────────────────────────────────────────────────────────────┘
                                                              │
                          wss://<pc>:<port>/app                │
                              JSON-RPC 行帧                     │
                                                              ▼
┌─────────────────────────────────────────────────────────────┐
│ PC：DSH + remote-host 插件                                   │
│                                                              │
│  tls/        CA + 叶子证书（自签，随 IP 变更重签）             │
│  identity    instanceId（CA 指纹 == instanceId）              │
│  devices.json 每设备 token 摘要、标签、撤销状态                │
│                                                              │
│  WebSocket 监听 ─ 每连接一个 JsonRpcLineTransport              │
│      └─ 同一套门面方法表（与 App 本地完全一致）                 │
│      └─ 桌面 native provider 应答反向 native.*                │
└─────────────────────────────────────────────────────────────┘
```

**核心性质：手机与 PC 之间是一条双向 JSON-RPC 管道，方法表完全相同。** 本地模式与远程模式的差异只有物理端点和身份，没有协议差异。

### 5.2 协议 v1 规格（P0 交付物）

传输：单条 `wss://host:port/app`，帧格式沿用现有 newline-delimited JSON-RPC 2.0，不改封装。

握手（首帧，客户端发起）：

```jsonc
→ {"jsonrpc":"2.0","id":"1","method":"protocol.hello","params":{
     "protocolVersion":1,
     "appVersion":"0.1.0+120",
     "deviceLabel":"Pixel 8",
     "capabilities":["binary-upload","window-ack"]}}
← {"jsonrpc":"2.0","id":"1","result":{
     "protocolVersion":1,
     "host":{"name":"Colin 的台式机","home":"C:\\Users\\…\\DSH","platform":"win32"},
     "capabilities":["window-ack"],
     "methods":["runtime.info","session.send","…"],
     "unsupported":["documents.*","linuxVm.*","scheduleWake.*"]}}
```

- `methods` / `unsupported` 让 App 在**连接时**就知道该隐藏哪些入口，而不是逐个方法失败。
- 版本不匹配直接以 `-32000 protocol-mismatch` 关闭，App 提示升级而不是半残工作。
- 握手后进入既有的 `runtime.ready` / `runtime.status` 流程，**保持 App 现有阶段协议不变**（`lib/runtime.dart:399-452` 的分代与重连逻辑依赖它）。

反向请求：沿用 `native.*` 命名空间，方向反过来。PC 侧客户端代码里 `transport.request('native.storage.root')` 会以请求帧到达 App。

### 5.3 门面平台拆分（P1）

现状：`apps/android/runtime/index.mjs` 无条件注册 `AndroidShell`、`AndroidCredentials`、Linux VM 工具、PTC 回调等。

方案：给插件加 `Config.platform: 'android' | 'desktop'`，把 Android 专属注册全部置于 `android` 分支，新增 `apps/android/runtime/native-desktop.mjs` 应答桌面 `native.*`：

| 反向方法 | 桌面实现 |
|---|---|
| `native.storage.root` | `resolveDshHome()` |
| `native.attachments.directory` | `<DSH_HOME>/app-attachments` |
| `native.exports.directory` | `<DSH_HOME>/exports` |
| `native.attachmentFiles.directory` | 同附件目录 |
| `native.credentials.*` | 转发 `ctx.credentials` |
| `native.documents.*` | 标记不支持（v1） |
| `native.toolCallback` / `native.workflowCallback` | 标记不支持（桌面 PTC 走进程内） |
| `native.linuxVm.*` / `native.scheduleWake.*` | 标记不支持 |

> **备选（更干净但更贵）**：把门面抽成 workspace 包 `packages/app-runtime`，`apps/android/runtime` 退化为 Android 组合层。建议**推迟到 P5 之后**做，先加 `platform` 配置验证可行性，避免一开始就动 30 多个测试。

PC 侧组合（新 profile，例如 `profiles/remote-host`）：

- 启用真实的 `terminal-controller`（App 本地 profile 里它是 `disabled: true`）
- 使用 `workspace` + `session-persistence-jsonl` 而非 Android 实现
- 关闭 `android-filesystem` / `android-directory-picker` / `android-attachment-store`
- 插入 `remote-host` 插件（监听器 + 身份 + 设备表）

### 5.4 身份与信任（P3）

照搬 §3.3 中被验证过的形状，但因为**没有浏览器**而可以简化：

| 项 | 设计 |
|---|---|
| PC 身份 | `identity.json`：`instanceId`（32 字节随机 hex）、显示名 |
| TLS | 自签 CA + 叶子，SAN 覆盖当前网卡 IP 与主机名；CA 指纹 == `instanceId` |
| 配对展示 | QR/短码 = `pocket-dsh://pair?origin=<wss>&instance=<64hex>&token=<43chars>`，TTL 120 s，单次 |
| 配对流程 | App 以"不校验"方式取 `/ca.cer` → **校验 SHA-256(CA) == instance 才固定** → `POST /pair` → 得 `deviceToken` |
| 稳态认证 | WS 握手头 `Authorization: Bearer <deviceToken>`，服务端比对摘要 |
| 撤销 | PC 设备列表逐条撤销；撤销即关闭该设备所有连接（Close 4001）并拒绝重连 |
| 存储 | token 进 Android Keystore（复用 `CredentialVault`）；主机/端口/别名进 SharedPreferences |

**为什么不要 cookie/CSRF**：CSRF 保护的是"浏览器自动携带的环境凭证"。这里没有浏览器、没有 cookie、凭证由客户端代码显式放在请求头里，不构成跨站伪造面。但仍要求精确 `Origin` 校验作为纵深防御（防止本机恶意页面连上）。

**简化不等于放松**：配对 = 完全信任（能控制整台 PC）。UI 必须把这个后果写清楚，并把"仅局域网"设为默认。

### 5.5 流控（P2，本地也要改）

现状是一个**逐条 ack** 的流控（`apps/android/runtime/streams.mjs:45-57`、`api_streams.dart:222-237`）：生产者发一条、等客户端 ack 再发下一条。

- 本地 loopback 下无所谓；**RTT 100 ms 时等于每条 10 条/秒**，`session/control`、`workspace/follow` 会直接崩。
- 且客户端遇到序号不连续会**判定致命并关闭流**（`api_streams.dart:186-194`），没有续传。

方案：改为**窗口化确认**——服务端在窗口（如 64 条 / 1 MiB）内连续推送，客户端按 `api.ack {streamId, upTo}` 周期性回执。本地与远程都切到新协议（单一代码路径优于双路径），需要为本地模式补回归测试。

### 5.6 App 侧改动

1. 抽 `RuntimeTransport` 接口（`request` / `notifications` / `close`），`LocalRuntimeTransport` 包装现有双通道，行为不变。
2. `RuntimeController` 增加 `RuntimeKind` 与 capabilities，状态机 `connecting → handshaking → ready → reconnecting → lost` 仍映射到既有 `runtime.status` 帧。
3. 新增 `RemoteRuntimeTransport`：`dart:io` 的 `WebSocket.connect`（`wss`），`SecurityContext` + 固定 CA 校验；无需新增 pubspec 依赖。
4. 远程模式不启动 `AgentService`、不申请前台服务、不做崩溃恢复——`runtime.dart` 里与 Service 绑定的分支需按 kind 短路。
5. 设备存储与配对 UI。
6. 侧栏入口（`chat_sidebar.dart:526-558`）+ 远程页面（新文件，`PocketScaffold` 风格）。

### 5.7 可达性阶梯

| 阶段 | 形态 | 说明 |
|---|---|---|
| v1 | 局域网直连 | 默认；PC 自主 TLS |
| v2 | 用户自有反向代理 | 只要能把 `wss` 转发到 PC 即可，App 不改代码 |
| v3（可选） | 隧道托管 | 参照 dsh-mobile 的 provider 槽位，逐条接 Cloudflare 命名隧道 / Tailscale |

---

## 6. 阶段计划

每个阶段都以"可验收的行为"结束，不以"代码写完"结束。

| 阶段 | 主题 | 交付物 | 验收 | 估时 |
|---|---|---|---|---|
| **P0** | 协议冻结 | 本文件 §5.2 落成独立 `protocol.md`；能力表；`protocol.hello` 字段定稿 | 两位评审对同一份协议无歧义 | 3–5 天 |
| **P1** | PC 宿主 | `platform` 配置 + `native-desktop.mjs` + `remote-host` 插件 + 远程 profile | **用 Node 脚本连上 PC，跑通一次真实对话**（发消息→流式回复→工具调用→审批） | 10–15 天 |
| **P2** | 传输与流控 | Dart `RuntimeTransport`、`RemoteTransport`、窗口化 ack、重连 | 本地模式零回归；远程断网重连后会话状态正确；100 ms 注入延迟下流不中断 | 8–10 天 |
| **P3** | 配对与设备 | CA/固定/QR 扫描/设备表/撤销 | 从零配一台新 PC ≤ 3 步；撤销后旧设备 1 秒内被断开 | 8–10 天 |
| **P4** | 远程外壳 | 侧栏入口、首页（chips/项目/会话）、标题菜单、会话页头、输入条变体、审批弹层、`+` 弹层 | 8 张截图逐条对照通过 | 15–20 天 |
| **P5** | 能力补齐 | 手机附件上传、远程文件浏览、终端、workspace diff、不支持项的隐藏/置灰 | 每种能力有"支持/降级/不可用"三态且可见 | 10–15 天 |
| **P6** | 可达性 | 反代/隧道文档、mDNS 发现、后台通知 | 跨网络可用；通知可送达 | 持续 |

**里程碑**

- **M1（≈ 第 4–5 周，P1+P2）**：技术可行性证伪点。此时应能在一台真机上，远程连 PC、发消息、看流式回复。**若 M1 不成立，后面全部作废，立即回到 §4 重新选型。**
- **M2（≈ 第 8 周，P3）**：可以交给别人试用。
- **M3（≈ 第 12–14 周，P4）**：达到截图水准。

**排期建议**：P1 与 P2/P3 可以并行（P0 冻结后两条线互不阻塞），这是 6–8 周压缩的来源。

---

## 7. 测试与验收

| 层 | 方法 | 关注点 |
|---|---|---|
| 协议 | 双端契约测试（Node 客户端 ↔ Node 服务端；Dart 客户端 ↔ Node 服务端） | 帧格式、`protocol.hello`、错误码、反向请求 |
| 流控 | 注入人为延迟（`tc`/代理）在 50/100/300 ms 下跑长会话 | 不中断、不丢序、ack 窗口不溢出 |
| 重连 | 拔网、休眠、PC 重启、撤销设备 | 状态机不卡死；不会永久空转 |
| 能力降级 | 连接一个缺少 `terminal` 的宿主 | 入口隐藏而非报错 |
| 回归 | 本地模式全量手工冒烟 + 现有 runtime 测试套件 | 远程改动不得影响本地 |
| 真机 | 至少一台 Android 10 与一台 14+ | 键盘、返回手势、扫描、Keystore |
| 安全 | 错误 token、过期 token、撤销后、伪造 Origin、中间人证书 | 全部拒绝且不泄露信息 |

**验收纪律**：每种能力必须给出"支持/降级/不可用"的明确状态，并在 UI 上可见。不接受"能点但没用"。

---

## 8. 风险登记册

| # | 风险 | 影响 | 概率 | 缓解 |
|---|---|---|---|---|
| R1 | 门面平台拆分动了 30+ 有测试的 runtime 模块 | 高 | 中 | 先加 `platform` 配置不动结构；M1 前不动已有测试 |
| R2 | 逐条 ack 在 WAN 下不可用 | 高 | **高** | P2 提前做窗口化；这是 M1 的必过项 |
| R3 | 严格解析器拒绝非 Android 宿主（`permission_policy.dart:29-58` 对 `shell.tool` 有硬校验） | 中 | **高** | 远程模式改走新增的 `runtime.capabilities`，不调用 `runtime.permissions` |
| R4 | `runtime.status` 阶段协议未被正确复刻 | 高 | 中 | 现有页面普遍以"代际"作废迟到结果；协议必须原样实现 |
| R5 | 手机侧反向请求（SAF/附件）语义错位 | 中 | 中 | v1 明确不支持 `documents.*`；P5 再做"手机文件上传" |
| R6 | 大帧（16 MiB）与无压缩 | 中 | 中 | 开启 permessage-deflate；附件分块 |
| R7 | 版本漂移（PC 与 App 方法表不一致） | 中 | 高 | `protocol.hello` 带版本 + 方法清单；不匹配即拒绝 |
| R8 | PC 侧分发与安装体验 | 中 | 中 | 先做 CLI/profile 启动；一键化放 P6 |
| R9 | 安全口径被误解为"仅局域网就安全" | 高 | 低 | 配对页与文档明确"完全控制这台电脑" |
| R10 | 远程改动影响本地稳定性 | 高 | 低 | 传输层抽接口 + 本地全量冒烟作为合并门槛 |

---

## 9. 明确不做

- 不做 WebView/网页壳方案（C 路线）。
- 不引入 dsh-mobile 作为依赖，不 fork 它的 Web 布局模块。
- v1 不做公网穿透的自动化管理（隧道交给用户自己的反代）。
- v1 不做多 PC 并发连接（一次连一台，切换即重连）。
- v1 不让远程宿主操作手机本地文件（SAF 语义）。
- 不改 DSH 的 Web 协议、不改 `packages/client/*`。

---

## 10. 待决策项

| # | 问题 | 建议 | 影响 |
|---|---|---|---|
| D1 | 远程会话用**现有对话内核**（工具卡片、diff、审批表单齐全）还是照截图重做一个极简对话页？ | **现有内核 + Codex 外壳**。理由是截图里的极简形态隐藏了工具过程，而我们的用户需要看到 agent 在 PC 上做了什么；重做等于把最贵的部分重写。 | P4 估时 ±3 周 |
| D2 | 远程与本地是**两个并列入口**（各自完整），还是把"远程"做成"给现有会话换一个执行端"？ | 并列入口，与截图一致。换执行端会污染 `RuntimeController` 的单例假设。 | 数据模型 |
| D3 | PC 侧安装形态：`dsh --profile remote-host` CLI，还是 DSH Desktop 里的一个开关？ | 先 CLI（P1 就能用），Desktop 一键化放 P6。 | P1/P6 |
| D4 | 配对是否强制局域网 + TLS，还是允许明文（调试）？ | 强制 TLS；明文仅 debug 构建且显著标识。 | 安全口径 |
| D5 | 是否需要"多台 PC 的会话聚合视图"（截图里「全部」chip 暗示）？ | v1 的「全部」= 当前 PC 的全部项目；真正的跨机聚合放 v2。 | P4 |

---

## 附录 A · 关键证据索引

本仓库：

- `apps/android/lib/runtime.dart:34-37, 313-397, 608-623` — 传输缝、事件分发、请求原语
- `apps/android/runtime/index.mjs:409-588` — 门面方法表
- `apps/android/runtime/transport.mjs:2-69` — 本地传输与帧校验
- `apps/android/runtime/cordis.patch.yml` — Android profile 组合
- `packages/sdk/protocol/src/transport.ts:65-276` — 与传输无关的 JSON-RPC 实现
- `packages/api/gateway/README.md`、`packages/client/connection/README.md` — Web 协议（B 路线所需）
- `packages/api/remotes/src/remote-events.ts:27-59` — 30 条事件白名单

参照项目 `apps/dsh-mobile`：

- `src/gateway.ts:2218-2332`（路由表）、`4404-4554`（WS 升级）、`4588-4639`（配对与撤销）
- `src/access.ts:103-156, 299-341, 451-467` — 令牌、限速、撤销
- `src/http-security.ts:5-18, 87-126` — cookie/CSRF/CSP
- `src/remote.ts:10, 135-153` — 可达性 provider 槽位
- `apps/mobile/android/.../NativeBridge.kt`、`LanDiscovery.kt`、`NsdDiscovery.kt` — 桥与发现

## 附录 B · 与 dsh-mobile 的取舍一览

| 我们采用 | 我们不采用 |
|---|---|
| 每设备令牌 + 摘要落盘 | HTTPS 反向代理 DSH Web UI |
| 43 字符配对码 / 120 s / 限速 | cookie + CSRF 体系（无浏览器，改用 Bearer） |
| CA 指纹 == instanceId 的 TOFU | React 布局模块与 boot 图注入 |
| 设备撤销的三步顺序 | Web Push / VAPID |
| 可达性 provider 槽位思路 | 隧道组件的自动下载与校验 |
| 健康探测驱动重连 | 4000 行 WebView 壳的恢复机制 |
| mDNS + UDP 发现（v2） | `/24` 扫描兜底（v2 再评估） |

---

## 12. 实施进度（滚动更新）

### 12.1 已落地的决策

| # | 决策 | 取值 |
|---|---|---|
| D1 | 远程会话形态 | **复用现有对话内核 + Codex 外壳**。不做极简对话重写。 |
| D2 | 远程与本地关系 | 两个并列入口；远程有自己的 RuntimeController，不改造现有单例假设。 |
| D3 | PC 安装形态 | 先 CLI/profile（`dsh --profile remote-host`），Desktop 一键化放 P6。 |
| D4 | 传输安全 | 强制 TLS；明文仅 debug 构建且需显式标识。 |
| D5 | 「全部」chip | v1 = 当前这台 PC 的全部项目；跨机聚合放 v2。 |

实现期的两个附带决策：

- **流控字段名**：本地链路继续发送 `{subscriptionId, generation, sequence}`（Kotlin `DocumentPreview` 与既有测试依赖它，改动面过大）；远程链路在 `RemoteRuntimeTransport` 内映射为协议规定的 `{streamId, upTo}`。服务端 `streams.mjs` 同时接受两套字段名。
- **会话页容器**：`remote_dsh_conversation.dart` 使用自建 `Scaffold` 而非 `PocketScaffold`。理由是会话视图需要"贴底跟随 + 阈值判断 + 键盘驱动输入区让位"的自有滚动模型，`PocketScaffold` 的固定头部高度与 bottom 高度通知模型表达不了。其余页面与组件复用 `PocketScaffold`、`CommonPopup`、`ElasticPress`、`GlassButton`、`PocketTile`、`DaylightBackdrop`。

### 12.2 状态

| 阶段 | 状态 | 产物 |
|---|---|---|
| P0 协议冻结 | 完成 | `docs/remote-dsh/protocol.md`（48 KB，含能力协商、反向请求、窗口流控、错误码、双端接口附录） |
| P1 PC 宿主 | **完成：真实启动，Node 端到端 23/23** | `apps/remote-host/`：`index.ts`/`server.ts`/`identity.ts`/`tls.ts`/`devices.ts`/`pairing.ts`/`native-desktop.ts`/`pairing-qr.ts`/`discovery.ts`/`cordis.patch.yml`/`scripts/e2e-remote-host.ts`；`dsh --profile remote-host` 出厂 profile |
| P2 App 传输 | 完成，本地零回归 | `lib/runtime_transport.dart`、`lib/remote_transport.dart`（wss + TLS 固定 + 握手 + 退避重连、`a-<uuid v4>` 请求 id）、`runtime.dart` 接缝、`api_streams.dart` 与 `streams.mjs` 窗口化确认（远程会话数据源按握手能力开启） |
| P4a 共享组件与入口 | 完成 | `lib/remote_dsh_widgets.dart`；侧栏「远程 DSH」入口（`chat_sidebar.dart`），目的地不叠层 |
| P4b 远程页面 | 完成：真实设备/项目/会话 + 真实会话页（窗口/发送/流式/自动连接/审批/模型选择/本次变更/归档/终端）+ 首页搜索/新建/归档/电脑文件/设置 | `lib/remote_dsh_page.dart`、`remote_dsh_archived_page.dart`、`remote_dsh_conversation.dart`、`remote_workspace_diff_page.dart`、`remote_workspace_files_page.dart`、`remote_dsh_settings_page.dart`、`remote_terminal_page.dart`、`remote_conversation_live_source.dart`、`remote_dsh_live_source.dart` |
| P3 配对与设备 | **完成：配对闭环打通（真机验证）** | 宿主 `/ca.cer` `/pair` + App `remote_pairing*.dart`；设备表/单次令牌/撤销/窗口重开在冒烟与端到端里覆盖 |
| P5 能力补齐 | **全部完成**：远程审批、会话模型选择、搜索、新建会话、已归档查看/恢复、电脑文件浏览、远程设置、workspace 本次变更、会话页归档、能力三态、模型路由自动兜底、**远程终端**、**附件上行（App/宿主/e2e/真机旁路验收）**、**输入区 `+`/方案模式**、**模型路由前置提示**、**B3 审批预设（真机切换通过）**、首页输入条文案 + goal 行置灰 | 见手册 §3.2.2–§3.2.8 与 §3.3 `p5-*`/`p5b-*`/`p5c-*` 真机截图；[p5-remaining-design.md](remote-dsh/p5-remaining-design.md) |
| P6 可达性 | **第三批完成**：可达性文档、终端二维码、扫码配对（真机解码 PASS）、局域网发现（宿主 UDP 4778 + App 搜索；PC 探测 PASS）、USB/adb reverse（真机连接 PASS）、手动地址覆盖、多台电脑管理与切换（真机 PASS）、后台通知步骤 (1)+(2)（宿主 §8.2/8.3/8.5 发送 + App 系统通知 + 点击深链，真机验证）、PC 配对设置页（回环 HTTP + 二维码 + 设备管理，浏览器验收）、App 拨号超时 12s、wss 443 修复；待做：真机拍照扫码、无隔离网络发现直连、approvalPending 真机链路、步骤 (3) 前台服务持 WS、PC 分发决策 | [reachability.md](remote-dsh/reachability.md)、[discovery.md](remote-dsh/discovery.md)、[pairing-qr-design.md](remote-dsh/pairing-qr-design.md)、[pc-pairing-page.md](remote-dsh/pc-pairing-page.md)、[pc-pairing-distribution.md](remote-dsh/pc-pairing-distribution.md)、HANDOFF §3.2.10–§3.2.15 |
| 会话洞察 UI | **完成（真机验证）**：远程会话悬浮任务卡片（可展开 todos）+ 底部统计条（轮/步、tok 与缓存命中%、上下文%，详情弹层），数据来自 `session.projections` 四类投影、事件驱动刷新 | `remote_session_insights.dart`、`remote_todo_card.dart`、`remote_stats_bar.dart`；HANDOFF §3.2.15 |

**M1 结论：成立**——真机连 PC、列真实项目与会话、发消息并看到流式回复（见
[remote-dsh/HANDOFF.md](remote-dsh/HANDOFF.md) §3.3 与 §9 最新记录）。P5 六批与 B3/附件/模型路由
均在真机验收；P6 已支持扫码/局域网发现/USB/手动地址多种连接方式与多台电脑管理。
进度、剩余项与分工以手册为准。

### 12.3 验收证据（本轮）

- `flutter analyze`：11 条 issue，**全部为改动前既有**（`files.dart`、`acceptance_files_test.dart`）；新增文件零告警。
- `flutter test`：**1913 项全部通过**（多种连接方式 + 多设备 + 后台通知新增用例全部在内），本地传输改动零回归。
- `tsc -p apps/remote-host` 与 `tsc -p tsconfig.host.json`：通过（host scripts 已纳入聚合）；`pnpm run build:check` 2/2 gates。
- 宿主冒烟 14/14、宿主真实端到端 **23/23**（send 项含协议 §8.2 严格断言）、发现自检 11/11、
  QR 自检 16/16、通知自检 11/11、协议 transport 22/22。
- 真机「多种连接方式」：扫码解码 PASS、USB/adb reverse 配对+连接 PASS、手动地址覆盖入口可用、
  多设备胶囊/切换失败态/移除/冷启动自动连上次设备 PASS（证据 `.cache/remote-device/p6-conn-*.png`）。
- 真机「后台通知」：退后台收到 `pocket-remote:taskCompleted:*`（channel `task-completed`）、
  前台不弹、退出远程页后通知清空；`approvalPending` 真机链路未触发（selfcheck+单测覆盖）。
- 真机既有证据：M1、P5 各批（`p5-*`/`p5b-*`/`p5c-*`）、B3 权限预设（`p5c-b*`）、C3 模型路由（`p5c-c1/c2`）、
  附件旁路（`p5c-a*`）、③ 首页/goal（`p5c-c01/c2-goal-disabled`）。
- `verify-translation-pairing`：新增文档已排除；仅余 6 条改动前既有的 `packages/*/README.i18n.yaml` 漂移。

### 12.4 下一轮必须完成（已按新发现重排）

> 2026-11-16 03:30 更新：P5 六批与 B3/附件/模型路由真机验收全部完成；P6 第二批完成多种连接方式
> （扫码/发现/USB/手动地址/多台电脑）。剩余逐条见 [remote-dsh/HANDOFF.md](remote-dsh/HANDOFF.md) §4：
> 真机拍照扫码与无隔离网络下的「发现→直连配对」补测、§8 后台通知实现（宿主映射→App 通知→前台服务）、
> PC 配对界面、PC 分发与发布身份、连接拨号超时、60fps 冷却后复测与优化（performance.md）。


**历史记录（已解决）：把门面插件变成可被 PC 引用的 workspace 包。**

这是 M1 的真实拦路虎。`apps/remote-host/cordis.patch.yml` 依赖 `@minnnng/dsh-android-runtime`，但该包只存在于 Android 打包产物里（`.cache/android/runtime-bundle/node_modules/@minnnng/dsh-android-runtime`），monorepo 根目录下 `node_modules/@minnnng` 并不存在。因此远程 profile 在当前仓库结构下**无法启动**。

两条路，建议走第一条：

1. 把 `apps/android/runtime` 提升为 workspace 包（例如 `packages/app/app-runtime`），`apps/android/runtime` 退化为 Android 组合层与原生适配器。这是 §5.3 早就列为"更干净但更贵"的方案，现在证明它是 M1 的前置条件，不是可选项。
2. 临时方案：补丁里改用暂存目录的绝对路径。不可移植、依赖本机布局，只适合一次性的可行性验证。

**改造前必须先处理的两个具体障碍**（已核实，不要低估）：

- 该目录被 26 个 `@deepseek-ai/*` 包直接 import（`dsh-app-boot`、`dsh-credentials`、`dsh-fs`、`dsh-llm`、`dsh-session`、`dsh-tools`、`dsh-tool-fs`、`dsh-web-app`、`cordis`、`schemastery` 等），成为 workspace 包就必须在它自己的 `package.json` 里逐一声明，否则运行时解析（Node 严格 node_modules）不成立。
- 一旦 `pnpm install` 在该目录生成 `node_modules`，`apps/android/tool/stage-runtime-plugin.mjs` 的 `treeWithoutLinks()` 会**直接抛错**（它拒绝符号链接，且 `directory()` 拒绝符号链接目录），Android 的运行时打包随即中断。所以提升为 workspace 包**必须同时**改这个 staging 脚本，跳过 `node_modules`，并重新验证 `pack-runtime.ps1` 与 `verify-apk.ps1`。
- `tool/stage-runtime.ts` 目前会往暂存副本里**写入** `package.json`（name `@minnnng/dsh-android-runtime`、`exports` 只含 `.` 与 `./auto-review.mjs`）；源目录一旦自带 `package.json`，两处定义必须合并成一个来源，否则会静默分歧。

因此这一步的正确顺序是：先改 staging 的链接守卫与清单来源 → 再建包与声明 26 个依赖 → 再跑 `build:artifacts` 与 `pack-runtime` → 最后才回到远程宿主。

**其余（按依赖顺序）**

1. **PC 宿主 dispatch 跑通**：宿主启动 → 门面通过 `appRuntimeFacade` 应答 → 用 Node 客户端跑一次 `runtime.info` + `sessions.list`。
2. **M1 端到端**：手机扫码/粘贴配对 → 连接 → 列出真实项目与会话 → 发一条消息并看到流式回复。
3. **P5**：手机附件上行、能力三态（支持/降级/不可用）在 UI 上可见。
4. **消息推送**：`remote.taskCompleted` / `remote.approvalPending` 接到 Android 通知通道，并解决后台连接存活（前台服务持 WS）。

### 12.7 范围纪律

用户明确要求：**DSH 有的才做，DSH 没有的先不做。** 据此已删除照搬 Codex 的「剩余用量」菜单。后续新增任何控件前先回答：DSH 或本 App 里它的数据源是什么？答不出就不做。

对照检查的结论：

- 「优先级」= 置顶会话优先，DSH 有 `pinSession`，成立。
- 「按项目 / 按时间倒序」= 工作区分组与 `updatedAt` 排序，成立。
- 「已归档任务」= DSH 有归档，成立（尚未接实现，点了会明确提示）。
- 「赞 / 踩」= DSH 有 `messageFeedback`，成立。
- 「剩余用量」= DSH 没有账户额度概念，**已删除**。
- 「云端」设备类型 = DSH 没有云端执行端，**未实现**。

### 12.5 Round 1 收尾记录

**修复的真缺陷**

| 问题 | 现象 | 处置 |
|---|---|---|
| `@peculiar/asn1-schema` 双版本 | `ensureTlsMaterial` 抛 `Cannot get schema for 'BasicConstraints' target`，宿主根本发不出证书 | `pnpm-workspace.yaml` 加 `overrides` 收敛到 `2.11.1`（electron-builder 的 webcrypto 拉 2.9.4，selfsigned 的 x509 拉 2.11.1，两套 schema 注册表） |
| 设备令牌无法读回 | `credentials.describe` 只报存在性，冷启动重连没有令牌可用 | 门面新增 `credentials.read`（`runtime/index.mjs`），Dart 侧 `RuntimeCredentialVault.read` 改用它 |
| 设备列表没有偏好通道 | `dsh/runtime` 只有若干专用偏好方法，无通用读写 | `MainActivity.kt` 新增 `remote.devices.read` / `remote.devices.save`，写入前先 `JSONArray` 解析校验，避免坏数据砖掉设备列表 |

**端到端证据（PC 宿主）**

`pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts` → **7/7 PASS**：

- 缺 `Authorization` 升级 → 401；错误 `Origin` → 403
- 正确令牌 + 正确 Origin → 连上并完成 `protocol.hello`（`protocolVersion=1`，`methods` 3 项）
- 普通请求拿到 result；未注册方法拿到 error
- 宿主主动通知客户端能收到（无 `id` 帧）
- 断开后连接数归零、未处理 rejection 0 条、临时目录与端口均已释放

**已知偏差（记录在案，未修）**

- 未注册方法当前返回 JSON-RPC `-32603`，协议 §9.1 要求 `-32601`。根因是 `JsonRpcLineTransport` 把所有处理器失败统一映射为 `-32603`；要修需要该共享包识别一个类型化错误码，会牵动 SDK 覆盖门禁。v1 接受此偏差，App 侧按 message 前缀识别「方法不存在」。

### 12.6 真机验收（OnePlus6 / Android，adb 在线）

真机暴露了三个静态检查发现不了的问题，均已修复：

| 问题 | 真机现象 | 处置 |
|---|---|---|
| 设备列表读写形状不一致 | 进入页面即报「读取远程电脑失败：本机保存的设备列表不是 JSON 对象」 | Kotlin 侧默认值由 `[]`（数组）改为**不写入即返回 null**，保存校验由 `JSONArray` 改为 `JSONObject`，与 Dart 的 `{version, devices}` 契约对齐 |
| 左上角三横线被做成返回 | 点 ☰ 直接退回聊天页，用户看不到侧栏 | ☰ 恢复为 App 菜单语义：先回到根对话页再打开侧栏（`ui.dart` 新增 `registerAppMenuScaffold` / `openAppMenu`，ChatPage 注册根 Scaffold）；子页（配对页）仍用返回箭头 |
| 「剩余用量」照搬 Codex | DSH 没有这个功能 | 菜单项、枚举值与处理分支全部删除。**原则：DSH 有的才做** |

已通过的真机检查（截图存于 `.cache/remote-device/`）：

- 侧栏「远程 DSH」位于「后台任务」正上方（`00`→`01`）
- 远程首页：头部、设备胶囊「全部」、「还没有连接任何电脑」空态、底部输入条（`02`）
- 标题 ▾ 菜单：优先级 / 按项目✓ / 按时间倒序 / 优先显示「最近」/ 管理｜已归档任务·添加连接·设置（`03`）
- 未实现项给出可见「暂未开放」提示，而非静默（`04`）
- 深色主题适配正确（`06`）
- ☰ 打开的是我们自己的侧栏（`09`）
- 「添加连接」推入配对页：粘贴链接输入、信任警告、空输入禁用「连接」（`12`）

补充修正：配对时上报的设备名原先写死为「Android 手机」，电脑的设备列表会显示一排同名手机。现在 `app.metadata` 增加 `model`（`Build.MANUFACTURER + Build.MODEL`，截断 120 字符），配对页优先用它，读不到才退回固定文案；该字段只用于显示，不参与任何校验。


