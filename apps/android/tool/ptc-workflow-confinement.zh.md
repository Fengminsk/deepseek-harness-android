# Android PTC 与 Workflow 的进程隔离

本文说明 Android 配置为何拒绝模型编写的 PTC 程序和工作流脚本。Android App 内嵌的 Node 宿主以应用 UID 运行。这个 UID 让其他应用无法直接访问本应用数据，但不会把子程序限制在选定工作目录，也不会阻止它读取应用私有文件。

原版 [`NodePtcRuntime`](../../../packages/ptc-runtime/ptc-runtime-node/src/index.ts) 允许直接使用 Node 文件系统、网络和子进程 API。在 `workspace-write` 模式下，它先调用 `ctx.sandbox.confine()`，再启动执行程序。原版 [`sandbox-local`](../../../packages/sandbox/sandbox-local/src/index.ts) 只为 Linux、macOS 和 Windows 选择隔离执行器；平台没有执行器时会拒绝运行。Android 当前没有对应执行器。把策略改成 `danger-full-access` 会跳过隔离，不能视作实现了原版 PTC 行为。

Android 配置保持 PTC 提供方、工作流引擎和工作流工具为禁用状态。[`stage-preset.mjs`](stage-preset.mjs) 拒绝打包时启用这三项。[`host-guard.mjs`](../runtime/host-guard.mjs) 在原生宿主启动前检查合成配置，拒绝配置目录和主目录覆盖、常规模块别名及预设内的激活项。Android 运行时还使用 `pluginManager.protectModules` 保留这三项已打包的模块标识，普通插件管理操作也不能在启动后开启它们。这些检查只验证已打包的配置和模块标识；它们无法隔离任意第三方插件代码，也无法阻止另一个模块自行实现类似行为。

Android 上实现这项能力需要将执行程序隔离于 App UID，通过明确的桥接接口访问已授权工作文件和工具调用，限制输出，并在结束时确认全部子进程退出。App 已声明一个 [`isolatedProcess` Service](https://developer.android.com/guide/topics/manifest/service-element)，并提供仅限 App 调用的 `runtime.isolation.probe`：宿主通过 Binder 授予不超过 256 KiB 的只读普通文件，检查 Binder 发送方 UID、内容摘要及其是否能通过路径读取另一份 App 私有标记，然后再次授予只读文件描述符，验证最多 64 KiB 的严格 UTF-8 文本回传。[`IsolatedWorkerBridge`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedWorkerBridge.kt) 只接收 App 已打开的文件描述符，不接受工作进程选择的路径；每次请求都有独立标识、五秒期限，失败时先发送取消消息再解绑。App 可对明确选中的工作目录相对路径文件生成快照，包括嵌套目录，并将有界文本描述符授予独立 UID 的工作进程进行字面编辑或搜索。搜索返回有界的行预览、位置、截断标记与快照版本；编辑由 [`IsolatedWorkerWriteback`](../android/app/src/main/java/com/minnnng/dsh_android/IsolatedWorkerWriteback.java) 按 SHA-256 版本写回。无效 UTF-8、超限输入或输出、无效路径及取消均被拒绝，编辑还会拒绝超量替换和过期版本。诊断探针覆盖编辑路径；新增代码通过主机 Java 测试和 Android Kotlin 编译，设备执行仍未验证。桥接写入在本进程的多个写入器之间串行化，但其他同 UID 写入者仍可在最终版本检查与重命名之间竞争，或在验证后替换父目录。这项传输能力只是基础，不是 PTC 执行器。当前 Node 子进程提供方和 PTC 控制通道仍不能通过该 Service 启动，通用工作目录操作和工具回调尚未通过 Binder 桥接，也无法约束后代进程。独立的 Android JavaScript 隔离环境可以考虑承载工作流脚本的受限子集，但不等同于 PTC 所承诺的直接 Node API。

启用原版能力前，需要在 Android 设备验证独立 UID 启动、允许的工作目录读写、拒绝访问应用私有文件及工作目录外文件、受控的网络与子进程行为、嵌套工具的审批和记录、取消及超时后的后代进程清理、持有者释放和重启恢复。主机上的配置拒绝测试不能证明这些设备行为。
