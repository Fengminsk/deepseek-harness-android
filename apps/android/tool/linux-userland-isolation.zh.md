# Android Linux 用户态执行边界

[English](linux-userland-isolation.md) | 中文

## 用途与当前行为

小型 Linux 用户态可让 Agent 的命令环境更稳定，例如 Shell、常用文本工具、语言运行时和一致的命令名称。它只提供兼容性，本身不是容器安全边界。当前 Android App 在应用 UID 下运行内嵌 Node，并保留仅供显式诊断的应用 UID `/system/bin/sh`；该路径没有文件系统或网络隔离，也不会作为普通模型工具开放。一个 `isolatedProcess` 服务可运行有界 V8 脚本，没有 Node 或环境文件／网络权限。另一个隔离命令服务已通过 App 持有的 Binder 调用桥执行少量固定 Android 工具，接受有界标准输入和文字参数，但不接受 Shell 源码、宿主路径或直接网络授权。固定命令的 `android_linux` Agent 工具已接入此命令桥，但尚未通过真机隔离验收。当前两条隔离路径都不能运行 Linux 发行版，也没有向模型开放的通用 Shell。参见 [Shell 策略](../runtime/shell-execution-policy.mjs)、[原生 Shell 监督器](../android/app/src/main/cpp/shell_supervisor.c)、[脚本引擎](isolated-ptc-script-engine.zh.md)与 [PTC 执行设计](ptc-execution-design.zh.md)。

## 职责划分

| 组件 | 职责 | 不得继承的权限 |
| --- | --- | --- |
| 可信 App 与 Node 宿主 | 管理任务状态、审批、账号凭据、镜像清单、审计和恢复 | 模型编写的命令不得以这个 UID 执行 |
| Linux 客体服务 | 在平台支持时以新的隔离 UID 运行一次获准命令 | 不得获得 App 私有路径、`ContentResolver`、账号令牌或运行协议外的 Binder 权限 |
| 文件与网络代理 | 在一次已签发策略内代理获准的工作区读写和精确主机 HTTPS | 不得接受客体任意指定的 App 原始路径、无限制套接字或隐式扩大目录授权 |
| 用户态镜像 | 提供经过核验且版本固定的可执行文件和数据，并标明 ABI | 不产生特权或沙箱保证，运行中不得动态安装软件包 |

App 通过[沙箱策略投影](isolated-sandbox-policy.zh.md)签发一次运行策略：默认只读、禁止联网；用户明确批准后才可包含工作区写入根目录和精确 HTTPS 主机。客体只能在该范围内请求操作，子任务只能收窄策略。文件写入必须在 App 侧操作代理执行限制，包括对 `.git`、`.agents`、`.codex` 和 `.aws` 的保护；即使虚拟路径看起来很宽也一样。客体不得获得可写的 App home 或工作区绑定挂载。当前 V8 桥接可作为协议基础，但不会自动为 Linux 原生进程提供有界宿主调用接口。

另见 [Linux 客体代理预检](linux-guest-sandbox-policy.zh.md)：它将有效租约投影到虚拟文件路径与精确 HTTPS 主机，不授予直接挂载或套接字；每次操作仍须由 App 侧代理执行。[代理帧契约](linux-guest-broker-wire.zh.md)限制并核对拟议的文件与 HTTPS 请求。[未激活的 Binder 通道](linux-guest-binder-transport.zh.md)可核验隔离服务身份，但尚无原生客体帧来源。[启动会话核验](linux-guest-launch-session.zh.md)还要求隔离 UID、代理调用结算与完整进程树退出证据。[运行日志契约](linux-guest-run-journal.zh.md)持久保留运行 ID，完成标记同步前不公开候选结果。这些组件都尚未连接可执行客体。

## 运行契约

准入前检查随包提供或下载的镜像的签名或固定摘要、ABI、清单版本、文件数、解包字节上限、路径穿越、链接目标与可执行文件来源。当前 App 以 API 36 为目标；对以 API 29 及以上版本为目标的 App，Android 禁止从可写 App home 中直接 `execve()` 解包后的 ELF。因此启动器和原生工具必须作为 APK 代码打包；下载的镜像只能提供经过核验的非可执行数据。参见 [Android 对可执行文件的限制](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)。App 可以原子安装并核验惰性归档，但不能假定隔离 Service 可以在 App 私有目录解包、遍历：[Android 16 隔离进程策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/isolated_app_all.te)禁止直接打开 App 数据文件。当前[暂存预检](linux-guest-staging-recovery.zh.md)会拒绝不可用的路径；Alpine 真正运行前还需解决[存储方案](linux-guest-storage-options.zh.md)。每次运行固定使用一个镜像版本。镜像核验确定代码身份，不证明客体被隔离。

App 在启动客体前记录 `runId`、父任务、镜像版本、已签发策略 ID、准确命令及参数、截止时间和输出限额。客体只收到这个不可变请求和明确的代理句柄。不得复制 App Node 进程的环境变量；`PATH`、区域设置、临时目录语义以及虚拟工作目录都要固定，且工作目录不能被误认为文件授权边界。输出应分帧、限量并关联运行 ID。只有客体退出、待处理代理调用、子进程和审计写入全部收尾后，才可持久记录成功。取消、超时、Binder 死亡、App 终止和软件包升级必须得到明确终态或 `outcome-uncertain`，不能凭空判定成功。

可选的[原生监管器源码](linux-guest-native-supervisor.zh.md)预备了固定诊断命令和系统持有的事件管道，但普通构建默认禁用，也没有 Service 调用方。

用户态选择应分阶段实施。先在普通手机的隔离 UID 中证明一套小型、固定版本、随 APK 打包且兼容 Bionic 的工具可以直接执行。当前候选采用 Alpine musl 根文件系统和单独构建的 PRoot 启动器；启用前必须以真机证明隔离 UID 如何读取客体数据、ELF 执行如何符合 Android W^X、系统调用转换如何工作，以及每个后代进程如何完成回收。参见[候选状态](linux-proot-candidate/STATUS.md)、[进程事件协议](linux-proot-candidate/EVENTS.zh.md)和[分发闸门](linux-proot-candidate/DISTRIBUTION.zh.md)。PRoot 可改变客体看到的路径语义，但不能执行 App 工作区、网络或凭据策略。完整发行版还会增加存储、启动、更新和供应链成本，应作为与基础 App 分开版本化的可选能力。Android 虚拟化框架不能直接作为普通第三方 App 的替代方案：虚拟机 API 需要受限的 `MANAGE_VIRTUAL_MACHINE` 权限（见 [AOSP 框架说明](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/tags/aml_net_351410000/libs/framework-virtualization/README.md)）。以后可以用 WASI 解释器执行能力受限的 WASM 程序，但它不能执行 Alpine ELF，也不能称作 Linux 虚拟机。

固定版本的 Alpine/PRoot [源码包证据](linux-proot-candidate/SOURCE-BUNDLE.md)可供后续分发审查；校验通过不代表允许打包或执行。

## 扩大客体权限前必须取得的真机证据

在无 Root 手机上证明客体实际 UID，以及对 App 私有文件、授权范围外的工作区文件和直接网络套接字的拒绝。证明只有通过代理和审批，才可读取文件、进行版本校验的写入与访问精确主机 HTTPS。分别运行 Shell 管道、派生子进程的命令、新会话尝试、大量输出、内存压力和挂起命令；取消及杀死服务后，证明没有子进程继续执行或产生迟到副作用。再覆盖后台、离线、进程终止以及 APK／镜像升级。若平台不能可靠控制或核对所有子进程，通用用户态命令工具保持不可用；隔离 V8 的 PTC 子集可继续独立开发。

取得对应真机证据前，界面不应宣称“Linux 容器”或“工作区沙箱”。用户态镜像确实可让 Agent 更方便地执行命令，但安全性依赖隔离 UID，以及 App 对文件、网络、进程和生命周期的控制。
