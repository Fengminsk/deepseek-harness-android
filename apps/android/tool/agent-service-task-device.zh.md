---
kind: reference
title: 正式 AgentService 账号任务验收
---

# 正式 AgentService 账号任务验收

[English](agent-service-task-device.md) | 中文

## 摘要

这项验收检查已安装 App 能否在手机保持锁屏时，使用当前 DeepSeek 账号与默认模型完成一次后台请求并持久化结果。它使用正式 AgentService 及其既有 home，创建一个专用会话，核对真实的助手回复。Build 116 r33 于 5,051 毫秒完成此项检查；保留的 r32 超时及进程冻结观察仍未解决。

## 目录

- [准入与账号使用](#admission-and-account-use)
- [完成与持久化](#completion-and-persistence)
- [清理与屏幕保护](#cleanup-and-screen-protection)
- [Build 116 真机观察](#build-116-observations)
- [证据范围](#evidence-limits)

<a id="admission-and-account-use"></a>
## 准入与账号使用

[设备适配器](acceptance-agent-service-task-device.mjs) 要求显式传入 `acceptRealAccountRequest: true`；[原生仪器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskAcceptanceInstrumentation.kt) 另行要求匹配的参数。请求使用既有账号，可能消耗账号额度。设备必须已锁屏且不可交互，正式运行时在准入前必须报告没有运行、排队或等待中的任务、后台作业及包操作。

当前默认服务商必须是 `deepseek-account`，其模型必须在该账号的可用模型目录中恰好出现一次。凭据缺失或默认模型不可用时，不会改选其他模型。验收确保新会话确已创建，为其设置专用标题，再次检查默认模型，随后以 `selectModel: false` 提交。它不修改全局模型选择或账号设置。

每轮分别为用例、会话、请求及导出生成随机标识。它提交一条用户消息，要求只回复唯一标记，并禁止工具调用和文件读取。这项限制属于提示词及验收条件，不是沙箱：正式工具回调仍然可用，发现工具尝试也无法撤销其影响。任何观测到的 `tool/*` 事件或助手工具调用块都会使验收失败。一次用户提交不代表只有一次服务商 HTTP 请求；本验收不统计重试或服务商其他流量。

<a id="completion-and-persistence"></a>
## 完成与持久化

验收在任务前、任务中和任务后要求正式 AgentService 的 PID 与运行代次不变、运行时已就绪，且 ActivityManager 报告该服务为前台服务。执行期间必须观测到自己的会话正在运行，并且新鲜的原生后台摘要中运行数大于零。前台服务状态不代表可见 Activity：验收不启动 Activity，也不额外获取 wake lock；App 既有的后台电源策略仍然适用。

[证据校验器](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/AgentServiceTaskEvidence.kt) 要求恰好一条匹配所提交请求 ID 与提示词的用户消息、每个已记录请求头均使用选定账号模型、一条文本匹配标记且未中断的助手消息，以及一个已完成的首轮任务。推理块可以存在，工具调用块会被拒绝。收到的 `task.completed` 通知必须指向相同轮次和结束序号。仅有发送成功回执不足以通过。

验收将 `session.read` 与已刷盘的 `session.export.prepare` 结果比较，仅包含自己的会话，不包含后代。它只读取 App 导出缓存中属于本轮的规范 UUID 路径 ZIP，核对会话 ID，并要求其中只有一个不超过一 MiB 的 `session.v4.jsonl` 条目。选定的用户、请求、轮次及助手事件必须在实时记录和持久记录中一致。结果保留数量与摘要，不输出账号秘密或助手原文。

<a id="cleanup-and-screen-protection"></a>
## 清理与屏幕保护

工作总预算为 300 秒，就绪等待上限为从入口起 120 秒，轮次等待上限为 120 秒。清理另有最多 60 秒的预算。已提交任务尚未结束时，清理先等待 `session.ensure` 形成准入屏障，再仅取消自己的会话，并确认它没有运行、排队或等待中的工作。随后归档专用会话、仅释放自己的导出，并注销和解除 Messenger 连接。它不清除数据、不停止服务，也不修改其他会话。

成功要求任务结束、会话归档、导出释放及连接解除均完成，且清理期间未请求取消；清理失败会使成功失效。失败仅保留有界的错误码与异常类型，不包含账号详情、模型文本或任意错误原文。[主机检查](acceptance-agent-service-task-host.mjs) 编译原生仪器并执行证据辅助代码，包括原始会话导出格式，但不证明真实账号请求或真机通过。

原生的锁屏／不可交互观察及解析成功都不能证明物理面板状态或进程退役。外层设备负责人必须使用[屏幕保护](device-screen-protection.zh.md)，保留面板观察，关闭自己拥有的宿主进程，并确认设备进程退役后才能报告验收通过。适配器明确将 `physicalPanelEvidence` 与 `processRetirement` 标为需要外层负责人提供。本验收不包含唤醒、解锁或无线网络修改操作。

<a id="build-116-observations"></a>
## Build 116 真机观察

r33 结果位于 `.cache/android/account-task-116-r33-protected-20261028.json.result.json`，外层报告为去掉 `.result.json` 的同路径文件。归档包对记录在 `.cache/android/device-v116-20261028/r33/archive-manifest.json`：App SHA-256 为 `5cd11e06ab70a170235971f7a0140c982db992acf2c3c368066752e7089c7b41`，AndroidTest SHA-256 为 `b5086aff18d3fcebc02b64de02016627bbeda2e7152d5af04661bb6c55af4a21`。正式 App 与 [116 升级记录](upgrade-116-acceptance.zh.md)中的包相同。

真实当前默认 `deepseek-account` / `deepseek-flash` 在专用会话 `android-account-acceptance-97a23b00-607e-4dbc-b490-1bbdad59361d` 中完成了一条已提交用户消息，整项验收耗时 5,051 毫秒。唯一助手标记及完成轮次在实时与持久记录中匹配，工具调用为零，持久事件为 15 条；历史 SHA-256 为 `3f43f1b8b036079893f7fd8f43c3bcf28c652d3e2b4088ec3af8d80fcf9eb265`。任务结束、导出释放、会话归档及连接解除均成功，清理期间未请求取消。

AgentService 保持 PID 6299、相同运行代次及前台服务状态。任务期间观测到一个运行任务且正式服务持有 wake lock；任务前后均为空闲、运行数为零且未持有 wake lock。原生观察均为锁屏且不可交互。外层报告记录五次采样中两块物理面板均为 Off、宿主实际关闭及设备进程退役已确认。这些是本次短请求的离散状态，不能作为连续面板或长时间休眠证据。

此前 `.cache/android/account-task-116-r32-protected-20261028.json.result.json` 在 190,012 毫秒后以 `DEADLINE_EXCEEDED` 失败，提交数为零。`.cache/android/account-task-r32-scheduler-01.json` 在采集时读取到主进程 PID 28936 与 Agent PID 28956 的 `cgroup.freeze=1`，且 `cgroup.events` 含 `frozen 1`。施加冻结的主体未知。r33 成功以及新增的早期进度脉冲不能证明该冻结已被修复，也不能解释 r32 超时。

只读记录 `.cache/android/account-task-r33-power-policy.json` 显示 `RUN_ANY_IN_BACKGROUND: allow`、`RUN_IN_BACKGROUND` 无显式记录且默认模式为 `allow`，DSH 已在用户 device-idle 白名单中；`settingsChanged` 为 false。这些是观测到的策略配置，不能证明所有系统调度器或冻结器都会允许持续执行。

<a id="evidence-limits"></a>
## 证据范围

r33 结果证明了一次经正式服务使用真实账号完成的请求，以及其在新专用会话中的持久回复；不能证明账号登录界面或头像显示、重新打开旧会话、令牌刷新、活动请求断网存活、服务死亡后恢复或长时间 Doze 运行。[空闲服务恢复验收](agent-service-recovery-driver.zh.md) 与 [Build 116 升级记录](upgrade-116-acceptance.zh.md) 分别拥有各自观察，两者均不能替代这项账号任务结果。
