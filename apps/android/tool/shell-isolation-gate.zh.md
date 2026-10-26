# Android Shell 隔离门禁

[English](shell-isolation-gate.md) | 中文

旧版 `android_shell` 路径在每次获批后，通过 App UID 下的原生 supervisor 启动 `/system/bin/sh`。DSH 共用的 `AndroidShell` 执行器在明确启用时也由 App UID 执行。工作目录和原有文件工具策略都不能限制这两条 Shell 路径的文件或网络行为。

`runtime/shell-execution-policy.mjs` 现在在未设置进程模式时默认要求 `isolated-required`。通用隔离 Shell 执行器尚不可用，因此面向模型的 `android_shell` 工具不予注册，共用 `AndroidShell` 入口也会在启动进程前拒绝执行。未知取值同样拒绝。只有内部迁移或诊断进程明确设置 `DSH_ANDROID_SHELL_EXECUTION_MODE=app-uid-approved` 时，才能走旧的逐次批准 App UID Shell；定向旧路径测试自行设置此值。该进程内开关不是用户设置或安全沙箱。仍在 App UID Node 中运行的其他代码可以绕过这些入口直接调用 `fs`、`net` 或 `child_process`，环境变量无法防御这类代码。真正的操作系统隔离完成并验收之前，第 4 阶段的通用 Shell 功能默认暂不可用。

只把 `/system/bin/sh` 搬到 `isolatedProcess` 不能形成类似 Codex 的可写路径与网络策略：Node 宿主仍持有 App UID 和环境权限，而隔离 UID 又不能直接访问 App 私有工作目录。[Android Service 官方文档](https://developer.android.com/guide/topics/manifest/service-element#isolatedProcess)规定隔离服务没有自己的权限，并通过 Service API 通信。真正受限的 Shell 还需要 App 管理准入、文件描述符或 broker 授权、独立网络管控、持久批准与结果记录，并在真机验证命令不能绕过这些限制。在这之前，不能把 App UID Shell 或整个产品称为已有沙箱。主机回归命令：`node --test apps/android/tool/tool-android-shell.test.mjs apps/android/tool/shell-execution-policy.test.mjs apps/android/tool/shell-deadline.test.mjs`。

## 固定命令真机门槛

`IsolatedShellProbe` 仍是内部诊断，不接收调用方脚本、工作目录、文件描述符或网络目标。App 绑定独立的隔离 Service 实例，只接受本 App UID 与 UUID 请求，最多等待五秒。子进程清空环境，仅保留 `PATH=/system/bin`，从 `/` 启动，执行期限 1.5 秒，输出最多 256 字节；Service 在执行期间同步收集输出，避免管道填满后卡住期限。子 Shell 必须报告自身 UID，证明无法列出 App 私有目录，也无法在该目录创建 UUID 命名的新文件。Service 还以隔离 UID 直接尝试创建 Internet socket。App 核对 Binder 发送者 UID、报告 UID、精确子进程输出与标记文件不存在；如果隔离失败导致标记被创建，仅清理这一随机标记。取消和连接死亡默认拒绝。

现有仪器测试的 `phase=shell-probe` 必须在未 Root 的 Android 真机上运行。宿主单测或 APK 构建不能证明设备真的拒绝了子进程文件与网络操作。此探针不授权模型 Shell：它没有工作区写入 broker，也没有精确主机名网络 broker。现有原生 Shell supervisor 要求启动方先创建独立 session/进程组；Kotlin 探针不满足这一契约，因此通用 Shell 还需独立证明整个进程树都能退出，才可接收任意命令。[Android 隔离 Service](https://developer.android.com/guide/topics/manifest/service-element#isolatedProcess)、[Android 独立实例绑定](https://developer.android.com/reference/android/content/Context#bindIsolatedService(android.content.Intent,int,java.lang.String,java.util.concurrent.Executor,android.content.ServiceConnection))、[Codex 沙箱与审批](https://learn.chatgpt.com/docs/agent-approvals-security)。

纯证据判定可用宿主 JDK 独立运行，无需 Android 或 JUnit 依赖：在仓库根目录执行 `node apps/android/tool/acceptance-shell-probe.mjs`。
