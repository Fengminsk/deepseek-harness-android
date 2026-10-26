# Android 隔离 guest echo 诊断

[English](guest-echo-diagnostic.md) | 中文

本参考说明 [`IsolatedGuestBackend`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedGuestBackend.kt) 与 [`IsolatedGuestService`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedGuestService.kt) 实现的受限 `diagnostic.echo` Binder 验证。它不是 JavaScript 或工作流执行器，不运行模型生成的文本，也未接入仍被禁用的 `ptc-runtime`、`workflow-ptc` 或 `tool-workflow` 模块。

App 只接受规范 JSON 请求：恰好包含 `version: 1`、`binding: "diagnostic.echo"` 和一个 `input.text` 字符串。完整帧最多 8 KiB，UTF-8 文本最多 4 KiB；[`GuestEchoFrame`](../android/app/src/main/java/com/minnnng/dsh_android/GuestEchoFrame.java) 拒绝未知绑定、额外字段、非规范编码、错误 Unicode 和多余字节。App 仅把请求标识及该帧发送给不可导出的 `isolatedProcess` 服务。guest 向 App 发起唯一允许的 echo 回调；App 检查 Binder 发送者 UID、请求及调用标识、单次调用限制和回显文本，才接受最终帧。此诊断接口不传递路径、文件描述符、账号令牌、凭据服务或 Node 环境；broker 消息只使用固定绑定，不向宿主透传任意操作名。

每个请求只有一个终态：`COMPLETED`、`CANCELLED`、`TIMED_OUT`、`WORKER_DIED` 或 `ERROR`。App 只记录先到的终态；取消或超时会发送取消消息并解除绑定。Android 10 及以上为每个请求使用不同名称的隔离服务实例；Android 9 使用系统提供的共享隔离服务绑定。两种情况均不运行脚本或子进程。主机 Java 测试覆盖规范输入准入及终态竞争，不构成真机 Binder UID、进程死亡或服务回收证据。

协议保留带版本的绑定字段，供后续按原版工作流的 `begin`、`startChild`、`childResult`、`disposeChild` 和进度报告设计宿主回调；当前解析器一律拒绝这些操作。启用通用 PTC 仍需另行评审脚本引擎、显式文件及工具 broker、审批与日志、进程及后代终止，以及 [PTC 与工作流隔离](ptc-workflow-confinement.zh.md) 所列真机证据。
