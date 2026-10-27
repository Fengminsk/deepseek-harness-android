# Android 原生工作流注册

[English](tool-native-workflow.md) | 中文

`registerAndroidWorkflowTool` 通过 `createWorkflowToolDefinition` 复用原版 `workflow` 的参数、结果和展示契约。执行器及构建持有的可用性函数由 App 提供，默认关闭。配置档字段、模型参数或用户凭据都不能开启此门槛。Build 116 候选在限定范围的 r26 真机验收后，将 `index.mjs` 中的 `MODEL_WORKFLOW_DEVICE_ACCEPTED` 设为 `true`；仅导入此模块仍不会注册工具。包含 workflow 的正式 profile（`expectWorkflow=true`）与普通 Build 116 升级仍待验证。系统提示只允许在用户明确要求工作流或多 Agent 编排时使用 workflow。

`modelWorkflowCapability` 将最大已审查子级工具集合报告为 `read`、`glob`、`grep`、`write`、`edit`、`web_search`、`web_fetch`、`linux_exec`、`linux_import`、`linux_export` 和 `linux_inspect`，对应 `childTools: 'reviewed-parent-tools'`。这不保证某个父级或子级一定具有其中任何工具，也不绕过实时准入。Linux 工具必须已在父级有效注册，这又要求已验证的客体构建与原生能力标记。候选源码已开放受审查 workflow 及离线 Linux 注册；模型参数不能开启缺失工具。能力说明描述激活时工作区、父子策略交集、继承的网页提供方，以及子 Session 私有且离线的 Linux 磁盘。面向模型的工具描述与系统提示列明这些条件能力及限制。

每次调用捕获准确的当前 ToolRuntime 定义和注册身份，核验存活的父 Agent 与真实 Session ID，并只消费一次 App 持有的准入票据。App 发放无文件及网络授权的 DSL 作用域，限定 120 秒、最多八个子级且并发两个。原版 JavaScript DSL 经固定的隔离客体执行，不在 Node 宿主中运行。子级工具使用独立的宿主授权，不向 DSL 提供直接文件系统或网络访问。

私有准入分别传递固定驱动程序和 `workflowBody`。原生编译器构造仅接收 `agent`、`parallel`、`pipeline`、`phase`、`log` 和 `args` 参数的异步函数体，然后关闭字符串代码生成，再将该函数作为第三实参传入驱动程序。函数体无法捕获驱动程序的宿主回调或局部变量。`WORKFLOW_BEGIN` 仅提供元数据、参数和限额，不编译代码。运行时的 `eval`、`Function` 和函数构造器仍被禁用。两个源码字段分别受 64 KiB UTF-8 上限约束；语法错误的函数体在发起回调前失败。

子级保留父级模型路由并使用专用预设。激活前，宿主从已审查集合中捕获父级当前可见的精确注册，仅接受原厂持有且仍存活的定义。原版子级管理器必须在准确父级下发布预留的子级，授权才会把工具注册到该子级自己的作用域。每次调用经过原版 ToolRuntime 和工具执行器；常规文件工具保留文件观察策略及 Android 文件系统守卫。App 文件访问限于激活时从父级捕获的规范化目录；写入还同时满足父子双方当前沙箱模式和不可变权限根目录，切换目录不会扩大父级写权限。父级可见性变化、注册替换、策略降级、取消或退役都会阻止失去授权的新调用。已经执行的调用仍按原工具的取消与收尾行为处理。

以只读策略启动的子级，不会因后续策略升级而获得写工具。网页工具仅从父级已经审查的注册中继承，并保留提供方原有检查。子级不获得 App UID Shell、PTC 或递归委派工具。结构化子级可以先使用同一授权工具集合，再通过自身受校验的 `structured_output` 提交结果。原版子级设置结束后会捕获此工具的精确定义、注册身份和执行器，后续同名替换会被拒绝。SAF 授权和父级附件不跨 Session 委派，其当前会话守卫保持独立。冷恢复子级会重建 Session 历史，但仅凭预设名称或持久化父子关系不会恢复文件、网页或 Linux 授权。

`linux_exec` 使用子 Session 私有磁盘，客体没有网络。只有激活时允许写入且父子双方当前策略均仍可写时才保留修改，否则命令产生的磁盘修改会被丢弃。后续策略升级不能扩大激活时授权。`linux_import` 读取获准的 App 文件，`linux_export` 发布新的 App 文件；相对 App 路径从子级 cwd 解析。两种传输都要求激活时可写和父子双方当前写权限，并限于激活目录及双方权限根目录。异步文件准备完成后会再次校验策略。整个 App 的 Linux 执行容量为一，因此并行工作流须串行安排各子级的 Linux 步骤。忙碌拒绝发生于原生分发前，既不代表完成，也不应触发自动重放。取消会等待原生执行退役并保留返回的提交回执，不假定已经回滚。

前台调用仅发布确认完成的回执。`run_in_background: true` 必须获得 App 明确的后台策略，才把准备好的请求交给 `startBackgroundDsl`，在真实 jobs 注册表内保留父级与创建该任务的 ToolCall ID。交接后不继续绑定工具步骤的信号。取消仍由 jobs 和所有者销毁控制；失败或未确认的退役不会变成完成结果，也不会伪造 Session 终态。

主机检查：`node --import tsx --test apps/android/tool/tool-native-workflow.test.mjs apps/android/tool/tool-workflow-preflight.test.mjs apps/android/tool/workflow-child-tools.test.mjs apps/android/tool/workflow-subagent-backend.test.mjs`。子级专项通过真实父级预设 Loader 加载原版工具，让真实子 Agent 与 ToolRuntime 操作临时文件，核对持久 JSONL 工具结果，并检查策略降级、注册身份、受保护元数据、目录变化、结构化结果、取消和冷恢复。模型回复和网页提供方使用样例。Linux 用例使用真实 NativeLinuxVm 宿主所有者与样例原生回执，并未启动 Android 客体。这些检查不构成公网或 Android Binder 执行证据。其余专项在替代原生边界的条件下使用真实 jobs 注册表。原版包回归为 `node node_modules/vitest/vitest.mjs run packages/workflow/tool-workflow/tests/tool-workflow.spec.ts`。

r26 真机证据已通过常规 workflow 套件（11／11）、120,256 毫秒时限检查（一个持久 run-end 且确认子级退役）及进程死亡恢复；参见[workflow 验收](workflow-device-acceptance.zh.md)与[生命周期证据](workflow-lifecycle-device.zh.md)。这些夹具通过脚本模型适配器执行实际 ToolRuntime、隔离原生所有者及 Session 记录，未修改用户账号设置。此前 r25 workflow 时限尝试达到 390 秒仍无结果，原因仍未解释。Build 116 候选已开放受审查入口，但所装 `expectWorkflow=true` 正式 profile 与普通升级的数据保持仍需端到端验证。主机或仅 Kotlin 的夹具不能替代这些证据。
