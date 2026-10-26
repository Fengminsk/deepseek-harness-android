# Linux 客体存储能力设备探针

[English](acceptance-linux-guest-storage-device.md) | 中文

调试 APK 包含 `DebugGuestStorageProbeService`、仅用于调试的原生 `openat(2)` 观察器和 `GuestStorageProbeInstrumentation`。此脚本首先检查主包与 AndroidTest 包的指纹、包名、签名证书、原生观察器、私有隔离 Service 声明和 Agent 进程中的测试入口。`--preflight-only` 不使用手机；签名预检不能证明 Android 存储行为。

用户授权设备测试后，脚本安装两个 APK，并让合成测试记录隔离进程直接读写 App 私有路径、使用 App 传入的只读文件描述符、通过已传入的目录描述符执行子路径 `openat` 读写、使用封存共享内存，以及在隔离临时目录中创建、读取、执行映射和执行文件的结果。八项隔离与只读传递结果必须符合预期。目录 FD 只有在额外证明子路径操作安全后才可能作为客体文件系统根目录；此探针要求目标设备拒绝子路径打开。临时能力分别报告为 `allowed`、`denied` 或 `untested`，不会被当成客体执行成功。测试只使用随机标记，并删除其精确创建的文件。已有安装时，脚本要求对获授权的测试显式传入 `--allow-existing`。

```sh
node apps/android/tool/acceptance-linux-guest-storage-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --preflight-only
node apps/android/tool/acceptance-linux-guest-storage-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --serial SERIAL
node --test apps/android/tool/acceptance-linux-guest-storage-device.test.mjs
```

[Android 16 隔离应用策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/isolated_app_all.te)允许使用 App 已打开并传入的文件描述符，但禁止隔离进程直接打开 App 数据文件。目录 FD 的观测旨在排除将“使用已打开 FD”误认为“可以遍历 rootfs”的情况。临时存储与执行状态将决定当前隔离 rootfs 暂存方案在目标设备上是否可行。即使临时能力显示 `allowed`，也不能据此证明 PRoot 隔离、进程树退役、文件与网络仅经代理访问，或 Linux 镜像可供正式分发；通过这些独立验收前，通用 Linux 客体和面向模型的命令仍不可用。
