# 原生 Linux 客体任务核验

中文 | [English](linux-guest-launch-session.md)

`LinuxGuestLaunchSession` 是拟议中的 Alpine/PRoot 任务的 App 侧核验组件。它没有连接启动器、模型工具或镜像验证器。当前 APK 不包含 PRoot ELF 或 Alpine rootfs，源码审查仍报告 `distributionApproved: false`。创建会话不会让 Linux 命令变得可用。

可信 App 必须先通过 `IsolatedExecutionPolicyOwner` 持久登记任务，并从有效租约投影出 `LinuxGuestSandboxPolicy`。会话将任务 ID 与固定镜像 SHA-256、启动器和加载器摘要、单调时限、一个经 Binder 观察到的客体 UID、有界输出和未结清的 App broker 调用绑定。新增的 `LinuxGuestLaunchSession.admitInstalled` 会调用 `LinuxGuestInstalledElfVerifier.verify`，从 `ApplicationInfo.nativeLibraryDir` 下预检两个固定的 arm64 ELF 候选文件；文件缺失、符号链接、可写、超限、架构错误、验证期间改变或摘要不符均拒绝，通过后才创建记账会话。本类尚未连接未来的启动器；原有仅接受摘要字符串的构造函数仍是未接线的测试／记账接口，单独调用不能构成可信可执行文件准入。Java 预检无法防止之后替换文件，因此原生 supervisor 在启动时还必须通过其已打开的描述符重新验证固定内容。调用方必须绑定 Android `isolatedProcess` 服务，使用 `Message.sendingUid` 作为 `sendingUid`；客体自行报告的整数不足以证明隔离。

文件和 HTTPS 请求先按有效权限预检，再计数，直到实际 App broker 返回经过审计的结算结果。本组件不会打开文件、挂载目录或创建套接字。App 必须在 PRoot 运行时直接从操作系统持有的管道读取 `DSH_TRACE_V1` 字节，并向会话提交真实的管道 EOF 和 tracer 进程退出。客体 Binder 负载不能充当进程证据。只有在进程树退出、全部 broker 调用结清、输出未超限、租约仍有效，而且 App 已持久记录任务终态后，才能发布成功结果。取消、超时、权限撤销、错误事件流、错误 UID 或缺失审计结算都会阻止成功。

使用 `node apps/android/tool/acceptance-linux-guest-launch-session.mjs` 运行仅在主机侧的生命周期检查，使用 `node apps/android/tool/acceptance-linux-guest-installed-elf.mjs` 检查已安装 ELF 的准入规则。这些检查使用合成 Binder、事件流和 ELF 输入。真机验收仍需验证可执行文件打包和分发审查、隔离 UID 与文件/网络拒绝效果、真实 PRoot 进程树收尾、取消、后台执行和升级恢复。在这些条件满足前，不开放通用 Linux Shell。
