# 自然定时唤醒验收

[English](schedule-wakeup-device.md)

此验收检查 Android 闹钟能否启动新的生产 AgentService 进程，并把提醒投递到原会话。前置条件是用户授权精确闹钟、开启定时唤醒，并在锁屏前让 App 主进程和 AgentService 保持运行。验收不会打开设置、授予权限、启动 Activity 或点亮屏幕。缺少前置条件只记为 `needsUserAction`，不算自然唤醒成功。

## 入口与证据

[驱动程序](acceptance-schedule-wakeup-device.mjs) 在同一进程内负责屏幕保护，应直接运行。通用验收子进程包装器会在清理时强停整个包，进而取消闹钟。四个 instrumentation 阶段都使用 `am instrument --no-restart`，并要求主进程 PID 已存在。普通 instrumentation 结束时可能强停整个包，因此缺少该选项会使观察无效。

```powershell
node apps/android/tool/acceptance-schedule-wakeup-device.mjs --adb C:/Android/platform-tools/adb.exe --serial DEVICE --report .cache/android/schedule-status.json --mode status
node apps/android/tool/acceptance-schedule-wakeup-device.mjs --adb C:/Android/platform-tools/adb.exe --serial DEVICE --report .cache/android/schedule-natural.json --mode run --accept-real-account-request true
```

连续测试需要让 OLED 屏幕持续不发光时，在任一命令末尾追加 `--keep-display-off true`（`cleanup` 同样支持）。确认验收载体退出后，保护器让手机休眠，核对不可交互且所有物理屏幕均为 Off，并保留灭屏覆盖；报告写入 `retainedWhileNonInteractive=true`，不会调用 `power-reset`。省略该选项则保持原行为，在清理后恢复系统屏幕控制。本驱动的选项必须显式填写 `true`。

这些设备命令尚待验证。`status` 只读取前置状态。`run` 仅接受当前可用的 `deepseek-account` 默认模型，不使用后备模型；创建一个随机专用会话，要求只调用一次延迟 180 秒的 `schedule_create`。它要求没有其他活动提醒或任务，核对保存的创建事件和原生闹钟时间，解除绑定，再普通终止已核对的 Agent PID。它不会强停整个包，也不修改服务商设置、凭据、唤醒偏好或权限。人工提交只有一次，但模型后续请求和自动标题生成可能产生多次网络请求。

向 Agent 发信号前，载体解除绑定、保存退役记录、确认原 Binder 端点仍能响应，并要求 ActivityManager 的进程记录和服务记录同时匹配 PID、UID 与完整进程名。最终身份核对与发信号之间不再写磁盘。只有 `Os.kill(pid, 0)` 返回 `ESRCH` 才确认进程消失；权限拒绝或其他探测错误均保持退出未确认。验收不依赖跨进程 `/proc` 文件的可见性。固定退役子步骤分别定位 RPC、解绑、身份、记录落盘、信号和退出等待失败，不输出异常正文。

自然等待期间没有 instrumentation、测试服务、绑定或测试 CPU 锁。主机只观察完整进程名与当前服务状态。成功要求旧 Agent 在到期前持续不存在，之后出现不同的 Agent PID，且其当前 ServiceRecord 启动 intent 为 `SCHEDULE_WAKE`；历史日志中的同名记录不算证据。`observe` 不使用 `BIND_AUTO_CREATE`，只绑定已经运行的服务；它检查精确的提醒回执、原始调度器消息格式、未改变的创建历史、完成的第二轮及持久化的最终标记回复。

## 清理与限制

清理仅取消本次尚未完成的任务，删除 UUID 归属的提醒，归档自己的会话，并取消自己的完成通知。合成所有权记录保留在 App 私有存储中，报告只保存其哈希。失败或取消使用独立且有时限的清理阶段。服务不存在时不会为清理而启动它，而是报告退出未确认；用户打开 App 后，操作者可使用 `--mode cleanup --case-id UUID` 重试。已有记录与失败报告保持保留。

退出确认表示本次 instrumentation 和主机 ADB 客户端已退出，且自己的任务已停止。原先的 App 主进程继续保留，报告明确写入 `mainPreserved=true` 和 `wholeAppRetired=false`。默认情况下，屏幕保护只有在锁屏、不可交互且所有内置物理屏幕均为 Off 时才恢复系统控制；退出状态未知时不能恢复，也不能确认持续灭屏成功。保留灭屏覆盖不会把失败任务改判为验收成功。

只读 `status` 失败后，即使独立清理确认没有活动 instrumentation、本次 ADB 客户端已关闭且主进程 PID 未变，验收仍然失败。这只确认验收载体退出，不证明自然投递，也不停止 App。任务清理失败时，还必须取得本次任务已停止的证据，才能确认退出。

失败报告可穿过屏幕保护的 `AggregateError` 包装保留驱动自己创建的 `result`。固定 `hostStage` 区分 `main-query`、`idle-preflight`、`instrument`，以及自然等待期间的被动观察与清理操作。`failureCode` 和 `nativeFailureCode` 保留最初错误；`cleanupFailureCode`、可选的 `cleanupNativeFailureCode` 和 `cleanupHostStage` 单独记录清理失败。可选的 `lastProgress` 只包含匹配本次用例的固定原生 `phase`、`stage` 及有界 `elapsedMs`；进度缺失不能证明原生执行停在哪一步。诊断不包含异常正文、堆栈或原始 ADB 输出，也不改变期限与验收要求。

## 主机验证

```powershell
node --test apps/android/tool/acceptance-schedule-wakeup-device.test.mjs
node apps/android/tool/acceptance-schedule-wakeup-device-host.mjs
```

主机入口无需 Gradle 即可编译 AndroidTest 载体，并使用原始调度消息格式与 LLM 消息工厂验证实际 Kotlin 事件校验器，不访问账号或设备。这些检查不能证明自然闹钟投递、权限撤销、重启恢复或长期后台可靠性。自然唤醒真机验收仍待执行。
