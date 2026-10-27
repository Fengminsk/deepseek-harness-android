# Android 原生工作流注册

[English](tool-native-workflow.md) | 中文

`registerAndroidWorkflowTool` 通过 `createWorkflowToolDefinition` 复用原版 `workflow` 的参数、结果和展示契约。执行器及构建持有的可用性函数由 App 提供，默认关闭。配置档字段、模型参数或用户凭据都不能开启此门槛。生产 `index.mjs` 接线与真机验收仍是独立关口，仅导入此模块不会注册工具。

每次调用捕获准确的当前 ToolRuntime 定义和注册身份，核验存活的父 Agent 与真实 Session ID，并只消费一次 App 持有的准入票据。App 发放无文件及网络授权的 DSL 作用域，限定 120 秒、最多八个子级且并发两个。原版 JavaScript DSL 经固定的隔离客体执行，不在 Node 宿主中运行。子级工具使用独立的宿主授权，不向 DSL 提供直接文件系统或网络访问。

子级保留父级模型路由并使用专用预设。激活前，宿主捕获父级当前可见的 `read`、`glob`、`grep`、`write`、`edit`、`web_search` 和 `web_fetch` 精确注册，仅接受原厂持有且仍存活的定义。原版子级管理器必须在准确父级下发布预留的子级，授权才会把工具注册到该子级自己的作用域。每次调用经过原版 ToolRuntime、文件观察策略、Android 文件系统守卫及工具执行器。文件访问限于激活时从父级捕获的规范化目录；写入还同时满足父子双方当前沙箱模式和不可变权限根目录，切换目录不会扩大父级写权限。父级可见性变化、注册替换、策略降级、取消或退役都会阻止新调用。已经执行的调用仍按原工具的取消与收尾行为处理。

以只读策略启动的子级，不会因后续策略升级而获得写工具。网页工具仅从父级已经审查的注册中继承，并保留提供方原有检查。子级不获得 Shell、Linux、PTC 或递归委派工具。结构化子级可以先使用同一授权工具集合，再通过自身受校验的 `structured_output` 提交结果。原版子级设置结束后会捕获此工具的精确定义、注册身份和执行器，后续同名替换会被拒绝。SAF 授权和父级附件不跨 Session 委派，其当前会话守卫保持独立。冷恢复子级会重建 Session 历史，但仅凭预设名称或持久化父子关系不会恢复文件或网页授权。

前台调用仅发布确认完成的回执。`run_in_background: true` 必须获得 App 明确的后台策略，才把准备好的请求交给 `startBackgroundDsl`，在真实 jobs 注册表内保留父级与创建该任务的 ToolCall ID。交接后不继续绑定工具步骤的信号。取消仍由 jobs 和所有者销毁控制；失败或未确认的退役不会变成完成结果，也不会伪造 Session 终态。

主机检查：`node --import tsx --test apps/android/tool/tool-native-workflow.test.mjs apps/android/tool/tool-workflow-preflight.test.mjs apps/android/tool/workflow-child-tools.test.mjs apps/android/tool/workflow-subagent-backend.test.mjs`。子级专项通过真实父级预设 Loader 加载原版工具，让真实子 Agent 与 ToolRuntime 操作临时文件，核对持久 JSONL 工具结果，并检查策略降级、注册身份、受保护元数据、目录变化、结构化结果、取消和冷恢复。模型回复和网页提供方使用样例，因此不构成公网或 Android Binder 执行证据。其余专项在替代原生边界的条件下使用真实 jobs 注册表。原版包回归为 `node node_modules/vitest/vitest.mjs run packages/workflow/tool-workflow/tests/tool-workflow.spec.ts`。

剩余真机证据应在现有 App 进程内使用仅供测试的组合：脚本模型适配器与全新的 `android-…` Session，不修改用户账号配置。通过实际 ToolRuntime 执行前台纯运算、真实受限子级、后台任务及 `job_kill`，核对持久 Session 事件、原生回执身份和任务终态。验收时只允许此经核查的组合明确开启注册门槛。仅 Kotlin 传输样例或主机替身不能满足这项端到端证据要求。
