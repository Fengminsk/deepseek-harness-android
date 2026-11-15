# 远程 DSH · 局域网自动发现（UDP 发现协议 v1）

状态：协议 v1（2026-11-16）。读者：实现 App 侧「找到电脑」的工程师、排查「手机发现不到电脑」的用户。
上位文档：[HANDOFF.md](HANDOFF.md)；wss 线上协议唯一来源：[protocol.md](protocol.md)；外网/反代接入：[reachability.md](reachability.md)。
宿主实现：`apps/remote-host/src/discovery.ts`；宿主装配：`apps/remote-host/src/index.ts`；自检：`apps/remote-host/scripts/discovery-selfcheck.ts`（11/11 PASS）。

**一句话结论**：手机在同一网段广播一帧 UDP 探测，宿主单播回「我是谁、当前配对链接是什么」。发现只是把**已有的配对链接**递给手机，省掉扫码与粘贴；它不建立信任、不改配对语义——配对仍然走 [protocol.md](protocol.md) §2 的一次性令牌流程。

---

## 0. 结论先行

| 项 | 结论 |
|---|---|
| 解决什么 | 免手输：手机自动找到正在开配对窗口的 DSH 宿主，直接拿到配对链接 |
| 不解决什么 | 不建立信任、不自动配对、不能连 wss；发现到的电脑 ≠ 已配对设备 |
| 端口 | UDP **4778**（`Config.discoveryPort` 可改；`Config.discoveryEnabled` 默认 `true`） |
| 依赖 | **零新增 npm 依赖**：只用 `node:dgram`，App 侧只用平台自带 UDP API |
| 适用范围 | 同一局域网/网段；跨网段与公网不广播（见 §7） |
| 关闭方式 | `config.discoveryEnabled: false`；关掉后扫码/粘贴照常可用 |
| 不做 | mDNS/Bonjour（理由见 §1）、自动授权、发现即连接、公网穿透 |

---

## 1. 为什么用自定义 UDP 发现，不用 mDNS/Bonjour

mDNS 是局域网发现的常见做法，本仓库明确不采用，理由按重要性排列：

1. **零依赖**：mDNS 需要 `multicast-dns` / `bonjour-service` 一类依赖，或 Android 侧的 `NsdManager` 插件；本方案只用 `node:dgram` 与 App 自带的 UDP 能力，宿主侧新增代码约 520 行、可完整自检。
2. **语义不同**：mDNS 的 TXT/SRV 记录是静态广播，而这里的应答必须**按探测现取**——只有配对窗口打开时才带链接、窗口一关立刻只回 `{open:false}`、同一来源还要限速。自定义一问一答比把动态状态塞进 mDNS 记录更直接，也不会被缓存污染。
3. **设备兼容**：Android 的 mDNS 解析受 ROM、AP 客户端隔离、组播过滤影响大；部分国产 ROM 会把组播包丢掉。单播应答（探测广播 → 宿主单播回）对网络设备的要求更低。
4. **规模**：发现只承载「一两台电脑」的信息量，不需要服务目录、txt 属性、IPv6 双栈、缓存与 TTL 语义。

代价是 App 与宿主必须共享一份字段约定——就是本文档。发现**不是唯一连接路径**：任何异常都应退回扫码/粘贴配对链接，而不是把「发现失败」当成连不上。

---

## 2. 协议 v1

### 2.1 传输层

| 项 | 规定 |
|---|---|
| 协议 | UDP（IPv4 / `udp4`），一问一答，无会话、无重传 |
| 宿主绑定 | `0.0.0.0:<discoveryPort>`，默认 4778 |
| 探测方向 | App 广播（或单播）到 `255.255.255.255:4778`；个别路由器拦全局广播时改发子网广播（如 `192.168.5.255:4778`） |
| 应答方向 | 宿主**单播**回探测来源的地址与端口（不是广播） |
| 编码 | 单帧 UTF-8 JSON，无换行、无 BOM |
| 大小 | 探测帧 ≤ 512 字节；应答实测最坏 866 字节（≤ 1400 字节上限，单包不分片） |
| TTL | 出站 TTL=1；App 发送时也应设 TTL=1（探测不跨路由） |
| 端口冲突 | 发现端口与 wss 端口（TCP 4777）互不冲突；不同进程可各占其一 |

### 2.2 探测帧（App → 宿主）

```json
{ "v": 1, "probe": "DSH-REMOTE-DISCOVER", "nonce": "3Jk9xQ2mP0aZ" }
```

| 字段 | 类型 | 必填 | 约束 | 说明 |
|---|---|---|---|---|
| `v` | number | 是 | 必须精确等于 `1` | 协议版本 |
| `probe` | string | 是 | 必须精确等于 `"DSH-REMOTE-DISCOVER"` | 协议标记 |
| `nonce` | string | 是 | 4–128 个 `[A-Za-z0-9_-]` 字符 | 每次探测随机生成（建议 16–32 字节随机值），宿主原样回显 |

`DSH-REMOTE-DISCOVER/1` 是 `probe` + `"/"` + `v` 拼出的**协议字面量**，用于文档与代码命名；它不是线上帧文本。只发这个字符串、发非 JSON、发数组、版本不符、缺字段、`nonce` 越界、超过 512 字节的帧，宿主一律**静默丢弃**（不回包，见 §3）。

### 2.3 应答帧（宿主 → App，单播）

配对窗口打开时：

```json
{
  "v": 1,
  "kind": "dsh-remote-host",
  "name": "DESKTOP-DCVQRNS",
  "origin": "wss://192.168.5.21:4777",
  "instanceId": "<64 位小写十六进制>",
  "pairing": {
    "open": true,
    "pairUrl": "wss://192.168.5.21:4777#instance=<64 hex>&token=<43 字符>",
    "expiresAt": 1763433600000
  },
  "nonce": "3Jk9xQ2mP0aZ"
}
```

配对窗口关闭（未打开、已消费、已过期）时 `pairing` 换成：

```json
{ "open": false }
```

| 字段 | 类型 | 出现条件 | 说明 |
|---|---|---|---|
| `v` | number | 总是 | 固定 `1` |
| `kind` | string | 总是 | 固定 `"dsh-remote-host"`；App 用它排除同端口上的其它服务 |
| `name` | string | 总是 | 宿主显示名（= 握手 `host.name`，≤ 120 字符） |
| `origin` | string | 总是 | 对外宣告的 `wss://host[:port]`（与配对链接/日志一致） |
| `instanceId` | string | 总是 | 64 位小写十六进制，等于宿主 CA 证书 sha256（protocol §2 的信任判据） |
| `pairing.open` | boolean | 总是 | 配对窗口此刻是否打开 |
| `pairing.pairUrl` | string | 仅 `open:true` | 完整配对链接，与 PC 日志/终端二维码里的是**同一条** |
| `pairing.expiresAt` | number | 仅 `open:true` | 窗口关闭时间（Unix 毫秒） |
| `nonce` | string | 总是 | 探测帧 `nonce` 原样回显 |

应答字段集合固定为上面 7 个顶层键；App 必须忽略未来新增的不认识字段（版本不变时的前向兼容）。字段值不合法（例如 `v` 不是 1、`kind` 不符、`nonce` 不匹配）的应答一律丢弃。

### 2.4 App 侧判定规则

1. 收到满足 `v === 1 && kind === "dsh-remote-host" && nonce 是自己刚发的` 的应答 → 记为「发现一台宿主」，按 `instanceId` 去重。
2. `pairing.open === true` → 直接把 `pairing.pairUrl` 交给现有配对流程（与粘贴/扫码解析同一条链接，见 `apps/android/lib/remote_pairing.dart`）。
3. `pairing.open === false` → 展示「已找到电脑 <name>，但配对窗口未打开」，提示在电脑上重新打开配对窗口（PC 侧 `remoteHost.pair()`，或重启宿主）。
4. 建议探测节奏：首次探测后 2 s、4 s 各重试一次（共 3 次），仍无应答则给出「没有发现同网段的电脑」+ 扫码/粘贴入口。不要无限广播。
5. 多台宿主返回时列表展示（`name` + `instanceId` 前 8 位），由用户选择。
6. **不要**在 App 日志、崩溃上报里记录 `pairUrl`（内含一次性配对令牌）。

### 2.5 版本策略

`v` 必须精确等于 1；不认识的版本静默丢弃。未来 v2 的兼容方式是：宿主可同时应答 v1，或在 App 侧按 `v` 分支；任何不行的情况都退回扫码，发现不是连接的唯一手段。

---

## 3. 安全边界

### 3.1 发现 ≠ 信任

发现给的是一条**配对链接**，不是设备令牌，也不是已建立的信任：

- 链接里的令牌是 `pairing.ts` 的一次性配对令牌，兑换仍需 `POST /pair` 且受单次有效、对端限速、窗口过期约束；
- 配对成功后 App 才拿到设备令牌，再走 wss + 固定 CA 的握手（protocol §2/§3）；
- 发现结果**不能**连上宿主，也不能读设备表、会话或文件；
- 一个被篡改/伪造的发现应答最多让 App 尝试连接错误的地址：App 会拿 `GET /ca.cer` 的证书 DER 算 sha256，必须等于 `pairUrl` 里的 `instanceId` 才会固定该 CA；伪造者拿不到宿主私钥，配对必然失败。

### 3.2 应答里有什么、没有什么

| 会出现在应答里 | 绝不会出现在应答里 |
|---|---|
| 宿主显示名 `name` | 设备令牌、设备列表、deviceId |
| `wss` origin | DSH 数据（会话、文件、设置） |
| instanceId（CA 指纹，本来就在配对链接/二维码里） | 宿主文件系统路径、用户名、日志 |
| 配对链接（仅窗口打开时） | 任何长期凭据 |

### 3.3 只有配对窗口打开时才给链接

- 宿主每次应答都**现取快照**：`pairing.open=true` 当且仅当此刻有未消费、未过期的窗口；
- 配对成功（`POST /pair` 兑换）后立刻作废当前票据，下一次探测只回 `{open:false}`；
- 重新打开窗口（启动、`remoteHost.pair()`、撤销设备后自动重开）会生成新链接，发现应答随之更新；
- 不做应答缓存，窗口关闭后不存在「旧链接还挂在缓存里」的窗口期。

### 3.4 限速与坏帧

| 约束 | 实现 |
|---|---|
| 按来源地址限速 | 同一来源地址 **1 s 内只应答 1 次**；窗口外的探测静默丢弃 |
| 来源表上限 | 最多跟踪 256 个来源地址；表满后新来源一律不应答（失败关闭，不无限记账） |
| 坏帧不回包 | 非 JSON、版本不符、缺字段、`nonce` 越界、超过 512 字节的帧全部静默丢弃，避免成为 UDP 放大反射点 |
| 坏帧不消耗配额 | 限速只在**合法探测**上计数，坏帧不会挤掉真实手机的探测 |
| TTL=1 | 出站不跨路由；探测方也应以 TTL=1 广播 |

### 3.5 局域网明文暴露（必须知道）

配对窗口打开期间，**同网段的任何设备**都可能探测到宿主并拿到配对链接，从而给自己配对。这是「免手输」的直接代价，缓解手段：

- 配对窗口保持短（产品默认 120 s、单次有效）；只在真的要配对时让窗口开着；
- 不信任的公共 Wi-Fi / 客户网络里关掉 `discoveryEnabled`，改用扫码或粘贴链接；
- **不要**在路由器/防火墙上把 UDP 4778 映射到公网；
- 发现关闭不影响 wss、配对与已配对设备的连接。

### 3.6 已知的协议层限制

- **入站 TTL 无法验证**：`node:dgram` 不向应用暴露收到的数据报 TTL，所以宿主无法证明探测确实来自本网段。这不改变安全结论（应答不含长期凭据，且窗口本身是用户主动打开的），「只在本网段可用」靠网络层保证（TTL=1 + 不映射公网）。
- **发现端口无认证**：任何同网段设备都能发探测。限速+坏帧静默把资源占用压到最小（每个来源 1 包/秒，不回包）。
- **广播依赖网络设备**：AP 客户端隔离、Guest Wi-Fi、部分企业网络会拦广播；这种情况只能扫码/粘贴。

---

## 4. 宿主侧实现

### 4.1 文件与接口

| 对象 | 位置 | 说明 |
|---|---|---|
| `DiscoveryResponder` | `apps/remote-host/src/discovery.ts:197` | 绑定 UDP 端口、解析探测、限速、拼应答 |
| `DiscoverySnapshot` | `apps/remote-host/src/discovery.ts:79` | 每次应答现取：`{name, origin, instanceId, pairing?}` |
| `DiscoverySocket` | `apps/remote-host/src/discovery.ts:109` | 只含 8 个动作的套接字表面，测试可注入假实现 |
| `DiscoveryStart` | `apps/remote-host/src/discovery.ts:186` | `{listening:true, port}` 或 `{listening:false}`，失败不抛错 |
| 配置 | `apps/remote-host/src/index.ts:128-147` | `discoveryEnabled`（默认 true）、`discoveryPort`（默认 4778） |
| 装配 | `apps/remote-host/src/index.ts:560-664` | 打开初始配对窗口后再启动发现；卸载时先停发现再关窗口与监听 |

`DiscoveryResponder` 的构造参数（全部可注入）：

| 参数 | 默认 | 用途 |
|---|---|---|
| `port` | 必填 | UDP 端口；`0` 交给系统分配（自检/本地调试） |
| `host` | `0.0.0.0` | 绑定地址 |
| `ttl` | `1` | 出站 TTL |
| `rateLimitMs` | `1000` | 同来源最小应答间隔 |
| `maximumTrackedPeers` | `256` | 来源表上限（失败关闭） |
| `clock` | `Date.now` | 时钟；自检用假时钟验证限速 |
| `snapshot` | 必填 | 当前快照提供者（见 4.3） |
| `log` | `writeRemoteLog` | 结构化日志 |
| `socketFactory` | 真实 `udp4` | 套接字工厂；注入假套接字覆盖失败路径 |

### 4.2 配置示例

`cordis.patch.yml` 或用户覆盖层（`Config` 由 schemastery 校验，越界值加载期失败）：

```yaml
- id: remote-host
  config:
    enabled: true
    discoveryEnabled: true      # 默认 true
    discoveryPort: 4778         # 默认 4778；0 = 系统分配（仅调试）
    publicHost: 192.168.5.21    # 多网卡机器显式指定局域网地址
```

### 4.3 装配时序（为什么快照这么取）

1. wss 服务器 `start()` → 得到 `origin`（`publicOrigin` 或自动选路）；
2. 打开**初始配对窗口**，把链接写日志（+ TTY 下画二维码），同时把票据记进 `currentPairing`；
3. 用 `currentPairing` + 身份 + origin 构造 `snapshot`，启动 `DiscoveryResponder`——所以第一帧发现应答拿到的就是**此刻可用**的链接；
4. 快照规则：`pairing` 仅在 `currentPairing` 存在且 `expiresAt > now` 时给出；`POST /pair` 兑换成功后立刻清空 `currentPairing`（装配层包了一层 `redeem`，不涉及 `pairing.ts` 语义）；
5. 卸载/停止：先 `discovery.stop()`，再 `pairing.close()`，最后 `server.stop()`，避免关闭过程中还有探测读到半关状态。

### 4.4 日志事件（沿用 `remote-host` logger）

| event | level | 何时 | 关键 fields |
|---|---|---|---|
| `discovery-listening` | info | UDP 端口绑定成功 | `port`、`address`、`ttl` |
| `discovery-failed` | warn | 绑定失败（端口占用/权限）；监听期套接字错误；单帧发送失败 | `port`、`address`、`phase`（`bind` / `runtime` / `send`）、`error` |
| `discovery-disabled` | info | `discoveryEnabled: false` | — |

没有 per-probe 日志：同网段探测会把日志刷满；排障看上面三条 + 端口占用命令（§5）。

### 4.5 失败语义

- 端口占用/权限不足：**只写一条 warn，宿主照常启动**，wss、配对、已配对设备全不受影响（自检第 11 项）；
- 不自动重试：端口释放后需要重启宿主才会重新监听（当前明确不做重试循环）；
- 单帧发送失败（例如探测方已关闭 socket）：记录 warn，不影响后续探测；
- `stop()` 幂等；`unref()` 让 UDP 套接字不阻塞宿主进程退出。

---

## 5. Windows 防火墙与网络前提

### 5.1 必须满足

1. 手机与 PC 在**同一网段**（例如都在 `192.168.5.0/24`）；
2. Windows 防火墙允许该进程的 **UDP 4778 入站**，且网络配置文件是「专用网络」；
3. 路由器/AP 未开启客户端隔离（AP isolation / guest network 隔离）；
4. 宿主真的在监听：宿主日志里有 `discovery-listening`。没启用发现时是 `discovery-disabled`。

### 5.2 只读诊断命令（不会改防火墙）

```powershell
# 宿主是否真的占用 UDP 4778（有输出 = 在监听）
Get-NetUDPEndpoint -LocalPort 4778 | Select-Object LocalAddress,LocalPort,OwningProcess

# 查看已存在的入站 UDP 规则（没有就说明还没放行过）
Get-NetFirewallRule -Direction Inbound -Enabled True |
  Where-Object { $_.DisplayName -like '*node*' -or $_.DisplayName -like '*DSH*' } |
  Select-Object DisplayName,Action,Profile
```

Windows 首次让一个程序监听 UDP 端口并收到外部包时会弹「允许访问」提示；选择**专用网络**即可。若当时点了取消，需要用户自己在「Windows 安全中心 → 防火墙 → 允许应用通过防火墙」里补一条 UDP 入站规则——这属于用户/部署决策，安装器不代改防火墙。

### 5.3 自测与真机验证的分工

- **本机自测（不需要防火墙）**：回环单播 `127.0.0.1:<discoveryPort>`（默认 4778；本机演练用过 4798），协议与限速都能验证（见 §9 与自检脚本）；
- **PC 本机广播自测**（不需要放行防火墙，但**证明不了**防火墙已放行）：Windows 会把本机发出的
  广播回送给本机监听者，因此下面这段能验证「宿主在应答、字段正确」，却验证不到「手机的包能进
  本机」——入站防火墙与 AP 隔离只对其它设备生效：

  ```powershell
  $udp = [System.Net.Sockets.UdpClient]::new()
  $udp.EnableBroadcast = $true
  $udp.Client.ReceiveTimeout = 2000
  $payload = [Text.Encoding]::UTF8.GetBytes('{"v":1,"probe":"DSH-REMOTE-DISCOVER","nonce":"lead-check-0001"}')
  [void]$udp.Send($payload, $payload.Length, [System.Net.IPAddress]::Broadcast, 4778)
  $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
  [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$remote))
  $udp.Dispose()
  ```

- **真机验证（唯一能证明防火墙/AP 没问题的方式）**：手机广播 → 宿主单播应答（App 侧发现 UI 落地后，
  或临时用手机端脚本发同一帧 JSON）。若手机收不到，先按 §5.2 确认宿主在监听，再确认防火墙与
  AP 隔离；不要为了自测改防火墙设置。

### 5.4 双网卡 / VPN

这台开发机的默认路由走 VPN（`172.30.x`），但发现端口绑定在 `0.0.0.0`，入站广播不受默认路由影响；配对链接里的地址仍由 `publicHost` 或默认路由决定（与发现无关）。多网卡机器上若手机与 PC 实际不在同一网卡，请用 `publicHost` 指定局域网地址。

---

## 6. 排障表

| 现象 | 可能原因 | 怎么确认 | 处理 |
|---|---|---|---|
| 手机一直「没有发现电脑」 | 防火墙未放行 UDP；不同网段；AP 隔离；`discoveryEnabled: false`；端口被占 | 宿主日志 `discovery-listening` / `discovery-disabled` / `discovery-failed`；§5.2 端口检查 | 放行专用网络 UDP；回同一 Wi-Fi；关 AP 隔离；打开发现；重启宿主 |
| 宿主日志 `discovery-failed`（`phase: bind`） | 4778 被别的程序占用，或无权限 | §5.2 看 4778 的 OwningProcess | 结束占用进程，或把 `discoveryPort` 换成空闲端口（需同时改 App 侧扫描端口） |
| 找到电脑但提示「配对窗口未打开」 | `pairing.open=false`（窗口未开/已消费/已过期） | 宿主日志 `pairing-window-opened` / `device-issued` | 在 PC 上重新打开配对窗口（`remoteHost.pair()` 或重启宿主） |
| 拿到链接但配对失败 403 | 窗口已过期/已被别的设备用掉 | 宿主日志 `device-issued` | 重新打开窗口；重新探测拿新链接 |
| 拿到链接但 TLS/CA 校验失败 | 应答被伪造，或 PC 换了 CA（instanceId 变了） | 对比日志里的 `instanceId` 与 App 显示的 | 重新探测/重新配对；不要绕过固定 CA |
| 只有一台手机能发现，另一台不行 | 该手机不在同网段/VPN 回程/系统限制后台 UDP | 手机网络信息 | 连同一 Wi-Fi；前台重试 |
| `discovery-listening` 有、真机仍不通 | 防火墙未放行，或广播被路由器丢 | §5.2；同网段 PC 另一台设备互测 | 用户自行放行/换网络 |

---

## 7. 与扫码、反代、外网的关系

| 场景 | 发现有用吗 | 说明 |
|---|---|---|
| 同 Wi-Fi 局域网 | **有用** | 手机自动拿到配对链接，直接进入配对 |
| 扫码 / 粘贴配对链接 | 无关 | 二维码与发现返回的是**同一条** `pairUrl`；发现失败就用二维码/粘贴 |
| 外网 / 反代 / Tailscale（[reachability.md](reachability.md)） | 无用 | 广播不跨网段、不穿公网；这类部署仍用配对链接/扫二维码。发现不改变 TLS 固定 CA 与协议要求 |
| 已配对设备重连 | 无关 | 自动重连走 App 本地设备表 + wss，不经过发现 |

发现**不会**打开配对窗口、不会自动信任、也不会把「发现到的电脑」写进已配对设备表。

---

## 8. App 侧实现约定（另一个任务）

App 侧只做「探测 → 展示 → 把链接交给现有配对流程」，不改 wss 协议：

1. **发送**：UDP socket（Android `DatagramSocket`），目标 `255.255.255.255:4778`；失败再试子网广播（如 `192.168.5.255:4778`）；TTL=1。需要 `INTERNET` 权限（App 已有），不需要 `WifiManager`/位置权限（不做 Wi-Fi 扫描、不用组播）。
2. **探测内容**：`JSON.stringify({v:1, probe:'DSH-REMOTE-DISCOVER', nonce})`，`nonce` 4–128 个 base64url 随机字符（建议 16–32 字节随机值）；UTF-8 编码。
3. **接收**：同一 socket 收单播应答（来源端口是宿主的 4778，来源地址是宿主 IP）；`nonce` 不匹配、`v`/`kind` 不符、超 1400 字节的包丢弃。
4. **展示**：`open:true` → 「发现电脑 <name>」+ 直接配对；`open:false` → 「已找到电脑 <name>，配对窗口未打开」；无应答 → 保留扫码/粘贴入口。
5. **安全**：把发现结果当**提示**而不是信任——`pairUrl` 必须走既有配对流程（取 `/ca.cer` 校验 instanceId）；不在日志里记录 `pairUrl`/token。
6. **测试**：真机与 PC 同 Wi-Fi；宿主日志应出现 `discovery-listening` 与 `device-issued`（配对成功时）。

---

## 9. 自检与验证证据（2026-11-16 本机）

| 验证 | 命令 | 结果 |
|---|---|---|
| 发现自检 | `node --import tsx/esm apps/remote-host/scripts/discovery-selfcheck.ts` | **11/11 PASS**（协议字段、窗口关闭、坏帧、限速恢复、stop/start、假套接字 TTL/unref、最坏长度 866 B 单包、端口占用降级） |
| 宿主类型检查 | `pnpm exec tsc -p apps/remote-host/tsconfig.json` | exit 0 |
| host 聚合类型检查 | `pnpm exec tsc -p tsconfig.host.json` | exit 0 |
| 改动文件 lint | `pnpm exec oxlint apps/remote-host/src/discovery.ts apps/remote-host/src/index.ts apps/remote-host/scripts/discovery-selfcheck.ts` | 0 warnings / 0 errors |
| 宿主冒烟（无回归） | `pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts` | **14/14 PASS** |
| 真实宿主演练 | 独立端口 4797 / 发现端口 4798 + 独立 `DSH_HOME` | 回环探测得到与日志**同一条** `pairUrl`；`POST /pair` 成功后同一来源再探测 → `{open:false}`；100 ms 内两次探测只回 1 帧（限速）；4 种坏帧 0 应答；停止后 TCP/UDP 端口均释放 |

真实宿主演练日志（节选）：

```text
[remote-host] info listening: 远程宿主已就绪：wss://127.0.0.1:4797/app。…
[remote-host] info discovery-listening: 局域网发现已就绪：手机在同一网段内可以自动找到这台电脑（UDP 4798）。 {"port":4798,"address":"0.0.0.0","ttl":1}
→ {"v":1,"kind":"dsh-remote-host","name":"DESKTOP-DCVQRNS","origin":"wss://127.0.0.1:4797",…,"pairing":{"open":true,"pairUrl":"…token=Hza8…","expiresAt":1794767433673},"nonce":"probe-nonce-01"}
[remote-host] info device-issued: 配对成功，已签发设备令牌…
→ {"v":1,…,"pairing":{"open":false},"nonce":"probe-after-pair"}
```

真机阶段（lead 执行）：重启 4777 宿主后用真机 App 广播探测，确认手机能发现并直接配对；若收不到，按 §5 检查防火墙/网段，不改防火墙配置换用回环自测即可复现协议结论。

---

## 10. 已知限制与后续

1. **不自动重试绑定**：发现端口被占用时宿主记 warn 后继续运行，释放端口后需重启宿主。
2. **不做 mDNS/Bonjour**：理由见 §1；未来若引入，应作为**额外**发现通道，不能替换本文协议或改变信任语义。
3. **入站 TTL 不可验证**：见 §3.6；依赖网络层（TTL=1 + 不映射公网）。
4. **广播不可靠**：AP 隔离/Guest Wi-Fi/部分企业网络会拦广播，扫码/粘贴必须一直可用。
5. **发现端口只有一对一 v1**：未来若需要「宿主动态端口」「多协议版本协商」，在本文档加 v2 章节并同时保留 v1 应答。
6. **App 侧发现 UI 尚未实现**（另一个任务）：契约见 §8；宿主侧已可用自检与真实宿主验证。

---

## 11. App 侧实现（2026-11-16，task-18）

§8 的契约已由 App 实现，入口在「添加连接」页的「搜索局域网」：

- 实现：`apps/android/lib/remote_discovery.dart`（零 Flutter 插件依赖，只用 `dart:io`）。
  - 发送：`RawDatagramSocket`（绑定 `0.0.0.0:0`），`broadcastEnabled = true`，发往
    `255.255.255.255:4778`，另按本机每个非回环 IPv4 的 `/24` 猜测子网广播
    （`x.y.z.255`；Dart 不暴露子网掩码，猜错的目标不会有副作用）；出站 TTL=1
    （`RawSocketOption`，不支持的内核静默忽略）。
  - 接收：同一套接字收单播应答；单帧 > 1400 B、非 JSON、`v`/`kind`/`nonce` 不符、
    `instanceId` 非 64 位小写十六进制、`origin` 非 `wss://host[:port]`、`pairing` 字段
    不合法、`pairUrl` 过不了 `PairingDescriptor.parse` 或其中的 instanceId 与顶层不一致
    → 整帧丢弃（本机探针帧不匹配应答形状，因此天然被忽略）。
  - 去重：按 `instanceId`（同一台电脑可能从多网卡回多个包；按名称或来源去重会重复展示）。
  - 窗口：默认 2.5 s；窗口内 1 s 时再发一帧降低 UDP 丢包；窗口结束立刻关闭套接字，
    没有后台轮询。
  - 失败：绑定失败 → `discovery/socket`；全部发送失败且无应答 → `discovery/send`；
    页面展示中文原因并保留扫码/粘贴入口。
- UI（`apps/android/lib/remote_pairing_page.dart`）：
  - 懒加载：只有切到「搜索局域网」或点「重新搜索」才调用 `discover()`，不在 `initState`
    启动，页面静置无 UDP 流量（60 fps 门禁）；
  - `pairing.open=true` → 行内「连接」直接用 `pairUrl` 走既有配对流程；
  - `pairing.open=false` → 「配对窗口未打开。请在电脑上重新打开配对窗口后重试」+ 重新搜索；
  - 空结果 → 同网段/防火墙/UDP 4778/AP 隔离说明 + 扫码、粘贴回退；
  - 发现结果只当提示：不写设备表、不自动连接；伪造应答会在 CA 指纹校验处失败，
    不改变 §3.1 的信任结论。
- 测试：`apps/android/test/remote_discovery_test.dart`（解析/坏帧/nonce/去重/超时/
  dispose/绑定失败/重入）与 `apps/android/test/remote_pairing_methods_test.dart`
  （懒加载、列表三态、手动地址、扫码入口保留）。
- 仍不做：mDNS、自动配对、跨网段发现；App 侧发现端口先固定 4778（宿主侧可配，
  后续需要时再加 App 设置项）。§10.6 的「App 侧发现 UI 尚未实现」由本节覆盖。
