# 普通 Android 上的 Linux Guest 存储选择

[English](linux-guest-storage-options.md) | 中文

本文适用于无 Root 的普通 App 及其 `isolatedProcess`。它不表示当前 PRoot 候选已经可以运行。Android 将隔离 Service 定义为没有自身权限的进程。AOSP Android 16 策略允许隔离进程使用通过 IPC 收到的、已经打开的 App 数据文件描述符，却禁止它按路径打开 App 数据文件或自行创建普通网络套接字。因此，不能假定隔离进程能在 App 私有 `cacheDir` 创建并遍历 rootfs；具体失败点仍需真机确定，现有暂存预检会拒绝不可用的目录。[Service 声明](https://developer.android.com/guide/topics/manifest/service-element)、[AOSP 隔离进程策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/isolated_app_all.te)。

| 方案 | 隔离进程得到的内容 | 尚待解决的问题 |
| --- | --- | --- |
| APK 内置原生工具 | 固定、经审查的 Bionic 兼容程序 | 真机验证安装包提取、`execve`、动态库加载、取消和全部子进程；命令目录及 App 授权接口仍需受限。 |
| APK 资源或 Alpine 压缩包 | APK 或封存快照中的只读数据 | tar/ZIP 不是 PRoot 的 `--rootfs=path` 所需文件树；隔离 UID 不一定能向 App 私有目录解包。 |
| Binder 传入文件或目录 FD | 已经打开对象的访问权 | 调试设备探针会尝试用传入的目录 FD 执行子路径 `openat`。获得真机结果前，不能将此 FD 当作 PRoot 可遍历根目录；单个归档 FD 不是完整文件系统。 |
| `SharedMemory` 或 memfd | 不暴露 App 私有路径的有限字节 | 封存数据映射适合校验，并非目录树或可执行程序；当前快照移除了写入和执行映射。 |
| App UID 中运行 PRoot | App 自有 rootfs 路径 | 若没有另一套经过验证的系统隔离，Guest 会继承 App 私有文件与凭据访问；PRoot 路径转换不能提供该隔离。 |

近期可行方向是隔离 UID 中的固定 APK 原生工具目录，不直接挂载工作区或开放 socket，文件与 HTTPS 操作由 App 授权接口办理。SHA-256、字节数和行数使用 APK 内同一个 Bionic 程序，参数模式固定，标准输入受限；其他固定命令仍使用 Android 系统工具。这是工具目录，不是 Alpine 文件系统命名空间。Android 要求目标 API 29+ 的 App 从 APK 内置代码执行，而不是从可写 App 私有目录执行；原生库是否以独立文件提取，还取决于打包设置，必须核对最终 APK 并在真机验证。[Android 执行限制](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)、[原生库打包方式](https://developer.android.com/guide/topics/manifest/application-element)、[AOSP App 代码策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/app.te)。

完整 Alpine Guest 需要单独审查并实现文件系统虚拟化，向 PRoot 提供路径、目录、元数据、加载器及执行操作，或找到在目标设备上证实可用的系统隔离存储机制。现有 PRoot 的 `--rootfs` 要求真实宿主路径，并用 `ptrace` 改写路径；它的绑定功能不等于宿主资源隔离。项目目前没有这种虚拟文件系统。[PRoot 手册](https://github.com/termux/proot/blob/master/doc/proot/manual.txt)。

真机验收需观察 Guest UID、程序的安装包路径与摘要、App 私有文件与直接 socket 的拒绝、获准的接口调用、全部子进程取消、安装包升级和 Service 被强杀。[合成存储设备探针](acceptance-linux-guest-storage-device.zh.md)还会区分“使用传入的文件 FD”和“借助传入的目录 FD 打开子路径”，记录存储与执行结果，但不会声称 Linux 已运行。存储预检失败必须拒绝任务，不能退回 App UID 执行命令。
