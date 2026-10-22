# Android Shell 进程归属

`android_shell` 工具从 App 解压后的原生库目录启动独立监督程序。监督程序必须确认启动，工具才会接受执行结果。原生库缺失、父进程死亡通知注册失败或启动确认缺失时，调用失败，不会退回直接执行 `/system/bin/sh`。监督程序的确认通道接收启动帧后，Shell 才开始运行。

监督程序是独立会话和进程组的组长。它的子 Shell 和普通后代留在这个进程组中。Node 父进程死亡时，包括被 `SIGKILL` 结束，Linux `PR_SET_PDEATHSIG` 会通知监督程序，随后监督程序向整组发送 `SIGKILL`。如果监督程序自身死亡，直接子 Shell 也会收到父进程死亡信号。监督程序在启动 Shell 前注册为子进程收养者，并通过 `waitpid` 等待所有收养的后代退出；关闭了标准输出和错误输出的后代也在等待范围内。内核维护的子进程数量避免了枚举竞态，也不依赖 Android 对其他 App UID 的 `/proc` 可见性。

普通取消和超时仍向独立进程组发送信号。工具分别报告超时、取消、输出截断和未确认的组信号。进程组不限制文件或权限；命令若创建新会话或新进程组，就可能逃离该机制。Android 也可能杀死整个 App 进程集合或监督程序自身；这个 helper 和透明悬浮窗都不能保证抵抗这类终止。

宿主侧运行 `node --test apps/android/tool/shell-deadline.test.mjs`，检查调用路由、启动确认、取消和超时。在隔离的模拟器上运行 `apps/android/tool/test-shell-supervisor-device.ps1 -Serial emulator-5582 -NdkDirectory <NDK 路径> -Adb <adb 路径>`。脚本拒绝真机序列号和非 QEMU 目标，按模拟器 ABI 交叉编译原生源码，并检查确认通道关闭时拒绝执行、普通命令正常结束、父进程存活时收养已关闭输出的后台子进程，以及父进程被 `SIGKILL` 后整组退出。宿主构建或模拟器检查不能证明 ARM64 手机上的行为。
