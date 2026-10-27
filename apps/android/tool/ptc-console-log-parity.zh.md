# PTC console 日志对齐范围

[English](ptc-console-log-parity.md) | 中文

原版 `packages/ptc-runtime/ptc-runtime-node` 会连同执行结果返回按顺序排列的 console 输出。Android 受限 `android_ptc` 传输此前即使隔离执行成功，也固定返回空的 `logs` 数组。本次将成功日志接通实际原生链路：V8 捕获 → JNI 结果 → 隔离 Binder 回复 → 版本化持久回执 → 原生桥 → Node 回执投影 → `android_ptc` 结果。工具文本渲染器也会先按顺序呈现这些日志，再显示结果。当前受审查模型入口已在源码中开放；单独的日志传输不代表完整产品验收已完成。

客体按顺序捕获 `console.log`、`info`、`warn`、`error`、`debug` 的文本行。最多允许 128 条、JSON 编码后的日志不超过 16 KiB；日志与返回 JSON 合计不超过 64 KiB。超限返回 `OUTPUT_TOO_LARGE`，不发布部分数据。失败、取消、超时、工作进程死亡及无法确认的退役状态均不发布日志或结果。第一版回执解码为空日志数组，新回执使用第二版格式。

宿主证据：`node apps/android/tool/acceptance-isolated-script-run.mjs` 通过，覆盖真实第一版回执样本及第二版带日志回执往返；`node apps/android/tool/acceptance-ptc-script-engine.mjs` 通过；四组定向 Node 测试共 33 项通过。离线 `:app:externalNativeBuildDebug :app:compileDebugKotlin :app:compileDebugAndroidTestKotlin` 成功。回执宿主验收首次运行在既有 256 条原子重命名压力循环中遇到 Windows `AccessDeniedException`，串行复跑通过。真机 instrumentation 仅已编译，尚未运行。

与原版 DSH 的剩余差距包括 Node 模块访问、已声明的更多绑定命名空间、持久 REPL、失败执行的日志保留、更长执行时间，以及 Binder、UID、进程死亡行为的真机证据。受审查的 Android 入口已按[所有者参考](model-ptc-readonly.zh.md)中的限制在源码中开放；r26 新增限定范围的[正式 profile 真机通过结果](production-profile-device.zh.md)，不代表所有 console／日志行为均已验收。普通 Build 116 升级仍待验证。
