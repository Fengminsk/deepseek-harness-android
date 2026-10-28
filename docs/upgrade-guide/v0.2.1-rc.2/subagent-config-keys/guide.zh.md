---
kind: upgrade-guide
description: "委派工具在每个组合中只注册一份共享定义，并把模型选择与发现拆开。"
---

# 更新委派工具配置

[English](guide.md) | 中文

## 变更

`@deepseek-ai/dsh-tool-subagent` 用 `modelSelection` 与 `modelDiscovery` 取代 `modelSelectionSettings`。`modelSelection` 公开可选的 `provider`、`model` 与 `reasoning_effort` 字段；`modelDiscovery` 注册共享的 `list_subagent_models` 工具，且独立于前者、默认关闭。原先依赖「设置驱动、字段随会话消失」的组合应关闭 `modelSelection`，并在每个工具作用域中恰好一个实例上启用 `modelDiscovery`。

插件不再为每个 Agent 安装定义。一个组合只拥有一份共享注册；Agent 继承它，切换 preset 只改变 scope 祖先关系，不会重新安装工具。preset 引用在调用启动子 Agent 时才解析，因此未知或无法加载的 preset 返回错误的工具结果，而不是让 Agent 发布失败。Host 的 `subagent-model-selection` 设置服务仍在 Agent 创建时为每个新顶层 Session 记录授权；委派在执行时读取该记录策略。

## 迁移

1. 把 `modelSelectionSettings: true` 替换为 `modelSelection: true`；需要发现工具时再加 `modelDiscovery: true`。随附的 Web 与 Desktop preset 已在 spawn 上启用两者，并在 fork 上保持关闭。
2. 删除依赖「按 Agent 安装」「安装期校验 preset」或「向 `apply(ctx, config, session?)` 传入 Session」的配置与测试；`apply` 现在只接受上下文与配置。
3. 用 `modelDiscovery` 选项替代 `registerListSubagentModels(ctx, { routes })`。直接调用方若持有投影句柄，使用 `registerListSubagentModels(ctx, handle)`，句柄来自 `await ctx.sessionProjections.register(...)` 返回的 `ProjectionHandle`。
4. 确认 preset 组合只暴露一份 `subagent` schema，指定不存在 preset 的子调用返回错误结果，并且路由字段依据 Session 记录的策略而非安装时的设置快照。
