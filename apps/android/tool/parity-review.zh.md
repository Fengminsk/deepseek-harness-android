# Android 迁移清单审查

[English](parity-review.md) | 中文

## 摘要

使用[迁移清单](parity-manifest.json)按用户能力查找 Android 剩余工作，并追溯到原始声明。审计通过只表明清单已经审查且覆盖完整，不表明运行时行为、真机验收或 Android 版本交付已经完成。

## 目录

- 分类
- 组合与证据
- 审查命令
- 交付优先级

## 分类

每条声明归属一个能力组。不同 profile 中重复的服务保留各自的声明标识，并共享能力组。能力组的 `remaining` 字段统一记录待交付和待验收工作。Linux 客体交付也有独立能力组，尽管这些上游补丁声明没有描述它。

| 分类 | 含义 |
| --- | --- |
| `unassessed` | 尚未记录源码审查。 |
| `partial` | 已确认 Android 组合方式或原生映射，但等价能力仍不完整或未验证。 |
| `adapted` | 已记录 Android 专属适配；独立的证据级别仍决定其验收边界。 |
| `not-migrated` | 必需能力尚无等价 Android 入口，或可用入口仍被禁用。 |
| `upstream-disabled` | 审查的上游声明本身已禁用该功能。 |
| `not-applicable` | 指定启动方式或平台契约不适用于 Android 原生入口。必须明确排除理由；相关共享能力仍独立保留待办。 |

替代的 headless、SDK 和 ACP 配置不代表额外缺失的原生页面。它们的共享服务关联到相应的 base 或预设声明。SDK Office 创作和工作区依赖仍是交付缺口，因为排除 stdio 启动器不会补齐这些能力。Windows PowerShell 和浏览器开发热重载有明确的平台排除理由；Android 进程隔离和正式升级仍保留各自要求。

## 组合与证据

[Android Host 配置](../runtime/host-guard.mjs)依次选择 base、Web 和 Android bundle 层。Web 禁用若干 Host 工具行；[预设暂存](stage-preset.mjs)在 Android Agent 下组合可移植工具与策略。可选 bundle 的 `assessment` 记录继承、后续配置、预设组合、替换、禁用或未选用的替代 profile，同时标明入口类别及相关声明。

151 条可选 bundle 声明均已记录评估，没有条目仍为 `unassessed`。未另行记录的执行证据仍保持 `unverified`。读取配置不能证明插件已激活或模型调用成功。14 条 `not-migrated` 包含八条原版 Node PTC／workflow 声明、三条 Bash 声明、原生本地化及两条 Office 创作／依赖声明；重复声明不是不同的缺失用户功能。`core`、`ui`、`behavior` 和 `device` 仍是独立证据声明，文件存在不会改变这些状态。

声明摘要检测行内容变化。`reviewInputs` 另行固定 Android 启动引导、Host 保护、运行时注册、Android 补丁、预设暂存和 Web 补丁的 LF 规范化 SHA-256。这些文件发生变化后必须重新审查组合，包括原先仅靠声明清单未覆盖的启用、禁用和模型注册变化。审查后一起更新受影响的映射、说明和摘要；不能只为让审计通过而刷新摘要。

已安装的 Build 118 保留[已审核工具的 PTC](model-ptc-readonly.zh.md)、[支持工作区传输的离线 Linux](linux-vm-runtime.zh.md)及[带已审核子工具的工作流](tool-native-workflow.zh.md)。PTC 组合经过审核的实时父工具；工作流子 Agent 仅继承已审核子集。原版 Node PTC／workflow 插件和 Linux 联网准入仍禁用。限定范围的生命周期检查及 [Build 116 r28 正式 profile 结果](production-profile-device.md#build-116-r28)覆盖文档列出的执行路径，包括一个工作流子 Agent。[真实账号证据](agent-service-task-device.md)另行覆盖 r33 简单回复、r34 一次跨无线断网恢复的待完成 Linux 调用，以及 r35 完成通知发布。[传输夹具](model-transport-recovery-device.md)验证 SSE 断流后的同回合重试；无线断网用例没有记录模型重试。

普通升级至 Build 118 保留了记录范围内的 Session 字节和 SAF 授权。117→118 r40 检查保留了 55 个会话文件（共 1,573,622 字节）、三项 SAF 授权及合成凭据，记录位于 `.cache/android/upgrade-117-118-r40-20261028.log`。这些结果不证明登录界面、旧会话恢复执行或所有后续产物已通过验收。r28 首次启动超时、r25 工作流挂起和 r32 进程冻结仍未解释。[定时唤醒](schedule-wakeup.zh.md)已实现默认关闭设置、精确闹钟权限检查和绑定连接代际的运行时投影；自然闹钟触发、权限变更、重启恢复及长时间 Doze 行为仍缺真机验收。本次审查不提升任何声明分类或证据级别。

Build 118 把 App 文本读取和 `android_files.read` 接入同一个[请求管理模块](../runtime/document-reads.mjs)。原生 `prepare/run/cancel` 绑定已授权根目录；Binder 提供 App 身份，工具绑定 Session 与调用身份。连接断开和运行时卸载会取消相应请求。只有读取线程与文件提供方清理任务均已停止，才释放准入名额。[r40 真机检查](file-tool-parity.zh.md#build-118-device-evidence)使用独立 Android UID 的受控提供方，验证了原生文本读取的并发、取消、晚到结果拒绝及请求关闭；它不证明任意提供方、用户点击文件的 UI 或此前闪退根因已获得验证。

Build 118 r40 还通过了一次经生产 AgentService 使用真实 `deepseek-account/deepseek-flash` 的提交：恰好一个 `android_ptc` 调用、一个有审计的 `list_agents` 回调、完成的回合及一致的实时／持久最终标记。会话归档、导出释放和进程退出均已确认，28 次屏幕采样均显示双屏 Off，结果为 `.cache/android/real-account-ptc-118-r40-20261028.json.result.json`。单独的 `.cache/android/real-account-workflow-118-r40-20261028.json.result.json` 仍为失败：父子任务完成且 `requiresReview=false`，但夹具使用普通会话入口归档子会话时返回 `DOMAIN_FAILED`。该次失败与后续结果分别保留。

正式 App 字节完全相同，r41 只修正夹具清理 API。`.cache/android/cleanup-workflow-r40-under-r41-20261028.json.result.json` 确认没有新提交，仅归档旧专用子会话。新的一次完整 `.cache/android/real-account-workflow-118-r41-20261028.json.result.json` 通过：一个真实账号工作流、一个零工具调用的子 Agent、父子完成且持久标记一致、`requiresReview=false`、两个会话归档、导出释放和连接关闭均已确认。外层报告记录六次双屏 Off 采样及进程退出确认。仅 AndroidTest APK 改为 SHA-256 `e1f3a40069d15758d51e6312b688f458f97b8835c2394dc4f7bb4cf84fbef50c`；这不是生产工作流业务缺陷修复声明，也不证明全部上游语义已验收。

## 审查命令

在仓库根目录执行清单审计、按能力分组的剩余工作报告和专项测试：

```powershell
node apps/android/tool/parity-audit.mjs
node apps/android/tool/parity-audit.mjs --capabilities
node --test apps/android/tool/parity-audit.test.mjs
```

报告输出声明数量、迁移分类、证据数量和能力组，均不代表已完成的用户功能数量。输入摘要失效会指出需要重读的源码；未知声明或无效关联键要求重新审查映射，不能通过从清单中删除来处理。

## 交付优先级

使用 `--capabilities` 查看分组工作。优先验证没有测试前台服务或 CPU 锁维持进程的自然定时唤醒，再补齐明确的 Linux HTTPS 审批和路由证据，之后才能开放该模型选项。现有 Linux 联网夹具要求交互状态的前台窗口，未经适配不能在当前持续息屏约束下运行。Office 创作及运行时依赖、终端剩余 VT／OSC 行为、原生文档与界面验收应与已交付的执行子集分别记录。完整原版 PTC／workflow 语义仍未实现。设备操作必须针对同一个已标识 APK 串行执行；当前通过结果不能解释此前启动或冻结现象。

## 开发备注

本文只记录明确范围的证据，不授权变更运行时发布控制。
