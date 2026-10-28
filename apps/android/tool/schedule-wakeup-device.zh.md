# 自然定时唤醒验收

[English](schedule-wakeup-device.md)

此验收检查 Android 闹钟能否启动新的生产 AgentService 进程，并把提醒投递到原会话。前置条件是用户授权精确闹钟、开启定时唤醒，并在锁屏前让 App 主进程和 AgentService 保持运行。验收不会打开设置、授予权限、启动 Activity 或点亮屏幕。缺少前置条件只记为 `needsUserAction`，不算自然唤醒成功。

## 入口与证据

[驱动程序](acceptance-schedule-wakeup-device.mjs) 在同一进程内负责屏幕保护，应直接运行。通用验收子进程包装器会在清理时强停整个包，进而取消闹钟。四个 instrumentation 阶段都使用 `am instrument --no-restart`，并要求主进程 PID 已存在。普通 instrumentation 结束时可能强停整个包，因此缺少该选项会使观察无效。

```powershell
node apps/android/tool/acceptance-schedule-wakeup-device.mjs --adb C:/Android/platform-tools/adb.exe --serial DEVICE --report .cache/android/schedule-status.json --mode status
node apps/android/tool/acceptance-schedule-wakeup-device.mjs --adb C:/Android/platform-tools/adb.exe --serial DEVICE --report .cache/android/schedule-natural.json --mode run --accept-real-account-request true
```

这些设备命令尚待验证。`status` 只读取前置状态。`run` 仅接受当前可用的 `deepseek-account` 默认模型，不使用后备模型；创建一个随机专用会话，要求只调用一次延迟 180 秒的 `schedule_create`。它要求没有其他活动提醒或任务，核对保存的创建事件和原生闹钟时间，解除绑定，再普通终止已核对的 Agent PID。它不会强停整个包，也不修改服务商设置、凭据、唤醒偏好或权限。人工提交只有一次，但模型后续请求和自动标题生成可能产生多次网络请求。

自然等待期间没有 instrumentation、测试服务、绑定或测试 CPU 锁。主机只观察完整进程名与当前服务状态。成功要求旧 Agent 在到期前持续不存在，之后出现不同的 Agent PID，且其当前 ServiceRecord 启动 intent 为 `SCHEDULE_WAKE`；历史日志中的同名记录不算证据。`observe` 不使用 `BIND_AUTO_CREATE`，只绑定已经运行的服务；它检查精确的提醒回执、原始调度器消息格式、未改变的创建历史、完成的第二轮及持久化的最终标记回复。

## 清理与限制

清理仅取消本次尚未完成的任务，删除 UUID 归属的提醒，归档自己的会话，并取消自己的完成通知。合成所有权记录保留在 App 私有存储中，报告只保存其哈希。失败或取消使用独立且有时限的清理阶段。服务不存在时不会为清理而启动它，而是报告退出未确认；用户打开 App 后，操作者可使用 `--mode cleanup --case-id UUID` 重试。已有记录与失败报告保持保留。

退出确认表示本次 instrumentation 和主机 ADB 客户端已退出，且自己的任务已停止。原先的 App 主进程继续保留，报告明确写入 `mainPreserved=true` 和 `wholeAppRetired=false`。屏幕保护只有在锁屏、不可交互且所有内置物理屏幕均为 Off 时才恢复系统控制；退出状态未知时不能恢复。

## 主机验证

```powershell
node --test apps/android/tool/acceptance-schedule-wakeup-device.test.mjs
node apps/android/tool/acceptance-schedule-wakeup-device-host.mjs
```

主机入口无需 Gradle 即可编译 AndroidTest 载体，并使用原始调度消息格式与 LLM 消息工厂验证实际 Kotlin 事件校验器，不访问账号或设备。这些检查不能证明自然闹钟投递、权限撤销、重启恢复或长期后台可靠性。自然唤醒真机验收仍待执行。
