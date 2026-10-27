---
kind: reference
title: 工作流运行时真机验收
---

# 工作流运行时真机验收

[English](workflow-device-acceptance.md) | 中文

## 摘要

[工作流载荷](device-runtime-acceptance/workflow.mjs) 通过生产 ToolRuntime、原生拥有者、隔离 JavaScript 客体、回调桥、真实子 Agent 和持久化 Session 验证已注册的 `workflow` 工具。仅模型流由脚本控制。十一项具名检查要求真实 Android 回执；主机检查或独立的纯原生 instrumentation 通过，均不代表此运行时验收通过。

## 目录

- [执行与证据](#execution-and-evidence)
- [场景](#scenarios)
- [未验证行为](#unverified-behavior)
- [主机验证](#host-verification)
- [开发备注](#dev-note)

<a id="execution-and-evidence"></a>
## 执行与证据

[运行时载体](device-runtime-acceptance.zh.md) 以 `suite=workflow` 选择此载荷；`suite=all` 时先执行它，再执行 PTC 和 Linux。它使用独立验收 home 和父 Session。载荷先验证默认注册不可用，再以仅供验收的可用性回调注册原工具，不改变产品能力设置。共享前台租约要求手机已解锁，并已绘制、聚焦全黑窗口；任何测试均不得唤醒或解锁手机。

十一项检查发起十四次工作流：JSON 拒绝占三次，两项限额检查占两次。每次生产执行仍受 120 秒上限约束；载体需为全部执行及有限退役时间预留预算，不能把一次执行上限当成全套时限。每次执行的子 Agent 并发上限仍为二，总数上限仍为八。一项失败后，后续检查停止；前台工具调用被取消并等待结束，拥有者销毁负责取消并等待后台工作，随后载体才结束。

每次通过的执行必须有真实原生终态回执、原生释放确认、匹配的只读原生查询，以及持久化父 Session 中唯一的 `run-start` / `run-end` 事件对。每个已预留子 Agent 都必须处于 `RETIRED`，且不再存在于活动 Agent 注册表。已激活子 Agent 还必须有独立、非空的持久化 Session 日志；报告保留其 ID、事件数和 SHA-256。授权拒绝可能已预留 ID 但未激活 Agent；报告区分此情况，不虚构子 Session。

载荷只在生产回调确认后记录 `phase` 与 `log`，并核对顺序及子 Agent 阶段标签。当前工作流记录器不会将这两类进度单独持久化为 Session 事件。子 Agent 开始／结束与执行开始／结束事件会持久化。报告不会把回调观察描述为已持久化的阶段／日志历史。

<a id="scenarios"></a>
## 场景

[具名检查定义](device-runtime-acceptance/workflow-checks.mjs) 是报告依据。下表描述实际执行行为和要求的结果；预期工作流失败，只有在退役和持久化失败状态均得到确认后，才算该检查通过。

| 行为 | 必需观察 |
| --- | --- |
| 纯计算 | 原始 ToolRuntime 调用返回 `42`，且未预留子 Agent。 |
| 普通子 Agent | 一个真实 Agent 返回脚本指定文本，销毁后独立 Session 仍被保留。 |
| `parallel`、`pipeline`、`phase`、`log` | 两个模型流在同步点相遇，四个子 Agent 完成，流水线阶段保留原始元素和索引，普通函数异常变成 `null`，已确认进度顺序符合预期。 |
| 结构化 JSON | 子 Session 中存在真实 `structured_output` 调用及匹配的成功结果；嵌套 JSON、Unicode、空值和重复共享值均无损返回。 |
| 非法 JSON | 循环引用、负零、值为 undefined 的对象成员分别产生原生 `FAILED`，无成功输出，且退役得到确认。 |
| 限额 | 八个子 Agent 完成；即使脚本捕获异常，第九个也不能启动。含 33 项的 parallel 请求同样失败，且不激活子 Agent。 |
| 普通子 Agent 失败 | 主动触发的模型异常产生失败子 Agent 和 `null` 元素，另一个子 Agent 仍完成；工作流自身完成。 |
| 基础设施失败 | 子 Agent 扩大 provider 路由被真实授权路径拒绝；工作流失败，已激活的并行子 Agent 和被拒绝的预留项均退役。 |
| 前台取消 | 挂起的子 Agent 已进入模型流后触发取消；子 Agent 感知取消，原生执行以 `CANCELLED` 结束。 |
| 后台完成 | 原有任务注册表达到 `completed`；`job_output` 返回子 Agent 结果，执行完成状态已持久化。 |
| 后台取消 | 原有 `job_kill` 取消挂起子 Agent；`killed` 必须伴随原生取消、子 Agent 退役和持久化的取消记录。 |

<a id="unverified-behavior"></a>
## 未验证行为

载荷始终声明三项独立证据缺口：等待嵌套工作时的原生超时、工作流 Binder 死亡／App 重启，以及升级后工作流记录保留。十一项通过因此仅表示已执行检查通过，`complete` 仍为 false。[聚合器](device-runtime-acceptance/report.mjs) 即使面对漏报，也会保留这些缺口；数字通过计数不能替代具名结果。

这些检查不证明真实服务商／网络行为、子 Agent 文件／网页权限继承、Linux 子 Agent 执行、无限循环终止或进程死亡恢复。对应证据分别由[运行时套件](device-runtime-acceptance.zh.md)、[子工具测试](workflow-child-tools.test.mjs)和[生命周期参考](linux-vm-lifecycle-device.zh.md)负责。进程终止与 APK 安装可能移除全黑前台 Activity；此类操作需要独立的屏幕保护方案，在无法满足全程黑屏要求时不得运行。

<a id="host-verification"></a>
## 主机验证

`node --import tsx --test apps/android/tool/device-runtime-acceptance-workflow-model.test.mjs` 检查真实 AgentLoop / ToolRuntime / JSONL 子 Agent：同时运行的模型流、普通失败、结构化输出、取消、路由拒绝和八个子 Agent 上限。路由拒绝检查还覆盖生产回调封装及其绑定运行和子任务的一次性证明；拒绝启动本身并不代表挂起的同级子任务已退役。它调用生产 Node 端口，不启动原生客体，也不生成 Android 回执。Windows 需要执行 Session JSONL 原子发布的权限；主机文件系统拒绝属于测试失败，不是真机结果。

失败报告分别保留原生回执、释放确认、Node 回调关闭观察和每个子任务的原生状态。最多对八个失败运行执行各限三秒的诊断读取，并记录当前 Agent 是否仍存活；无法读取时明确报告。观察结果不会将未确认回执改成通过。`node --import tsx --test apps/android/tool/workflow-failure-observation.test.mjs` 检查这种失败报告及其时限，不执行设备验收。

`node --test apps/android/tool/device-runtime-acceptance-report.test.mjs` 验证具名聚合，包括拒绝旧三项覆盖冒充完整验收、用计数隐藏失败，以及遗漏生命周期缺口。`node apps/android/tool/check-device-runtime-profile.mjs` 通过普通 `dsh` 配置加载复制后的载荷，并在首次原生准入请求处停止。它仅验证启动，不执行或模拟原生工作流完成。

<a id="dev-note"></a>
## 开发备注

模型适配器只控制流式模型内容和可取消的等待，不伪造工具结果、Session 事件、原生终态、释放或退役。应保留原始真机报告及其具名未验证项；增加此载荷不会开启面向模型的工作流能力。
