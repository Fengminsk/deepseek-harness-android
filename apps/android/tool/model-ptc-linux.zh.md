---
kind: reference
title: Android PTC 中经审查的 Linux 工具
---

# Android PTC 中经审查的 Linux 工具

[English](model-ptc-linux.md) | 中文

## 摘要

[Linux 审查模块](../runtime/model-ptc-linux-review.mjs)允许已准入的 Android PTC 程序组合父执行的原版 `linux_import`、`linux_exec`、`linux_export`、`linux_inspect` 工具。它支持连续文件分析，不向 PTC 客体提供 Node API、App UID Shell、原生文件或网络授权。PTC 和 Linux 的产品可用性仍要求各自既有的设备验收开关；父作用域内不存在的工具，在 PTC 中也不会出现。

## 目录

- [权限与执行](#authority-and-execution)
- [结果与取消](#results-and-cancellation)
- [验证](#verification)
- [开发说明](#dev-note)

<a id="authority-and-execution"></a>
## 权限与执行

审查只捕获准确、有效的原厂定义及注册身份。每次调用保留活动父执行的 ToolRuntime 令牌和 Agent Session。同名替换注册也不能继承审查。原版 Linux 工具继续解析当前 Session 策略及可能存在的工作流子 Agent 授权；PTC 不向模型参数增加文件根目录、Session 身份、持久化覆盖值或审批令牌。

`linux_import` 和 `linux_export` 需要当前可写策略。导入读取获准的当前 Agent 工作区；导出拒绝已有目标、受保护元数据及工作区外路径。只读策略下的 `linux_exec` 会丢弃客体磁盘改动。原生所有者照常进行首次 Session 检查、单执行槽准入和退役确认。`linux_inspect` 只报告当前 Session，不重放或解锁此前任务。[Linux 工具说明](linux-vm-runtime.zh.md)负责这些执行及传输语义。

联网参数仍只是请求，不是授权。联网 `linux_exec` 经过原有 ApprovalService 和[原生单次审批](linux-network-native-approval.zh.md)，绑定同一命令、调用者、审计 ID、域名、预算、持久化选择及已应用路由。审批拒绝或 PTC 取消都不能产生执行授权。PTC 不能批准自己的请求，也不能把空的原生网络作用域当作 Linux 联网权限。

PTC 的 120 秒总耗时限制仍覆盖整个程序，包括每次 Linux 启动、审批等待和命令执行，不会按调用重置。各 Linux 超时继续受原版工具上限约束。PTC 调用串行执行，Linux 步骤使用既有的 App 全局单执行槽；其他所有者占用时返回失败，不代表可以自动重放。长任务需要使用时限合适的直接 Linux 调用，不能假设 PTC 会延长命令生命周期。

<a id="results-and-cancellation"></a>
## 结果与取消

`linux_exec`、`linux_import`、`linux_export` 使用经审查的 `isolated-execution` 效果，即使某次执行会丢弃客体改动也是如此。它们要求回调开始记录和终态记录之后的 Session 刷盘均成功，才能确认日志并向客体交付。不能通过标为纯计算或只读跳过持久化。`linux_inspect` 保留既有的只读 append 行为。[回调端口](isolated-tool-call-port.zh.md)负责分发与日志顺序。

Linux 结果保留全部有界原生字段；48 KiB 客体限额不会静默丢弃发布或退役事实。结果过大时明确返回不支持错误，并要求检查记录的回执及 `linux_inspect`，不会自动重跑命令。后续命令应限制输出；需要较大回复限额时使用直接工具。原生截断仍是原生工具自身的事实。

原版 Linux 延后上下文会转交父执行并记录，即使 ToolRuntime 将晚到成功归一化为取消。已发布的导出因此可以同时保留 `filePublished:true`、`diskCommitted:false`、`cancelRequested:true`。回调关闭等待真实嵌套调用结束；日志或 Session 刷盘未确认时，不发布 PTC 成功，也不改写已知提交事实。恢复检查、发布不确定或联网审批清理未确认，均保留原有停止并核对行为。错误不表示回滚。

<a id="verification"></a>
## 验证

`node --import tsx --test apps/android/tool/model-ptc-linux.test.mjs` 运行原版 AgentLoop、ToolRuntime、Linux 工具工厂、NativeLinuxVm 解析及取消、ApprovalService、PTC 回调桥和 JSONL 持久化。[记录投影](expected/model-ptc-linux.expected.json)保留导入、执行、导出、检查的顺序。原生 PTC 和 Linux 传输明确使用模拟夹具；真实临时文件读写验证组合路径，不代表客体文件系统或 Android 发布证据。Windows 运行沙箱拒绝 `MoveFileExW` 时，原版 Session 原子发布需要主机权限。

检查覆盖实时策略和定义变化、文件范围与禁止覆盖、两次刷盘屏障、取消前已发布、输出超限、原生恢复拒绝、原版单次联网准入，以及审批等待期间取消。它们不能认证原生 UI 手势、客体 Python 执行、Android UID／Binder 隔离、网络流量、共享总耗时终止或进程死亡恢复。

`node apps/android/tool/acceptance-ptc-linux-tools.mjs` 使用 SDK JSON 编译并执行真实 Kotlin 请求解析器，验证四个 Linux 名称仅向经审查 PTC 开放，拒绝环境权限工具、未审查名称和畸形帧，并保留相互独立的回执事实。共享[主机编译器](kotlin-host-test.mjs)需要 JDK 17 或更新版本、缓存的 Kotlin 编译器依赖及 Android 36 SDK 源码，不会组装或安装 APK。改变可用性前，仍须在已安装产物上验收生产 PTC 到 Linux 的调用链及取消路径。

`ptc` 设备套件在[夹具](device-runtime-acceptance/ptc-linux.mjs)中声明 `reviewed-ptc-linux-import-analysis-export`。它在现有真实 AgentLoop 轮次中调用生产 PTC 工具，由隔离 JavaScript 客体调用原版 Linux 导入、Python JSON 分析、导出及检查。新的验收 Session 首次检查必须为 absent；没有预热命令或替代原生实现。三次客体启动共享未变的 120 秒 PTC 总时限。承载器只增加等待本项检查的时间，不增加执行权限。缺少客体资产、执行过慢或退役未确认都记为失败。

检查读取真实导出字节，独立核对 SHA-256、长度及计算结果、原生导入导出路径、原始 Linux 运行 ID、App／PTC／Linux UID 隔离、磁盘提交和文件发布事实。它刷盘父 Session 并重新打开持久化读取器，验证四组回调开始与结束记录、三份原始 Linux 回执及最后的检查上下文。注册位于可释放 fiber 中，使 `all` 后续可以挂载 Linux 套件自己的所有者。只移除以 UUID 命名的验收文件；Session 日志与原生执行记录保留为证据。

`node --import tsx --test apps/android/tool/device-runtime-acceptance-ptc-linux.test.mjs apps/android/tool/device-runtime-acceptance-report.test.mjs` 检查夹具验证器在证据不全时拒绝通过、生成程序遇到不确定结果后停止、原版 Cordis 注册清理，以及报告必须包含准确名称。它还在真实主机临时文件上运行相同的内嵌 Python 程序。验证器的合成观察和主机 Python 执行都不是设备证据。在已安装的成对产物上执行前，新增设备调用链仍未验证；它也不认证 PTC 到 Linux 的取消、共享时限到期、联网审批或进程死亡恢复。这些边界独立于离线调用链成功。

<a id="dev-note"></a>
## 开发说明

该适配仍是经过审查的工具子集，不是原版不受限的 Node PTC 环境。主机组合成功或声明计数变化，都不能补足缺少的生产设备证据。
