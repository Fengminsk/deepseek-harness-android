---
description: "在设置里托管 PC 侧远程宿主，并用页面长期保留的二维码配对手机。"
kind: "package-bundle"
---

# @deepseek-ai/dsh-device-interconnect

[English](README.md) | 中文

## 概述

一个 opt-in（默认不启用）的设置页：托管 PC 侧的远程 DSH 宿主。页面把远程宿主作为独立子进程启动和停止，展示长期有效的配对二维码与链接，编辑宿主的监听设置，并列出已配对手机、支持撤销。远程宿主本身不属于本包：插件只通过它只监听回环地址的配对控制 HTTP API 通信，因此官方 DSH 安装无需导入远程宿主的包即可加载本插件。

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

### 安全模型

远程宿主的控制 API 只绑定 `127.0.0.1`；本插件的桥接路由拒绝任何非回环 `Host` 头与跨站 `Origin`。每个读写还必须带 `x-dsh-device-interconnect: 1` 头——跨站页面要设置它就必须通过本 Host 从不批准的 CORS 预检；响应不返回任何 CORS 头。唯一免该头的是二维码图片路由：`<img>` 必须能加载它，而它不泄露页面本已展示之外的信息。所有响应都带 `Cache-Control: no-store`。接受的本地威胁是常规情况：同一台电脑上的其它进程本就能读取配置文件与子进程日志。

### 卸载

在插件管理器中移除该 bundle；插件在卸载时停止子进程。`$DSH_HOME/device-interconnect/`（配置与生成的 overlay）会保留以便重新安装，可手动删除。已配对设备保存在远程宿主一侧，不在本包内。

-----

<a id="understand-the-implementation"></a>
## 理解实现

### Host 插件与 HTTP 桥

`apply` 读取配置文件、构建一个 `Bridge`、在 `ctx.webServer` 上注册一个 `/device-interconnect/api` 前缀路由（用 `ctx.get` 读取，因此没有 Web 服务的 profile 也能加载），并注册 supervisor 的清理。路由只接受本机回环的 JSON；每个动作都返回完整运行时快照，页面无需再拼接第二次读取：

| 方法与路径 | 请求体 | 效果 |
| --- | --- | --- |
| `GET /device-interconnect/api/state` | — | 配置、子进程状态与日志尾部、控制面事实、配对视图、设备、运行器就绪状态 |
| `POST /device-interconnect/api/enabled` | `{enabled}` | 持久化开关并启动或停止子进程 |
| `POST /device-interconnect/api/config` | `{config}` | 校验完整配置文档、持久化，运行中则重启子进程 |
| `POST /device-interconnect/api/pair` | — | 通过控制面重开配对窗口 |
| `POST /device-interconnect/api/devices/revoke` | `{deviceId}` | 撤销一台已配对设备 |
| `GET /device-interconnect/api/logs` | — | 子进程输出尾部 |
| `GET /device-interconnect/api/qr.svg` | — | 代理当前窗口的二维码 SVG，页面 `<img>` 同源加载 |

失败返回 `{error: {code, message}}`，稳定 code 由页面映射到自己的字典文案。

### 子进程 supervisor

`HostSupervisor` 独占那一个子进程：stdout 与 stderr 汇入 64 KiB 的日志尾部；`start` 幂等；`stop` 在 Windows 用 `taskkill /T /F` 结束进程树（其它平台发信号）并等待退出；`restart` 应用新配置；清理时停止子进程。`/api/state` 的读取缓存一秒，多个已打开页面按两秒轮询也不会成倍增加回环请求。

### 回环控制面客户端

`createControlPlane` 在这个进程边界上逐字段校验远程宿主 `/api/state` 的 JSON，并用控制头调用 `/api/pair` 与 `/api/devices/revoke`。控制面不可达是快照里的一个字段而不是异常：页面会把宿主显示为未运行并说明原因。

### 浏览器页面

浏览器半注册 `settings.section` 条目（id `device-interconnect`，order 15，label 来自字典）、对应的 `settings.section.icon` 图标，以及 en/zh 字典。`DeviceInterconnectController` 持有快照 store 与轮询驱动：挂载的页面调用 `open`，卸载时调用 `close`，文档隐藏时暂停轮询，每个动作后刷新快照。页面展示开关与状态、长期配对卡、监听设置、已配对设备（含确认弹层）、可折叠的运行器字段与子进程输出。

-----

<a id="further-exploration"></a>
## 延伸阅读

- [远程宿主组合](../../../apps/remote-host/cordis.patch.yml) — 本包托管的 PC 侧层。
- [插件管理页面](../../client/ui-plugin-manager/README.zh.md) — 安装、启用、移除 bundle。
- [Host Web 服务器](../../host/webserver/README.zh.md) — 桥接路由注册所用的路由表。

-----

<a id="model-experience"></a>
## 模型体验

None, as 本设置页只托管独立的远程宿主进程，不向模型上下文、工具或 Session 事件添加任何内容。

#### KV Cache effect

本包不添加请求内容，因此既不增长也不使已缓存请求前缀失效。切换开关只影响一个独立的子进程，本 Host 上的 DSH Session 不受影响。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- **远程宿主不随本包分发** —— 插件启动的是一个已存在的 checkout，其中必须包含远程宿主 bundle 与挂载它的 profile。官方 DSH 安装可以加载本页面，但在配置路径上没有可用 checkout 或打包运行时之前无法启动宿主。
- **控制 API 就是远程宿主的本机配对页** —— 配对窗口状态、长期窗口、`/api/pair`、`/api/devices/revoke` 与 `/qr.svg` 都是 `apps/remote-host` 的契约。配对页缺少某个契约端点的 checkout 只会让对应动作报告失败，页面其余部分照常工作。
- **页面没有远程访问** —— 桥接有意拒绝非回环 `Host` 头，因此监听非回环地址的 DSH 实例无法从另一台机器使用本设置页。这是安全边界，不是缺失功能。
- **Windows 进程树结束依赖 `taskkill`** —— 在没有 `taskkill` 的平台上，停止后孙进程可能仍存活；supervisor 会记录超时，而不是报告一次干净停止。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>维护者上下文 —— 点击展开</summary>

无。

</details>
