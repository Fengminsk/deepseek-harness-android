# Android 正式 profile 验收

[English](production-profile-device.md)

本参考页说明[打包 Node 验收](device-runtime-acceptance.zh.md)中的无真实密钥 `production-profile` 套件。夹具导入随包发布的 `bootstrap.mjs`，由它启动 `dsh --profile android`，并通过随包发布的 Android `index.mjs` 注册工具。夹具不会注册替代的 PTC、工作流或 Linux 工具。只有模型 HTTP 端点和凭据是合成数据；AgentLoop、Session、ToolRuntime、原生分派与隔离执行均使用正常实现。

每次运行在 `noBackup/native-runtime-acceptance` 下创建 UUID home 和专用工作区目录。原生凭据使用独立内存 Map，保存一个合成 API key，以及原始 Connection 插件启动时生成且经过校验的浏览器会话密钥；账号和无关凭据写入会被拒绝。夹具不会打开用户凭据存储。模型与关闭认证使用各自独立的随机 32 字节秘密，只保存在专用 home 中，证据和诊断不包含它们；关闭还须校验本次 case nonce。本地 Messages 服务只绑定 `127.0.0.1`，校验模型 key、限制请求字节数，并接受固定调用顺序。模型实际收到 `android_ptc` 和 `linux_exec` 定义，Linux 定义不得包含 `networkHosts` 或 `networkCallLimit`。PTC 读取创建的工作区文件，随后 Linux 使用 Python 的 `hashlib`、`sqlite3` 和 `zipfile` 执行检查。模型发出最终回复前，必须匹配工具结果 ID、内容、不同的客体 UID 和已确认的退役状态。

默认 `expectWorkflow=false` 要求不存在工作流工具。显式设置 `expectWorkflow=true` 则要求实际构建开放工作流，并增加一次前台工作流调用。一个子 Agent 收到专用提示，通过真实模型协议返回标记。夹具检查匹配的工作流结果、一次子模型请求、父级运行与成员结束事件，以及单独落盘的子 Session。该参数不会改变产品可用性。

请求认证先于运行状态变更和正文解析。没有提供任一用途专用秘密的请求返回 401，只记录有界的拒绝计数及最近的方法／路径，因此无关本机探测不能使已认证轮次失败或向前执行。已认证请求的方法、路径或关闭 case 无效时，套件仍严格失败。请求诊断排除请求头与查询字符串，限制方法／路径长度，并隐藏两种夹具秘密。

套件要求 `foregroundCarrier=service`，且设备已锁定、不可交互。它不打开 Activity，不唤醒或解锁屏幕。只能在现有[物理面板保护与进程退役所有者](device-screen-protection.zh.md)内运行。验收服务保持测试进程获得调度，不构成正式 `AgentService` 后台存活证据。宿主必须等待自己启动的 ADB 调用结束，仅停止该测试拥有的 App／测试进程，并验证最终全部进程退役。框架锁屏与显示状态不构成像素或物理面板证据。

```sh
adb shell am instrument -w -r -e suite production-profile -e foregroundCarrier service -e expectWorkflow false com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation
```

在该外层所有者中调用[宿主驱动](acceptance-production-profile-device.mjs)导出的 `runProductionProfileAcceptance({ invoke, signal, expectWorkflow })`。`invoke(args, signal)` 指定设备，仅在自己的 ADB 子进程关闭后返回有界 stdout；取消或无法确认子进程退役时必须拒绝。驱动校验原生收尾，并明确返回仍需外层证明的物理面板状态和 Node 退役要求。不含工作流时原生套件预算为 360 秒，含工作流时为 480 秒；模型轮次另有时限。执行失败会请求取消 Session，并将收尾失败保留为 suppressed 异常。模型关闭须等待监听器及未完成请求处理器结束。

结果记录随包 bootstrap／runtime 哈希、模型工具定义哈希、匹配的 Session ID，以及专用 JSONL 文件哈希。成功要求已完成的落盘轮次包含 PTC 分派和 Linux 执行、最终回复、已关闭的模型监听器，以及载体确认的原生所有者关闭。保留的夹具文件只含合成输入和协议证据。宿主协议／解析测试与独立 Kotlin 编译不构成设备验收；作出设备通过结论前须保留实际 instrumentation 结果及外层退役／显示报告。本套件不验证真实模型凭据、Linux 联网、升级、正式后台存活或通用工作流生命周期限制。

启动诊断记录固定检查点名称、单调时间、当前等待的 RPC、原生与通知方法名、运行时失败阶段及 errno、模型计数、有界的 socket 地址／地址族、匹配的接口身份和堆栈位置。本地 socket 必须是明确的回环地址；对端必须为 `127.0.0.1`、`::ffff:127.0.0.1`、`::1`，或精确匹配该请求即时读取的 `os.networkInterfaces()` 快照中的本机单播地址。快照不可用、地址缺失、通配／组播地址及未分配给本机的远端地址均被拒绝，不允许网段或持久保存的设备 IP。任何通过地址校验的请求仍须提供对应用途的秘密。诊断不包含凭据值、请求头、提示词或模型正文。运行时初始化失败会立即终止 ready 等待。模型证据缺失或关闭响应失败会明确报告监听器退役未确认，不能静默通过收尾。[JVM 场景检查](acceptance-production-profile-host.mjs)使用实际场景类与 Android SDK JSON 源码验证启动凭据和诊断行为，不将其当作 Android 进程证据。

<a id="build-116-r28"></a>
## Build 116 r28 真机观察

保留的两次运行使用同一 App SHA-256 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41` 和 AndroidTest SHA-256 `74d913413f36559cb9272df2bbfe2ae1c614e8878cbd5a024010e75091399b0e`。结果文件为 `.cache/android/production-profile-116-r28-protected-20261028.json.result.json` 和 `.cache/android/production-profile-116-r28-warm-20261028.json.result.json`；各自的外层屏幕／退役报告位于去掉 `.result.json` 的同路径文件。

首次运行到达 `production-bootstrap-import-start` 后，在 `runtime-ready-wait` 失败。ready 等待配置为 90 秒，失败记录的实际已用时间为 287,158 毫秒，原生调用、通知和模型调用均为零。启动停滞及超时延后报告的原因仍未知。随后关闭及外层退役不能使该次运行变为通过。

随后标记为 `warm` 的运行在 `expectWorkflow=true` 下于 15,462 毫秒通过：四次父模型请求、一次子模型请求、PTC 工作区读取、Linux Python 分析及 workflow 完成。它保留了两份独立的父／子 Session JSONL 持久文件。Linux 客体 UID 为 99478，App UID 为 10496；客体退役与模型监听器关闭均已确认。这些是合成模型端点驱动的实际随包正式 profile 操作。

warm 外层报告记录九次采样中两个物理面板均为 `Off`、在不可交互状态下恢复、宿主命令结束及目标进程消失已确认。进程内 `nodeProcessRetired` 字段仍为 false；整个进程的退役由该外层报告单独提供证据。warm 成功不能解释或抹去首次失败。两次运行均不认证真实账号鉴权、公网模型供应商、正式后台存活或长期 Doze 行为。[115→116 升级记录](upgrade-116-acceptance.zh.md)说明其独立的数据保持检查。
