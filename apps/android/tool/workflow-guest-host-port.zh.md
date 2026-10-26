# Android 工作流 Guest 回调

中文 | [English](workflow-guest-host-port.md)

`WorkflowGuestHostPort` 是一个已准入工作流的内部回调持有者。它通过 `begin` 返回有界脚本输入，将 `startChild`、`childResult` 和 `disposeChild` 交给 `WorkflowChildPort`，并按顺序将 `phase`、`log`、`agent-start` 和 `agent-end` 进度交给可信观察者。它不负责运行准入、执行 JavaScript、持久化 Session 事件，也不注册模型工具。App 私有原生工作流持有者已将其连接到隔离 V8 Guest；面向模型的工作流工具仍关闭。

调用方必须提供已由持久化持有者准入的 App 选定执行请求、子任务授权函数、受约束的子任务启动后端，以及每次返回前持久化所接收事件的进度观察者。`installWorkflowSubagentPreset` 每个运行时注册一次仅供模型调用的子级预设；它固定原生工具展示、屏蔽继承的工具，并拒绝稍后在子级作用域注册的工具执行；`createWorkflowSubagentBackend` 将各个工作流绑定到原版 `spawn` 激活管理器。两者要求精确的在线父 Agent、已准入的运行 ID、Session 持久化和查询服务；每次启动还须消耗 App 对相同运行 ID、父级 ID 与规范子会话 UUID 的预留。请求的提供方或模型不能偏离父级路由。原版 schema 选项通过单独的受限预设使用子级本地 `structured_output` 工具；只有被接受的结构化结果会送回 Guest。子任务拥有独立的持久化 Session，模型不能执行工具。这是在 App 进程内约束模型操作，并非为子级模型客户端另建 UID 沙箱。原生子级回调要求 App 预留，并将启动、取消和退役接入持久持有者；真机行为仍未验证。子任务可能恢复期间须保留该预设，并在运行时启动时重新安装。App 私有持有者负责持久准入和 Guest 调用，但不会开放面向模型的工作流工具。`begin` 只接受一个空对象，返回已校验的元信息、脚本正文、JSON 参数和限制。App 持有的私有工作流客体最长运行 120 秒，普通隔离脚本仍限五秒；此有限期限不能证明已完整对齐原版 DSH 工作流能力。

每批进度在交付任何事件前复制并校验。每批最多 64 条、64 KiB；一次运行最多接收 2,048 条事件。智能体开始事件必须指向本端口已发布的子任务，使用递增序号，每个子任务只能开始一次，并且恰有一个匹配的结束事件。观察者失败或无效进度会立即取消子任务，并阻止 `close()` 报告干净结束；子任务释放失败同样不能干净关闭。开始释放会立即阻止已等待中的子任务结果发布，迟到输出不能再交付。后端释放失败时继续占用并发名额，停止启动新子任务并取消其他子任务；一个可能还在运行的子任务不能为新子任务腾出名额。启动器返回的子会话 ID 若与 App 预留 ID 不符，端口仍持有句柄直至确认释放；释放失败时保留并发名额，并将关闭状态标为未确认。 格式不完整的启动结果若仍有释放句柄，会在拒绝前退役；若没有释放句柄，则关闭结果无法确认，并停止后续子任务启动。关闭时停止回调和子任务启动，等待已发布子任务退出，并为已记录但尚未结束的智能体写出取消结束事件。调用方必须将 `ANDROID_WORKFLOW_RETIRE_UNCONFIRMED` 视为结果未确认，不得发布工作流成功结果。

主机检查：`node --import tsx --test apps/android/tool/workflow-child-port.test.mjs apps/android/tool/workflow-guest-host-port.test.mjs` 和 `node --import tsx --test apps/android/tool/workflow-subagent-backend.test.mjs`。集成测试通过脚本模型验证真实子 Agent、Session 归属、工具执行拒绝、精确子级身份、模型路由收窄及 App 拒绝、结果及释放和同进程冷恢复。进程重启恢复、原生子级账本接线、真机执行、原版 `parallel`／`pipeline` 行为、持久化工作流进度以及模型可见 PTC 仍未验证或不可用。
