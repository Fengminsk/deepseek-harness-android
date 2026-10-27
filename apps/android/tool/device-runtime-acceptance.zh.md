# 打包 Node 工具验收

[English](device-runtime-acceptance.md)

`NativeRuntimeToolsAcceptanceInstrumentation` 使用已打包的 Android Node 引擎、普通 `dsh --profile device-acceptance` 启动入口、生产 AgentLoop、ToolRuntime、Session 持久化、子 Agent／任务服务及原生 Binder owner。样例 profile 与脚本模型仅存在于 AndroidTest 资产中，产品运行时不注册这些样例。标准执行创建独立的 `noBackup/native-runtime-acceptance/<uuid>` home，与用户 profile、凭据、会话分开。显式 PTC 恢复会复用自己准备的 home 和 Session，并保留原样例。回调通道调用生产工作流／PTC owner，但只代表有限的测试承载，不代表完整 `AgentService` 或 UI 启动路径。

`all` 只包含 `workflow`、`ptc` 和 `linux`。独立的 `ptc-process-death` 与 `ptc-saf` 需要各自准备样例，不会隐式加入 `all`；准备、清理和证据限制见 [PTC 生命周期验收](ptc-lifecycle-device.zh.md)。

使用 `-PdshAcceptanceBuildType=release -Ptarget-platform=android-arm64` 同时构建 App 和 AndroidTest，分别通过 `adb install -r` 安装；每次运行仪器测试前停止 App，保证嵌入式 Node 在新进程中启动。执行 `adb shell am instrument -w -r -e suite workflow com.minnnng.dsh_android.test/com.minnnng.dsh_android.NativeRuntimeToolsAcceptanceInstrumentation`；也可选择 `ptc`、`linux` 或 `all`。`INSTRUMENTATION_CODE: -1` 与 `passed: true` 表示至少执行了一项具名检查且没有失败，不表示完整验收通过。保留的样例 home 只包含验收数据及运行时诊断。

默认 `foregroundCarrier=activity` 要求整个样例执行期间保持验收页面位于前台。仅 release 验收构建包含 `RuntimeAcceptanceActivity`：它位于 `:agent`，不对外导出，也没有桌面入口。`AcceptanceForegroundLease` 要求设备已经解锁且屏幕可交互，不会主动唤醒或解锁。只有黑色窗口已绘制、获得焦点且截图所有像素的 RGB 均为零后，才准备运行时。页面隐藏系统栏，将窗口亮度降至最低，不改变系统设置；可见时保持亮屏，不启动 Flutter、`AgentService` 或产品 Node profile。失焦、系统栏露出或系统返回操作都会使样例失败。承载清理时关闭页面。此前台条件避免依赖缓存后台进程获得调度，但不能证明后台执行或锁屏存活。显式 `foregroundCarrier=service` 选择[无界面验收服务](acceptance-foreground-service.zh.md)，单独记录锁屏／显示状态，不作像素声明。

运行 `BlackScreenAcceptanceInstrumentation` 可在三十秒内对包含系统栏的合成画面采样六次，只记录尺寸和结果，不保存截图。声称某台手机的黑屏保护有效前，必须取得真机证据。黑色 Activity 与 Agent 同进程：终止该进程、强停软件或安装升级均会移除黑窗。主机的 [OLED 保护包装器](device-screen-protection.zh.md) 独立控制实际面板电源；它仅检查屏幕的探测不算上述切换的验收证据。正常清理会移除黑窗，因此测试结束后应让屏幕息屏。

启动 watchdog 的期限为 120 秒，到样例 Node 派发时结束。Activity 模式超时后先发布 `startup-timeout` 及当前启动阶段，再让独立守护线程读取调用栈；承载最多等待两秒获取调用栈，随后报告失败且不确认清理完成。服务模式发布超时后，由仪器线程清理原生 owner 并作最终报告。超时会阻止排队中的 worker 稍后派发 Node。整个进程被冻结时，watchdog 自身也无法执行，因此没有超时输出不代表启动仍有进展。这些启动诊断与下文的套件执行期限分开计算。

结果另行提供 `complete` 及 `coverage.required`、`coverage.passed`、`coverage.failed`、`coverage.unverified`、`coverage.issues`。检查名称均包含套件前缀。[报告汇总器](device-runtime-acceptance/report.mjs) 定义必需名称；即使套件省略某项，该项仍会列为未验证。只有所选套件的全部检查（`all` 则为全部套件）通过，且不存在未解决缺口、缺失证据、重复结果或未知名称／状态时，`complete` 才为 `true`。未知套件或零项已执行检查会同时返回 `passed: false` 与 `complete: false`。各套件原始报告仍保留。这一完整性仅针对样例声明的检查，不代表生产服务生命周期或整个 Android 交付完成。`node --test apps/android/tool/device-runtime-acceptance-report.test.mjs` 无需设备即可验证汇总逻辑。

[工作流样例](workflow-device-acceptance.zh.md) 经过真实 ToolRuntime 和十四次原生准入，执行十一项具名检查，包括结构化子任务、限制、失败与取消。使用客体工具的子任务由 Linux 套件单独检查。脚本模型不使用凭据、不发外部模型请求。PTC 验收通过生产已审查 SDK 验证本地读取、受保护的写入／编辑及附件落地，以及隔离 UID、回调、取消和 CPU 限制；公开网页抓取属于真实网络测试。SAF 用例要求保留验收目录的持久授权，并保持 `dsh-saf-acceptance.txt` 与记录的哈希一致。附件用例在专用 Session 中创建自己的文件，不查看用户文档或既有会话附件。

`linux` 套件要求使用 [Alpine 验收构建](tinyemu-build.zh.md#alpine-验收-apk)及匹配的 release AndroidTest APK。它在生产 App 工作区内建立独占的 `.device-acceptance-<uuid>` 子目录，验证 Linux 执行与持久化、文件导入／导出哈希、禁止覆盖发布和只读策略。实际工作子任务检查调用原生 `workflow` 工具，创建真实子 Agent，再由脚本模型依次发出 `linux_import`、`linux_exec`、`linux_export` 调用。实际执行使用原厂 ToolRuntime、原厂能力授权、NativeLinuxVm 及 Android Binder owner。断言核对父子身份、继承注册、原生完成／退役、导出文件内容与哈希、已落盘的子 Session 工具结果与 Linux 回执，以及原生工作流已退役的子任务记录。专用验收 home 保留 Session 证据。这一项覆盖可写子任务成功路径，不代表子任务撤权或冷恢复已验收。

`production-python-stdlib-file-analysis` 通过生产 `linux_exec` 工具在 Alpine 内执行 [Python 样例](device-runtime-acceptance/python-analysis.py)。它创建三个小型 UTF-8 文件及 JSON 元数据，写入并读回 deflate 压缩 ZIP，提交并重开 SQLite 检查完整性和分类字节汇总，计算 SHA-256，再启动第二个 Python 进程独立读取 ZIP。它还创建开启主机名／证书验证并装载信任锚的 SSL 上下文，但不发起 TLS 连接。Node 用独立计算的文件、大小和哈希核对输出，同时要求 Linux／RISC-V 身份及正常的隔离 UID 完成／退役回执。AndroidTest 资产目录包含 `python-analysis.py` 及其 `.mjs` 辅助模块，仪器测试将两者复制进样例 home。`node --test apps/android/tool/device-runtime-acceptance-python.test.mjs` 使用宿主 Python 执行同一脚本，并验证错误输入失败及输出校验；这只验证样例脚本，不是 Android 证据。覆盖范围限于已交付标准库操作，不包括 pandas、NumPy、pip 或其他第三方包。客体网络与导入过程中的进程死亡恢复仍是具名未验证项。

工作流与 Linux 套件在一次执行中共用一个回调／预设 owner，`all` 也如此，并在报告成功前关闭它。建议分套运行，便于定位失败。PTC 承载等待上限为 360 秒，包含一项 120 秒 PTC→Linux 检查。工作流允许十四次原生准入，每次保留既有 120 秒限制和 30 秒退役余量，再加 120 秒承载余量，总计 2,220 秒。Linux 按十一次客体启动使用相同余量，总计 1,770 秒。`all` 总计 4,350 秒。这些是有限的测试承载等待时间，不是预计耗时，也不延长产品限制；子工作流仍受生产 120 秒总期限约束。承载超时按失败报告，不能据此判定尚未返回的检查是否完成。

`node apps/android/tool/check-device-runtime-profile.mjs` 只验证宿主启动：启动同一 profile，看到第一个生产原生准入请求即停止，不能证明真机执行。对应的完整设备检查通过前，产品能力开关保持关闭。

生产服务恢复使用另一条命令：安装匹配的 release 测试 APK 后，执行 `node apps/android/tool/acceptance-agent-service-recovery-device.mjs --serial <设备> --accept-network-toggle-and-lock`。它启动真实 `AgentService`，创建一个专用 Session，不调用模型；在手机锁屏、断网及恢复网络后核对相同的运行时 generation、Agent 进程和 Session 事件哈希。脚本临时关闭 Wi-Fi 和移动数据，在 `finally` 中恢复原开关及原亮屏／息屏状态；不改变 VPN 配置、不解锁锁屏。成功后归档专用 Session。通过只证明服务与持久化会话可用，不代表正在执行的模型请求存活或断网重试已验收。
