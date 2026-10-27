# 真实 Node 工作流生命周期验收

[English](workflow-lifecycle-device.md) | 中文

## 范围

`workflow-deadline` 和 `workflow-process-death` 套件使用打包的 Node 运行时、原版 ToolRuntime、真实进程内子 Agent 及原生隔离工作流所有者。只有模型流由脚本控制，不使用账号或付费服务商调用。每次运行使用专用私有 home 和 Session。它们不会开启生产工具，也不重复十一项普通工作流检查。

## 真机执行

使用配对且通过审计的 App 与 AndroidTest APK。驱动接受 `--suite deadline`、`--suite process-death` 或 `--suite all`（默认）。它要求 service 载体、设备已锁屏、明确授权停止包进程，以及保留数据升级现有安装的授权。屏幕包装器负责两个物理面板；仅有框架锁屏字段不能证明面板始终为 Off。

```sh
node apps/android/tool/device-screen-protection.mjs --adb <adb-path> --serial <serial> --seconds 780 --report <screen-report.json> -- apps/android/tool/acceptance-workflow-lifecycle-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --suite all --foreground-carrier service --accept-force-stop --allow-existing
```

此命令需由发布负责人执行真机验收；主机解析测试不是真机通过。驱动检查包名、签名及精确的 Agent 进程 Instrumentation。它使用 `install -r`，不清除 App 数据、不唤醒或解锁设备。生成的 Session、标记及原生回执保留以供检查。

## 观察项

期限用例等待真实子 Agent 模型流和 `WORKFLOW_CHILD_RESULT`。生产 120 秒原生期限必须产生 `TIMED_OUT` 脚本回执，以及无输出的失败工作流。载荷的取消兜底为 175 秒；若兜底触发，用例失败。通过还要求子模型已取消、原生子任务已退役、release 已确认，且 Session 恰有一条持久化失败终态。

死亡准备阶段等待同一真实子任务结果回调，flush 父子 Session，并 fsync 包含日志哈希、精确身份及进程租约的标记。主机将存活隔离客体绑定到运行 UUID，停止 App／测试包，要求完整进程清单连续两次为空。准备阶段 ADB 客户端完全关闭后，才在另一进程启动恢复。恢复沿用私有 home，并新建观察者 Session。生产原生租约恢复必须使旧子任务退役，同时保持原运行中断且无输出。按解析事件比较，两份旧 Session 日志必须相同；不得出现模型请求、回调重放或新准入。测试代码不会代为退役记录中的子任务，也不会写入旧 Session 成功终态。

失败会停止依赖阶段。驱动执行有界的最终包进程退役，分别保留已完成检查和失败阶段。进程、租约、回执或日志证据缺失仍为失败。这两个显式套件不会隐式加入普通运行时载荷的 `all`；它们的报告不能消除独立的升级记录保留要求。

期限失败会保留具名失败检查，附有界的原生结算、回调关闭／错误链、ToolRuntime 错误及内存／持久化事件摘要。缺少 `run-end`、缺少 `data.stopReason` 和终态错误会分别失败。诊断读取不会结算或重试运行，并标明观察发生在载荷 finally 清理前；后续清理不会将这些观察改为通过。事件摘要不含提示词或输出。真实主机子 Agent 回归确认：取消成员事件先于唯一持久化 `run-end`，后者的 `stopReason` 为 `error`；原生期限行为仍只能由真机运行证明。

即时 `acceptance.workflowLifecycleStage` 通知区分等待子任务、等待／返回原生调用、诊断失败、清理等待／完成阶段。每条完整 JSON-RPC 帧不超过 12 KiB，不含回调 token，仅表示观察结果。后续清理阻塞仍受原有整体期限约束而失败；通知不能标记套件完成，也不能替代实际进程退役。

## 主机检查

```sh
node --test apps/android/tool/acceptance-workflow-lifecycle-device.test.mjs apps/android/tool/device-runtime-acceptance-report.test.mjs apps/android/tool/device-screen-protection.test.mjs
node --import tsx --test apps/android/tool/device-runtime-acceptance-workflow-model.test.mjs
```

第一条命令使用主机替身检查证据校验、设备绑定、阶段顺序和失败清理。第二条使用脚本模型检查真实主机 Agent 与 Session 持久化。两者均不执行 Android Binder 代码。
