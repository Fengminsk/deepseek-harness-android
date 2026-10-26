# ARM64 候选版的可选 Android 共享内存模式

[English](SHMEM.md) | 中文

锁定版本的 Termux PRoot 已能在不启用 libandroid-shmem 跨实例共享时，通过
`--sysvipc` 处理单个 PRoot 实例内的 System V IPC。该库针对另一种带键跨实例
共享模式，并非运行普通 Shell 的前提。上游实现把键软链接放在 `_PATH_TMP`，
这不是已验证可供 Android 隔离 UID 写入的位置；创建键时也可能无限重试。

`build.ps1` 校验固定版本的 PRoot、talloc 与 libandroid-shmem 源码包，解压到
脚本拥有的缓存目录，再运行 `patch-shmem-private.py`。补丁只接受两个固定
SHA-256 对应的源码版本。它改用 `DSH_SHMEM_KEY_DIR`，要求该目录为绝对路径、
属于当前进程 UID、最终路径不是软链接且不向同组或其他用户开放；创建键最多
重试 32 次。PRoot 的跨实例共享模式**默认关闭**，同时提供
`DSH_ENABLE_LIBANDROID_SHMEM` 与 `DSH_SHMEM_KEY_DIR` 才会尝试开启，并继续
尊重 `PROOT_DONT_SHARE_LIBANDROID_SHMEM`。候选二进制静态链接补丁后的库，
运行时还依赖 Android 的 `libandroid` 与 `liblog`。

当前结果只说明候选版可以编译并重复得到相同字节，**不说明手机上 IPC 已可用
或具备隔离能力**。App 尚未连接启动器，隔离进程也可能无法写入 App 私有目录。
现有目录检查尚未通过可信目录描述符消除所有父路径竞争。后续启动器必须为
单次运行提供隔离 UID 真正可用的私有目录，以无路径竞争的方式校验，并只在
获准任务确实需要时开启该模式；还需在普通无 Root 手机上验证拒绝、清理和
完整进程树回收。完成这些检查前，不向 Agent 开放带键共享模式。

主机检查：`python -m unittest apps.android.tool.linux-proot-candidate.test_patch_shmem_private`。
构建产物只保存在 `.cache/android/linux-proot-source/build-arm64-v8a/`，
不会打入 APK。
