# 隔离工作流回调传输

中文 | [English](native-workflow-guest-callbacks.md)

`NativeWorkflowGuestCallbacks` 是 Node 宿主中一个运行实例对应一个令牌的回调端口。它只接受宿主已准备的 `kind: workflow` 请求，在原生端确认 `native.workflow.bindCallbacks` 后，才把 `WORKFLOW_BEGIN`、`WORKFLOW_START_CHILD`、`WORKFLOW_CHILD_RESULT`、`WORKFLOW_DISPOSE_CHILD` 和 `WORKFLOW_PROGRESS` 转交给 `WorkflowGuestHostPort`。每个回调都必须携带同一个运行 ID、宿主私有令牌和不可重放的调用序号。关闭时等待子 Agent 退出，清理失败会拒绝关闭。

最多同时绑定 4 个运行；每个运行最多接受 128 次回调，同时等待分发的回调最多 8 个。宿主在预留调用序号之前，会将 JSON 请求按 64 KiB 上限复制成不可变快照；已接受的请求再按调用序号串行执行。每个回包在交付原生端之前还要经过 64 KiB 上限校验。过大或队列已满而被拒绝的请求不会消耗下一序号。关闭会取消并回收子任务端口，随后等已接受的回调退出；子任务回收失败仍是关闭失败。

`IsolatedWorkflowRequest` 和 `IsolatedWorkflowCallbackBridge` 是 Android App 侧的对应协议片段。构造中继时必须提供 `DurableWorkflowOwner`，且每次回调与回包发布前都复核运行仍处于 `ADMITTED`。Binder 中继还核对发送者 UID、运行 ID、nonce、严格字段集、序号、请求大小和回包身份；未经可信证明的回调异常会取消运行，并把结果标为需要检查。隔离进程仍只拥有现有 `host.callAsync` JSON 通道，不会得到 App 文件路径、Node 对象或通用工具 API。

试图扩宽父 Agent 模型路由的子任务请求会在激活前被拒绝。可信后端记录一份私有、单次消费的证明，绑定运行 ID 和 App 预留的子任务 ID。只有原始错误对象可以产生 `{runId, callId, denied: {code: 'MODEL_ROUTE_DENIED', childId}}`；相同错误文字或复制错误码均不能。原生中继核对全部字段后停止客体并关闭同级子任务。发布 `FAILED` 回执仍要求客体 Binder 死亡、回调工作线程退出、Node 成功关闭，以及每份预留记录均持久化为已退役。回包畸形、传输失败、缺少关闭确认或退役失败仍为未确认；单独一次成功关闭不能清除这些故障。此区别的 Android 验证由 `NativeWorkflowAcceptanceInstrumentation` 和真实 Node 工作流套件负责。

控制器将客体结果状态传入回调校验。只有工作流 `DEADLINE_EXCEEDED` 可以在仍有待处理回调时进入退役流程；成功结果仍要求零待处理回调，身份、UID、持久化准入及期限校验保持不变。`WorkflowCallbackRetirement` 在中断工作线程前记录本所有者的停止请求，因此由此产生的 `InterruptedException` 或 `CancellationException` 即使没有用户取消也属于预期控制流。未经请求的中断、RPC 超时、回包畸形及其他故障继续保持未确认，后续成功关闭也不能清除。退役仍要求工作线程退出及 Node 关闭，再结合客体死亡和绑定清理证据；此次调整不会将到期伪装为成功或用户取消。普通文件与 PTC 回调校验不变。`node apps/android/tool/acceptance-workflow-callback-retirement.mjs` 使用真实 JVM 线程中断和负例检查生产状态所有者；它不执行 Android Binder，也不能替代真实 Node 期限套件。

内部 `native.workflow.admit/bindCallbacks/execute/cancel/settle/release` 路由先预留脚本及工作流回执，才回复 App 生成的令牌；隔离脚本控制器完成执行后，只发布对应的持久终态。`AgentService` 通过 `native.workflowCallback` 与 `native.workflowCallback.cancel` 向 Node 发起反向请求。`NativeWorkflowPrivateOwner` 要求准备好的会话 ID 与在线父 Agent 的会话一致，在接纳后写入原版 `tool-workflow/run-start` 记录，并在确认进度回调前经 `SessionStore.flush` 落盘每个成员的开始和结束。只有子级回收、原生结算及释放均获确认，才写入并落盘 `tool-workflow/run-end`；存储未确认或收尾不确定时保留未结束的运行。Binder 中继在转发 `WORKFLOW_START_CHILD` 前持久预留子级 UUID 和 `LAUNCHING` 状态；Node 使用此 UUID 通过原版 `startActivation` 启动仅含模型能力的子级。`WORKFLOW_CHILD_RESULT` 返回有界内容；`WORKFLOW_DISPOSE_CHILD` 等原版 activation 完成回收后才将回执标为已退役。

Agent Service 启动时先取得独占运行时进程锁，再对旧工作流回执对账并启动 Node。它通过 `runtime.status.workflowRecovery` 提供本次新中断运行和未退役子级的数量；这一启动快照不能替代逐会话的 `workflow.inspect` 来查看更早的待检查记录。回执不可读取只阻止新工作流准入，不中断无关的 App 工作。Node 尚未接纳就退出时清除进程标记，不误报已启动的 Node 崩溃。冷启动不会重放访客；若还有未回收的子任务 ID，在后端确认子级停止前拒绝新工作流准入。取消时经回调关闭确认后，仅预留而未启动的子级也能退役。

私有 `workflow.inspect` RPC 通过只读持久化句柄读取准确父 Session 的有界物理事件前缀。有 `run-end` 记录时以其终态为准；有未结束记录且内存中存在对应所有者时，判为运行中；所有者退出后仍未结束的记录判为 `interrupted-unconfirmed`，需要复核。会话仍附着但找不到对应所有者、读取期间所有权改变、日志过长或事件冲突，都保守判为 `unconfirmed`。检查不会恢复 Agent、重放访客，也不会补写虚假的 `run-end`。这是诊断契约，尚非自动续跑或界面恢复流程。

**面向模型的工作流入口仍未开放。** 子级在 App UID 下使用作用域内零工具预设；该预设不能提供独立的操作系统 UID，也不能将任意子级代码的文件系统和网络访问变成完整沙箱。私有客体在较窄限制内支持原版工作流钩子，会话记录使用原版事件名称。会话追加并不等同独立、经 fsync 确认的工作流进度日志。普通隔离脚本仍以 5 秒为上限；只有 App 持有的私有工作流路由可请求最多 120 秒，而且作用域租约必须覆盖这个期限。此有限客体期限本身不能证明通用模型推理流程已对齐。进程终止和回调竞态仍需独立真机验收。面向模型的 `ptc-runtime`、`workflow-ptc` 与 `tool-workflow` 继续关闭。

宿主测试：`node --test apps/android/tool/native-workflow-guest-callbacks.test.mjs apps/android/tool/workflow-guest-host-port.test.mjs apps/android/tool/workflow-child-port.test.mjs apps/android/tool/workflow-cold-observation.test.mjs` 和 `node --import tsx --test apps/android/tool/workflow-subagent-backend.test.mjs`。冷启动检查测试会先落盘原版父 Session，再销毁旧 Context，并由新 Context 重新打开 JSONL 日志。Android 隔离 Binder 验收用例为 `NativeWorkflowAcceptanceInstrumentation`，需在设备执行。

[原生设备驱动](acceptance-native-workflow-device.mjs) 要求五个独立的 Instrumentation 进程：包含已确认路由拒绝的八项基础检查，错误预留身份、传输失败和关闭失败各一阶段，最后冷启动检查三个未确认运行。每阶段强制停止后，必须连续两次读取完整进程名列表，确认 App、测试包及隔离客体均已消失，才能开始下一阶段。各阶段报告实际 PID 和不同的进程租约。冷启动检查使用生产恢复所有者与操作系统租约观察，必须保留各运行的 `INTERRUPTED_UNCONFIRMED` 状态，同时确认旧进程死亡后其受限子任务已退役。测试不会修补这些负例回执，也不清除 App 数据。请求使用专用的 `native-workflow-acceptance-<runId>` Session 身份。阶段不完整、回执归属变化或进程退出未确认都会阻止汇总通过。驱动不唤醒或解锁手机；调用方须在进程切换期间持续提供屏幕保护。驱动测试只检查调度，不是真机证据。
