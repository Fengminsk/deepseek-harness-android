# Android 隔离工具调用端口

[English](isolated-tool-call-port.md) | 中文

`apps/android/runtime/isolated-tool-call-port.mjs` 为已完成持久准入的单次脚本、PTC 或工作流 Guest 分发已审查工具。Guest 的原生文件和网络授权始终为空。App 掌握精确工具定义、父 Agent 与 Session、策略回调、持久日志和结果投影；Guest 只能提供 `{runId,callId,name,arguments}`。`cordis.patch.yml` 中的 Android PTC 与工作流仍保持关闭，等待设备验收。

端口允许宿主审查的 `pure` 和 `read-only` 效果。仅 PTC 运行可额外调用原版 `write`、`edit`，或 `action: 'materialize'` 的 `android_attachments`；这些操作必须分类为 `workspace-write`，并提供受信任的 Session 刷盘函数。调用方绑定固定工具定义与注册身份；即使重新注册的是同一对象，也会拒绝替换后的注册。混合附件工具可按 action 把最大写权限降为只读，但只读审查不能获得写权限。当前 ToolRuntime 策略与原有 Android 文件守卫仍决定是否允许实际写入。PTC 还可按 `isolated-execution` 分类调用已审查的 `linux_exec`、`linux_import`、`linux_export`，并使用相同刷盘屏障；`linux_inspect` 保持只读。普通脚本和工作流端口拒绝这些名称。[Linux 审查](model-ptc-linux.zh.md)保留原生执行、恢复和审批规则。App UID Shell、嵌套 PTC、工作流、图片读取及未审查工具仍不能经此端口调用。

调用串行执行，最多尝试 32 次；被拒绝的尝试同样消耗序号。每次调用都使用同一 Agent、外层执行令牌、派生的根／子调用 ID 和取消信号，经过真实 `ToolRuntime.execute`。参数与 Guest 结果限额为 64 KiB；审计内容、元数据和上下文快照各限 128 KiB；Guest 错误文字限 4 KiB。紧凑 Guest 投影不会移除原始宿主元数据。元数据超限时，结果收尾后会明确返回“不支持”，不会宣称文件没有变化。

工具的 `additionalContexts` 原样转交父调用，包括失败和取消后的回执；限额内的快照也保存在 Session 审计中。这些上下文不会进入 Guest JSON。图片与 `concludesTurn` 仍不支持。原版文件工具在观察监听器执行前保留已提交路径回执，因此后续观察错误或取消仍可保留真实路径。宿主的后置执行策略仍可阻断该上下文。此时端口可能只知道请求路径；`verify-before-retry` 提示不会杜撰规范路径，也不表示已回滚。写入失败、取消或结果不支持时，调用方必须先检查受影响文件，再考虑重试。宿主不会自动重试写入。

写操作与隔离 Linux 操作的顺序为**日志准备 → Session 开始事件 → 等待 Session 刷盘 → 同步分发标记 → ToolRuntime → 结果观察标记 → Session 终态事件 → 等待 Session 刷盘 → 日志确认 → Guest 回复**。两次刷盘都必须返回 `true`。第一次失败会阻止分发；第二次失败会留下可能已执行或发布但未确认的结果。纯计算／只读调用保留配对 Session append 与日志顺序，不宣称完成 Session 磁盘刷写。受信任投影可通过 `reviewedToolProjectionError(message)` 提供有界、私有登记的恢复提示；写操作错误始终保留先检查文件的警告。

App 私有日志只存 ID、名称和 SHA-256 摘要，不存文件路径或负载。原生绑定前先独占占用每个运行目录。所有目录与调用标记均不可重放，包括绑定失败和已确认调用。重启后，`prepared` 表示尚未分发，`dispatch-unconfirmed` 表示副作用可能发生，`result-unconfirmed` 表示审计确认未完成。`confirmed` 只说明工具结果已收尾，绝不能证明报错的写操作没有改变文件。可读审计和已保留的提交路径回执存在持久 Session 中。日志与 Session 写入有先后顺序，但并非跨存储原子事务。[日志快照](isolated-tool-call-journal.snapshot.json)记录这些状态。

只有私有签发的策略拒绝、已确认工具失败和已确认的不支持结果会变成 Guest 可捕获错误。审计、传输或取消状态不确定时，运行会停止。若取消发生时已取得完整结果、终态审计与必要 Session 刷盘均成功，仍先确认该结果，再阻止向 Guest 回复；不会把已知取消或提交事实改成未知。结果观察、刷盘或日志确认失败仍阻止确认关闭。`close()` 取消排队和在途调用，并等待实际执行结束；审计未确认会使关闭失败。原生回调另外校验 UID、运行身份、nonce、序号和私有准入令牌。Guest 提供的运行 ID 只用于关联，不是身份认证。精确工具身份不能防御同 UID 恶意代码绕过 ToolRuntime。

Node 到原生的转发仅将私有确认的回调关闭表示为 `{runId,callId,closed:true,cancelRequested}`。私有身份在日志确认后绑定原运行与调用；排队、未分发、关闭后新到达以及审计失败的调用均不能签发。`cancelRequested` 来自实际父取消信号。原生可能在 cancel RPC 前收到该回包，但不会把它作为工具值发送给 Guest。本所有者请求的工作线程中断，仅对中断／取消异常类型视为预期；普通 RPC 错误、超时、畸形帧及此前不确定状态仍保留失败。PTC 截止回包可以在回调未结束时进入退役，不会改成用户取消；成功仍要求零待处理回调。工作线程退出、原始 Node 关闭确认、Binder 死亡及绑定清理仍是各自独立的要求。

`node apps/android/tool/acceptance-isolated-tool-callback-retirement.mjs` 使用真实 JVM 工作线程屏障及 SDK JSON 执行实际回调桥，仅替换 Android 消息传递和无关的能力结果枚举；另行使用真实 Android SDK 消息类型编译回调桥。`--baseline` 将当前 `HEAD` 回调桥读取到临时目录进行负例比较，不改写生产源码。检查覆盖两种取消先后顺序、非法关闭帧、RPC 故障、关闭拒绝及待处理回调的到期退役，不代表设备 Binder 行为。Build 120／r43 已通过这条中继的简单取消、嵌套取消及共享截止检查；[Linux 验证记录](model-ptc-linux.zh.md#verification)保留 r42 失败、实际退役事实和剩余限制。这不是嵌套进程死亡恢复或完整 PTC 套件验收。

宿主检查使用 `node --import tsx --test apps/android/tool/isolated-tool-call-port.test.mjs apps/android/tool/model-ptc-caller-binding.test.mjs apps/android/tool/isolated-tool-mutations.test.mjs`，覆盖真实 ToolRuntime 与 Session、原版文件工具、JSONL 刷盘、只读撤销、后置策略上下文、晚到取消及不确定结果。Windows 需要允许原版文件原子发布操作。这些检查不能证明 Android UID／Binder 隔离、进程死亡恢复或设备文件系统持久性；设备验收由 [PTC 执行设计](ptc-execution-design.zh.md)负责。
