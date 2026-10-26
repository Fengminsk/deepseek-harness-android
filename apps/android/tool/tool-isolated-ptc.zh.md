# Android 模型 PTC 入口

[English](tool-isolated-ptc.md) | 中文

原版 DSH 的 `run_code` 是 PTC 模式的保留传输，包含生成的工具 SDK、日志、时间预算、沙箱审批和嵌套工具执行。Android 当前以原版 `ToolRuntime` 的 native 模式运行。拟提供的 `android_ptc` 是明确受限的产品路径，不等同于通用 `run_code`：模型只提供 `code` 和 `description`，App 将语言固定为 TypeScript 异步函数体，期限固定为五秒。客体没有文件或网络授权，只能通过 `tools.list_agents({ scope: 'children' })` 调用已审核的原版直接子任务查询。

Android 运行时启动时会用原生隔离执行桥、持久回调日志、原版 `ToolRuntime`、Agent 注册表和子任务服务创建 App 归属的 PTC owner，并将它交给 `registerAndroidPtcTool` 和源码控制的产品闸门。无 Root 真机的隔离、取消、回调退役和进程死亡验收尚未完成，闸门保持 `false`；因此当前构建不会注册或开放 `android_ptc` 模型工具。闸门不是模型参数、用户设置、profile 配置或远程开关。`runtime.permissions.programmaticTools.modelPtc` 如实报告不可用状态和零授权边界。原版 `ptc-runtime`、`workflow-ptc` 与 `tool-workflow` 模块继续受保护且禁用。

条件注册的工具定义使用真实外层 `ToolRunContext`。Owner 用 `ToolRuntime.isActiveExecution` 拒绝伪造或已经结束的父调用，从父 Agent 导出会话，签发新的 App 零授权租约，校验并擦除有界代码的类型，然后准入一次原生隔离运行。它只发现仍为该 Agent 注册的原版第一方 `list_agents` 定义。每次嵌套回调都重新核对精确注册身份、当前 Agent、父令牌和参数策略；递归 `descendants`、额外字段、替换注册和环境工具会被拒绝。`IsolatedExecutionRun` 对原生持久回执只投影一次；成功值及有界 console 日志在不暴露内部运行 ID 的情况下呈现，取消、退役状态不明和失败回执不会发布结果。运行途中闸门关闭也会隐藏输出。Cordis 作用域销毁时会取消并等待活跃运行退役，然后释放原生传输。

运行 `node --import tsx --test apps/android/tool/model-ptc-caller-binding.test.mjs apps/android/tool/tool-isolated-ptc.test.mjs` 可使用原版 AgentLoop、Agent、Session 和 ToolRuntime，配合模拟原生传输检验条件注册、真实父调用与第一方回调、伪造输入与 owner、注册替换、取消、闸门变化、owner 关闭和结果隐藏。这些宿主测试不能证明 Android Binder 或 UID 隔离。[PTC 回调验收](acceptance-ptc-callback-device.zh.md)及[工作流进程死亡验收](native-workflow-process-death-device-acceptance.zh.md)仍需在真实设备上运行。更广的文件／网络能力、原版 `run_code` 行为和异步工作流执行必须分别实现和验收，才能宣称通用 PTC 已完成。
