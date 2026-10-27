# 锁屏下的 AgentService 恢复验收

[English](agent-service-recovery-driver.md)

`acceptance-agent-service-recovery-device.mjs` 通过真实 ADB 驱动已安装的原生验收。不传场景参数时运行 `AgentServiceRecoveryInstrumentation`：正式 AgentService 创建专用空闲会话，核对断网与恢复联网前后的事件数量、SHA-256 不变，不调用模型。显式选择 `radio-linux` 时改用 `AgentServiceTaskAcceptanceInstrumentation` 执行一次真实账号任务。两者均由 `agent-service-recovery-driver.mjs` 唯一负责网络修改、恢复和进程退役；都不能证明模型 HTTP 重试或服务死亡后的恢复。

## 入口与屏幕保护

使用已经锁屏、不可交互且最初具有已验证网络连接的手机。驱动在启动原生验收前读取 `dumpsys power` 及限定范围内的 `KeyguardServiceDelegate`，拒绝交互中、未锁定、含糊或不可读的状态。它不发送唤醒、休眠或解锁输入。`--no-wake` 用于明确这项固定行为，省略也不会允许唤醒。

```powershell
node apps/android/tool/device-screen-protection.mjs --adb D:\Programs\adb\adb.exe --serial <serial> --seconds 420 --report <screen-report.json> -- apps/android/tool/acceptance-agent-service-recovery-device.mjs --accept-network-toggle-and-lock --no-wake --report <recovery-report.json>
```

屏幕包装器将 `--adb`、`--serial` 绑定到自己保护的目标。本入口通过同进程导入并等待，不经过可被直接杀死的 Node 子进程路径。守护取消以 AbortSignal 传入驱动，物理面板立即重新关屏；包装器等待驱动完成独立清理后才考虑恢复屏幕控制。通用子进程启动器明确拒绝此入口。单独运行时必须显式提供 `--adb`、`--serial`、`--report` 和网络切换同意标记，并通过同一清理所有者处理 SIGINT/SIGTERM；需要物理屏幕保护时应使用包装器。

<a id="radio-linux"></a>
## 显式启用活动 Linux 调用

只有获得真实账号请求授权时，才向同一受保护入口添加 `--exercise radio-linux --accept-real-account-request`。两个参数必须同时提供，并保留 `--accept-network-toggle-and-lock`；不传时仍使用空闲会话场景。直接 echo 适配器也保留不改无线网络的默认行为。账号准入、精确的 40 秒 Python 命令与持久完成检查由[账号任务验收](agent-service-task-device.zh.md#radio-linux)说明。

radio 就绪状态绑定原用例、会话、运行代次、Agent PID 和未完成 `linux_exec` 调用。`tool/call` 记录先于调度器准备，不能说明 Python 已启动。确认两项无线网络均关闭、网络分类器未发现底层 INTERNET 网络后，驱动收集至少两次离线任务观察，从首次离线采样完成起覆盖至少 15 秒的宿主单调时钟区间。每次重新核对同一 PID、运行中的父任务、未完成调用、锁屏状态和关闭的标志。`offlineSamples` 保留这些观察，`timing.minimumDwellMs` 为 `15000`。驱动恢复原始标志并观察到可用连接后才发送 `restored`，随后等待原轮次的最终 Linux 回执和已持久化助手回复，不再次提交模型请求。

[radio 校验器](agent-service-task-radio.mjs)独立检查各检查点及最终任务结果。该协议不另建网络清理所有者：失败、超时、信号或屏幕守护取消仍进入下述同一恢复与进程退役路径。原生离线至恢复区间也必须达到 15 秒。未完成调用的观察及最终客体回执不能证明 Python 在断网期间持续执行、客体可联网或被中断的模型 HTTP 流已重试。通过的真机结果及其范围见 [r34 账号任务记录](agent-service-task-device.zh.md#radio-linux-r34)。

## 证据与恢复

适配器在启动原生验收前预留新的报告文件，并写入不可覆盖的 `<report>.original.json`，保存设备序列号、随机标记及精确的 `wifi_on`／`mobile_data` 配置标志。已有报告和原始快照不会被覆盖。两项标志必须为 `0` 或 `1`，且至少一项开启；屏幕报告与恢复报告必须使用不同路径。配置快照不声称由哪张 SIM 卡或哪种传输方式提供已验证连接，原生验收会另外观察 Android 的已验证网络数量。

仪器为服务启动、绑定、运行时就绪、会话操作及检查点发送绑定 token 的进度。宿主将最后完整记录保存为 `lastProgress`，将其阶段保存为 `nativeStage`，超时也会保留，并只将经过验证、已脱敏的进度写入 `<report>.progress.json`。该文件不含原始转录、账号秘密或模型文本，也不是成功结果。固定字段包括序号、PID、单调 elapsed／uptime 计时以及筛选后的运行时摘要，空闲场景进度另含后台详情；未知字段、阶段、令牌及重复序号会被拒绝，不保留其内容。elapsed 包含设备休眠，uptime 不包含；两种计时都不能单独证明某个进程被冻结。空闲场景在主 Looper 运行时每五秒读取既有原生 `runtime.status`，包括 `bootStage`、任务数量和 wake lock 状态；radio 心跳只报告就绪／观察循环缓存的运行时状态，不另发 RPC，也不在 `progress.runtime` 中包含后台详情。两种场景均以 `runtimeObservedAtMs` 区分新回执与保留的旧快照。这项观察不获取 wake lock，也不改变生产启动或任务策略。宿主的 150 秒就绪等待包括原生就绪和专用会话 RPC；radio 还需等到模型的未完成工具调用通过校验，并非只测量 Node 启动时间。不完整行继续等待，不合法进度不能阻止独立清理。

空闲场景的每次观察必须保留原会话 ID、运行代次、事件数量及摘要，并报告 `locked=true`、`interactive=false`。radio 则保持原活动任务及调用身份，允许预期的新完成事件出现。两种场景的正式 Agent 进程 PID 都必须不变。第 2 版网络证据记录匿名网络句柄、SDK 已知传输枚举、INTERNET／VALIDATED／VPN／NOT_SUSPENDED 标志、App 默认网络及独立统计，不输出能力对象整串、SSID、IP 地址或 UID 名单。仅包含在 AndroidTest 中的 `RecoveryNetworkEvidence.java` 按 INTERNET + VALIDATED + 非 VPN 分类，不限制传输方式，因此以太网、USB 和其他互联网传输也会计入。宿主会根据逐项事实重新核对所有统计。

宿主在就绪后、离线检查点和恢复网络观察后检查相同的 Agent PID，最后一次检查位于允许仪器结束的 `restored` 命令之前。`processChecks` 保留这些观察以及 radio 的额外离线检查。最终空闲检查点仍须保持同一会话／代次／摘要及锁屏状态；radio 则要求通过校验的任务完成证据。两者都须归档专用会话、返回唯一成功结果并实际关闭宿主进程。预期的仪器结束后不要求目标 PID 继续存活；最终进程退役由清理阶段独立检查。`timing` 记录宿主单调时钟下的检查点偏移和在线至恢复观察的跨度。15 秒观察回执上限不是驻留时间：空闲场景保留 `minimumDwellMs: 0`，radio 另行执行上述区间要求。空闲场景的离散观察不能证明持续 15 秒断网或活跃任务存活；两者都不能证明长时间休眠／Doze 存活。

恢复网络前，两项配置标志必须实际读到关闭，且不能残留任何非 VPN 的 INTERNET 网络。没有 INTERNET 能力的 IMS 或常驻的已验证 VPN 覆盖层不代表可用的底层互联网，但仍保留在证据中。能力未知或尚未验证的非 VPN INTERNET 网络也会阻止断网验收，因为未经验证不等于不可访问。最初及恢复后的检查点要求至少存在一个 INTERNET + VALIDATED 非 VPN 网络，且没有未知能力。网络分类本身是 Android 能力观察，不是 HTTP 探测；radio 的独立模型请求可能消耗账号额度。最终原生结果必须唯一且成功，并具有对应场景要求的会话证据，其 ADB 进程还必须实际成功关闭。

每条 ADB 命令有八秒截止时间，另有最多 3.5 秒的关闭观察。取消已派发的 `svc` 修改时，会等待该命令在期限内结束，避免立即恢复与尚未结束的修改竞争。修改回执失败后，网络结果始终标为未知，即使后续标志碰巧匹配。独立清理会尝试恢复两项原始标志，在最多 15 秒加有界命令延迟内核对精确回读，再强停 App 与测试包，最多等待 20 秒确认宿主进程实际关闭，并在最多 20 秒加命令延迟内检查 App、测试及隔离服务的完整进程名。不清除任何数据。原生验收另有 330 秒宿主截止时间。radio 原生工作仍限 300 秒、轮次限 120 秒、原生清理另有最多 60 秒；宿主截止时间可能中断该清理，之后仍必须独立完成恢复和退役。

清理不继承已取消的工作信号。报告分别记录网络恢复、宿主关闭和设备退役，任何失败都返回 `result: unknown`；保留失败阶段、最后检查点及网络事实、有界分层的执行／清理／取消原因，以及能够取得的原生失败原因。未关闭的子进程只在有界清理后释放事件循环引用，仍明确标为未退役。恢复或退役未知时，屏幕包装器不会重置面板覆盖。写报告失败仍会在抛出的错误中保留这些事实，并打印备用 JSON 诊断。宿主被强杀或 USB 不可用无法靠同进程 `finally` 保证恢复；重新连接后应按不可覆盖的快照恢复原始标志，并核对设备进程和面板状态后再继续工作。

## 主机检查

```powershell
node --test apps/android/tool/recovery-network-evidence.test.mjs apps/android/tool/agent-service-recovery-driver.test.mjs apps/android/tool/device-screen-protection.test.mjs
```

这些无密钥测试通过受控 IO 验证解析、取消、部分修改、不明确回执、精确恢复及退役。网络测试在宿主 JVM 上编译并执行 AndroidTest 的实际 Java 分类器，不算真机验收证据，也不属于 Android APK 构建。真实 ADB 适配器输出的报告带有 `evidence: device-adb`；每次真机尝试都应保留失败报告并使用新路径。

## Build 116 r31 空闲服务观察

真机记录 `.cache/android/agent-service-116-r31-recovery-20261028.json` 报告通过：在线、离线及恢复检查点保持相同的 Agent PID、运行代次、专用会话及单事件摘要。就绪检查点位于 4,510.680 毫秒，在线至恢复观察跨度为 4,623.577 毫秒，且 `minimumDwellMs: 0`；这个跨度不是离线驻留时间。离线观察中没有底层 INTERNET 网络，仍可见一个已验证的 VPN 覆盖层；原 Wi-Fi 和移动数据标志均恢复为 `1`。

配套的 `.cache/android/agent-service-116-r31-screen-20261028.json` 记录七次采样，两块物理面板均为 Off。原生检查点均已锁屏且不可交互，专用会话已归档，清理确认宿主关闭、设备进程退役及网络恢复。这些属于离散观察，不代表连续屏幕状态或长时间休眠证据。本轮没有模型请求或活动 Agent 任务；独立检查由[账号任务验收](agent-service-task-device.zh.md)负责。
