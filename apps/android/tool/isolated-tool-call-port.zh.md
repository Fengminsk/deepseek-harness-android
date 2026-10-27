# Android 隔离工具调用端口

[English](isolated-tool-call-port.md) | 中文

受信任的结果投影可抛出 `reviewedToolProjectionError(message)`，携带由宿主编写、最多 4 KiB 的恢复提示。端口确认结果不支持后，把私有登记的提示保留在 Guest 可捕获的错误及 Session 错误原因中。修改错误对象不能改变已登记的提示；未知投影异常只返回通用消息。Guest 随后可在同一次调用预算内缩小参数并重试。

`apps/android/runtime/isolated-tool-call-port.mjs` 是**已完成准入的单次**脚本、经审查的 PTC 或工作流 Guest 的宿主侧回调边界。[只读 PTC 所有者](model-ptc-readonly.zh.md)提供原始工具定义审查和有界结果投影。它不注册 `run_code`、不启动 Guest，也不批准文件或网络权限。`cordis.patch.yml` 中的 Android PTC 与工作流仍保持关闭。

原版 DSH `run_code` 接收 TypeScript 异步函数体，并绑定当前 Agent 可见的工具。内部工具调用携带父执行令牌、根调用与子调用 ID，经过 `ToolRuntime` 的策略、取消和配对会话审计。Android 隔离 V8 Guest 接收 JavaScript 函数体；受信任宿主现可把可擦除的 TypeScript 转为该格式。原生 Binder 通道可传递具名异步工具回调，但生产模型调用方尚未绑定原版 `tools.*` 集合。本端口只实现原版契约在宿主侧的一段，不能代表语言或工作流功能齐备。

受信任的 App 宿主用匹配的原生准入、**未授予文件或网络权限**的规范化 Guest 范围、属于同一会话的外层 `ToolRunContext`、生产 `ToolRuntime`、有限允许列表、每次调用必经的 `authorizeTool` 策略回调，以及 App 私有持久日志创建端口。Guest 回调只能提交 `{runId,callId,name,arguments}`。`callId` 是单调递增的整数，拒绝的尝试也会消耗编号；宿主自行生成会话子调用 ID。端口校验运行归属、纯 JSON、大小与次数；拒绝不在允许列表内的名称、`run_code`、已知的 App 环境文件、Shell、PTC 或工作流工具、调用时已失去可见性的工具、绑定后被同名替换的工具，以及当前宿主策略不批准的调用。子调用串行执行，写入配对的 `tool/ptc-dispatch-start` 与 `tool/ptc-dispatch` 事件，并携带外层令牌及取消信号经过 `ToolRuntime.execute`。成功的 JSON 结果经限额检查后返回 Guest；普通工具错误可由 Guest 捕获。图片、延迟上下文和结束回合标记暂不交给 Guest。超出审计限制的内容、无法表示或超限的 Guest 返回值，以及过长的工具错误均确认为“不支持”的结果；它们不会泄露给 Guest，也不会妨碍后续调用。审计或分发结果不确定时，端口停止后续调用。`close()` 取消并等待在途调用退出；已有未确认分发时会报错。

`IsolatedToolCallJournal` 在 App 私有的 `DSH_HOME/isolated-tool-call-journal/<runId>/` 下写入独占且同步落盘的标记。原生回调绑定前先原子占用并同步运行目录；包括进程退出后留下的空目录在内，任何旧目录都使重新绑定在再次请求原生端之前被拒绝。顺序为**占用运行目录 → 原生绑定 → 准备 → 会话开始事件 → 分发 → ToolRuntime → 观察到结果 → 会话终态事件 → 确认 → 回复 Guest**。标记只含 ID、工具名和 SHA-256 摘要，不存参数、结果或准入令牌原文。重启后，`prepared` 表示尚未进入分发；`dispatch-unconfirmed` 表示副作用可能已经发生；`result-unconfirmed` 表示运行时已有结果，但配对审计或 Guest 回复未确认；`confirmed` 表示同步会话 append 与日志确认都已返回。每个运行目录和调用标记都不可复用，包括尚未发生首次回调就绑定失败的运行。App 不会重放它们。[无密钥状态快照](isolated-tool-call-journal.snapshot.json) 由宿主测试核对。

原生回调通道校验 Binder 调用方 UID、运行身份、nonce、调用序号，以及 App 到 Node 的私有准入令牌。Guest 提交的运行 ID 只能做关联校验，**不能**用作身份认证。`NativeIsolatedToolCallbacks` 仅在持久准入后把原生运行与本端口配对；取消和收尾等待 `close()` 结果。只有端口创建的已确认工具错误、已确认的不支持结果，或分发前的策略拒绝会变为精确的 `{error:{code,message}}` 原生回复。App 自有的 Guest `tools.name()` 绑定将该回复抛为 JavaScript 可捕获错误。审计、传输或取消异常不能伪装成这种回复，运行仍按不确定结果收尾。App 还必须审查工具允许列表：`ToolRuntime` 策略不可代替隔离沙箱，App UID Shell、无限制文件或环境网络工具不能自动继承脚本权限。端口在进入 `ToolRuntime` 前检查绑定时的工具定义，`ToolRuntime` 则在异步策略与分发期间固定调用开始时选中的注册身份。工具在执行主体前被同名替换时会返回 `UNKNOWN_TOOL`；暂存版运行时回归验证了新旧主体均不会执行。此身份检查不能隔离恶意同 UID 代码对已注册定义对象的直接修改或绕过运行时的调用。持久日志能阻止重放，但**不能证明已分发的外部副作用是否提交**；`authorizeTool` 必须为绑定时的同一个工具定义对象返回 `pure` 或 `read-only` 分类；仅凭名称、单独的分类字符串或笼统的布尔批准均会被拒绝。每次分发前都会重新核对。策略回调抛错表示批准或审计状态可能不确定，会终止运行，不能变成 Guest 可捕获的普通拒绝。这项分类由宿主给出，不能单独证明工具没有副作用；生产允许列表仍须逐个审查工具定义。原生通道最多接收 32 次单调编号的调用，绑定工具时要求文件和网络范围为空。`ToolRuntime` 还依赖各工具遵守其 AbortSignal；若工具无法退出，`close()` 会保持等待并隐藏输出。日志确认发生在同步 Session append 返回之后，目前没有跨存储的原子提交，也没有 Session 落盘完成的证明。没有手机期间，设备上的 UID、Binder 死亡、设备文件系统持久性和取消行为尚未验证；工作流还需接入生产子 Agent。

宿主验证命令：`node --test apps/android/tool/isolated-tool-call-port.test.mjs apps/android/tool/native-isolated-tool-callbacks.test.mjs apps/android/tool/isolated-tool-call-journal.test.mjs apps/android/tool/app-owned-model-ptc.test.mjs`。测试覆盖真实暂存版 `ToolRuntime`、原生回调绑定、子进程在分发途中退出、重启拒绝重放、摘要不一致、取消和会话终态审计失败；这些不能证明 Android UID、Binder 行为、设备文件系统持久性或 Session 落盘。模型工具必须等到 [PTC 执行设计](ptc-execution-design.zh.md) 的设备与产品准入条件通过后才能启用。
