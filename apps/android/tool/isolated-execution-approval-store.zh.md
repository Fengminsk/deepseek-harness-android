# 隔离执行审批历史

中文 | [English](isolated-execution-approval-store.md)

[`IsolatedExecutionApprovalStore`](../android/app/src/main/java/com/minnnng/dsh_android/IsolatedExecutionApprovalStore.java) 是内部[`IsolatedExecutionPolicyOwner`](isolated-execution-policy-owner.zh.md)的 App 私有持久化适配器。它从拒绝全部能力的版本 1 策略开始，把后续范围和审批标识写入带校验和及前后关联的历史；重新打开后只返回拒绝全部能力的范围。如果最后持久记录的是已授权范围，重新打开时先写入新的撤销版本。恢复过程不会重新激活中断或结果不确定的授权。存储器不读取模型文本，也不接受客体 Binder 调用。

调用方提供 App 私有根目录内已存在的目录和目录同步操作。文件锁确保一次只有一个写入者。每次变更都通过已同步的临时文件、原子替换和目录同步重写有界历史；重新打开时清理未发布的临时文件。历史最多 256 次变更、总计 1 MiB，每个范围最多 16 KiB。损坏、陌生的持有者或会话、未解决的文件系统失败、容量耗尽或并发写入者都会阻止准入；不会悄悄重置既有证据。历史中已完成的审批标识不能再次使用。

可信 App 界面必须先核实某次具体的用户选择，再用新的 UUID 调用 `prepareTrustedUiApproval(next, approvalId)`。随后 `PolicyOwner.replace(next)` 消耗这一次准备的决定，同步持久化完全相同的范围，之后范围才生效。缺少匹配决定的授权变更会被拒绝。`IsolatedScriptRunController.newPolicyOwner` 打开该存储器，把唯一策略持有者绑定到一次性脚本回执存储，并返回 `ApprovalHandle`；文件与网络宿主运行会拒绝并非该工厂签发的持有者。唯一的授予 API `approveTrustedUiChoiceForRun` 还把持有者绑定到一个规范运行 ID。内部原生调用方必须先在 `IsolatedExecutionApprovalInbox` 登记精确的待审请求。Flutter 可展示完整的 App 私有工作区路径、相对可读写范围、域名、额度和有效期，但不能提交新权限范围。前台 `MainActivity` 的确认动作通过独立的原生 Binder 消息传递待审挑战标识；普通 JSON-RPC 调用不能授予权限。存储器记录这一决定，但无法独立证明用户确实点击。当前尚无生产调用方登记此类请求，因此界面显示空状态；仪表测试使用合成审批。

关闭存储器会撤销它创建的持有者。进程终止会释放文件锁；重新打开时会验证完整历史，并在返回持有者前写入拒绝全部能力的版本。若损坏、容量或 I/O 结果不确定导致撤销无法持久记录，重新打开会拒绝继续工作，等待人工检查。该记录不会恢复存活的租约、限制 App UID Shell，也不会启用原版 PTC／工作流工具。新的审阅界面、原生确认和存储路径仍需在设备上验收，才能交给生产脚本请求使用。

运行 `node apps/android/tool/acceptance-isolated-execution-approval.mjs` 可在宿主测试新审批准备、单持有者锁、审批标识重放、模拟进程重启时的撤销、同步结果不确定、历史损坏、临时文件清理及容量边界。运行 `node apps/android/tool/acceptance-isolated-execution-approval-inbox.mjs` 可检查精确范围展示、重复与过期挑战拒绝、一次性授权、撤销及超时。这些是宿主文件系统测试，不能充当 Android 断电或真机执行证据。
