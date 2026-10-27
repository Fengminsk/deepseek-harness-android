# ARM64 Linux 用户态候选镜像供应链

[English](linux-userland-supply-chain.md) | 中文

## 固定来源与当前状态

已检查的**纯数据**候选镜像是 [Alpine Linux 3.24.3 aarch64 minirootfs](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.3-aarch64.tar.gz)。官方 [SHA-256 文件](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.3-aarch64.tar.gz.sha256)给出的摘要为 `4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50`；检查的压缩包大小为 4,029,999 字节。[`linux-userland-source-lock.mjs`](linux-userland-source-lock.mjs)固定了版本、大小和摘要，可校验本地副本。不能信任与镜像来自同一个不可信下载方的哈希。升级来源时需要审核锁定信息的变更，并重新验证归档和真机行为。此候选镜像尚未随 App 分发、启用，也不可执行。

已检查的 Alpine 软件包数据库包括 BusyBox、apk-tools、libapk 等 GPL-2.0-only 软件包，也含其他许可证的软件包。再分发义务和声明尚未审核，因此不得把归档加入 APK 资源，也不能将它描述为可随 App 分发的镜像。

## App 归档存储（仅内部显式操作）

[`LinuxImageInstallManager`](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxImageInstallManager.kt)提供固定 HTTPS 地址、禁止重定向、支持取消及限时的显式下载方法。目前**未连接到用户可见操作或模型工具**，App 不会自动下载镜像。[`PinnedLinuxImageStore`](../android/app/src/main/java/com/minnnng/dsh_android/PinnedLinuxImageStore.java)仅接受锁定的字节数和 SHA-256，在 App 的 `noBackupFilesDir/linux-userland/versions` 下暂存纯数据归档及记录来源和许可审核状态的收据，然后原子发布完整版本。发布后及离线重启检查时均重新读取归档与收据。中断或不匹配的下载无法发布；已发布版本若损坏则拒绝使用并保留供排查。安装器只清理自己创建且内容已知的未完成暂存目录。归档内容不会被解压、执行或交付来宾。文件 `fsync` 在原子重命名前完成；这里无法移植地对父目录 `fsync`，故突然断电后的持久性尚未证实。

[Termux 的 PRoot 构建配方](https://github.com/termux/termux-packages/blob/master/packages/proot/build.sh)列出了其分支、GPL-2.0 许可、源码哈希以及 `libandroid-shmem`、`libtalloc` 依赖。2026-10-24 查到上游配方为 5.1.107.100；仓库内单独审核过的源码锁仍为 5.1.107.96。不得直接替换成新下载版本：源码审查、可复现 Android 构建、完整依赖、APK 原生库打包方案及再分发声明仍待完成。预检中的 `libpocket_proot.so` 仅是清单槽位，**并不表示该二进制已存在**。分发镜像或 PRoot 之前还须审核 Alpine 软件包许可与相应分发义务。

## 候选版本安装约束

仅供开发的打包清单使用 `format: "pocket-linux-userland-v2"`，并通过 `source` 对象提供 `sourceUrl`、`sourceRevision` 和 `license`。应根据已审核的来源锁重新生成旧候选清单；预检会在读取产物文件前明确拒绝 v1，不改写已有清单。该输入不是 Session 格式、原生安装收据或 TinyEMU 镜像清单。验证结果仅在进程内使用，不授予执行能力。

[`verifyLinuxUserlandArtifacts`](../runtime/linux-userland-image.mjs)根据受信任清单检查 ARM64 ABI、文件大小和 SHA-256，并签发进程内不可伪造的验证结果。[`publishRootfsCandidate`](linux-userland-rootfs.mjs)只接收该结果，重新复制并校验归档、完整扫描 tar 流，对压缩大小、条目数、解压总量、单文件大小和路径深度设置上限，再解包到新建的版本化暂存目录。它拒绝路径穿越、Windows 路径别名、重复或大小写冲突的名称、设备/FIFO 条目、符号链接父目录、越界链接以及指向非先前普通文件的硬链接。镜像中的绝对符号链接被改写成候选目录内的相对链接。普通文件完成解包后才创建硬链接与符号链接，避免 tar 通过归档控制的链接写入其他位置。解包后还要按归档内容计算的 SHA-256 核对普通文件、硬链接身份及完整文件树。成功后原子重命名为 `versions/<sha256>` 并写入收据；失败时只清除安装器自己的未完成暂存目录。这保证并发读取时只能看到完整候选版本，但尚未建立目录 `fsync` 协议，不能保证突然断电后的持久性。[`verifyPublishedRootfsCandidate`](linux-userland-rootfs.mjs)允许重启后的进程根据独立重新验证的源镜像、完整归档、收据和解包文件树复核候选版本。可写收据和候选版本都不构成运行授权。该模块不会启用版本、清理旧版本或运行来宾。正式启用与回滚还需要持久任务引用和明确的版本指针。

## Android 执行阻碍

App 的目标 API 为 36。[Android 的可执行文件限制](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)禁止目标 API 29 及以上的 App 直接 `execve()` 可写 App 私有目录内解包的 ELF。这里的 rootfs 是可写数据，因此不能假设其中的 `/bin/busybox` 等 ELF 可以运行。PRoot 只提供路径和 ABI 兼容能力，不是安全沙箱；[PRoot-Distro 官方文档](https://github.com/termux/proot-distro/blob/master/README.md)明确说明它不隔离进程、IPC 和网络。仍需 APK 内置的原生启动器，以及经过真机验证的来宾执行机制。

现有隔离 UID Shell 探针专门验证它不能读取 App 私有目录。因此 App UID 在私有 `filesDir` 中暂存的 rootfs 不会自动对隔离进程可见。不能为了运行来宾而放宽此项拒绝。需要设计只交付经过校验的不可变镜像数据的跨 UID 通道，并在无 Root 设备上验证。W^X 行为、子进程清理、文件和网络代理、后台生命周期均通过真机验收之前，[`requireLinuxUserlandExecution`](../runtime/linux-userland-image.mjs)保持关闭，返回 `LINUX_USERLAND_EXECUTOR_UNAVAILABLE`。

## 已记录证据

- Alpine 官方归档通过只读检查：514 个条目，普通文件解压后合计 8,652,224 字节，包括 96 个目录、83 个普通文件和 335 个符号链接。
- 单元测试覆盖哈希变化、伪造预检结果、原子发布、路径穿越、链接和资源配额。Windows 主机不允许创建测试符号链接，因此尚未在本机验证链接实体化。
- 此管线尚未在 Android 上运行 Linux 来宾进程，不能把它标为可工作的容器或提供为 Agent 工具。
