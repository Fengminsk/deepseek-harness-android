# 隔离脚本宿主调用桥

[English](isolated-script-host-bridge.md) | 中文

`IsolatedScriptRunController.run` 可选接收由 App 持有的文件和网络策略。文件策略包含 App 私有工作区根目录、持久化 `IsolatedCapabilityJournal`、不透明的所有者 ID、精确文件授权和沙箱策略；网络策略包含精确 HTTPS 域名集合、持久化 `IsolatedNetworkJournal`、带截止时间的解析器和固定路由的 TLS 传输层。使用任一能力都必须提供有效的 `IsolatedExecutionPolicyOwner`，由它唯一的一次接纳回调持久写入一次性脚本回执。控制器在绑定隔离服务**之前**核对授权、精确域名以及分别计算的文件和网络调用额度是否处于已接纳的租约范围内。只有网络能力时无需文件工作区或文件授权。未提供两种策略时，V8 只接收输入值，没有宿主对象。所有者不得从模型文本重建这些策略，也不得把该重载直接开放为模型工具。

JavaScript 函数接收 `(input, host)`。`host.grants` 只包含随机文件授权 ID 和动作，不包含路径；只有网络能力时它为空。`host.call({action, callId, grantId, ...})` 发起同步 Binder 请求，`READ`、`SEARCH` 和 `EDIT` 由 App 侧文件代理处理，路径留在 App 侧并逐次审计。`host.call({action:'HTTPS_GET',callId,url})` 交给 App 侧网络代理：只允许精确列入白名单的 HTTPS 域名，解析地址固定到选定的 Android Network，并逐次审计。请求不能携带请求头、凭据、正文、任意方法、IP 字面地址或其他协议。每次调用都使用由调用方提供的规范 UUID，即使拒绝也会消耗。客体仍没有直接文件系统、Node、子进程或网络 API；目前不支持待完成的 Promise 或 DSH PTC 的具名异步绑定。

客体一次最多等待一个请求，序号严格递增，最多 128 次调用；JSON 请求上限 32 KiB，并携带脚本运行 ID、随机码和自报 UID。App 在派发前核对 Binder 实际发送者 UID、自报 UID、运行身份、字段集合及序号，分别计算文件和网络调用额度。App 返回的 448 KiB 以内结果包含结构化状态和有界数据；这个上限覆盖 64 KiB 文件读取或网络响应按最坏情况转义后的大小。网络文本作为 `bodyText` 返回，非 UTF-8 字节作为 `bodyBase64` 返回；超限正文记为 `RESPONSE_TOO_LARGE`。客体验证对应回复后才恢复 V8。引擎输出仍限 64 KiB，执行时限仍为五秒。取消会撤销两类代理、唤醒等待中的回调，并阻止迟到结果变成脚本成功。文件编辑的 `COMMIT_UNCERTAIN` 或网络调用的 `AUDIT_UNCERTAIN` 都会扣留脚本输出，重试前须检查结果。

脚本返回且没有未完成的宿主调用时，App 才提议完成。只有客体 Binder 死亡、绑定清理、适用的终态审计和脚本回执同步均确认后，运行才可成功。每个文件能力会话用写入锁安排取消与文件替换的先后顺序；如果取消与受阻的重命名重叠，即使重命名稍后完成，运行也记为未确认。宿主工作线程未停稳、清理不确定或审计落盘失败时，脚本输出不会发布。恢复流程既不重建授权，也不重试网络调用。通用 PTC／工作流仍关闭，App UID Shell 不在该隔离客体之内。宿主检查、Android／JNI 和仪器测试编译已运行；隔离 UID、Binder 发送者归属、Android DNS/TLS、文件和网络操作以及进程死亡仍需普通无 Root 手机验收。
