# 远程 DSH · 局域网之外怎么连（可达性）

状态：v1 适用（2026-11-16）。读者：想从外网用手机连自己 PC 的用户、给远程宿主接入反代/组网的运维。
上位文档：[remote-dsh-plan.md](../remote-dsh-plan.md) §5.7 可达性阶梯；协议细节唯一来源：[protocol.md](protocol.md)；接力状态：[HANDOFF.md](HANDOFF.md)。

**一句话结论**：默认只接受「手机直连宿主自己的 TLS 端点」（固定宿主 CA）。所以外网访问的默认做法是——① 把手机和 PC 放进同一个私有网络（Tailscale/WireGuard）后直连；② 用户自有的 **TCP 直通**（L4）反代或隧道把 4777 原样搬到公网，TLS 全程由宿主自己做。**在中间终止 TLS 的做法（Cloudflare Tunnel、Caddy/nginx 的 HTTPS 反代、Tailscale Serve/Funnel、ngrok 默认模式）在默认入口下会因固定 CA 校验失败**；2026-11-16 起 App 另有一个显式的「HTTPS 反代」配对入口（§3.7），在你自己控制反代、后端只有我们的宿主、域名证书由公网 CA 签发的条件下支持这种链路——它用系统根证书验证反代证书，并继续用 `/ca.cer` 指纹绑定电脑身份，默认入口不会自动切过去。

---

## 0. 结论先行

| 做法 | v1 可用 | 代价 | 推荐度 |
|---|---|---|---|
| 局域网直连（现状） | 可用 | 只能在同一个 Wi-Fi | 默认 |
| **A. Tailscale / WireGuard 组网后直连** | **可用** | PC 与手机各装一个客户端、登录同一网络；手机需常开 VPN | **首选**：不暴露公网、不改宿主、TLS 端到端 |
| **A'. 自有域名 + 公网 IP/端口转发（不终止 TLS）** | 可用 | 需要公网 IPv4 或 IPv6、DNS、路由器端口映射 | 次选（对固定线路很干净） |
| **B. 自有反代/隧道，TCP 直通** | 可用 | 一台公网机器（VPS）+ frp/rathole/nginx stream/HAProxy 等；公网入口暴露一个端口 | 能接受运维时可用 |
| C. TLS 终止型反代/隧道（Cloudflare Tunnel、HTTPS 反代、Tailscale Serve/Funnel、ngrok 默认） | 默认入口**不可用**；自有反代可走 **§3.7 HTTPS 反代入口** | 默认入口会直接破坏证书固定；§3.7 入口显式改用系统根证书验证反代证书，并要求反代可信、后端只有我们的宿主 | 仅在你控制反代且需要 HTTPS 域名时用 §3.7；否则优先 A/B |
| D. 「反代只转发 `/app` 路径」 | **不可用** | 与配对链接格式冲突，见 §1.4 | **不做** |
| E. 内建公网穿透/隧道管理 | 不做 | v1 明确交给用户自己的网络手段 | 不做（plan §9:440） |

选型只需回答一个问题：**公网入口那一跳会不会看到并替换 TLS 证书？** 不会 → 属于 v1 支持；会 → 不可用。

---

## 1. 现状：线上只有一个 TCP 端口、三种用途

### 1.1 端点与端口

| 用途 | 方法/协议 | 路径 | 证据 |
|---|---|---|---|
| 手机业务连接 | `wss://<host>:<port>/app` | 必须精确 `/app`，带查询串/其它路径一律 HTTP 404 | `apps/remote-host/src/server.ts:32`、`apps/remote-host/src/server.ts:413-415` |
| 取宿主 CA | `GET https://<host>:<port>/ca.cer` | 回 CA 证书 DER（`cache-control: no-store`） | `apps/remote-host/src/server.ts:35`、`apps/remote-host/src/server.ts:1385-1403` |
| 兑换设备令牌 | `POST https://<host>:<port>/pair` | JSON `{token, deviceLabel, appVersion}` → `{deviceId, deviceToken, expiresAt}` | `apps/remote-host/src/server.ts:38`、`apps/remote-host/src/server.ts:1415-1487` |
| 其它任何 HTTP 路径 | — | 404 | `apps/remote-host/src/server.ts:1350-1374` |

默认监听 `0.0.0.0:4777`，可配置；配对窗口默认 120 s、设备令牌默认 180 天（`apps/remote-host/src/index.ts:121-129`）。
一个端口同时是 https 与 wss：**配对和连接必须走同一个 `host:port`**（配对链接只有 host/port 两个字段，见 §1.3）。

### 1.2 一条连接上必须成立的四件事

1. **TLS 端到端由宿主自己做**。宿主进程用一张长期自签 CA + 一张 1 年期的服务器叶子证书起 https 服务器（`apps/remote-host/src/server.ts:1267`、`apps/remote-host/src/tls.ts:43-53`）。CA 证书 DER 的 SHA-256 就是宿主 `instanceId`（`apps/remote-host/src/tls.ts:350-367`）。
2. **手机固定这张 CA**。配对后 App 用 `SecurityContext(withTrustedRoots: false)` 只信任这张 CA 连 `/pair` 和 `wss /app`（`apps/android/lib/remote_pairing.dart`、`apps/android/lib/remote_transport.dart`）；叶子证书的主机名还必须与链接里的主机名一致（Dart `HttpClient` 默认做主机名校验，App 没有关）。例外只有取 CA 那一次：`/ca.cer` 用「先握手、后按响应体指纹判定」的 TOFU 方式。**另一个显式例外**是「HTTPS 反代」配对入口（§3.7）：该模式下 `/pair` 与 `/app` 用系统根证书验证反代出示的公网证书（含主机名），宿主 CA 仍通过 `/ca.cer` 响应体指纹绑定身份。
3. **`Origin` 必须逐字节等于 `https://pocket-harness.local`**，否则升级被 HTTP 403 拒绝（宿主常量 `apps/remote-host/src/server.ts:41`，校验在 `apps/remote-host/src/server.ts:1573-1582`；App 发出的就是该常量 `apps/android/lib/remote_transport.dart:207`、`apps/android/lib/remote_transport.dart:582-585`）。这是纵深防御，不是鉴权（protocol §2.3）。
4. **鉴权只在应用层**：升级头 `Authorization: Bearer <43 字符 base64url>`（`apps/remote-host/src/server.ts:65`、`apps/remote-host/src/server.ts:1583-1593`），令牌摘要用 `timingSafeEqual` 比对（`apps/remote-host/src/devices.ts:418` 起）；失败先在升级后回结构化错误再关闭 `4000`/`4001`（`apps/remote-host/src/server.ts:1683-1712`）。

### 1.3 配对链接的形态（决定了哪些网络形态可行）

```
wss://<host>:<port>#instance=<64 位小写 hex>&token=<43 字符 base64url>
```

- 生成 `apps/remote-host/src/pairing.ts:237-245`；`instance` 是 CA 指纹，`token` 单次有效。
- 端口省略时 App 按 **4777** 补（`apps/android/lib/remote_pairing.dart:34-35`、`apps/android/lib/remote_pairing.dart:163`）。
- **不接受路径前缀、查询串、账号信息**：链接带路径时 App 直接报「v1 只接受直连的 wss://\<host>:\<port>」（`apps/android/lib/remote_pairing.dart:148-158`）；宿主侧 `publicOrigin` 也拒绝路径（`apps/remote-host/src/index.ts:892-920`，错误文案「反向代理请用 TCP 直通」）。

### 1.4 为什么「反代只转发 `/app` 路径」不可行

- 路径反代意味着反代在 HTTP 层解析请求 → 它必须先终止 TLS → 手机看到的是反代的证书。默认入口的 App 只信宿主那张 CA，`/pair` 与 `/app` 都在 TLS 握手阶段失败（§1.2 第 2 条）。
- 即便证书问题被绕过，链接也不允许带路径前缀，App 解析阶段就会拒（§1.3）。
- 宿主没有「按路径放行」的配置：要么整个端口可达（宿主自己只实现 `/app`、`/ca.cer`、`/pair` 三个端点，其它一律 404），要么不可达。**默认入口下「只转发 /app」没有实现方式**；要做访问控制请在网络层做（§3.4、§6）。
- §3.7 的「HTTPS 反代」入口同样要求**整站转发**（`/ca.cer`、`/pair`、`/app` 三条端点都到同一台宿主）：只转发 `/app` 时配对第一步取 `/ca.cer` 就会失败。

---

## 2. 做法 A（首选）：组网后直连，TLS 端到端

把手机和 PC 放进同一个私有二层/三层网络，让手机用组网地址直接访问 PC 的 4777。好处是宿主配置几乎不动、公网零暴露、证书固定完全保留。

### 2.1 Tailscale / WireGuard（推荐）

最小步骤（以 Tailscale 为例；其它 WireGuard 组网同理）：

1. PC 安装 Tailscale 并登录自己的 tailnet，记下 PC 的组网地址：
   ```powershell
   tailscale ip -4        # 例：100.101.102.103
   ```
2. 手机安装 Tailscale 并登录**同一个** tailnet，打开 VPN 开关（Tailscale 会占用系统 VPN 槽位；手机同时只能有一个 VPN）。
3. PC 上的远程宿主不需要改任何网络配置：叶子证书的 SAN 自动覆盖本机所有非回环 IPv4（`apps/remote-host/src/index.ts:805-813`、`apps/remote-host/src/index.ts:423-427`）。**装完 Tailscale 后重启一次宿主**，让叶子按新的网卡集合重签（CA 不变，已配对手机不受影响，见 §5）。
4. 手机侧用宿主日志里的配对链接配对（扫码或粘贴，见 §7）。如果日志里的地址仍是局域网 IP，在宿主配置里显式指定组网地址后重启（等价于真机验收时用覆盖层 `publicHost` 的做法，见 HANDOFF §3.3）：
   ```yaml
   - id: remote-host
     config:
       enabled: true
       publicHost: 100.101.102.103
   ```
5. 想改用 MagicDNS 名字（`<machine>.<tailnet>.ts.net`）而不是 IP 时，必须写 `publicOrigin`（因为 `publicHost` 只影响链接里的地址，不参与证书 SAN）：
   ```yaml
   - id: remote-host
     config:
       enabled: true
       publicOrigin: wss://<machine>.<tailnet>.ts.net:4777
   ```
   否则手机按名字连接时会因证书主机名不匹配失败；这条规则对「自有域名」同样适用（`apps/remote-host/src/index.ts:931-935`）。

注意：

- **不要用 Tailscale Serve/Funnel**：它们在 Tailscale 侧终止 TLS 并出示 `*.ts.net` 证书，手机固定 CA 的校验必然失败（§4）。
- tailnet ACL 需要允许手机 → PC 的 `tcp/4777`（默认 `autogroup:member` 互访通常已允许）。
- 组网地址不在公网路由表里；`instanceId` 与设备令牌语义不变。

### 2.2 自有域名 + 公网 IP / 端口转发（不终止 TLS）

如果 PC 有公网 IPv4（或可用的 IPv6）且能配置端口映射，这是第二条干净路线：不需要反代，只是把流量原样送到宿主。

1. 路由器把外网 `8443/tcp` 映射到 PC 的 `4777/tcp`（或直接把外网端口设 4777）。
2. 给 PC 一个有 A/AAAA 记录的域名，例如 `dsh.example.com`。
3. 宿主配置写清对外 origin（端口与转发后的端口一致，见 §3.5 的 443 限制）：
   ```yaml
   - id: remote-host
     config:
       enabled: true
       publicOrigin: wss://dsh.example.com:8443
   ```
   `publicOrigin` 的主机名会被加进叶子证书 SAN 并按需重签叶子（CA 复用，`apps/remote-host/src/index.ts:423-427`）。
4. 手机不在同一网络也能用同一个链接。

Windows 上若只想把某个端口的流量在网卡之间转一层，自带的 L4 转发也能用（不解析 TLS）：
```powershell
netsh interface portproxy add v4tov4 listenport=8443 listenaddress=0.0.0.0 connectport=4777 connectaddress=192.168.5.21
```

---

## 3. 做法 B：自有反代 / 隧道，但必须是 TCP 直通（L4）

### 3.1 前提：反代不能终止 TLS

反代只做 TCP 字节搬运时，手机看到的证书就是宿主自己那张（由固定 CA 签发、SAN 含链接主机名），证书固定完好。做法 A' 其实也是这个性质，只是没有代理进程。

**唯一例外**（不推荐）：反代持有宿主 CA 私钥、自己给域名签发叶子证书，就能在反代上终止 TLS 并让 App 的固定 CA 校验通过。代价是把信任根复制到反代机器上：反代被入侵即可冒充你的电脑，且叶子每年重签要手动重来。除非你有明确的 WAF/审计需求，不要这样做。

### 3.2 反代放在哪里

- PC 有公网地址：按 §2.2 直接映射即可，通常不需要反代。
- **PC 在 NAT 后面（大多数家庭网络）**：做法是「PC 上的客户端把 4777 以 TCP 方式拨到一台公网 VPS」，VPS 上监听一个端口。这是 frp/rathole 的标准用法，全程不解析 TLS。

### 3.3 常见落地的完整配置

以下所有例子的共同点：**只用 TCP 转发，不配置任何 TLS 参数、不改写字节**。

#### frp（PC 在 NAT 后，最省事）

VPS（frps）开 7000 与 8443：

```toml
# frps.toml（VPS）
bindPort = 7000
auth.token = "<换成自己的长随机串>"
proxyBindAddr = "0.0.0.0"   # 想只让本机 nginx 前置时改成 127.0.0.1
```

PC（frpc，随宿主一起开机启动）：

```toml
# frpc.toml（PC）
serverAddr = "vps.example.com"
serverPort = 7000
auth.token = "<与 frps 相同>"

[[proxies]]
name = "dsh-remote"
type = "tcp"
localIP = "127.0.0.1"
localPort = 4777
remotePort = 8443
```

然后 `publicOrigin: wss://dsh.example.com:8443`（`dsh.example.com` 解析到 VPS）。frp 只是把字节搬到 VPS 的 8443，手机与宿主之间的 TLS 仍是端到端。

#### nginx stream（VPS 上已有 nginx，想按 SNI 分流多个服务）

```nginx
# 必须使用 TCP/UDP 转发的 stream 模块（发行版 nginx 一般自带；没有的话装 nginx-full 或改 HAProxy）
stream {
    # 只按 SNI 选后端，不做 TLS 终止：不要写 ssl_certificate / proxy_ssl 等参数
    map $ssl_preread_server_name $dsh_backend {
        dsh.example.com  127.0.0.1:4777;   # frp 的 proxyBindAddr=127.0.0.1 时的本地端口
        default          127.0.0.1:4777;
    }
    server {
        listen 8443;
        proxy_pass $dsh_backend;
        ssl_preread on;      # 只读 ClientHello 里的 SNI，不用证书
    }
}
```

#### HAProxy（同样是 L4）

```haproxy
frontend dsh
    bind *:8443
    mode tcp
    default_backend dsh

backend dsh
    mode tcp
    server pc 127.0.0.1:4777
```

#### 临时排障：socat

```bash
socat TCP-LISTEN:8443,fork,reuseaddr TCP:127.0.0.1:4777
```

### 3.4 头、SNI 与证书链的要求（照着核对）

| 项 | 要求 | 证据 |
|---|---|---|
| TLS | 不得终止、不得替换/追加证书；SNI 原样透传即可 | §1.2 第 2 条；宿主单证书 https 服务 `apps/remote-host/src/server.ts:1267` |
| 证书主机名 | 手机连接用的主机名必须出现在宿主叶子 SAN 里 → 用 `publicOrigin` 声明该域名 | `apps/remote-host/src/index.ts:931-935` |
| `Origin` 头 | App 固定发 `https://pocket-harness.local`；L4 直通天然保留。若反代在 HTTP 层（即已终止 TLS）会改变它 → 403 | `apps/android/lib/remote_transport.dart:207`、`apps/remote-host/src/server.ts:1573-1582` |
| `Host` 头 | 宿主**不校验** `Host`；TLS 握手用的是链接里的主机名，因此 Host 是否被改写不影响 | `apps/remote-host/src/server.ts:1560-1614`（升级准入只校验路径/Origin/Authorization） |
| 路径 | 不得加前缀/改写路径；链接与端点都没有路径前缀 | `apps/remote-host/src/server.ts:413-415`、`apps/android/lib/remote_pairing.dart:154-158` |
| WebSocket | 反代必须允许升级请求（L4 天然允许）；不要启用压缩协商 | `apps/remote-host/src/server.ts:1270-1273` |
| 空闲超时 | App 与宿主各 20 s 发一次 ping（`apps/android/docs/remote-dsh/protocol.md` §1.5、`apps/remote-host/src/server.ts:53-56`）；中间设备的空闲超时设到 ≥ 120 s 更稳 | `apps/android/lib/remote_transport.dart:592` |
| `/ca.cer` 缓存 | 宿主已声明 `no-store`；反代也不要在 HTTP 层缓存（L4 不会） | `apps/remote-host/src/server.ts:1396-1401` |

### 3.5 端口 443（已修复，可正常使用）

宿主用 WHATWG URL 归一化 `publicOrigin`（`apps/remote-host/src/index.ts` 的 `normalizePublicOrigin`）。
`wss` 的默认端口是 443，`new URL('wss://dsh.example.com:443').origin` 会得到 `wss://dsh.example.com`
（端口被吃掉），而 App 在链接没写端口时按 **4777** 补（`apps/android/lib/remote_pairing.dart:163`），
曾导致「填 443 反而连错端口」。

**现状（2026-11-16 已修）**：`normalizePublicOrigin` 在检测到输入里显式写了 `:443` 时保留端口，
配对链接变成 `wss://dsh.example.com:443#instance=…`；未写端口的地址行为不变。自检：
`node --import tsx/esm apps/remote-host/scripts/public-origin-selfcheck.ts`（13/13，覆盖
`wss://h:443` 保留、`wss://h` 不变、`wss://h:8443` 不变、IPv6、大小写、非法输入）。

仍然注意：L4 反代/隧道必须把外网 443/tcp 原样转到宿主端口；HTTPS 反代（§3.7）不需要 L4 直通，但要求整站端点转发与可信反代。

### 3.6 反代的访问控制（有就加，没有也别指望宿主）

L4 反代看不到应用层内容，能做的是网络层控制：只放行已知源 IP、只绑 tailnet/VPN 地址、或给 8443 套 `fail2ban` 之类的连接级限速。宿主自带的防护是：43 字符随机令牌、`/pair` 对端限速（§6）。

### 3.7 HTTPS 反代（TLS 在反代终止）接入

这是 §3.1「反代不能终止 TLS」前提的**唯一例外**：App 的「添加连接」页有独立的第四个入口
「HTTPS 反代」，只在用户显式选择时把 TLS 信任库换成**系统根证书**，用来验证反代出示的
公网证书（含主机名）。其余入口（粘贴 / 扫码 / 局域网）仍是固定宿主 CA 的直连语义，不会
自动切换到该模式。

适用链路：手机 → 公网域名（内网穿透/端口映射）→ 反代（Nginx 等）终止 TLS → 电脑 4777。
反代必须把 `/ca.cer`、`/pair` 与 `/app`（含 WebSocket Upgrade）都转发到**同一台**电脑。

#### 3.7.1 宿主配置（电脑）

宿主生成的配对链接由 `publicOrigin` 决定。经反代接入时把它写成对外的域名与端口：

```yaml
- id: remote-host
  config:
    enabled: true
    publicOrigin: wss://ddsshh.data.knows.love:443
```

重启宿主后日志/二维码里的链接形如：

```
wss://ddsshh.data.knows.love:443#instance=<64 位 hex>&token=<43 字符>
```

- `instance` 仍是电脑 CA 的 SHA-256，设备令牌与撤销语义都不变（§5）。
- 显式写 `:443` 会被 `normalizePublicOrigin` 保留（§3.5），App 不会再把端口猜成 4777。
- 宿主叶子证书在反代模式下不再被直接校验（反代的 `proxy_ssl_verify off`），但 `/ca.cer`
  的响应体指纹必须等于 `instance`，所以「反代后面必须是这台电脑」没有被放松。

#### 3.7.2 Nginx 示例（树莓派，TLS 在反代终止）

```nginx
# http 段：WebSocket 升级用的 Connection 变量
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream dsh_pc {
    # PC 上的 remote-host。宿主本身只监听 HTTPS/WSS，所以 upstream 也用 https。
    server 192.168.5.21:4777;
    keepalive 16;
}

server {
    listen 443 ssl;
    server_name ddsshh.data.knows.love;

    # 公网 CA 签发的证书（如 Let's Encrypt）：手机用系统根证书验证它。
    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    location / {
        proxy_pass https://dsh_pc;

        # 只关闭「反代 → 电脑」这一跳对宿主自签叶子的校验：它在你自己内网里，
        # 且电脑身份由 /ca.cer 指纹绑定。手机 → 反代这一跳仍是公网证书验证。
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;          # 宿主不校验 Host，仅保持可读
        proxy_set_header X-Forwarded-For $remote_addr;

        proxy_read_timeout 300s;              # App/宿主各 20s ping；≥120s 更稳
        proxy_send_timeout 300s;
        proxy_buffering off;                  # 流式帧不要攒批
    }
}
```

要点：

- **`proxy_ssl_verify off` 不是「关闭证书校验」**：它只作用于 `反代 → 电脑` 这一跳；
  `手机 → 反代` 这一跳由系统根证书 + 公网 CA 证书验证，这才是本模式的安全边界。
- 不要在没有 `proxy_ssl_trusted_certificate` 的情况下改用 `proxy_ssl_verify on`（会一律
  失败），也不要在这里做路径前缀或 `rewrite`——宿主只实现 `/app`、`/ca.cer`、`/pair`。
- `proxy_buffering off` 与 ≥120 s 的读写超时避免流式回复被攒批、连接被空闲掐断
  （App 与宿主各 20 s ping，见 §3.4）。
- 反代到电脑这一段若改走明文 `http://`：宿主只监听 HTTPS，会直接握手失败；upstream
  必须保持 `https://`。
- 想启用 HTTP/2 时再加 `http2 on;`；若 WebSocket 升级在 h2 上不通，先退回纯 HTTP/1.1
  验证链路。
- 若内网穿透本身也终止了 TLS（例如穿透服务提供 https 入口），则对外的证书由**最先
  终止 TLS 的那一跳**提供：树莓派 Nginx 可以改成内网 `listen 80`，但手机看到的证书
  必须仍是公网 CA 签发且匹配链接域名。判据只有一条：**手机这一侧能通过系统根证书
  验证**。
- HTTP 层反代会保留 App 固定发送的 `Origin: https://pocket-harness.local` 与路径；
  若某个中间层会改写它们，升级会被 403/404 拒绝（§1.2、§6.4）。

#### 3.7.3 App 配对步骤

1. 在电脑上打开远程 DSH，拿到 `publicOrigin` 生成的配对链接（日志/终端二维码）。
2. 手机「添加连接」→ 切到 **HTTPS 反代** 入口 → 粘贴整段链接 → 点连接。
   - App 用系统根证书验证反代证书（证书链、有效期、域名）；
   - 取回 `/ca.cer` 并核对 `instance` 指纹（身份绑定）；
   - `POST /pair` 换取设备令牌，设备记录保存为「HTTPS 反代」模式。
3. 配对成功后照常用原生 UI 连接 `wss://<域名>:443/app`：协议、`Authorization`、
   `Origin`、重连与通知全部不变。
4. 在普通「粘贴链接」入口粘了反代链接时，App 只显示「改用 HTTPS 反代」按钮，不会
   静默改变信任模式；看到提示时不要为了「能连上」手工绕开模式。
5. 之后改域名/端口/反代地址都要重新配对（设备记录固化地址，§5）。

#### 3.7.4 安全模型变化

| 项 | 直连（默认） | HTTPS 反代（§3.7 入口） |
|---|---|---|
| 手机 → 对端的 TLS 证书 | 固定宿主 CA（自签） | 反代公网证书，系统根证书验证（含主机名） |
| 反代能否看到明文 | 否（L4 只看字节） | **能**：TLS 在反代终止，反代可见明文 JSON、设备令牌与内容 |
| 电脑身份绑定 | CA 固定 | `/ca.cer` 响应体 SHA-256 == `instanceId`；读回设备记录时复核 |
| 设备令牌 / Origin / 路径 / 协议 | 不变 | 不变 |
| 适用条件 | 任意可达路径 | 反代由你自己控制；upstream 只有我们的宿主；域名证书由公网 CA 签发 |

- **只在你自己控制的反代上使用**：反代（树莓派）能看到请求明文与设备令牌，它被入侵
  就等于电脑被冒充；域名与证书也必须归你所有。
- `/ca.cer` 指纹核对会拒绝转到别的后端，但它不能替代对反代本身与网络路径的信任。
- 公网暴露后仍按 §6 做网络层限制：`/pair` 窗口只有 120 s，配完撤设备或关宿主。
- 该模式不放松任何既有约束：链路仍必须 HTTPS，设备令牌仍是唯一鉴权，`Origin` 仍是
  纵深防御（protocol §2.3）。

---

## 4. 做法 C：明确不支持、也不做

| 方案 | 为什么不可用 |
|---|---|
| **Cloudflare Tunnel（普通模式）** | 隧道在 Cloudflare 边缘终止 TLS，手机拿到的是边缘的公有 CA 证书；默认入口只信任宿主那张 CA，`/pair` 与 `/app` 在 TLS 握手中停住（`apps/android/lib/remote_pairing.dart`、`apps/android/lib/remote_transport.dart`）。`/ca.cer` 因为走 TOFU 能取到，但配对第二步必失败，表现出来的现象是「证书指纹对得上、配对仍连不上」。技术上可改用 §3.7 入口，但边缘与明文都经过第三方，不推荐。 |
| **任何 HTTPS 反代（Caddy `reverse_proxy`、nginx `location /` + `proxy_pass`）** | **经 §3.7「HTTPS 反代」入口支持**：条件 = 反代由你自己控制、upstream 只有我们的宿主、域名证书由公网 CA 签发、整站转发 `/ca.cer` `/pair` `/app`。默认入口仍然失败（不会自动改模式）。 |
| Tailscale Serve / Funnel | Tailscale 侧终止 TLS 并出示 `*.ts.net` 证书：默认入口失败；Serve 在自有 tailnet 内可经 §3.7 入口（但组网直连更好），Funnel 属第三方入口，不推荐。 |
| ngrok 默认（HTTPS 端点） | ngrok 终止 TLS，默认入口失败；技术上可经 §3.7，但不推荐把命门交给第三方。付费 TCP 端点属于 L4，仍是首选形态。 |
| 反代只转发 `/app` 路径 | §1.4：默认入口与链接格式冲突；§3.7 入口也要求整站转发（否则 `/ca.cer` 取不到）。 |
| 关掉 App 的证书固定（接受任意证书） | 直接放弃唯一能挡住中间人的判据；配对=完全控制那台电脑（`apps/android/lib/remote_pairing_page.dart`），不接受的改动（HANDOFF §6 第 4 条）。§3.7 用的是系统根证书而不是「接受任意证书」。 |
| v1 内建公网穿透/隧道管理 | 明确不做，隧道交给用户自己的反代（`apps/android/docs/remote-dsh-plan.md:440`）。 |

需要这些能力时，正确顺序是：先确认反代可信并在 App 里显式选择对应信任模式（§3.7 已提供
「HTTPS 反代」入口），再谈配置；不要在文档里给一个「关掉 pinning 就能用」的假方案。

---

## 5. 地址变了、CA 换了、设备被撤销了

先记住两个东西是**分开**的：

- **宿主身份**：`instanceId` = CA 指纹；只要 CA 不变，它就是同一台电脑，设备令牌继续有效。
- **手机侧的地址**：配对时把 `host`/`port` 写进本机设备记录（`apps/android/lib/remote_device_store.dart`），**没有任何修改地址的入口**（`RemoteDevice.copyWith` 只允许改 label/lastSeenAt/systemTrust，见 `apps/android/lib/remote_device_store.dart`）。记录还包含 **TLS 信任模式**（直连固定 CA / HTTPS 反代系统信任），同样在配对时固化：两种模式不能就地互换，换模式也要重新配对。

| 情形 | instanceId | 设备令牌 | App 侧现象 | 要做的事 |
|---|---|---|---|---|
| 换反代/隧道地址（域名或端口变了） | 不变 | 不变 | 仍连旧地址，连不上 | **重新配对**（新链接自动换地址）；旧设备可在电脑上撤销（§6）。已知产品缺口：手机上还没有「删除已配对电脑」的界面，`RemoteDeviceStore.remove` 已实现但无 UI 入口（`apps/android/lib/remote_device_store.dart`）。 |
| 换接入方式（直连 ↔ HTTPS 反代） | 不变 | 不变 | 旧记录仍按旧信任模式连接，通常 TLS 失败 | **重新配对**并在正确入口选择模式（信任模式固化在设备记录里，不能就地改；§3.7） |
| 换 IP / 加网卡 / 换域名（叶子重签，CA 复用） | 不变 | 不变 | 用旧链接地址仍可连或连不上（取决于地址） | 不需要重新配对；如果要用新地址就得重新配对（原因同上）。叶子 SAN 覆盖不到新主机名时，宿主按 `publicOrigin` 重签（`apps/remote-host/src/tls.ts:258-277`）。 |
| 宿主重启 | 不变 | 不变 | 短暂重连 | 无需操作；设备表在 `$DSH_HOME/remote-host/devices.json`。 |
| 换 CA（删/损坏 `$DSH_HOME/remote-host/tls/`、CA 到期） | **变**（新 CA 指纹） | 旧令牌仍在但手机固定的是旧 CA | 所有旧手机 TLS 失败，重连也失败 | 所有设备**重新配对**；宿主会把 `identity.json` 重新绑定到新 CA（`apps/remote-host/src/identity.ts:198-209`、`apps/remote-host/src/tls.ts:369-401`）。 |
| 只删 `identity.json`、保留 `tls/` | — | — | 宿主直接启动失败：`CA 指纹与 instanceId 不一致`（`apps/remote-host/src/tls.ts:350-367`） | 把 `identity.json` 与 `tls/` 一起删除并重启（等于换 CA，所有设备重配）。 |
| 设备被撤销 | 不变 | 该设备令牌作废 | 收到 `remote.deviceRevoked` → 提示「这台手机已被电脑撤销授权」（`apps/android/lib/remote_connection.dart:498-501`）；连接以 4001 关闭，重连被拒 | 在电脑上重开配对窗口重新配对；撤销成功后宿主会自动开新窗口（`apps/remote-host/src/index.ts:582-593`）。撤销顺序固定：先落盘删除 → 推通知 → 关闭连接（`apps/remote-host/src/server.ts:1500-1548`）。 |
| 设备令牌到期（默认 180 天） | 不变 | 过期 | 连接以 4000 `auth-failed` 终止，提示重新配对（protocol §1.4） | 重新配对。 |

**一句话**：反代/隧道只改变「手机怎么找到 PC」，不会改变宿主身份和设备令牌；但 App 记的是配对时的地址，所以**换地址就要重新配对**。想少折腾就先确定最终对外地址再配对（或用组网方案让地址稳定）。

---

## 6. 安全清单

### 6.1 必须做

- **只暴露一个端口**：局域网直连暴露 4777；用反代/组网就只暴露那一个入口。宿主本身只有 `/app`、`/ca.cer`、`/pair` 三个端点，但不要额外假设「多开几个端口无所谓」——每多一个可达入口就多一份配对窗口暴露面。
- **保留证书固定（默认入口）**：App 的 `withTrustedRoots: false` + 固定 CA 是直连语义唯一的中间人防线（`apps/android/lib/remote_transport.dart`）。任何时候都不要为了「能连上」换成接受任意证书；需要 TLS 终止型反代时走 §3.7 的显式入口，那里用的是系统根证书，同样不是「接受任意证书」。
- **配对要在可信网络上做**：配对链接里带着一次性令牌，谁先拿到谁先配对。默认窗口 120 s、单次有效、失败按对端限速（5 次/分钟，对端表上限 256）（`apps/remote-host/src/pairing.ts:20-30`、`apps/remote-host/src/pairing.ts:131-166`）。配完把链接当密码看待，不要贴群聊。
- **设备表只存摘要**：`devices.json` 里只有令牌的 SHA-256，明文令牌只在配对应答里出现一次（`apps/remote-host/src/devices.ts:5-11`、`apps/remote-host/src/devices.ts:385-390`）。
- **撤销走顺序**：先落盘删除、再推 `remote.deviceRevoked`、最后关闭连接（`apps/remote-host/src/server.ts:1500-1548`），App 收到即置为已撤销。
- **反代只看字节**：L4 直通时反代不解析 Authorization/Origin；不要在反代上开 HTTP 日志记录请求头（若你把反代升级成 HTTP 层，就等于放弃了本方案的信任模型，见 §3.1）。
- **中间设备空闲超时 ≥ 120 s**：手机每 20 s ping（`apps/android/lib/remote_transport.dart:592`），宿主 20 s ping、两周期无活动关闭（`apps/remote-host/src/server.ts:53-56`）；更短的超时会把连接「莫名其妙地断」。

### 6.2 绝不能做

- 关闭 App 的证书固定 / 使用「信任所有证书」的调试开关连生产电脑（§3.7 的「HTTPS 反代」入口是系统根证书 + `/ca.cer` 指纹绑定，不属于这类开关）。
- 把宿主 CA 私钥复制到反代、第三方机器或仓库里（除非你接受 §3.1 的信任根外泄，且知道叶子每年要重签）。
- 直接把 4777 端口映射到公网却不加任何 L4 访问控制，还指望「协议有 Origin 校验就安全」：Origin 是纵深防御，不是鉴权（protocol §2.3）。
- 用明文 `ws://` 承载远程连接（v1 默认关闭，protocol §1.1）。
- 把配对链接的 `token` 写进文档、脚本、CI 日志。

### 6.3 公网暴露的额外风险（相对「仅局域网」）

- **配对窗口对全世界可达**：`/pair` 有对端限速与单次令牌，但窗口开着就意味着任何能连到端口的人都能尝试。建议只在配对时开、配完撤设备或直接关宿主。
- **升级端点可被扫描**：没有 per-IP 限速（见 §6.5），43 字符令牌在实践上不可爆破，但会产生日志噪音与资源占用；公网部署建议在网络层只允许自己常用的源地址段。
- **暴露了你的电脑名/主机名**：握手响应里的 `host.name` 是宿主机器名（`apps/remote-host/src/index.ts` 的 `createHandshake`），只有通过鉴权的连接才看得到，但这仍是信息面。
- **证书是自签的（直连）**：除 App 以外没有别的软件会信任它，这是特性，不是缺陷。§3.7 的反代模式下手机看到的是反代的公网证书，电脑自签证书只在「反代 → 电脑」这一跳出现，由反代按 `proxy_ssl_verify off` 跳过校验。
- **手机侧风险**：配对 = 完全控制那台电脑。手机丢失去先撤销设备（§5 表格）。

### 6.4 与 protocol §2 的鉴权要求对照

| protocol 要求 | 现状 | 证据 |
|---|---|---|
| 升级前：路径 `/app`、无查询串 → 否则 404 | 已实现（精确字符串比较） | `apps/remote-host/src/server.ts:413-415`、`apps/remote-host/src/server.ts:1563-1571` |
| 升级前：`Origin` 逐字节匹配 → 否则 403 | 已实现 | `apps/remote-host/src/server.ts:1573-1582` |
| 升级前：`Authorization: Bearer <43 base64url>` 形态 → 否则 401 | 已实现（不回显原值） | `apps/remote-host/src/server.ts:65`、`apps/remote-host/src/server.ts:1583-1593` |
| 升级后：令牌摘要 `timingSafeEqual` → 失败 `-32001`/关闭 4000 | 已实现 | `apps/remote-host/src/devices.ts:418` 起、`apps/remote-host/src/server.ts:1683-1712` |
| 升级后：设备已撤销 → `-32002`/关闭 4001 | 已实现 | 同上 |
| `/pair` 401/403/429 语义 | 已实现（窗口关闭/过期/限速） | `apps/remote-host/src/index.ts:658-722`、`apps/remote-host/src/pairing.ts:143-166` |
| `/ca.cer` 回 CA DER 且不缓存 | 已实现 | `apps/remote-host/src/server.ts:1385-1403` |

### 6.5 已知缺口（写在这里，避免被当成「已实现」）

1. **升级请求没有 per-IP 限速**：protocol §2.2 写的是「同一源地址 5 秒内最多 5 次尝试，超出回 HTTP 429」，当前宿主只对 `/pair` 做了对端限速（`apps/remote-host/src/pairing.ts:176-195`），WebSocket 升级的鉴权尝试没有限速分支（`apps/remote-host/src/server.ts` 全文无 429 逻辑）。公网暴露时请用网络层兜住。
2. ~~`publicOrigin` 不能用 443~~ **已修复（§3.5）**：显式 `:443` 会被保留，HTTPS 反代链接因此可用。
3. **手机上不能改地址/不能删除已配对电脑**：§5，重新配对是当前唯一路径。
4. **HTTPS 反代入口只在 Android App 提供**：旧版本 App 没有这个入口，遇到反代链接只会按默认入口失败（证书校验不过）；升级 App 后重新配对即可。

---

## 7. 配对链接与二维码

配对入口有五种（App 的「添加连接」页：粘贴链接 / 扫码配对 / 搜索局域网 / HTTPS 反代 / 手动地址，见 §11）。为了不必手抄 107 个字符，宿主进程的 **stderr 直接连终端**时会在配对日志后额外打印一张字符画二维码（实现与校验见 [pairing-qr-design.md](pairing-qr-design.md)）：

```text
[remote-host] info listening: 远程宿主已就绪：wss://192.168.5.21:4777/app。…
[remote-host] 用手机扫码得到配对链接（链接也可以直接从下面这一行整段复制）：
<ascii QR>
wss://192.168.5.21:4777#instance=…&token=…
```

日志被重定向（写文件、被 e2e 脚本捕获）时**不会**打印二维码块，只会保留原有结构化日志行，字段不变（`apps/remote-host/src/index.ts:568`、`apps/remote-host/src/index.ts:1645-1662`）。扫码由 App 内「扫码配对」入口完成（原生相机 intent + ZXing 解码，见 [pairing-qr-design.md](pairing-qr-design.md) 与 §11），扫码得到的文本与终端里那行明文链接是同一条。

PC 侧配对界面（在电脑上重开配对窗口、显示二维码、管理/撤销已配对设备）的评估与推荐方案见 [pc-pairing-distribution.md](pc-pairing-distribution.md) §1；本轮未实现，PC 侧目前仍以终端输出为准。

---

## 8. 本机环境相关的坑

- **默认路由是 VPN 的机器**：自动选到的地址可能是 VPN 网卡，手机连不上；用 `publicHost` 显式指定真实对外地址（`apps/remote-host/src/index.ts:96-102`、HANDOFF §8.1）。组网方案里同样适用（指定 `100.x` 地址）。
- **Windows 防火墙**：局域网直连要放行入站 TCP 4777，例如：
  ```powershell
  New-NetFirewallRule -DisplayName "DSH remote host" -Direction Inbound -Protocol TCP -LocalPort 4777 -Action Allow
  ```
- **多网卡/虚拟网卡**：宿主会把所有非回环 IPv4 写进叶子 SAN（`apps/remote-host/src/index.ts:805-813`），所以换网卡后**重启宿主**让 SAN 覆盖新地址；CA 不变，已配对手机不需要重配。
- **手机同时只能有一个 VPN**：Tailscale/WireGuard 会占用 Android 的 VPN 槽，和公司 VPN/代理类 App 冲突。

---

## 9. 排障表

| 症状 | 最可能原因 | 处置 |
|---|---|---|
| 配对报「与电脑建立 TLS 连接失败」 | 链接里的主机名不在叶子 SAN（例如只设了 `publicHost` 的域名，没用 `publicOrigin`，或换网卡后没重启宿主） | 用 `publicOrigin` 声明名字并重启宿主（§2.1、§3.4） |
| 配对报「反代出示的 HTTPS 证书不受系统信任」 | 反代证书自签/过期/证书链不完整，或粘贴到了普通入口 | 换公网 CA 签发的证书；确认用「HTTPS 反代」入口（§3.7），不要改普通入口 |
| 配对报「反代证书与配对链接里的域名不一致」 | 证书 SAN 与链接域名不同（Nginx `server_name`/证书不匹配） | 用证书覆盖的域名重新生成链接（`publicOrigin`）；核对 §3.7.2 |
| 配对报「反代没有把 /ca.cer 转发到电脑」（404/502） | Nginx `location`/`upstream` 未覆盖 `/ca.cer`、`/pair`，或后端端口写错 | 按 §3.7.2 整站转发到 PC:4777，并确认 upstream 用 `https://` |
| 配对报「反代地址拒绝连接」 | 链接端口不对（HTTPS 反代一般是 443）或 Nginx 未监听该端口 | 核对 `publicOrigin` 与 `listen`；对照 §3.5 |
| 反代模式能配对但连接以 4000/4001 关闭 | 设备令牌无效/过期/被撤销 | 重新配对（§5） |
| 反代模式连接反复断（1001） | 反代空闲超时过短、未处理 WebSocket Upgrade 或缓冲流式帧 | `proxy_read_timeout` ≥ 120 s、透传 `Upgrade/Connection`、`proxy_buffering off`（§3.7.2） |
| 配对报「证书指纹与配对码不一致」 | 链接来自另一台电脑、链接过期，或反代把请求转给了别的后端 | 重新从当前宿主日志取链接；检查反代后端只有一台 |
| 配对报「配对窗口已关闭或过期」（403） | 窗口默认 120 s、单次有效 | 在电脑上重开配对窗口（宿主撤销设备/`remoteHost.pair()` 会自动开，见 §5） |
| 配对报 429 | 对端尝试次数超限 | 等一分钟或重开配对窗口 |
| 升级被 403 拒绝 | `Origin` 被中间层改写（说明中间层在 HTTP 层，已终止 TLS） | 按 §3/§4 换成 TCP 直通 |
| 升级 404 | 中间层加了路径前缀/重写了路径 | 链接与端点都不带路径前缀，改用 L4 直通 |
| 连上一会就断（1001） | 中间设备空闲超时太短 | 把空闲超时调到 ≥ 120 s（§3.4） |
| 能配对、能连，但偶尔要重连 | 手机网络切换/VPN 关闭；协议支持 1 s→30 s 退避重连 | 无需处理；确认组网客户端始终在线 |
| 设备突然提示「已被电脑撤销授权」 | 有人在电脑上撤销了这台设备 | 重新配对（§5） |
| 连接以 4000 关闭 | 设备令牌无效/过期（例如换了 CA 或超过 180 天） | 重新配对 |

---

## 10. 证据索引

| 事实 | 位置 |
|---|---|
| 端点 `/app`、`/ca.cer`、`/pair` 与 404 兜底 | `apps/remote-host/src/server.ts:32`、`:35`、`:38`、`:1350-1374` |
| 升级准入：路径 → Origin → Authorization 顺序 | `apps/remote-host/src/server.ts:1560-1614` |
| Origin 常量与逐字节比较 | `apps/remote-host/src/server.ts:41`、`:1573-1582` |
| 鉴权失败的结构化错误与 4000/4001 | `apps/remote-host/src/server.ts:1683-1712` |
| 撤销顺序与 `remote.deviceRevoked` | `apps/remote-host/src/server.ts:1489-1548` |
| 宿主 CA/叶子生命周期与 SAN | `apps/remote-host/src/tls.ts:43-53`、`:258-277`、`:369-401` |
| instanceId = CA 指纹、绑定与失配拒绝 | `apps/remote-host/src/tls.ts:350-367`、`apps/remote-host/src/identity.ts:198-209` |
| 配对窗口 TTL/限速/单次 | `apps/remote-host/src/pairing.ts:20-30`、`:131-166` |
| 配对链接生成与 origin 归一化 | `apps/remote-host/src/pairing.ts:198-245` |
| 设备令牌摘要与 tombstone | `apps/remote-host/src/devices.ts:5-11`、`:385-390`、`:418` 起 |
| `publicHost` / `publicOrigin` 语义与 SAN | `apps/remote-host/src/index.ts:96-117`、`:423-427`、`:892-919`、`:928-935` |
| 终端配对二维码打印（仅 TTY） | `apps/remote-host/src/index.ts:568`、`:1645-1662` |
| App 固定 CA（/pair 与 wss） | `apps/android/lib/remote_pairing.dart`、`apps/android/lib/remote_transport.dart` |
| HTTPS 反代：App 系统信任配对与传输选择 | `apps/android/lib/remote_pairing.dart`（`systemTrust` 参数、`looksLikeHttpsProxyPairingLink`）、`apps/android/lib/remote_transport.dart`、`apps/android/lib/remote_connection.dart` |
| HTTPS 反代：设备记录信任模式字段与序列化 | `apps/android/lib/remote_device_store.dart`（`RemoteDevice.systemTrust`） |
| HTTPS 反代：配对入口与「改用反代」提示 | `apps/android/lib/remote_pairing_page.dart` |
| `/ca.cer` 的 TOFU 取法与指纹比对 | `apps/android/lib/remote_pairing.dart:339-370` |
| 配对链接解析：拒绝路径/查询串、默认 4777 | `apps/android/lib/remote_pairing.dart:127-199` |
| App 设备记录（host/port 固化、无改地址入口） | `apps/android/lib/remote_device_store.dart:99-130`、`:208` |
| App 收到撤销通知的反应 | `apps/android/lib/remote_connection.dart:498-501` |
| 「添加连接」页五入口（粘贴/扫码/发现/HTTPS 反代/手动地址）与「完全信任」提示 | `apps/android/lib/remote_pairing_page.dart`、`apps/android/lib/remote_pairing_scan.dart` |
| App 侧 UDP 发现（探测/解析/去重/窗口） | `apps/android/lib/remote_discovery.dart`、`apps/android/docs/remote-dsh/discovery.md:321-331` |
| 可达性阶梯（v1/v2/v3）与不做项 | `apps/android/docs/remote-dsh-plan.md:369-375`、`:436-444` |

---

## 11. 手机侧连接方式

App 的「添加连接」页（`apps/android/lib/remote_pairing_page.dart`）把所有配对入口收拢在
一处；五种方式最终都把**同一条配对链接**交给同一条配对流程（`remote_pairing_flow.dart`：
解析 → `GET /ca.cer` 校验 instanceId → `POST /pair` → 设备令牌进 Keystore），发现/扫码/
手动地址都只是「拿到链接」的不同途径，不改变一次性令牌语义；信任模式（直连固定 CA /
HTTPS 反代系统信任）由用户选择的入口显式决定（§3.7）。

| 入口 | 适用场景 | 前提 |
|---|---|---|
| 粘贴链接 | 任何可达方式（局域网、组网、反代、USB） | 从电脑日志/终端复制完整 `wss://…#instance=…&token=…`；直连语义（固定宿主 CA） |
| 扫码配对 | 电脑日志直接连终端（打印二维码） | 手机有可用相机；App 不申请 CAMERA 权限，用系统相机 intent |
| 搜索局域网 | 手机与电脑在同一 Wi-Fi/网段 | 宿主 `discoveryEnabled`（默认开）、UDP 4778 入站放行、无 AP 隔离 |
| HTTPS 反代 | 公网域名 + Nginx/内网穿透，TLS 在反代终止 | 反代由你自己控制、upstream 只有我们的宿主、公网证书有效；整站转发 `/ca.cer` `/pair` `/app`（§3.7） |
| 手动地址（高级） | USB adb reverse、反代/域名与链接地址不一致 | 已有一条完整配对链接；只替换地址，不跳过 instanceId；仍是直连语义 |

### 11.1 粘贴链接

电脑上把日志里的 `wss://…` 整段复制发到手机（或手动输入），粘贴到「粘贴链接」后点「连接」。
这是所有网络形态的兜底入口：发现被防火墙拦、相机不可用、反代地址变化都回到这里。
如果粘贴的是 `wss://<域名>:443#…` 或 `https://<域名>…`（HTTPS 反代形态），普通入口只提示
切换到「HTTPS 反代」，不会静默改用系统信任（§3.7）。

### 11.2 扫码配对

宿主 stderr 是终端时会在配对日志后打印字符画二维码（§7）。App 用系统相机
（`MediaStore.ACTION_IMAGE_CAPTURE` + FileProvider，不申请 CAMERA 权限）拍照，原生
ZXing 在后台线程解码，把文本填进链接输入框；**扫码不等于配对**，仍需点「连接」走上面
那条流程。相机不可用（无相机应用、ROM 限制、解码失败）时给出可读原因并保留粘贴入口。
解码与验收细节见 [pairing-qr-design.md](pairing-qr-design.md)。

### 11.3 搜索局域网（UDP 发现）

协议、端口、字段与安全边界见 [discovery.md](discovery.md)。App 侧行为：

- 只有切到「搜索局域网」或点「重新搜索」才发送一次探测，默认窗口 **2.5 s**，窗口结束
  立即关闭套接字——不在 `initState` 常驻轮询，页面静置不产生 UDP 流量（60 fps 门禁）。
- 探测广播到 `255.255.255.255:4778`（另按本机 IPv4 猜 `/24` 子网广播），宿主单播回
  `{name, origin, instanceId, pairing}`；只接受本轮 nonce 回显，坏帧静默丢弃。
- `pairing.open=true`：列表里点「连接」直接用宿主给的 `pairUrl`（与二维码/日志同一条），
  走既有配对流程；`pairing.open=false`：显示「配对窗口未打开，请在电脑上重新打开」并提供
  重新搜索；空结果给出同网段/防火墙/UDP 4778/AP 隔离说明与扫码、粘贴回退。
- 发现结果只是提示：伪造应答最多让配对失败（CA 指纹对不上），不会建立信任，也不会写设备表。

### 11.4 手动地址与令牌（高级）

用于「链接里的地址手机不可达，但另有一条网络路径可达」：

- **USB adb reverse**（手机没有 Wi-Fi/跨网段时的调试通道）：

  ```powershell
  # PC 上执行（USB 已连接、adb 授权）
  D:\Programs\adb\adb.exe reverse tcp:4777 tcp:4777
  # 手机：添加连接 → 手动地址与令牌 → 配对链接粘贴电脑日志里的完整链接
  #       电脑地址填 127.0.0.1:4777 → 用这个地址配对
  # 结束后：adb reverse --remove-all
  ```

  宿主叶子证书的 SAN **恒包含 127.0.0.1 与 localhost**（`apps/remote-host/src/tls.ts` 的
  `MANDATORY_HOSTS`），所以固定 CA + 主机名校验都能通过；这条通道只用一次配对，
  配对后的连接地址会记成 `127.0.0.1:4777`，拔掉 USB 后该设备需要重新配对/改地址。

- **反代/隧道地址替换**：链接由电脑按 `publicOrigin` 生成（可能是域名:8443），手机在
  局域网内想直连内网地址时，把手动地址填成 `192.168.x.x:4777`；`instanceId` 与 token 仍取
  自链接，证书校验照旧，不会降级为「见证书即信任」。

- 手动地址**必须**有完整链接：只给 `host:port` 或只给 43 字符 token 无法配对——首次配对
  的信任锚是链接里的 `instanceId`（CA 指纹），App 不会用「从该地址现取的证书」当锚点
  （那会让同网段的中间人可以冒充电脑）。缺少时页面会明确提示粘贴完整链接或改用扫码。

### 11.5 HTTPS 反代（TLS 在反代终止）

完整配置与安全模型见 §3.7。App 侧只需要：

1. 「添加连接」→ 切到 **HTTPS 反代** 入口（第四段）；
2. 粘贴宿主按 `publicOrigin` 生成的完整链接（形如 `wss://ddsshh.data.knows.love:443#instance=…&token=…`）；
3. 点「连接」。App 用系统根证书验证反代公网证书，仍取回 `/ca.cer` 核对 `instance` 指纹，并把设备记录标成 HTTPS 反代；之后正常使用原生 UI 连接。

在普通「粘贴链接」入口粘到反代链接时，App 只显示「改用 HTTPS 反代」按钮，不会静默
改变证书信任方式；反方向（在反代入口粘局域网直连链接）也不会自动换模式，失败文案会
提示改用普通入口。

### 11.6 地址变化时怎么办

主动改地址/换 CA/换设备的处理仍按 §5：地址变了（含 USB 改地址）要重新配对；CA 不变时
已配对设备不受影响，但设备记录里的 host/port 是配对时固化的（`remote_device_store.dart`），
所以换网络路径后需要重新配对，不能就地改已配对设备的地址。

| 协议端点头/Origin/鉴权/关闭码 | `apps/android/docs/remote-dsh/protocol.md:44-56`、`:121-181`、`:100-113` |
