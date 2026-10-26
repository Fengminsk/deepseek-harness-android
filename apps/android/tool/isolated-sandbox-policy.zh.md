# Android 隔离沙箱策略投影

[English](isolated-sandbox-policy.md) | 中文

原版 DSH 的 `sandboxPolicy.resolve()` 默认采用 `read-only`，并按 Session 工作区确定 `workspace-write` 的范围。Android 上由模型编写的 PTC 不能把 App UID 的 Node 进程当成该工作区沙箱。[`isolated-sandbox-policy.mjs`](../runtime/isolated-sandbox-policy.mjs)把**已经由 App 选定的能力范围**投影为更窄的 Android 策略；它本身不审批该范围、不准入运行，也不执行文件或网络操作。真正执行检查的仍是原生策略所有者、独立 UID 客体、文件代理和 HTTPS 代理。模型可见的 PTC 与工作流入口继续关闭。

`projectIsolatedSandboxPolicy({approvedScope, mode?, networkMode?}, parent?)` 默认文件只读、网络拒绝。App 如选择了读取路径，它们仍是精确的相对文件或目录范围；客体实际取得的也只是 App 签发的精确文件句柄。`workspace-write` 只允许写入 `approvedScope.writablePaths` 中落在可读范围内的路径。即使获得更宽的目录授权，写入路径中含 `.git`、`.agents`、`.codex` 或 `.aws` 的操作也会被拒绝。网络单独配置：`allow-listed-https` 只能使用 `approvedScope.exactHosts` 和对应网络调用额度。未设置网络模式或设为拒绝时，不能附带主机授权。本策略不提供 `danger-full-access`、无限制网络、任意路径、环境凭据、子进程或 Shell 权限。

决策对象只接受自身的数据属性。App 必须从可信的审批所有者取得 `approvedScope`，将其绑定到正确的 Session 和运行，并在原生准入前冻结授权。JavaScript 函数本身无法证明调用者获得了人的批准；即使向它传入伪造范围，也不会产生原生权限。`requireIsolatedSandboxPolicy` 仅接受本模块投影的策略，供模型草稿准备时使用。子级必须引用本模块产生的有效父策略，不能改变所有者、Session、工作区或版本，也只能收窄模式、相对路径、精确主机、额度和租期。原生准入以及每次文件和网络调用仍须独立检查相同的不可变范围。策略变更或运行中断后，授权应撤销；重试需要新的审批与运行身份。

宿主验证：`node --test apps/android/tool/isolated-sandbox-policy.test.mjs apps/android/tool/isolated-execution-contract.test.mjs`。测试覆盖默认拒绝、写入与网络的独立选择、伪造字段和访问器、不可变范围复制及子级权限收窄。它们不能证明 Android Binder 身份、设备文件系统约束、DNS／TLS 路由、用户审批或进程终止后的恢复。
