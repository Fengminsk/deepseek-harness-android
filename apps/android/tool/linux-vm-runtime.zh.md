---
kind: reference
title: Android Linux 虚拟机执行
---

# Android Linux 虚拟机执行

[English](linux-vm-runtime.md) | 中文

## 概要

可选 Android 载体在隔离服务中嵌入 TinyEMU 的 RISC-V 解释器。它启动 Linux 内核并运行传入的 Shell 脚本，不以 App UID 执行该脚本。普通构建排除虚拟机原生执行器和客体镜像，也不要求准备 TinyEMU 源码；仅显式 `-PdshAcceptanceBuildType=release -PdshLinuxGuestFixture=true` 同时启用它们，未包含的执行器对请求明确返回不可用。模型注册另由[运行时入口](../runtime/index.mjs)的 `LINUX_VM_DEVICE_ACCEPTED` 控制。关闭状态不能表述为模型已经能够使用此能力。

## 目录

- [执行](#执行)
- [工作区文件导入](#工作区文件导入)
- [客体产物导出](#客体产物导出)
- [持久化与失败](#持久化与失败)
- [构建与证据](#构建与证据)

## 执行

[原生执行器](../android/app/src/main/cpp/linux_vm_engine.c)仅接收 BIOS、内核和磁盘的内存映射。客体拥有 128 MiB 内存、VirtIO 控制台和块设备，不包含宿主文件系统、网络设备、SDL、KVM 或 Node API。服务启动客体前检查隔离 UID 无法读取 App 存储或创建网络套接字。

`linux_exec` 接收 `command` 与 `timeoutMs`，由已注册的 Agent 提供会话身份。脚本上限为 32 KiB UTF-8 字节，从 `/workspace` 开始执行，启动及执行总时限最多 120 秒。控制台输出上限为 64 KiB，并明确报告截断。已结束的 Shell 可以返回非零退出码。原生结果分别记录超时、取消、执行器退出和磁盘发布状态。

当前 ToolRuntime 执行读取 Agent 的实时 `sandboxPolicy`。缺少策略或 Agent 未注册时拒绝执行。宿主独立提供 `persistChanges`，模型参数不能设置它：只读会话丢弃客体磁盘改动；可写会话可在命令完成后提交。若已完成回执中的 `diskCommitted` 与该策略不符，Node 持有者会拒绝回执。

## 工作区文件导入

`linux_import` 接收 `source`、`destination` 和可选的 `timeoutMs`。源文件相对于当前 Agent 工作目录，目标相对于客体 `/workspace`。拒绝绝对路径、父目录穿越、URI，以及模型指定的会话或持久化参数。仅接受同时位于 App 工作区及当前会话工作区内、不超过 64 MiB 的普通文件。附件需先通过独立授权的物化步骤写入工作区，再执行导入。

文件解析后，工具再次检查实时 Agent 与可写会话策略。[原生文件读取器](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmFileInput.kt)在读取前检查已打开描述符的实际路径是否位于 App 工作区。导入成功回执包含规范化的 App 相对 `source`、客体相对 `destination`、`bytes` 和 `sha256`。导入命令失败时不提交磁盘改动。导入要求可写策略；只读会话仍可通过 `linux_exec` 检查已有客体，但不保留改动。

## 客体产物导出

`linux_export` 将不超过 64 MiB 的普通客体文件复制到当前 Agent 工作区。`source` 相对于客体 `/workspace`，`destination` 相对于 Agent 工作目录。它复用附件物化使用的 Android 写入授权，包括受保护的工作区元数据规则，并要求可写会话。工具检查 App 与会话目录归属、拒绝已存在目标；最终竞态由原生描述符相对操作及不覆盖发布检查处理。导出不会保存客体磁盘的临时改动。

成功结果要求 `filePublished: true`、`diskCommitted: false`，以及一致的源路径、目标路径、字节数和 SHA-256。工具补充 `file_path`，供已有文件浏览器和展示工具使用。若文件发布成功后同步出错，即使 `filePublished` 为真也标为 `outcome_uncertain`；持有者关闭，调用方应检查已存在目标，不能自动重试。[设备测试](device-runtime-acceptance/linux.mjs)读取专用导出文件、核对内容哈希，并检查不覆盖与只读拒绝。

## 持久化与失败

[镜像存储](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmImageStore.kt)校验打包镜像，并为每个会话映射独立的 128 MiB `/workspace` 卷。更换系统镜像时保留工作区；工作区之外的自定义改动则属于该系统镜像版本。客体退出后，[块存储](../android/app/src/main/java/com/minnnng/dsh_android/LinuxVmBlockStore.java)只写入并同步发生变化的 64 KiB 内容块，再原子发布同时包含两个磁盘状态的指针，避免每条命令重写完整镜像。中断或取消的快照保留之前的指针。取消和发布共用持有者锁，因此取消不能撤销已发布的指针。

所有虚拟 CPU 均在隔离进程内执行，不创建宿主子进程。原生调用返回或该进程的 Binder 死亡用于确认执行器退出。用户取消与持有者卸载只请求取消，原执行 RPC 保留至独立时限。最终回执保留真实 `diskCommitted` 并报告 `cancelRequested`，包括先发布磁盘、后收到取消的竞态。最终回执丢失或无效时，Node 持有者以 `outcome_uncertain` 关闭并阻止自动重试，即使取消确认已经证明进程退出。停止或结果不确定的调用保留运行记录，不把其输出当作命令成功。

Linux 工具通过真实 ToolRuntime 结果附加有界的 `android-linux-receipt` 上下文。即使调用方取消使工具结果归一化为 `ABORTED`，仍保留原生运行标识和实际发布状态。不确定结果使用结构化 `HarnessError` 错误码 `linux-vm/outcome-uncertain`；未知发布状态保持 `null`，不根据取消确认推断为假。取消后收到的上下文由 AgentLoop 写入 Session 的 `agent/inbox/spliced` 事件，并在下一轮交给模型。此审计不包含 Shell 输出或命令文本。宿主回归同时覆盖取消后的规范结果与真实 Session 事件顺序。

## 构建与证据

[源码构建器](build-tinyemu.mjs)校验[固定的官方输入](tinyemu-source-lock.mjs)，应用[嵌入补丁](patch-tinyemu.mjs)，记录编译器、源码和产物哈希。[CMake](../android/app/src/main/cpp/linux_vm.cmake)使用准备好的源码重新编译 JNI 执行器。[镜像准备命令](stage-linux-vm-fixture.mjs)将启动测试镜像放入缓存；仅显式验收 release 构建的 `-PdshLinuxGuestFixture=true` 参数会包含它们。对应源码和许可记录完整前，测试镜像的 distribution 字段仍保持受限。

[Node 持有者测试](native-linux-vm.test.mjs)、[真实 ToolRuntime 注册测试](tool-linux-vm.test.mjs)和[控制台帧测试](../android/app/src/test/java/com/minnnng/dsh_android/LinuxVmConsoleTest.java)分别覆盖自身的宿主路径。[设备测试入口](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/LinuxVmAcceptanceInstrumentation.kt)负责内核启动、实际命令执行、磁盘保持和中断证据。编译与宿主测试不能替代设备结果。

## 开发说明

固定工具 `android_linux` 与此虚拟机具有独立实现，两者均不提供 Root 或 ADB 权限。客体仍不联网。Android 路径不会仅因出现在脚本中就成为客体挂载目录；`linux_import` 与 `linux_export` 是显式授权的复制操作。
