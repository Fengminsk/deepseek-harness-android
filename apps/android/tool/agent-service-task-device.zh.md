---
kind: reference
title: 正式 AgentService 账号任务验收
---

# 正式 AgentService 账号任务验收

[English](agent-service-task-device.md) | 中文

## 摘要

这项验收检查已安装 App 能否在手机保持锁屏时，使用当前 DeepSeek 账号与默认模型完成一次后台请求并持久化结果。默认 echo 场景检查不调用工具的回复；显式选择的 `radio-linux` 场景检查一次未完成 Linux 调用跨越实测离线区间。两者均使用正式 AgentService 及其既有 home，并创建一个专用会话。Build 116 r33 于 5,051 毫秒完成 echo 检查；保留的 r32 超时及进程冻结观察仍未解决。

## 目录

- [准入与账号使用](#admission-and-account-use)
- [显式启用无线网络与 Linux 场景](#radio-linux)
- [完成与持久化](#completion-and-persistence)
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

<a id="completion-and-persistence"></a>
## 完成与持久化

验收在任务前、任务中和任务后要求正式 AgentService 的 PID 与运行代次不变、运行时已就绪，且 ActivityManager 报告该服务为前台服务。执行期间必须观测到自己的会话正在运行，并且新鲜的原生后台摘要中运行数大于零。前台服务状态不代表可见 Activity：验收不启动 Activity，也不额外获取 wake lock；App 既有的后台电源策略仍然适用。

[证据校验器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt) 要求恰好一条匹配所提交请求 ID 与提示词的用户消息、每个已记录请求头均使用选定账号模型、一条文本匹配标记且未中断的最终助手消息，以及一个已完成的首轮任务。推理块可以存在。echo 拒绝工具调用块；radio 另行校验此前唯一的工具调用与结果。收到的 `task.completed` 通知必须指向相同轮次和结束序号。仅有发送成功回执不足以通过。

验收将 `session.read` 与已刷盘的 `session.export.prepare` 结果比较，仅包含自己的会话，不包含后代。它只读取 App 导出缓存中属于本轮的规范 UUID 路径 ZIP，核对会话 ID，并要求其中只有一个不超过一 MiB 的 `session.v4.jsonl` 条目。选定的用户、请求、轮次及助手事件必须在实时记录和持久记录中一致。结果保留数量与摘要，不输出账号秘密或助手原文。

<a id="cleanup-and-screen-protection"></a>
## 清理与屏幕保护

工作总预算为 300 秒，就绪等待上限为从入口起 120 秒，轮次等待上限为 120 秒。原生清理另有最多 60 秒预算，并以入口起 360 秒为上限；radio 适配器独立的 330 秒宿主截止时间可能更早到期。已提交任务尚未结束时，原生清理先等待 `session.ensure` 形成准入屏障，再仅取消自己的会话，并确认它没有运行、排队或等待中的工作。随后归档专用会话、仅释放自己的导出，并注销和解除 Messenger 连接。原生清理不清除数据、不停止服务，也不修改其他会话；radio 的宿主负责人另行恢复网络并使 App 与测试进程退役。

成功要求任务结束、会话归档、导出释放及连接解除均完成，且清理期间未请求取消；清理失败会使成功失效。失败仅保留有界的错误码与异常类型，不包含账号详情、模型文本或任意错误原文。[主机检查](acceptance-agent-service-task-host.mjs) 编译原生仪器并执行证据辅助代码，包括原始会话导出格式，但不证明真实账号请求或真机通过。

原生的锁屏／不可交互观察及解析成功都不能证明物理面板状态或进程退役。外层设备负责人必须使用[屏幕保护](device-screen-protection.zh.md)，保留面板观察，关闭自己拥有的宿主进程，并确认设备进程退役后才能报告验收通过。echo 适配器明确将 `physicalPanelEvidence` 与 `processRetirement` 标为需要外层负责人提供。两种场景都不唤醒或解锁手机。echo 不修改无线网络；radio 的修改与恢复仅由[共享宿主清理所有者](agent-service-recovery-driver.zh.md)负责。

<a id="build-116-observations"></a>
## Build 116 真机观察

r33 结果位于 `.cache/android/account-task-116-r33-protected-20261028.json.result.json`，外层报告为去掉 `.result.json` 的同路径文件。归档包对记录在 `.cache/android/device-v116-20261028/r33/archive-manifest.json`：App SHA-256 为 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`，AndroidTest SHA-256 为 `b5086aff18d3fcebc02b64de02016627bbeda2e7152d5af04661bb6c55af4a21`。正式 App 与 [116 升级记录](upgrade-116-acceptance.zh.md)中的包相同。

真实当前默认 `deepseek-account` / `deepseek-flash` 在专用会话 `android-account-acceptance-97a23b00-607e-4dbc-b490-1bbdad59361d` 中完成了一条已提交用户消息，整项验收耗时 5,051 毫秒。唯一助手标记及完成轮次在实时与持久记录中匹配，工具调用为零，持久事件为 15 条；历史 SHA-256 为 `3f43f1b8b036079893f7fd8f43c3bcf28c652d3e2b4088ec3af8d80fcf9eb265`。任务结束、导出释放、会话归档及连接解除均成功，清理期间未请求取消。

AgentService 保持 PID 6299、相同运行代次及前台服务状态。任务期间观测到一个运行任务且正式服务持有 wake lock；任务前后均为空闲、运行数为零且未持有 wake lock。原生观察均为锁屏且不可交互。外层报告记录五次采样中两块物理面板均为 Off、宿主实际关闭及设备进程退役已确认。这些是本次短请求的离散状态，不能作为连续面板或长时间休眠证据。

此前 `.cache/android/account-task-116-r32-protected-20261028.json.result.json` 在 190,012 毫秒后以 `DEADLINE_EXCEEDED` 失败，提交数为零。`.cache/android/account-task-r32-scheduler-01.json` 在采集时读取到主进程 PID 28936 与 Agent PID 28956 的 `cgroup.freeze=1`，且 `cgroup.events` 含 `frozen 1`。施加冻结的主体未知。r33 成功以及新增的早期进度脉冲不能证明该冻结已被修复，也不能解释 r32 超时。

只读记录 `.cache/android/account-task-r33-power-policy.json` 显示 `RUN_ANY_IN_BACKGROUND: allow`、`RUN_IN_BACKGROUND` 无显式记录且默认模式为 `allow`，DSH 已在用户 device-idle 白名单中；`settingsChanged` 为 false。这些是观测到的策略配置，不能证明所有系统调度器或冻结器都会允许持续执行。

<a id="radio-linux-r34"></a>
### r34 活动 Linux 调用跨越断网

通过记录为 `.cache/android/radio-linux-116-r34-recovery-20261028.json`；配套屏幕报告将 `recovery` 替换为 `screen`。`.cache/android/device-v116-20261028/r34/archive-manifest.json` 中的 r34 归档清单保留上述相同 App 摘要，AndroidTest SHA-256 为 `ab9149a554af7ba6d0cdb4f0be5a60ebca34c4a795ca356bda550e58a3e844d5`。当前账号模型在 62,902 毫秒内完成一条用户提交、一次 Linux 调用和一个最终标记，共有 24 条持久事件。历史 SHA-256 为 `9c5a5d17c9552f7e49941b43bc76dfd2cb9bddf1a91c2deb50f620bd470df96f`。

宿主于 13,724.261 毫秒收到就绪；九次离线观察从 18,320.3411 至 33,554.017 毫秒，从首次离线采样完成起执行的驻留要求实测为 15,233.6717 毫秒。每次均保留 Agent PID 13213、相同运行代次及调用身份、自己的运行父任务和未完成 Linux 调用。独立的原生离线至恢复区间为 18,534 毫秒。两种时钟起点不同；就绪或这些离散待完成状态都不能确定 Python 何时开始执行。

最终回执记录客体 UID 99480、Python 等待 40,006 毫秒、退出码为零，以及 `diskCommitted: true`、`retirementConfirmed: true`；输出 SHA-256 为 `67ff8e8ac3df4dffcd6d440fb0cd34f07d33f2f25e7c0ff8452d25d43efd0b2e`。相同调用的结果及最终回复在实时和持久记录中一致。原生任务结束、会话归档、导出释放及断开连接均完成，清理未发起取消。Wi-Fi 和移动数据标志恢复为原始 `1` / `1`，外层所有者确认宿主关闭及设备进程退役。29 次屏幕采样均显示两块面板 Off，屏幕控制在不可交互状态下恢复。记录中的重试事件为零：本轮证明所观察的未完成 Linux 任务在恢复连接后完成，不证明被中断的模型 HTTP 重试、长期 Doze 存活或 r32 冻结问题已修复。

<a id="evidence-limits"></a>
## 证据范围

r33 结果证明了一次经正式服务使用真实账号完成的 echo 请求及其持久回复；r34 另行证明了一次未完成 Linux 调用在实测断网区间保持，并在恢复连接后完成。两者均使用新专用会话，都不能证明账号登录界面或头像显示、重新打开旧会话、令牌刷新、被中断的模型 HTTP 重试、服务死亡后恢复、长时间 Doze 运行，或 r32 冻结的原因及其已解决。[空闲服务恢复验收](agent-service-recovery-driver.zh.md) 与 [Build 116 升级记录](upgrade-116-acceptance.zh.md) 分别拥有各自观察，两者均不能替代这些账号任务结果。
