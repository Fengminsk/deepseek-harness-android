# 打包 Node 工具验收

[English](device-runtime-acceptance.md)

`NativeRuntimeToolsAcceptanceInstrumentation` 使用已打包的 Android Node 引擎、普通 `dsh --profile device-acceptance` 启动入口、生产 AgentLoop、ToolRuntime、Session 持久化、子 Agent／任务服务及原生 Binder owner。样例 profile 与脚本模型仅存在于 AndroidTest 资产中，产品运行时不注册这些样例。每次执行创建独立的 `noBackup/native-runtime-acceptance/<uuid>` home，与用户 profile、凭据、会话分开。回调通道调用生产工作流／PTC owner，但只代表有限的测试承载，不代表完整 `AgentService` 或 UI 启动路径。

使用 `-PdshAcceptanceBuildType=release -Ptarget-platform=android-arm64` 同时构建 App 和 AndroidTest，分别通过 `adb install -r` 安装；每次运行仪器测试前停止 App，保证嵌入式 Node 在新进程中启动。执行 `adb shell am instrument -w -r -e suite workflow com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation`；也可选择 `ptc` 或 `all`。通过必须同时满足 `INSTRUMENTATION_CODE: -1` 与结果中的 `passed: true`，任何子项 `unverified` 仍是验收缺口。保留的样例 home 只包含验收数据及运行时诊断。

工作流验收让模型形状的请求经过真实 ToolRuntime，验证原生计算及子 Agent 输出，通过 `job_kill` 取消已经进入模型执行的真实子任务，并将持久化 Session 的工作流开始／结束事件与原生恢复观察对应。子模型不使用凭据、不发外部网络请求。PTC 验收使用生产只读 SDK、真实本地样例文件、隔离 UID、回调、取消和 CPU 限制；公开网页抓取属于真实网络测试。SAF 用例只读取明确预置的验收文件并核对哈希；附件用例在专用 Session 中创建自己的 ZIP，不查看用户文档或既有会话附件。

`linux` 套件还要求构建中包含校验过的 Linux 样例。它在生产 App 工作区内建立独占的 `.device-acceptance-<uuid>` 子目录，验证 Linux 执行与持久化、文件导入／导出哈希、禁止覆盖发布和只读策略。DSH home 仍然独立。这些检查不代表 Python 或完整发行版镜像已验收。

`node apps/android/tool/check-device-runtime-profile.mjs` 只验证宿主启动：启动同一 profile，看到第一个生产原生准入请求即停止，不能证明真机执行。对应的完整设备检查通过前，产品能力开关保持关闭。

生产服务恢复使用另一条命令：安装匹配的 release 测试 APK 后，执行 `node apps/android/tool/acceptance-agent-service-recovery-device.mjs --serial <设备> --accept-network-toggle-and-lock`。它启动真实 `AgentService`，创建一个专用 Session，不调用模型；在手机锁屏、断网及恢复网络后核对相同的运行时 generation、Agent 进程和 Session 事件哈希。脚本临时关闭 Wi-Fi 和移动数据，在 `finally` 中恢复原开关及原亮屏／息屏状态；不改变 VPN 配置、不解锁锁屏。成功后归档专用 Session。通过只证明服务与持久化会话可用，不代表正在执行的模型请求存活或断网重试已验收。
