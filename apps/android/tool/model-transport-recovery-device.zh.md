# Android 模型传输恢复验收

[English](model-transport-recovery-device.md)

本参考说明负责无需账号的 `model-transport-recovery` 套件。它导入交付版 Android profile，运行原始 DeepSeek HTTP/SSE 适配器、AgentLoop、重试策略和 Session 持久化。在新建私有 home 中创建专用 Session，只发送一次用户消息。仅本地模型端点与隔离凭据属于测试替身，不使用公开账号或付费请求。

模型保持部分 SSE 回复。原始 App 发出含该内容的 `session.live` 通知后，原生场景才请求经过认证的套接字断开。原始普通重试策略随后建立新连接，在同一轮、同一步内完成任务。测试不改变默认重试预算与延迟。它核对已消费的失败尝试、匹配的 `llm/retry` 和 `llm/retry-started` 标识、不同连接上的两次请求、唯一最终助手回复和唯一完成轮次。已有消息块及其余请求设置必须不变，包括模型、工具、推理配置、系统提示和未知扩展。原始 `dsh_session_log` 扩展可以推进增量游标：测试核对有界格式、相同 Session/头和向前的游标，并记录事件摘要；不认证扩展交付、并发标题上传或 JSONL 与线上格式的转换。新增 user/text 块必须逐一对应原始 Session 在重试开始后、最终回复前产生的运行上下文更新，且公开历史与 JSONL 一致。上下文生成的用户角色事件与唯一人工提交分别计数。

公开历史与专用 JSONL 日志必须包含相同的重试事件。结果记录其有序序列号、两次原始请求摘要及字节是否一致、经过验证的运行上下文更新数、增量日志观察、持久文件摘要以及交付版 bootstrap/runtime 哈希。诊断输出有界计数、固定请求/失败阶段与原因，以及每个变化顶层字段的类型、大小和原始/规范化 JSON 摘要。未知字段名只记录哈希，不输出字段值、请求体、请求头、凭据或异常消息。模型关闭会等待监听器、已接入套接字和请求处理器结束。缺少历史、持久化、清理或原生所有者证据都会使验收失败。原生场景组合复用[正式配置的隔离与关闭](production-profile-device.zh.md)，不改变用户凭据库。未认证的本地探测返回 401，只增加有上限的计数；已准入的畸形请求会使测试失败。

复制到私有 home 的 bootstrap 比较规范化后的真实文件路径，识别经由 Android 路径别名直接执行的入口，再读取 runtime 配置并导入模型。临时解析器只把证据模块的 `@deepseek-ai/dsh-llm` 导入指向指定打包 runtime，核对实际包位置后立即注销。它不改变生产 bootstrap，也不提供通用包回退。打包导入回归将验收资产复制到仓库外，使用不带 tsx、`NODE_OPTIONS` 或 `NODE_PATH` 的普通 Node，并通过目录符号链接或 Windows junction 验证入口实际执行。暂存 runtime 全程只读。

在现有[屏幕与进程保护所有者](device-screen-protection.zh.md)内部调用[驱动](acceptance-model-transport-recovery-device.mjs)的 `runModelTransportRecoveryAcceptance({ invoke, signal })`。调用方提供绑定指定 ADB/设备的调用函数，子进程关闭后才返回输出。套件要求 `foregroundCarrier=service`，设备全程锁屏且不可交互。它不打开 Activity，不改变 Wi-Fi、移动数据或 VPN 设置，不唤醒或解锁屏幕。载体整体期限为 240 秒；就绪、部分回复消费、重试完成和取消各有有限等待。

集成该套件后，设备运行所有者使用以下 instrumentation 参数；单独执行此命令不提供物理屏幕保护或最终进程退役证据：

```sh
adb shell am instrument -w -r -e suite model-transport-recovery -e foregroundCarrier service com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation
```

聚焦主机验证通过真实本地 HTTP 套接字运行原始适配器和 AgentLoop，包括重试期间刷新运行上下文。另一个长期回归在隔离 home 中启动实际暂存 Android bootstrap/profile，使用明确的主机存储/设置替身与真实本地模型，核对完成后的 JSONL；保留原始 provider 扩展和重试策略。正常 EOF 负例仍是默认不重试的 `STREAM_CLOSED`；退避期间取消会阻止后续请求。事件校验器和驱动拒绝重复提交、改变步骤、修改已有输入/模型/工具/设置、没有匹配持久运行上下文的新增内容、畸形增量日志观察，以及未确认的清理。场景的 JVM 检查使用 SDK JSON 实现验证诊断字段的类型和筛选。主机测试不能证明 Android 执行或持久化。

```sh
node --import tsx --test apps/android/tool/model-transport-recovery.test.mjs apps/android/tool/acceptance-model-transport-recovery-device.test.mjs
node --import tsx --test apps/android/tool/model-transport-recovery-profile.test.mjs
node --test apps/android/tool/model-transport-recovery-packaged.test.mjs
node apps/android/tool/acceptance-model-transport-recovery-host.mjs
```

2026-10-28 的真机验收使用 build 116 和测试修订 r31，通过。已安装正式 App 的 SHA-256 保持为 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`；测试 APK 的 SHA-256 为 `83fa170f2aaaaa4e43909b2a543db2beed1ffe35fdff36b58f3d99245f5b81c7`。场景耗时 13,344 毫秒，观察到一次提交、不同连接上的两次模型请求、一次 `TRANSPORT` 重试、已消费的部分文本，并在第 1 轮第 1 步完成。序列 20 的最终回复和序列 22 的轮次结束均与专用 JSONL 一致。类型化诊断确认只有 `dsh_session_log` 变化，设置与已有消息块保持不变；日志快照从 `afterSeq=-1, throughSeq=12` 推进到 `afterSeq=12, throughSeq=18`。模型监听器与原生所有者已关闭。外层保护所有者另行确认主机子进程关闭、设备进程消失；10 次采样均显示两块物理屏幕 Off。证据保留于 `.cache/android/model-transport-116-r31-protected-20261028.json.result.json`、对应的 `.json` 保护报告及 `.json.live.txt` instrumentation 日志。内层 `nodeProcessRetired=false` 字段不作为退役证明；该证据来自外层报告。

此前 r28 和 r30 仍保留为失败记录，文件前缀为 `.cache/android/model-transport-116-<revision>-protected-20261028`。r28 在等待重试完成时失败，缺少字段级诊断。r30 记录了已消费的前缀和第二次请求，但在已有消息块未变的情况下拒绝了变化的非消息字段。后续完整 profile 主机回归与 r31 真机结果证明该增量日志变化符合本项契约；它们不会将旧结果追认为通过，也不能据此确定 r28 的具体失败原因。此次测试修正没有改变生产重试策略或 App 二进制。

真机通过可证明：交付版 Android runtime 在测试服务载体内完成活动模型请求的传输恢复。它不能证明实际无线断网/重连、公网可用、长时间 Doze、进程死亡后续跑，或正式 AgentService 长期活动任务存活。现有 [AgentService 恢复](agent-service-recovery-driver.zh.md)检查真实无线状态改变期间服务与 Session 是否可用；不能将这两组观察合并成活动生产任务经历上述变化仍存活的结论。
