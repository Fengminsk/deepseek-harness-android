# 隔离脚本设备验收

中文 | [English](isolated-script-device-acceptance.md)

## 范围与前提

仅用于测试的[`IsolatedScriptAcceptanceInstrumentation`](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/IsolatedScriptAcceptanceInstrumentation.kt)在 Android 10 及以上版本指向 App 的 `:agent` 进程。它调用内部[`IsolatedScriptRunController`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptRunController.kt)，并绑定真实隔离 Service；不会开启模型可见的 PTC 工具。Android 的[`targetProcesses`](https://developer.android.com/guide/topics/manifest/instrumentation-element)属性用于选择该进程。测试 APK 编译成功不能证明设备行为。

先准备匹配的调试版 App APK 与测试 APK，再询问是否可以使用手机。测试 APK 由 `:app:assembleDebugAndroidTest` 构建，位于 `apps/android/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk`。只有在用户同意测试窗口后，才在空闲的普通无 Root 测试手机上运行；安装 App APK 或终止 `:agent` 会打断已有任务。测试只改动自行创建的 App 私有标记、工作区、审计日志和运行回执，不请求宽泛的存储或网络授权。

## 设备运行

安装匹配的 App 和测试 APK 后，下列命令是计划使用的普通验收入口。它**尚未在设备上执行**：

```sh
adb shell am instrument -w -e phase normal com.minnnng.dsh_android.test/com.minnnng.dsh_android.IsolatedScriptAcceptanceInstrumentation
```

结果 Bundle 报告 `passedCount` 和 `failedCount`。普通阶段检查 JSON 结果与不同的客体 UID、持久完成和重复运行 ID 拒绝、两个纯计算客体的并行准入与完成、没有直接 Node 文件／网络及 Java 桥 API、读取私有标记及调用 HTTPS `fetch` 均返回 `ReferenceError`、无限循环超时、取消、App 主线程阻塞时仍能完成，以及错误 guest 请求后的 Binder 死亡。它还检查真实隔离客体读取一个 App 批准的精确文件，并在执行前拒绝尾斜杠目录授权，留下终态回执。可选文件能力用例读取 App 签发的精确文件授权、拒绝重复调用 ID 和未授权编辑，并对额外的路径字段作终态拒绝。网络用例使用合成 DNS 解析器和传输层，检查精确域名授权、无效 URL 与私网 DNS 结果拒绝、每次调用的终态审计，以及在 DNS 阶段撤销后不进入传输。这些用例不访问外网，也不能验证 Android 设备上的真实 DNS 路由或 TLS 实现。标记和 `fetch` 检查只证明相关 JavaScript API 不存在，**不能**证明内核拒绝文件系统或 Socket 访问。主线程用例会故意阻塞 App 主线程最多 3.6 秒，只能在 App 空闲时运行。

可选的进程死亡阶段需要两个新的 UUID 和空闲测试手机。`kill-agent` 在出现 `ADMITTED` 回执后终止 `:agent`；`kill-running-agent` 等待客体文件调用写入持久的 `CALL_SETTLED` 审计记录，再终止 `:agent`。两次 instrumentation 命令预计都会异常结束。随后用原来的 `runId` 和另一个 `recoveryRunId` 执行 `recover`：它启动新运行，核对旧回执已转为 `INTERRUPTED_UNCONFIRMED`，并确认旧 ID 无法再次执行。第二个阶段能确认客体代码已经进入 App 文件代理，但无法证明 App 进程死亡的瞬间客体仍在运行。这两个阶段都尚未在设备上执行；只有用户提供可操作手机且没有用户任务运行时才能执行。

主机命令 `node apps/android/tool/acceptance-isolated-execution-approval.mjs` 启动独立 JVM 准入进程，并在未关闭策略写入器时结束进程。新进程检查恢复后的策略默认拒绝、一次性批准 ID、无输出的中断终态、重复 ID 拒绝，以及迟到完成结果无法发布。它提供可重复的持久化验收，不代表 Android Service 或客体进程的运行结果。

## 验收边界

开放 PTC 之前，还需从真实 guest 测试 App 私有文件、授权范围之外的工作区、SAF URI 和直接 Socket 均被拒绝，以及通过 App 能力代理授权的版本校验编辑与限定 HTTPS。内部的[文件调用桥](isolated-script-host-bridge.zh.md)与按需授权的[HTTPS 代理](isolated-network-broker.zh.md)都需要 App 签发的策略租约；当前没有模型可见的 PTC 入口。记录 Android 版本、安装包版本、客体 UID、结果 Bundle 和所有 `RETIRE_UNCONFIRMED` 回执；不能把传输失败当作成功。
