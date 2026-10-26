# Android PTC 执行设计与准入门槛

[English](ptc-execution-design.md) | 中文

## 当前状态与决定

Android 版本**尚不能**执行 `run_code` 或 `workflow` 脚本。本文是实施设计和验收约定，不代表原版 PTC 已可用。在以下门槛于普通非 Root 手机通过以前，Android profile 中的 `ptc-runtime`、`workflow-ptc`、`tool-workflow` 和 `preset-ptc` 继续禁用，打包及运行时的阻断也继续保留。

原版 [`PtcRuntime`](../../../packages/ptc-runtime/ptc-runtime/README.zh.md) 包括解析后的程序格式、超时、所有者生命周期、具名异步绑定、限额日志、无损 JSON 结果、结构化错误及独立的沙箱事实。已发布的 Node 提供方允许模型代码直接使用 Node 文件系统、网络和子进程 API；在 `workspace-write` 或 `read-only` 下，先经 `ctx.sandbox.confine()`，再启动受管 Node 进程。[`WorkflowExecution`](../../../packages/workflow/workflow-ptc/src/runtime.ts) 在同一个 PTC 进程里运行含 `agent`、`parallel`、`pipeline`、`phase`、`log` 和 JSON `args` 的 JavaScript 正文；工作流适配器负责子 Agent、取消和释放。只复刻工具名称而缺少这些行为，不算功能对齐。

## 当前 Android 工程的证据

| 发现 | 来源 | 结论 |
| --- | --- | --- |
| 已锁定 Android Node 24.22.0 和 `libnode.so`。 | [`runtime-lock.json`](runtime-lock.json)、[`CMakeLists.txt`](../android/app/src/main/cpp/CMakeLists.txt) | 具备 JavaScript 引擎不等于具备隔离。 |
| `NativeRuntime.start()` 将 `HOME`、`DSH_HOME`、缓存和工作目录指向应用私有路径，在应用 UID 的 `:agent` 进程启动完整 DSH。 | [`runtime.cpp`](../android/app/src/main/cpp/runtime.cpp)、[`NativeRuntime.kt`](../android/app/src/main/kotlin/com/minnnng/dsh_android/NativeRuntime.kt) | 隔离 UID 无法读取这些路径；直接在 `:agent` 执行模型代码则会暴露凭据。 |
| Manifest 声明了隔离 Service，其中内部 V8 JavaScript 求值器与诊断回显分开运行。 | [`AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml)、[`IsolatedScriptService.kt`](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedScriptService.kt)、[`PtcScriptEngine.java`](../android/app/src/main/java/com/minnnng/dsh_android/PtcScriptEngine.java) | 已有有界纯 JavaScript 求值器，但尚无面向模型的 PTC 提供方，也不具备原版 PTC 的完整语义。 |
| 原版本地沙箱只为 Linux、macOS、Windows 选择执行器。 | [`sandbox-local/src/index.ts`](../../../packages/sandbox/sandbox-local/src/index.ts) | Android 的 `workspace-write` 必须拒绝；改用 `danger-full-access` 让它运行会降低策略。 |
| Android profile 显式禁用 PTC 和工作流。 | [`cordis.patch.yml`](../runtime/cordis.patch.yml)、[`ptc-workflow-confinement.zh.md`](ptc-workflow-confinement.zh.md) | 今天没有面向模型的脚本执行能力。 |

隔离 UID 是防止读取应用私有文件的重要边界，但**不自动实现**工作区文件策略。它不会把 SAF 文档变成可直接访问的文件路径，不会将所有全局可读路径限制到选定工作区，也不保证 Service 解绑后 Node 子进程都消失。JavaScript `vm` 上下文同样不是操作系统隔离边界。

## 公开方案对照

| 方案 | 已公开的执行边界 | 对本项目的含义 |
| --- | --- | --- |
| Android [`isolatedProcess`](https://developer.android.com/guide/topics/manifest/service-element) 与 [`bindIsolatedService`](https://developer.android.com/reference/android/content/Context#bindIsolatedService(android.content.Intent,int,java.lang.String,java.util.concurrent.Executor,android.content.ServiceConnection)) | Service 可以在独立 UID 运行；每次绑定与消息传输仍由 App 设计。 | 可作为 guest 进程边界，工作文件、工具和状态必须逐项授权。 |
| [Termux `RUN_COMMAND` Intent](https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent) | 第三方经权限调用在 Termux 环境执行命令。 | 可作为用户自选的外部终端集成，但其工作区和权限不等于本 App 对模型代码的隔离；不能当作原版 PTC 的内置实现。 |
| [OpenAI 官方 Programmatic Tool Calling](https://developers.openai.com/api/docs/guides/tools-programmatic-tool-calling) | 每段模型程序在新建的隔离 V8 环境执行，无 Node、直接文件系统、网络和子进程；外部效果只能通过准入工具。 | 证明「脚本编排 + 宿主能力代理」是可行的产品形态，但它是受限工具编排，语义上不等于本仓库允许直接 Node API 的 PTC 提供方。 |
| [OpenAI 官方 Sandbox Agents](https://developers.openai.com/api/docs/guides/agents/sandboxes) 与[安全说明](https://developers.openai.com/api/docs/guides/agents-api/environments/security) | 将负责审批、审计和恢复的控制面与运行模型代码的执行面分开，并限制文件、网络与凭据暴露。 | 支持把账号与任务状态留在可信 App／Host，把代码放到受限 guest；不能因为两者同在一个 Node 进程就宣称已隔离。 |

上表是架构对照，不表示 Android App 能复用 OpenAI 的托管运行时，也不表示 Termux 或 Android Service 自动满足 DSH 的原版策略。

## 目标架构

1. **应用侧准入。** PTC 适配器只接受有明确所有者的任务，冻结 Session ID、工作区版本、策略、程序格式、绑定白名单、取消源及预算；先记录受理事实再启动 guest。无效选项在发布任务前拒绝。扩大权限须由应用侧做一次性审批，不能从脚本参数推定。
2. **每次执行使用新 guest 进程。** API 29+ 为每个任务绑定唯一名称的 `android:isolatedProcess` Service；API 28 回退路径串行化，并在任务后强制退出。通过有界描述符或 Binder 帧传递程序字节，不交出应用私有代码、凭据、Home 或工作区路径。guest 没有应用私有启动脚本和环境权限。两端都检查 Binder 发送 UID、run ID 及唯一 call ID。Binder 意外死亡使任务失败。
3. **脚本引擎。** 已锁定的 `libnode` 包含 V8，但**不暴露 Node 全局对象**的嵌入式 V8 isolate 是另一种提供方：可实现仅通过 broker 调用的 TypeScript/JavaScript 子集和工作流钩子，却不等同原版可直接访问 `fs`、`net`、`child_process` 的契约。完整 Node 提供方必须先拥有经真机证明的内核级文件及进程隔离，并解决工作区路径模型。仅 V8 方案仍需原生执行桥、Promise 微任务循环、中断、堆上限、严格 JSON 转换和异步宿主调用。只有同步 `eval`、没有宿主绑定，不算实现了 `workflow`。
4. **能力代理。** 应用保存 opaque grant ID 到用户授权工作区文件的映射。guest 只能发送 `{runId, callId, grantId, action, boundedArgs}`。应用检查租约、审批、操作类型、预期文件版本；返回有界读取、搜索或编辑结果；记录请求及其终态。不接受 guest 指定的应用私有路径或任意工具名。工作流 `agent()` 需要独立的子 Agent 能力，遵守所有者、上限和释放规则；文件授权不能隐含授权它。
5. **资源与生命周期。** 分别限制脚本大小、帧大小、输出大小、堆、等待中的调用数和宿主队列。经过时间截止从绑定前开始，包括所有回调等待。同步死循环须通过 V8 中断或杀进程终止；guest 丢失只结算一个终态并撤销授权。取消先阻断后续回调，再释放已接受的子 Agent，并记录停止原因。成功后也退休 guest；在完成 state owner 释放与崩溃恢复之前，不宣称支持持久内存环境。
6. **提供方接入。** 新 Android 提供方应报告真实的 `language`、执行模式与强制隔离事实。若不支持直接 Node API，必须给出不同的 `executionInstructions`，不能冒充现有 Node 提供方。原版 `workflow-ptc` 加载时拒绝非 TypeScript PTC 提供方，内部 VM 使用 `node:vm`；改造或替换这一层是实质性集成工作。只有完成并检查各工具所需契约后，才向模型暴露 `run_code`、`workflow`。

拟议的应用回调边界为 `hostCall(runId, callId, grantId, action, boundedArgs) -> boundedResponse`。每个请求均可关联、最多受理一次，并在 guest 死亡时也有终态。该接口故意不包含文件路径、`process.env`、网络套接字或任意 Shell 请求。

### Android 执行策略

遵循 [OpenAI Docs 的 Codex 沙箱说明](https://learn.chatgpt.com/docs/sandboxing)与[智能体审批说明](https://learn.chatgpt.com/docs/agent-approvals-security)中的边界：审批结果本身不会扩大沙箱。每次运行默认没有 guest 文件授权，也没有 guest 网络授权。应用可以显式准入 `workspace-write` 范围，仅包含用户选定的应用工作区可读、可写路径。文件操作边界必须拒绝范围外写入，包括工作区中的受保护元数据（`.git`、`.agents`、`.codex`、`.aws`）。网络默认拒绝；经审核的精确 HTTPS 域名只能通过应用网络代理授权给一次有界运行。子任务只能缩小父任务权限。guest 只拿到不透明句柄，不拿原始路径、凭据或环境网络套接字。所选 Android 执行器若无法强制执行该策略，就返回 `sandbox-unavailable`，不能退回应用 UID 执行。

现有 `IsolatedExecutionPolicyOwner`、文件代理、网络代理和手动脚本审批，已覆盖应用私有工作区精确文件与精确域名选择的一部分契约。原有应用 UID Shell、Host 网络工具和第三方插件是不同执行面；它们不会继承隔离 guest 的授权，各自需要强制约束或明确的不可用状态。这是模型脚本与工作流的目标策略，并不表示今天已开放那些工具。

实现时应对传输帧进行版本化，在准入时冻结字段：

```text
Start {version, runId, ownerId, programFormat, programBytes, programSha256,
       args, grantIds, timeoutMs, maxOutputBytes, maxMessageBytes,
       maxPendingCalls, maxHeapMb}
HostCall {version, runId, callId, grantId, action, boundedArgs}
HostReply {version, runId, callId, result | error}
Terminal {version, runId, completed(value, logs) | failed(kind, detail),
          sandboxFacts, counters}
```

`programBytes` 可以经一次性只读描述符而非 Binder `Bundle` 传递；应用必须校验 guest 实际读取的大小及哈希。收到结果帧还不能直接判定成功：必须等待 guest 退出、全部宿主调用及子 Agent 结算，并完成清理。任务状态机为 `admitted -> binding -> running -> stopping -> settled`；只有应用写入持久的 `settled`。每次回调都检查任务仍为 `running`。迟到回复、重复终态帧及过期进程身份要丢弃并审计。guest 异常对应 `exception`，经过时间截止对应 `timeout`，用户取消对应 `abort`，错误或过大的控制帧对应 `protocol`，文件策略不可用对应 `sandbox-unavailable`，guest 死亡或清理失败对应 `worker-exit`，输出过大对应 `output-limit`。`sandboxFacts` 须独立于错误类型报告。

原版 Node 默认值为 120 秒经过时间截止（数字请求最高 600 秒）、64 MiB 合并输出、512 MiB V8 老生代堆、128 MiB 控制消息、128 个待处理宿主调用（见 [`config.ts`](../../../packages/ptc-runtime/ptc-runtime-node/src/config.ts)）。这些值不能直接视为适合手机。Android 若采用较低上限，须在提供方描述中明确给出并在 `resolve()` 验证；不得悄悄截断脚本或结果后宣称功能一致。

## 向模型开放之前的验收门槛

| 门槛 | 所需证据 |
| --- | --- |
| 原生 guest | 在普通非 Root 手机安装 APK，以隔离 UID 真正执行一段模型生成的脚本，并证明 guest UID 与 `:agent` 不同。Android 编译和主机单测不能替代。 |
| 无环境权限 | 从实际脚本尝试读取应用私有标记、授权之外的工作区文件、其他 SAF URI，以及直接网络/子进程路径，均须失败。不能只测试诊断回显。 |
| 授权文件及工具效果 | 授权读取、搜索及按版本编辑成功；撤销授权、过期版本、超大数据、错误 UTF-8 和文件缺失有稳定错误。所有效果写入持久工具／Session 记录。 |
| 工作流一致性 | 对真实子 Agent 运行 `agent`、`parallel`、`pipeline`、`phase`、`log`；检查子数量、上限、JSON 输出、普通子失败、基础设施失败、前台和后台任务。 |
| 收尾 | 覆盖同步死循环、待处理 broker 调用、等待子 Agent、取消、超时、Binder 死亡、进程强杀和应用重启。保证一个终态、没有越权的迟到效果，也没有残留后代进程。 |
| 所有者及升级 | 不同所有者不共享状态；若支持保留内存，退出时释放且不能跨进程死亡恢复；APK 升级保留持久记录，不重放副作用。 |
| 策略报告 | `read-only` 和 `workspace-write` 须在真实 guest 执行世界得到强制约束，否则返回 `sandbox-unavailable`；不能仅凭独立 UID 宣称完全隔离。 |

这些门槛通过以前，产品明确报告 PTC 不可用，并继续提供现有 Android 文件及子 Agent 工具。旧版应用 UID Shell 在正常启动时不出现，仅保留显式诊断路径；不能拿它或应用 UID 的 Node 进程冒充隔离执行器，也不能把内部纯 JavaScript 客体称作原版 PTC 提供方。
