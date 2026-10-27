# Linux 命令联网审批

[English](linux-network-admission.md) | 中文

## 模型请求

可选的 [Linux 准入服务](../runtime/linux-network-admission.mjs) 为 `linux_exec` 增加 `networkHosts` 与 `networkCallLimit`。两者必须同时提供：1–32 个不重复的小写 ASCII 公网 DNS 名，以及 1–64 次 HTTPS GET 请求。拒绝通配符、IP 字面量、URL、本地用途域名和尾随点。这些字段仅描述申请范围。省略时命令保持离线；`sandboxPolicy.networkAllow` 不代表用户批准。App 选择的持久化策略独立生效，只读会话仍丢弃磁盘改动。

该路径支持客体 `dsh-fetch` 客户端通过 App HTTPS 代理执行请求，不提供客体套接字、自定义请求头、上传、包管理器或通用 curl/Git 联网。响应正文上限为 64 KiB，重定向仍需匹配已批准的精确域名。产品注册还要求独立的原生／设备验收设置通过，并显式组合联网准入服务。源码测试不会开启该设置。

## 审批与派发

原始 `ApprovalService.request` 负责会话策略及成对的 `approval/asked`、`approval/decided` 事件。专用答复器仅处理本服务创建的同一个请求对象；`never` 策略会在答复器运行前拒绝。答复器向可信原生授权页提交命令、Session、调用 ID、原始审批审计 ID、申请域名、持久化策略和预算。只有该页面持久记录的一次性批准才能返回绑定同一运行及 App 所选网络路由的令牌。没有该原生决定，普通答复器返回 `allowed-once` 也不能授权派发。

原生决定返回后，Node 核对原始决定记录并刷新 Session 到磁盘。保存失败、调用者取消、实时工具注册被替换或持久化策略变化，都会撤销尚未使用的原生授权。恢复检查完成后、消费令牌之前，还会再次核对实时 ToolRuntime 执行及策略。模型无法获得令牌。延后记录的上下文保留原生审批 ID、DSH 审计 ID、运行 ID、精确域名、路由、命令哈希及预算。

`native.linuxVm.network.review` 接收 `id`、`sessionId`、`callId`、`approvalAuditId`、`command`、`timeoutMs`、`persistChanges`、`exactHosts` 与 `networkCallLimit`。批准响应包含匹配的身份、`outcome:"allowed-once"`、UUID 格式的 `approvalId` 和 `token`，以及有长度上限的路由摘要。`native.linuxVm.executeNetwork` 使用未变更的命令字段、`approvalToken` 和 `approvalAuditId` 消费授权，不把重新提交的域名清单当作权限。原生准入独立核对已审阅方案和路由，并向 VM 管理器提供已经准入的租约。

## 取消与证据

`native.linuxVm.network.cancelReview` 撤销指定的待审阅请求或未使用授权，并确认相同的运行与 Session 身份。原始 DSH 取消可能先于答复器结束，但工具仍等待原生审阅及撤销完成。撤销结果无法确认时，联网审批服务停止接受新请求。令牌消费后，取消与未知执行结果遵循[既有 Linux 回执规则](linux-vm-runtime.zh.md#持久化与失败)；取消请求不会撤回已发布的文件或先前网络影响。命令不会自动重放。

定向宿主检查命令为 `node --import tsx/esm --test apps/android/tool/linux-network-admission.test.mjs apps/android/tool/native-linux-network.test.mjs`。它使用真实 ApprovalService、ToolRuntime、AgentLoop 与 JSONL Session 存储，配合模拟原生传输，包含[已录制的 Session 投影](expected/linux-network-approval.expected.json)。这些检查不证明原生 UI 决定、Binder UID 绑定、路由选择、真实 HTTPS 请求或锁屏行为；这些仍要求已接受的 Android 构建产物和设备证据。

联网执行回执包含 `approvalCleanupConfirmed`。持久授权收尾无法确认时，回执保留实际命令状态、输出及发布事实，同时增加 `needsReview:true` 与可见说明。Node 执行服务停止后续命令；即使取消操作替换即时工具结果，延迟写入的 Session 回执也会保留此失败。不要重试命令，也不要据此认定已提交的影响被撤回。缺少收尾字段表示原生响应不完整，不代表已确认。
