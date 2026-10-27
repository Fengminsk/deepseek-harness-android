# Android APK 升级与 Keystore 真机验收

[English](acceptance-upgrade-device.md) | 中文

## 范围与准备

该测试通过 Android 系统包管理器把旧 App APK 升级到新版。[`UpgradePersistenceInstrumentation.kt`](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/UpgradePersistenceInstrumentation.kt) 会在目标 App 的 `noBackupFilesDir` 写入 64 字节随机文件，并用唯一的 `acceptance/upgrade/<token>` 引用在 `CredentialVault` 保存另一段随机合成值。新版 APK 必须读到完全相同的文件字节，并用原有 Android Keystore 密钥解密合成值。基本测试不会使用真实账号、会话或用户文档；可选 SAF 可读性模式会只读访问已有授权文件。

先准备旧版 App APK、新版 App APK，以及用**新版**源码构建并注册了升级测试的 AndroidTest APK。三个包必须使用同一签名证书，新版 App 的 `versionCode` 必须更大。系统需提供 Android SDK 的 `aapt2`、`apksigner.jar`、`adb` 与 Java。授权一台设备，并在整个测试期间保持可操作。如果 App 已安装，脚本要求明确传入 `--allow-existing`，且已安装版本必须等于旧 APK 版本。普通 `adb install -r` 会保留包数据；脚本不会调用 `pm clear`、卸载或降级参数。

在仓库根目录、APK 已准备且设备使用已获授权后运行：

```sh
node apps/android/tool/acceptance-upgrade-device.mjs --old-apk <old-arm64-debug.apk> --new-apk <new-arm64-debug.apk> --test-apk <new-arm64-androidTest.apk> --serial <adb-serial> --allow-existing
```

脚本在安装前计算三个 APK 的哈希并核对包名、版本号、签名证书以及准确的测试 runner 声明；随后安装旧 App 与新版测试包，写入合成数据，执行新版 App 的 `adb install -r`，检查文件与解密结果，最后只清除本次生成的合成数据。每个阶段还会比较已持久授权的 SAF 只读 URI 数量与身份摘要；除非启用下述选项，空授权集合也是允许的。脚本不会打印原始文档 URI。验证失败时不执行清理。写入前，标准错误会打印测试 token，方便升级失败后定位可能保留的文件；成功 JSON 记录 APK 哈希与各阶段结果，不打印合成密钥原文。

## 可选真机观察

对于经过 R8 压缩的正式版，还需传入 `--old-test-apk <旧版配套-androidTest.apk>`。每版 App 与对应测试包必须来自同一次联合构建、使用同一份映射。运行器使用旧版配套测试包写入／保持数据，升级 App 后才安装新版测试包。把新版正式测试包提前装到旧版目标上可能导致混淆辅助方法不存在，不能作为生命周期验收证据；两版测试包都必须支持本次请求的可选观察。

正式版验收构建会保留仅测试 APK 使用的共享 Kotlin 支持类，包括用于排序 Session 文件清单的比较门面类，以及失败报告使用的异常门面类。修改这些 keep 规则后，必须一起重新构建目标 App 和 AndroidTest APK；只重编测试包无法恢复目标 App 中被移除的类。即使联合编译成功，旧版种子阶段缺少依赖也意味着该项观察仍未验证；不得改用新版测试包，或在没有成功取得旧版基线时声称 Session 字节已保留。

`--require-saf-grant` 要求旧版 App 已安装、传入 `--allow-existing`，并且运行前用户已通过 App 获得至少一项持久 SAF 读取授权。没有授权或升级前后授权集合变化时，验收失败。这检查授权元数据，不证明文档当前仍可读取。

`--saf-readable-path <relative/path.txt>` 进一步要求已安装的旧版 App 拥有 SAF **目录**持久读取授权，并传入 `--allow-existing`。先在某个已授权目录放置一份不超过 16 MiB、运行期间保持不变的普通文件，参数填写相对于该目录的路径。支持中文等 Unicode 文件名和空格；拒绝控制字符、反斜杠、绝对路径及空段或 `.`、`..` 段。传给 ADB 前会对路径编码。该路径在全部已授权目录中必须恰好对应一个文件。探针会在旧版 Agent 进程写入阶段、新版升级验证阶段及清理阶段完整读取文件，比较授权根与文档标识的哈希、字节数及 SHA-256 内容摘要；不会修改文件，也不会输出其 URI、路径或内容。运行期间不要移动/编辑文件或更改授权。该选项自动要求 SAF 授权。例如：

```sh
node apps/android/tool/acceptance-upgrade-device.mjs --old-apk <旧版.apk> --new-apk <新版.apk> --test-apk <新版-androidTest.apk> --serial <设备序列号> --allow-existing --saf-readable-path upgrade-probe.txt
```

`--require-device-offline` 要求 Android 在写入、验证和清理阶段都没有暴露带 `NET_CAPABILITY_INTERNET` 的网络。运行前需断开 Wi-Fi、移动数据和可联网 VPN；USB ADB 仍可使用。脚本不会改变设备的网络设置。该选项仅检查三个时点的系统网络能力，不证明离线会话或请求重放行为。

`--force-stop` 在写入后启动一段停留于旧版 App Agent 进程的 instrumentation。脚本等待明确的就绪状态和对应存活 PID，执行 `am force-stop`，确认该 PID 消失且 instrumentation 退出，然后才升级。该操作会停止 App 全部进程及当前任务，仅在允许中断时使用。未观察到受控进程终止时，脚本会失败，不会报告进程终止通过。

这些选项可与基本命令组合。使用 `--require-device-offline` 时，整个运行过程都应保持断网。

## 证据边界

`--require-session-files` 还会在升级前后核对既有 `noBackup/dsh/sessions` 文件清单及内容的合并哈希。它要求至少存在一份文件，拒绝符号链接，并限制最多 20,000 份文件、512 MiB；仅向设备外输出合并摘要、文件数和字节数。该选项证明这些持久数据经过升级保持不变，不代表已经打开会话或恢复模型请求。

基本测试通过只证明这台设备经过真实包管理器升级后保留了该 App 私有 no-backup 文件，并能解密此合成 `CredentialVault` 项。可选结果分别证明 SAF 授权元数据连续、所选 SAF 文件确实可读且字节未变、三个检查时点无可联网网络，以及通过 force-stop 观察到 Agent 进程终止。SAF 模式只覆盖所选文件，不覆盖每份授权；真实 DeepSeek 账号、对话、后台任务恢复、设备重启和模型请求行为仍需分别真机验收。应保留每次运行的 APK 哈希和各阶段结果；旧版 APK 组合通过，不代表后续修改也已通过验收。
