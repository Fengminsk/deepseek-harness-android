# Android 完成回执进程终止验收

中文 | [English](task-completion-device-acceptance.md)

`TaskCompletionCrashInstrumentation` 在 App 的 `:agent` 进程使用生成的会话标识。保持阶段通过 `TaskCompletionNotifications` 发送合成成功完成信号，等待完成序号水位与匹配的待投递回执提交，再阻塞主线程，使通知暂时无法显示。脚本随即强停该进程，在新的 Agent 进程检查一条匹配通知、已清理的回执、未改变的水位，以及过期和无效合成回执均未产生通知。清理阶段只删除生成的偏好设置键与通知。本项验收会中断 App 进程，需要获准使用的开发安装包，并开启完成通知。

App 和 AndroidTest APK 从相同源码、相同签名构建后，可先在不操作手机的情况下核验包名与测试声明：

```sh
node apps/android/tool/acceptance-task-completion-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

用户允许占用手机后运行真机阶段。现有安装必须明确传入 `--allow-existing`；该参数允许保留应用数据原位安装 APK，并强停当前 App 进程。Android 13 及更新版本应先在 App 中授予通知权限。脚本不会代替用户授权，也不会清除应用数据。被阻塞的主线程需尽快强停，避免 ANR。

```sh
node apps/android/tool/acceptance-task-completion-device.mjs --apk <app.apk> --test-apk <androidTest.apk> [--serial <adb-serial>] [--allow-existing]
```

`node --test apps/android/tool/acceptance-task-completion-device.test.mjs` 检查清单、崩溃窗口状态、新进程结果和失败输出的严格解析。真机通过只证明一次 Agent 进程强停后的回执投递；探针不启动真实模型任务，也不能证明 Android 恢复会话任务时没有重跑。原版 Android profile 的会话不重跑宿主场景由 `node apps/android/tool/task-recovery-smoke.mjs` 验证；锁屏、断网、Service 销毁和通知权限变化下的真实任务仍需分别验收，才可声称完整后台验收通过。若真机验收失败，脚本会打印生成的标识，合成回执可能留作诊断；刻意不支持用同一标识直接重跑。
