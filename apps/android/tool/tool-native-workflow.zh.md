# Android 原生工作流注册

[English](tool-native-workflow.md) | 中文

`registerAndroidWorkflowTool` 通过 `createWorkflowToolDefinition` 复用原版 `workflow` 的参数、结果和展示契约。执行器及构建持有的可用性函数由 App 提供，默认关闭。配置档字段、模型参数或用户凭据都不能开启此门槛。生产 `index.mjs` 接线与真机验收仍是独立关口，仅导入此模块不会注册工具。

每次调用捕获准确的当前 ToolRuntime 定义和注册身份，核验存活的父 Agent 与真实 Session ID，并只消费一次 App 持有的准入票据。App 发放无文件及网络授权的作用域，限定 120 秒、最多八个子级且并发两个。子级继承父级模型路由和受限预设，不具备文件、网页或 Shell 工具，仅在请求结构化输出时开放结果提交。原版 JavaScript DSL 经固定的隔离客体执行，不在 Node 宿主中运行。

前台调用仅发布确认完成的回执。`run_in_background: true` 必须获得 App 明确的后台策略，才把准备好的请求交给 `startBackgroundDsl`，在真实 jobs 注册表内保留父级与创建该任务的 ToolCall ID。交接后不继续绑定工具步骤的信号。取消仍由 jobs 和所有者销毁控制；失败或未确认的退役不会变成完成结果，也不会伪造 Session 终态。

主机检查：`node --import tsx --test apps/android/tool/tool-native-workflow.test.mjs apps/android/tool/tool-workflow-preflight.test.mjs`。它使用真实 ToolRuntime、Agent 和 jobs 注册表，但替代了原生边界，不能证明 Android Binder 执行。原版包回归为 `node node_modules/vitest/vitest.mjs run packages/workflow/tool-workflow/tests/tool-workflow.spec.ts`。

剩余真机证据应在现有 App 进程内使用仅供测试的组合：脚本模型适配器与全新的 `android-…` Session，不修改用户账号配置。通过实际 ToolRuntime 执行前台纯运算、真实受限子级、后台任务及 `job_kill`，核对持久 Session 事件、原生回执身份和任务终态。验收时只允许此经核查的组合明确开启注册门槛。仅 Kotlin 传输样例或主机替身不能满足这项端到端证据要求。
