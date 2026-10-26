# Android SAF 图片会话记录检查

[English](saf-image-recorded-session.md) | 中文

按[构建说明](../README.zh.md)暂存 Android 运行时后，在仓库根目录执行 `pnpm run test:android:recorded`。`recorded-sessions.json` 清单列出 Android profile 场景；`scenarios/saf-image.json` 独立于预期输出，提供此场景的用户请求和模型工具调用。命令启动已暂存的 Android profile，通过原生请求协议提供合成 SAF 图片，让模型调用 `android_files/read_image`，并检查续接的模型请求引用了已上传的图片文件。随后关闭运行时、读取持久化的 `session.v4.jsonl`，在同一私有目录下重启 profile，确认会话结果仍引用同一附件，且没有重写日志或保存原始图片字节。该通道拒绝缺失或过期的暂存运行时源码文件及缺失的预期输出，并在成功或失败时清理临时私有目录。

提交的[预期投影](expected/saf-image-session.expected.json)仅记录重开会话后稳定的用户输入、请求、工具调用与完成字段；随机消息标识、时间、内容寻址的附件标识及工作区指令正文均被排除。每次运行都会对比该投影。行为有意变化后，可执行 `pnpm run test:android:recorded:refresh` 重写投影供审阅；该命令不会更新原版 `snapshots/` 语料。

这是正式的 Android 自有录制会话通道，**并非**规范的 `pnpm run test:snapshot` 通道。规范通道目前只接受 `headless`、`sdk`、`sdk-minimal`、`acp` 和 `web` profile，并要求进程通过 `dsh` 启动；Android 以原生 RPC 所有者启动 `bootstrap.mjs`。此命令不会自行暂存运行时，也未加入全仓库 CI 快照聚合，不能证明真实 SAF 提供方、Binder、Keystore、模型服务或真机行为。仍需 Android 真机通道和更广的场景集。
