# Linux 客体暂存的进程死亡处理

[English](linux-guest-staging-recovery.md) | 中文

隔离 Service 可能在发布一次运行的 rootfs 后、执行 `Staged.close()` 清理前被强制终止。下次启动的隔离 Service 可能拥有不同 UID。`LinuxGuestStagingPreflight` 不假设新 UID 可以打开或删除上次的目录，也不会放宽私有目录权限来清理。解包封存镜像前，它要求缓存目录可直接访问，拒绝已有的 `linux-guest-root-*` 同级目录，并检查能否创建和删除一个空目录。缓存不可访问或存在残留时会拒绝暂存，不会复用或删除旧目录；只要残留可见，后续顺序重试不会继续发布新目录。这是失败约束，不代表已回收占用空间。

这个预检仍不足以让当前方案运行。[Android 16 隔离进程 SELinux 策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/isolated_app_all.te)禁止隔离进程打开 App 数据文件，但允许使用已经打开并传入的文件描述符。[App 策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/prebuilts/api/202404/private/app.te)也将隔离进程排除在普通 App 私有目录与文件创建权限之外。因此，当前在 `cacheDir` 中暂存预计会在原生 Android 16 设备上失败；Java 主机测试和 Android 编译通过不能证明客体文件能够落盘。是否存在符合策略的按运行隔离存储方式，需要在目标设备上结合实际 SELinux 和 UID 行为验证。

当前 Service 没有原生 PRoot 启动、模型可调用的 Shell 或任务成功发布。后续实现必须明确存储所有权以及强杀后的清理方式，不能让客体获得不受限制的 App 私有数据访问；启用可执行 userland 前要在设备上验证正常结束和强杀两条路径。现有 Binder 负例测试只检查身份和错误交接，不能证明存储恢复。主机检查命令：`node apps/android/tool/acceptance-linux-guest-staging-preflight.mjs`。
