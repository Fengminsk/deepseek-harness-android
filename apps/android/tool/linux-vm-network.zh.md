# Linux VM HTTPS 主机验证

[English](linux-vm-network.md) | 中文

主机验证在现有 TinyEMU/Alpine 镜像内运行 Python，通过专用虚拟块设备发出有界 HTTPS GET，再在 Linux 内校验响应。它没有启用 Android App 内的网络，也不提供 socket、curl 路由、软件包下载或 Git 传输。Android VM 管理器、生产开关及默认 APK 保持原状。

## 运行

使用现有 Windows TinyEMU 主机构建、已固定的编译器运行库、JDK 17，以及镜像哈希已校验的 Alpine 候选。每次运行将证据保留在 `.cache/android/linux-vm-network/run-*`，不会回写源候选及其磁盘。验证器检查镜像字节和 JNI 源码/库身份，不验证候选中较早的对应源码归档；正式发布仍需重新验证完整源码集合。

```powershell
node apps/android/tool/acceptance-linux-vm-network.mjs
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=live
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=wrong-host
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=revoked
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=proxy-unavailable
```

第一条命令执行确定性的回环 TCP 与 mailbox 测试。live 模式需要指定的本地 HTTP 代理，读取 `https://example.com/`，在客体内验证 `Example Domain` 并记录正文哈希。wrong-host 模式返回已审计的策略拒绝。revoked 模式在客体请求解析目标域名时撤销租约，中止 VM 且不发布响应。proxy-unavailable 模式选择已关闭的回环端口，并要求收到离线结果，不允许回退到公网直连。报告包含原生与客体退出码，崩溃不会被算作拒绝成功。

## 请求与隔离规则

`LinuxVmHttpsMailbox` 接收专用直接内存映射和 App 持有的 `IsolatedExecutionPolicyOwner.Lease`。请求包含精确运行 UUID、新调用 UUID、序号、有界 URL 与 SHA-256。现有 HTTPS 代理执行实时精确域名策略、DNS/公网 IP 校验、重定向检查、截止时间及审计接纳。重复调用 ID 或非法帧会终止 mailbox。响应要求匹配的审计终态和有效租约，正文最多 64 KiB。文件授权、App 路径、凭据、任意请求头和原始 socket 均不跨越该映射。SHA-256 帧摘要用于检测数据撕裂；授权来自租约与通道绑定，而不是摘要。

验证使用 `/dev/vdd`，客体 Python 执行按扇区对齐的 `O_DIRECT` I/O。宿主只在解释器线程的控制台读取回调中、客体执行步骤之间轮询，因此原生块设备写入和 Java 帧读取不会并发。这不是供解释器和网络线程并发访问的共享内存 API。取消运行时必须关闭 mailbox 或撤销租约，才能关闭活动 socket；仅设置 VM 的共享取消标志，要到下一次回调才会被检查。撤销授权或修改代理配置必须终止旧租约，不能静默更换已接纳请求的路由。

`PinnedTlsTransport.throughLocalHttpProxy` 只连接可信配置所指定端口的 `127.0.0.1`，并对已校验的公网 IPv4 地址的 443 端口发出 CONNECT。随后使用默认信任根、原域名的 SNI 和 HTTPS 主机名校验建立 TLS。本地连接明确关闭 JVM 自动代理选择。代理拒绝、响应头非法或超限、超时与取消均会失败，不回退直连。旧构造函数为现有调用方保留随 DNS 绑定网络的直连行为。

## 仍需完成的 Android 接入

主机 CLI 授予测试租约，并对接纳与审计文件执行文件同步；目录同步回调明确属于主机测试夹具。这不代表 Android 持久授权、Binder 身份、目录 fsync、默认/VPN 路由、本地 FlClash 访问、进程终止恢复或锁屏行为已经验收。Android 接入必须将 mailbox 绑定到已接纳的隔离 Service，仅交付该映射，依据 `NetworkProxyPreferences` 选择路由，使用 `AndroidDeadlineResolver` 与 `AndroidNetworkJournal`，并在会话取消、策略或代理变更时终止 mailbox 和 VM。主机报告不宣称这些生产接入已经完成。
