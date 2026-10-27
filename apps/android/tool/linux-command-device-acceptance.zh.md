# Linux 命令真机验收

[English](linux-command-device-acceptance.md) | 中文

## 范围

[`LinuxCommandAcceptanceInstrumentation.kt`](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/LinuxCommandAcceptanceInstrumentation.kt) 在普通无 Root Android 设备上检查内部固定 Linux 风格命令服务。它检查原生服务，不验证已单独注册的 `android_linux` Agent 工具，也不能证明通用 Linux 容器已可用。App 与 AndroidTest APK 必须来自同一源码版本。设备需要 Android 10 或更高版本、已授权 USB 调试，并在测试期间保持可操作。生命周期阶段需要可调试的 App APK，因为诊断命令不能在正式包中运行。

从仓库根目录，在 APK 准备好且已获准使用设备后运行：

```sh
node apps/android/tool/acceptance-linux-command-device.mjs --apk <arm64-debug.apk> --test-apk <arm64-androidTest.apk> --serial <adb-serial>
```

脚本使用 `adb install -r` 安装明确指定的两个 APK，保留现有 App 数据。APK 缺失、设备未授权或不唯一、安装失败、instrumentation 结果缺失、测试列表不完整，以及通过 `adb shell ps -A -o PID,ARGS` 看到固定的 30 秒测试子进程残留，都会使测试失败。两个阶段均通过后，脚本才输出含 APK 哈希与阶段结果的 JSON。不要在用户正操作手机时运行。

## 证据边界

基线阶段将子进程 `id -u` 输出与 Binder 客体 UID 比对，并确认它与 App UID 不同。命令完成还要求隔离服务无法列出 App 私有目录、无法直接创建网络套接字。SHA-256、字节数和行数现在使用 APK 安装的固定参数 Bionic 可执行文件；真机用例核对 APK 安装的可执行文件身份、64 KiB 输入上限处的准确结果、隔离 UID 和直接子进程收尾。排序与字面量过滤仍使用固定的系统 Toybox 命令，包括无匹配结果。App 持有的 RPC 管理器必须以隔离 UID 返回正确 SHA-256 结果，并在准入前拒绝测试专用命令 ID 和多余的 `cwd` 字段。内置可执行文件自身拒绝未知模式与超过 64 KiB 的输入，策略在分发前也执行同样的大小限制。

生命周期阶段以仅限调试包的固定命令单独检查 APK 内原生字节计数工具，并检查收到已验证的子进程启动 Binder 回执后的取消、客体超时、输出溢出及隔离服务死亡。脚本紧接着扫描固定的 30 秒测试子进程；如果阶段耗时长到泄漏的子进程可能自然退出，测试也会失败。此扫描只覆盖具名诊断子进程，不能证明任意 Shell 程序的整棵进程树会被回收，也不能证明软件包安装、Alpine／PRoot 客体、文件／网络代理、后台存活或 Android 系统包管理器升级。对应能力在取得各自真机证据前保持关闭。
取消与客体超时断言还要求收到隔离客体的终态回执和 UID，而不只依据 App 侧取消请求就判定已完成。宿主时限到期且收不到回执时，结果属于回收未确认。

在同一命令末尾加 `--image`，可在命令阶段完成后运行封口镜像 Binder 通道的 instrumentation。它要求隔离 UID 的成功回执，并验证可写或摘要不符的镜像快照被拒绝。此合成用例不安装也不执行 Alpine。

在同一命令末尾加 `--image-install-fixture`，可在设备上用合成的惰性数据验证镜像存储。此用例检查部分安装被拒绝、重启后的复核和收据篡改被拒绝，随后仅清理自己创建的测试目录。它既不下载也不执行 Alpine，不能证明真正的 Linux 客体可以启动。

## 可选的隔离客体存储探针

在同一命令末尾加 `--guest-storage-probe`，使用**同一源码构建的调试版 App 与 AndroidTest APK**。探针服务仅存在于调试包。测试只使用随机合成标记，通过只读文件描述符和已封口的 `SharedMemory` 传递；不读取用户文件，不开放 Agent 工具，不下载网络内容，也不安装或运行 Alpine／PRoot。它分别尝试直接读取 App `noBackupFilesDir` 下的专用测试文件、在该目录创建文件、读取和写入传入描述符、读取和写入共享内存，以及在隔离服务的 `cacheDir` 创建、读取、执行临时文件；还会尝试对合成临时文件建立只读可执行 `mmap`，但不会调用映射的字节。执行用例仅为执行后立即退出的合成 `/system/bin/sh` 脚本。这些只是 W^X 观测，不能证明 Alpine ELF 或 PRoot 加载器可运行。测试只清理自身 UUID 命名的文件，保留原有 App 数据。

主机验收要求：直接读取或写入 App 私有目录均为 `denied`；传入只读 FD 可读为 `allowed`、可写为 `denied`；已封口共享内存可读为 `allowed`、可写为 `denied`。缺失结果、无法验证隔离 UID 或出现意外权限时，测试失败。临时目录的三个结果分别报告 `allowed`、`denied` 或 `untested`，不参与上述边界断言。`untested` 表示该操作未执行或结果无法确认，不能当作系统拒绝。例如隔离 UID 无法创建 App 缓存文件时，后续执行能力就没有被验证；这不能推断另一个经代理提供的客体目录是否可执行。

结果只适用于受测设备和系统版本，不能证明 PRoot 能挂载或运行 Alpine，也不能证明任意文件代理安全或客体后台长期存活。Android 官方说明 `isolatedProcess` 服务不拥有应用本身的权限，AOSP 定义了 `isolated_app` SELinux 域；这些资料只是探针设计依据，不能代替真机结果。参考 [Android 服务清单](https://developer.android.com/guide/topics/manifest/service-element)、[AOSP SELinux 概念](https://source.android.com/docs/security/features/selinux/concepts) 与 [Android SharedMemory API](https://developer.android.com/reference/android/os/SharedMemory)。

\n