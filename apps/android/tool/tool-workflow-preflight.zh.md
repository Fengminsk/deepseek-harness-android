# Android 模型工作流预检

[English](tool-workflow-preflight.md) | 中文

[`tool-workflow-preflight.mjs`](../runtime/tool-workflow-preflight.mjs) 中的 `prepareModelWorkflow` 将原版 `workflow` 工具的参数形状（`script`、`meta`、可选 JSON `args`）复制为有界且由宿主持有的请求。Session、随机运行 ID、已签发沙箱策略、时限和子任务预算由 App 提供；模型参数不能指定这些字段。预检只解析纯 JavaScript 异步函数体，不执行代码；TypeScript、错误语法以及尚无持久任务持有者的后台执行都会被拒绝。目前仅接受无文件授权、只读且禁止联网的策略。原生运行失败或结果不确定时，不向模型返回输出值。

**这不会注册模型工具。** `runModelWorkflow` 和 `modelAdmission.run()` 仍拒绝执行。原版 [`tool-workflow`](../../../packages/workflow/tool-workflow/src/index.ts) 执行带有 `agent`、`parallel`、`pipeline`、进度、取消以及可选后台任务的 JavaScript 脚本。Android 已有 App 私有的原生工作流执行器，包含有界的客体钩子、受限子 Agent 后端，以及写入原版父会话事件的运行与成员记录。经过审查的准入票据现可经明确的 App 私有 `executePrivate()` 路径交给该执行器。票据绑定实际存活的 Agent、ToolRuntime 注册身份和 Session，并在原生准入前消耗；即使准入失败也不能重放。取消、工具定义替换及持有者销毁都会撤销票据。执行器预算更窄，私有客体期限最长 120 秒；普通隔离脚本仍以五秒为上限。此私有路径不是面向模型的工具。

后续仍需在私有执行器支持实用的推理时长、持久后台持有及未完成运行记录的冷启动核对后，再把第一方模型工具绑定到这条已审查调用链。通用 Node/TypeScript PTC 还需要独立的 Android 受限执行器；V8 工作流 DSL 的能力更窄。开放模型工具前，还应在 Android 设备验证子级隔离、进度、取消、进程终止及升级行为。

主机检查：`node --test apps/android/tool/tool-workflow-preflight.test.mjs` 及 `node --import tsx --test apps/android/tool/model-workflow-admission.test.mjs`。
