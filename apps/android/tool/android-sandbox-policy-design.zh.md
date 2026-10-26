# Android 执行沙箱策略：可写路径与网络

中文 | [English](android-sandbox-policy-design.md)

## 决策与现状边界

未来 Android PTC／工作流脚本采用**类似 Codex 的策略约束执行环境**：独立隔离客体、明确的读写授权、单独控制的网络能力，以及执行副作用前由 App 审批。这是实施设计，**不是已启用的模型调用功能**。Android profile 仍禁用 `ptc-runtime`、`workflow-ptc`、`tool-workflow` 和 `preset-ptc`；[执行验收门槛](ptc-execution-design.zh.md)仍然必须满足。隔离 V8 客体已有内部的策略租约[文件调用](ptc-capability-broker.zh.md)和[精确域名 HTTPS 调用](isolated-network-broker.zh.md)、持久准入及单次运行的 App 审核队列。生产模型请求尚未调用它，设备隔离效果仍未验证。

不能把这个提案等同于当前 DSH 的 `sandbox-policy`：原版 `read-only`、`workspace-write`、`danger-full-access` 模式**只约束文件副作用**。原版 Node PTC 提供方允许直接使用 Node 文件系统、网络和子进程 API，具体限制取决于选定的操作系统沙箱；Android 没有对应 runner。Android profile 当前给既有文件工具配置 `workspace-write`。普通模型调用中的 `android_shell` 默认关闭；只有明确启用的内部迁移模式才允许它在逐次审批后以 App UID 执行，且**没有操作系统级的工作区限制**。UI 不得暗示它已经受下述沙箱保护。参见原版[策略](../../../packages/sandbox/sandbox-policy/README.zh.md)、[Node PTC 提供方](../../../packages/ptc-runtime/ptc-runtime-node/README.zh.md)和 [Android profile](../runtime/cordis.patch.yml)。

拟定边界只适用于内置的隔离脚本客体，不约束可信 App 代码、App-UID Shell 命令、装入 Host 的第三方插件、可执行配置或插件安装脚本；这些需要各自的策略与信任决定。不能仅凭一个客体被隔离就宣称整个产品都在沙箱中。

借鉴的是**控制维度分离**，不是复用 Codex 内部实现。Codex 官方文档把可写根、审批策略和命令网络权限分开；`workspace-write` 默认网络关闭，目标域名规则还需要独立的网络约束。OpenAI 沙箱指导将凭据和审批保留在可信控制端，与模型驱动的计算环境隔开。Android `isolatedProcess` 提供没有自身权限的独立 UID，但本身不会建立用户所选工作区或 HTTP 策略。[Codex 沙箱与审批](https://learn.chatgpt.com/docs/agent-approvals-security)、[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)、[OpenAI 沙箱安全](https://developers.openai.com/api/docs/guides/agents-api/environments/security)、[Android Service 参考](https://developer.android.com/guide/topics/manifest/service-element)。

## 拟定策略契约

| 维度 | 新脚本运行的初始状态 | 用户可控制的扩展 | 不可绕过的边界 |
| --- | --- | --- | --- |
| 文件读取 | 只读明确挂载的工作区或文件；不能读 App home、账号库、私有缓存、任意 SAF URI 或其他 App 私有数据 | 用户通过系统选择器选文档／目录树，或选择已授权工作区 | 客体只得到不透明句柄和限量字节，不得到 App 原始路径或环境级 `ContentResolver` |
| 文件写入 | 新准入的 PTC／工作流脚本为 `read-only` | 对明确命名的工作区选择 `workspace-write`；工作区外的单个文件需新的精确 SAF 授权和单次审批 | 代理检查相对文件名、父目录身份、预期版本、大小／配额及原子发布；不自动给工作区外临时目录写入权 |
| 网络 | 客体代码为 `off`；可信模型传输及 App 账号通信独立管理 | 对获准任务／租约开放 `restricted` 精确 HTTPS 主机，必要时逐次审批 | 客体没有直接 socket API；只经 App 侧限量 HTTP 代理，检查 URL、跳转、DNS、IP；不暴露凭据 |
| 进程 | 脚本不能直接 Shell、启动原生子进程、装载动态库、开本地服务器或装包 | 首版不扩展；未来独立进程提供方需另行证明约束 | `android_shell` 保持单独标识的 App-UID 工具；其审批不得冒充 PTC 沙箱 |
| 审批 | 超出当前授权的副作用被拒绝，或执行前暂停 | 用户对精确目标／动作准许一次，或调整命名会话策略 | 审批只产生狭窄能力授权，不把模型程序切到 App UID 或 `danger-full-access` |

此处 `read-only` **仅针对新的模型编写脚本执行器**，不会暗中改变当前使用 DSH `workspace-write` 的 Android 文件工具。用户明确信任某会话工作区后，后续脚本可从 `workspace-write` 开始，保留 Codex 式的实用编辑体验。策略降级从下一次调用生效，并撤销旧写入授权；进行中的写入必须先结算，或标为 `COMMIT_UNCERTAIN`，才能报告新策略已生效。移动端 UI 应显示实际文件模式、工作区名称、网络模式／主机，以及 Shell 不受此沙箱限制的事实。Android 客体不提供 `danger-full-access`。

### 准入与权限

每次运行由可信 App 冻结 `{sessionId, ownerId, workspaceId, workspaceRevision, fileMode, readableGrantIds, writableRootId?, networkMode, exactHosts, expiry, budgets, policyVersion}`，在绑定隔离客体前记账。客体只收到运行 ID 与不透明句柄。每次回调都检查运行、所有者、租约、能力、动作和策略版本。子 Agent／工作流阶段继承的授权和预算**不得超过**父运行；委派不能拓宽文件或网络主机。准入后新增审批只为暂停中的本次调用产生一次性能力，不追溯改写旧决定。取消、超时、Binder 死亡、所有者释放或进程死亡均撤销能力，并且只结算一次日志。离线运行不能获取新的网络授权或伪造审批；已有本地授权的任务仍可在期限内完成。

现有文件代理的五分钟租约只是原型的安全上限，**不是**原版工作流的生命周期契约：原版工作流适配器可请求不设置整体 PTC 截止时间。长期运行的 Android 工作流需要可信所有者续租和持久化子任务记账设计，或者明确公布产品时长限制。不得悄悄终止或无限延长工作流却声称对等。

工作区根是 App 解析出的身份，不是客体传入的字符串。App 私有工作区可通过以描述符为锚的相对操作桥接；SAF 目录树始终是 URI 能力，不能伪装为本地路径。即使已持久授权，文档移动或删除后 SAF 访问也可能失效，所以每次调用都须重新检查并封闭失败。此设计不申请宽泛的 `MANAGE_EXTERNAL_STORAGE`。Android 系统选择器提供用户控制的授权，Android 11 起还有目录选择限制。[Android Storage Access Framework](https://developer.android.com/training/data-storage/shared/documents-files)。

首批写入能力只包括已授权工作区中的常规文件创建、替换与编辑。删除、整目录移动、权限变更、路径穿越、符号链接、硬链接别名、设备节点，以及写入 App 运行时／凭据目录，都要等各自的设计和测试完成后再考虑。替换已有内容前必须携带已记录版本，限制每次运行的字节数和文件数，在同一已打开目录中暂存、同步、发布，并保留有界撤销／版本记录。版本过期或提交结果不明时**不能自动重试**。现有安全目录写回已经记录同 UID 竞争边界，不得宣称可以抵抗恶意同 UID 写入者。隔离客体不与 App 共享 UID，使模型程序不处于该竞争类别；可信代理仍需并发控制和真机测试。[隔离约束说明](ptc-workflow-confinement.zh.md)。

网络策略**不是**允许打开任意 socket 的布尔开关。`off` 拒绝模型发起的 HTTP。`restricted` 只允许精确匹配且规范化的 HTTPS 主机；每次跳转重新检查目标，连接 IP 检查默认拒绝回环、链路本地、私网和保留地址，除非将来单独设计本地网络功能。默认拒绝 URL 用户信息、非 HTTPS scheme、IP 字面量、任意端口、代理隧道、WebSocket 升级和环境 Cookie。在连接时重新解析或固定已验证地址，以免 DNS 重绑定；同时限制请求／响应字节、跳转、并发及总耗时。App 自己的模型／账号联网单独运作，但模型程序得不到 API key 或含令牌的原始响应。主机清单由可信网络代理实际执行，不能只写在提示词里。OpenAI 托管沙箱提供 `disabled`、精确主机 `restricted` 和 `enabled`；此 Android 策略刻意不开放无限制的客体网络。[OpenAI 托管沙箱网络设置](https://developers.openai.com/api/docs/guides/agents-api/environments/openai-hosted)。

### 审批与失败行为

审批 UI 以易懂文字显示一次具体请求：操作、选定文件／工作区或精确主机、用途、大小／副作用、运行身份，以及“仅本次允许”／“拒绝”。工作区策略变更可以另提供明确的会话级选择，但不能藏在 JSON 编辑器里。过期、不可用或已变化的请求都拒绝。审批与执行结果分别持久记录；执行或日志提交不确定时不自动重放。只读策略拒绝后的提权请求只针对具体操作；决定作出后从原运行暂停的调用继续。这借鉴 Codex 的沙箱与审批分离，并不声称本 App 自动继承 Codex Auto-review。[Codex 审批](https://learn.chatgpt.com/docs/agent-approvals-security)、[OpenAI 人工审核指导](https://developers.openai.com/api/docs/guides/agents/guardrails-approvals)。

按实际情况返回结构化的 `POLICY_DENIED`、`APPROVAL_DENIED`、`GRANT_REVOKED`、`SANDBOX_UNAVAILABLE`、`STALE_REVISION`、`NETWORK_DENIED`、`NETWORK_OFFLINE`、`COMMIT_UNCERTAIN` 或 `AUDIT_UNCERTAIN`。`offline` 是环境事实，不能据此扩大主机清单。UI 须区分策略拒绝、断网、沙箱不可用和副作用结果不明。隔离绑定失败绝不改用 App UID 执行。

## 现有模型文件工具与相对路径

当前 Android 模型文件守卫独立于隔离脚本代理。原版 `read`、`read_image`、`edit`、`present`、`glob`、`grep` 和 `str_replace_editor` 可访问限定在 App 工作区内的目标；相对路径以固定的会话工作目录为基准。`write` 还受原版 `SandboxedFileSystem` 修改策略约束。原版字符串编辑器本身要求绝对路径；其**目录** `view` 仍被拒绝：真实 ToolRuntime 测试发现原版两级目录列表会跟随子目录 junction 回到 App home，泄露 `account.sqlite` 文件名。普通文件 `view` 保留。原版文本／图片读取要求常规文件，`present` 也要求现有常规文件，不会递归列目录。打包的 Windows ripgrep 在宿主测试中从工作区根执行 `glob`／`grep` 时没有跟随子 junction，但 Android 设备尚未验证。

文件提供方现在会在每次模型 stat／read 操作时，根据固定的会话工作目录重新解析目标；延迟读取的文本流在实际消费时也会重新检查。受保护的 ripgrep 子进程接口还会检查启动目录和搜索根。这些检查会拒绝父目录已被重定向的旧目标，以及之后变化的会话 cwd。模型上下文的目录枚举仍关闭，因为原版字符串编辑器会跟随子项符号链接；重新开放前必须约束每个子项并限制遍历规模。真正抗竞态的边界应使用目录句柄和相对 `openat` 一类操作；路径 realpath 检查与系统调用之间仍有同 UID 替换符号链接的时间窗。不能把当前守卫称为操作系统沙箱，也不能声称它约束了 App UID Shell、插件或未纳入守卫的未来工具。

## 实施顺序与验收

1. **策略归属与 UI。** 在原版每会话文件模式旁新增 Android 专用策略记录；用版本化准入记录可读／可写工作区 ID、网络模式和精确主机。进程死亡后持久协调；显示实际策略及 Shell 例外，同时不能假称 PTC 已可用。
2. **文件代理接入。** 把真实脚本引擎接到现有代理，将单文件授权扩展成 App 解析的工作区树，以描述符／SAF 操作实现；有未查明编辑时日志继续阻止准入，测试继承、撤销和版本变化。此阶段仍不启用工具。
3. **HTTP 代理。** 独立实现 URL 策略与请求限额，禁止客体直接联网；测试跳转、DNS 变化、本地 IP、超大响应、超时、离线及取消。不把账号凭据给客体。
4. **执行与工作流。** 实现承诺的脚本语法／绑定及子 Agent 生命周期，或明确暴露契约不同的受限工具提供方；逐项对比原版 PTC／工作流测试。仅有 V8 引擎不能宣称具备 Node 直接 API 对等能力。
5. **真机证明。** 在普通无 root 手机上，从实际模型脚本验证隔离 UID、App 私有／未授权文件与网络访问拒绝、授权后的版本校验写入和白名单 HTTPS、kill／取消后无迟到副作用、进程树退场、离线与 APK 升级恢复；将策略与结果写入 Session 记录。完成后才考虑启用模型可见工具。

主机单测与 APK 编译不能证明 Android UID／SAF／Binder／网络隔离。真机门槛通过之前，既有文件工具维持明确策略，`android_shell` 对普通模型调用保持关闭；内部诊断模式须明确启用并逐次审批，PTC／工作流继续禁用。本设计不包含 root、ADB 设备控制、全局文件系统挂载或隐藏的全访问回退。
