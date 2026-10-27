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

此次补充评估的可选 bundle 执行证据全部保持 `unverified`。读取配置不能证明插件已激活，也不能证明模型调用成功。`core`、`ui`、`behavior` 和 `device` 仍是独立的人工证据声明，文件存在不会改变这些状态。主机测试不能替代真机要求。

声明摘要检测行内容变化。`reviewInputs` 另行固定 Android 启动引导、Host 保护、运行时注册、Android 补丁、预设暂存和 Web 补丁的 LF 规范化 SHA-256。这些文件发生变化后必须重新审查组合，包括原先仅靠声明清单未覆盖的启用、禁用和模型注册变化。审查后一起更新受影响的映射、说明和摘要；不能只为让审计通过而刷新摘要。

Build 116 源码候选开放[已审核工具的 PTC](model-ptc-readonly.zh.md)、[支持工作区文件传输的离线 Linux 执行](linux-vm-runtime.zh.md)及[带已审核子工具的工作流](tool-native-workflow.zh.md)；Linux 联网准入仍关闭。PTC 可以串联父 Agent 已审核的文件、网页及 [Linux 工具](model-ptc-linux.zh.md)；工作流子 Agent 仅继承已审核的实时父工具。Linux 执行离线客体命令，文件需显式传输；可选的有界 HTTPS 实现未注册到正式模型工具。Build 115 r15／r17／r21 的观察覆盖文档列出的回调、恢复和取消用例。r26 所装正式 profile 另已在锁屏息屏设备上通过脚本模型驱动的 PTC 工作区读取及离线 Linux Python 分析，客体与 App UID 不同，退役结果与 Session 记录一致。r26 workflow 专项另已通过常规执行（11／11）、120,256 毫秒时限检查（一个持久 run-end 且子级退役）及进程死亡恢复。包含 workflow 的正式 profile（`expectWorkflow=true`）与普通 Build 116 升级仍待验证。r25 workflow 时限尝试曾挂起至 390 秒墙钟上限而无结果；虽然后续通过，其原因仍未解释。清单记录这项限定范围的结果，不将所有声明提升为已验证。宿主保护继续禁用普通 Node PTC 插件。

## 审查命令

在仓库根目录执行清单审计、按能力分组的剩余工作报告和专项测试：

```powershell
node apps/android/tool/parity-audit.mjs
node apps/android/tool/parity-audit.mjs --capabilities
node --test apps/android/tool/parity-audit.test.mjs
```

报告输出声明数量、迁移分类、证据数量和能力组，均不代表已完成的用户功能数量。输入摘要失效会指出需要重读的源码；未知声明或无效关联键要求重新审查映射，不能通过从清单中删除来处理。

## 交付优先级

使用 `--capabilities` 查看当前分组工作。编程式工具、工作流和 Linux 客体需要可用的模型入口，以及隔离和生命周期验收。文件能力需要真实模型调用、授权保持与撤销、安全且有界的读取。后台任务和历史记录需要锁屏、断网、进程终止与普通升级证据。这些方向可以独立开发，但安装和前台真机验收必须针对同一个已标识 APK 串行执行。

## 开发备注

本次审查没有新增真机观察，也不构成修改运行时发布控制的授权。
