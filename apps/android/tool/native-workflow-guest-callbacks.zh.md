# 隔离工作流回调传输

中文 | [English](native-workflow-guest-callbacks.md)

`NativeWorkflowGuestCallbacks` 是 Node 宿主中一个运行实例对应一个令牌的回调端口。它只接受宿主已准备的 `kind: workflow` 请求，在原生端确认 `native.workflow.bindCallbacks` 后，才把 `WORKFLOW_BEGIN`、`WORKFLOW_START_CHILD`、`WORKFLOW_CHILD_RESULT`、`WORKFLOW_DISPOSE_CHILD` 和 `WORKFLOW_PROGRESS` 转交给 `WorkflowGuestHostPort`。每个回调都必须携带同一个运行 ID、宿主私有令牌和不可重放的调用序号。关闭时等待子 Agent 退出，清理失败会拒绝关闭。

最多同时绑定 4 个运行；每个运行最多接受 128 次回调，同时等待分发的回调最多 8 个。宿主在预留调用序号之前，会将 JSON 请求按 64 KiB 上限复制成不可变快照；已接受的请求再按调用序号串行执行。每个回包在交付原生端之前还要经过 64 KiB 上限校验。过大或队列已满而被拒绝的请求不会消耗下一序号。关闭会取消并回收子任务端口，随后等已接受的回调退出；子任务回收失败仍是关闭失败。

`IsolatedWorkflowRequest` 和 `IsolatedWorkflowCallbackBridge` 是 Android App 侧的对应协议片段。构造中继时必须提供 `DurableWorkflowOwner`，且每次回调与回包发布前都复核运行仍处于 `ADMITTED`。Binder 中继还核对发送者 UID、运行 ID、nonce、严格字段集、序号、请求大小和回包身份；回调异常会取消运行，并把结果标为需要检查。隔离进程仍只拥有现有 `host.callAsync` JSON 通道，不会得到 App 文件路径、Node 对象或通用工具 API。

内部 `native.workflow.admit/bindCallbacks/execute/cancel/settle/release` 路由先预留脚本及工作流回执，才回复 App 生成的令牌；隔离脚本控制器完成执行后，只发布对应的持久终态。`AgentService` 通过 `native.workflowCallback` 与 `native.workflowCallback.cancel` 向 Node 发起反向请求。`NativeWorkflowPrivateOwner` 要求准备好的会话 ID 与在线父 Agent 的会话一致，在接纳后写入原版 `tool-workflow/run-start` 记录，并在确认进度回调前经 `SessionStore.flush` 落盘每个成员的开始和结束。只有子级回收、原生结算及释放均获确认，才写入并落盘 `tool-workflow/run-end`；存储未确认或收尾不确定时保留未结束的运行。Binder 中继在转发 `WORKFLOW_START_CHILD` 前持久预留子级 UUID 和 `LAUNCHING` 状态；Node 使用此 UUID 通过原版 `startActivation` 启动仅含模型能力的子级。`WORKFLOW_CHILD_RESULT` 返回有界内容；`WORKFLOW_DISPOSE_CHILD` 等原版 activation 完成回收后才将回执标为已退役。

Agent Service 启动时先取得独占运行时进程锁，再对旧工作流回执对账并启动 Node。它通过 `runtime.status.workflowRecovery` 提供本次新中断运行和未退役子级的数量；这一启动快照不能替代逐会话的 `workflow.inspect` 来查看更早的待检查记录。回执不可读取只阻止新工作流准入，不中断无关的 App 工作。Node 尚未接纳就退出时清除进程标记，不误报已启动的 Node 崩溃。冷启动不会重放访客；若还有未回收的子任务 ID，在后端确认子级停止前拒绝新工作流准入。取消时经回调关闭确认后，仅预留而未启动的子级也能退役。

私有 `workflow.inspect` RPC 通过只读持久化句柄读取准确父 Session 的有界物理事件前缀。有 `run-end` 记录时以其终态为准；有未结束记录且内存中存在对应所有者时，判为运行中；所有者退出后仍未结束的记录判为 `interrupted-unconfirmed`，需要复核。会话仍附着但找不到对应所有者、读取期间所有权改变、日志过长或事件冲突，都保守判为 `unconfirmed`。检查不会恢复 Agent、重放访客，也不会补写虚假的 `run-end`。这是诊断契约，尚非自动续跑或界面恢复流程。

**面向模型的工作流入口仍未开放。** 子级在 App UID 下使用作用域内零工具预设；该预设不能提供独立的操作系统 UID，也不能将任意子级代码的文件系统和网络访问变成完整沙箱。私有客体在较窄限制内支持原版工作流钩子，会话记录使用原版事件名称。会话追加并不等同独立、经 fsync 确认的工作流进度日志。普通隔离脚本仍以 5 秒为上限；只有 App 持有的私有工作流路由可请求最多 120 秒，而且作用域租约必须覆盖这个期限。此有限客体期限本身不能证明通用模型推理流程已对齐。进程终止和回调竞态仍需独立真机验收。面向模型的 `ptc-runtime`、`workflow-ptc` 与 `tool-workflow` 继续关闭。

宿主测试：`node --test apps/android/tool/native-workflow-guest-callbacks.test.mjs apps/android/tool/workflow-guest-host-port.test.mjs apps/android/tool/workflow-child-port.test.mjs apps/android/tool/workflow-cold-observation.test.mjs` 和 `node --import tsx --test apps/android/tool/workflow-subagent-backend.test.mjs`。冷启动检查测试会先落盘原版父 Session，再销毁旧 Context，并由新 Context 重新打开 JSONL 日志。Android 隔离 Binder 验收用例为 `NativeWorkflowAcceptanceInstrumentation`，需在设备执行。
