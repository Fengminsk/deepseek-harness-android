# 原生隔离脚本桥接

中文 | [English](native-isolated-execution-bridge.md)

[`native-isolated-execution-bridge.mjs`](../runtime/native-isolated-execution-bridge.mjs) 通过五个私有 Node 到 AgentService 请求承接单次内部 `IsolatedExecutionRun`：`admit`、`execute`、`cancel`、`settle`、`release`。AgentService 在进程内持有每个随机令牌，[`IsolatedScriptRunController`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptRunController.kt) 在返回准入结果前持久记录运行 ID。准入后 15 秒仍未开始的运行会被取消。即使回执已压缩，相同运行 ID 也不能再次准入。准入超时意味着结果未知，不得重试。Agent 进程停止后，未完成回执恢复为 `INTERRUPTED_UNCONFIRMED`，不会重新启动客体。

Node 适配器目前仍只准入文件和网络授权均为空的脚本。App 自有的手工脚本流程另可使用原生授权分支：可信 AgentService 审批回调先安装不可变计划，绑定唯一运行 ID、会话 ID、不透明工作区 ID、程序、输入 JSON、时限及控制器持久化的 `ApprovalHandle`。原生端只接受已批准**精确文件**和精确 HTTPS 主机的更小集合。可以完全去掉一个已批准的能力类别，此类别的调用次数必须为零，也不会建立相应 broker。保留的类别必须沿用批准的调用上限，租约时长也必须与批准值相同。主机桥接按策略租约的预算与时长执行，允许请求声称更小的数值会误导调用方。原生端不从 Node 提交的范围创建授权。批准计划被取出后，原生端先持久准入策略租约与脚本回执，再核对程序和范围；不匹配会取消预留、撤销租约并留下终态回执。如果租约预留在返回前失败，桥接器会在存储可写时为已移除计划的运行 ID 写入取消或不确定回执。待处理计划不能被同一运行 ID 的空授权请求绕开。文件授权仅对应精确路径，动作限于读/搜索或读/搜索/编辑。目录范围在有界目录授权契约落实前明确拒绝。

Android 仪器测试同时检查真实隔离客体成功读取 App 批准的精确文件，以及在执行前拒绝尾斜杠目录授权。目录拒绝会留下终态回执；重建桥接实例后也不能复用该运行 ID。准入目录访问仍需另行审查有界目录授权契约。

目前 App 自有的手工脚本流程（`AgentService.prepareManualRun`）是 `prepareIsolatedScriptApproval` 的可信生产者：UI 审批后先安装与该次运行严格匹配的计划，再由 App 工作线程准入。Agent／模型请求没有对应的审批生产者或 RPC，无法绑定它自己的运行 ID、源码、授权范围与 UI 决定；Node 适配器也明确拒绝非空范围，包括伪造的审批提示。原生手工路径不能视为已打通端到端的模型授权 PTC。拒绝、审批过期和 Service 销毁会清除**尚未准入**的计划，且不写运行回执。这类 ID 之后仍可能被当作新的空范围运行准入，但已丢弃的文件／网络授权不能恢复；若要销毁前就持久烧掉所有 ID，还需要单独设计适用于 Service 销毁流程的持久化方案。一旦计划被 `admit` 取出，即使程序或范围不匹配也会留下终态回执；该 ID 无法再次准入或安装新计划，回执压缩后亦如此。脚本仍在 Android 每次运行独立的隔离 Service 中执行；只有控制器确认客体退出、Binder 清理和终态回执持久化后才返回输出。取消会等待终态，再允许读取回执或释放。执行前回执写入失败会移除令牌、尝试记录不确定终态并禁止重放；不确定的退出不会暴露输出。

这个桥接器是内部计算路径，不是已注册的模型工具。它不支持原版 Node PTC、工作流子级或长时间脚本。在通过[设备与行为验收条件](ptc-execution-design.zh.md#向模型开放之前的验收门槛)之前，模型侧 PTC 入口保持关闭。宿主测试检查传输顺序、拒绝 Node 自授权限、伪造审批提示及批准范围收窄。Android 仪器测试包括真实隔离 UID/Binder 的精确文件读取，以及重建桥接实例后的计划拒绝与重放检查；仅编译或通过宿主测试不能视为真机验收。网络准入仍需单独的设备执行证据。
