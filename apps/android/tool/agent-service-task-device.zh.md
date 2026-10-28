---
kind: reference
title: 正式 AgentService 账号任务验收
---

# 正式 AgentService 账号任务验收

[English](agent-service-task-device.md) | 中文

## 摘要

这项验收检查已安装 App 能否在手机保持锁屏时，使用当前 DeepSeek 账号与默认模型完成一次后台请求并持久化结果。默认 echo 场景检查不调用工具的回复；显式选择的 `radio-linux` 场景检查一次未完成 Linux 调用跨越实测离线区间。两者均使用正式 AgentService 及其既有 home，并创建一个专用会话。Build 116 r33 于 5,051 毫秒完成 echo 检查；保留的 r32 超时及进程冻结已归因于设备 OEM 冻结器：它在 AMS 报告未冻结时冻结了 App。

## 目录

- [准入与账号使用](#admission-and-account-use)
- [显式启用无线网络与 Linux 场景](#radio-linux)
- [程序化调用与子 Agent Linux 场景](#programmatic)
- [完成与持久化](#completion-and-persistence)
- [显式检查系统完成通知](#completion-notice)
- [清理与屏幕保护](#cleanup-and-screen-protection)
- [Build 116 真机观察](#build-116-observations)
- [证据范围](#evidence-limits)

<a id="admission-and-account-use"></a>
## 准入与账号使用

[echo 设备适配器](acceptance-agent-service-task-device.mjs) 要求显式传入 `acceptRealAccountRequest: true`；[原生仪器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskAcceptanceInstrumentation.kt) 另行要求匹配的参数。`radio-linux` 的[恢复入口](agent-service-recovery-driver.zh.md#radio-linux)还要求明确同意修改无线网络。请求使用既有账号，可能消耗账号额度。设备必须已锁屏且不可交互，正式运行时在准入前必须报告没有运行、排队或等待中的任务、后台作业及包操作。

当前默认服务商必须是 `deepseek-account`，其模型必须在该账号的可用模型目录中恰好出现一次。凭据缺失或默认模型不可用时，不会改选其他模型。验收确保新会话确已创建，为其设置专用标题，再次检查默认模型，随后以 `selectModel: false` 提交。它不修改全局模型选择或账号设置。

每轮分别为用例、会话、请求及导出生成随机标识，并提交一条用户消息。echo 要求只回复唯一标记，禁止工具调用和文件读取；任何观测到的 `tool/*` 事件或助手工具调用块都会使其失败。radio 只允许下述调用。这些限制属于提示词及验收条件，不是沙箱：正式工具回调仍然可用，发现非预期工具尝试也无法撤销其影响。一次用户提交不代表只有一次服务商 HTTP 请求；两种场景都不能确定服务商 HTTP 请求的次数。

<a id="radio-linux"></a>
## 显式启用无线网络与 Linux 场景

`radio-linux` 要求真实账号模型恰好调用一次 `linux_exec`，参数只能包含 `command` 和 `timeoutMs: 120000`。命令必须与[固定 Python 脚本](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt)一致：测量单调时间，休眠 40 秒，再输出包含用例标记、其 SHA-256 和耗时毫秒数的 JSON。它不请求客体网络访问，也不读取或修改文件。模型随后必须只回复标记。

原生 `ready` 检查点要求已有持久 `tool/call` 事件、同一父任务仍在运行且调用尚未完成。该事件先于调度器准备和派发：就绪不能证明 Linux 客体或 Python 已经启动。每个检查点绑定用例、会话、Agent PID、运行代次、调用 ID、调用序号和命令摘要。[宿主校验器](agent-service-task-radio.mjs)拒绝身份变化、待执行工作缺失、网络能力未知或失去锁屏／不可交互状态。

[共享恢复驱动](agent-service-recovery-driver.zh.md)只在该检查点后关闭 Wi-Fi 和移动数据。它确认两项标志均关闭且没有非 VPN INTERNET 网络，再以宿主单调时钟记录至少 15 秒、至少两次观察；每次必须保持相同 Agent PID、自己的运行任务和未完成 Linux 调用。驱动恢复精确的原始标志并观察到底层互联网可用后，才允许原生任务结束。原生离线至恢复区间也必须达到 15 秒。这证明了待执行工作在离散采样中的连续性，不代表客体 CPU 在整个断网区间持续执行。

完成验收必须将原调用对应到唯一成功的 `tool/result`、退出码为零且确认客体退役的完成 Linux 回执，以及实时和已刷盘会话记录中的最终标记。客体 UID 必须不同于 App UID；输出标记和 SHA-256 必须匹配，实测等待须在 39,000 至 120,000 毫秒之间。取消、超时、输出截断、额外调用或清理时取消都会使验收失败。此场景不测试客体网络或被中断的模型 HTTP 流，也不能证明模型传输重试行为。[r34 真机记录](#radio-linux-r34)证明了本场景上述限定范围的结果。

<a id="programmatic"></a>
## 程序化调用与子 Agent Linux 场景

任务适配器还接受显式 `exercise: 'ptc'`、`'workflow'` 或 `'workflow-linux'`。每种场景都要求当前真实账号、一个专用父会话以及相同的外层屏幕保护和进程退役控制。[程序化证据校验器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceProgrammaticEvidence.kt)要求固定的父工具参数与结果、有序的回调或成员事件、已完成的父回复，以及一致的实时和持久记录。`ptc` 只允许一次经审核的 `list_agents` 回调。`workflow` 要求一个已完成的子会话，包含自己的标记且没有工具调用。父会话和已验证的子会话均通过各自原有管理入口归档；子会话使用 `workspace.archiveSession`，其回执包含整个归档集合。清理失败仍使验收失败。

`workflow-linux` 要求该子 Agent 调用一次 `linux_exec`，执行[固定的离线 Python 文件任务](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceChildLinuxEvidence.kt)。它仅在子会话 `/workspace` 下新建的临时目录内写入自己的测试输入，打包并读回 ZIP，校验内容、计算 SHA-256，然后删除临时目录。子回复和父工作流结果必须包含精确的子标记、摘要和字节数。子会话的独立导出必须包含匹配的 Linux 调用、原生结果及来源事件关联。验收要求执行完成、退出码为零、客体确认退役、客体 UID 不同于正式 App UID，没有超时、取消或截断，并确认临时文件已清理。`diskCommitted` 记录实际策略结果：只读子会话可以完成这项临时文件任务而不提交磁盘。本场景不导入手机文件，也不请求客体联网；账号模型流量仍会发生。定向宿主检查验证载体及证据规则，不认证真机子 Agent Linux 执行。

参数不匹配时仍返回 `PROGRAMMATIC_ARGUMENTS_CHANGED`，并附加固定字段诊断：`code` / `description` 或 `script` / `meta` / `meta.name` / `meta.description` 的存在状态、类型、UTF-8 字节数、SHA-256 与原始相等性。工作流 `script` 还须带有经审核的 `return await agent(<字符串>);` 包装与固定子提示词：解码后的前缀必须完全一致，尾部的子参数必须解析为经审核的取值。因此该字符串内部的 JSON 转义写法与尾部空白不能决定验收，而任何前缀、包装或解析后参数的改变仍会失败。诊断额外保留 `script` 记录，含包装、提示词与参数的摘要。未知字段名与原始值均不输出，额外字段仅计数；这些观察也不能撤销事件检查前已经派发的工具。

独立的 `runAgentServiceTaskDiagnostic` 适配器选择 `workflow-diagnose`、`diagnosticCaseId`、原来的 `workflow` 或 `workflow-linux` 场景，以及 `acceptRealAccountRequest: false`。它仅读取指定专用父会话及唯一记录的子会话，将实时历史与自己的导出比较，并核验原父请求和提示词。子会话归属还要求其导出头明确指向该父会话且 `origin: subagent`。成员记录缺失、归属冲突与子证据不可用均明确保留；这些结果都不授权清理，也不认证原任务。诊断不会请求会话 ensure、send、cancel 或 archive，仅释放自己的导出。既有 `workflow-cleanup` 仍是独立且仅适用于已完成工作流的模式。`parseAgentServiceTaskDiagnosticResult` 保留外层屏幕和进程退役责任。

r42 的 `workflow-linux` 尝试仍按先前的逐字节比较保留为失败。其只读 r43 诊断 `.cache/android/workflow-linux-r42-diagnostic-under-120-r43-20261028.json.result.json` 确认元数据相同且没有额外字段，但预期脚本为 1,311 字节，实际为 1,308 字节。`.cache/android/workflow-linux-r42-slash-variants.json` 在 128 个斜杠转义变体中仅有一个与实际 SHA-256 `5c22393b82ee9ee59c7e1abb1abb92c534cec313add8c4fcb7b314d33f56368b` 完全一致：三处嵌套 JSON 斜杠各少一个冗余反斜杠，两者解码后的子提示词相同。修订后的验收改为解码包装并解析子参数来接受这种等价，并为失败回合保留有界的提供方错误码；`.cache/android/device-v120-20261028/r49/archive-manifest.json` 保持正式 App 未变（SHA-256 `56316b0ad4215d5808e85d5bf6d993f105f8783b686c2f9311fe431df146385a`）与重建的 AndroidTest SHA-256 `fbe87fff10147b7d2b7620c686211849fe05215c59c454da7313216157ed98fc`，其宿主检查通过 135 项断言。首次真机尝试 `.cache/android/real-account-workflow-linux-120-r44-protected-20261028.json.result.json` 没有进入模型请求：它在 319,535 毫秒后以 `DEADLINE_EXCEEDED` 失败且提交数为零，只发出 81 毫秒与 319,477 毫秒两次进度脉冲，运行时最后一次观测停在 3,593 毫秒的 `starting-node`。在该阻塞期间的采样中，`/sys/fs/cgroup/apps/uid_10496/pid_<主进程>/cgroup.freeze` 与 `:agent` 组均读到 `1`，而 `dumpsys activity processes` 同时报告 `isFrozen=false`、两个进程处于前台或可感知 adj，且存活的 events 缓冲区中没有 `am_freeze` 记录。这一特征与 r32 记录的 OEM 冻结一致，并说明 AMS 并非施加者。设备电池策略将该 App 设为不受限制后，r45 至 r49 都在约 2.6 秒内就绪、未再被冻结、各提交一次，随后以 `SESSION_FAILED` 与提供方错误码 `TRANSPORT` 失败。原因是 App 侧网络代理已启用但没有可达的代理；关闭后 echo 场景 `.cache/android/real-account-echo-120-r52-protected-20261028.json.result.json` 以 105,510 毫秒通过一轮，`.cache/android/real-account-echo-120-r53-protected-20261028.json.result.json` 以 5,671 毫秒通过同一检查（r33 基线为 5,051 毫秒），因此首个长回合是冷启动而非持续延迟。随后的 `workflow-linux` 尝试 `.cache/android/real-account-workflow-linux-120-r51-protected-20261028.json.result.json` 提交一次后在 127,854 毫秒触达 120 秒回合上限并以 `DEADLINE_EXCEEDED` 失败；`.cache/android/real-account-workflow-linux-120-r54-protected-20261028.json.result.json` 已到达工具调用，但模型写出了另一段 1,379 字节程序，被包装检查以 `PROGRAMMATIC_ARGUMENTS_CHANGED` 拒绝。通过记录为 `.cache/android/real-account-workflow-linux-120-r55-protected-20261028.json.result.json`：一次提交在 33,178 毫秒内完成，父会话 26 个事件、历史 SHA-256 `6a453638ae556d43e5088a9f258d6facbe3c95f221b09ae27da833baa8c500f7`。经审核的包装与解析后的子参数被接受，父会话记录一次工作流运行 `c121929f-9d08-4d40-aae6-c058654b63cf`、一个已完成成员且 `requiresReview: false`，子会话 `e156e748-b52a-44e0-a614-ad10c60e7e0f` 记录一次 `linux_exec` 调用。该调用退出码为零，客体 UID 99,028 与 App UID 10,496 不同，确认退役，`diskCommitted: true`，载荷 59 字节、SHA-256 `95bdadd466258f15f4c447868bb2b0ee1c9ba4075a276887ad7884a5d85e7bae`，归档条目为 1 且确认临时清理。外层负责人记录 16 次双物理面板 Off 采样，并在非交互状态下恢复屏幕控制；App 与测试包均被强制停止且进程已观测消失。该 r43 诊断另记录一次工作流开始与零个成员记录（`no_member_record`），既不能证明没有创建子会话，也不构成归档子会话的许可。

<a id="completion-and-persistence"></a>
## 完成与持久化

验收在任务前、任务中和任务后要求正式 AgentService 的 PID 与运行代次不变、运行时已就绪，且 ActivityManager 报告该服务为前台服务。执行期间必须观测到自己的会话正在运行，并且新鲜的原生后台摘要中运行数大于零。前台服务状态不代表可见 Activity：验收不启动 Activity，也不额外获取 wake lock；App 既有的后台电源策略仍然适用。

[证据校验器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt) 要求恰好一条匹配所提交请求 ID 与提示词的用户消息、每个已记录请求头均使用选定账号模型、一条文本匹配标记且未中断的最终助手消息，以及一个已完成的首轮任务。推理块可以存在。echo 拒绝工具调用块；radio 另行校验此前唯一的工具调用与结果。收到的 `task.completed` 通知必须指向相同轮次和结束序号。仅有发送成功回执不足以通过。

验收将 `session.read` 与已刷盘的 `session.export.prepare` 结果比较，仅包含自己的会话，不包含后代。它只读取 App 导出缓存中属于本轮的规范 UUID 路径 ZIP，核对会话 ID，并要求其中只有一个不超过一 MiB 的 `session.v4.jsonl` 条目。选定的用户、请求、轮次及助手事件必须在实时记录和持久记录中一致。结果保留数量与摘要，不输出账号秘密或助手原文。

<a id="completion-notice"></a>
## 显式检查系统完成通知

echo 适配器与结果解析器接受显式 `requireCompletionNotice: true` 选项，并向原生仪器传入 `-e requireCompletionNotice true`。默认值为 false；普通 echo 通过不能认证通知投递。提交前，此选项检查 App 通知权限、通知开关及既有 `task-completed` 通道，不修改这些设置。

真实 `task.completed` 信号及匹配的持久最终回复出现后，验收最多等待八秒，要求 Android 活跃通知中恰好一条匹配本会话标签和通知 ID 3。它检查精确的合成标记、通道、私密展示、自动取消标志，以及内容 PendingIntent 的创建者包名和 UID 均属于本 App。报告只保留哈希与固定事实，不输出通知原文。它不读取跨进程 SharedPreferences，也不发送 PendingIntent；`notificationTapTested` 始终为 false，因此不验证点击通知或打开对应会话。

清理只取消本轮精确标签和 ID 的通知，并最多等待三秒确认其已消失；用户通知与偏好设置保持不动。成功要求 `cleanup.completionNoticeCancelled: true`，清理失败会使验收失败。[宿主适配器检查](acceptance-agent-service-task-device.test.mjs)覆盖显式准入及无效通知证据。[r35 真机记录](#completion-notice-r35)证明了本选项的投递；r33 与 r34 未检查活跃系统通知。独立的[回执崩溃验收](task-completion-device-acceptance.zh.md)覆盖另一条路径，仍单独保留。

<a id="cleanup-and-screen-protection"></a>
## 清理与屏幕保护

工作总预算为 300 秒，就绪等待上限为从入口起 120 秒，轮次等待上限为 120 秒。原生清理另有最多 60 秒预算，并以入口起 360 秒为上限；radio 适配器独立的 330 秒宿主截止时间可能更早到期。已提交任务尚未结束时，原生清理先等待 `session.ensure` 形成准入屏障，再仅取消自己的会话，并确认它没有运行、排队或等待中的工作。随后归档专用会话、仅释放自己的导出，并注销和解除 Messenger 连接。原生清理不清除数据、不停止服务，也不修改其他会话；radio 的宿主负责人另行恢复网络并使 App 与测试进程退役。

成功要求任务结束、会话归档、导出释放及连接解除均完成，且清理期间未请求取消；清理失败会使成功失效。失败保留有界的错误码、异常类型及上述固定字段指纹，不包含账号详情、模型文本或任意错误原文。回合失败时还会保留记录的提供方错误码与有效范围内的 HTTP 状态，该错误文本仅以字节长度和 SHA-256 表示。[主机检查](acceptance-agent-service-task-host.mjs) 编译原生仪器并执行证据辅助代码，包括原始会话导出格式，但不证明真实账号请求或真机通过。

原生的锁屏／不可交互观察及解析成功都不能证明物理面板状态或进程退役。外层设备负责人必须使用[屏幕保护](device-screen-protection.zh.md)，保留面板观察，关闭自己拥有的宿主进程，并确认设备进程退役后才能报告验收通过。echo 适配器明确将 `physicalPanelEvidence` 与 `processRetirement` 标为需要外层负责人提供。两种场景都不唤醒或解锁手机。echo 不修改无线网络；radio 的修改与恢复仅由[共享宿主清理所有者](agent-service-recovery-driver.zh.md)负责。

<a id="build-116-observations"></a>
## Build 116 真机观察

r33 结果位于 `.cache/android/account-task-116-r33-protected-20261028.json.result.json`，外层报告为去掉 `.result.json` 的同路径文件。归档包对记录在 `.cache/android/device-v116-20261028/r33/archive-manifest.json`：App SHA-256 为 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`，AndroidTest SHA-256 为 `b5086aff18d3fcebc02b64de02016627bbeda2e7152d5af04661bb6c55af4a21`。正式 App 与 [116 升级记录](upgrade-116-acceptance.zh.md)中的包相同。

真实当前默认 `deepseek-account` / `deepseek-flash` 在专用会话 `android-account-acceptance-97a23b00-607e-4dbc-b490-1bbdad59361d` 中完成了一条已提交用户消息，整项验收耗时 5,051 毫秒。唯一助手标记及完成轮次在实时与持久记录中匹配，工具调用为零，持久事件为 15 条；历史 SHA-256 为 `3f43f1b8b036079893f7fd8f43c3bcf28c652d3e2b4088ec3af8d80fcf9eb265`。任务结束、导出释放、会话归档及连接解除均成功，清理期间未请求取消。

AgentService 保持 PID 6299、相同运行代次及前台服务状态。任务期间观测到一个运行任务且正式服务持有 wake lock；任务前后均为空闲、运行数为零且未持有 wake lock。原生观察均为锁屏且不可交互。外层报告记录五次采样中两块物理面板均为 Off、宿主实际关闭及设备进程退役已确认。这些是本次短请求的离散状态，不能作为连续面板或长时间休眠证据。

此前 `.cache/android/account-task-116-r32-protected-20261028.json.result.json` 在 190,012 毫秒后以 `DEADLINE_EXCEEDED` 失败，提交数为零。`.cache/android/account-task-r32-scheduler-01.json` 在采集时读取到主进程 PID 28936 与 Agent PID 28956 的 `cgroup.freeze=1`，且 `cgroup.events` 含 `frozen 1`。该状态由设备 OEM 冻结器施加：2026-10-28 已安装的 Build 120 记录了 `OplusHansManager ... freeze uid: 10496 com.minnnng.dsh_android ... scene: |StrictMode-3|LcdOff`，当时 `AgentService` 为前台服务，而 AMS 报告 `isFrozen=false`，因此该状态从不属于 AMS。该冻结器忽略前台服务，不受 App 控制；`AgentService` 现会记录暂停区间并随失败一并报告。r33 成功以及新增的早期进度脉冲不能修复该冻结，迟到截止时间由暂停解释，而不是模型或工具过慢。

只读记录 `.cache/android/account-task-r33-power-policy.json` 显示 `RUN_ANY_IN_BACKGROUND: allow`、`RUN_IN_BACKGROUND` 无显式记录且默认模式为 `allow`，DSH 已在用户 device-idle 白名单中；`settingsChanged` 为 false。这些是观测到的策略配置，不能证明所有系统调度器或冻结器都会允许持续执行。

<a id="radio-linux-r34"></a>
### r34 活动 Linux 调用跨越断网

通过记录为 `.cache/android/radio-linux-116-r34-recovery-20261028.json`；配套屏幕报告将 `recovery` 替换为 `screen`。`.cache/android/device-v116-20261028/r34/archive-manifest.json` 中的 r34 归档清单保留上述相同 App 摘要，AndroidTest SHA-256 为 `ab9149a554af7ba6d0cdb4f0be5a60ebca34c4a795ca356bda550e58a3e844d5`。当前账号模型在 62,902 毫秒内完成一条用户提交、一次 Linux 调用和一个最终标记，共有 24 条持久事件。历史 SHA-256 为 `9c5a5d17c9552f7e49941b43bc76dfd2cb9bddf1a91c2deb50f620bd470df96f`。

宿主于 13,724.261 毫秒收到就绪；九次离线观察从 18,320.3411 至 33,554.017 毫秒，从首次离线采样完成起执行的驻留要求实测为 15,233.6717 毫秒。每次均保留 Agent PID 13213、相同运行代次及调用身份、自己的运行父任务和未完成 Linux 调用。独立的原生离线至恢复区间为 18,534 毫秒。两种时钟起点不同；就绪或这些离散待完成状态都不能确定 Python 何时开始执行。

最终回执记录客体 UID 99480、Python 等待 40,006 毫秒、退出码为零，以及 `diskCommitted: true`、`retirementConfirmed: true`；输出 SHA-256 为 `67ff8e8ac3df4dffcd6d440fb0cd34f07d33f2f25e7c0ff8452d25d43efd0b2e`。相同调用的结果及最终回复在实时和持久记录中一致。原生任务结束、会话归档、导出释放及断开连接均完成，清理未发起取消。Wi-Fi 和移动数据标志恢复为原始 `1` / `1`，外层所有者确认宿主关闭及设备进程退役。29 次屏幕采样均显示两块面板 Off，屏幕控制在不可交互状态下恢复。记录中的重试事件为零：本轮证明所观察的未完成 Linux 任务在恢复连接后完成，不证明被中断的模型 HTTP 重试、长期 Doze 存活，也不证明 r32 记录的 OEM 冻结已被消除。

<a id="completion-notice-r35"></a>
### r35 真实任务与系统完成通知

通过结果为 `.cache/android/account-notice-116-r35-protected-20261028.json.result.json`；配套屏幕报告省去 `.result.json`。`.cache/android/device-v116-20261028/r35/archive-manifest.json` 中的 r35 归档清单保留上文记录的未变更正式 App 摘要，AndroidTest SHA-256 为 `dc06f94ba4fc2861f8e861609e4d52350afb64127b208f5e36169eb2a2b6a926`。启用 `requireCompletionNotice: true` 后，当前 `deepseek-account` / `deepseek-flash` 在 6,753 毫秒内完成一条用户提交和一个最终标记，工具调用为零，持久事件为 15 条。历史 SHA-256 为 `205e1c6f00a7d49456264f366d1d0124be688813d60e7c4f6f5aa08ec944458b`。

恰好一条活跃通知匹配专用会话标签、ID 3、`task-completed` 通道及标记预览。私密展示、自动取消以及内容 PendingIntent 属于本 App 均获确认；清理确认该通知已取消，会话归档、导出释放及断开连接已完成。外层所有者记录六次采样中两块 OLED 面板均为 Off，并确认宿主与设备进程退役，随后在不可交互状态下恢复屏幕控制。没有发送 PendingIntent：本轮验证真实完成通知的投递与清理，不验证通知点击、会话跳转或崩溃后的回执恢复。它不能阻止 r32 记录的 OEM 冻结。

<a id="evidence-limits"></a>
## 证据范围

r33 结果证明了一次经正式服务使用真实账号完成的 echo 请求及其持久回复；r34 另行证明了一次未完成 Linux 调用在实测断网区间保持，并在恢复连接后完成；r35 证明了真实任务的系统完成通知及其清理。各轮均使用新专用会话，都不能证明通知点击、账号登录界面或头像显示、重新打开旧会话、令牌刷新、被中断的模型 HTTP 重试、服务死亡后恢复、长时间 Doze 运行，或 r32 记录的 OEM 冻结已被修复。[空闲服务恢复验收](agent-service-recovery-driver.zh.md) 与 [Build 116 升级记录](upgrade-116-acceptance.zh.md) 分别拥有各自观察，两者均不能替代这些账号任务结果。
