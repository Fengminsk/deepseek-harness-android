# Android 完成回执进程终止验收

中文 | [English](task-completion-device-acceptance.md)

`TaskCompletionCrashInstrumentation` 在 App 的 `:agent` 进程使用生成的会话标识。保持阶段通过 `TaskCompletionNotifications` 发送合成成功完成信号，等待完成序号水位与匹配的待投递回执提交，再阻塞主线程，使通知暂时无法显示。脚本的下一条命令强停 App，随后等待保持阶段 ADB 客户端实际关闭，并确认没有 App、测试或隔离服务进程残留。新的 Agent 进程必须投递一条匹配通知、清除已提交回执、保留水位，并抑制过期及无效合成回执。最终原生清理只移除本 token 生成的偏好设置键与通知。不涉及模型请求、账号修改或真实会话创建。

可先在不操作手机的情况下核验同源码、同签名的 App 与 AndroidTest 包：

```sh
node apps/android/tool/acceptance-task-completion-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

真机执行要求获准使用的现有安装、已开启完成通知，以及已锁屏且不可交互的手机。必须提供下列全部参数和新的报告路径。脚本核验本地包名、签名及仪器身份，再将两个已安装 base APK 的 SHA-256 与所提供产物逐一比较；缺失、不匹配或拆分安装都会被拒绝。`--installed-only` 从不安装、降级、清除数据、授予权限、启动 Activity 或发送屏幕／锁屏输入。`--allow-existing` 授权中断这份安装；准入前和 hold 前都必须通过完整进程名检查，确认没有 App 或测试进程。

```sh
node apps/android/tool/acceptance-task-completion-device.mjs --adb <adb-path> --serial <adb-serial> --apk <exact-installed-app.apk> --test-apk <exact-installed-test.apk> --allow-existing --installed-only --no-wake --report <new-report.json>
```

`runTaskCompletionEntry(args, { signal })` 负责报告和 ADB 适配器；`runTaskCompletionCrashAcceptance(io, options)` 负责保持、强制终止、核验及退役。[屏幕保护所有者](device-screen-protection.zh.md)可以在同进程中传入取消信号并等待入口完成。独立 CLI 通过相同路径处理 SIGINT/SIGTERM。锁屏／不可交互检查不是物理面板证据，必须保留外层的面板观察及设备退役确认。仪器命令结束或请求杀死客户端都不能单独证明退役。

普通 ADB 命令上限为八秒，hold 就绪上限为 20 秒，verify 或 token 清理上限为 30 秒；客户端结果结束最多另需 3.5 秒。收到已提交回执的 hold 就绪后，不再发额外观察 RPC 延误强停。等待保持阶段客户端关闭最多 20 秒。取消或失败使用独立清理作用域，强停 App 和测试包、停止并等待所有自有 ADB 子进程关闭，再以完整名称观察 App／测试／隔离服务进程，最多 20 秒加有界命令延迟。关闭未确认、强停失败或残留进程都会阻止确认退役及通过；工作取消不会取消这项清理。

原生 token 清理只在验证成功后执行，随后发生取消也一样。验证失败不能绕过原生“回执已确认”的要求；报告会保留 token，并标记 `syntheticStateMayRemain: true`。清理失败使成功结果无效。报告保留生成的 token、精确产物摘要、有界阶段结果、失败阶段／类型，以及独立的宿主／设备退役事实，不输出任意工具内容、通知原文或账号数据。工作前以排他方式预留报告，清理后再写入结果，已有路径不会覆盖。持久化失败时，抛出错误和备用诊断仍保留脱敏结果。宿主被强杀或 USB 失联仍可能留下合成状态或未知退役结果，应保留 token 做限定调查，不要清除用户数据。

`node --test apps/android/tool/acceptance-task-completion-device.test.mjs` 检查安装身份精确匹配、锁屏及无进程准入、立即强停顺序、延迟关闭、取消、原生验证／清理失败、残留检测、报告预留及真实宿主子进程终止。这些宿主检查不证明设备投递。下述真机通过只证明一次 Agent 进程强停后的合成回执投递，不证明真实模型任务、会话重跑行为、通知交互或完整后台任务生命周期。独立真实账号证据由[账号任务验收](agent-service-task-device.zh.md)记录。

## Build 116 r35 真机结果

`.cache/android/completion-crash-116-r35-result-20261028.json` 记录通过，配套屏幕报告将 `result` 替换为 `screen`。本轮只验证既有安装，没有重装：正式 App SHA-256 保持 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`，AndroidTest SHA-256 为 `dc06f94ba4fc2861f8e861609e4d52350afb64127b208f5e36169eb2a2b6a926`。hold PID 为 24363，强停后 verify PID 为 24431，cleanup PID 为 24496。匹配通知存在、无效通知未出现、回执已清理，本 token 的合成状态清理也通过。

报告确认两包强停、所有自有宿主客户端关闭及设备进程退役；`cleanupFailures` 为空，`syntheticStateMayRemain` 为 false。外层四次采样均记录两块 OLED 面板 Off，并在不可交互状态下恢复屏幕控制。本轮没有唤醒操作，使用已锁屏／不可交互的入口；这些仍是有限采样，不代表连续屏幕观测或长时间后台存活，也不证明真实任务在进程死亡后重新执行或恢复。
