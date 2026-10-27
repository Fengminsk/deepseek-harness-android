# Android 工作流进程终止验收

此可选设备测试跨两个仪器测试阶段执行真实的 Android 进程停止。第一阶段在应用的 `:agent` 进程中启动隔离 Binder 工作流，等子任务预留持久记录进入 `LAUNCHING` 后，停在子任务结果回调。它先 fsync 本次运行的标记，再通过 instrumentation 状态报告标记，不再需要调试版 `run-as`。运行器观察 Agent 与隔离客体 PID，然后强制停止整个应用，并确认这两个进程名均无存活 PID。新的 `:agent` 进程读取同一私有标记和回执。生产恢复必须取得旧进程租约锁，只退役归属该租约的进程内子任务，保持旧任务中断且无输出，不重放回调；随后新准入须能正常取消。测试不再手动退役新版样例子任务。

隔离服务使用每次运行独立的实例名；即使使用 `ps -w`，Android 仍可能截断进程 argv。因此运行器先通过 ActivityManager 的服务进程记录核对完整运行 UUID，再独立核对该 PID 出现在存活进程列表中。固定的 `pidof :ptc_script` 查询不能证明客体不存在。显式停止应用后，所有这些运行实例的客体 PID 都必须消失。

无需连接手机，即可预检安装包、签名和精确的 Agent 进程清单声明：

```sh
node apps/android/tool/acceptance-native-workflow-process-death-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

手机可用且明确授权这项会中断应用的测试后：

```sh
node apps/android/tool/acceptance-native-workflow-process-death-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --accept-force-stop [--serial <adb-serial>] [--allow-existing]
```

运行器通过 `adb install -r` 安装匹配的 APK 对，并强制停止整个应用。AndroidTest APK 必须针对与 App 相同的 release/debug 目标和代码压缩配置构建；调试测试 APK 与 R8 正式目标不是有效组合。已有安装未经 `--allow-existing` 明确授权就拒绝运行。生成的应用私有工作流回执会保留以供检查。失败运行可能留下中断测试任务，重试前应核对回执。运行器不会删除用户文件或清空应用数据。解析测试：`node --test apps/android/tool/acceptance-native-workflow-process-death-device.test.mjs`。

旧回执没有进程租约，绝不自动退役。可通过 `adb shell am instrument -w -r -e phase inspect-legacy com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeWorkflowProcessDeathInstrumentation` 仅列出待回收标识。核查精确旧任务后，在上述已授权命令中添加 `--retire-legacy-run <run-uuid>`。该独立模式重新核对这一个任务、观察旧 Agent PID、强制停止应用并要求 Agent 与客体进程均已消失，再启动新的 instrumentation 进程。它先持久写入 `files/workflow-legacy-retirement/<run-uuid>.json` 审计，再确认列出的子任务停止；任务本身保持中断且无输出。模型工具和生产 RPC 均不提供此迁移入口，也没有批量重置或删除回执。

若真机运行通过，可证明真实应用进程停止后的回执行为。夹具使用合成回调后端；它不能证明 `AgentService`／Node 的启动顺序、真实子 Agent 副作用、任意操作系统杀进程、后台持续运行或 PackageManager 升级。这些需要单独真机验收。面向模型的工作流闸门仍关闭。
