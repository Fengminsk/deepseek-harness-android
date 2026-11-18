# 远程 DSH · 协议契约 v1

状态：冻结候选。P1（PC 宿主）、P2（传输与流控）、P3（配对与设备）、P4（远程外壳）一律按本文件实现。
上位文档：[remote-dsh-plan.md](../remote-dsh-plan.md)（只引用结论，不复述路线论证）。
读者：实现 PC 宿主的 Node 侧作者、实现 Dart 传输的作者、写远程页面接线的作者。

---

## 0. 术语与规范力

| 术语 | 含义 |
|---|---|
| App | `apps/android` 的 Flutter 客户端 |
| 宿主 | PC 上加载了 `remote-host` 插件的 DSH 进程 |
| 门面 | `apps/android/runtime/index.mjs` 中 `transport.onRequest` 的方法表 |
| 反向请求 | 宿主发起、App 应答的 JSON-RPC 请求，复用 `native.*` 命名空间 |
| 流 | `api.subscribe` 打开、由服务端连续推送的序列 |
| 连接 | 一条 wss 会话 = 一个 App 实例连一台 PC；v1 一个 App 同时只有一条 |
| 帧 | 一行以 `\n` 结尾的 JSON 文本 |

四条硬规则：

1. 方法名一律不改（§4）。远程不是新 API，是同一套方法表换物理通道。
2. 不引入连接级游标，不引入第二套封装（§7）。
3. 文中出现的字段名就是线上字段名。Dart 与 Node 两侧不得改名，附录 A/B 可直接照抄。
4. 协议层忽略不认识的**帧内字段**（向前兼容）；`params` 的严格校验由各业务方法自己的契约决定，不在本协议范围。

链路总览：

```
Flutter                      Node（宿主）
  RuntimeTransport.request ──┐
                             │  {"jsonrpc":"2.0","id":"a-…","method":"session.send","params":{…}}\n
                             ▼
                    wss://<host>:<port>/app
                             │
  RuntimeTransport.events ◄──┘  {"jsonrpc":"2.0","method":"api.stream","params":{…}}\n
```

---

## 1. 传输

### 1.1 端点

| 项 | 值 |
|---|---|
| URL | `wss://<host>:<port>/app` |
| 路径 | 必须精确等于 `/app`；其它路径回 HTTP 404 |
| 查询串 / 片段 | 不允许；出现即回 HTTP 404 |
| TLS | TLS 1.2 及以上；服务端证书由配对流程固定（见 P3） |
| 子协议 | 不协商 `Sec-WebSocket-Protocol`；出现即忽略 |
| 压缩 | v1 不启用 `permessage-deflate` |
| 明文 `ws://` | 仅 debug 构建可用（待决策项 D4，v1 默认关闭） |

一条连接只有一条帧流。不存在第二条通道、不存在多路复用标签：**帧里没有 channel 字段，方法名自己就是路由**。

### 1.2 帧格式

换行分隔的 JSON-RPC 2.0。UTF-8、单行、以 `\n` 结尾；禁止 `\r\n`，禁止一条帧里出现裸换行（`JSON.stringify` 天然满足）。

三种帧：

| 种类 | 形态 | 说明 |
|---|---|---|
| 请求 | `{"jsonrpc":"2.0","id":…,"method":…,"params":{…}}` | 需要应答 |
| 响应 | `{"jsonrpc":"2.0","id":…,"result":…}` 或 `{"jsonrpc":"2.0","id":…,"error":{"code":…,"message":…,"data":{…}}}` | `result` 与 `error` 互斥且必居其一 |
| 通知 | `{"jsonrpc":"2.0","method":…,"params":{…}}` | 无 `id`，不等应答，不回响应 |

`params` 必须是对象，不接受数组；省略 `params` 等同于 `{}`。

`id` 规则（双向都需要，防止两侧自增撞号）：

| 方向 | 形态 |
|---|---|
| App → 宿主 | `"a-" + uuidv4`，例 `a-3f2b…` |
| 宿主 → App | `"h-" + uuidv4`，例 `h-9c41…` |

响应必须原样回填请求的 `id`（唯一例外：鉴权失败时连接上还没有任何请求帧，此时用 `"id": null`，见 §2.2）。收到不匹配任何在途请求的响应帧：**丢弃并记录，不关闭连接**（反向请求超时后迟到响应属正常现象）。

示例（一次真实往返）：

```jsonc
→ {"jsonrpc":"2.0","id":"a-1","method":"session.send","params":{"sessionId":"s-1","text":"hi"}}
← {"jsonrpc":"2.0","id":"a-1","result":{"accepted":true}}
← {"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s-1","event":{…}}}
```

### 1.3 帧上限

| 项 | 值 | 越界行为 |
|---|---|---|
| 下行单帧（宿主 → App） | 16 MiB（16777216 字节，对齐 `appStreamMaxFrameBytes` 默认值） | 服务端不得发送；该流以流内 `error`（`app-stream/limit`）终止 |
| 上行单帧（App → 宿主） | 1 MiB（1048576 字节） | 不解析，回 `-32700`，关闭 `1009` |
| 单连接并发流数 | 32 | `api.subscribe` 回 `-32603`，`data.code = "gateway/unavailable"` |
| 单连接请求速率 | 100 次/秒，突发 300 | 回 `-32003 rate-limited`（不关闭）；连续 3 秒超限关闭 `4003` |

字节数一律按 `Buffer.byteLength(JSON.stringify(frame), 'utf8')` 计（与本地实现一致，含 `jsonrpc` 等全部字段）。

### 1.4 关闭码

| 关闭码 | 含义 | App 的处理 |
|---|---|---|
| `1000` | 正常关闭（宿主下线 / App 主动关） | 不自动重连 |
| `1001` | 宿主进程退出 | 可重连，指数退避 1 s → 30 s，抖动 ±20% |
| `1002` | 协议错误（收到不可解析或非对象帧） | 可重连，计一次失败 |
| `1009` | 上行帧超限 | 不自动重连，提示「请求过大」 |
| `4000` | 认证失败（`auth-failed`） | 终止态：不重连，提示重新配对 |
| `4001` | 设备已撤销（`auth-revoked`） | 终止态：不重连，提示已撤销 |
| `4002` | 协议版本不匹配（`protocol-mismatch`） | 终止态：不重连，提示升级 |
| `4003` | 限速关闭（`rate-limited`） | 可重连，退避 ≥ 30 s |

收到表外关闭码一律按 `1001` 处理。

### 1.5 保活

App 侧 `WebSocket.pingInterval = 20 s`；宿主 60 s 内既未收到上行帧也未收到 pong 即关闭 `1001`。不发应用层心跳方法。

---

## 2. 鉴权

### 2.1 升级请求头

WS 升级请求必须恰好携带：

```
GET /app HTTP/1.1
Host: <host>:<port>
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <标准>
Sec-WebSocket-Version: 13
Authorization: Bearer <deviceToken>
Origin: https://pocket-harness.local
```

| 头 | 规则 |
|---|---|
| `Authorization` | `Bearer ` + `deviceToken`；`deviceToken` 为 43 字符 base64url（32 字节随机），无空格、无换行。大小写敏感的 `Bearer` 前缀 |
| `Origin` | 必须精确等于 `https://pocket-harness.local`，逐字节比较，不做规范化 |

### 2.2 校验顺序与失败表现

| 步 | 校验 | 失败时的表现 |
|---|---|---|
| 1 | 路径 `/app`、无查询串 | 升级前 HTTP 404 |
| 2 | `Origin` 精确匹配 | 升级前 HTTP 403 |
| 3 | `Authorization` 存在且形如 `Bearer <43 字符 base64url>` | 升级前 HTTP 401，不回显收到的值 |
| 4 | token 摘要（SHA-256）与 `devices.json` 中记录用 `timingSafeEqual` 比对 | **接受升级**，随后回 `-32001 auth-failed` 并关闭 `4000` |
| 5 | 设备未撤销 | **接受升级**，随后回 `-32002 auth-revoked` 并关闭 `4001` |

第 4、5 步放在升级之后，是为了让 App 拿到可展示的结构化原因：`dart:io` 的 `WebSocket.connect` 失败时只抛 `WebSocketException`，拿不到状态码，更拿不到响应体。补救措施：未通过鉴权的连接不分配 `deviceId`、不进入握手、5 秒内无条件关闭；同一源地址 5 秒内最多 5 次尝试，超出回 HTTP 429。

第 4、5 步失败时，连接上还没有任何请求帧，无从得知 `id`。错误帧因此使用 `"id": null`（JSON-RPC 2.0 允许在无法确定 id 时用 `null`）：

```jsonc
← {"jsonrpc":"2.0","id":null,"error":{
     "code":-32001,
     "message":"连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。",
     "data":{"code":"auth-failed"}}}
```

App 必须把 `id: null` 的错误帧当作**连接级错误**：不结算任何在途请求，直接进入终止态并展示 `message`。

`devices.json` 只存摘要（SHA-256），绝不落盘明文 token；设备撤销的顺序固定为「先落盘删除 → 再终止该设备全部连接 → 最后推 `remote.deviceRevoked`」。

### 2.3 为什么不用 cookie / CSRF

CSRF 保护的是「浏览器自动携带的环境凭证」：cookie 由浏览器按域自动附加，页面无法控制是否发送，所以需要 token 或 SameSite 来区分来源。本协议里这个前提不成立：

1. 客户端是 Flutter 原生 WS，没有 cookie jar，没有浏览器自动凭附加机制。
2. 凭证由 App 代码显式写进 `Authorization` 请求头，是按请求维度精确控制的。
3. 服务端不设 `Set-Cookie`，不读 `Cookie`，因此不存在「跨站请求自动带上凭证」这一攻击面。

固定 `Origin: https://pocket-harness.local` 不是 CSRF 防护，是**纵深防御**：

- 该源不可路由，也不是任何真实站点的源；原生客户端可以照抄这个常量。
- 浏览器无法伪造 `Origin`（它由浏览器按真实页面源填写，脚本改不了）。所以任何从本机恶意网页发起的 WS 连接都会因为 `Origin` 不匹配被 403 拒绝——挡掉「恶意页面连本机监听端口」这一类本地攻击。
- 代价为零：原生客户端本来就没有真实 Origin。

---

## 3. 握手

### 3.1 请求（必须是连接上的第一帧）

```jsonc
→ {"jsonrpc":"2.0","id":"a-hello","method":"protocol.hello","params":{
     "protocolVersion":1,
     "appVersion":"0.1.0+121",
     "deviceLabel":"Pixel 8",
     "capabilities":["window-ack"]}}
```

| 字段 | 类型 | 必填 | 约束与用途 |
|---|---|---|---|
| `protocolVersion` | integer | 是 | 本文件定义的版本，v1 恒为 `1` |
| `appVersion` | string | 是 | App 构建号（如 `0.1.0+121`），仅供宿主展示与排障 |
| `deviceLabel` | string | 是 | 设备显示名，1–120 字符；宿主记入设备表 |
| `capabilities` | string[] | 是 | 客户端能力；v1 只定义 `"window-ack"`（见 §6）。未知项宿主忽略 |

### 3.2 响应

```jsonc
← {"jsonrpc":"2.0","id":"a-hello","result":{
     "protocolVersion":1,
     "host":{"name":"Colin 的台式机","platform":"win32","home":"C:\\Users\\colin\\DSH"},
     "methods":["runtime.info","session.send","terminal.*","…"],
     "unsupported":["documents.*","linuxVm.*","scheduleWake.*"],
     "capabilities":["window-ack"]}}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `protocolVersion` | integer | 宿主支持的版本，v1 恒为 `1` |
| `host.name` | string | 宿主显示名，≤ 120 字符 |
| `host.platform` | string | `process.platform`：`win32` / `darwin` / `linux` |
| `host.home` | string | DSH 主目录绝对路径，**仅用于展示与排障**，不得用于拼接 App 侧路径 |
| `methods` | string[] | 宿主可应答的方法清单，语法见 §10 |
| `unsupported` | string[] | 宿主明确不支持的方法，语法见 §10；优先级高于 `methods` |
| `capabilities` | string[] | 宿主能力；v1 只定义 `"window-ack"` |

### 3.3 版本协商

| 情形 | 服务端行为 |
|---|---|
| `protocolVersion == 1` | 回上述 `result`，连接进入 `ready` |
| `protocolVersion` 缺失、非整数、或 `!= 1` | 回 `error`，然后关闭 `4002` |

版本不匹配的错误帧：

```jsonc
← {"jsonrpc":"2.0","id":"a-hello","error":{
     "code":-32000,
     "message":"协议版本不匹配：宿主为 v1，App 为 v3。请把两端升级到同一版本。",
     "data":{"code":"protocol-mismatch","hostVersion":1,"appVersion":3,
             "detail":"version-mismatch"}}}
```

**关闭前不再处理任何其它方法。** 具体规则：

1. 一旦判定版本不匹配，宿主只发送上面这一条错误帧，然后关闭 `4002`。
2. 关闭前已经在缓冲里的任何其它请求帧一律丢弃，不回响应、不执行、不着陆任何副作用。
3. App 收到 `-32000 / protocol-mismatch` 后立即停止发送，不再排队新请求。

握手前与握手中的其它约束：

| 情形 | 服务端行为 |
|---|---|
| 连接建立后 10 s 内未收到合法 `protocol.hello` | 关闭 `4002`，`reason = "handshake-timeout"` |
| 首帧是 `protocol.hello` 之外的任何请求 | 回 `-32000`，`data.code = "protocol-mismatch"`，`data.detail = "handshake-required"`，关闭 `4002` |
| 同一条连接上第二次 `protocol.hello` | 回 `-32000`，`data.detail = "duplicate-hello"`，关闭 `4002` |
| 握手前收到通知帧 | 丢弃，不关闭 |

### 3.4 握手之后仍走既有阶段协议

握手成功不等于可用的 App。宿主随后照旧推 `runtime.status` / `runtime.ready`，App 的阶段机（`connecting → handshaking → ready → reconnecting → lost`）与「代际作废迟到结果」的既有逻辑**原样保留**，本协议不改它们。

- `ready` 的判据仍是 `runtime.status.params.phase == "ready"`。
- App 在 `runtime.status.phase != "ready"` 期间不得调用业务方法（与本地模式一致）。
- 重连一次即 `connectionGeneration` 递增一次，旧代的响应与流一律作废。

---

## 4. 方法表

### 4.1 通用规则

- 方法名**一字不改**，与 `apps/android/runtime/index.mjs` 的 `transport.onRequest` 分发完全一致，包含 6 组前缀分支（`workspaceChanges.`、`references.`、`library.`、`workspace.files.`、`document.`、`terminal.`）。
- 本协议只新增一个方法：`protocol.hello`（§3）。
- 不认识的方法：回 `-32601`，`data.code = "unsupported-method"`（§9.1）。**不得回 `-32603`，不得静默丢弃。**
- 业务错误（`gateway/…`）走**成功的 `result`** 里的 `_pocket_error` 对象，沿用本地约定，不改封装：

```jsonc
← {"jsonrpc":"2.0","id":"a-2","result":{"_pocket_error":{
     "code":"gateway/bad-request","message":"params must be an object","details":{}}}}
```

- 协议级错误（认证、版本、限速、方法不存在、帧非法）走 JSON-RPC `error` 对象（§9.1）。
- App 的 `RuntimeTransport` 把这两种统一抛成 `PlatformException(code, message, details)`：`code` 取 `_pocket_error.code` 或 `error.data.code`，`message` 取对应 `message`，`details` 取整个错误对象。既有页面代码不需要知道错误是从哪一层来的。

### 4.2 方法清单

| 命名空间 | 方法（完整名单） | 远程归属 | 备注 |
|---|---|---|---|
| `runtime.` | `info`、`permissions`、`live`、`transition.reserve`、`transition.commit`、`transition.release` | 随宿主，按宿主平台应答 | `permissions` 的 `shell` / `fileTools` 反映**宿主**平台；App 侧对远程连接的严格校验分支由 P2 处理（R3），本协议不新增方法 |
| `session.` | `send`、`ensure`、`selectPreset`、`command`、`cancel`、`readWindow`、`read`、`read.release`、`turnOutline`、`export.prepare`、`export.cancel`、`export.release`、`attachmentFile.prepare`、`attachmentFile.info`、`attachmentFile.read`、`attachmentFile.cancel`、`attachmentFile.release` | 随宿主 | 会话读写的全部入口 |
| `api.` | `call`、`subscribe`、`ack`、`unsubscribe` | 随宿主；`subscribe`/`ack`/`unsubscribe` 语义见 §6 | `api.call` 仍是 typertGateway 的一元透传 |
| `workspace.files.` | `info`、`list`、`read`、`search` | 随宿主 | 读 PC 工作区文件 |
| `document.` | `mediaPolicy`、`call`、`bytes`、`cancel`、`release` | 随宿主；渲染端在设备侧 | Office/PDF 预览的字节源在 PC |
| `terminal.` | `list`、`shells`、`create`、`read`、`write`、`resize`、`rename`、`close` | 随宿主 | 远程 profile 启用真实 `terminal-controller` |
| `tasks.` | `summary`、`list`、`session`、`cancel`、`killUnownedJob`、`removeQueued`、`editQueued`、`steerQueued` | 随宿主 | |
| `interactions.` | `list`、`reply`、`dismiss`、`wait` | 随宿主 | 审批与提问 |
| `settings.` | `describe`、`mutate` | 随宿主 | |
| `library.` | `catalog`、`directoryList`、`directoryCreate`、`workspaceCreate`、`workspaceRename`、`workspaceReorder`、`sessionCreate`、`sessionRename`、`sessionPin`、`sessionArchive`、`sessionReorder`、`sessionFork` | 随宿主 | 侧栏/项目/会话列表的写入口 |
| `attachments.` | `prepare`、`preview`、`release` | 一半随宿主、一半在设备 | v1 只走既有分片读，不做二进制分块上传（§11） |
| `subagents.` | `catalog`、`inspect`、`page`、`send`、`interrupt` | 随宿主 | |
| `workspaceChanges.` | `summary`、`diff`、`cancel` | 随宿主 | |
| `references.` | `list` | 随宿主 | `@` 引用查询 |
| （无前缀） | `sessions.list`、`account.signIn`、`credentials.describe`、`credentials.set`、`credentials.unset`、`configuration.transfer.export`、`configuration.transfer.preview`、`configuration.transfer.apply`、`configuration.transfer.release`、`chat.image.preview`、`documents.roots`、`documents.list`、`documents.read`、`documents.read.cancel`、`documents.revoke`、`documents.search`、`documents.search.cancel`、`web.status`、`web.configure`、`web.rotate`、`workflow.inspect`、`userText.mask` | 见备注 | 凭据在远程必须由 PC 侧保管；`web.*` 远程无意义（建议列入 `unsupported`）；`documents.*` 在 v1 由宿主列入 `unsupported`（§11） |
| （协议） | `protocol.hello` | 宿主 | 本协议新增，握手专用（§3） |

未在表中的方法名，即使在源码里出现过，也按 `-32601` 处理。

---

## 5. 反向请求（宿主 → App）

### 5.1 为什么需要

门面不是只被动应答。`session.send` 之类的调用会在 PC 侧触发 `transport.request('native.…')`。这些反向请求必须能到达正确的一方：

- **PC 能本地满足的**，由宿主进程拦截应答，**不上线**；
- **只有手机能回答的**（语义是「手机上的文件」），以请求帧转发给 App；
- **V1 谁都无法满足的**，由收到请求的一方明确回 `-32601`。

### 5.2 拦截与转发表

| `native.*` 方法 | 由谁应答 | 说明 |
|---|---|---|
| `native.storage.root` | 宿主拦截 | `resolveDshHome()` |
| `native.attachments.directory` | 宿主拦截 | `<DSH_HOME>/app-attachments` |
| `native.exports.directory` | 宿主拦截 | `<DSH_HOME>/exports` |
| `native.attachmentFiles.directory` | 宿主拦截 | 同附件目录 |
| `native.credentials.get` / `.set` / `.remove` / `.names` | 宿主拦截 | 转发 `ctx.credentials`，密钥不离开 PC |
| `native.web.preferences`、`native.web.save`、`native.network.addresses` | 宿主拦截 | 桌面实现自答 |
| `native.scheduleWakeup.begin`、`native.scheduleWakeup.update` | 宿主拦截 | 桌面无 Android 唤醒约束，直接确认 |
| `native.networkChanged`、`native.appDisconnected` | 不发送 | Android 专属通知，远程模式不发 |
| `native.documents.roots`、`.list`、`.read.prepare`、`.read.run`、`.read.cancel`、`.image.read`、`.image.cancel`、`.search.prepare`、`.search.run`、`.search.cancel`、`.revoke` | **转发给 App** | v1 手机侧统一回 `-32601`；P5 实现后改为正常应答 |
| `native.attachments.read` | **转发给 App** | 分页读取手机附件草稿的私有副本；v1 旧 App 回 `-32601` 时宿主以 `attachment-file/unsupported` 失败 |
| `native.toolCallback` / `.cancel`、`native.workflowCallback` / `.cancel` | 宿主本地标记不支持 | 桌面 PTC 走进程内，不回手机 |
| `native.linuxCommand.*`、`native.linuxVm.*`、`native.isolated.*`、`native.workflow.*` | 宿主本地标记不支持 | 桌面无对应实现 |

### 5.3 不支持时的应答（强制）

App 收到自己不认识的 `native.*` 请求，必须回：

```jsonc
← {"jsonrpc":"2.0","id":"h-7f2","error":{
     "code":-32601,
     "message":"当前设备不支持 native.documents.roots。",
     "data":{"code":"unsupported-method","method":"native.documents.roots"}}}
```

**不得静默丢弃。** 静默丢弃会让 PC 侧的 `packageOperations.runWork` 永久悬挂，比报错严重得多。

宿主侧同理：拦截表里没有、也不转发的方法，回同一条 `-32601`。

### 5.4 超时与断开

| 情形 | 行为 |
|---|---|
| 发起方 90 s 未收到响应 | 本地以 `gateway/timeout` 失败；迟到的响应帧按未知 `id` 丢弃 |
| 连接关闭 | 双向所有在途请求以 `gateway/cancelled` 失败；宿主关闭该连接的全部流（等价 `closeOwner`） |
| App 收到反向请求但自己正在关闭 | 回 `-32603`，`message` 为 `「设备正在断开连接。」` |

反向请求受 §1.3 的帧上限约束，但不占 §6 的流窗口。

---

## 6. 流控

### 6.1 三个方法的线上参数

```jsonc
→ {"jsonrpc":"2.0","id":"a-3","method":"api.subscribe","params":{
     "streamId":"stream-17f0-1",
     "namespace":"session","method":"follow","args":{…}}}
← {"jsonrpc":"2.0","id":"a-3","result":{"streamId":"stream-17f0-1","generation":"<uuidv4>"}}

→ {"jsonrpc":"2.0","id":"a-4","method":"api.ack","params":{"streamId":"stream-17f0-1","upTo":37}}
← {"jsonrpc":"2.0","id":"a-4","result":{"accepted":true,"upTo":37}}

→ {"jsonrpc":"2.0","id":"a-5","method":"api.unsubscribe","params":{"streamId":"stream-17f0-1"}}
← {"jsonrpc":"2.0","id":"a-5","result":{"closed":true}}
```

| 参数 | 类型 | 约束 |
|---|---|---|
| `streamId` | string | 客户端生成，`[A-Za-z0-9_-]{1,64}`，连接内唯一；**每次订阅尝试必须新生成，不得复用** |
| `namespace` | string | typertGateway 命名空间 |
| `method` | string | typertGateway 方法 |
| `args` | object | 可为空 |
| `upTo` | integer | 从 1 开始、单调递增的累计确认序号 |

`generation` 由服务端每次订阅生成（`uuidv4`）。`streamId` 已存在时 `api.subscribe` 回 `-32602`，`data.code = "gateway/bad-request"`。

流帧：

```jsonc
← {"jsonrpc":"2.0","method":"api.stream","params":{
     "streamId":"stream-17f0-1","generation":"<uuidv4>","sequence":37,
     "type":"item","value":{…}}}
```

| `type` | 附带字段 | 语义 |
|---|---|---|
| `item` | `value` | 一条增量（或重建时的快照帧，见 §7） |
| `end` | 无 | 流正常结束，`streamId` 即刻失效 |
| `error` | `error: {code, message, details?}` | 流异常终止，`streamId` 即刻失效 |

### 6.2 窗口语义

设 `W = 64`、`B = 1048576`（1 MiB）。

服务端每维护两个量：

- `sentUpTo`：已推送的最大 `sequence`；
- `ackedUpTo`：已确认的最大 `upTo`（初值 0）。

不变量：**未确认窗口 = 序号落在 `(ackedUpTo, sentUpTo]` 的那批帧，其条数 ≤ W 且字节数 ≤ B。** 只有把下一帧计入后仍满足两条约束时才允许推送，否则挂起生产者，直到 `api.ack` 推进窗口。

- 字节数按 §1.3 的口径算整帧。
- `end` 与 `error` 帧不计入窗口（终止帧总是立即推送），但它们仍占用一个 `sequence`。
- 单帧自身超过 `B` 或超过 16 MiB：不推送，改推 `error`，`code = "app-stream/limit"`，然后终止该流。

客户端回执节奏（Dart 侧实现要求）：累计收到 `min(W, 32) = 32` 条，或距上次回执 ≥ 200 ms，或收到 `end`/`error` 前最后一帧时，发一次 `api.ack`。回执只报最新的连续序号，无需逐条报。

服务端接受 `api.ack` 的判定：

| `upTo` 取值 | 服务端行为 |
|---|---|
| `== ackedUpTo` | 幂等空操作，回 `{"accepted":true,"upTo":ackedUpTo}` |
| `> ackedUpTo` 且 `<= sentUpTo` | 推进窗口，回 `{"accepted":true,"upTo":upTo}` |
| `< ackedUpTo`（回退） | **协议错误**：回 `-32602`，`data.code = "app-stream/ack-violation"`，并按 §6.3 终止该流 |
| `> sentUpTo`（跳跃） | **协议错误**：同上 |
| `streamId` 不存在 | 回 `{"accepted":false,"upTo":0}`，不终止任何东西（订阅可能已 end） |

### 6.3 终止一条流

协议错误（`ack-violation`）与超时（`ack-timeout`，60 s 内无任何回执）都只终止**该流**，不关闭连接：

```jsonc
← {"jsonrpc":"2.0","method":"api.stream","params":{
     "streamId":"stream-17f0-1","generation":"<uuidv4>","sequence":38,
     "type":"error","error":{"code":"app-stream/ack-violation",
       "message":"流确认序号回退，已终止该流。"}}}
```

终止即 `abort` 上游生产者、从订阅表删除 `streamId`。App 收到 `type:"error"` 后按既有 `api_streams.dart` 行为以 `PlatformException` 失败并关闭本地观察。

### 6.4 逐条退化（兼容）

| 连接情形 | 生效模式 |
|---|---|
| `protocol.hello.params.capabilities` 含 `"window-ack"` **且** `protocol.hello.result.capabilities` 也含 `"window-ack"` | 窗口模式：`W = 64`、`B = 1 MiB` |
| 任一侧未声明 `window-ack` | 逐条模式：`W = 1`、`B` 不设限 |

**逐条模式就是「服务端从不越过未确认帧」：推一条、等一条 `api.ack`、再推下一条。** 这正是本地现有实现的语义，所以：

- 老客户端（每帧 ack、不声明能力）零改动继续工作；
- 新客户端声明 `window-ack` 后立刻拿到窗口吞吐；
- 逐条模式下 `upTo` 语义不变（累计确认），只是窗口深度退化为 1。

本地 loopback 与远程连接使用**同一套常量与同一套判定**，不为本地另开一条代码路径。本地实现的 `owner` 维度在远程连接上恒为单一 owner，不为它引入额外字段。

### 6.5 流命名简写

下文与 P2/P4 的讨论用 `namespace.method` 的简写指代一次订阅，等价关系固定如下：

| 简写 | 完整调用 |
|---|---|
| `session.follow` | `api.subscribe {namespace:"session", method:"follow"}` |
| `session.control` | `api.subscribe {namespace:"session", method:"control"}` |
| `workspace.follow` | `api.subscribe {namespace:"workspace", method:"follow"}` |

简写只用于文档与代码里的常量名，**永远不上线**：`api.subscribe` 的 `namespace` 与 `method` 始终是两个独立字段。

这三条流的 `namespace` / `method` 由宿主侧网关的注册决定。上表给出远程模式要求的配对；P1 落地前必须用宿主实际注册的配对核对一次，若不一致，改这一张表，不改代码里的其他任何地方。

### 6.6 与订阅生命周期的关系

- `api.unsubscribe` 立即 abort 生产者，并回 `{"closed":true}`；对不存在的 `streamId` 同样回 `{"closed":true}`（幂等）。
- 连接关闭 → 该连接全部流终止，无需逐一 `api.unsubscribe`。
- 一个 `streamId` 终止后不可复活；重新订阅必须用新 `streamId`（`generation` 也会不同）。

---

## 7. 重连与断点

### 7.1 连接级无游标

本协议**没有**连接级续传：不存在 `resumeToken`、`lastSeq`、`cursor` 之类的字段。任何方法都不接受这类参数；服务端收到必须忽略。

理由与约束：

- 断线期间的所有通知都**不重放**，一条不补。
- 状态正确性由「重连后重新握手 + 各流自身的 opening 快照」保证，而不是由日志回放保证。
- 因此实现上不允许出现「靠补帧修复状态」的代码；状态只能来自一次显式读或一次快照帧。

### 7.2 重连步骤（App 侧顺序固定）

1. 关闭旧连接，作废旧 `connectionGeneration`，把所有在途请求以 `gateway/cancelled` 失败，清空所有 `streamId`。
2. 重新建立 WS，重发 `protocol.hello`（同一份 `appVersion` / `deviceLabel` / `capabilities`）。
3. 收 `protocol.hello.result`：版本不符即终止（§3.3）；`methods` / `unsupported` 可能已变化，按 §10 重新计算入口可见性。
4. 等宿主推 `runtime.status`，`phase == "ready"` 后才继续；随后按既有 `refresh()` 流程重读 `runtime.info`、`live`、`interactions`、`web`、`sessions`、`forms`、`tasks`。
5. 对每条需要在屏的流重新 `api.subscribe`（新 `streamId`）：服务端从该流当前状态重新生成 opening 快照，`sequence` 从 1 重新计数，`generation` 是新的 uuid。
6. 打开中的会话按既有 `session.readWindow` 从窗口 `throughSeq` 重读，补齐断线期间丢失的 `session.event`。

宿主侧对应义务：新连接一律当作全新的、无记忆的客户端；不得假设对方还持有上一代的任何状态。

### 7.3 哪些能重建、哪些只是通知

| 流 / 通知 | 类别 | 重连后如何恢复 |
|---|---|---|
| `session.follow`（`api.subscribe(namespace:"session", method:"follow")`） | **快照 + 增量** | 重新订阅；第一帧 `item` 即该会话当前完整投影（快照），其后是增量。App 先整体替换、再追加 |
| `session.control`（`api.subscribe(namespace:"session", method:"control")`） | **快照 + 增量** | 重新订阅；第一帧 `item` 即当前控制态（运行中/排队/待审批），其后是状态迁移 |
| `workspace.follow`（`api.subscribe(namespace:"workspace", method:"follow")`） | **快照 + 增量** | 重新订阅；第一帧 `item` 即工作区与变更摘要基线，其后是增量 |
| 其它经 `api.subscribe` 打开的流 | 由该流自身契约决定 | 本协议不承诺快照语义；若首帧不是自洽快照，调用方必须重新走一次等价的一元读 |
| `session.event` | **纯通知，不重放** | 不补发。用 `session.readWindow` 重读历史窗口补齐；`session/title` 类的旁路事实由 `sessions.list` 重读 |
| `session.status` / `session.error` / `session.live` | 纯通知，不重放 | 用 `runtime.live` 与 `session.readWindow` 重建；`revision` 回退的帧丢弃 |
| `sessions.changed` | 纯通知（触发器） | 重连后直接 `sessions.list` / `library.catalog` 重读，不等通知 |
| `settings.changed` | 纯通知（触发器） | `settings.describe` 重读 |
| `interactions.changed` | 纯通知（触发器） | `interactions.list` 重读 |
| `runtime.tasks.changed` | 纯通知（触发器） | `tasks.summary` + `tasks.list` 重读 |
| `web.changed` | 纯通知（触发器） | `web.status` 重读 |
| `task.completed` / `notifications.error` | 纯通知，不重放 | 只在本地模式产生系统通知；远程用 `remote.taskCompleted`（§8） |
| `api.event` | 纯通知，不重放 | 无重建义务，缺失即缺失 |

一句话：**触发器型通知丢了无所谓（重新读一次即可），内容型通知丢了就真丢了（`session.event` 靠读窗口补，`api.event` 直接放弃）。**

---

## 8. 远程推送通知

### 8.1 通则

| 项 | 规则 |
|---|---|
| 方向 | 仅宿主 → App |
| 形态 | 通知帧（无 `id`），App 不回响应；收到带 `id` 的 `remote.*` 一律丢弃 |
| 发送条件 | 仅在**已进入 `ready`** 的连接上发送 |
| 与既有通知的关系 | `remote.*` 与 `task.completed` 等既有通知是两条线：既有通知服务于页面投影，`remote.*` 服务于系统通知与设备级提示。**App 只对 `remote.*` 触发系统通知**，避免重复打扰 |
| 截断 | 字符串超限一律截断并置 `truncated: true`；**绝不允许发送超过上限的帧** |
| 未知字段 | 忽略 |

### 8.2 `remote.taskCompleted`

帧上限 8 KiB。

| 字段 | 类型 | 必填 | 说明 | 上限 |
|---|---|---|---|---|
| `taskId` | string | 是 | 任务 id | 128 字符 |
| `sessionId` | string | 是 | 所属会话 | 128 字符 |
| `workspaceId` | string | 否 | 所属项目 | 128 字符 |
| `title` | string | 是 | 任务标题 | 200 字符 |
| `status` | string | 是 | `completed` / `failed` / `cancelled` | 枚举 |
| `turn` | integer | 否 | 结束的轮次序号 | ≥ 0 |
| `completedAt` | integer | 是 | Unix 毫秒 | — |
| `summary` | string | 否 | 结果摘要，单段纯文本 | 512 字符 |
| `truncated` | boolean | 否 | 是否有字段被截断，默认 `false` | — |

### 8.3 `remote.approvalPending`

帧上限 16 KiB。

| 字段 | 类型 | 必填 | 说明 | 上限 |
|---|---|---|---|---|
| `interactionId` | string | 是 | 交互 id（与 `interactions.*` 同一标识） | 128 字符 |
| `sessionId` | string | 是 | 所属会话 | 128 字符 |
| `kind` | string | 是 | `approval` / `question` / `plan` | 枚举 |
| `title` | string | 是 | 标题（如工具名或问句首行） | 200 字符 |
| `summary` | string | 否 | 一行摘要，纯文本，不含代码块 | 1024 字符 |
| `toolName` | string | 否 | 触发审批的工具名 | 128 字符 |
| `createdAt` | integer | 是 | Unix 毫秒 | — |
| `truncated` | boolean | 否 | 是否有字段被截断 | — |

### 8.4 `remote.deviceRevoked`

帧上限 1 KiB。

| 字段 | 类型 | 必填 | 说明 | 上限 |
|---|---|---|---|---|
| `deviceId` | string | 是 | 被撤销的设备 id | 128 字符 |
| `deviceLabel` | string | 否 | 设备显示名 | 120 字符 |
| `reason` | string | 是 | `user-revoked` / `expired` | 枚举 |
| `revokedAt` | integer | 是 | Unix 毫秒 | — |

语义顺序固定：宿主**先**落盘删除设备记录，**再**关闭该设备全部连接，**最后**推这条通知。App 收到后立即把该 PC 置为「已撤销、需重新配对」，并忽略随后到达的连接关闭原因。

### 8.5 `remote.sessionChanged`

帧上限 4 KiB。

| 字段 | 类型 | 必填 | 说明 | 上限 |
|---|---|---|---|---|
| `sessionId` | string | 是 | 会话 id | 128 字符 |
| `workspaceId` | string | 否 | 所属项目 | 128 字符 |
| `revision` | integer | 是 | 同一 `sessionId` 内单调递增 | ≥ 0 |
| `title` | string | 否 | 会话标题 | 200 字符 |
| `archived` | boolean | 否 | 是否归档 | — |
| `removed` | boolean | 否 | 会话已被删除 | — |
| `updatedAt` | integer | 是 | Unix 毫秒 | — |

顺序：同一 `sessionId` 的 `remote.sessionChanged` 由宿主按 `revision` 单调发送；App 丢弃 `revision` 回退的帧。跨 `sessionId` 无顺序保证。

---

## 9. 错误码

### 9.1 协议层（JSON-RPC `error`）

| 场景 | `error.code` | `error.data.code` | 是否关闭连接 |
|---|---|---|---|
| 帧不是合法 JSON | `-32700` | `gateway/bad-request` | 是，`1002` |
| 帧不是对象 / `jsonrpc != "2.0"` / 缺 `method` | `-32600` | `gateway/bad-request` | 是，`1002` |
| 方法不存在 | `-32601` | `unsupported-method` | 否 |
| 参数非法（协议层可判定，如 `streamId` 格式、`upTo` 类型） | `-32602` | `gateway/bad-request` | 否 |
| 流确认违规 | `-32602` | `app-stream/ack-violation` | 否（终止该流，§6.3） |
| 未捕获的内部错误 | `-32603` | `gateway/internal` | 否 |
| 协议版本不匹配 / 未握手 / 重复握手 | `-32000` | `protocol-mismatch` | 是，`4002` |
| 认证失败 | `-32001` | `auth-failed` | 是，`4000` |
| 设备已撤销 | `-32002` | `auth-revoked` | 是，`4001` |
| 限速 | `-32003` | `rate-limited` | 否（连续超限才 `4003`） |

`-32000` ~ `-32003` 属 JSON-RPC 保留的「实现定义的服务端错误」区间。`data` 至少含 `code`，可携带 `detail`、`hostVersion`、`appVersion`、`method`、`retryAfterMs` 等排障字段。

### 9.2 应用层（`result._pocket_error`）

`gateway/*` 是既有词汇，**原码保留、一个不改**。App 展示时用下表兜底（有专用映射的页面继续用专用文案）：

| `code` | 中文兜底消息模板 |
|---|---|
| `gateway/bad-request` | 请求参数不正确：{message} |
| `gateway/arguments-invalid` | 请求参数不完整，请重新操作。 |
| `gateway/internal` | 电脑上的 DSH 处理失败：{message} |
| `gateway/cancelled` | 操作已取消（连接或页面已关闭）。 |
| `gateway/not-found` | 找不到要操作的对象，请刷新后重试。 |
| `gateway/forbidden` | 电脑上的 DSH 拒绝了这个操作。 |
| `gateway/invocation-unavailable` | 这台电脑没有提供该能力。 |
| `gateway/unavailable` | 电脑上的 DSH 暂时不可用，请稍后重试。 |
| `gateway/timeout` | 电脑上的 DSH 响应超时，请重试。 |
| `gateway/missing-receipt` | 上一次操作未确认完成，请重新打开该会话。 |
| `settings/conflict` | 设置已被修改，请刷新后重新提交。 |
| `settings/rejected` | 设置被拒绝：{message} |

`{message}` 用宿主给的原消息；原消息为英文时直接拼在后面（既有 App 就是中英混排，不新造翻译层）。

### 9.3 流内错误（`api.stream` 的 `type: "error"`）

| `error.code` | 含义 | 中文模板 |
|---|---|---|
| `app-stream/failed` | 上游生产者在消费中抛错 | 数据流异常中断：{message} |
| `app-stream/limit` | 单帧超限或数据量超限 | 数据量过大，无法继续推送。请缩小范围后重试。 |
| `app-stream/ack-violation` | 确认序号回退或跳跃 | 数据流确认异常，已终止该流。 |
| `app-stream/ack-timeout` | 60 s 内无任何确认 | 数据流长时间无响应，已终止该流。 |

### 9.4 用户可见错误必须能直接展示

`message` 字段本身就是**已经组装好、可以直接 `Text()` 的中文句子**（必要时带宿主原消息）。App 不得对 `message` 再做前缀拼接或二次加工，只做长度截断。

协议层错误的标准文案（`message` 原样给出）：

| `data.code` | 标准消息 |
|---|---|
| `protocol-mismatch` | 协议版本不匹配：电脑为 v{hostVersion}，手机为 v{appVersion}。请把两端升级到同一版本。 |
| `auth-failed` | 连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。 |
| `auth-revoked` | 这台手机已被电脑撤销授权。请在电脑上重新配对。 |
| `rate-limited` | 操作太频繁，请 {n} 秒后重试。 |
| `unsupported-method` | 当前连接的电脑不支持「{method}」。 |

---

## 10. 版本与能力协商

### 10.1 `methods` / `unsupported` 的语法

| 项 | 规则 |
|---|---|
| 条目 | 精确方法名（`session.send`）或前缀通配（`terminal.*`） |
| 通配 | 只允许 `.*` 结尾，只允许出现在末尾；`*.send`、`a.*.b`、`*` 一律非法 |
| 互斥 | 生产者不得让同一个精确名同时出现在两个数组里 |
| 优先级 | 先判 `unsupported`（覆盖即不支持），再在 `methods` 里找匹配；万一出现重叠，按 `unsupported` 处理 |
| 完整性 | `methods` 是**宿主可应答方法的完整清单**，不是增量；App 不得只为在清单里的方法建立入口 |
| 变化 | 每次握手都重新取；宿主重启后清单可能变化，App 不得缓存跨连接 |

### 10.2 App 如何用它隐藏入口

| 判定 | 结果 |
|---|---|
| 入口的主方法在 `methods` 中且不被 `unsupported` 覆盖 | 可用 |
| 入口的主方法被 `unsupported` 覆盖 | 隐藏入口；若页面已在栈上，整页置灰并显示「这台电脑不支持{能力名}」 |
| 入口的主方法不在 `methods` 中 | 同上（视同不支持，但**不缓存**成永久不支持） |
| `protocol.hello` 失败或版本不符 | 不进主界面，直接显示 §9.4 的 `protocol-mismatch` 文案与「重新连接」按钮 |

具体要求：

1. **不允许「能点但没用」**：入口可见即代表该能力可用；不可用的入口必须隐藏或置灰并给出原因。
2. 认证/版本/限速三类错误**必须**同时影响入口：`auth-revoked` 后整台 PC 的所有入口置灰。
3. 任何 `-32601` 只影响该次调用，**不得**写入本地「不支持」缓存——临时故障不能把入口永久隐藏。
4. 远程外壳的侧栏入口（P4）在**未连接**时可见；连接后按本表决定其内部各项的可见性。

### 10.3 能力（`capabilities`）

| 能力 | 声明方 | 语义 |
|---|---|---|
| `window-ack` | 双方 | 支持 §6 的窗口化确认。双方都声明才生效，否则逐条模式 |

其它字符串一律忽略，不得因未知能力拒绝连接。新增能力走 `protocolVersion` 升级（v2），不在 v1 内追加。

---

## 11. v1 明确不做

| 不做 | 说明 |
|---|---|
| 二进制分块上传 | 附件与文件传输继续走既有分片读（`attachments.*`、`session.attachmentFile.*`）；不引入 WS 二进制帧，不引入分块重组状态机 |
| 多 PC 并发 | 一个 App 进程同时只保持一条远程连接；切换 PC = 关闭旧连接 + 重新握手。设备 chips（P4）只是同一台 PC 内的过滤，不是多宿主 |
| 公网隧道自管理 | 引擎只负责连 `wss://` 端点；内网穿透由用户自备反向代理。协议不引入 provider 槽位、不做隧道生命周期 |
| 连接级续传 | §7.1：无游标、不补帧 |
| 手机本地文件接入 | `native.documents.*` 在 v1 一律 `-32601`（P5 再开放） |
| 压缩 | 不启用 `permessage-deflate`，不做应用层压缩 |
| 子协议协商 | 不读不写 `Sec-WebSocket-Protocol` |
| 跨连接设备状态同步 | 两个 App 实例连同一台 PC 时互不感知，服务端不做互斥；后果由 P3 的设备表承担 |

---

## 附录 A · Dart 侧 `RuntimeTransport`

与 `lib/runtime.dart` 现有 `typedef Json = Map<String, dynamic>` 一致。字段与方法名和上文完全一致，P2 可直接照抄。

```dart
/// 本地与远程共用的唯一传输缝。实现者只处理帧，不解释业务方法。
abstract class RuntimeTransport {
  /// 发送一次请求并等待响应。
  ///
  /// 失败时抛 [PlatformException]：`code` 取 `result._pocket_error.code`
  /// 或 `error.data.code`，`message` 是可直接展示的中文，`details` 是原始错误对象。
  /// 传输已关闭时抛 `code: 'gateway/cancelled'`。
  Future<dynamic> request(String method, [Json params = const {}]);

  /// 发送一条单向通知，不等待结果。传输已关闭时静默丢弃。
  void notify(String method, [Json params = const {}]);

  /// 入站通知帧，形态固定为 `{'method': String, 'params': Json}`，
  /// 包含 `api.stream` 与全部 `remote.*`；不包含响应帧。
  Stream<Json> get events;

  /// 关闭传输：未结算请求以 `gateway/cancelled` 失败，`events` 随后关闭。
  Future<void> close();

  /// 安装反向请求处理器（`native.*`）。
  ///
  /// handler 返回值即 JSON-RPC `result`。
  /// handler 抛 [UnsupportedError] 或 `PlatformException(code: 'unsupported-method')`
  /// 时，传输层回 `-32601`；其它异常回 `-32603`，消息截断到 1024 字节。
  /// 未安装 handler 时，所有反向请求回 `-32601`。
  void setRequestHandler(
    Future<dynamic> Function(String method, Json params)? handler,
  );
}
```

实现约束（P2 必须满足，否则 §1–§7 不成立）：

1. `request` 的 `params` 一律进 `params` 字段，不得把方法名拼进 URL 或 `id`。
2. 入站帧按 §1.2 分流：有 `method` 且有 `id` → 反向请求（交 handler）；有 `method` 无 `id` → `events`；有 `id` 无 `method` → 结算在途请求；`id` 为 `null` 且无 `method` → 连接级错误（§2.2），不结算任何在途请求。
3. `close()` 幂等；重复调用不抛。
4. 关闭码到错误的映射按 §1.4 表，`auth-failed` / `auth-revoked` / `protocol-mismatch` 为终止态，实现里必须有「不再自动重连」的显式分支。

---

## 附录 B · Node 侧 `RemoteConnection`

一条已鉴权连接的全部对外表面。字段名与 §3、§6、§8 完全一致。

```js
/**
 * 一条已接受升级的远程连接。
 * 未进入 ready 前只接受 protocol.hello。
 */
export class RemoteConnection {
  /** 连接 id，进程内唯一。 */
  /** @type {string} */ id
  /** 设备 id；握手前后均由鉴权阶段确定。 */
  /** @type {string} */ deviceId
  /** 设备显示名，来自 protocol.hello.params.deviceLabel。 */
  /** @type {string} */ deviceLabel
  /** 对端地址，仅用于日志与限速。 */
  /** @type {string} */ remoteAddress
  /** 已协商版本，恒为 1。 */
  /** @type {1} */ protocolVersion
  /** 客户端声明且服务端支持的能力，例如 ['window-ack']。 */
  /** @type {string[]} */ capabilities
  /** 本连接可应答的方法清单（§10 语法）。 */
  /** @type {string[]} */ methods
  /** 本连接明确不支持的方法清单（§10 语法）。 */
  /** @type {string[]} */ unsupported
  /** @type {'awaiting-hello'|'ready'|'closing'|'closed'} */ state

  /**
   * 宿主 → App 的请求。
   * @param {string} method - 方法名，例如 'native.documents.roots'。
   * @param {object} params - 请求参数，缺省为 {}。
   * @param {AbortSignal} [signal] - 中止信号；中止只丢弃在途记录，不发送任何帧。
   * @returns {Promise<unknown>} 结果；失败为带 code 的 Error（code 取 -32601 的 data.code 等）。
   */
  request(method, params, signal) {}

  /**
   * 宿主 → App 的通知。
   * @param {string} method - 例如 'remote.taskCompleted'。
   * @param {object} [params] - 通知参数。
   * @returns {void} 帧写入失败时抛错，调用方负责记日志。
   */
  notify(method, params) {}

  /**
   * 安装 App → 宿主的请求处理器。
   * @param {(method: string, params: object) => Promise<unknown>|unknown} handler
   *   - 返回值为 JSON-RPC result；抛错则回 -32603 并截断消息到 1024 字节。
   *   - 未安装或方法不在 methods 内时回 -32601。
   * @returns {void}
   */
  onRequest(handler) {}

  /**
   * 安装 App → 宿主的通知处理器。
   * @param {(method: string, params: object) => void} handler
   *   - 未安装时通知被丢弃（通知无响应可回）。
   * @returns {void}
   */
  onNotification(handler) {}

  /**
   * 关闭连接。先终止本连接的全部流（§6.6），再把在途反向请求以
   * gateway/cancelled 失败，最后按 §1.4 的关闭码关闭 WS。
   * @param {number} code - 1000/1001/1002/1009/4000/4001/4002/4003 之一。
   * @param {string} reason - 简短原因，≤ 123 字节（WS 协议上限）。
   * @returns {Promise<void>}
   */
  close(code, reason) {}
}
```

宿主侧装配约束：

1. 一条 `RemoteConnection` 恰好对应一个 `JsonRpcLineTransport`，不为它再造一层封装。
2. `methods` 由门面的分发表生成，不由 profile 手写；`unsupported` 由平台分支与 `platform` 配置生成。
3. 拦截 `native.*` 的本地应答者必须在 `onRequest` 里先于转发判断，否则手机的 `-32601` 会盖掉 PC 本来能满足的请求。
4. `close()` 必须幂等，且必须在 `state` 变为 `closed` 之前完成流的终止（否则 `streamId` 会泄漏到下一连接）。

---

## 附录 C · 字段名对照（本地现状 → 远程）

同一份 Dart 观察层要同时服务两种模式，字段映射只在本表这一处定义。

| 本地现状 | 远程（本协议） | 说明 |
|---|---|---|
| `api.subscribe.params.subscriptionId` | `api.subscribe.params.streamId` | 两者都是「每次订阅尝试新生成」；Dart 现有 `'$id-$attempt'` 可直接当 `streamId` |
| `api.subscribe.params.owner`（由原生注入） | 无 | 一条连接只有一个 owner，恒为 `"remote"`，不上线 |
| `api.subscribe.result.generation` | 同名保留 | 值来源不变 |
| `api.stream.params.subscriptionId` | `api.stream.params.streamId` | |
| `api.stream.params.owner` | 无 | 同上 |
| `api.stream.params.sequence` | 同名保留 | 从 1 开始，每流独立 |
| `api.ack.params.subscriptionId` + `sequence` + `generation` | `api.ack.params.streamId` + `upTo` | 语义从「确认单帧」改为「累计确认」；`generation` 不再参与确认（`streamId` 不复用即可保证） |
| `api.unsubscribe.params.subscriptionId` | `api.unsubscribe.params.streamId` | |
| 逐条 ack（每帧一次） | 窗口 ack（累计，§6.2） | 未声明 `window-ack` 时行为退化为逐条，见 §6.4 |
| `events` 的 `{method, params}` 封装 | 完全相同 | 不改 |
| `_pocket_error` 走 `result` | 完全相同 | 不改 |

---

## 附录 D · 实现方自检清单

P1（宿主）：

- [ ] `/app` 之外的路径回 404；`Origin` 不匹配回 403；`Authorization` 非法回 401。
- [ ] token 摘要比对用 `timingSafeEqual`，`devices.json` 无明文 token。
- [ ] 版本不匹配只发一条 `-32000` 就关闭 `4002`，且不再处理其它方法。
- [ ] `methods` / `unsupported` 由分发表生成，语法符合 §10.1。
- [ ] `native.*` 本地拦截优先于转发；无法满足的回 `-32601`，不静默丢弃。
- [ ] 流窗口 `W=64` / `B=1 MiB` 与 §6.2 不变量一致；`ack` 回退/跳跃终止该流而非关连接。

P2（App 传输）：

- [ ] 入站帧按 §1.2 三分流，未知 `id` 的响应丢弃不关连接。
- [ ] 关闭码按 §1.4 映射，三个终止态有显式「不重连」分支。
- [ ] `-32601` 只影响单次调用，不写入不支持缓存。
- [ ] 回执节奏满足 §6.2（32 条 / 200 ms）。
- [ ] 本地模式与远程模式共用同一套窗口常量与判定。
- [ ] 反向请求 handler 未安装时回 `-32601`。

P4（远程外壳）：

- [ ] 入口可见性严格按 §10.2，不存在「能点但没用」。
- [ ] 所有错误展示直接用 §9.4 的 `message`，不二次加工。
