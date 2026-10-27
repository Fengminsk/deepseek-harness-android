# 锁屏下的 AgentService 恢复验收

[English](agent-service-recovery-driver.md)

`acceptance-agent-service-recovery-device.mjs` 通过真实 ADB 驱动已安装的正式 `AgentServiceRecoveryInstrumentation`；`agent-service-recovery-driver.mjs` 负责阶段顺序、网络恢复和退役。验收启动正式 AgentService，创建专用会话，并核对断网与恢复联网前后的事件数量、SHA-256 不变。它不调用模型；通过不代表运行中的 Agent 任务存活、模型请求重试或杀死服务后的持久化已获验证。

## 入口与屏幕保护

使用已经锁屏、不可交互且最初具有已验证网络连接的手机。驱动在启动原生验收前读取 `dumpsys power` 及限定范围内的 `KeyguardServiceDelegate`，拒绝交互中、未锁定、含糊或不可读的状态。它不发送唤醒、休眠或解锁输入。`--no-wake` 用于明确这项固定行为，省略也不会允许唤醒。

```powershell
node apps/android/tool/device-screen-protection.mjs --adb D:\Programs\adb\adb.exe --serial <serial> --seconds 420 --report <screen-report.json> -- apps/android/tool/acceptance-agent-service-recovery-device.mjs --accept-network-toggle-and-lock --no-wake --report <recovery-report.json>
```

屏幕包装器将 `--adb`、`--serial` 绑定到自己保护的目标。本入口通过同进程导入并等待，不经过可被直接杀死的 Node 子进程路径。守护取消以 AbortSignal 传入驱动，物理面板立即重新关屏；包装器等待驱动完成独立清理后才考虑恢复屏幕控制。通用子进程启动器明确拒绝此入口。单独运行时必须显式提供 `--adb`、`--serial`、`--report` 和网络切换同意标记，并通过同一清理所有者处理 SIGINT/SIGTERM；需要物理屏幕保护时应使用包装器。

## 证据与恢复

适配器在启动原生验收前预留新的报告文件，并写入不可覆盖的 `<report>.original.json`，保存设备序列号、随机标记及精确的 `wifi_on`／`mobile_data` 配置标志。已有报告和原始快照不会被覆盖。两项标志必须为 `0` 或 `1`，且至少一项开启；屏幕报告与恢复报告必须使用不同路径。配置快照不声称由哪张 SIM 卡或哪种传输方式提供已验证连接，原生验收会另外观察 Android 的已验证网络数量。

每次观察必须保留原会话 ID、运行代次、事件数量及摘要，并报告 `locked=true`、`interactive=false`；正式 Agent 进程 PID 也必须不变。第 2 版网络证据记录匿名网络句柄、SDK 已知传输枚举、INTERNET／VALIDATED／VPN／NOT_SUSPENDED 标志、App 默认网络及独立统计，不输出能力对象整串、SSID、IP 地址或 UID 名单。仅包含在 AndroidTest 中的 `RecoveryNetworkEvidence.java` 按 INTERNET + VALIDATED + 非 VPN 分类，不限制传输方式，因此以太网、USB 和其他互联网传输也会计入。宿主会根据逐项事实重新核对所有统计。

恢复网络前，两项配置标志必须实际读到关闭，且不能残留任何非 VPN 的 INTERNET 网络。没有 INTERNET 能力的 IMS 或常驻的已验证 VPN 覆盖层不代表可用的底层互联网，但仍保留在证据中。能力未知或尚未验证的非 VPN INTERNET 网络也会阻止断网验收，因为未经验证不等于不可访问。最初及恢复后的检查点要求至少存在一个 INTERNET + VALIDATED 非 VPN 网络，且没有未知能力。这些是 Android 能力观察，不是 HTTP 探测或付费模型请求。最终原生结果必须唯一且成功，保留相同会话证据，其 ADB 进程还必须实际成功关闭。

每条 ADB 命令有八秒截止时间，另有最多 3.5 秒的关闭观察。取消已派发的 `svc` 修改时，会等待该命令在期限内结束，避免立即恢复与尚未结束的修改竞争。修改回执失败后，网络结果始终标为未知，即使后续标志碰巧匹配。独立清理会尝试恢复两项原始标志，在最多 15 秒加有界命令延迟内核对精确回读，再强停 App 与测试包，最多等待 20 秒确认宿主进程实际关闭，并在最多 20 秒加命令延迟内检查 App、测试及隔离服务的完整进程名。不清除任何数据。原生验收另有 330 秒宿主截止时间。

清理不继承已取消的工作信号。报告分别记录网络恢复、宿主关闭和设备退役，任何失败都返回 `result: unknown`；保留失败阶段、最后检查点及网络事实、有界分层的执行／清理／取消原因，以及能够取得的原生失败原因。未关闭的子进程只在有界清理后释放事件循环引用，仍明确标为未退役。恢复或退役未知时，屏幕包装器不会重置面板覆盖。写报告失败仍会在抛出的错误中保留这些事实，并打印备用 JSON 诊断。宿主被强杀或 USB 不可用无法靠同进程 `finally` 保证恢复；重新连接后应按不可覆盖的快照恢复原始标志，并核对设备进程和面板状态后再继续工作。

## 主机检查

```powershell
node --test apps/android/tool/recovery-network-evidence.test.mjs apps/android/tool/agent-service-recovery-driver.test.mjs apps/android/tool/device-screen-protection.test.mjs
```

这些无密钥测试通过受控 IO 验证解析、取消、部分修改、不明确回执、精确恢复及退役。网络测试在宿主 JVM 上编译并执行 AndroidTest 的实际 Java 分类器，不算真机验收证据，也不属于 Android APK 构建。真实 ADB 适配器输出的报告带有 `evidence: device-adb`；每次真机尝试都应保留失败报告并使用新路径。
