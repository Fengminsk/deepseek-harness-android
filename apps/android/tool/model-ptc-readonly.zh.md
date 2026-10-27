# Android 只读 PTC 所有者

中文 | [English](model-ptc-readonly.md)

## 概述

App 自有的[只读 PTC 所有者](../runtime/model-ptc-readonly-owner.mjs)通过隔离 V8 客体执行可擦除的 TypeScript 函数体。它是私有组合组件，不注册模型工具，也不启用已关闭的 Android PTC profile。它通过有效父执行的 ToolRuntime 处理文件和网页，不提供 Node、Shell、直接网络访问或原生文件授权。

## 目录

- 经审查的调用
- 结果与记录
- 执行限制
- 验证

## 经审查的调用

Android 运行时在源码控制的设备验收开关后组合[模型工具工厂](../runtime/tool-readonly-ptc.mjs)。它只暴露 `code` 和 `description`，分别报告已审查回调子集与原生授权，并在启动前、发布结果前检查可用性。生产设备验收通过前，开关保持关闭。

每次执行捕获有效 Agent、活动父执行令牌、作用域内的原始定义及注册身份。原始包工厂识别自己冻结的定义；复制定义或卸载插件后，身份校验失败。每次回调在进入原始 ToolRuntime 授权和执行流程前，重新核对身份、可见性、父执行生命周期和参数。

| 工具 | 允许的操作 |
| --- | --- |
| `list_agents` | 既有审查允许的子 Agent 列表 |
| `read`、`glob`、`grep` | 受 Android 文件守卫约束的原版工作区读取与搜索 |
| `web_search`、`web_fetch` | 配置的网页提供方及其既有策略、取消机制 |
| `android_files` | 用户授权文档根上的 `roots`、`list`、`read`、`search` |
| `android_attachments` | 当前会话引用的 `list`、`read`、`inspect_archive`、`inspect_apk` |

不允许图片、写入、物化文件、Shell 命令、Linux 执行或嵌套 PTC/工作流调用。有效父执行作用域内不存在的工具不会暴露。包身份校验本身不授予访问权限，宿主工具策略仍然有效。客体不能自行指定执行类别或预算。

## 结果与记录

成功回调的值在交给客体前限制为 48 KiB 编码 JSON。工作区读取保留完整行，缩短时返回下一行偏移；SAF 和附件读取保留有效 UTF-8 或完整十六进制字节，并准确推进字节偏移。搜索和网页摘录明确标注截断，不伪造提供方的继续读取能力。无法放入限额的单个条目返回已确认的不支持结果。

APK 分析保留准确的检查范围和各自独立的 Manifest 游标。结果超过 48 KiB 时拒绝返回并提供恢复方法：减小 Manifest 分页的 `limit`，或对代码使用 `limit: 1` 与 `sampleLimit: 0`。超大的单个结果仍可通过直接附件工具读取；PTC 不会静默丢弃嵌套声明，也不会将分析改写为空的成功分页。

[工具调用端口](isolated-tool-call-port.zh.md)将实际交给客体的投影 JSON 写入配对的 Session 回调事件。持久日志保留不可重放的调用标记及结果摘要。回调审计、分发、取消或收尾不确定时，不发布成功结果。Session append 与独立日志不构成原子磁盘事务；这些检查不证明 Session 已完成刷盘。

## 执行限制

原生 `ptc` 准入只接受空文件/网络授权范围，并要求执行前绑定 ToolRuntime 回调端口。总耗时最多 120 秒，V8 执行线程另有五秒 CPU 限额。原生看门狗每 20 ms 采样该线程的 CPU 时钟；等待宿主回复消耗总耗时，不消耗计算额度。成功完成前还会再次检查 CPU。无法检查时钟时，拒绝执行或终止且不返回输出。普通脚本保留五秒总耗时限制。

App 控制器为 `ptc` 选择显式的 `function-body` Binder 格式，普通脚本和工作流保留 `function-expression`。服务将函数体交给 V8 原生 AsyncFunction 构造器。客体 SDK 发送精确的 `{action:"TOOL_CALL",callId,name,arguments}`；原生中继验证该帧，并在调用 Node 前附加私有运行身份。

原生 PTC 回调解析器独立将工具名和 Android 动作限制在上表范围，保留既有 32 次调用上限、Binder 调用方 UID 与 nonce 检查、有界帧、等待取消完成和持久收尾。CPU 限额针对 V8 执行线程，不是整个进程的总 CPU 或 RSS 限制。

## 验证

`node --import tsx --test apps/android/tool/model-ptc-readonly.test.mjs` 使用原始工具定义、真实父 ToolRuntime 及原生传输夹具，检查定义复制和卸载、禁止的动作、有界分页及[无密钥 Session 记录快照](expected/model-ptc-readonly.expected.json)。每个回调的记录 JSON 均与客体收到的回复逐字节核对。

`node apps/android/tool/acceptance-ptc-script-engine.mjs` 在主机检查 Java 限制和原生快照语义。`IsolatedScriptAcceptanceInstrumentation` 的 `ptc-readonly-budget` 阶段检查原生准入/动作拒绝、超过五秒的回调等待，以及配置 120 秒总耗时后的 CPU 终止。这些 Binder 夹具与生产验收分别记录：真正的 Node 到原生文件、SAF、附件、网页调用，以及取消、进程死亡和恢复，仍需真机证据后才能启用模型入口。
