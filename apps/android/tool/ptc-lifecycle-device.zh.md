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

[测试提供器](../android/app/src/androidTest/java/com/minnnng/dsh_android/PtcSafAcceptanceProvider.java)只位于 AndroidTest 安装包内，保留 `MANAGE_DOCUMENTS` 及 URI 授权检查。它的显式[绑定控制服务](../android/app/src/androidTest/java/com/minnnng/dsh_android/PtcSafAcceptanceControlService.java)要求应用签名级别的 `RUNTIME_ACCEPTANCE` 权限，在提供器 UID 下运行，只接受固定操作和绑定用例的 UUID。服务创建两个固定文本文件，将一个生成的目录树授权给固定目标应用，并返回该 URI。应用通过 Android 常规 resolver 持久化授权。任何命令都不接受任意文件路径、文档 URI 或目标包名。

App 从既有验收载体通过 `BIND_AUTO_CREATE` 显式绑定，并在整个用例期间保持绑定。测试服务不启动前台服务或界面。其 Messenger 校验 Android 提供的 `sendingUid` 必须等于固定目标 App UID，同时校验绑定 UUID、请求序号与操作。App 检查回执的内核来源 UID 等于 instrumentation 安装包 UID，并要求控制 PID 始终一致。绑定、断连和控制响应失败均保留为失败，不重试结果未知的工作。清理只释放生成的持久授权、删除该用例，并在失败时也解绑。解绑不证明 Android 已销毁测试进程；实际进程消失由宿主退役所有者核验。

对于阻止跨包冷启动的设备，可选的[引导 instrumentation](../android/app/src/androidTest/java/com/minnnng/dsh_android/PtcSafBootstrapInstrumentation.java)仅以 `com.minnnng.dsh_android.test` 及其同名进程为目标。Shell 在主 SAF instrumentation 之前启动它。它在独立测试 UID 下自行绑定控制服务，不创建文档，也不授予任何 URI。就绪帧包含确切令牌、PID、UID、不同的 App UID，以及 60–600 秒的有界租约。它不打开窗口、不启动前台服务、不持有唤醒锁，也不唤醒或解锁设备。租约到期或服务丢失均失败；引导就绪本身绝不是 SAF 验收通过。

[宿主辅助模块](acceptance-saf-bootstrap.mjs)导出 `withSafBootstrap({ adb, serial, logPath, leaseMillis? }, operation)`，日志路径必须尚不存在。回调接收 `AbortSignal`，必须拥有并等待自己的主 instrumentation 子进程及其他资源结束后才返回。辅助模块拒绝接管既有测试包进程，等待令牌一致的完整就绪帧，再通过完整进程观察核验实际 PID/UID 后调用回调。引导提前退出时会触发取消，等待主流程清理，仅强制停止自己拥有的测试包，确认旧 PID 及该 UID 下全部进程消失，并等待所属 ADB 客户端关闭后才返回 `{ value, bootstrap }`。主流程失败或未确认的清理仍是失败。外部屏幕守护继续负责物理显示保护及最终 App 和完整进程清理。原生与 PTC SAF 主检查保留真实的跨 UID 持久授权和撤权断言。

[原生 instrumentation](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/PtcSafAcceptanceInstrumentation.kt)检查有界文本搜索，等待第二次搜索进入提供器，然后仅释放自己生成的授权并等待取消完成。它拒绝撤权后返回内容，检查后续读取和搜索被拒绝，删除自己的提供器文件，并逐一比较所有既有持久授权的 URI 和权限标志。提供器的无关异常不能算作取消成功。撤权后的测试控制仍经签名权限保护的绑定完成，不保留文档读取授权。

搜索与图片读取仅在完成既有持久授权及文档检查后使用[原始提供器读取器](../android/app/src/main/kotlin/com/minnnng/dsh_android/DocumentProviderRead.kt)。读取器调用 `ContentProviderClient.openAssetFile(uri, "r", signal)`，避免 resolver 的只读 MIME 转换在 `DocumentsProvider` 中丢弃取消信号。它用 `AssetFileDescriptor.createInputStream()` 保留资源偏移和声明长度，关闭流、描述符及客户端，并在清理也失败时保留原始异常。图片校验仍打开两个独立的流。原生搜索报告记录 `openDocumentSignalPresent`，要求其为真才成功，并将清理错误保留为 suppressed 异常。取消及工作线程退役期限保持不变。

[PTC SAF 验收模块](device-runtime-acceptance/ptc-saf.mjs)使用套件 `ptc-saf`，通过原始 `android_files`、真实 `NativeIsolatedToolCallbacks` 和 `AppDocumentSearch` 发送搜索与读取。验收入口只提供生成的授权根，并仅对该确切根处理 `acceptance.saf.revoke`。模块要求独立隔离 UID、一次原生搜索生命周期、四条持久回调结果，以及撤权后读取和搜索均被拒绝。原生在途测试与 PTC 测试覆盖不同断言，不能相互替代。

`PtcSafAcceptanceInstrumentation` 和 Node 载体的 `ptc-saf` 套件均接受 `-e foregroundCarrier service`，默认仍为 `activity`。原生探针的服务租约为 90 秒。载体失效会取消搜索所有者，并在等待搜索工作线程结束后释放租约。成功结果含载体身份、关闭确认及观察到的锁屏和显示状态。这些是系统框架观察，不是像素采样或物理面板电源证明。

## 验证范围

使用 `node --import tsx/esm --test apps/android/tool/acceptance-ptc-process-death-device.test.mjs` 运行定向宿主回归。它确实在真实 ToolRuntime 写入后终止子 Node 进程，并在另一进程重载真实会话及日志。宿主 SAF 测试使用真实工具、回调和搜索所有者，但明确模拟 Android 传输。负例会拒绝损坏标记、不完整搜索、重复结果及指向其他运行的证据。宿主通过不能证明 Android 进程退役、URI 授权、Binder 取消或 release 安装包行为。

运行 `node --test apps/android/tool/acceptance-saf-bootstrap.test.mjs` 检查就绪、进程身份和清理负例，包括用同步屏障阻止主流程仍在清理时提前报告成功。运行 `node apps/android/tool/acceptance-saf-control-host.mjs <android.jar>`，在不依赖 App 或 Kotlin 的条件下检查真实 Java 请求策略并编译三个独立组件。运行 `python apps/android/tool/audit-saf-test-apk.test.py` 检查依赖审计负例。AndroidTest APK 构建后，运行 `python apps/android/tool/audit-saf-test-apk.py --test <test.apk> --platform <android.jar> --report <new-report.json>`。该命令检查实际 DEX 中从 Provider、控制服务及引导 instrumentation 可达的依赖，包括合成辅助类、初始化、异常类型和成员签名；只允许测试 APK 与 SDK 解析依赖，绝不使用主 App 兜底。静态链接不证明 Binder 投递、反射或设备行为。

运行 `node apps/android/tool/acceptance-document-provider-open.mjs <kotlin-compiler-config.json>`，以本地 `compilerCp` 类路径，将生产 Kotlin 读取器、`DocumentBinaryReadAccess` 与 `DocumentSearchJob` 针对明确模拟的 Android API 端点编译执行。它检查独立图片校验读取、有界资源数据、打开期间的取消、空或失效提供器，以及清理失败时的原始错误保留。它将唯一分配的宿主输出留在项目缓存中。这些宿主检查不证明 Android Binder 行为；原生搜索与图片取消各自仍需对应的设备证据。

## 开发注记

每项设备结论都须对应已保存的报告。r20 PTC SAF 报告确认了自目标引导与主 App instrumentation 并行时的独立测试 UID、搜索和读取回调、撤权及进程退役。独立的原生在途搜索未能退役，其取消修复仍需重建 App 并真机复测。共用修复的图片读取不能借 PTC 或原生搜索结果视为已通过真机验收。早先设备日志指出广播与跨包服务冷启动均被启动策略拒绝；另行发现的 Kotlin 依赖是潜在缺陷，不证明那些尝试发生了崩溃。失败用例记录应留存排查，不得改写为成功或可重放状态。
