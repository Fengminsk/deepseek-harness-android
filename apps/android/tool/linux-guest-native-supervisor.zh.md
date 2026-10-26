# 尚未交付的 Linux 客体原生监管器

[English](linux-guest-native-supervisor.md) | 中文

`linux_guest_supervisor.c` 目前只是 Android ARM64 可行性源码。App CMake 中的 `DSH_BUILD_LINUX_GUEST_SUPERVISOR` **默认关闭**；普通 APK 构建不会编译或打包此程序、PRoot、加载器或 Alpine。目前没有 Service 调用方，也没有 Agent 工具。显式编译该目标**不代表**获准将其放入 APK。

未来固定诊断调用为 `libpocket_linux_guest_supervisor.so PARENT_PID RUN_UUID ISOLATED_ROOTFS_DIR`。父进程必须是可信的、每次运行独立的 `isolatedProcess` Service，并须并行读取标准输出。监管器要求规范 UUID、隔离 UID 自有且无写入权限的规范 rootfs 目录，以及与监管器同处 APK 安装目录、当前 UID 不可写的 PRoot／加载器候选文件。它以不跟随符号链接的方式打开两个文件，针对**同一只已打开的只读描述符**核对固定 SHA-256；用描述符 4 执行启动器，仅通过 `PROOT_LOADER=/proc/self/fd/6` 向 PRoot 提供固定加载器描述符。安装目录对隔离 UID 不可写，核验期间描述符始终保持打开，以免同 UID 替换路径。可信 App 仍须独立核验 rootfs 镜像摘要和不可变安装包版本。拟议诊断命令固定为 `/bin/true`，不接受模型参数。Android SELinux 是否允许 `execve("/proc/self/fd/4")`，以及 PRoot 是否可使用描述符形式的加载器路径，仍须真机验证。

摘要核验后，监管器才会在派生子进程前建立独立的事件、丢弃客体输出和执行失败管道。子进程将 PRoot 事件管道放在描述符 3，执行后只保留这个控制描述符与只读固定加载器描述符 6，再用内核 `close_range` 关闭所有意外描述符，且仅传入固定环境和运行 UUID。若内核不支持 `close_range`，立即拒绝启动。`execve` 失败不会被当作成功的事件收尾。父进程限制客体输出 64 KiB、事件 2 MiB、运行 30 秒；标准输出仅转发已解析的 `DSH_TRACE_V1` 事件，客体输出只计数并丢弃。成功须同时看到 `ROOT`、`ARM`、按序生命周期事件、`DRAIN`、管道 EOF、追踪进程正常退出、已观测活动后代清零以及子收割器的 `waitpid` 穷尽。App 的 `LinuxTraceeEventWire` 和持久运行日志仍需独立复核并提交结果。

取消、超时、事件畸形或 App 父进程死亡时，监管器只在追踪进程 PID 尚未收割时终止其进程组。作为子收割器，它还读取自身的 `/proc/self/task/<pid>/children`，在收割前终止直接子进程；中间父进程退出后重复检查，以发现被接管的后代。事件记录中的历史 PID 可能已经被回收并复用，绝不用于发信号。即使所有管道已关闭，监管器仍执行这一步；发现意外接管、子进程列表无法完整读取或两秒内无法收割时，均不得报告成功。这**不能证明**手机上所有脱离进程组的后代都会死亡。未来 Service 必须每次运行使用新的隔离 UID，结果不明时销毁该进程，并以真机验证没有遗留后代。PRoot 只转换路径，不是安全沙箱；隔离 UID 和代理策略必须拒绝 App 私有路径与网络权限。失败或中断的运行不能写入成功收据；安装包升级后须使暂存镜像和已固定可执行文件身份失效，再允许重试。

目前的主机证据：[验收脚本](acceptance-linux-guest-native-supervisor.ps1)使用 Android NDK 28.2.13676358、`-Wall -Wextra -Werror` 编译 ARM64 源码，检查 AArch64 PIE、解释器 `/system/bin/linker64`、16 KiB 加载段对齐；提供 APK 时还检查普通包未包含监管器。同一份 SHA-256 C 核心及直接子进程列表解析器会编为 WebAssembly；[解析测试](acceptance-linux-guest-children.mjs)覆盖畸形、超界和输出容量不足的 PID 列表。主机检查无法验证 Android 的子进程接管或 SELinux。它尚未在手机运行，没有加载 PRoot 或运行 Alpine。候选文件进入任何调试或正式 APK 前，必须先解决 [PRoot 分发审查](linux-proot-candidate/DISTRIBUTION.zh.md) 的许可证与源码交付闸门。

功能对照边界：原版 DSH 的[本地沙箱](../../../packages/sandbox/sandbox-local/README.zh.md)约束宿主命令及后代；[沙箱策略](../../../packages/sandbox/sandbox-policy/README.zh.md)管理文件影响，网络策略另行处理。这个固定 `/bin/true` 的客体实验没有实现通用命令、工作区写入或网络能力。只有真实隔离 UID 执行与故障恢复完成真机验证，才能考虑替换当前面向模型的有界 `android_linux` 工具。
