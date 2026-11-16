# 远程 DSH · 本机配对设置页（宿主内嵌回环页面）

状态：2026-11-16，**已落地并自检通过**（`apps/remote-host/src/pairing-page.ts`）；浏览器/真机截图验收待补（见 §3）。
读者：在 PC 上给手机配对/撤销设备的用户、排障的 Agent、后续改配对 UI 的施工者。

相关：[pc-pairing-distribution.md](pc-pairing-distribution.md)（§1 方案评估与决策、§2 分发）、[HANDOFF.md](HANDOFF.md)（§3.2.14、§4、§9）、[pairing-qr-design.md](pairing-qr-design.md)（终端二维码与配对输入路线）、[discovery.md](discovery.md)（UDP 局域网发现）、[protocol.md](protocol.md)（§2 配对、§8.4 撤销）。

**一句话**：宿主在本机回环地址上起一个只读/受控的设置页——显示配对二维码与窗口倒计时、明文配对链接、USB `adb reverse` 链接、已配对设备列表，并提供「重新打开配对窗口」与「撤销设备」。它不启用完整 Web 组合（不碰 `dsh-web-app`/`webStartup`），零新增依赖。

---

## 1. URL、端口与 Config

| 项 | 值 |
|---|---|
| 页面 URL | `http://127.0.0.1:4780/`（宿主日志 `pairing-page-ready` 给出完整 URL，端口以日志为准） |
| 绑定地址 | 固定 `127.0.0.1`（不可配置；不监听 `0.0.0.0`，不对局域网开放） |
| `pagesEnabled` | 默认 `true`；设 `false` 时不启动页面，只记一条 `pairing-page-disabled`，配对链接仍在日志里 |
| `pagesPort` | 默认 `4780`；`0` = 交给系统分配（只用于测试）；范围 1–65535 |
| 端口被占用/权限不足 | 只记 `pairing-page-failed` warn，`start()` 返回 `listening:false`；**宿主照常启动**，配对链接仍在日志 |
| 与既有端口 | wss `4777`（TCP）、UDP 发现 `4778`、页面 `4780` 互不冲突；页面是明文 HTTP 回环，与 wss 的 TLS 无关 |

cordis.yml 覆盖示例（不改默认值时不需要写）：

```yaml
- id: remote-host
  config:
    pagesEnabled: true
    pagesPort: 4780
```

装配位置：`apps/remote-host/src/index.ts` 的 `apply()` 在 `remoteHost` 服务挂载后 `new PairingPageServer(...)` 并 `await start()`；插件卸载时 effect 逆序释放，页面先于 wss 监听停止（`PairingPageServer.stop()` 会关闭监听并断开浏览器 keep-alive 连接）。

## 2. 页面截图位置

截图统一放仓库根的 `.cache/remote-device/`（`.cache/` 不入库，与既有 `p5c-*`/`p6-*` 截图一致）。建议文件名：

| 文件 | 内容 |
|---|---|
| `.cache/remote-device/pairing-page-lan.png` | 窗口打开：二维码、倒计时、明文链接、设备列表（有效/已撤销/已过期各一行） |
| `.cache/remote-device/pairing-page-usb.png` | USB 段落：`adb reverse tcp:4777 tcp:4777` 与回环配对链接 |
| `.cache/remote-device/pairing-page-expired.png` | 窗口过期/被消费后的「当前没有打开的配对窗口」态 |

拍摄方法：用真实 profile 启动宿主（HANDOFF §1），PC 浏览器打开日志里的 URL，直接截屏；点「撤销」确认后再截一张（宿主自动重开窗口 + 列表出现已撤销行）。验收后把文件名补进 HANDOFF §3.2.14/§9。

本轮未截图：验证环境不跑真实宿主（lead 的 4777 在跑，本任务禁止占 4777/4778），页面渲染与防护契约由 `pairing-page-selfcheck.ts` 的 24 项断言覆盖（见 §8）。

## 3. 使用步骤

### 3.1 普通（手机与电脑同一局域网）

1. 按 HANDOFF §1 启动宿主（`pnpm dsh --profile remote-host ...`）。
2. 终端出现 `[remote-host] info pairing-page-ready: … http://127.0.0.1:4780/`，在电脑浏览器打开该 URL。
3. 手机 App →「添加连接」→「扫码配对」扫描页面二维码；或点「复制配对链接」后粘贴到 App 配对页。
4. 配对成功（宿主日志 `device-issued`），页面 2 s 内自动刷新：二维码随窗口消费变为「已关闭」，已配对设备列表出现该设备。
5. 配下一台手机：点「重新打开配对窗口」→ 页面 303 刷新出新二维码与链接。

### 3.2 USB（手机与电脑不同网段/隔离网络）

1. 电脑执行页面 USB 段落里的命令：`adb reverse tcp:4777 tcp:4777`（端口取自宿主实际监听端口，不写死）。
2. 复制页面里的 `usbPairUrl`（`wss://127.0.0.1:4777#instance=…&token=…`），粘贴到 App 配对页。
3. USB 链接与主链接是同一张一次性配对票据（token 与 instanceId 相同），只是主机名不同；任选一种完成配对即可。

### 3.3 反向代理 / 公网入口（`Config.publicOrigin`）

页面主二维码用 `publicOrigin`（或 `publicHost`/默认路由地址）生成 `pairUrl`，USB 段落始终是回环地址的同一张票据——同一窗口两张链接可直接互换，不需要在页面里配置反代。域名型部署要求设置 `publicOrigin`（见 [reachability.md](reachability.md)），页面只展示宿主已经生成好的链接。

### 3.4 撤销设备

设备表每行右侧「撤销」→ 确认对话框 → 宿主执行既有撤销流程：先落盘 `devices.json`，再关闭该设备的在线连接并推 `remote.deviceRevoked`（protocol §8.4），随后自动打开新的配对窗口 → 页面 303 刷新，看到新二维码与「已撤销」状态。只有「有效」设备有撤销按钮；已撤销/已过期行显示状态与 `—`。

## 4. 契约

### 4.1 `GET /`

服务端渲染的单页 HTML（中文、内联 CSS/极简 JS、无任何外部资源）：

- 头部：宿主显示名、instanceId 前 8 位、`wss` origin、UDP 局域网发现状态、回环地址提示；
- 配对卡片：窗口状态（打开/已关闭）、剩余秒数、过期时间、**内联 SVG 二维码**（`encodeQrMatrix` → `viewBox` + 每行连续深色模块合并成 path，含 4 模块安静区）、明文链接 textarea + 复制按钮、USB `adb reverse` 命令 + `usbPairUrl` + 复制按钮、「重新打开配对窗口」按钮（CSRF 隐藏字段）；
- 设备表：`label` / `id` 前 8 位 / 配对时间（`createdAt`）/ 最近连接（`lastSeenAt`）/ 状态（有效、已撤销、已过期）/ 每行撤销按钮（含 CSRF 隐藏字段，二次确认）；
- 页脚：安全说明（只监听回环、不要通过端口转发暴露、同机进程可读属已接受威胁）；
- 页面 JS：每秒本地刷新倒计时；每 2 s 轮询 `/api/state`，窗口关闭时隐藏二维码区块，窗口重新打开或设备数变化时整页刷新。无 JS 也可完成扫码/复制与表单提交。

### 4.2 `GET /api/state`

```json
{
  "pairing": {
    "open": true,
    "expiresAt": 1760000000000,
    "pairUrl": "wss://192.168.5.21:4777#instance=<64hex>&token=<43chars>"
  },
  "usbPairUrl": "wss://127.0.0.1:4777#instance=<64hex>&token=<43chars>",
  "devices": [
    {
      "id": "<32hex>",
      "label": "OnePlus6",
      "createdAt": 1760000000000,
      "lastSeenAt": 1760000000000,
      "expiresAt": 1780000000000
    }
  ]
}
```

- 窗口未打开/已过期/已被消费：`{"pairing":{"open":false},"usbPairUrl":null,"devices":[…]}`——**不出现任何 token 或链接**。
- `devices` 是 `DeviceSummary`（`apps/remote-host/src/devices.ts`）：不含令牌摘要；`revokedAt` 只在已撤销时出现。
- 字段集合固定为 `pairing` / `usbPairUrl` / `devices`（自检断言）。

### 4.3 `POST /pair/reopen`

表单 `application/x-www-form-urlencoded`，字段 `csrf=<43chars>`。成功：`303 Location: /` → 页面加载新窗口；动作失败：`500`（详情见宿主日志 `pairing-page-action result=failed`）。

### 4.4 `POST /devices/revoke`

表单字段 `csrf=<43chars>&id=<32hex>`。成功（无论该设备本轮是否真的撤销）：`303 Location: /`；id 形态非法：`400`；未知/已撤销 id：仍 `303`，日志 `result=not-revoked`；宿主撤销抛错：`500`。

### 4.5 状态码

| 情况 | 状态码 |
|---|---|
| 正常 GET | 200 |
| `Host` 不在 `127.0.0.1:<port>` / `localhost:<port>`（防 DNS rebinding） | 403（缺 Host 的 HTTP/1.1 由 Node 24 `requireHostHeader` 直接 400） |
| 带 `Origin` 且非同源 | 403 |
| POST 缺/错/重复 `csrf` | 403 |
| POST 非表单编码 | 415 |
| POST 表单体超过 4 KiB | 413 |
| 方法不对 | 405 + `Allow` |
| 未知路径 | 404 |
| 页面内部错误 | 500 |

### 4.6 日志事件

| event | level | 内容 |
|---|---|---|
| `pairing-page-ready` | info | `fields.url`（完整页面 URL，不含 token）、`port`、`address` |
| `pairing-page-failed` | warn / error | `fields.phase` = `bind` / `bind-sync` / `runtime` / `qr` / `request` + `error`；启动失败只 warn、不抛错 |
| `pairing-page-action` | info / warn / error | `fields.action`（`pair-reopen` / `device-revoke` / `request`）、`method`、`result`（`ok` / `revoked` / `not-revoked` / `rejected` / `failed`），撤销时带 `deviceId` 与 `closedConnections`；**不含 token 与 CSRF** |
| `pairing-page-disabled` | info | `pagesEnabled=false` 时的说明 |

注意：重开窗口复用既有 `remoteHost.pair()`，它会按既有行为把含 token 的 `pairUrl` 写进结构化日志（这是终端用户在没有页面时的唯一获取方式，属既有契约，不是本页新增的日志）。页面自身的上表事件不含 token——自检会断言日志里不出现 CSRF、配对令牌与 `#instance=`。

## 5. 安全与威胁模型

实现里逐条成立：

- **只绑回环**：固定 `127.0.0.1`，没有配置项能改成对外地址；页面是增强能力，绑定失败只降级。
- **Host 校验（防 DNS rebinding）**：所有请求（含 GET）都要求 `Host` 是 `127.0.0.1:<实际端口>` 或 `localhost:<实际端口>`（大小写不敏感），其它主机名/端口一律 403。
- **Origin 校验**：带 `Origin` 头的请求必须与本页同源，否则 403；不返回任何 `Access-Control-*` 头（无 CORS）。
- **CSRF**：进程启动时 `randomBytes(32).toString('base64url')` 生成，嵌在 HTML 表单隐藏字段；所有 POST 用 `timingSafeEqual` 校验，缺失、错误、重复出现都 403，且不产生任何副作用。
- **无外部资源与点击劫持**：CSP `default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`，配合 `X-Frame-Options: DENY`。
- **其余响应头**：`X-Content-Type-Options: nosniff`、`Cache-Control: no-store`、`Referrer-Policy: no-referrer`。
- **内容逃逸**：设备名（配对方上报）与所有动态文本先 HTML 转义再拼进页面；JSON 只含 `DeviceSummary`（无令牌摘要）。
- **token 生命周期**：只在窗口打开期间渲染/返回；窗口过期或被消费后，页面（2 s 轮询）与 `/api/state` 都不再给出链接与 token。

已接受的威胁（写进页面页脚与本节）：

- 同一台电脑上的其它进程本来就能读 `$DSH_HOME/remote-host/devices.json` 与宿主日志，回环页带来的增量风险有限；`Host`/`CSRF`/`Origin` 防的是**浏览器里其它网页**发起的 DNS rebinding 与 CSRF，不防同机进程。
- 浏览器地址栏 URL 不含 token，但窗口打开期间页面内容含 token（二维码与明文链接就是要展示的）；不要把页面 URL 通过端口转发/反向代理暴露给其它机器，也不要让不可信本机用户共用这台电脑。
- 回环 HTTP 明文与远程链路无关：wss 仍是协议要求；页面只是本机展示面。

明确不做：一次性 `uiToken`/URL 令牌（评估 §1.2 的可选方案，本实现用 Host+CSRF+Origin 覆盖浏览器侧攻击；URL 里不带 token 便于用户直接打开）；HTTPS（回环明文即可，且浏览器把 `127.0.0.1` 视为安全上下文，剪贴板 API 可用）。

## 6. 排障

| 现象 | 排查 |
|---|---|
| 日志没有 `pairing-page-ready` | 检查 `Config.pagesEnabled` 是否为 `true`；看是否有 `pairing-page-failed`（`fields.phase`/`port`）；端口被占用时换 `pagesPort` 或设 `0` |
| 浏览器打不开页面 | 必须用 `http://127.0.0.1:<port>/` 或 `http://localhost:<port>/`；`localhost` 若解析到 `::1`，改用 `127.0.0.1` |
| 二维码扫不出 | 直接复制明文链接；超长 origin（长域名）可能超出内置编码器容量，页面会降级成「二维码没有生成，请直接复制链接」 |
| 页面显示「当前没有打开的配对窗口」 | 窗口单次有效：已被消费或已过期 → 点「重新打开配对窗口」 |
| 点撤销没反应/没有撤销按钮 | 只有「有效」设备有按钮；303 刷新后看设备状态与宿主日志 `pairing-page-action` |
| 访问返回 403 | 用的不是回环主机名，或端口与实际绑定端口不一致；本页只服务 `127.0.0.1`/`localhost` |
| 4780 被其它程序占用 | `pagesPort` 换一个（或 `0` 随机）；页面失败不影响配对与远程连接 |
| 想在没有浏览器的机器上看配对信息 | 页面只是增强能力：终端日志与 TTY 二维码（`writePairingQr`）仍然可用 |

## 7. 验证

### 7.1 本任务跑过的（原样摘录）

- `node --import tsx/esm apps/remote-host/scripts/pairing-page-selfcheck.ts` → `PASS 24/24 项全部通过（页面/JSON 契约 + Host/CSRF/CORS 防护 + 生命周期降级）`
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` → exit 0
- `pnpm exec tsc -p tsconfig.host.json` → exit 0
- `pnpm exec oxlint apps/remote-host/src/pairing-page.ts apps/remote-host/src/index.ts apps/remote-host/scripts/pairing-page-selfcheck.ts` → `Found 0 warnings and 0 errors.`
- `pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts` → `PASS 14/14 项全部通过`（宿主行为无回归）

### 7.2 lead 启动 4777 后手工验证（PowerShell，命令已在本机以预览页演练过）

```powershell
# 0) 宿主重启后终端应出现（端口以日志为准）：
#    [remote-host] info pairing-page-ready: 本机配对页已就绪：... http://127.0.0.1:4780/

# 1) 页面与安全头
$page = Invoke-WebRequest -Uri 'http://127.0.0.1:4780/' -UseBasicParsing
$page.StatusCode                                    # 200
$page.Headers['X-Content-Type-Options']             # nosniff
$page.Headers['Cache-Control']                      # no-store
$page.Headers['X-Frame-Options']                    # DENY
$page.Headers['Access-Control-Allow-Origin']        # 空（无 CORS）
[regex]::IsMatch($page.Content, '<svg[^>]*viewBox="0 0 \d+ \d+"')   # True（内联二维码）

# 2) JSON 状态：窗口打开时含 pairUrl/usbPairUrl；关闭时 pairing.open=false、usbPairUrl=null
(Invoke-WebRequest -Uri 'http://127.0.0.1:4780/api/state' -UseBasicParsing).Content

# 3) 带 CSRF 重开窗口（303；curl 不跟随重定向，所以打印 303）
$csrf = [regex]::Match($page.Content, 'name="csrf" value="([A-Za-z0-9_-]{43})"').Groups[1].Value
curl.exe -s -o NUL -w "%{http_code}`n" -X POST -d "csrf=$csrf" http://127.0.0.1:4780/pair/reopen        # 303

# 4) 防护：无 CSRF / 跨站 Origin / 伪造 Host 都应是 403
curl.exe -s -o NUL -w "%{http_code}`n" -X POST http://127.0.0.1:4780/pair/reopen                        # 403
curl.exe -s -o NUL -w "%{http_code}`n" -X POST -H "Origin: http://evil.example" -d "csrf=$csrf" http://127.0.0.1:4780/pair/reopen   # 403
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: evil.example:4780" http://127.0.0.1:4780/api/state    # 403

# 5) 撤销设备（id 从 /api/state 取；303；之后宿主日志 pairing-page-action result=revoked，
#    App 收到 remote.deviceRevoked 并 4001 断开，页面刷新出新二维码）
$state = (Invoke-WebRequest -Uri 'http://127.0.0.1:4780/api/state' -UseBasicParsing).Content | ConvertFrom-Json
$id = $state.devices[0].id
curl.exe -s -o NUL -w "%{http_code}`n" -X POST -d "csrf=$csrf&id=$id" http://127.0.0.1:4780/devices/revoke   # 303
```

浏览器侧验收（对应评估 §1.2）：打开页面 → 手机扫码配对成功 → 设备列表出现该设备 → 点「撤销」→ App 提示被撤销、宿主自动重开窗口、页面刷新出新二维码 → 倒计时归零后显示「窗口已过期」。截图按 §2 命名保存。

## 8. 未做项 / 已知边界

1. **截图未拍**（§2）；需在真实宿主 + 浏览器环境补验收图。
2. **设备在线状态未展示**：评估 §1.2 建议设备行带 online，需要宿主把当前绑定连接暴露出来（`server.ts` 的连接表）；本任务不改 `server.ts`，页面只展示 `lastSeenAt`。如需在线状态，后续在 `RemoteHostHandle.pages().devices()` 里补字段。
3. **无 SSE/WebSocket**：页面 2 s 轮询 `/api/state`；配对窗口最长 15 分钟、数据量小，轮询足够，避免新增推送通道。
4. **页面中文单语**：宿主内嵌页不属于 `packages/client` 的 locale 字典体系（评估 §1.2 风险①），v1 只做中文；若以后要双语，需要 lead 决定文案归属。
5. **页面不写配置**：只展示 UDP 发现状态，不提供开关；`Config` 一律从 cordis.yml 改。
6. **重开窗口会按既有行为打印终端二维码并写含 token 的既有日志**（§4.6 注意）；这是复用 `remoteHost.pair()` 的预期行为，不是页面日志。
7. **Node 24 缺 Host 直接 400**：HTTP/1.1 无 `Host` 的请求在 Node 层就被拒绝，页面的 Host 校验是第二道；HTTP/1.0 无 Host 走到页面校验回 403。

## 9. 代码地图

| 文件 | 职责 |
|---|---|
| `apps/remote-host/src/pairing-page.ts` | 本页全部：回环 HTTP 服务、HTML/JSON 渲染、Host/CSRF/Origin/CSP 防护、启停与降级 |
| `apps/remote-host/src/index.ts` | Config `pagesEnabled`/`pagesPort`、`RemotePairingTicket.usbPairUrl`、`handle.pages()` 数据源、`apply()` 装配与 effect 清理 |
| `apps/remote-host/scripts/pairing-page-selfcheck.ts` | 24 项零依赖自检（真实回环 HTTP + 内存假数据源） |
| `apps/android/docs/remote-dsh/pc-pairing-page.md` | 本文 |
