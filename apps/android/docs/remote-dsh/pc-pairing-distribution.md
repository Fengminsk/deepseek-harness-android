# 远程 DSH · PC 配对界面、PC 分发与后台通知边界（评估）

状态：2026-11-16，评估完成、**未落地代码**。读者：决定 P6 剩余投入的 lead、后续施工的 Agent。`apps/remote-host/src/index.ts` 正被 task-20 并行修改，文中标注「当前约」的行号以文件内符号名为准。
相关：[HANDOFF.md](HANDOFF.md)（§4 第 6/7/13 项、§9 变更日志）、[pairing-qr-design.md](pairing-qr-design.md)（配对输入路线与终端二维码）、[discovery.md](discovery.md)（UDP 发现协议）、[reachability.md](reachability.md)（外网接入）、[protocol.md](protocol.md)（§7.1 无重放、§8 远程通知）。

**结论先行**：

1. **PC 配对界面**：推荐 **A1「宿主内嵌的本地回环设置页」**（新插件内起 `node:http`，只绑 `127.0.0.1`，页面显示配对二维码 + 窗口倒计时 + 设备列表 + 撤销/重开）。二维码可直接复用 [pairing-qr.ts](../../../remote-host/src/pairing-qr.ts) 的 `encodeQrMatrix()` 输出 **SVG**（零新依赖，约 30 行；PNG 不必要，浏览器能直接渲染 SVG）。全量 Web GUI（A2）要 5–8 天且把无头宿主变成第二个前端；独立 Electron/Tauri（C）成本更高，均不推荐。终端 TUI（B）作为无浏览器/无桌面的兜底。
2. **PC 分发**：今天**没有任何面向用户的安装路径**——宿主的发布链（npm CLI 与 Desktop 安装器）都会因为 `@minnnng/dsh-android-runtime@0.0.0` 不存在而失败（本机实测 tarball 依赖 + registry 404 + release/desktop 工具链规则）。推荐把运行时**升为 dsh 发布家族成员**：改名 `@deepseek-ai/dsh-android-runtime`、去 `private`、目录仍留 `apps/android/runtime`，一条改动同时修好 npm CLI 与 Desktop 安装链，并保持 Android APK 与 PC 宿主共用同一份源码。是否公开发布是产品/团队决定，见 §2.4。
3. **后台通知**：task-20/21 落地后覆盖的是「**App 进程存活**时」的送达（前台不打扰、退后台才弹）。要跨「退后台/Activity 销毁」继续收，推荐先做 **前台服务 + 缓存 FlutterEngine** 保活 UI 进程（3–4 天，Dart 传输与协议状态机零改动）；「transport 移出 UI 进程」（Kotlin 持 WS 或移进 Node runtime）只在产品要求「进程被杀也不中断」时再做（4–8 天，架构面大）。

---

## 1. PC 侧配对界面

### 1.1 现状盘点

**宿主已经有的东西**（配对能力齐全，缺的只是展示与设备管理面）：

| 能力 | 现状 | 证据 |
|---|---|---|
| 配对窗口 | 单次有效，默认 120 s，上限 15 分钟；消费/过期即失效 | `apps/remote-host/src/pairing.ts`（`MAXIMUM_TTL_MS`、`open`/`redeem`） |
| 重开窗口 | `remoteHost` 服务已暴露 `pair()`；撤销设备后自动重开 | `apps/remote-host/src/index.ts` 的 `interface RemoteHostHandle`（`pair()`）与 `ctx.provide(REMOTE_HOST_SERVICE, …)`；当前约 `:304-320`、`:428-432` |
| 设备管理与撤销 | 服务暴露 `devices()` / `revokeDevice(id)`；撤销会推 `remote.deviceRevoked` 并关闭 4001 | 同上；`apps/remote-host/src/server.ts` 的 `revokeDevice`（`:1500-1548`） |
| 配对票据 | `pair()` 返回 `{ pairUrl, expiresAt }`；窗口打开时日志同时给出 `pairUrl` / `usbPairUrl` / `expiresAt` | `apps/remote-host/src/index.ts` 的 `RemotePairingTicket`、`openPairingWindow`（当前约 `:296-302`、`:599-632`） |
| 终端展示 | TTY 下打印二维码 + 明文链接 + `adb reverse` USB 回环链接与命令 | `apps/remote-host/src/index.ts` 的 `writePairingQr`（当前约 `:1090-1115`） |
| 局域网发现 | UDP **4778**，配对窗口打开时才在应答里带同一条 `pairUrl`；关窗只回 `{open:false}` | `apps/remote-host/src/discovery.ts:41`、`:197`、`:240`；协议见 [discovery.md](discovery.md) |
| TLS 端点 | `wss://<host>:<port>/app`、`GET /ca.cer`、`POST /pair`；`publicOrigin` 支持域名/SAN | `apps/remote-host/src/server.ts`（端点常量与 HTTP 面）；`apps/remote-host/src/index.ts` 的 `Config.publicOrigin` |

**App 侧已经不需要 PC 界面再发明什么**：`App`「添加连接」已有三入口 + 手动地址覆盖——粘贴 / **扫码配对**（系统相机 + 原生 ZXing，`MethodChannel` 方法 `remote.pairing.scan`）/ **搜索局域网**（UDP 发现）/ 手动地址与令牌（USB `adb reverse`、反代），见 `apps/android/lib/remote_pairing_page.dart:392-410`、`:432-449`；扫码实现在 `PairingQrScan.kt`（`com.google.zxing:core:3.5.3`，`apps/android/android/app/build.gradle.kts:203`）。所以 PC 侧只要**把二维码显示足够大**，配对链路就是通的。

**缺的**（这些正是 PC 界面要补的）：PC 上无法一键重开窗口、看不到已配对设备、无法撤销、看不到窗口倒计时。而且**服务接口本身还缺三项信息**，任何 PC UI 都要先补：

1. `pair()` 只返回 `pairUrl`/`expiresAt`，**USB 回环票据 `usbPairUrl` 没有对外暴露**（它只在内部算出来用于日志/终端，见 `apps/remote-host/src/index.ts:612`）。
2. 没有暴露监听信息（host/port/origin）、`instanceId`、发现状态（`discoveryEnabled`/`discoveryPort`）、当前是否已有设备在线。
3. 没有"当前连接"信息（`binding` 是 `startRemoteHost` 的局部变量，`server.connections` 也未对外）；设备列表 `devices()` 里没有 online 字段。

### 1.2 方案 A1：宿主内嵌本地回环设置页（推荐）

**形态**：在 `remote-host` 插件里再挂一个极小的 HTTP 服务（`apps/remote-host/src/pairing-ui.ts`，由 `apps/remote-host/src/index.ts` 的 `apply()` 装配），只绑 `127.0.0.1`，用 `node:http` + 一个内嵌 HTML/JS 页面，不引任何框架、**不启用完整 Web 组合**（不碰 `dsh-web-app`/`webStartup`）。

**页面元素（可直接照做）**：

- 头部：宿主显示名、`instanceId` 前 8 位、监听地址/端口、局域网发现开关与 UDP 端口。
- 配对卡片：「打开配对窗口」按钮；打开后显示**窗口剩余时间**倒计时（来自 `expiresAt`）、**二维码**（主：`pairUrl`，即局域网/反代地址）、二维码下方「复制链接」。
- USB 卡片：`usbPairUrl` 二维码 + `adb reverse tcp:<port> tcp:<port>` 命令一键复制（对应终端里已有的 USB 段落）。
- 设备列表：`label` / `deviceId` 短写 / `createdAt` / `expiresAt` / `revokedAt` / 在线状态；每行「撤销」按钮（二次确认），撤销后列表刷新、宿主自动重开窗口并刷新二维码。
- 已过期态：窗口过期或被消费后，二维码区显示「窗口已过期」+ 重新打开按钮（`pair()` 就是它）。
- 刷新方式：页面每 1 s `GET /api/state`；窗口只有 120 s、数据量小，不必上 SSE。

**需要的宿主接口增补（最小改动）**：

- `RemotePairingTicket` 增加 `usbPairUrl`（或新增 `pairDetails()` 返回 `{ pairUrl, usbPairUrl, expiresAt, origin }`）。
- 新增 `remoteHost.status()`：`{ listen: { host, port, origin }, instanceId, discovery: { enabled, port }, pairing: { expiresAt } | null, connection: { deviceId, remoteAddress } | null }`（连接信息可在 `onConnection`/`onClose` 里记录 `connection.id`/`deviceId`，`server.ts` 已有连接表但不必公开）。
- 设备列表加 `online`（用上面的当前连接 `deviceId` 比较即可，不必进 `devices.json`）。

**安全边界（必须写死）**：

- 只绑 `127.0.0.1`；启动时生成一次性随机 `uiToken`，打印到终端（`http://127.0.0.1:<port>/?token=…`），所有请求校验 token；`Host` 头只接受 `127.0.0.1`/`localhost`；响应 `Cache-Control: no-store`；不设 CORS。
- 页面不返回设备令牌（`devices()` 返回的已经是摘要级 `DeviceSummary`）。
- 明文 HTTP 仅限 loopback，与远程链路的 TLS 要求不冲突；但要在文档/UI 上写明"只在本机浏览器打开"。
- 端口：默认取一个独立端口（建议 4779 或 `0` 让系统分配后打印 URL）；绑定失败不能让宿主启动失败（记 warn、禁用 UI，与 `discovery.ts` 的失败语义一致）。

**二维码渲染结论（明确回答"能否复用 pairing-qr.ts 出 PNG/SVG"）**：

- **SVG：能，且推荐**。`encodeQrMatrix(text)` 已返回模块矩阵（`apps/remote-host/src/pairing-qr.ts:174`、`:645`），服务端把它转成 `<svg viewBox="0 0 N N">` + 每行一个 `<rect>`/一个 `<path>` 即可（约 20–30 行，零依赖），页面 `<img src="/api/qr.svg?link=lan">` 或直接内联。扫码 App 拍屏幕照旧可解。
- **PNG：不必要**。浏览器/Electron/Tauri 都能直接渲染 SVG；真要做 PNG（例如出图给打印），才需要纯 Node 里手写 zlib+PNG chunk（约 80–120 行，仍无依赖）或引 `sharp`/`canvas`（新原生依赖，**不建议**）。本轮评估结论：**只做 SVG，不做 PNG**。

**改动面**：

| 文件/位置 | 改动 |
|---|---|
| `apps/remote-host/src/pairing-ui.ts`（新） | HTTP 服务、路由（`/`、`/api/state`、`/api/pair`、`/api/revoke`、`/api/qr.svg`）、内嵌页面、token/Host 校验；约 350–450 行（含 HTML 模板） |
| `apps/remote-host/src/index.ts` | 装配 UI 插件（启动/停止 effect）、`pair()` 增加 `usbPairUrl`、新增 `status()`、打印 UI URL；约 40–60 行 |
| `apps/remote-host/src/index.ts` 或 `server.ts` | 记录当前连接 deviceId（在线状态）；约 10 行（`binding` 已有，只需在 `RemoteHostHandle` 暴露） |
| `apps/remote-host/cordis.patch.yml` | 新增 `pairingUiUrl`/端口配置项 1–2 行（或全部用插件默认值，不暴露配置） |
| 测试 | `apps/remote-host/scripts/pairing-ui-selfcheck.ts`（假 `remoteHost` 服务 + 临时端口，验证 token/Host 校验、pair/revoke 调用、SVG 输出）；冒烟不回归 |

**依赖**：零新增依赖。

**风险**：① 页面文案属于产品 UI，仓库要求客户端文案 locale-owned；这是宿主内嵌页而非 `packages/client` 插件，建议 v1 只做中文并在文档标注、或直接内嵌中英两份文案（需 lead 定），不要硬编码一堆中文散在代码里。② 本机任意进程本来就能读 `$DSH_HOME/remote-host/devices.json` 并操作文件，回环页带来的增量风险有限；token+Host 校验是为了防"浏览器里其它网页发起的 CSRF/DNS rebinding"（页面无 CORS、token 在 URL，已足够）。③ 端口占用与用户不知道 URL（用终端打印解决）。

**工期**：2–4 天（含自检与文档；不含真机，PC 侧浏览器验证即可）。

**验收方式**：宿主启动 → 终端出现 `本机配对页：http://127.0.0.1:<port>/?token=…` → 浏览器打开显示二维码 → App 扫码配对成功（宿主日志 `pair-issued`、`connection-opened`）→ 设备列表出现该设备且在线 → 点击撤销 → App 收到「已被撤销」、宿主自动重开窗口、二维码刷新 → 倒计时归零后显示「窗口已过期」。

### 1.3 方案 A2：复用完整 Web GUI（不推荐现在做）

**事实核查**（这个方案比看起来贵）：

- `remote-host` profile **已经**包含 `dsh-web-app` 层（`packages/util/official-bundles/src/bundles.ts:30-37`），但 `dsh --profile remote-host` **不会启动 Web 服务**：`webStartup` 服务只在 `dsh web` 命令的 action 里 `provide`（`packages/bundle/web-app/src/startup.ts:91-123`），而 `webserver` 行严格 `inject: [webStartup]`（`packages/bundle/web-app/cordis.patch.yml:183-192`）；`dsh web` 固定等价 `dsh --profile web`（`apps/cli/src/args.ts:92`）。
- 因此要走 A2，必须先做组合层改动：让 remote-host 能拿到 `webStartup`（新 profile/启动参数/CLI 组合），或者把 Web 服务改成"有配置就能起"。这会动到全量 Web 组合的启动语义（影响所有 profile），风险不小。

**若坚持 A2，完整工作**：① 组合/启动改动；② 新客户端插件（设置页 + 设计系统 + i18n + 测试，参考 `packages/bundle/web-app/cordis.patch.yml:310-311` 的 settings 行）；③ 新 Host API 插件（就是 A1 需要的 `status/pair` 增补）；④ 端口/浏览器打开/与 `dsh web` 并存策略。工期 **5–8 天**，并且以后每个配对 UI 改动都要同时改两端。结论：不做。

### 1.4 方案 B：终端 TUI（兜底，可选）

零依赖（`node:readline`/`process.stdin` 的 keypress），在已打印二维码的终端里继续提供：设备列表（`d`）、重开窗口（`p`）、撤销（`r` + 序号）、退出 UI（`q`）。**只适合"用户就在这台电脑的终端前"的场景**，且只在 TTY 下可用（与现有 `writePairingQr` 的 TTY 判断一致）。

风险：与日志输出交错、stdin 归属（CLI 目前没有占用 stdin，但需要确认不与未来的交互式命令冲突）；桌面/服务方式启动时不可用。**建议作为 A1 的补充而非替代**：加一个 `ui: 'web' | 'terminal' | 'off'` 配置，默认 `web`（无 TTY 或端口绑定失败时自动退到日志）。工期 1 天。

### 1.5 方案 C：独立小工具（Electron/Tauri/本地页面）— 不推荐

- "独立"意味着新的安装器、签名、自动更新、崩溃上报，与现有 `apps/desktop` 的 electron-builder 链重复（`apps/desktop/scripts/electron-builder-config.mjs`、`apps/desktop/windows-signing/`）。
- 它要显示配对窗口/设备列表，仍必须与运行中的宿主通信——而宿主没有 IPC 面（只有日志/文件/端口）；要么再实现一套 loopback API（= A1 的 API），要么让工具自己读写 `devices.json` 并操控不了运行中进程（撤销要关连接，做不到）。
- 结论：C 的成本 ≈ A1 + 一整套打包分发；如果未来要做，形态应是在**现有 DSH Desktop** 里加页面（见 §2 分发决定），而不是新造一个 app。

### 1.6 推荐落地顺序

1. **A1**：宿主内嵌回环设置页（2–4 天）——同时补齐 `status()/pair()` 接口，App 扫码链路无需改动。
2. **B**（可选 1 天）：给无 TTY/无浏览器场景的终端兜底与设备管理。
3. A2 / 桌面集成：等 §2 的 PC 分发决定后再议（若 remote-host 最终以 Desktop 形态分发，配对 UI 应该做进 Desktop，而不是 Web GUI）。

**已落地（2026-11-16）**：A1 已实现，实现说明、契约、威胁模型与验证见 [pc-pairing-page.md](pc-pairing-page.md)。与本节评估的差异：① 页面用 **Host 校验 + 进程级随机 CSRF token + Origin 同源校验**，没有采用本节建议的一次性 `uiToken`（页面 URL 不含 token，浏览器打开即可用）；② `RemotePairingTicket` 按「接口增补 1」增加了 `usbPairUrl`，`status()` 增补未做（页面只需要当前窗口 + 设备摘要，在线状态留给后续）；③ 二维码按评估结论用 `encodeQrMatrix` 直接出内联 SVG，不引 PNG 依赖。`pairing-page-selfcheck.ts` **24/24 PASS**、两个 tsc exit 0、oxlint 改动文件 0 error、宿主冒烟 14/14；浏览器截图验收待补（位置见 pc-pairing-page.md §2）。

---

## 2. PC 分发

### 2.1 现状盘点（含实测）

**运行时的身份**（`apps/android/runtime/package.json`）：

- 名字 `@minnnng/dsh-android-runtime`（第 2 行），版本 `0.0.0`（第 3 行），**`private: true`**（第 4 行），`main: ./index.mjs`，`license: MIT`，带 `dsh.bundle.patch: ./cordis.patch.yml`；**缺** `repository` / `publishConfig` / `engines` / `files` / README（`apps/android/runtime` 目录里也没有 README）。
- 它同时是 Android APK 的运行时门面：`apps/android/tool/stage-runtime.ts:17` 生成 `.cache/android/runtime-bundle`，`apps/android/tool/stage-runtime-plugin.mjs` 把源码目录复制到 `node_modules/@minnnng/dsh-android-runtime`，`apps/android/tool/pack-runtime.ps1` 再放进 APK assets。

**谁依赖它**：

- `apps/remote-host/package.json:41`（`"@minnnng/dsh-android-runtime": "workspace:*"`）
- `apps/cli/package.json:111`（同上；HANDOFF §3.4：不声明依赖则加载器无法从安装锚点解析 bundle）
- 出厂 profile 模板：`packages/util/official-bundles/src/bundles.ts:30-37`（`remote-host` 层序 = base → web-app → android-runtime → remote-host）
- TS 路径：`tsconfig.base.json:510`；workspace 显式列入 `pnpm-workspace.yaml:15`

**实测：发布/安装链目前是断的**（2026-11-16 本机）：

1. `pnpm --dir apps/remote-host pack` 与 `pnpm --dir apps/cli pack` 的 tarball 里，依赖写成了 **`"@minnnng/dsh-android-runtime": "0.0.0"`**（本机实际 pack 产物里读出来的 manifest）。
2. npm registry（2026-11-16 查询：`https://registry.npmjs.org/@minnnng%2Fdsh-android-runtime` 与 `.../@deepseek-ai%2Fdsh-remote-host`）：两者均 **404**；已发布的 `@deepseek-ai/dsh@0.2.2-rc.1` 依赖清单里**没有** `@deepseek-ai/dsh-remote-host`/`@minnnng/dsh-android-runtime`（说明现网版本早于本功能，**下一轮 release 会把这两个依赖带进发布产物**）。
3. release 工具链规则：`dsh` 家族成员 = `packages/*/*/package.json` + `apps/*/package.json`（`scripts/release/families.ts:350-353`），**跳过 `private` 包**（`:132`），**包名必须以 `@deepseek-ai/` 开头**（`:136`），全家族**共用一个版本**（`:365-371`）→ 当前这个运行时**在规则上不可能是发布成员**。
4. `release:verify-packed-install` 会把 family tarball 装进一个临时 consumer 并驱动 CLI（`scripts/release/verify-packed-install.ts:95-117`）：缺运行时 tarball 时 npm 会去 registry 找 `@minnnng/...@0.0.0` → 404 → 验证失败。
5. Desktop 安装器同样阻断：安装器里的 dsh 运行时来自 **core package set**，从 `@deepseek-ai/dsh` + `@deepseek-ai/dsh-desktop-host` 出发做闭包，闭包里每个 workspace 依赖都必须出现在 packed 输入中，否则报 `desktop package set: X requires unpacked package Y`（`apps/desktop/scripts/prepare-package-set.ts:74-108`、`:151-181`）；输入就是 release pack 的 tarball 目录（`:185-196`）。electron-builder 再把整棵 `dsh`（含 node_modules）塞进安装包（`apps/desktop/scripts/electron-builder-config.mjs:155-157`）。

**结论**：今天只有「工作区源码 + `pnpm dsh --profile remote-host`」这一种运行方式；任何面向用户的安装（npm CLI 或 Desktop 安装器）都会在依赖解析处失败。

### 2.2 三条路线

#### A. 发布到 npm（推荐，需先决策包名/scope）

把运行时升为 dsh 发布家族成员。两种落法：

- **A1（推荐）目录不动，只改身份**：名称 `@deepseek-ai/dsh-android-runtime`，去 `private`，版本交给 `release:bump`（家族统一版本），补 `repository`/`publishConfig.access: public`/`engines: { node: ">=24.9.0" }`/显式 `files`/README；release 家族 patterns 增加**显式一条** `apps/android/runtime/package.json`（不要写 `apps/*/*/package.json` 通配，避免未来把别的嵌套 app 误收进发布家族）。
- **A2 迁移到 `packages/<group>/<pkg>`**：家族通配已覆盖，但会破坏 Android 侧大量按路径引用的脚本（`apps/android/tool/**` 的 staged 路径、`parity-manifest.json`）——**不建议**。

**必做清单（A1）**：

1. `apps/android/runtime/package.json`：改名、去 `private`、补 `repository`/`publishConfig`/`engines`/`files`/README(.md/.zh)、description 与 `homepage` 按发布成员规范。
2. 同步全仓包名引用（本机 ripgrep 实测 84 处匹配，含 lock 文件与文档）：`bundles.ts:34`、`apps/cli/package.json:111`、`apps/remote-host/package.json:41`、`tsconfig.base.json:510`、Android `tool/**` 与验收脚本（staged 路径里的 `node_modules/@minnnng/dsh-android-runtime`）、`apps/android/runtime/bootstrap.mjs` 与 `host-guard.mjs`、`stage-runtime-plugin.mjs`/`stage-runtime.ts:97`、`pack-runtime.ps1`、`metadata_artwork.dart` 的插件名映射等。
3. 门禁：`scripts/check-workspace-constraints.ts` 的 `appPackageFiles` 增加条目（`:81-91`），并让 `standardReleaseMemberDirectory`（`:74-77`）与 family patterns 接受嵌套 app 目录（`apps/android/runtime`）；`verify-product-use.ts:77` / `verify-default-product-isolation.ts:67` 目前按路径发现该包，改名后确认仍匹配。
4. 发布策略：家族统一版本（`families.ts:365-371`），prerelease 自动走 `next`（`:381-387`）；不做独立 0.x 版本线（要新增 ReleaseFamily，成本远大于收益）。
5. Android 侧单一来源：`stage-runtime.ts:97` 目前会**再写一份** package.json（name/version/exports 覆盖），与源目录 manifest 必须合并成一个来源，否则改名后必有一处漂移（`apps/android/docs/remote-dsh-plan.md:563` 已记录该风险）。
6. 发布前演练：`pnpm run release:pack` → `pnpm run release:verify-packed-install`（CI 发布 lane 已有，`release-publish.yml`/`release.yml`）必须通过；`pnpm run build:official` 与 `release:verify` 走一遍。

**依赖**：无新增运行时依赖；发布需要 npm 组织权限与 CI secrets。

**风险**：① 一旦公开发布，包就承担公开 API 兼容承诺（运行时是 App 与宿主共同加载的 `.mjs` 门面，改动面大）；② 改名是 mechanical 但跨 50+ 文件（Android 验收脚本/parity manifest 最容易漏）；③ 发布链路需要一次真实 release 演练才能确认闭环。

**工期**：1–2 天（改名+门禁+README/发布字段）+ 一次 release 演练。

#### B. 只随宿主安装包内置（单独不可行，可作为 A 之后的附加形态）

关键事实：**Desktop 安装器本身也只吃 release family 的 tarball**（见 §2.1 第 5 条），所以 B 无法绕过"运行时必须是可打包成员"。可行变体是：让 desktop 打包流水线额外 `pnpm pack` 这个私有包并作为 `--from` 输入（`prepare-package-set.ts` 的 `--from` 已支持多目录），安装包里带一份私有副本、**不发布到公网 npm**。但：

- npm CLI 路径照旧断（`@deepseek-ai/dsh` 的发布依赖仍指向它）→ 要么从 CLI 依赖里移除并放弃 `dsh --profile remote-host` 的 npm 用户，要么做"按需安装"新机制；
- 要动 release + desktop 两条流水线与门禁；收益只是"不发 npm"。

结论：B 不是 A 的替代，而是"决定不公开、只发 Desktop"时的 A 变体，仍需完成 A1 的成员化改造（版本/字段/门禁）。

#### C. 仅源码 / 私有 registry（内部）

保持现状（`private: true`，只从工作区运行），或发到私有 registry（需要用户机器配置 registry+token，且 release 工具链要支持非 `@deepseek-ai` scope 与 `private` 白名单）。适合当前阶段自用；若目标受众包含外部用户，C 不能交付。

### 2.3 推荐

**A1 > A2 > C > B**。理由：A1 让"同一份运行时源码"同时服务 Android APK、PC 宿主、npm CLI 与 Desktop 安装器，且 diff 可控；A2 迁移目录收益小破坏面大；C 只适合自用；B 单独不可交付。

### 2.4 需要用户/团队决策的清单

1. **包名与 scope**：改成 `@deepseek-ai/dsh-android-runtime`（推荐，符合发布工具）还是保留 `@minnnng`（需改 release 工具与门禁，且 npm scope/发布令牌归属个人账号）。
2. **目标受众**：公开发布 npm / 仅 Desktop 安装器 / 仅内部源码——决定走 A1、B 变体还是 C。
3. **是否接受运行时成为公开 API 表面**（发布即承诺兼容）。
4. **版本策略**：家族统一版本（推荐）vs 独立 0.x（需新增 ReleaseFamily）。
5. **`@deepseek-ai/dsh-remote-host` 的发布身份**：它已是发布成员（`apps/remote-host/package.json` 有 publishConfig/repository），但它依赖未发布的运行时 → 现在发布就是"坏包"；必须与运行时同一批决策。
6. **Android APK 与 npm 包的单一来源**：`stage-runtime.ts` 的二次 package.json 收敛方式。

### 2.5 发布前检查清单（给施工 Agent）

- [ ] `apps/android/runtime/package.json`：名称/版本/`private`/`repository`/`publishConfig.access`/`engines`/`files`/README 齐全。
- [ ] family patterns 显式加 `apps/android/runtime/package.json`；`check-workspace-constraints` 的 app 目录正则与 `appPackageFiles` 支持该路径。
- [ ] 84 处包名引用改名完成；`stage-runtime.ts` 与源 manifest 合并为单一来源。
- [ ] `pnpm run release:pack` 产物里 `@deepseek-ai/dsh` 与 `@deepseek-ai/dsh-remote-host` 的依赖解析到**已发布**版本。
- [ ] `release:verify-packed-install` 通过（会实际安装并驱动 CLI）。
- [ ] Desktop：`prepare:packages` 闭包包含运行时，`package:win:x64`/`package:mac:*` 的 `verify` 通过。
- [ ] Android：`stage-runtime.ts` → `pack-runtime.ps1` → APK 构建/冒烟通过（`apps/android/tool/smoke-runtime.mjs`）。

---

## 3. 后台通知交付边界与前台服务架构

### 3.1 本轮（task-20/21）交付范围

- **宿主（task-20）**：新增 `apps/remote-host/src/notifications.ts`，观察门面 sink 的页面线通知（`task.completed` / `interactions.changed`），映射成 protocol §8.2 `remote.taskCompleted` / §8.3 `remote.approvalPending`（字段截断、`truncated`、帧上限 8/16 KiB、同一交互只发一次、只在 ready 连接发）；`apps/remote-host/src/index.ts` 注入；新增 `apps/remote-host/scripts/notification-selfcheck.ts`；e2e 增加断言。协议 §8.5 `remote.sessionChanged` 视成本决定（详见该任务报告）。
- **App（task-21）**：新增 `apps/android/lib/remote_notifications.dart`（帧解析/去重/前台抑制/注入式 bridge）与 Kotlin `RemoteNotifications.kt`（复用 `task-completed` / `agent-requests` 渠道，点击打开 App 带 `sessionId`）；`remote_connection.dart` 在原有 `remote.deviceRevoked` 之外处理 §8 通知；`MainActivity.kt` 接线。
- **共同边界**：**App 进程（含 Flutter engine）活着才有 WS**。前台不弹（由页面线呈现），退后台才弹；App 进程被杀/系统回收 → 连接断开、通知不可达；断线期间的通知按 protocol §7.1 **不重放**（丢了就丢了）。

### 3.2 现有限制的证据

| 事实 | 证据 |
|---|---|
| 远程 WS 在 Flutter/Dart 进程里 | `apps/android/lib/remote_transport.dart:574-593`（`WebSocket.connect` + 固定 CA）；`apps/android/lib/remote_connection.dart` 管理连接生命周期 |
| 远程模式按设计不申请前台服务 | `apps/android/docs/remote-dsh-plan.md:365`（§5.6 第 4 条） |
| UI 进程 = FlutterActivity 的默认引擎，Activity 销毁即引擎销毁 | `MainActivity.kt:33`（`class MainActivity : FlutterActivity()`）、`:262`（`configureFlutterEngine`），没有 `FlutterEngineCache`/`provideFlutterEngine` |
| 真正长期存活的是 `:agent` 进程 | `AndroidManifest.xml:36-38`（`AgentService`，`android:process=":agent"`、`stopWithTask="false"`、`foregroundServiceType="specialUse"`）；`AgentService.kt:40`（"Owns Node and its IPC endpoint; activity destruction does not terminate tasks."）、`:664`（`RuntimeProcessLease.start`，libnode） |
| 本地模式的通知/常驻通知已有成熟基建 | `BackgroundExecution.kt`（前台通知 channel `agent`、`startForeground`）；`TaskCompletionNotifications.kt` / `ApprovalNotifications.kt`；`AgentService.kt` 的帧分派（页面线与系统通知都从这里进） |
| 协议不重放 | `protocol.md:482-490`（§7.1） |

### 3.3 两条架构路线

#### 路线 1（推荐先做）：前台服务 + 缓存 FlutterEngine，保活 UI 进程

做法：Application（或 MainActivity）持有一个 `FlutterEngine` 并放进 `FlutterEngineCache`，Activity 用 `provideFlutterEngine` 复用；建立远程连接时在 UI 进程内启动一个新的前台服务（常驻通知「远程 DSH 已连接」），断开/切换设备/退出远程页时停止并释放引擎缓存。

- 收益：**Dart 侧传输、状态机、重连/回放语义一行不用改**；task-21 的 `lifecycleState != resumed` 判定在退后台时自然变成 `paused` → 系统通知按预期弹；改动集中在 Kotlin 生命周期与引擎，不动协议。
- 成本/风险：常驻通知（用户可见，需要产品接受）；Android 12+ 前台服务后台启动限制（连接建立时 App 通常在前台，合规；若在后台自动重连则需 `startForegroundService` 的豁免/改由通知触发）；Android 14 FGS 类型（现有 `specialUse` 的用法可作为模板，需要新的 subtype 说明）；**OEM 电池策略仍可能杀进程**（本机 ColorOS 是已知坑，需引导用户加白名单）；引擎常驻后插件/生命周期测试与内存要复核。
- 工期：3–4 天 + 真机矩阵（含厂商 ROM）。
- 验收：冷启动连接 → 建立连接后通知栏出现常驻通知；Home 键退后台 → 宿主完成任务 → 系统通知弹出；点击通知回到 App 并打开对应会话；`adb shell dumpsys notification` 能看到 `task-completed`/`agent-requests` 渠道与 tag；手动杀进程后不再有通知（已知边界）。

#### 路线 2（需要"进程被杀也不中断"时再评估）：把 transport 移出 UI 进程

- **2a Kotlin 服务持 WS**：在 `:agent` 进程（或新服务）用平台 WebSocket 客户端建连，Dart 侧把 socket 换成 `MethodChannel`/EventChannel 双向流；证书固定用自定义 TrustManager；`remote.*` 帧由 Kotlin 直接投递通知。注意协议 §7.1 无 resume：UI 重启后仍需重新握手，后台期间该连接只能作"通知通道 + 自动重连"，不能承载页面流——需要把它设计成独立的"后台通知连接"而不是 UI 连接复用。工作量 4–6 天，新增网络库依赖与 TLS 固定实现，双连接语义要评审。
- **2b transport 移进 Node runtime（`:agent` 的 libnode）**：让 `apps/android/runtime` 新增 wss 客户端（要么加 `ws` 依赖进 APK 资产，要么手写握手/分帧，约 200–400 行），实现固定 CA、TOKEN 经 native bridge 取、重连退避；UI 通过既有本地 RPC 消费同一套门面。优点：直接继承 `:agent` 进程的开机重启/崩溃恢复/前台服务生命周期，通知帧可以复用 `AgentService` 现有分派进 Kotlin 通知类；缺点：**工作量最大（6–8 天）**、双传输/多设备语义、Dart 侧 `RemoteRuntimeTransport` 与页面数据源要重构为"门面在 Node 侧"。
- 结论：先做路线 1；如果产品确实要求"手机后台甚至进程被杀后仍能收到任务完成/审批"，再评估路线 2，且优先 2b（复用既有长期进程），2a 只作为过渡。

### 3.4 明确交付边界（写给产品/用户）

- 本轮之后：**App 在后台、进程未被杀** → 能收到 `remote.taskCompleted`/`remote.approvalPending` 通知；**App 被系统/用户杀掉** → 断连，通知不可达，重连后也不补发（协议无重放），页面靠 `readWindow`/`interactions.list` 重新读。
- 通知与页面线是两条线：`remote.*` 只驱动系统通知；页面上的会话内容仍由 `session.event`/`readWindow` 等页面线提供（`protocol.md:525-536`）。
- 不把"通知可达"当作"连接可靠"：真正的可靠性仍是 App 打开后的自动重连（`remote_transport.dart` 的退避重连）。

---

## 4. 证据索引

| 事实 | 位置 |
|---|---|
| 配对窗口/重开/撤销服务 | `apps/remote-host/src/index.ts` 的 `RemoteHostHandle`、`ctx.provide(REMOTE_HOST_SERVICE, …)`（当前约 `:304-320`、`:428-432`、`:675-692`） |
| 配对票据与 USB 链接 | `apps/remote-host/src/index.ts` 的 `RemotePairingTicket`（`:296-302`）、`openPairingWindow`（`:599-632`）；`writePairingQr`（`:1090-1115`） |
| 终端二维码实现 | `apps/remote-host/src/pairing-qr.ts:174`（`QrMatrix`）、`:645`（`encodeQrMatrix`）、`:681`（`renderTerminalQr`） |
| 局域网发现 | `apps/remote-host/src/discovery.ts:41`、`:159`、`:197`、`:240`；协议 [discovery.md](discovery.md) |
| 配对端点/TLS | `apps/remote-host/src/server.ts`（`/app` `/ca.cer` `/pair` 常量与 HTTP 面） |
| App 配对入口 | `apps/android/lib/remote_pairing_page.dart:392-410`、`:432-449`；扫码 `PairingQrScan.kt`；`build.gradle.kts:203` |
| 运行时包身份 | `apps/android/runtime/package.json:2-4`、`:13-14` |
| 依赖与组件层 | `apps/remote-host/package.json:41`、`apps/cli/package.json:111`、`packages/util/official-bundles/src/bundles.ts:30-37`、`tsconfig.base.json:510`、`pnpm-workspace.yaml:15` |
| release 家族规则 | `scripts/release/families.ts:123-147`、`:348-371`；`scripts/release/verify-packed-install.ts:95-117` |
| Desktop 打包规则 | `apps/desktop/scripts/prepare-package-set.ts:74-108`、`:151-181`、`:185-196`；`apps/desktop/scripts/electron-builder-config.mjs:155-157` |
| 包发布文件策略 | `scripts/check-workspace-constraints.ts:81-91`、`:526-549`、`:564-571` |
| Android 运行时打包 | `apps/android/tool/stage-runtime.ts:17`、`:97`；`apps/android/tool/stage-runtime-plugin.mjs`；`apps/android/tool/pack-runtime.ps1` |
| 远程传输与前台限制 | `apps/android/lib/remote_transport.dart:574-593`；`apps/android/docs/remote-dsh-plan.md:365` |
| UI 进程/长期进程 | `MainActivity.kt:33`、`:262`；`AndroidManifest.xml:36-38`；`AgentService.kt:40`、`:664`；`BackgroundExecution.kt` |
| 通知协议 | `apps/android/docs/remote-dsh/protocol.md:482-490`（§7.1 无重放）、`:525-568`（§8.1-8.3） |
