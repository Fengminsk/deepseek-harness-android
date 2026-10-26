# 隔离脚本执行控制器

中文 | [English](isolated-script-run.md)

[`IsolatedScriptRunController`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptRunController.kt)接收一个由 App 持有的运行 ID、受限的 JavaScript 函数表达式、JSON 输入、1–5000 毫秒执行时限和取消状态。它仍是没有生产调用方的内部设施：Android 的 DSH `run_code` 与工作流 profile 项保持禁用，模型无法调用该路径。纯计算运行没有宿主对象；明确获得 App 持有的策略租约后，可使用受限文件或 HTTPS 宿主调用。guest 本身没有 Node、环境文件或网络 API、计时器或宿主调用 Promise；这仍不等同于 DSH PTC 功能。

App 先在私有 `files/isolated-script-runs` 目录写入 `ADMITTED` 收据，并同步文件和目录，随后才绑定服务。Android 10 及以上使用 `bindIsolatedService` 为每次运行创建具名的隔离服务实例；Android 9 因无法提供同等的逐次绑定属性而拒绝执行。[`IsolatedScriptWire`](../android/app/src/main/java/com/minnnng/dsh_android/IsolatedScriptWire.java)固定协议版本 1、规范 UUID 运行 ID 和随机值、准确的 Binder 字段、脚本和输入输出字节限制，以及一次结果。App 核验 Binder 记录的发送方 UID，要求其不同于 App UID，并与 guest 上报的 UID 交叉校验。协议不传递路径、凭据或权限授权。

guest 在独立工作线程运行[`PtcScriptEngine`](../android/app/src/main/java/com/minnnng/dsh_android/PtcScriptEngine.java)，上报受限大小的结果，然后等待 App 的 `RETIRE` 消息并退出。只有绑定的 Binder 已死亡、`unbindService` 已返回，而且终态收据完成原子替换与目录同步，App 才接受 `COMPLETED`。取消、总时限到期、错误 Binder 字段和 guest 提前死亡均不会发布成功结果。如果截止时间内无法确认 guest 死亡或绑定清理，收据记录 `RETIRE_UNCONFIRMED`，不能视为安全完成。guest 还监听 App 的回复 Binder，App 进程死亡时会自行终止。

[`IsolatedScriptReceipt`](../android/app/src/main/java/com/minnnng/dsh_android/IsolatedScriptReceipt.java)拒绝重复运行 ID。控制器只接受 `:agent` 进程调用，并串行处理启动恢复和持久准入；独立的已准入运行随后可以并行绑定和执行。进程启动后的首次运行将先前只有接纳记录的收据核对为 `INTERRUPTED_UNCONFIRMED`，不重放任务。损坏的收据原样保留并拒绝重放，但不会阻塞其他运行的恢复；恢复期间目录同步失败仍会阻止新任务。这不能证明 App 进程被终止时 guest 的确切执行结果。控制器没有公开调用方或跨进程调度器。每次运行的专用回调线程处理 Binder 消息和服务绑定，主线程繁忙不会延迟 guest 收尾。尚未在 Android 真机执行此 JNI 路径，因此隔离 UID、Binder 时序、原生库加载、终止与取消、并行绑定以及进程死亡行为仍缺少设备证据。

App 将每个规范 UUID 记录在 256 个追加式、带校验和的 ID 文件之一，先同步 ID 记录，再创建可用于绑定的收据。缺少迁移完成标记时，启动过程先把现存收据名称迁入 ID 记录；全部迁入后才原子替换标记并同步目录。标记损坏则拒绝启动。单写者存储在配额检查和恢复之前丢弃未发布的替换临时文件并同步目录，原收据和已接纳 ID 仍然保留。正常接纳在 1,024 个收据文件上限内预留一个替换位置，完整收据另有 128 MiB 配额；新任务需要空间时，只按时间从早到晚删除已有持久 ID 的终态收据。此后无法从该存储读取它们的结果文本，但仍拒绝重复 ID。活动、损坏或无法核实持久 ID 的收据一律不删除。某个 ID 文件损坏时只拒绝其对应分桶的新 ID，不会使该分桶的旧 ID 重新可用。

ID 记录另有 128 MiB 配额，包含分桶文件头。耗尽时以 `CapacityExceededException` 拒绝新任务；截断或损坏的分桶拒绝该分桶的新任务。已接纳 ID 不会删除或重置。任意 UUID 需要持久身份记录，因此仍有有限生命周期容量，但从原先 1,024 次扩大到数百万次。文件或目录同步失败时不能绑定客体；结果不确定的 ID 可能永久占用。主机检查覆盖旧收据迁移、精简、防重放、截断分桶和配额。设备文件系统的持久性及进程死亡行为尚未验证。

主机检查：`node apps/android/tool/acceptance-isolated-script-run.mjs` 检查协议限制、终态分类和持久收据的禁止重放状态；`:app:compileDebugKotlin :app:compileDebugJavaWithJavac` 验证 Android 编译链接。它们不能替代普通无 Root 手机上的执行，以及无限循环、内存压力、取消、错误消息、Binder 死亡和 App 进程死亡的反例测试。
