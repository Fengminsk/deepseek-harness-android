---
kind: reference
title: 原生 Linux 联网审批
---

# 原生 Linux 联网审批

[English](linux-network-native-approval.md) | 中文

## 摘要

[原生协调器](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmNetworkApprovalCoordinator.kt) 仅在现有原生审批对话框记录可信用户决定后，将待处理的 Linux 联网请求转换为一次性令牌。JSON 请求不能授予权限。[模型准入所有者](linux-network-admission.zh.md) 负责 Session 策略、审计和刷盘要求；[Linux 网络代理](linux-vm-network.zh.md) 负责允许的 HTTPS 流量。

## 目录

- [审查与界面](#review-and-ui)
- [消费与退役](#consumption-and-retirement)
- [主机检查](#host-checks)
- [开发说明](#dev-note)

<a id="review-and-ui"></a>
## 审查与界面

`native.linuxVm.network.review` 接收模型准入所有者定义的运行 ID、Session ID、调用 ID、原始审批审计 ID、命令、超时、持久化选择、精确域名列表及网络调用预算。原生校验在准备审批前拒绝多余字段、无效标识和预算。不可变请求包含 App 当前选择的代理路由，并写入独立的私有运行目录。Inbox 快照将该请求绑定到仅含网络权限的作用域：没有文件根目录、可读或可写路径，文件调用次数为零，只有精确批准的域名和有界网络调用次数。

请求只会提交给已注册且处于 resumed 状态的 [MainActivity](../android/app/src/main/kotlin/com/minnnng/dsh_android/MainActivity.kt)，不会在后台启动 Activity。没有可用前台界面时，请求返回 `unavailable`。[玻璃对话框](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedApprovalDialog.kt) 从原生 Inbox 获取命令、路由、域名、超时及持久化选择，并在展示前检查预期快照。关闭对话框会拒绝请求。批准沿用现有原生 Messenger 手势通道；App JSON 回复和模型提供的布尔值都不能批准请求。

待处理审批在 120 秒后过期。Inbox 的持久化批准产生包含 `allowed-once` 结果、审批 ID、不透明 UUID 令牌和路由摘要的回复。未消费令牌在 30 秒后过期。拒绝、取消和不可用回复均不含令牌、审批 ID 或路由。原生策略租约持续时间为已审查命令的超时加五秒，最长 125 秒；这不会延长命令超时。

批准的路由是已应用到 Agent 进程的配置。该已应用路由变化时，待处理和未消费的审批失效，正在使用的租约也会被撤销。只在 Flutter 进程保存设置并不代表立即跨进程撤权；现有应用配置或重启流程仍负责使配置生效。

<a id="consumption-and-retirement"></a>
## 消费与退役

`native.linuxVm.executeNetwork` 将令牌、运行、Session、命令、超时、持久化选择及审批审计 ID 与审查过的请求匹配，然后再次检查已应用路由。只有一个调用方能够消费令牌。原有持久化策略所有者先写入准入标记，随后协调器才将五个执行字段、已准入的仅网络租约和捕获的路由传给真实 VM 管理器。重用令牌或改变字段既不能再次派发命令，也不能撤销已合法运行的命令。

`native.linuxVm.network.cancelReview` 只撤销待处理请求或未消费令牌。先于审查到达的取消会建立有界取消记录，防止乱序到达的请求获得权限。令牌消费后，取消由 `native.linuxVm.cancel` 和原执行结果负责；迟到的审批取消不会取消该次运行。请求和结果不确定的命令都不会自动重放。

Inbox 关闭和服务关闭会同步撤销租约，原生取消与持久化清理则在 Inbox 锁和主 Looper 之外执行。执行清理保留 VM 管理器的真实终态回执。每份完整联网回执都包含 `approvalCleanupConfirmed`；清理未确认时，附加稳定分类 `durable-revocation-unconfirmed`，保留实际执行及磁盘发布事实，并停止新审批，直到重建协调器。这不代表命令没有产生影响。

协调器关闭在共同的 15 秒时限内等待条目清理和取消工作线程结束。超时或持久化拒绝失败仍属于失败；关闭流程不会把未确认退役报告为成功。历史私有审批记录会保留，新存储实例不会从中恢复有效租约。

<a id="host-checks"></a>
## 主机检查

使用 JDK 17 或更新版本、仓库缓存的 Kotlin 编译器依赖及 Android 36 SDK 源码，运行 `node apps/android/tool/acceptance-linux-network-approval.mjs`。[运行器](acceptance-linux-network-approval.mjs) 使用 SDK JSON 实现编译生产协调器、Inbox、策略所有者和审批存储，然后执行[所属检查](../android/app/src/test/kotlin/com/minnnng/dsh_android/LinuxVmNetworkApprovalCoordinatorTest.kt)。临时输出限制在仓库缓存内，并在运行后移除。

检查覆盖无界面、字段绑定、单次消费、待处理及未消费过期、路由变化、提前和迟到取消、并发重复执行、持久化批准或准入失败、非阻塞 Inbox 关闭、等待清理线程，以及清理失败后保留真实结果。界面决定由测试直接调用，VM 执行器和目录同步使用测试回调。这些主机检查不能认证 Android 用户手势、Binder 身份、Android 目录持久性、真实客体 HTTPS 流量、屏幕行为或进程终止恢复。

<a id="dev-note"></a>
## 开发说明

[服务集成](../android/app/src/main/kotlin/com/minnnng/dsh_android/AgentService.kt) 负责协调器生命周期和三个原生 RPC 方法，并保留独立的手动隔离脚本审批路径。原生联网仍受产品现有能力可用性检查约束；该协调器不会启用这些能力。
