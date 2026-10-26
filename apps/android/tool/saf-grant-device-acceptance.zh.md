# 进程终止后的 SAF 持久授权读取验收

此设备验收检查真实 Android 文件提供方、App 授权和 `DocumentAccess` 快照阅读器，而非合成 Cursor 测试。测试只读取专用目录根部的 `dsh-saf-acceptance.txt`，内容必须恰为 `Pocket Harness SAF acceptance v1` 加一个 LF 换行。请在专用文件夹中创建此文件，并通过 App 文件选择器授予 Pocket Harness 该文件夹的读取权限。探针要求恰有一个仍可用的持久目录授权包含该文件；不会撤销授权或修改文件。

使用相同源码和签名构建 App 与 AndroidTest APK，取得设备测试授权后运行：

```sh
node apps/android/tool/acceptance-saf-grant-device.mjs --apk <app.apk> --test-apk <androidTest.apk> [--serial <adb-serial>]
```

脚本记录两个 APK 的摘要，核验包名、签名和 AndroidTest instrumentation 清单，以 `adb install -r` 安装并保留 App 数据，拒绝未授权或不唯一的 ADB 设备，在 Agent 进程通过持久授权读取指定文件，强制停止 App，再在新的 Agent 进程中读取一次。两次读取必须保持同一授权标识和相同文件摘要。`am force-stop` 会中断 App 所有进程及正在执行的任务，请勿在用户操作手机时运行。通过结果只证明该设备上这条特定授权与读取链路，不证明任意提供方、撤销授权、离线网络执行或长时间后台任务存活。

宿主解析检查：`node --test apps/android/tool/acceptance-saf-grant-device.test.mjs`。编译和宿主检查均不属于真机证据。
