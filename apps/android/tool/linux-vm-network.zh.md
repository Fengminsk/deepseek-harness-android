# Linux VM 有界 HTTPS

[English](linux-vm-network.md) | 中文

Android 实现通过 App 批准的精确域名租约，为 `dsh-fetch` 提供有界 HTTPS GET。普通 Linux 执行仍然离线。这不是 socket 接口，也不为 curl、包管理器或 Git 提供路由。原生代码与设备夹具已通过独立编译；设备验收与模型审批 UI 仍需分别取证。主机验证启动同一 TinyEMU/Alpine 镜像并运行随 App 提供的客户端，但不能据此认定 Android 已验收或开启生产开关。

## 运行

使用现有 Windows TinyEMU 主机构建、已固定的编译器运行库、JDK 17，以及镜像哈希已校验的 Alpine 候选。每次运行将证据保留在 `.cache/android/linux-vm-network/run-*`，不会回写源候选及其磁盘。验证器检查镜像字节和 JNI 源码/库身份，不验证候选中较早的对应源码归档；正式发布仍需重新验证完整源码集合。

```powershell
node apps/android/tool/acceptance-linux-vm-network.mjs
python -B -m unittest apps/android/tool/test_linux_vm_network_client.py
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=live
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=wrong-host
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=revoked
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=proxy-unavailable
```

第一条命令执行确定性的回环 TCP、mailbox、App 请求处理与损坏响应测试；Python 命令验证随 App 提供的客户端的帧解析和连续调用序号。live 模式需要指定的本地 HTTP 代理，读取 `https://example.com/`，在客体内验证 `Example Domain` 并记录正文哈希。wrong-host 模式返回已审计的策略拒绝。revoked 模式在客体请求解析目标域名时撤销租约，中止 VM 且不发布响应。proxy-unavailable 模式选择已关闭的回环端口，并要求收到离线结果，不允许回退到公网直连。报告包含原生与客体退出码，崩溃不会被算作拒绝成功。

## 请求与隔离规则

`LinuxVmHttpsMailbox` 在隔离 Service 内持有专用直接缓冲区。请求包含精确运行 UUID、新调用 UUID、序号、有界 URL 与 SHA-256。`LinuxVmNetworkGuest` 发出有界 Binder 请求；`LinuxVmRunner` 将真实发送者 UID 与已启动的隔离 Service 匹配，`LinuxVmNetworkHostBridge` 检查本轮 nonce。App 持有的 `LinuxVmHttpsBrokerExchange` 在调用现有 HTTPS 代理前，独立检查运行身份、调用序号、租约及预算。响应要求匹配的审计终态和有效租约，正文最多 64 KiB。非法帧、重放、并行请求或未确认审计会终止该能力。文件授权、App 路径、凭据、任意请求头和原始 socket 均不跨越此通道。SHA-256 检测帧字节撕裂；授权来自租约与 Binder 绑定。

客户端对 `/dev/vdd` 执行按扇区对齐的 `O_DIRECT` I/O，并用文件锁串行化不同客户端进程。隔离解释器仅在执行步骤之间的控制台读取回调中轮询。App 不映射此缓冲区，只由有界工作线程接收已复制的 Binder 字段。取消或撤销租约会关闭传输、唤醒客体等待者并停止 VM。代理变化会使已捕获路由失效，而不是替换已接纳调用的路由。管理器返回前等待网络线程退场；未确认的清理属于结果不确定，不能作为成功重试依据。

`PinnedTlsTransport.throughLocalHttpProxy` 只连接可信配置所指定端口的 `127.0.0.1`，并对已校验的公网 IPv4 地址的 443 端口发出 CONNECT。随后使用默认信任根、原域名的 SNI 和 HTTPS 主机名校验建立 TLS。本地连接明确关闭 JVM 自动代理选择。代理拒绝、响应头非法或超限、超时与取消均会失败，不回退直连。旧构造函数为现有调用方保留随 DNS 绑定网络的直连行为。

## Android 授权与待完成的设备证据

`LinuxVmManager.executeApprovedNetwork` 要求可信 App 代码提供精确接纳的租约、会话及运行身份，以及已审阅的代理快照。它拒绝文件授权，不会从模型提供的域名或 `approved` 布尔值推导许可。调用方必须将命令、持久化选择、超时、域名、预算和路由绑定到用户的一次性批准。管理器读取 `NetworkProxyPreferences`，使用 `AndroidDeadlineResolver` 与 `AndroidNetworkJournal`，并为本次执行将内置客户端注入 `/tmp`。网络失败不允许回退直连。取消到达时若磁盘已经发布，该发布仍然有效；应检查最终回执。

`LinuxVmNetworkAcceptanceInstrumentation` 在 Agent 进程内使用自己的 UUID 会话和持久测试批准。模式包括 `wrong-host`（审计终态为策略拒绝）、`budget`（第二次请求使 VM 退场）、`revoked`（观察到夹具自己的拒绝审计提交后撤权）和 `live`（在 Linux 内校验公网 HTTPS 内容）。它保留自己的审计，不修改代理偏好或用户授权。这些测试批准不能证明面向模型的审批 UI 已验收。Android Binder 身份、目录持久性、默认/VPN 和本机 FlClash 路由、进程终止及锁屏行为仍待设备取证；主机报告明确保留这一限制。

设备夹具使用[黑色前台验收窗口](device-runtime-acceptance.zh.md)：手机必须已解锁且可交互，黑窗必须完成绘制并持有焦点，失去可见性会撤销测试租约。它不会唤醒或解锁手机。用户要求连续屏幕保护时不可运行；启动 instrumentation 或替换进程无法保证这一保护。
