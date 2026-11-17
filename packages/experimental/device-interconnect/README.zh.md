---
description: "在设置里托管 PC 侧远程宿主，并用页面长期保留的二维码配对手机。"
kind: "package-bundle"
---

# @deepseek-ai/dsh-device-interconnect

[English](README.md) | 中文

## 概述

一个 opt-in（默认不启用）的设置页：托管 PC 侧的远程 DSH 宿主。页面把宿主作为独立子进程启动和停止，展示长期有效的配对二维码与链接，编辑监听设置，并列出已配对手机、支持撤销。页面还可以托管 SakuraFrp `frpc` 子进程，通过 TCP 隧道把宿主的 TLS 端口发布到公网，并按隧道公网地址推导配对链接的对外地址。宿主本身不属于本包：插件只通过它只监听回环地址的配对控制 HTTP API 通信，因此官方 DSH 安装无需导入宿主的包即可加载本插件。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [延伸阅读](#further-exploration)
- [模型体验](#model-experience)
- [已知限制与后续工作](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用本包

### 安装并启用 bundle

`package.json` 声明了可安装的 `dsh.bundle` 层与浏览器入口。用插件管理器的 `install_bundle` 从本地目录安装，或在安装发布包后把包名加入 profile 的 `dsh.profile.bundles`。该 bundle 声明 `listedByDefault: false`，在 profile 显式列出之前不会出现在默认组合中。设置里会出现「设备互联」页；远程宿主在打开开关前保持停止。

页面渲染需要标准 Web 组合；远程宿主还需要它自己的可运行 profile（启动器的 `--profile` 参数）。在没有 Web 服务器服务的 profile 里，插件仍会加载、只记录一条 warn 日志、不注册任何桥接路由。

### 配置运行器

插件在仓库目录中以 `<node> <pnpm.mjs> dsh --profile <profile> --patch <生成的 overlay> --no-open` 启动远程宿主，并设置 `DSH_HOME` 与 `PATH` 中的 Node.js 目录。运行器（高级）区可编辑：

| 字段 | 含义 | 首次运行推断 |
| --- | --- | --- |
| `nodePath` | 运行启动器的 Node.js 可执行文件 | `DSH_DEVICE_INTERCONNECT_NODE`，否则 `$DSH_HOME/dsh-runtimes/*/dependencies/` 下的 node，否则当前进程可执行文件（仅在非 Electron 时） |
| `pnpmPath` | Node.js 运行的 `pnpm.mjs` | `DSH_DEVICE_INTERCONNECT_PNPM`，否则托管运行时的 `dependencies/pnpm/bin/pnpm.mjs` |
| `repoDir` | 子进程运行所在的仓库目录 | `DSH_DEVICE_INTERCONNECT_REPO`，否则留空 |
| `profile` | 子进程启动的 DSH profile | `remote-host` |
| `patchPath` | 在生成的 overlay 之后追加的 `--patch` | 留空 |
| `dshHome` | 传给子进程的 `DSH_HOME` | 留空则继承 DSH 主进程的值 |

路径为空或不存在时页面会如实报告，开关不会启动一条坏命令。生成的 overlay 在每次启动子进程时按监听设置重写，因此远程宿主不会以过期配置运行。

### 监听与配对设置

页面可编辑远程宿主的 `port`、`host`、`publicHost`、`publicOrigin`、UDP 局域网发现开关与端口、回环配对控制页开关与端口。保存会先校验整份配置，再原子写入 `$DSH_HOME/device-interconnect/config.json`，子进程运行中则重启以应用。长期配对默认开启：生成的 overlay 请求 30 天有效期的配对窗口，且远程宿主在每次配对成功后会打开新窗口，因此页面显示没有倒计时的二维码，下一台手机无需再操作本页即可配对。「重新生成配对链接」用于按需重开窗口。

`publicOrigin` 只接受 `wss://host[:端口]`，用于 TLS 终止反向代理或按域名部署；留空时按 `publicHost` 或默认路由 IPv4 地址生成。

### SakuraFrp TCP 隧道

页面可以托管 [SakuraFrp](https://www.natfrp.com/) 的 `frpc` 子进程，把远程宿主的 TLS 端口映射到公网，使不在同一局域网的手机也能配对。**必须使用 TCP 隧道**：远程宿主用固定 CA 自己做 TLS 终止，HTTP/HTTPS 隧道会在服务商侧终止 TLS，导致 App 的固定证书校验失败、永远连不上。隧道卡会写明这一限制，并拒绝以 `https://` 形式粘贴的公网地址。

1. 在 SakuraFrp 面板创建一条 **TCP** 隧道，本地目标填 `127.0.0.1:<远程宿主端口>`（默认 4777）。面板会分配节点域名与远程端口。
2. 在设置页打开「内网穿透（SakuraFrp）」，选择 **SakuraFrp** 并填写：

   | 字段 | 取值 |
   | --- | --- |
   | frpc 可执行文件 | 你从 SakuraFrp 获取的 `frpc`/`frpc.exe` 完整路径。插件只校验文件存在，不会自动下载。 |
   | 访问密钥 | SakuraFrp 面板 →「查看访问密钥」（与账户密码不同）。以明文保存在本插件配置文件中，且不会回传给页面。 |
   | 隧道 ID | 一条或多条 TCP 隧道 ID，英文逗号分隔：`114514` 或 `114514,114516`。 |
   | 公网地址 | 面板显示的 `<节点域名>:<远程端口>`，例如 `cn-xx.natfrp.cloud:12345`。不要带 `https://` 前缀；显式端口（如 `:443`）会保留。 |

3. **保存内网穿透设置**。页面推导 `publicOrigin = wss://<节点域名>:<远程端口>` 并写入生成的远程宿主 overlay；远程宿主正在运行时会自动重启，使新的配对链接使用该地址。配置了公网地址时它会覆盖上面的手填 `publicOrigin`，卡片会回显最终生效值。
4. **启动隧道** 会在远程宿主确认监听端口后启动 frpc 子进程。卡片显示子进程状态、最近输出，按钮变为 **停止隧道** / **重试**。停止隧道不会停止远程宿主。插件激活时，已配置的隧道会在远程宿主就绪后自动启动；关闭远程宿主开关或卸载 bundle 时会先停隧道。

必填项可以先留空保存——页面会列出缺失项并阻止启动，插件激活也不会 spawn 坏命令。高级区提供自定义 `frpc.ini`（以 `frpc -c <ini> -n` 启动，替代访问密钥与隧道 ID，但公网地址仍需填写以推导对外地址）与附加 frpc 参数。frpc 以 `-n --disable_log_color` 运行，不自动更新且日志无颜色控制符。

### 安全模型

远程宿主的控制 API 只绑定 `127.0.0.1`；本插件的桥接路由拒绝任何非回环 `Host` 头与跨站 `Origin`。每个读写还必须带 `x-dsh-device-interconnect: 1` 头——跨站页面要设置它就必须通过本 Host 从不批准的 CORS 预检；响应不返回任何 CORS 头。唯一免该头的是二维码图片路由：`<img>` 必须能加载它，而它不泄露页面本已展示之外的信息。所有响应都带 `Cache-Control: no-store`。接受的本地威胁是常规情况：同一台电脑上的其它进程本就能读取配置文件与子进程日志。

SakuraFrp 访问密钥在桥接上是只写的：state 只返回 `tokenConfigured: true`，页面不会再次显示密钥，也不会写进日志。但它仍以明文保存在 `$DSH_HOME/device-interconnect/config.json`，同样适用本地读取威胁；页面留空表示保留已存密钥，清除需要显式的 `clearToken`/`null` 写入。插件从不下载 frpc：可执行文件路径由用户提供，只做存在性校验。

### 卸载

在插件管理器中移除该 bundle；插件在卸载时先停止隧道、再停止远程宿主。`$DSH_HOME/device-interconnect/`（配置——含已保存的访问密钥——与生成的 overlay）会保留以便重新安装，可手动删除。已配对设备保存在远程宿主一侧，不在本包内。

-----

<a id="understand-the-implementation"></a>
## 理解实现

### Host 插件与 HTTP 桥

`apply` 读取配置文件、构建一个 `Bridge`、在 `ctx.webServer` 上注册一个 `/device-interconnect/api` 前缀路由（用 `ctx.get` 读取，因此没有 Web 服务的 profile 也能加载），并注册两个子进程 supervisor 的清理。路由只接受本机回环的 JSON；每个动作都返回完整运行时快照，页面无需再拼接第二次读取：

| 方法与路径 | 请求体 | 效果 |
| --- | --- | --- |
| `GET /device-interconnect/api/state` | — | 配置（不含访问密钥）、远程宿主子进程状态与日志尾部、隧道子进程状态、推导出的对外地址与就绪状态、控制面事实、配对视图、设备、运行器就绪状态 |
| `POST /device-interconnect/api/enabled` | `{enabled}` | 持久化远程宿主开关并启动或停止该子进程 |
| `POST /device-interconnect/api/tunnel` | `{enabled}` | 启动或停止隧道子进程，不改变远程宿主开关 |
| `POST /device-interconnect/api/config` | `{config}` | 校验完整配置文档、持久化，运行中则重启子进程；`tunnel.token` 只写（`null` 或 `clearToken` 清除） |
| `POST /device-interconnect/api/pair` | — | 通过控制面重开配对窗口 |
| `POST /device-interconnect/api/devices/revoke` | `{deviceId}` | 撤销一台已配对设备 |
| `GET /device-interconnect/api/logs` | — | 远程宿主子进程输出尾部 |
| `GET /device-interconnect/api/tunnel/logs` | — | 隧道子进程输出尾部 |
| `GET /device-interconnect/api/qr.svg` | — | 代理当前窗口的二维码 SVG，页面 `<img>` 同源加载 |

失败返回 `{error: {code, message}}`，稳定 code 由页面映射到自己的字典文案。

### 子进程 supervisor

每个子进程（远程宿主与 frpc）各由一个 `ChildSupervisor` 实例独占：stdout 与 stderr 汇入 64 KiB 的日志尾部；`start` 幂等；`stop` 在 Windows 用 `taskkill /T /F` 结束进程树（其它平台发信号）并等待退出；`restart` 应用新配置；清理时停止子进程。启动顺序由 bridge 保证：远程宿主的控制面报告 `listener` 就绪后才启动隧道；远程宿主重启或停止时先停隧道；隧道失败不会停掉远程宿主。`/api/state` 的读取缓存一秒，多个已打开页面按两秒轮询也不会成倍增加回环请求。

### 回环控制面客户端

`createControlPlane` 在这个进程边界上逐字段校验远程宿主 `/api/state` 的 JSON，并用控制头调用 `/api/pair` 与 `/api/devices/revoke`。控制面不可达是快照里的一个字段而不是异常：页面会把宿主显示为未运行并说明原因。

### 浏览器页面

浏览器半注册 `settings.section` 条目（id `device-interconnect`，order 15，label 来自字典）、对应的 `settings.section.icon` 图标，以及 en/zh 字典。`DeviceInterconnectController` 持有快照 store 与轮询驱动：挂载的页面调用 `open`，卸载时调用 `close`，文档隐藏时暂停轮询，每个动作后刷新快照。页面展示开关与状态、长期配对卡、监听设置、已配对设备（含确认弹层）、可折叠的内网穿透卡（服务商选择、frpc 字段、生效对外地址、隧道状态与输出）、可折叠的运行器字段与远程宿主输出。

-----

<a id="further-exploration"></a>
## 延伸阅读

- [远程宿主组合](../../../apps/remote-host/cordis.patch.yml) — 本包托管的 PC 侧层。
- [插件管理页面](../../client/ui-plugin-manager/README.zh.md) — 安装、启用、移除 bundle。
- [Host Web 服务器](../../host/webserver/README.zh.md) — 桥接路由注册所用的路由表。

-----

<a id="model-experience"></a>
## 模型体验

None, as 本设置页只托管独立子进程（远程宿主与可选的 frpc 隧道），不向模型上下文、工具或 Session 事件添加任何内容。

#### KV Cache effect

本包不添加请求内容，因此既不增长也不使已缓存请求前缀失效。切换开关只影响独立的子进程，本 Host 上的 DSH Session 不受影响。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- **远程宿主不随本包分发** —— 插件启动的是一个已存在的 checkout，其中必须包含远程宿主 bundle 与挂载它的 profile。官方 DSH 安装可以加载本页面，但在配置路径上没有可用 checkout 或打包运行时之前无法启动宿主。
- **控制 API 就是远程宿主的本机配对页** —— 配对窗口状态、长期窗口、`/api/pair`、`/api/devices/revoke` 与 `/qr.svg` 都是 `apps/remote-host` 的契约。配对页缺少某个契约端点的 checkout 只会让对应动作报告失败，页面其余部分照常工作。
- **页面没有远程访问** —— 桥接有意拒绝非回环 `Host` 头，因此监听非回环地址的 DSH 实例无法从另一台机器使用本设置页。这是安全边界，不是缺失功能。
- **Windows 进程树结束依赖 `taskkill`** —— 在没有 `taskkill` 的平台上，停止后孙进程可能仍存活；supervisor 会记录超时，而不是报告一次干净停止。
- **只有 TCP 隧道能保留远程宿主的 TLS** —— App 固定信任远程宿主的 CA，因此 HTTP/HTTPS 类型的 SakuraFrp 隧道（TLS 在服务商处终止）无法工作。隧道卡会拒绝 `https://` 公网地址并说明限制，不会自动回退到其它隧道类型。
- **SakuraFrp 访问密钥明文存储** —— 桥接不回传、日志不记录，但 `$DSH_HOME/device-interconnect/config.json` 中以明文保存，可被本机其它进程读取。按与配对配置相同的本地读取威胁接受。
- **frpc 由用户自备** —— 插件不自动下载隧道客户端（供应链安全），因此由用户填写 SakuraFrp 提供方的可执行文件路径；文件不存在时隧道无法启动。
- **隧道推导出的对外地址会覆盖手填值** —— 配置了公网地址时，上面的手填 `publicOrigin` 被忽略，改用 `wss://<节点域名>:<端口>`；清空公网地址后，下次保存或启动会恢复手填值。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>维护者上下文 —— 点击展开</summary>

无。

</details>
