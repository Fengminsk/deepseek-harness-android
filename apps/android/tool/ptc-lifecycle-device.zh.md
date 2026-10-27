# PTC 进程终止与 SAF 验收

[English](ptc-lifecycle-device.md) | 中文

## 摘要

这些可选检查验证 PTC 是否将中断的文件改动保留为未确认状态，以及撤销 Android 文档授权后是否停止后续访问。它们使用专用验收会话、由 UUID 派生的目录和生成的文档，不重置应用数据，也不撤销任何既有文档授权。测试需要签名匹配的应用和 AndroidTest 安装包。默认的[纯黑验收窗口](device-runtime-acceptance.zh.md)会拒绝锁屏或非交互状态的手机。显式选择 service 模式后使用[无界面验收服务](acceptance-foreground-service.zh.md)，可在锁屏时运行，不会唤醒或解锁手机。两种模式均不能保证安装或进程终止期间的物理屏幕电源状态；这一要求由外部物理电源守护负责。

## 目录

- [进程终止](#进程终止)
- [文档搜索与撤权](#文档搜索与撤权)
- [验证范围](#验证范围)

## 进程终止

[宿主运行器](acceptance-ptc-process-death-device.mjs)校验 APK 身份及真实 Node 验收入口声明。`--preflight-only` 会在访问设备前结束。设备运行必须传入 `--accept-force-stop`；使用既有安装还必须传入 `--allow-existing`。安装使用 `adb install -r`。强制停止会中断该应用内的全部工作，因此设备所有者必须授权这项中断性测试。运行器不会清空存储、卸载应用或删除审计记录。它等待自己启动的 ADB 准备进程及标准流关闭后才输出成功；即使已经收到恢复结果，进程启动错误或未确认完成的清理仍会使验收失败。

验收入口选择套件 `ptc-process-death`、阶段 `prepare` 或 `recover`，以及一个生成的 `caseId`。其私有主目录以该 UUID 结尾，工作区以 `.ptc-death-<caseId>` 结尾。恢复仅接受原有且身份一致的配置，并恢复 `ptc-death-<caseId>` 会话。[Node 验收模块](device-runtime-acceptance/ptc-process-death.mjs)通过真实模型 PTC 所有者、原生隔离回调适配器和持久回调日志，调用原始 `write` 工具。文件写入并同步后，它暂停回调，让日志保留在 `dispatch-unconfirmed`。私有就绪文件含有准入令牌；instrumentation 状态只公开用例和运行 ID、Agent PID 及输出哈希。

宿主运行器传入 `--foreground-carrier service`，直接调用 instrumentation 则传入 `-e foregroundCarrier service`。运行器向两个阶段传递相同选择，检查准备阶段的载体就绪状态帧，并要求恢复阶段的载体及原生所有者关闭后才接受成功。缺失、冲突或不完整的载体证据都会失败。被主动终止的准备进程没有正常关闭回执；仍须证明真实 PID 消失。service 模式仅为测试提供调度支持，不证明生产 Agent 服务的后台存活能力。

收到就绪信号后，宿主将确切运行 UUID 与 ActivityManager 中的隔离服务进程关联，并独立确认其 PID 存活。宿主强制停止应用，要求 Agent 和全部隔离脚本进程消失。新进程恢复时，必须具有不同的 Agent PID、原始文件哈希及未改变的未确认日志。重新绑定原准入记录必须在原生重新绑定或工具执行前，以 `ANDROID_TOOL_REPLAY` 拒绝。结果未知的改动仍保持未知；测试不会重放，也不会解除用户的恢复阻塞。验收入口仅只读检查原生回执：`nativeReceiptState` 必须为 `ADMITTED` 或 `INTERRUPTED_UNCONFIRMED`，`nativeOutputAbsent` 必须为 `true`。宿主以 `nativeReceiptInspection: read-only-unconfirmed` 保留这些观察，不调用或证明原生冷恢复状态转换。

## 文档搜索与撤权

[测试提供器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/PtcSafAcceptanceProvider.kt)只位于 AndroidTest 安装包内，保留 `MANAGE_DOCUMENTS` 及 URI 授权检查。它的显式控制接收器要求应用签名级别的 `RUNTIME_ACCEPTANCE` 权限，在提供器 UID 下运行，只接受固定操作和 UUID。接收器创建两个固定文本文件，将一个生成的目录树授权给固定目标应用，并返回该 URI。应用通过 Android 常规 resolver 持久化授权。任何命令都不接受任意文件路径、文档 URI 或目标包名。

显式控制广播使用 [`FLAG_INCLUDE_STOPPED_PACKAGES` 与 `FLAG_RECEIVER_FOREGROUND`](https://developer.android.com/reference/android/content/Intent#FLAG_INCLUDE_STOPPED_PACKAGES)，以便守护强制停止测试包后，测试接收器仍可启动并获得前台调度。这些标志不授予文档访问权限。接收器进入回执用于区分广播投递超时和提供器控制超时；仅最终成功响应提供生成的 URI。签名权限、提供器 UID 和持久授权检查仍是必需条件。

[原生 instrumentation](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/PtcSafAcceptanceInstrumentation.kt)检查有界文本搜索，等待第二次搜索进入提供器，然后仅释放自己生成的授权并等待取消完成。它拒绝撤权后返回内容，检查后续读取和搜索被拒绝，删除自己的提供器文件，并逐一比较所有既有持久授权的 URI 和权限标志。提供器的无关异常不能算作取消成功。撤权后的测试控制仍经签名权限保护的接收器完成，不保留文档读取授权。

[PTC SAF 验收模块](device-runtime-acceptance/ptc-saf.mjs)使用套件 `ptc-saf`，通过原始 `android_files`、真实 `NativeIsolatedToolCallbacks` 和 `AppDocumentSearch` 发送搜索与读取。验收入口只提供生成的授权根，并仅对该确切根处理 `acceptance.saf.revoke`。模块要求独立隔离 UID、一次原生搜索生命周期、四条持久回调结果，以及撤权后读取和搜索均被拒绝。原生在途测试与 PTC 测试覆盖不同断言，不能相互替代。

`PtcSafAcceptanceInstrumentation` 和 Node 载体的 `ptc-saf` 套件均接受 `-e foregroundCarrier service`，默认仍为 `activity`。原生探针的服务租约为 90 秒。载体失效会取消搜索所有者，并在等待搜索工作线程结束后释放租约。成功结果含载体身份、关闭确认及观察到的锁屏和显示状态。这些是系统框架观察，不是像素采样或物理面板电源证明。

## 验证范围

使用 `node --import tsx/esm --test apps/android/tool/acceptance-ptc-process-death-device.test.mjs` 运行定向宿主回归。它确实在真实 ToolRuntime 写入后终止子 Node 进程，并在另一进程重载真实会话及日志。宿主 SAF 测试使用真实工具、回调和搜索所有者，但明确模拟 Android 传输。负例会拒绝损坏标记、不完整搜索、重复结果及指向其他运行的证据。宿主通过不能证明 Android 进程退役、URI 授权、Binder 取消或 release 安装包行为。

## 开发注记

支持 service 的进程终止和 SAF 检查需要新的配套安装包设备证据。上一次 SAF 真机运行已确认服务就绪，但在提供器控制回执前超时；宿主测试和编译不能证明停止包修复已解决该设备故障。对应检查通过手机验收前，必须单独保留模型 PTC 的验收结论。失败用例记录应留存排查，不得改写为成功或可重放状态。
