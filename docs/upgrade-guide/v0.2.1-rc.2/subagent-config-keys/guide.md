---
kind: upgrade-guide
description: "Delegation tools register one shared definition per composition and separate model selection from discovery."
---

# Update delegation tool configuration

English | [中文](guide.zh.md)

## Change

`@deepseek-ai/dsh-tool-subagent` replaces `modelSelectionSettings` with `modelSelection` and `modelDiscovery`. `modelSelection` exposes the optional `provider`, `model`, and `reasoning_effort` fields; `modelDiscovery` registers the shared `list_subagent_models` tool and defaults off independently of it. Disable `modelSelection` where a composition previously relied on the settings-driven fields disappearing, and enable `modelDiscovery` on exactly one instance per tool scope.

The plugin no longer installs a definition per Agent. One composition owns one shared registration; Agents inherit it, and switching presets changes scope ancestry without reinstalling tools. Preset references are resolved when a call starts a child, so an unknown or unloadable preset returns an errored tool result instead of failing Agent publication. The Host's `subagent-model-selection` settings service keeps recording the authorization in each fresh top-level Session during Agent creation; delegation reads that recorded policy at execution time.

## Migration

1. Replace `modelSelectionSettings: true` with `modelSelection: true` and, where discovery was expected, `modelDiscovery: true`. Shipped Web and Desktop presets already enable both on spawn and leave both off on fork.
2. Remove configuration or tests that expect per-Agent tool installation, install-time preset validation, or a Session argument to `apply(ctx, config, session?)`; `apply` now takes only the context and configuration.
3. Replace `registerListSubagentModels(ctx, { routes })` with the `modelDiscovery` option. Direct callers that pass a projection handle use `registerListSubagentModels(ctx, handle)` with `ProjectionHandle` from an awaited `ctx.sessionProjections.register(...)`.
4. Confirm that a preset composition exposes one `subagent` schema, that a child naming an absent preset yields an errored tool result, and that route fields follow the recorded Session policy rather than the settings snapshot at installation.
