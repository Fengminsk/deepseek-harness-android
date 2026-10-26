# Android 隔离执行准入契约

中文 | [English](isolated-execution-contract.md)

[`isolated-execution-contract.mjs`](../runtime/isolated-execution-contract.mjs)及其[TypeScript 声明](../runtime/isolated-execution-contract.d.mts)为未来的 DSH PTC 或工作流提供方定义内部预检查。Android 配置和启动守卫仍禁用模型可见的 `ptc-runtime`、`workflow-ptc` 与 `tool-workflow` 条目。调用 `requireModelFacingIsolatedExecution()` 会得到 `ANDROID_PTC_UNAVAILABLE`。此契约不会注册工具、启动客体、批准请求，也不会把当前 V8 脚本引擎当成原版 Node PTC。

`prepareIsolatedExecution()` 接收符合 DSH 形状的脚本或工作流请求，并单独接收**由 App 选择的策略范围**。模型请求不能附带策略、工作区根路径或沙箱覆盖参数。运行和 Session ID 必须是规范 UUID；程序和 JSON 参数各自符合当前隔离 V8 的 64 KiB 传输上限，显式截止时间不超过五秒。工作流输入保留 `meta`、JSON `args` 以及显式的子任务总数和并发预算；这些字段会校验，但**不会执行**。隔离客体支持有界的异步代理调用，但原版工作流的 `agent`、`parallel`、`pipeline` 和子 Agent 执行尚未接通。

[`workflow-child-port.mjs`](../runtime/workflow-child-port.mjs) 在明确的 App 策略回调同意后，管理宿主内部的子级启动。该回调必须确认父级所有权、受支持的 Schema、收窄的子级授权、继承工具和持久准入。端口限制子级启动总量和并发数，在销毁前持有已发布的句柄，消纳未等待的结果拒绝，并在取消后清理迟到发布的子级再拒绝启动。当前未绑定启动适配器：Android 子 Agent 预设可能继承 App UID Shell，且隔离脚本的执行时限只有五秒，因此还不能通过此端口安全启动模型请求的工作流子级。`snapshotIsolatedJson()` 为未来的宿主传输复制并限制子级请求与结果数据，不授予副作用权限。

策略范围包含不透明的工作区 ID、App 选择的相对文件路径或以 `/` 结尾的目录范围、精确 HTTPS 主机、文件与网络调用预算和租期，初始授权为空。`normalizeExecutionScope(child, parent)` 拒绝变更所有者、Session、版本或工作区，也拒绝扩大路径、主机、预算或租期；父级目录范围可以收窄为后代文件或目录，但名称前缀相似的旁支不能继承权限。可写范围必须落在可读范围内。这可以在原生准入前筛掉扩权的子请求；[原生策略持有者](isolated-execution-policy-owner.zh.md)仍负责审批、授权执行和持久准入。客体仅得到 App 签发的精确文本文件不透明句柄，目录范围不允许它自行指定任意后代文件。JavaScript 中的路径校验不能替代原生的目录描述符文件代理或 DNS／TLS 代理。

`projectIsolatedReceipt()` 要求提供预期的运行 ID，而且只接受与之匹配的终态原生回执。`COMPLETED` 必须有有界 JSON 输出和已观察的客体 UID；取消、超时、工作进程死亡及不确定的退出都会扣留输出。`RETIRE_UNCONFIRMED` 与 `INTERRUPTED_UNCONFIRMED` 设置 `requiresReview`，调用方重试前应检查先前的副作用。这个投影仅供内部使用，不声称已经满足 PTC 的 `sandbox.enforcement`、Node 兼容性、日志或工作流结果契约。

[`isolated-execution-run.mjs`](../runtime/isolated-execution-run.mjs) 在此契约外增加单次运行的宿主生命周期。它在任何原生调用之前预处理请求，由**受信任的 App／Service 桥接器**只准入一次，仅在准入句柄回显预期运行 ID 后执行，读取原生终态回执，并在原生退出完成前扣留包括有效成功结果在内的全部输出。准入期间取消会阻止客体启动；执行或读取终态期间取消会等待原生取消请求。取消后的迟到成功、桥接异常、句柄或回执不匹配、退出失败都不能发布输出，也不会自动重试。`dispose()` 同样等待退出。[类型声明](../runtime/isolated-execution-run.d.mts)规定了桥接器五个方法的持久化和静默退出责任。这是宿主侧契约，**尚未注册为工具，也没有可工作的原生桥接器**。

原版 `tool-workflow` 在 Node PTC 客体中提供 `agent`、`parallel`、`pipeline`、`phase`、`log`，前台／后台作业归属及持久的子 Agent 生命周期。Android 运行端口只覆盖有界隔离运行从准入到退出的顺序；它没有实现这些客体钩子、Node API、后台作业或安全子级启动。今后连接原生桥接器，必须保留 App 策略不扩权、客体 UID 隔离、文件与网络代理以及模型开放前已持久化的终态记录。不能用 App UID Shell 替换桥接器，也不能把五秒 V8 客体当成原版 Node 工作流。

运行 `node --test apps/android/tool/isolated-execution-contract.test.mjs apps/android/tool/isolated-execution-run.test.mjs apps/android/tool/workflow-child-port.test.mjs` 可检查宿主输入、子权限收窄、运行和子级生命周期以及终态结果。这些宿主测试无法证明 Android UID 隔离、Binder 行为、网络路由、文件提供者、真实审批界面或进程终止恢复。只有在普通设备上通过 [PTC 验收门槛](ptc-execution-design.zh.md#向模型开放之前的验收门槛)后，才可考虑开放模型可见提供方。
