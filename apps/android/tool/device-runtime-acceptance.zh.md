# 打包 Node 工具验收

[English](device-runtime-acceptance.md)

`NativeRuntimeToolsAcceptanceInstrumentation` 使用已打包的 Android Node 引擎、普通 `dsh --profile device-acceptance` 启动入口、生产 AgentLoop、ToolRuntime、Session 持久化、子 Agent／任务服务及原生 Binder owner。样例 profile 与脚本模型仅存在于 AndroidTest 资产中，产品运行时不注册这些样例。每次执行创建独立的 `noBackup/native-runtime-acceptance/<uuid>` home，与用户 profile、凭据、会话分开。回调通道调用生产工作流／PTC owner，但只代表有限的测试承载，不代表完整 `AgentService` 或 UI 启动路径。

使用 `-PdshAcceptanceBuildType=release -Ptarget-platform=android-arm64` 同时构建 App 和 AndroidTest，分别通过 `adb install -r` 安装；每次运行仪器测试前停止 App，保证嵌入式 Node 在新进程中启动。执行 `adb shell am instrument -w -r -e suite workflow com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation`；也可选择 `ptc`、`linux` 或 `all`。`INSTRUMENTATION_CODE: -1` 与 `passed: true` 表示至少执行了一项具名检查且没有失败，不表示完整验收通过。保留的样例 home 只包含验收数据及运行时诊断。

结果另行提供 `complete` 及 `coverage.required`、`coverage.passed`、`coverage.failed`、`coverage.unverified`、`coverage.issues`。检查名称均包含套件前缀。[报告汇总器](device-runtime-acceptance/report.mjs) 定义必需名称；即使套件省略某项，该项仍会列为未验证。只有所选套件的全部检查（`all` 则为全部套件）通过，且不存在未解决缺口、缺失证据、重复结果或未知名称／状态时，`complete` 才为 `true`。未知套件或零项已执行检查会同时返回 `passed: false` 与 `complete: false`。各套件原始报告仍保留。这一完整性仅针对样例声明的检查，不代表生产服务生命周期或整个 Android 交付完成。`node --test apps/android/tool/device-runtime-acceptance-report.test.mjs` 无需设备即可验证汇总逻辑。

工作流验收让模型形状的请求经过真实 ToolRuntime，验证原生计算及子 Agent 输出，通过 `job_kill` 取消已经进入模型执行的真实子任务，并将持久化 Session 的工作流开始／结束事件与原生恢复观察对应。这三项特意使用没有工具的子 Agent；实际工作的子 Agent 由 Linux 套件检查。脚本模型不使用凭据、不发外部模型请求。PTC 验收通过生产已审查 SDK 验证本地读取、受保护的写入／编辑及附件落地，以及隔离 UID、回调、取消和 CPU 限制；公开网页抓取属于真实网络测试。SAF 用例要求保留验收目录的持久授权，并保持 `dsh-saf-acceptance.txt` 与记录的哈希一致。附件用例在专用 Session 中创建自己的文件，不查看用户文档或既有会话附件。

`linux` 套件要求使用 [Alpine 验收构建](tinyemu-build.zh.md#alpine-验收-apk)及匹配的 release AndroidTest APK。它在生产 App 工作区内建立独占的 `.device-acceptance-<uuid>` 子目录，验证 Linux 执行与持久化、文件导入／导出哈希、禁止覆盖发布和只读策略。第五项调用原生 `workflow` 工具，创建真实子 Agent，再由脚本模型依次发出 `linux_import`、`linux_exec`、`linux_export` 调用。实际执行使用原厂 ToolRuntime、原厂能力授权、NativeLinuxVm 及 Android Binder owner。断言核对父子身份、继承注册、原生完成／退役、导出文件内容与哈希、已落盘的子 Session 工具结果与 Linux 回执，以及原生工作流已退役的子任务记录。专用验收 home 保留 Session 证据。这一项覆盖可写子任务成功路径，不代表子任务撤权、冷恢复、Python 包、客体网络或导入过程中的进程死亡恢复已验收。

工作流与 Linux 套件在一次执行中共用一个回调／预设 owner，`all` 也如此，并在报告成功前关闭它。建议分套运行，便于定位失败。工作流与 PTC 承载等待上限仍各为 240 秒。Linux 按十次串行客体启动计算：父任务七次、子任务三次，每次保留既有 120 秒命令限制与 30 秒退役余量，再加 120 秒承载余量，总计 1,620 秒。`all` 再加两个 240 秒套件余量，总计 2,100 秒。这些是有限的测试承载等待时间，不是预计耗时，也不延长产品限制；子工作流仍受生产 120 秒总期限约束。承载超时按失败报告，不能据此判定尚未返回的检查是否完成。

`node apps/android/tool/check-device-runtime-profile.mjs` 只验证宿主启动：启动同一 profile，看到第一个生产原生准入请求即停止，不能证明真机执行。对应的完整设备检查通过前，产品能力开关保持关闭。

生产服务恢复使用另一条命令：安装匹配的 release 测试 APK 后，执行 `node apps/android/tool/acceptance-agent-service-recovery-device.mjs --serial <设备> --accept-network-toggle-and-lock`。它启动真实 `AgentService`，创建一个专用 Session，不调用模型；在手机锁屏、断网及恢复网络后核对相同的运行时 generation、Agent 进程和 Session 事件哈希。脚本临时关闭 Wi-Fi 和移动数据，在 `finally` 中恢复原开关及原亮屏／息屏状态；不改变 VPN 配置、不解锁锁屏。成功后归档专用 Session。通过只证明服务与持久化会话可用，不代表正在执行的模型请求存活或断网重试已验收。
