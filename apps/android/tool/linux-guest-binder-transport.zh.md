# Linux 客体 Binder 通道接口

[English](linux-guest-binder-transport.md) | 中文

`IsolatedLinuxGuestBinderService` 是独立、不可导出的 `isolatedProcess` 服务。它执行由 App 发起的 `OPEN`／`HELLO` 握手；可信 App 显式提供 broker 时，还可[把锁定的 Alpine 归档当作数据暂存](linux-guest-image-handoff.zh.md)。它**没有原生客体帧来源**。握手成功或镜像暂存回执都不表示 Linux、PRoot 或模型命令已启动。UI 和 Agent 工具均没有进入这个服务的入口。

可信 App 代码只能为持久化状态为 `ADMITTED` 的运行构造 `LinuxGuestBinderBinding`。它用随机 nonce 绑定一个独立隔离服务实例，核对 Android 提供的 `Message.sendingUid`、消息报告的 UID、App UID、运行 ID 与 nonce，再把身份交给 `LinuxGuestLaunchSession`。未来服务可以发送最大为 `LinuxGuestBrokerWire.MAX_REQUEST_BYTES` 的 `FRAME`；App 复制帧字节，由 `LinuxGuestBinderBridge` 按活跃租约准入版本 2 帧，再交给现有精确文件或 HTTPS 代理。回复有长度上限；格式错误、越权、未经审计及迟到的调用会关闭通道。

绑定断开、Binder 死亡、租约撤销、超时和错误消息都会关闭 wire，并通过 `LinuxGuestRunJournal` 持久化 `RETIRE_UNCONFIRMED`。写收据失败会保存在 `journalFailure` 中；恢复时没有最终发布标记的候选结果仍不能显示为成功。当前服务因为没有原生客体消费回复，会主动拒绝 `FRAME_REPLY`。绑定层与服务均不调用 `LinuxGuestRunJournal.complete`。

未来原生监管器另有 `DSH_TRACE_V1` 事件管道与后代收尾约束。Binder 帧不能替代操作系统持有的进程证据。还需接入真实原生帧生产者和监管器、仅安装已审查的可执行字节，并在手机上验证 Binder UID、断连和真实运行。

主机准入测试：`node apps/android/tool/acceptance-linux-guest-binder-bridge.mjs`。`LinuxGuestBinderInstrumentation` 检查真机握手；`LinuxGuestImageHandoffInstrumentation` 检查未锁定的镜像报价和调用 ID 不匹配的快照均被拒绝。两项均已登记于 AndroidTest 并通过编译，尚未在手机运行，也不会启动客体。主机测试无法证明 Android Binder 身份语义。
