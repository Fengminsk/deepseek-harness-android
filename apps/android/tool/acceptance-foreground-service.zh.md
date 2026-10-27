# 无界面运行时验收

[English](acceptance-foreground-service.md)

本文说明[打包 Node 工具验收](device-runtime-acceptance.zh.md)可选的服务承载。主机检查验证所有权与清理；Android 锁屏时的调度仍需真机验收。它不证明生产 `AgentService` 的后台存活。

## 选择与证据

`NativeRuntimeToolsAcceptanceInstrumentation` 接受 `foregroundCarrier=activity|service`，省略时选择 `activity`。显式 `service` 值选择仅包含于 release 验收构建、位于 `:agent`、不对外导出的服务，没有桌面入口。其 `specialUse` 前台服务声明明确用途为仪器运行时验收。租约仅借用仪器从后台启动前台服务所需的权限。它不启动 Activity、Flutter、产品服务或产品 Node profile。既有承载仍负责准备独立样例 home，并启动打包的样例 Node 引擎。

服务模式创建无点击跳转的静音低重要性通知，只持有带期限的 partial wake lock。它不修改显示设置、不请求亮屏或解锁，也不采集像素。报告包含 `foregroundCarrier` 及框架状态 `deviceStateBefore`、`deviceStateReady`、`deviceStateAfter`：可交互状态、锁屏／设备锁定状态以及显示器 ID／状态。这些观察不能证明实际面板电源；该证据由[主机屏幕保护器](device-screen-protection.zh.md)负责。Activity 模式保留已绘制且有焦点的黑窗要求和像素检查。

## 所有权与失败

受签名权限保护的状态／关闭广播携带一个 UUID 和 Agent 进程 PID。只有成功进入前台且获取 CPU 租约后才确认就绪。其他令牌不能替换或释放该 owner。正常关闭等待 wake lock 释放、前台状态移除后的 `onDestroy`；仅请求停止不算确认。服务使用 `START_NOT_STICKY`，不能自动重启已失去所有者的样例。

服务租约允许套件预算外加 120 秒启动时间和 60 秒余量。到期会通知仪器失败并关闭真实原生 owner，同时最多再保留前台／CPU 资源 120 秒供清理。wake lock 使用相同硬期限，始终不超过两小时。Android `onTimeout`、意外销毁或清理时间耗尽也会使样例失败，不能证明 owner 已退役。服务模式的启动超时同样通过仪器清理流程返回，不从 watchdog 直接结束。未响应的 owner 不能产生成功结果。

仪器在释放服务租约并结束前，关闭工作流、PTC、Linux 和文档搜索 owner。`nativeOwnersClosed` 记录这些关闭操作是否成功返回。`nodeProcessRetired` 保持 `false`：中断 Java worker 不会停止嵌入式 Node。最终进程退役必须由外部主机保护器强停归属的测试包并检查进程列表。终止或升级软件包可能移除该服务；它不为这些切换提供像素或连续显示保护。

## 主机验证

`node apps/android/tool/acceptance-foreground-service.mjs` 编译相同资源 owner 并在 JVM 上执行。受 barrier 控制的线程验证就绪在实际资源获取后出现、关闭在实际释放／销毁后出现。负例覆盖外来令牌、部分启动、资源释放失败、期限、意外销毁和不合法租约。Android 框架类另以 SDK 36 编译；这些检查不验证手机上的前台服务权限授予、厂商调度或实际显示面板。
