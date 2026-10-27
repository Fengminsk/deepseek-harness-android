# Android 持久工作流所有权

[English](durable-workflow-owner.md) | 中文

[`DurableWorkflowOwner`](../android/app/src/main/java/com/minnnng/dsh_android/DurableWorkflowOwner.java) 是 App 内部为受隔离工作流及其子级 ID 保存生命周期状态的组件。内部 `IsolatedWorkflowRunNativeBridge` 调用它完成原生接纳、取消和终态发布。它没有 App UID Shell 回退。普通隔离脚本以五秒为上限；App 持有的私有工作流客体另有 120 秒上限。此有限期限不能证明已完整对齐原版工作流能力。

原版 [`PtcWorkflowRun`](../../../packages/workflow/workflow-ptc/src/host.ts) 在取消、获取结果及销毁期间持有各子智能体句柄。Android 的 [`IsolatedScriptRunController`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptRunController.kt) 则只在 Binder 死亡、解绑和脚本回执持久化之后，确认单次隔离执行的结果。工作流持有者同时要求这两项条件，不把单独的脚本结果或子级结果认作整个工作流完成。

调用方提供已存在的 App 私有父目录和目录 fsync 实现。规范 UUID 运行 ID 会在访客或子级启动前获得新回执文件；该文件不删除，ID 不复用。规范的子级 Session UUID 先生成并持久记为 `RESERVED`，再交给子级后端。调用方在请求后端启动前持久记为 `LAUNCHING`。后端使用持有者指定的相同 ID 启动，并在工作流发布完成前向原生账本确认子级退役。专用预设拒绝子级使用工具，子级限于 App 进程内运行。回执版本 2 将此受限后端绑定至 `WorkflowProcessLease` UUID；版本 1 仍可读取，但不会补造缺失的归属信息。该进程租约不能证明操作系统后代进程或外部副作用的状态。

`requestCancel` 先持久记录 `CANCEL_REQUESTED`，再由调用方向访客和子级发出信号，并返回所有未退役的子级 ID。此后并发完成不能发布成功。调用方只能在安全后端确认终止和持久退役后，确认子级退役。`complete` 从磁盘读取对应 `IsolatedScriptReceipt`；只有回执为 `COMPLETED`、所有子级均已退役且工作流仍为 `ADMITTED`，才发布有大小限制的输出。`confirmCancelled` 还要求访客回执为 `CANCELLED`。`confirmFailed` 要求访客回执确认 `ERROR`、`TIMED_OUT` 或 `WORKER_DIED` 且所有子级已退役；`markUnconfirmed` 在无法证实回收时保留运行及待回收子级 ID。这些操作均不接受调用方提供的成功布尔值或未经确认的输出。

进程启动后须先执行 `recoverInterrupted`，再接纳新的工作流任务。进程租约在整个 JVM 生命周期持有 App 私有操作系统文件锁，不提供逻辑 close 接口。已知仍存活的所有者，其活动回执保持原样。成功取得旧租约锁表示 Android 已释放该进程持有的锁，只有此时才可将其记名的进程内子级标为 `RETIRED`。中断任务本身仍为无输出的 `INTERRUPTED_UNCONFIRMED`：子级终止不能证明任务完成，也不会撤销副作用。租约缺失、锁仍被持有或旧回执没有租约信息，都不能证明终止；相关子级 ID 会在重复恢复时保持待回收，并阻止新任务准入，直到清理被证实。恢复不会重放脚本或启动子级。损坏或不完整的回执保留在原处，禁止其 UUID 复用，并使对账关闭；新工作流接纳前须人工检查。已有完成、失败、取消回执不变。

`requestCancel` 在同一个所有者锁内持久化取消并发布进程内信号，回调不会在信号发布前读到新的持久状态。明确取消所触发的线程中断属于正常控制流程，本身不表示副作用无法确认。回调退役仍须同时等待回调线程退出与 Node 子级端口关闭，才能确认取消；其他回调失败或未完成的关闭继续保持未确认状态。

Session ID 保留原始的 1～128 字符 ASCII 标识（`[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`），包括 Android 的 `android-…` 形式，不替换为生成的 UUID。运行 ID、nonce 和工作区 ID 仍要求规范 UUID，从而保持原始 Session 事件历史及审批归属。

每次操作取得操作系统文件锁和进程内监视器、读取当前回执、原子替换有大小限制及校验和的快照，然后同步目录。这防止两个 App 进程同时发布状态转换。持有者要求在任何修改操作前完成启动对账。最多保留 4096 份运行回执，ID 不清理；容量耗尽时拒绝新任务。未发布的替换临时文件不算运行回执，也不能抹掉已接纳的 ID。文件或目录同步失败会终止调用；新 ID 可能已被占用，结果也可能无法确定。接纳目录同步或回执替换失败时，当前持有者会撤销对账状态，拒绝继续修改，直到 `recoverInterrupted` 把未完成运行标为未确认。持有者不能证明子级副作用、撤销副作用，或证明从 App 外部杀死的 Android 进程已清理后代。这些性质需要受隔离的子级后端和真机验证。

主机验收：`node apps/android/tool/acceptance-durable-workflow-owner.mjs` 编译 Java，并检查所有权、取消、另一个 JVM 中的重启恢复、不重放、确认完成的回执、损坏文件拒绝及注入的目录同步失败。它还会在真实子 JVM 持有租约时终止该进程，验证存活所有者保护、已终止所有者退役、v1 回执兼容，以及缺失或跨目录租约被拒。常规主机测试采用空目录同步适配器；Android 文件系统持久性和 App 集成仍须通过独立的[真机验收](native-workflow-process-death-device-acceptance.zh.md)。
即使 V8 脚本回执为 `COMPLETED`，工作流 DSL 仍可能返回 `stopReason: error`。原生所有者现将这种 DSL 结果持久记录为无输出的 `FAILED`；未知停止原因保留 `INTERRUPTED_UNCONFIRMED`。私有 Node 调用方会等待并发 Abort 取消请求完成、校验 DSL 结果，并且仅在原生终态与本地子任务回收都已确认后释放所有者。面向模型的入口仍须等待真机验收。
原生终态分类要求精确、有界的 DSL 结果结构：`value`、`stopReason`、整数 `agentsStarted`，失败时还须有结构化错误字段。即使 V8 自身执行完成，缺失、格式错误或未知的结果仍保留待检查状态。

受信任的 App 私有 `startBackgroundDsl` 入口使用原版 `ctx.jobs` 注册任务，并将准确的父级 Agent 设为持有者。任务取消和持有者销毁会中止运行，等待原生取消、子级退役及结算，然后才报告任务终态。只有经确认完成的工作流会交付结果；原生退役未确认时，任务失败且 Session 的运行记录保持未结束，供后续检查。Jobs 注册表仅存在于当前进程；进程死亡后不会恢复任务或重放访客。`workflow.inspect` 读取持久 Session 事件，并对未结束的运行通过 `native.workflow.inspect` 读取原生回执；中断状态及待退役子级数量可直接观察，不会伪造 `run-end`。原生终态已有回执但 Session 终态事件尚未持久化时，仍报告未确认，而非完成。

App 私有后台入口尚未连接面向模型的 `run_in_background` 参数；该参数和原版工作流工具仍关闭。开放前仍需受信任的生产注册路径、App 进程死亡与子级清理的 Android 真机测试，以及通用 PTC 对齐。
