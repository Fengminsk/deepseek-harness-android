# Android 定时唤醒

[English](schedule-wakeup.md) | 中文

## 概述

定时唤醒让 Android 在已保存的提醒到期时启动现有 agent（智能体）服务。该功能默认关闭，需要用户授予精确闹钟权限。Android 只保存唤醒索引；原有调度服务仍负责判断提醒是否有效、提交输入并记录结果。成功注册闹钟不代表任务已经送达。

## 目录

- [启用与状态](#enablement-and-status)
- [投影与归属](#projection-and-ownership)
- [闹钟投递与恢复](#alarm-delivery-and-recovery)
- [进程与开机限制](#process-and-boot-limits)
- [验证](#validation)
- [开发备注](#dev-note)

-----

## 启用与状态
<a id="enablement-and-status"></a>

[后台设置区块](../lib/schedule_wake_settings.dart) 分别展示启用偏好、Android 授权与观测到的闹钟状态。打开 Android 的精确闹钟设置不会自动开启调度。未获权限时，启用请求会被拒绝且不会保存启用偏好；关闭功能会使当前闹钟 token 失效。读取状态不会注册闹钟或更改设置。权限检查使用 `canScheduleExactAlarms()`；注册使用不可变 `PendingIntent` 和 `setExactAndAllowWhileIdle(RTC_WAKEUP, ...)`，受 Android [精确闹钟要求](https://developer.android.com/develop/background-work/services/alarms) 约束。

原生状态区分未知或不可用的目录、就绪但为空的目录、已安排投递、正在唤醒、缺少权限与操作失败。持久化写入失败会关闭该 controller 实例的唤醒准入，因为写入结果可能不确定。存储不存在时默认关闭；已有存储不可读或损坏时保留原记录、报告固定错误并禁用此功能，不使整个 agent 启动失败。显式恢复会重新读取存储记录，不会把坏记录替换为空记录。

## 投影与归属
<a id="projection-and-ownership"></a>

Android profile 注册的 [runtime 投影 owner](../runtime/native-schedule-wakeup.mjs) 先订阅变化，再读取原有调度目录。它只发送有效提醒数量和最早到期时间，或明确的不可用状态，不发送提示词、提醒 ID、Session ID 或账号数据。读取期间若发生已提交的调度变化，该过期结果不能重新安排闹钟。原生更新未得到确认时，owner 停止后续投影写入；本地取消不能证明 Android 已取消先前发出的写入。

[Controller](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeupController.kt) 只接受当前服务代次及递增修订号。新代次使旧 RPC 失效，但不删除未来闹钟；正常解绑也会保留该闹钟。每次重排先持久化旧 token 失效，再取消 Android 注册，并在安排新闹钟前创建新 token。记录只是索引，不是任务权威来源：投影和 receiver 都不提交模型输入、不更改提醒内容，也不重放结果不确定的 core 操作。原调度器的持久化与提交顺序保持不变。

## 闹钟投递与恢复
<a id="alarm-delivery-and-recovery"></a>

[Receiver](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeupReceiver.kt) 与 [Android owner](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeup.kt) 运行在 `:agent` 进程。匹配的 token 必须仍处于启用、已授权且到期状态，receiver 才会将其持久化为 `waking`。重复认领会失败。Service 随后重新检查同一个 `waking` token；直接发送 Service intent 不能认领仅处于已安排状态的闹钟。

闹钟可能刚注册成功，进程就死亡，留下带 token 的 `pending` 记录。冷启动后的实际投递可以直接认领该记录，无需先调用恢复。取消中的 pending 记录没有当前 token，不能认领；明确记录为注册错误的状态也仍被拒绝。恢复会先取消已追踪的旧注册，再按持久化的目标时间重试。`armedAtMs` 是实际闹钟目标时刻，即到期时间与当前墙上时钟两者的较大值；时钟回拨不能使旧 token 在该目标之前立即获得资格。

成功认领后，Android owner 请求一个带 120 秒超时的部分唤醒锁，并启动现有前台 agent 服务。它限制的是启动交接时间，不授予无限期任务锁。新鲜的后台观测确认到期事项已消除，且正常任务唤醒锁已持有或任务状态为 idle/attention 后，owner 释放交接锁。关闭功能、服务退出和启动失败也会释放它；到期时记录固定失败。前台服务准入、runtime 启动和厂商调度仍可能失败。交接本身不能证明提醒已执行，也不能证明设备始终可运行。

runtime 发生终态失败时，`AgentService.reportFailure` 在进程收尾前调用 [交接清理](../android/app/src/main/kotlin/com/minnnng/dsh_android/ScheduleWakeupHandoff.kt)。它核对服务代次，尝试为当前交接 token 记录 `runtime_unavailable`，并在 `finally` 中显式释放该交接锁。持久化失败不能跳过释放，也不能中断失败路径的进程退役。过期代次不能释放较新的交接锁，过期 token 也不能使较新的未来闹钟失效。

## 进程与开机限制
<a id="process-and-boot-limits"></a>

Android 闹钟可以在普通进程死亡后继续存在。系统强制停止不同：Android 15 及以上会取消该包的 pending intent，并保持停止状态，直到用户交互解除它。因此，强制停止测试不能代替普通进程死亡后的自然闹钟投递验收。实现不会绕过停止状态，也不修改系统或厂商白名单。参见 Android 的 [停止状态行为](https://developer.android.com/about/versions/15/behavior-changes-all#stopped-state)。

索引使用凭据加密的 App 存储，receiver 不支持 Direct Boot。恢复等待用户在开机后至少解锁一次；此时 `BOOT_COMPLETED` 提供 manifest（元数据清单）receiver 的恢复路径。首次解锁后再次锁屏，不会让凭据加密存储变得不可用。包替换、时钟或时区变化，以及精确闹钟权限授予，也会重新协调已存索引。manifest 中的 `USER_UNLOCKED` filter 不是独立恢复路径：Android 只向动态注册的 receiver 发送该 action。这些是 [Direct Boot](https://developer.android.com/privacy-and-security/direct-boot) 与 [广播](https://developer.android.com/reference/android/content/Intent#ACTION_USER_UNLOCKED) 的限制，不是厂商及时投递的保证。

## 验证
<a id="validation"></a>

主机 runner 使用 Android 的 JSON 实现编译生产 Kotlin controller、交接 helper 和 `RuntimeLifecycle`，并运行确定性的存储、闹钟及并发替身：

```powershell
node apps/android/tool/acceptance-schedule-wakeup-host.mjs
```

使用 `node apps/android/tool/acceptance-schedule-wakeup-host.mjs --handoff-only` 只执行五项终态交接检查；该参数不会重新运行 23 项 controller 检查。

真机验收仍需创建获授权的专用提醒，确认原生闹钟已经安排，普通终止 agent 进程，并在锁屏且两块物理面板均 Off 时由实际闹钟启动。等待期间不得由测试持有 CPU 锁或前台测试载体维持目标存活。证据必须将到期闹钟与新的 agent 进程、原调度器的持久任务结果对应起来。取消和替换必须拒绝旧 token，且不提交任务。撤销与重新授予权限、重启恢复分别需要独立证据，不能从进程死亡测试通过推断。任何 fixture（测试前置数据）只清理自己的提醒，并恢复其修改的偏好。本页尚未记录自然闹钟真机结果。

## 开发备注
<a id="dev-note"></a>

主机验证记录：controller 的 23 项检查通过，报告位于 `.cache/android/schedule-wakeup-host-mETBIN/report.json`。另一次 `--handoff-only` 运行针对真实 controller 与 `RuntimeLifecycle` 的五项检查通过，记录在 `.cache/android/schedule-wakeup-host-pWZLbA/handoff-report.json`。原终态失败路径已经调用 `killProcess`，进程死亡时操作系统会释放其唤醒锁。新增清理在退出前记录与代次绑定的失败并显式释放交接锁；这些检查不能证明此前存在 120 秒锁泄漏。

[投影测试](native-schedule-wakeup.test.mjs) 的 29 项检查通过。[设置测试](../test/schedule_wake_settings_test.dart) 与 [后台设置测试](../test/background_settings_test.dart) 原有 31 项检查通过，另有 1 项错误优先级回归单独通过，总计 32 项；没有将完整 32 项重新合跑。

[调度 profile smoke](smoke-schedule.mjs) 通过正式 bootstrap 和原始 `schedule_create` 工具/API，在 17.781 秒内通过。日志 `.cache/android/schedule-wakeup-profile-smoke-fixed.log` 记录了空目录 → 创建 → 重排 → 删除 → 空目录，投影修订号依次为 1、2、3、4。另一个近期待执行提醒生成了一条持久投递回执，指向所属 Session 中恰好一条已插入输入，随后转为 inactive。原生闹钟桥接使用 mock：`kind="protocol-only"` 且 `systemAlarmsRegistered=0`。这验证了宿主 profile 的原始调度器与投影路径，不是 Android 闹钟注册或真机自然唤醒。这些主机结果均不能证明长期 Doze 存活或此前的间歇性进程冻结已经修复。
