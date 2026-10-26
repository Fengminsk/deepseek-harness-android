# Android 隔离能力代理

进程终止后的审计核对和容量维护见 [能力日志恢复检查](capability-journal-recovery.zh.md)。`:agent` Service 在启动时检查应用私有日志；审计不可读或有未决结果时拒绝文件授权运行。这是宿主接线，不代表设备验收通过。

App 进程为每次拟执行的 PTC 或工作流创建一个 `IsolatedCapabilityBroker`，并在私有审计日志中绑定任务 ID。它发放随机运行 ID 和最多 32 个随机授权句柄。仅 App 可见的 `GrantSpec` 指向应用私有工作区内的一个相对文本文件，或以 `/` 结尾的已命名子目录，并指定 `READ`、`SEARCH`、`EDIT`、`WRITE` 中允许的操作。隔离进程按发放顺序收到不透明句柄，不能自行选择 App 工作区根、凭据、网络地址、Shell 或未登记工具。仅对内部构造的目录授权，每次调用必须携带 `sub/file.txt` 这样的相对子路径；精确文件授权拒绝该字段。代理重新核对拼接后的工作区相对目标是否处于可读／可写策略内，并将实际目标记入审计。

隔离侧调用格式为 `{runId, callId, grantId, action, boundedArgs}`。App 校验每个 ID 和单调时钟租约，先将准入写入应用私有且已 `fsync` 的 JSONL 日志，再执行获授权的操作，记录结果后才回复。调用 ID 在执行前消耗，重放不能再次编辑。被拒绝的调用也有记录。每次运行最多调用 128 次、租约最长五分钟。日志写入失败会拒绝新工作；若结果记录失败，返回 `AUDIT_UNCERTAIN`，必须检查工作区，不能盲目重试编辑。

`IsolatedCapabilityWorkspace` 使用现有安全目录写回实现绑定。读取返回最多 64 KiB 的 UTF-8 文本与 SHA-256 修订号；搜索返回有上限的位置和摘要。`EDIT` 执行文本替换；`WRITE` 发布完整且有大小上限的 UTF-8 文本。两者均要求精确文件可写授权及预期 SHA-256 修订号。`WRITE` 使用 `missing` 时只能新建尚不存在的文件；版本变化返回 `STALE`。两者都在锚定的工作区目录内暂存、同步并原子重命名。写回层还会拒绝路径中的 `.git`、`.agents`、`.codex`、`.aws`，即使调用方绕过代理也一样；生产文件提供方无法核实目标只有一个硬链接时会拒绝操作。取消、超时和隔离进程死亡只能关闭运行一次。若写入期间发生终止且可能已经提交，返回 `COMMIT_UNCERTAIN`，不会冒充成功。授权目标只记录在应用私有日志中；传给隔离进程的句柄不含文件名。

该目录调用协议只是内部、失败即拒绝的受限子集，不是可用的通用可写根功能。`IsolatedRunNativeBridge` 准入时仍拒绝全部目录授权。硬链接计数检查与锚定的基础属性核对尚不能完整防御恶意同 App UID 写入者对路径名发起的竞争。当前也没有目录列举或目录创建操作。子路径会拒绝穿越、绝对路径、相似前缀根、控制字符、过深和过长；文件操作仍受 SHA-256 版本、调用额度、取消和持久审计约束。宿主测试只证明代理的路由和拒绝行为，不能证明 Android 文件提供者行为。解决同 UID 竞争假设并完成真机检查前，不得放开原生准入。

这只是宿主绑定协议，不是 PTC 执行器。Android profile 仍禁用原版 Node PTC 和工作流脚本。任意 Node 文件、子进程或网络 API 都能绕开这些句柄，因此不能直接放行。真机还需验证 Android 安全目录提供方、UID 隔离、Binder 死亡、并发编辑、离线执行与重启恢复。恶意同 App UID 写入者仍超出现有写回保障；见[隔离说明](ptc-workflow-confinement.zh.md)。

生产写回要求 `Files.newDirectoryStream` 返回 `SecureDirectoryStream`；否则 `READ`、`EDIT`、`WRITE` 都会拒绝，不回退为基于路径名的打开。[AOSP 安全目录流实现](https://android.googlesource.com/platform/prebuilts/fullsdk/sources/+/refs/heads/androidx-transition-release/android-34/sun/nio/fs/UnixSecureDirectoryStream.java)和 [Unix `nlink` 属性视图](https://android.googlesource.com/platform/prebuilts/fullsdk/sources/+/refs/heads/androidx-constraintlayout-release/android-35/sun/nio/fs/UnixFileAttributeViews.java)说明了预期机制，但不能证明当前手机或厂商文件系统的实际行为。提供方检查以及原有读／编辑兼容性仍需真机验收。

独立的 `FileBrokerProviderInstrumentation` 在 `:agent` 进程检查真实的应用私有 Android 文件提供方，覆盖安全目录流类型、`unix:nlink`、带版本的 `READ`／`EDIT`／`WRITE`、过期版本拒绝、取消，以及符号链接和硬链接隔离。探针只在测试应用的私有 `filesDir` 下生成临时文件，完成后清理。离线解析测试命令是 `node --test apps/android/tool/acceptance-file-broker-provider-device.test.mjs`；生成对应的应用和 AndroidTest APK 后，可用 `node apps/android/tool/acceptance-file-broker-provider-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only` 在不操作手机的情况下检查包身份和 Agent 进程登记。得到手机测试授权后，去掉 `--preflight-only` 并用 `--serial` 选择设备；`--allow-existing` 明确允许替换已安装应用。离线测试或 APK 预检通过不等于真机验收；还需探针在手机上通过，并核查 UID、重启和并发边界，才能宣称代理在手机上可用。
