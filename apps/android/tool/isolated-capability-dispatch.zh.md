# App 侧隔离能力调度

[English](isolated-capability-dispatch.md) | 中文

`IsolatedCapabilityBinderDispatch` 是未来隔离 PTC／工作流执行器的 App 侧传输接口。目前它没有接入诊断用 guest 或面向模型的运行时；在脚本执行器及其完整隔离得到验证前，程序工具继续保持不可用。

所属 App 服务在其生命周期内创建一个 `IsolatedCapabilityJournal`，并将同一实例交给每个获准的会话。接纳任务前必须检查日志的启动恢复结果；未完成或结果不确定的任务不得重放。App 决定工作区根目录、不可变的读写路径策略、每个授权目标及操作、所属任务 ID，以及最长五分钟的租约。guest 只拿到随机授权 ID 和操作、运行 ID、每次运行的 256 位随机值；不会拿到文件路径、工作区根目录、凭据或 Android `Context`。

App 为会话绑定一个不对外导出的新隔离服务，并通过该服务的 Messenger 发送一次授权信息。首次 HELLO 核对随机值、运行 ID 和上报 UID 后，固定实际的 `Message.sendingUid`。后续调用和 FINISH 必须来自同一个 UID；App UID、UID 不符、运行 ID 或随机值错误、Bundle 字段多余、并发调用或格式错误都会终止该任务。guest 上报的 UID 不能代替 Binder 记录的发送方 UID。Binder 回调和每次能力调用都在专用后台线程处理；工厂接纳、发送授权、绑定生命周期和取消操作也必须由调用方安排在后台线程，因为其审计路径可能写磁盘。guest 只能指定 App 发出的授权 ID 和操作；`IsolatedCapabilityBroker` 再次校验、消耗一次性调用 ID，并持久记录接纳、结果和终态。文件操作经由 `IsolatedCapabilityWorkspace`，其打开和写入被限制在 App 私有目录内。FINISH 只提出完成结果并进入 STOPPING，不写入 `COMPLETED`。调度器发回 STOPPING 让 guest 退出；只有已绑定 Binder 死亡、且 App 侧完成绑定清理后才持久写入 `COMPLETED`。若在绝对租约到期前无法确认死亡或清理，则拒绝成功并进入失败终态。取消和意外死亡会撤销任务；无法证明提交结果的在途编辑仍按代理语义报告 `COMMIT_UNCERTAIN`。

本模块本身不绑定服务、不独立取得 ServiceConnection 的 UID、不运行脚本、不代理网络，也不隔离现有 App UID 下的 Shell 和插件工具。生产调用方还须拥有 ServiceConnection，提供可在取消或超时时解除绑定并停止 guest 的清理回调，保留日志实例，并在取消或绑定失败时关闭调度器。调度器在后台线程清理绑定、监听已绑定 Binder 的死亡，并用独立计时器处理 guest 忽略 STOPPING 的情况。FINISH 后出现含糊的断连，只等待到租约截止，不会据此确认成功。Binder 发送方归属、隔离 UID 分配、App 私有目录限制、进程死亡和真实编辑结果不确定性，都需要真机验收后才能向模型开放。
