# 远程 DSH · 本机配对设置页（宿主内嵌回环页面）

状态：2026-11-17，**已落地并通过自检 + 浏览器验收**（`apps/remote-host/src/pairing-page.ts`）；
页面截图 `pairing-page-lan.png` 已补（见 §2）；真机扫码配对链路仍由 §3 的常规配对验收覆盖。
2026-11-17 扩展：本页同一服务器新增**本机控制面 JSON API**（`/api/state` 字段、`/api/pair`、
`/api/devices/revoke`、`/qr.svg`）与**长期配对模式**（`Config.pairingLongTerm`），供设备互联插件
托管远程宿主时使用；原有页面与表单/CSRF 语义不变。
读者：在 PC 上给手机配对/撤销设备的用户、排障的 Agent、后续改配对 UI 的施工者、写本机控制面客户端的插件作者。

相关：[pc-pairing-distribution.md](pc-pairing-distribution.md)（§1 方案评估与决策、§2 分发）、[HANDOFF.md](HANDOFF.md)（§3.2.14、§4、§9）、[pairing-qr-design.md](pairing-qr-design.md)（终端二维码与配对输入路线）、[discovery.md](discovery.md)（UDP 局域网发现）、[protocol.md](protocol.md)（§2 配对、§8.4 撤销）。

**一句话**：宿主在本机回环地址上起一个只读/受控的设置页——显示配对二维码与窗口倒计时、明文配对链接、USB `adb reverse` 链接、已配对设备列表，并提供「重新打开配对窗口」与「撤销设备」；同一回环服务器还提供一套本机控制面 JSON API（状态/重开窗口/撤销设备/二维码 SVG），供本机插件（设备互联）读取状态与驱动长期配对。它不启用完整 Web 组合（不碰 `dsh-web-app`/`webStartup`），零新增依赖。

---

## 1. URL、端口与 Config

| 项 | 值 |
|---|---|
| 页面 URL | `http://127.0.0.1:4780/`（宿主日志 `pairing-page-ready` 给出完整 URL，端口以日志为准） |
| 绑定地址 | 固定 `127.0.0.1`（不可配置；不监听 `0.0.0.0`，不对局域网开放） |
| `pagesEnabled` | 默认 `true`；设 `false` 时不启动页面，只记一条 `pairing-page-disabled`，配对链接仍在日志里 |
| `pagesPort` | 默认 `4780`；`0` = 交给系统分配（只用于测试）；范围 1–65535 |
| `pairingTtlMs` | 配对窗口有效期；默认 `120000`（120 s），范围 1 s–**90 天**（`MAXIMUM_PAIRING_TTL_MS`，`apps/remote-host/src/pairing.ts`）。超过 15 分钟或开长期模式时启动日志写 warn 安全提示 |
| `pairingLongTerm` | 默认 `false`；`true` 时窗口按 `pairingTtlMs` 打开，且**配对成功后自动打开下一个窗口**（同 TTL、新 token），适合「设置页里长期展示一张二维码」；安全取舍见 §5 |
| 端口被占用/权限不足 | 只记 `pairing-page-failed` warn，`start()` 返回 `listening:false`；**宿主照常启动**，配对链接仍在日志 |
| 与既有端口 | wss `4777`（TCP）、UDP 发现 `4778`、页面 `4780` 互不冲突；页面是明文 HTTP 回环，与 wss 的 TLS 无关 |

cordis.yml 覆盖示例（不改默认值时不需要写）：

```yaml
- id: remote-host
  config:
    pagesEnabled: true
    pagesPort: 4780
    # 长期配对（设备互联插件托管时常用）：30 天窗口 + 配对成功后自动续张
    pairingTtlMs: 2592000000
    pairingLongTerm: true
```

装配位置：`apps/remote-host/src/index.ts` 的 `apply()` 在 `remoteHost` 服务挂载后 `new PairingPageServer(...)` 并 `await start()`；插件卸载时 effect 逆序释放，页面先于 wss 监听停止（`PairingPageServer.stop()` 会关闭监听并断开浏览器 keep-alive 连接）。

## 2. 页面截图位置

截图统一放仓库根的 `.cache/remote-device/`（`.cache/` 不入库，与既有 `p5c-*`/`p6-*` 截图一致）。建议文件名：

| 文件 | 内容 |
|---|---|
| `.cache/remote-device/pairing-page-lan.png` | 窗口打开：二维码、倒计时（短窗口）/「长期有效」（长窗口）、明文链接、设备列表（有效/已撤销/已过期各一行） |
| `.cache/remote-device/pairing-page-usb.png` | USB 段落：`adb reverse tcp:4777 tcp:4777` 与回环配对链接 |
| `.cache/remote-device/pairing-page-expired.png` | 窗口过期/被消费后的「当前没有打开的配对窗口」态 |

拍摄方法：用真实 profile 启动宿主（HANDOFF §1），PC 浏览器打开日志里的 URL，直接截屏；点「撤销」确认后再截一张（宿主自动重开窗口 + 列表出现已撤销行）。验收后把文件名补进 HANDOFF §3.2.14/§9。

**2026-11-16 已补**：`pairing-page-lan.png`（1000×1600，窗口打开：宿主信息/instance 前缀/origin/发现状态、二维码、明文链接、USB `adb reverse` 段、设备表含已撤销行与撤销按钮）——用 headless Edge 打开真实 4777 宿主的 `http://127.0.0.1:4780/` 截图。浏览器验收同时确认：`GET /` 200 + `nosniff`/`no-store`/无 CORS；`/api/state` 返回窗口与设备表；带 CSRF 的 `POST /pair/reopen` → 303（宿主日志 `pairing-page-action result=ok`）；伪造 Host → 403；对旧「M1 探针」设备 `POST /devices/revoke` → 303，宿主日志 `device-revoked`，设备列表该行变为「已撤销」。
USB/expired 两张未单独截：USB 段与窗口打开态在同一页（已包含在 `pairing-page-lan.png`）；过期态要让窗口到期（把 `pairingTtlMs` 设成几秒后重启，或配对消费掉窗口），自检已覆盖窗口关闭时无二维码/无链接/`/qr.svg` 404 的契约。

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

### 3.5 长期配对（`pairingLongTerm`，设备互联插件托管时使用）

1. 宿主配置写 `pairingTtlMs: 2592000000`（30 天）与 `pairingLongTerm: true`（或由插件生成的 overlay 写入同样字段），重启宿主。
2. 页面不再显示秒级倒计时（剩余时间超过 1 小时时只显示「长期有效」与真实过期时间），二维码与链接在窗口有效期内一直可扫。
3. 每配对成功一台手机，宿主会自动换一张新二维码/链接（日志事件 `pairing-window-reopened-longterm`），页面 2 s 内刷新；不需要手动点「重新打开配对窗口」。
4. 宿主重启后照常开一个新窗口；不想再开放配对入口时关宿主或把 `pairingLongTerm`/`pagesEnabled` 关掉。长期窗口的安全取舍见 §5。

## 4. 契约

### 4.1 `GET /`

服务端渲染的单页 HTML（中文、内联 CSS/极简 JS、无任何外部资源）：

- 头部：宿主显示名、instanceId 前 8 位、`wss` origin、UDP 局域网发现状态、回环地址提示；
- 配对卡片：窗口状态（打开/已关闭）、剩余秒数、过期时间、**内联 SVG 二维码**（`encodeQrMatrix` → `viewBox` + 每行连续深色模块合并成 path，含 4 模块安静区）、明文链接 textarea + 复制按钮、USB `adb reverse` 命令 + `usbPairUrl` + 复制按钮、「重新打开配对窗口」按钮（CSRF 隐藏字段）；
- 设备表：`label` / `id` 前 8 位 / 配对时间（`createdAt`）/ 最近连接（`lastSeenAt`）/ 状态（有效、已撤销、已过期）/ 每行撤销按钮（含 CSRF 隐藏字段，二次确认）；
- 页脚：安全说明（只监听回环、不要通过端口转发暴露、同机进程可读属已接受威胁）；
- 页面 JS：短窗口每秒本地刷新倒计时（长窗口不渲染倒计时元素）；每 2 s 轮询 `/api/state`，窗口关闭时隐藏二维码区块，窗口重新打开或设备数变化时整页刷新。无 JS 也可完成扫码/复制与表单提交。

### 4.2 `GET /api/state`

```json
{
  "host": {
    "name": "DESKTOP-ABC",
    "instanceId": "<64hex>",
    "origin": "wss://192.168.5.21:4777",
    "port": 4777,
    "discovery": { "enabled": true, "port": 4778 },
    "listening": true
  },
  "pairing": {
    "open": true,
    "expiresAt": 1760000000000,
    "pairUrl": "wss://192.168.5.21:4777#instance=<64hex>&token=<43chars>",
    "usbPairUrl": "wss://127.0.0.1:4777#instance=<64hex>&token=<43chars>"
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

- `host` 是 `PairingPageHost`：`port` 是 **wss 监听端口**（不是页面端口），`origin` 是对外宣告的 `wss://host[:port]`，`listening` 表示 wss 仍在服务（页面只在监听成功后构造，正常恒为 `true`）；另有宿主显示名、instanceId（CA 指纹）与 UDP 发现状态。
- `pairing` 四字段在窗口关闭/过期/已消费时全部为 `null`（`open:false`），客户端不需要处理缺失字段；`pairing.usbPairUrl` 是 USB 回环配对链接。
- 顶层 `usbPairUrl` 是兼容旧消费者的副本（与 `pairing.usbPairUrl` 同值）；`devices` 是 `DeviceSummary`（`apps/remote-host/src/devices.ts`），不含令牌摘要，`revokedAt` 只在已撤销时出现。
- 字段集合固定为 `host` / `pairing` / `usbPairUrl` / `devices`（自检断言），**不含** `longTerm`（长期模式由插件自己的配置决定 UI 文案）；窗口打开时三处带 token 的链接（`pairing.pairUrl`、`pairing.usbPairUrl`、顶层 `usbPairUrl`）都只是同一张票据的不同副本。

### 4.3 `POST /pair/reopen`（页面表单）

表单 `application/x-www-form-urlencoded`，字段 `csrf=<43chars>`。成功：`303 Location: /` → 页面加载新窗口；动作失败：`500`（详情见宿主日志 `pairing-page-action result=failed`）。

### 4.4 `POST /devices/revoke`（页面表单）

表单字段 `csrf=<43chars>&id=<32hex>`。成功（无论该设备本轮是否真的撤销）：`303 Location: /`；id 形态非法：`400`；未知/已撤销 id：仍 `303`，日志 `result=not-revoked`；宿主撤销抛错：`500`。

### 4.5 控制面 JSON API（本机插件用）

三个端点只额外要求 `Host` 是回环地址（同 §4.2 的守卫）；`/api/pair` 与 `/api/devices/revoke` 还必须带自定义头

```http
x-dsh-pairing-control: 1
```

缺失或值不是 `1` 时回 `403 {"error":{"code":"control-header-required",…}}`，且不产生任何副作用。它们不需要 CSRF、不接受表单编码；`Content-Type` 只有 `/api/devices/revoke` 强制 `application/json`（`/api/pair` 可空体、带 JSON 对象也接受）。错误响应统一：

```json
{ "error": { "code": "machine-readable-code", "message": "可直接展示的中文说明" } }
```

| 端点 | 请求 | 成功响应 |
|---|---|---|
| `GET /qr.svg[?v=任意]` | 无请求体、**不要**控制头（浏览器 `<img>` 不能带自定义头）；query 串被忽略，可用 `?v=<expiresAt>` 刷新缓存 | `200 image/svg+xml`：当前窗口 `pairUrl` 的二维码（与页面内联二维码同一份渲染，`renderPairingQrSvg`）；`Cache-Control: no-store`。窗口未打开/已过期/已消费：`404 text/plain` |
| `POST /api/pair` | 控制头；空 body 或 `{}` | `200` + **与 `GET /api/state` 完全相同的完整 state**（打开/重开窗口，旧窗口立即失效）；失败：`500 pair-failed` |
| `POST /api/devices/revoke` | 控制头 + `Content-Type: application/json` + `{"deviceId":"<32hex>"}` | `200` + 最新完整 state（撤销成功时宿主同时自动重开下一个配对窗口）；`400 invalid-request`（非 JSON/缺/形态非法 deviceId）、`404 device-not-found`、`409 device-already-revoked`、`415 unsupported-media-type`、`500 revoke-failed` |

`GET /api/state` 是只读端点：不要求控制头（跨站读取被同源策略与「没有 CORS 头」挡住），但写操作都要求控制头。

### 4.6 状态码

| 情况 | 状态码 |
|---|---|
| 正常 GET | 200 |
| `Host` 不在 `127.0.0.1:<port>` / `localhost:<port>`（防 DNS rebinding） | 403（缺 Host 的 HTTP/1.1 由 Node 24 `requireHostHeader` 直接 400） |
| 带 `Origin` 且非同源 | 403（表单与控制 API 都一样） |
| POST 缺/错/重复 `csrf`（表单） | 403 |
| POST 缺/错控制头（`/api/pair`、`/api/devices/revoke`） | 403 `control-header-required` |
| POST 非表单编码（表单端点） | 415 |
| 控制 API 非 JSON（`/api/devices/revoke`） | 415 `unsupported-media-type` |
| POST 表单体超过 4 KiB / 控制 API 体超过 4 KiB | 413（控制 API 另给 `body-too-large`） |
| 撤销：非法 deviceId / 非法 JSON / 未知 / 已撤销 | 400 / 400 / 404 / 409 |
| `GET /qr.svg` 时没有打开的窗口 | 404 |
| 方法不对 | 405 + `Allow` |
| 未知路径 | 404 |
| 页面内部错误 | 500 |

### 4.7 日志事件

| event | level | 内容 |
|---|---|---|
| `pairing-page-ready` | info | `fields.url`（完整页面 URL，不含 token）、`port`、`address` |
| `pairing-page-failed` | warn / error | `fields.phase` = `bind` / `bind-sync` / `runtime` / `qr` / `request` + `error`；启动失败只 warn、不抛错 |
| `pairing-page-action` | info / warn / error | `fields.action`（`pair-reopen` / `device-revoke` / `api-pair` / `api-device-revoke` / `request`）、`method`、`result`（`ok` / `revoked` / `not-revoked` / `rejected` / `failed`），撤销时带 `deviceId` 与 `closedConnections`；**不含 token 与 CSRF** |
| `pairing-page-disabled` | info | `pagesEnabled=false` 时的说明 |
| `pairing-window-reopened-longterm` | info | 长期配对：配对成功后自动开下一个窗口（由 `./index.ts` 写入，含 `pairUrl`，与既有窗口日志同形） |
| `pairing-longterm-enabled` | warn | `pairingLongTerm=true` 的启动安全提示：长期窗口等于长期可配对入口，只适合个人可信网络 |
| `pairing-window-long` | warn | 未开长期模式但 `pairingTtlMs > 15 分钟` 的启动安全提示 |
| `pairing-longterm-reopen-failed` | warn | 长期模式配对成功但自动重开下一个窗口失败（设备仍已配对，可在控制面手动重开） |

注意：重开窗口复用既有 `remoteHost.pair()`，它会按既有行为把含 token 的 `pairUrl` 写进结构化日志（这是终端用户在没有页面时的唯一获取方式，属既有契约，不是本页新增的日志）。页面自身的上表事件不含 token——自检会断言日志里不出现 CSRF、配对令牌与 `#instance=`。

## 5. 安全与威胁模型

实现里逐条成立：

- **只绑回环**：固定 `127.0.0.1`，没有配置项能改成对外地址；页面是增强能力，绑定失败只降级。
- **Host 校验（防 DNS rebinding）**：所有请求（含 GET）都要求 `Host` 是 `127.0.0.1:<实际端口>` 或 `localhost:<实际端口>`（大小写不敏感），其它主机名/端口一律 403。
- **Origin 校验**：带 `Origin` 头的请求必须与本页同源，否则 403；不返回任何 `Access-Control-*` 头（无 CORS）。
- **CSRF**：进程启动时 `randomBytes(32).toString('base64url')` 生成，嵌在 HTML 表单隐藏字段；所有 POST 用 `timingSafeEqual` 校验，缺失、错误、重复出现都 403，且不产生任何副作用。
- **控制面头（控制 API）**：`POST /api/pair` 与 `POST /api/devices/revoke` 必须带 `x-dsh-pairing-control: 1`。跨站表单不能加自定义头；跨站 fetch 加自定义头会先发预检，而本页不实现 `OPTIONS`、也不返回 CORS 头，预检必然失败。它挡的是**浏览器里其它网页**发起的 CSRF，不是本机进程鉴权（同机进程可以照抄这个头，见下）。
- **只读端点不带控制头**：`GET /api/state`、`GET /qr.svg` 只靠回环 Host 守卫。跨站读取被同源策略挡住（无 CORS）；`<img src="/qr.svg">` 只能显示、不能读像素，不构成 token 外泄通道。
- **无外部资源与点击劫持**：CSP `default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`，配合 `X-Frame-Options: DENY`。
- **其余响应头**：`X-Content-Type-Options: nosniff`、`Cache-Control: no-store`、`Referrer-Policy: no-referrer`；`/qr.svg` 同样带这些头。
- **内容逃逸**：设备名（配对方上报）与所有动态文本先 HTML 转义再拼进页面；JSON 只含 `DeviceSummary`（无令牌摘要）。
- **token 生命周期**：只在窗口打开期间渲染/返回；窗口过期或被消费后，页面（2 s 轮询）、`/api/state` 与 `/qr.svg` 都不再给出链接与 token。

已接受的威胁（写进页面页脚与本节）：

- 同一台电脑上的其它进程本来就能读 `$DSH_HOME/remote-host/devices.json` 与宿主日志，回环页带来的增量风险有限；`Host`/`CSRF`/`Origin`/控制头防的是**浏览器里其它网页**发起的 DNS rebinding 与 CSRF，不防同机进程。控制头同理**不是鉴权**：本机插件用它是为了显式标记「控制面客户端」，恶意本机进程可以直接读取设备表与日志。
- 浏览器地址栏 URL 不含 token，但窗口打开期间页面内容含 token（二维码与明文链接就是要展示的）；不要把页面 URL 通过端口转发/反向代理暴露给其它机器，也不要让不可信本机用户共用这台电脑。
- 回环 HTTP 明文与远程链路无关：wss 仍是协议要求；页面只是本机展示面。

**长期配对（`Config.pairingLongTerm`）的安全取舍**：长期窗口等于「长期可配对入口」——窗口开着期间，任何能连到配对端口的人都可以尝试兑换一张设备令牌（`/pair` 仍是单次令牌 + 对端限速，但入口本身一直存在）。因此：

- 只应部署在个人可信网络（局域网/组网/Tailscale 等），不要配合公网端口映射；
- 长期模式（`pairingLongTerm=true`）与「超过 15 分钟的窗口」都会在宿主启动时写一条 warn（`pairing-longterm-enabled` / `pairing-window-long`），不要忽略；
- 安全边界靠**设备撤销 + 不用时关闭宿主**，不是靠窗口倒计时；多台设备共用同一张长期链接时要记得删掉不再使用的设备；
- 90 天上限只是「链接可以活多久」的技术上限，不表示推荐值；插件默认的 30 天已经足够长，体验上不需要更久；
- 到期后窗口不会自动续期（自动续开只发生在配对成功后）：要持续开放入口就重启宿主或让控制面 `POST /api/pair` 重开。

明确不做：一次性 `uiToken`/URL 令牌（评估 §1.2 的可选方案，本实现用 Host+CSRF+Origin+控制头覆盖浏览器侧攻击；URL 里不带 token 便于用户直接打开）；HTTPS（回环明文即可，且浏览器把 `127.0.0.1` 视为安全上下文，剪贴板 API 可用）；控制头的进程级随机 token（插件无法在 spawn 前读到它，静态头已足以挡住浏览器侧攻击，真正的边界是回环绑定与同机信任）。

## 6. 排障

| 现象 | 排查 |
|---|---|
| 日志没有 `pairing-page-ready` | 检查 `Config.pagesEnabled` 是否为 `true`；看是否有 `pairing-page-failed`（`fields.phase`/`port`）；端口被占用时换 `pagesPort` 或设 `0` |
| 浏览器打不开页面 | 必须用 `http://127.0.0.1:<port>/` 或 `http://localhost:<port>/`；`localhost` 若解析到 `::1`，改用 `127.0.0.1` |
| 二维码扫不出 | 直接复制明文链接；超长 origin（长域名）可能超出内置编码器容量，页面会降级成「二维码没有生成，请直接复制链接」 |
| 页面显示「当前没有打开的配对窗口」 | 窗口单次有效：已被消费或已过期 → 点「重新打开配对窗口」（长期模式下配对成功会自动换新窗口，见 §3.5） |
| 长期模式下配对成功后二维码没更新 | 页面 2 s 轮询会自动刷新；看宿主日志 `pairing-window-reopened-longterm`；也可通过控制 API `POST /api/pair` 主动重开 |
| 控制 API 返回 403 `control-header-required` | `POST /api/pair`、`POST /api/devices/revoke` 必须带 `x-dsh-pairing-control: 1`；`GET /api/state`、`GET /qr.svg` 不需要 |
| `GET /qr.svg` 返回 404 | 当前没有打开的窗口（未开/已过期/已消费）→ 先重开窗口；查询串不影响结果 |
| 长窗口页面不显示倒计时了 | 剩余时间超过 1 小时时页面按设计只显示「长期有效」与真实过期时间，不显示秒级倒计时 |
| 点撤销没反应/没有撤销按钮 | 只有「有效」设备有按钮；303 刷新后看设备状态与宿主日志 `pairing-page-action` |
| 访问返回 403 | 用的不是回环主机名，或端口与实际绑定端口不一致；本页只服务 `127.0.0.1`/`localhost` |
| 4780 被其它程序占用 | `pagesPort` 换一个（或 `0` 随机）；页面失败不影响配对与远程连接 |
| 想在没有浏览器的机器上看配对信息 | 页面只是增强能力：终端日志与 TTY 二维码（`writePairingQr`）仍然可用 |

## 7. 验证

### 7.1 本任务跑过的（原样摘录，2026-11-17）

- `node --import tsx/esm apps/remote-host/scripts/pairing-page-selfcheck.ts` → `PASS 30/30 项全部通过（页面/JSON/QR 契约 + 控制 API + Host/CSRF/CORS 防护 + 生命周期降级）`
- `node --import tsx/esm apps/remote-host/scripts/pairing-longterm-selfcheck.ts` → `PASS 8/8 项全部通过（TTL 上限 + pairingLongTerm 自动续开 + 二维码导出）`
- `node --import tsx/esm apps/remote-host/scripts/qr-selfcheck.ts` → `PASS 16/16 项全部通过（矩阵 KAT + 结构 + 独立回读 + 渲染）`
- `pnpm exec tsc -p apps/remote-host/tsconfig.json` → exit 0
- `pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts` → `PASS 14/14 项全部通过`（wss/TLS/配对/撤销协议行为无回归）

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

# 2) JSON 状态：host / pairing 四字段 / devices；关闭时 pairing 四字段全 null
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

# 6) 控制面 API（设备互联插件的调用形态）：QR SVG + 重开窗口 + 撤销
curl.exe -s -D - -o qr.svg http://127.0.0.1:4780/qr.svg | Select-String 'HTTP/|Content-Type|Cache-Control'  # 200 image/svg+xml; no-store
curl.exe -s -X POST -H "x-dsh-pairing-control: 1" http://127.0.0.1:4780/api/pair | ConvertFrom-Json   # state JSON，pairing.open=true 且换新 token
curl.exe -s -o NUL -w "%{http_code}`n" -X POST http://127.0.0.1:4780/api/pair                          # 403 control-header-required
curl.exe -s -X POST -H "x-dsh-pairing-control: 1" -H "Content-Type: application/json" -d "{\"deviceId\":\"$id\"}" http://127.0.0.1:4780/api/devices/revoke | ConvertFrom-Json   # state JSON，devices[].revokedAt
```

浏览器侧验收（对应评估 §1.2）：打开页面 → 手机扫码配对成功 → 设备列表出现该设备 → 点「撤销」→ App 提示被撤销、宿主自动重开窗口、页面刷新出新二维码 → 倒计时归零后显示「窗口已过期」。截图按 §2 命名保存。

## 8. 未做项 / 已知边界

1. **截图未拍**（§2）；需在真实宿主 + 浏览器环境补验收图。
2. **设备在线状态未展示**：评估 §1.2 建议设备行带 online，需要宿主把当前绑定连接暴露出来（`server.ts` 的连接表）；本任务不改 `server.ts`，页面只展示 `lastSeenAt`。如需在线状态，后续在 `RemoteHostHandle.pages().devices()` 里补字段。
3. **无 SSE/WebSocket**：页面 2 s 轮询 `/api/state`；数据量小，即使长期窗口也用轮询，避免新增推送通道（本机插件同样轮询）。
4. **页面中文单语**：宿主内嵌页不属于 `packages/client` 的 locale 字典体系（评估 §1.2 风险①），v1 只做中文；若以后要双语，需要 lead 决定文案归属。
5. **页面不写配置**：只展示 UDP 发现状态，不提供开关；`Config` 一律从 cordis.yml 改（长期模式同样由配置决定，页面不发明开关）。
6. **重开窗口会按既有行为打印终端二维码并写含 token 的既有日志**（§4.7 注意）；这是复用 `remoteHost.pair()` 的预期行为，不是页面日志。
7. **Node 24 缺 Host 直接 400**：HTTP/1.1 无 `Host` 的请求在 Node 层就被拒绝，页面的 Host 校验是第二道；HTTP/1.0 无 Host 走到页面校验回 403。
8. **长期模式不会主动续期到期的窗口**：自动续开只发生在配对成功后；窗口到期后要重启宿主或用控制面 `POST /api/pair` 重开（刻意不做定时器续期，避免无人值守时无限期开放配对入口）。
9. **`longTerm` 不放进 `/api/state`**：控制面客户端（设备互联插件）自己写 `pairingLongTerm`，UI 文案由它按配置决定；宿主只如实返回窗口状态与真实 `expiresAt`。
10. **`/qr.svg` 跨源 `<img>` 只能显示不能读**：插件设置页可以用它展示二维码，但不能通过 canvas 读回内容；需要文本时用 `/api/state` 的 `pairing.pairUrl`。

## 9. 代码地图

| 文件 | 职责 |
|---|---|
| `apps/remote-host/src/pairing-page.ts` | 本页全部：回环 HTTP 服务、页面/JSON/SVG 渲染、控制 API（`/api/state`、`/api/pair`、`/api/devices/revoke`、`/qr.svg`）、Host/Origin/CSRF/控制头/CSP 防护、启停与降级；导出 `renderQrSvg` / `renderPairingQrSvg` |
| `apps/remote-host/src/pairing.ts` | 一次性配对窗口、`MAXIMUM_PAIRING_TTL_MS`（90 天）、对端限速、`pairUrl` |
| `apps/remote-host/src/index.ts` | Config `pagesEnabled`/`pagesPort`/`pairingTtlMs`/`pairingLongTerm`、`RemotePairingTicket.usbPairUrl`、`handle.pages()` 数据源、长期配对 `withLongTermPairingReopen`、`apply()` 装配与 effect 清理；包根导出 `renderPairingQrSvg` |
| `apps/remote-host/scripts/pairing-page-selfcheck.ts` | 30 项零依赖自检（真实回环 HTTP + 内存假数据源） |
| `apps/remote-host/scripts/pairing-longterm-selfcheck.ts` | 8 项零依赖长期配对自检（TTL 上限、Config、自动续开组合函数、二维码导出） |
| `apps/android/docs/remote-dsh/pc-pairing-page.md` | 本文 |
