---
kind: reference
title: Windows Linux 客体验证
---

# Windows Linux 客体验证

[English](README.md) | 中文

此宿主测试将准备好的 TinyEMU 源码和生产 `linux_vm_engine.c` 编译为 Windows x86_64 库。JVM 适配器复用 `LinuxVmConsole`，显式传入内存磁盘，并记录有大小限制的串口诊断。Windows 头文件将未使用的网络回调类型映射到 Winsock 声明，不向客体提供网络设备或宿主目录。测试不编译 Android 文件发布器，也不验证 Binder 隔离、服务退役、Android 存储权限或 App 启动。

[构建器](../build-tinyemu-host.mjs)要求已有校验过的 TinyEMU 准备记录、本机 JDK 和固定的 [LLVM-MinGW 便携归档](https://github.com/mstorsjo/llvm-mingw/releases/tag/20260908)。将 `llvm-mingw-20260908-ucrt-x86_64.zip` 及其解压目录放到 `.cache/android/windows-host-tools/`；SHA256 必须为 `1bcf74d06b724aeecaa6412ca85f5b26fb1da770e7cdcefa9263c9c5c3ad34b6`。无需系统安装或 WSL。构建记录包含源码、JNI、Java、编译器与库文件标识。

在仓库根目录执行：

```powershell
node apps/android/tool/build-tinyemu-host.mjs '--jdk=C:\path\to\jdk'
node apps/android/tool/verify-tinyemu-host.mjs smoke
node apps/android/tool/verify-tinyemu-host.mjs alpine
node apps/android/tool/verify-tinyemu-host.mjs lifecycle
```

[运行器](../verify-tinyemu-host.mjs)需要已准备的开发客体资产，`alpine` 还要求校验过的镜像构建输入。`smoke` 验证真实客体启动及两次运行之间的工作区保持；`alpine` 在客体内创建 ext2 镜像，安装锁定的离线软件包，启动该镜像，实际执行 Python、线程、随机数、SQLite、SSL、子进程、git、curl 和文件操作，再使用 `e2fsck -fn` 检查独立、未挂载的只读镜像。`lifecycle` 让已进入的循环超时，并在确认客体输出后取消执行；两者均不发布改动后的镜像，同时核对源镜像保持不变。

每次运行在 `.cache/android/tinyemu-host/runs/` 内使用新目录。报告包含原生状态、客体退出码、哈希和明确的 `androidDeviceVerified: false`。只有客体命令完成且原生执行器关闭后才写出镜像，失败诊断会保留。宿主检查通过不启用产品能力，也不代表手机执行已验收。[运行时说明](../linux-vm-runtime.md)（[中文](../linux-vm-runtime.zh.md)）定义普通 Android 构建排除此执行器和镜像的行为。

## 候选装配

`alpine` 报告将通过的构建、运行时测试和文件系统检查绑定到准确的系统镜像、离线软件包输入及解释器构建记录。准备后发生变化的原生代码、控制台或软件包输入会被运行器拒绝。缺少这些绑定的旧报告不能用于候选装配。

`alpine` 通过后，先打包当前对应源码，再将它打印的报告路径传给[候选装配器](../stage-alpine-vm-candidate.py)。使用打印的候选目录进行独立校验：

```powershell
python apps/android/tool/package-linux-vm-sources.py
python apps/android/tool/stage-alpine-vm-candidate.py --host-report <report.json> --source-manifest .cache/android/tinyemu-probe/linux-vm-corresponding-source.manifest.json
python apps/android/tool/stage-alpine-vm-candidate.py --verify <candidate-directory>
python apps/android/tool/test_linux_vm_candidate.py
```

每个候选在 `.cache/android/linux-vm-candidates/` 下占用新目录，包含 `assets/linux-vm`、独立源码归档及主机证据。系统盘使用已测试的 Alpine 镜像，不复制旧演示磁盘。装配器重新计算复制文件的哈希，只有校验后才写入 `candidate.json`。复制失败时保留不带成功记录的部分文件。既有样例和候选保持不变。

候选装配不会修改 Gradle、安装 APK、启用模型工具或认证 Android 执行。镜像仍没有网络设备；curl 测试验证本地执行，不代表联网。发布前仍须完成设备生命周期及生产 Agent 集成验收。
