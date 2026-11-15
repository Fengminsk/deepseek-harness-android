# 远程 DSH · P5 剩余能力设计：附件上行 / 输入区 / 模型路由前置提示

状态：P5 剩余项的实现设计，供下一轮直接落地。**本文只做设计，不含代码改动。**
上位文档：[remote-dsh-plan.md](../remote-dsh-plan.md)（§5 目标架构、§12.7 范围纪律）、[HANDOFF.md](HANDOFF.md)（§3 状态、§4 剩余工作、§6 硬约束）、[protocol.md](protocol.md)（冻结 v1）。
范式参照：[terminal-design.md](terminal-design.md)（同一套「结论 → 现状证据 → 线上契约 → 实现 → 里程碑 → 风险」结构）。
范围：`apps/android/lib`（App）、`apps/android/runtime`（宿主侧适配）、`apps/android/android`（Kotlin 设备侧）、`apps/remote-host`（profile 与 e2e）。**不改 `packages/*`；不改 `protocol.md` 的方法表、帧格式与能力协商**（A 方案需向 `protocol.md` §5.2 追加一行反向请求条目，见 §3.4.1 与附录 A，属待决策 D2）。

证据基线：2026-11-15 23:5x 的工作区快照（HEAD `c20c00cd15` + 未提交改动）。终端实现正在并行落地，`remote_dsh_conversation.dart` 等文件仍在被改动；**引用行号随施工漂移，以文中给出的符号名/函数名为准**。

---

## 0. 结论（先看这里）

| 主题 | 推荐结论 | 一句话理由 | 是否需改协议 | 工作量 |
|---|---|---|---|---|
| **A 附件上行** | **方案②：把字节传输做成反向请求拉取**（宿主在 `attachments.prepare` 内用 `native.attachments.read` 分页向手机要字节，流式写进既有 `ctx.fileUploads.uploadStream`） | 唯一能覆盖「照片原图 / 文档」真实大小的方案，且不需要分块重组状态机、不新增 App→宿主方法、不新增帧类型/能力/版本 | 需在 §5.2 追加一行（v1 内，等价于已预留的「P5 再开放」） | M+M |
| **B 输入区** | `+` 弹层**按 DSH 指令目录重建**（复用 `ComposerCommands`）；**方案模式做**；**语音不做**；**审批预设在宿主启用 `permission` 后做** | 本地 `+` 的真实数据源是 `api.call commands/list`（不是截图里的六项固定清单）；方案模式全部走已冻结方法；语音在 DSH 是 experimental 且手机侧零实现；审批预设是 DSH 既有服务但宿主 profile 没启用 | 否 | `+` M / 方案模式 S / 语音 0 / 审批预设 M |
| **C 模型路由前置提示** | **判定口径补齐即可**：把「服务商不在 `routableProviders`」也算不可用，其余（提示条、动作、自动兜底）**已实现** | 现有提示只看 `modelCatalog.failures`；而「无 API Key 的 `deepseek-official`」在目录里是**静默缺席**（`discoverModels` 返回 `[]`），既不在 groups 也不在 failures，所以 HANDOFF §4.2 描述的缺口仍在 | 否 | S |

三句话版：

- **A**：不要做「base64 分块上传」（违反 §11 且需要宿主重组状态机），也不要升 v2；用**既有的反向请求通道 + 一个 `native.*` 新条目**，把手机选好的私有缓存副本按页拉给宿主，落到既有 `fileUploads` 收据上。大小上限由宿主既有 DSH 配置决定，不需要新协议常量。
- **B**：输入区不是「补四个按钮」，而是「把本地那套数据驱动菜单接到远程门面上」。能做的是 `+`（指令目录）、方案模式、审批预设；相机/照片/插件/语音没有可回答的「哪个门面方法」，按 HANDOFF §6.2 判不做；「追求目标」需要新增 `remote.*` 通知，延期。
- **C**：机制已在（首屏异步判定 + 输入区上方提示条 + 发送失败自动改默认模型重试一次），缺的只是判定输入少了一路信号；补 `routableProviders` 对照即可，页面与文案不动。

---

## 1. 待决策（D1–D8）

每行都给出推荐值；「影响」列写清楚不采纳推荐会多花什么。

| 编号 | 问题 | 推荐值 | 影响 |
|---|---|---|---|
| **D1** | A 的字节通道走哪条路：①单帧内联（不新增方法，但受 1 MiB 上行帧限制）／②反向请求拉取（需 §5.2 加一行）／③协议 v2 专设上传方法 | **②**。①只够 ~780 KiB 原始字节，覆盖不了手机照片与多数 PDF，做完等于半个功能；③要双端版本协商与协调发版，收益只有「少一个 native 条目」 | 选①：附件功能对 >0.8 MiB 文件永久不可用，后续仍要重做一次；选③：两端各一轮版本升级 + 握手兼容窗口，P5 内做不完 |
| **D2** | 是否允许为 A 修订 `protocol.md`：**只向 §5.2 反向请求表追加一行**（App→宿主方法表、帧格式、能力协商、版本号都不动） | **允许**。§5.2 对 `native.documents.*` 已写明「v1 统一 `-32601`，P5 实现后改为正常应答」，追加一行与这条既有约定同性质；且反向请求在 §5.3/§5.4 里已有完整的失败与超时语义 | 不允许：A 只能退化为 D1 的①或③，产品上不可接受（见上） |
| **D3** | 远程附件的**额外大小上限**：直接沿用宿主 DSH 配置（单图 50 MiB / 单消息图片 200 MiB / 单文件 256 MiB），还是在远程链路另设更小的上限 | **沿用宿主配置**，只在手机端做**发送前预检**（超过 50 MiB 的图片、超过 256 MiB 的文件在选择后立即提示，不进入上传），不引入第二套常量 | 另设上限：两套限额会让「同一台电脑的桌面与手机行为不同」，增加文档与支持成本；不设预检：用户要等传完才失败 |
| **D4** | 输入区 `+` 弹层的内容形态：按 DSH 指令目录重建，还是保留截图式「相机/照片/文件/插件/方案模式/追求目标」六项 | **按 DSH 指令目录重建**（`api.call commands/list` + 客户端动作）。相机/照片并入「文件」（系统文件选择器本来就能选图片）；插件做成独立目的地不进 composer；goal 延期 | 保留六项：四项没有门面数据源，只能永远置灰，违反 protocol §10.2「不允许能点但没用」与 plan §12.7 |
| **D5** | 审批预设：远程宿主启用 `permission`（= `@deepseek-ai/dsh-permission-presets`，提供 `/permission` 命令 + `permissions` 投影 + `permissionPresets.catalog`），还是维持现状（只有一次性 `allowed-once`/`rejected`） | **启用**，并允许手机切换预设；但复用本地 `SessionPermissionPage` 的二次确认（`danger-full-access` 与 `auto` 必须勾选「我已了解风险」） | 维持现状：远程用户每次越界操作都要点一次「允许一次」，长任务不可用；同时 `runtime.permissions.presets.available` 永远是 false，能力三态里该入口只能常灰 |
| **D6** | 方案模式只做 `/plan` 开关，还是把 goal（`+` 里的「追求目标」）一起做 | **只做 `/plan`**。goal 的「是否已授权继续跑」是**进程内激活态**，靠 `goal/activation-changed` 这种 runtime 事件传播；远程模式没有对应通知，要新增 `remote.*` 通知（protocol §8 是封闭清单） | 一起做：等于顺手重开一次协议 §8，把 B 从 M 变成 L，且与 P6 的通知通道耦合 |
| **D7** | 语音输入做不做 | **不做**。DSH 侧是 experimental bundle（浏览器 `MediaRecorder` → 宿主 SenseVoice），按 `packages/experimental/AGENTS.md` 不能进 shipped profile；手机侧没有任何录音/编码实现；`speech.transcribe` 默认 4 MiB 音频也超过 1 MiB 上行帧。替代：系统输入法自带的语音听写 | 做：需要新 native 录音、WAV 编码、新依赖、麦克风权限与前台服务，以及把 experimental 装进远程 profile——等于新开一条产品线 |
| **D8** | A 的宿主侧实现放哪：改 `apps/android/runtime/attachments.mjs`（复用同一类） vs 新增 `apps/android/runtime/attachments-desktop.mjs`（照 `terminal-desktop.mjs` 范式） | **新增 desktop 文件**，Android 现有附件实现零改动；代价是约 120 行宿主侧逻辑重复，用同一份单测跑两套实现兜底 | 改原文件：热点路径是「手机附件安全校验 + 图片解码上限」，改它等于让本地模式一起冒回归风险，违反 HANDOFF §6.5 |

**决策记录（lead，2026-11-16 00:00）：D1–D8 全部按推荐值采纳。** 施工顺序：A（宿主 `attachments-desktop.mjs` + 协议 §5.2 追加一行 + App 反向应答/分页读 + 输入区附件 rail）→ B（`+` 指令目录、方案模式）→ 审批预设（先宿主启用 `permission`，再手机端切换入口）→ C（`routableProviders` 判定补齐）。语音与 goal 按 D6/D7 不做。协议修订只允许 §5.2 表追加 `native.attachments.read` 一行；方法表、帧格式、能力协商与版本号保持冻结。

**实施状态（2026-11-16 01:00）：**

| 主题 | 状态 | 证据 |
|---|---|---|
| A 附件上行 | **完成（真机验收被 ROM 挡住）** | 宿主 `attachments-desktop.mjs` + App `attachment_surface.dart`/`remote_attachments.dart`/`remote_native_bridge.dart` + Kotlin 分页读 + 会话页 rail；宿主单测 33 项、App 测试 20+3 项；真实宿主 e2e 23/23（含 3 项附件检查）；HANDOFF §3.2.5、§7 #23/#25。真机 SAF 被 ColorOS 限制，A4 换机待做 |
| B `+` 弹层与方案模式 | **完成（B1/B2）** | 复用本地 `ComposerCommands`/`ChatPlanDock`；`remote_commands.dart`、`remote_goal_plan.dart`；测试 11+14+11 项；HANDOFF §3.2.6 |
| B 审批预设（B3） | 未开始 | 依赖宿主 patch 启用 `permission` + 手机端 preset 列表与二次确认（§4.5） |
| C 模型路由前置提示 | **代码完成（C3 真机待做）** | `routableProviders`/`unavailableProviders`；数据源 +4、widget +3 用例；HANDOFF §3.2.6 |


---

## 2. 现状证据

### 2.1 已在 DSH / App 里存在 vs 需要新增

| 能力 | 现状 | 证据 |
|---|---|---|
| 附件选择的设备侧私有缓存 | **已有**：SAF 选文件 → `<cacheDir>/pocket-attachments/<uuid>.bin` + `.json`，不把路径交给 Flutter | `apps/android/android/app/src/main/kotlin/com/minnnng/dsh_android/AttachmentTransfers.kt:31-46`、`:65-130`、`:158-164` |
| 附件准备/发送链路（本地） | **已有**：`attachments.prepare` → 宿主 `ctx.fileUploads.uploadStream` → 收据 `receiptId` → `session.send{attachmentIds}` | `apps/android/lib/attachments.dart:69-119`、`:124-167`；`apps/android/runtime/attachments.mjs:73-153`；`apps/android/runtime/index.mjs:566-575`、`:869-871`；`apps/android/runtime/sessions.mjs:78-105` |
| `fileUploads` 收据与流式入库 | **已有**：`uploadStream` 接受 `AsyncIterable<Uint8Array>`，中途取消会清理临时文件 | `packages/client/file-upload/src/index.ts:127-140`、`:194-196`；`packages/attachment/attachment-local/src/store.ts:349-388` |
| 双向反向请求通道（宿主→App） | **已有**（协议 §5 全套语义），宿主侧 `createFacadeSink` 先本地拦截再转发；**App 侧从未安装 handler**，所以现在一律 `-32601` | `apps/remote-host/src/index.ts:782-795`、`:487-490`；`apps/android/lib/remote_transport.dart:1024-1072`；`apps/android/runtime/index.mjs:187-220`（晚绑定传输） |
| 手机侧原生选择器通道 | **已有**：`attachment.pick` 是 App 自己的 MethodChannel，与本地/远程模式无关 | `apps/android/lib/attachments.dart:74-78`；`apps/android/android/app/src/main/kotlin/com/minnnng/dsh_android/MainActivity.kt:274` |
| 附件三态/错误文案 | **部分**：`AttachmentDrafts` 有上传中/失败/重试/移除，但错误直接展示底层异常 | `apps/android/lib/attachments.dart:124-167`、`:252-366` |
| DSH 指令目录（`+` 的真实数据源） | **已有**：`api.call {namespace:'commands', method:'list'}`，本地 `+` 就是它 | `apps/android/lib/composer_commands.dart:76-87`、`:116-137`、`:378-518`；`apps/android/lib/main.dart:1442-1470`、`:639-687` |
| 方案模式 | **已有**：状态读 `session.projections` + 实时 `session.control` 流；写走 `session.command '/plan'` | `apps/android/lib/chat_goal_plan_state.dart:111-132`、`:168-197`、`:344-391`；`packages/plan/plan-mode/src/index.ts:136-137`、`:232-235` |
| 审批预设服务 | **DSH 有、当前 profile 未启用**：`permission-presets` 要求沙箱执行器可界定（Android 无沙箱 → 组合即抛错，故 app 层禁用；远程宿主已恢复沙箱但没重新启用它） | `packages/interaction/permission-presets/src/index.ts:215-217`、`:239-246`、`:254-266`；`apps/android/runtime/cordis.patch.yml:18-21`；`apps/remote-host/cordis.patch.yml:52-65`、`:117-122` |
| 审批一次性的语义 | **已有且是 DSH 的语义**（只有 `allowed-once` 是授权，其它是拒绝/取消/不可用） | `packages/interaction/user-approval/src/types.ts:32`；`apps/android/runtime/interactions.mjs:291` |
| 模型路由发送前提示 | **已有机制**，判定输入只有 `failures` | `apps/android/lib/remote_dsh_conversation.dart:405`、`:1265-1282`；`apps/android/lib/remote_conversation_live_source.dart:763-834`、`:1072-1122`；测试 `apps/android/test/remote_conversation_page_test.dart:1070-1168` |
| `routableProviders`（本应使用的第二路信号） | **DSH 已返回**，App 解析时丢弃 | `packages/api/session-controller/src/types.ts:134-141`；`packages/api/session-controller/src/catalog.ts:20-72`；App 未解析：`apps/android/lib/remote_conversation_live_source.dart:1072-1122` |
| **需要新增**：反向请求的 App 侧 handler | `setRequestHandler` 只有定义、无安装点 | `apps/android/lib/remote_transport.dart:389-394`、`apps/android/lib/runtime_transport.dart:58-65`（只有接口）；全仓 `grep setRequestHandler` 无其它调用 |
| **需要新增**：手机侧分页读通道 | 现有 `attachment.pick` 之外没有读缓存文件的通道 | `AttachmentTransfers.kt` 全文件（只有 pick/onActivityResult/close） |
| **需要新增**：远程输入区附件 rail 与 `attachmentIds` 透传 | 远程 `send` 不带附件；页面无 rail | `apps/android/lib/remote_conversation_live_source.dart:282-306`；`apps/android/lib/remote_dsh_conversation.dart:743-880` |

### 2.2 关键约束（来自冻结协议与 handoff）

| 约束 | 值 | 证据 |
|---|---|---|
| 上行单帧 | 1 MiB（1048576 B），越界回 `-32700` 并关闭 `1009` | `protocol.md:94` |
| 下行单帧 | 16 MiB（16777216 B），越界以流内 `error app-stream/limit` 终止 | `protocol.md:93` |
| 本机 native 帧上限（对比） | 32 MiB，所以本地能塞 20 MiB 预览图 | `apps/android/runtime/attachments.mjs:8-9` |
| v1 明确不做 | 「二进制分块上传……继续走既有分片读；不引入 WS 二进制帧，不引入分块重组状态机」 | `protocol.md:703-707` |
| 方法表 | 只新增 `protocol.hello`；业务方法名一字不改 | `protocol.md:268-304` |
| 未知 `native.*` 必须回 `-32601` | 不得静默丢弃 | `protocol.md:334-347` |
| 反向请求超时 | 90 s 未响应 → `gateway/timeout`；连接关闭 → `gateway/cancelled` | `protocol.md:349-357` |
| `unsupported`/`methods` | 每次握手重取，不得缓存跨连接 | `protocol.md:666-692` |
| DSH 有的才做 | 答不出「数据源是哪个门面方法」就不做 | `HANDOFF.md:344-351`；`remote-dsh-plan.md:576-588` |
| 本地模式零回归 | 传输/流控改动必须同时通过本地测试 | `HANDOFF.md:350` |

---

## 3. 主题 A：附件上行（手机选文件 → 宿主侧会话）

### 3.1 本地链路（必须复用的形状）

```
AttachmentDrafts.pick()                      ← MethodChannel 'attachment.pick'（App 自己的通道）
  → 设备缓存 <cacheDir>/pocket-attachments/<id>.bin + .json
AttachmentDrafts._prepare()                  ← runtime.call('attachments.prepare', {sessionId, id})
  → 宿主 AppAttachments.describe(id)         ← 读 <native.attachments.directory>/<id>.bin|.json
  → 宿主 ctx.fileUploads.uploadStream(...)   ← 生成 receiptId（或图片走 validateImage，无收据）
  → 返回 {id, kind:'file'|'image', name, bytes, receiptId?}
AttachmentDrafts.consume() / 发送            ← session.send{sessionId, requestId, text, provider, model, attachmentIds}
  → 宿主 AppAttachments.content(sessionId, ids) → PromptContentPart
```

证据：`apps/android/lib/attachments.dart:69-119`、`:124-167`、`:196-216`；`apps/android/runtime/attachments.mjs:51-71`、`:73-153`、`:236-297`；`apps/android/runtime/index.mjs:564-575`、`:869-871`；`apps/android/runtime/sessions.mjs:88-105`。

### 3.2 取证：`attachments.prepare` 在当前远程组合下的实际行为

结论：**必然以 `-32603` + Node 的 ENOENT 文案失败，且手机侧看不到任何「远程不支持附件」的解释。** 推导链（全部为代码事实）：

| 步 | 事实 | 证据 |
|---|---|---|
| 1 | 远程会话页目前没有附件入口，`+` 弹层六项全灰 | `apps/android/lib/remote_dsh_conversation.dart:1189-1200`（`disabled: RemoteAddAction.values.toSet()`）；首页输入条四项也是 `_unavailable(...)`：`apps/android/lib/remote_dsh_page.dart:1177-1190` |
| 2 | 一旦按本地链路调用，门面 `attachments.prepare` 会用 `transport.request('native.attachments.directory')` 取目录 | `apps/android/runtime/index.mjs:572-575` |
| 3 | 宿主拦截这个方法，返回的是**宿主自己的** `<DSH_HOME>/app-attachments`（并 mkdir 出来） | `apps/remote-host/src/native-desktop.ts:318-336`、`:398-412` |
| 4 | `AppAttachments.describe(id)` 先 `realpath(configured)`（成功），再对 `<id>.bin`、`<id>.json` 逐个 `realpath` 并检查父目录；这两个文件只存在于**手机**缓存目录 | `apps/android/runtime/attachments.mjs:51-71`（尤其 `:56-60`） |
| 5 | 于是 `realpath` 抛 `ENOENT: no such file or directory, realpath '…\app-attachments\<id>.bin'`；`upload()` 捕获后记 `Pocket attachment storage failure: ENOENT` 并原样重抛 | `apps/android/runtime/attachments.mjs:93-153`（`:142-152`） |
| 6 | `packageOperations.runWork` 只做准入计数，不改写错误 | `apps/android/runtime/package-operations.mjs:49-54` |
| 7 | 共享传输把 handler 的失败统一写成 `-32603`，`message` 取 `error.message` | `packages/sdk/protocol/src/transport.ts:278-288` |
| 8 | App 侧 `-32603` → `code='gateway/internal'`、`message` = 上面那句英文 ENOENT | `apps/android/lib/remote_transport.dart:942-980` |
| 9 | `AttachmentDrafts._prepare` 把失败塞进 `item.error`，rail 显示「上传失败」+ 原始异常文本 | `apps/android/lib/attachments.dart:160-166`、`:317-331` |

**可验证的最小动作**：e2e 客户端发一条 `attachments.prepare {sessionId:<真实会话>, id:<随机 uuid v4>}`，断言收到 `-32603` 且 `message` 含 `ENOENT`。这条同时可作为 A 的「起点证据」检查项（不依赖手机）。

### 3.3 候选方案与取舍

| 维度 | ① 单帧内联（不新增方法名） | ①′ 分块 base64（App 主动推） | ② 反向请求拉取（推荐） | ③ 协议 v2 专设上传 |
|---|---|---|---|---|
| 形态 | 复用 `attachments.prepare` 的 params 加可选 `data/name/mediaType`（或 `api.call {namespace:'fileUploads', method:'upload'}`），一次请求带完整文件 | 同一方法加 `offset/append` 参数，宿主按 id 累积 | 宿主在 `prepare` 内**反向请求** `native.attachments.read`，手机按页回字节；宿主流式写入 `fileUploads` | 新增 v2 方法/二进制帧 |
| 可用大小 | 受 1 MiB 上行帧 ≈ **原始 780 KiB** | 任意，但宿主必须有重组状态机 | 任意（逐页推进，内存有界） | 任意 |
| 与 §11 的关系 | 字面不违反（不是分块、不是二进制帧），但与「附件继续走既有分片读」的**意图**冲突，需要一条注记 | **直接违反**「不引入分块重组状态机」 | 不违反：字节仍以**分片读**推进，宿主不重组，直接进流式入库 | 需要 v2 协商，等于把 §11 的「不做」改成「做」 |
| 改动面 | 宿主 `attachments.mjs` + App 一处传参；0 协议 | 宿主新增累积状态 + 中断清理 + 头外路径；App 循环 | 宿主新增 desktop 附件实现（D8）+ 协议 §5.2 一行；App 新增反向 handler + Kotlin 分页读 + 发送透传 + rail | 协议 v2 + 双端握手 + 方法表 + e2e |
| 安全性 | 与本地一致（宿主仍做 image validate / 大小校验） | 累积状态要落盘或占内存，`release` 与连接关闭都要清理，路径逃逸面变大 | 宿主只按 `<uuid>` 向**手机**取页；手机只服务自己缓存目录内的 `<id>.bin`，且可限定「本次已选的 draft id」；宿主侧不落临时文件（直接流进 attachments store 的 tmp） | 同②，另加版本兼容面 |
| 中断语义 | 单请求失败即可，语义最简单 | 需要「未完成上传」的清理契约 | 连接关闭 → 在途反向请求以 `gateway/cancelled` 失败 → `uploadStream` 的 `signal` 中止 → `stageImmutableObject` 清理 tmp（`attachment-local/src/store.ts:349-388`） | 同② |
| 测试点 | 1 个小文件 | 分块边界、乱序、重放、清理 | 分页边界、`-32601` 降级、中断清理、大图、预览上限 | 全套 |
| 本地零回归 | App 侧无分支，但宿主 `attachments.mjs` 被改（本地同文件） | 同左 | **Android 文件零改动**（D8），App 侧仅在 remote 数据源新增 | — |
| 工作量 | S（但产品不可用） | L | M（宿主）+ M（App） | L×2 |

**推荐方案 ②**，理由按优先级：
1. **只有它能覆盖真实文件**：手机照片普遍 2–8 MiB、PDF 常见 1–10 MiB；①的 780 KiB 上限把最主要的使用场景挡掉。
2. **它不新增业务方法**：App→宿主方法表仍是冻结的那 93 项；只用到 protocol §5 已存在的反向请求通道。增加的是 §5.2 表里的一行（D2），与表内 `native.documents.*` 的「P5 再开放」同性质。
3. **它没有状态机**：`uploadStream` 的入参就是 `AsyncIterable<Uint8Array>`（`packages/client/file-upload/src/index.ts:127-140`），宿主边拉边写，取消即中止；不需要按 id 累积、不需要临时文件、不需要跨请求内存。
4. **它的失败语义现成**：`-32601`（旧 App 不认识）、`gateway/timeout`（90 s）、`gateway/cancelled`（断连）都是协议已定义的，手机侧可三态展示。
5. **它对本地零回归**：`android` 分支继续用 `AppAttachments`，桌面分支用新类（D8）；App 侧新代码只挂在远程数据源。

不选 ③：v1 冻结是当前路线的最大资产（两端都已在真机跑通），为一次字节传输升版本不划算；v2 的收益是把 base64 换成二进制帧，省约 25% 带宽，局域网场景无感。

### 3.4 推荐方案 ② 的线上契约

#### 3.4.1 方法表（App→宿主：0 新增；宿主→App：+1 行）

| 方向 | 方法 | 说明 |
|---|---|---|
| App→宿主 | `attachments.prepare` | **方法名不变**，params 追加可选的 `name` / `mediaType` / `bytes`（协议 §4.2 只冻结方法名，业务 params 由门面实现定义；本地分支忽略多余字段，因此 App 可以无条件携带） |
| App→宿主 | `session.send` / `session.command` | 不变，沿用既有 `attachmentIds` |
| 宿主→App | `native.attachments.read`（新增） | 只有桌面分支会发；Android 本地链路没有宿主，永不触发 |

`protocol.md` §5.2 追加行（文案见附录 A）：

| `native.*` 方法 | 由谁应答 | 说明 |
|---|---|---|
| `native.attachments.read` | **转发给 App** | 分页读取手机附件草稿的私有副本；v1 旧 App 回 `-32601` 时宿主以 `attachment-file/unsupported` 失败 |

#### 3.4.2 请求/响应

```
宿主 → App
{"jsonrpc":"2.0","id":"h-…","method":"native.attachments.read","params":{
   "id":"<uuid v4>","offset":0,"length":262144}}

App → 宿主（成功）
{"jsonrpc":"2.0","id":"h-…","result":{
   "data":"<base64>","nextOffset":131072,"size":5242880,"eof":false}}
```

| 规则 | 值 | 理由 |
|---|---|---|
| `id` | 必须是 `attachment.pick` 产生的 uuid v4，且**仍在 App 当前草稿集合里** | 与本地 `attachments.mjs:6` 同一正则；把服务面收缩到「用户本次选中的文件」 |
| `offset` | `0 ≤ offset ≤ size` | 服务端对越界回 `attachment-file/invalid-request` |
| `length`（请求） | 1–262144 | 宿主侧**页大小 256 KiB**：base64 后 ≈ 350 KiB，远低于 1 MiB 上行帧（`protocol.md:94`） |
| 返回 `data` | base64，解码后 ≤ 请求 length | App 可以返回更少（短读），由 `nextOffset` 推进 |
| `eof` | 读到 `size` 时为 true | 宿主据此结束循环并与 `prepare` 声明的 `bytes` 对账 |
| `size` | 该文件的权威大小（设备侧 stat） | 宿主与 `prepare` 声明值不一致 → `attachment-file/changed` |
| 错误 | `-32601`（未知/旧版）/ `-32603` + `data.code` ∈ `attachment-file/not-found`、`attachment-file/cancelled`、`attachment-file/invalid-request` | 复用 protocol §5.3 的强制 `-32601` 语义 |

#### 3.4.3 宿主侧错误码（App 可见）

| 场景 | `_pocket_error.code` | 手机展示 |
|---|---|---|
| 手机没有该草稿（已移除/重启） | `attachment-file/not-found` | 「文件已不在手机上，请重新选择」 |
| 手机返回 `-32601`（旧版 App） | `attachment-file/unsupported` | 「这台手机上的 App 版本不支持上传附件」 |
| 字节数与 `prepare` 声明不符 | `attachment-file/changed` | 「选择的文件已变化，请重新选择」 |
| 图片超限/格式不支持 | 沿用既有 `UNSUPPORTED_IMAGE_TYPE` / `IMAGE_TOO_LARGE` / `IMAGE_PREVIEW_TOO_LARGE`（`apps/android/runtime/attachments.mjs:175-183`） | 与本地一致 |
| 断连中途中止 | `gateway/cancelled` | 「连接已断开，请重试」 |

注意：当前 `attachments.prepare` 的错误是**裸抛**（不包 `_pocket_error`），因此远程只能看到 `-32603`。方案 ② 落地时应在桌面分支统一用既有 `remoteFailure`（`apps/android/runtime/index.mjs:117-125`）把附件错误包成 `_pocket_error`，否则手机拿不到可分类的 `code`。这是 A 的一处**必须**改动。

#### 3.4.4 宿主实现（`apps/android/runtime`）

新文件 `attachments-desktop.mjs`，导出 `DesktopAppAttachments`，与 `AppAttachments` **同方法面**：`prepare/preview/release/content/commandContent/close`。接线（`index.mjs`）：`attachments = android ? new AppAttachments(...) : new DesktopAppAttachments(...)`。

内部每条 draft 一条记录：`{ id, sessionId, name, mediaType, bytes, kind, receipt?, imageDigest?, inflation?, state, lifetime }`。

- **prepare**：校验 `id`/`name`/`mediaType`/`bytes`（`attachments.mjs:6` 的 uuid 正则、`attachment-files.mjs:11-12` 的非法名规则），`await ensureSession(sessionId)`（复用 `AppSessions.ensure`），按 `mediaType.startsWith('image/')` 分流：
  - 文件：`ctx.fileUploads.uploadStream({sessionId, name, data: this.#pull(id, bytes, signal), signal})`——`#pull` 是 async generator，循环 `transport.request('native.attachments.read', {id, offset, length})`，解码 base64 后 `yield`，`eof` 结束，同时统计字节数与 `size`/声明值对账。
  - 图片：先把整图读进内存（上限 `imageLimits.maxImageBytes`）→ `ctx.attachments.validateImage({data, mediaType, name})` → 记 `imageDigest`，与本地图片分支同规则（`attachments.mjs:99-124`）。
- **preview**：从同一 `#pull` 读整图（上限 `min(imageLimits.maxImageBytes, 远程预览上限)`），返回 `{id, kind:'image', name, mediaType, bytes, data}`。**远程预览上限需从 20 MiB 降到 ≤8 MiB**：下行单帧 16 MiB，base64 后 8 MiB 原始 ≈ 10.7 MiB，留出信封余量；超过则回 `IMAGE_PREVIEW_TOO_LARGE`（手机显示「图片已选，超过远程预览上限，可直接发送」）。
- **release**：**不删宿主文件**（宿主没有副本），只清记录并中止在途拉取；手机侧在 `attachments.release` 成功后自行删除本机缓存副本（设备内通道，不上线）。
- **content**：与本地相同的收据/摘要校验后再把 `{type:'file', receiptId}` / `{type:'image', data(base64), mediaType, name}` 交给 `sessions.send` 的既有装配点。
- **限制**：单连接串行拉取（一页一个来回）；页大小 256 KiB；每次 `prepare` 一个在途拉取；`close()` 中止全部。

#### 3.4.5 App 实现（Dart + Kotlin）

| 文件 | 改动 |
|---|---|
| **新** `apps/android/lib/attachment_surface.dart` | `AttachmentCallSurface`（`ready`/`phase`/`connectionGeneration`/`call`/`addListener`/`removeListener`，与 `terminal_runtime.dart:16-38` 的 `TerminalCallSurface` 同形）；`AttachmentDrafts` 的 `RuntimeController` 参数改为该接口（`apps/android/lib/attachments.dart:30-36`） |
| **新** `apps/android/lib/remote_attachments.dart` | `RemoteAttachmentSurface implements AttachmentCallSurface`：`call` → `RemoteConversationSource`/`RemoteConnectionController` 的请求；`ready/phase/generation` 投影连接控制器（与 `remote_terminal.dart` 同一做法） |
| `apps/android/lib/remote_native_bridge.dart`（新） | 在 `RemoteConnectionController` 建好传输后安装 `setRequestHandler`：只接 `native.attachments.read`（转 Kotlin 分页读），其它一律 `UnsupportedError` → `-32601`（§5.3 强制）。**必须覆盖整条连接**，不能只装到某个会话页 |
| `apps/android/lib/remote_conversation_live_source.dart` | `send` 增加 `attachmentIds`（`sessions.mjs:88-105`）；`submitCommand` 的 `attachmentIds` 由 `[]` 改为透传；新增 `createAttachmentSurface()` |
| `apps/android/lib/remote_conversation_source.dart` | 抽象类加 `send(text, {attachmentIds})`、`submitCommand(line, {attachmentIds})`、`createAttachmentSurface()` |
| `apps/android/lib/remote_dsh_conversation.dart` | 持有一个 `AttachmentDrafts`（remote surface）并渲染 `PocketAttachmentRail`（`apps/android/lib/attachments.dart:252-366`，无需改）；`+` 弹层的「文件」项 → `drafts.pick(sessionId)`；`_submit` 前 `snapshotIds`、成功后 `consume`（与 `main.dart:752-849` 同序） |
| `apps/android/lib/remote_dsh_page.dart` | 首页新建会话输入条不需要附件（新会话首条经会话页发送），保持 `_unavailable` |
| `AttachmentTransfers.kt` | 新 MethodChannel 方法：`attachment.read {id, offset, length}` → `{data(base64), nextOffset, size, eof}`；`attachment.discard {id}` 删除 `.bin/.json`。仅接受本 App 缓存目录内的 `<uuid>.bin`（`canonicalFile` + 目录相等校验，沿用 `:158-164` 的规则） |
| `apps/android/lib/image_preview.dart` | 远程模式下 `attachments.preview` 失败要说清原因（预览上限），不阻塞发送 |

#### 3.4.6 安全边界

| 风险 | 处置 |
|---|---|
| 文件路径逃逸 | 手机侧只解析 `<cacheDir>/pocket-attachments/<uuid>.bin`，`id` 走 uuid 正则；不做路径拼接（Flutter 侧永远拿不到路径，沿用 `AttachmentTransfers.kt:19` 的设计前提） |
| 宿主被伪造请求诱导读手机任意文件 | 手机只服务**当前草稿集合**内的 id（pick 时登记，release/dispose 时注销）；集合外一律 `attachment-file/not-found` |
| 大小放大/DoS | 宿主每页 256 KiB、`eof` 与声明 `bytes` 对账；总量受 `attachmentFileMaxBytes`（默认 256 MiB，`apps/android/runtime/index.mjs:105`）与图片限额（`packages/attachment/attachment-local/src/index.ts:36-40`）约束；手机上送的 `bytes` 只作声明，实际以累计字节为准 |
| 断开后残留 | 连接关闭 → 在途反向请求 `gateway/cancelled` → `uploadStream` 的 `signal` 中止 → 附件 store 清理 tmp；手机侧草稿在 App 重启/缓存清理时自然消失 |
| 图片炸弹 | 沿用宿主既有 `validateImage`（像素/尺寸/字节上限），手机不参与校验 |
| 配对信任口径 | 不新增监听、不新增凭据、不改变 TLS/撤销语义（HANDOFF §6.4） |

#### 3.4.7 本地模式零回归

- 宿主：Android 分支不构造 `DesktopAppAttachments`，`attachments.mjs` **一行不改**（D8）；`index.mjs` 只加一个三元分支与一处 `remoteFailure` 包装（包装放在 desktop 分支内，避免改变本地错误形状）。
- App：`AttachmentDrafts` 只把 `RuntimeController` 换成接口，`main.dart` 传 `runtime`（`RuntimeController implements AttachmentCallSurface`，成员已齐：`apps/android/lib/runtime.dart` 的 `ready`/`phase`/`connectionGeneration`/`call`/`addListener`）；本地行为、文案、测试不变。
- 验证门：`flutter analyze` 无新增告警 + `flutter test` 全量（含 `attachments` 相关既有测试）；宿主 `tsc -p apps/remote-host` + 冒烟 14/14。

### 3.5 里程碑与验收

| 里程碑 | 交付 | 验收 |
|---|---|---|
| **A0 取证** | e2e 增一条「`attachments.prepare` 随机 id → `-32603` + ENOENT」 | 现有 16/16 不回归，新增项 PASS 并打印该文案 |
| **A1 协议与宿主** | `protocol.md` §5.2 追加一行 + `attachments-desktop.mjs` + `index.mjs` 接线 + Node 单测（fake transport：正常分页、短读、`eof`、`-32601`、断连中止、字节对账） | `node --test apps/android/tool/attachments-desktop.test.mjs` 全绿 |
| **A2 宿主 e2e** | e2e 客户端实现 `native.attachments.read`（用固定 1.5 MiB 夹具文件），走通 `prepare → session.send` | 真实宿主下 `e2e-remote-host.ts` 全 PASS，第 17 项起新增附件检查 |
| **A3 App 接线** | `attachment_surface.dart`、`remote_attachments.dart`、`remote_native_bridge.dart`、Kotlin 分页读、会话页 rail + `attachmentIds` | `flutter test`（新增 `remote_attachments_test.dart`：小文件、多页大文件、断连、旧宿主无 handler 时的 `attachment-file/unsupported`、移除后重试） |
| **A4 真机** | ① 选一张 5 MiB 照片发送并看到模型收到 ② 选一个 3 MiB PDF 发送 ③ 上传中点移除 ④ 上传中断网 → 失败可重试，恢复网络后重试成功（草稿仍在手机上） ⑤ 杀 App 重开后草稿消失、宿主无残留（`attachments.release` 幂等） ⑥ 大图预览超限提示且不阻塞发送 | 截图 `.cache/remote-device/p5c-a*.png`；日志无裸 `-32603` |

### 3.6 风险与延后项

1. **手机侧分页读的通道成本**：一个 8 MiB 照片 = 32 次反向请求往返（256 KiB/页）+ 32 次设备内 MethodChannel 调用（不经过网络）。局域网实测应在 1–3 s；若真机偏慢，优先把页大小提到 512 KiB（仍远低于 1 MiB 上行帧），而不是上 v2。
2. **反向请求 id 偏差**（HANDOFF §4.3 / §7 #14）：`native.attachments.read` 的响应 id 由 App 原样回填，与宿主 `req_…` 前缀问题无关；A 不依赖该修复。
3. **图片预览上限**：远程缩到 8 MiB 后，大图「已选不预览」；若要完整预览，需把图片转成宿主侧缩略图（新方法/新能力）——延期。
4. **附件草稿的跨页面归属**：`AttachmentDrafts` 目前按 `sessionId` 分桶（`apps/android/lib/attachments.dart:37`），远程页与首页各持一个实例即可，不做全局单例。
5. **并发多设备**：v1 单设备（`protocol.md:708`），不需要处理两台手机同时拉同一 id。

---

## 4. 主题 B：输入区能力（`+` 弹层 / 方案模式 / 语音 / 审批预设）

### 4.1 控件盘点：本地数据源与远程判定

| 控件 | 本地实现与数据源（证据） | 远程可用的门面方法 | 判定 | 工作量 |
|---|---|---|---|---|
| `+` 弹层 | `ComposerCommands`：`api.call {commands, list}` + 客户端动作 `file`/`model`/`export`/`skills`（`composer_commands.dart:76-87`、`:116-137`、`:399-518`；装配 `main.dart:1442-1470`，动作分发 `main.dart:639-687`） | `api.call`、`session.ensure`、`session.command`、`session.export.*` 均已在冻结表 | **做**（重建为数据驱动） | M |
| 方案模式 | `ChatGoalPlanController`：读 `session.projections`（`chat_goal_plan_state.dart:168-197`）、实时 `session/control`（`:121-129`）、写 `session.command '/plan'`（`:344-391`） | 同上，全部已在表内；宿主 `plan-mode` 默认启用 | **做** | S |
| 语音 | 本地无任何实现：无录音代码、无语音依赖（`apps/android/pubspec.yaml` 无 speech/record 包；全仓 `语音` 仅出现在远程占位组件） | 无（DSH 侧是 experimental 的浏览器录音 + 宿主 SenseVoice，`packages/experimental/client-ui-voice-input`、`.../speech-to-text-sensevoice`、`.../api-speech-to-text/src/index.ts:88-104`） | **不做**（替代：系统输入法语音听写） | 0 |
| 审批预设 | 本地 `SessionPermissionPage`：`api.call {permissionPresets, catalog}` + `session.projections.values.permissions` + `session.command '/permission <值>'`（`composer_commands.dart:571-638`） | 同一套 api.call / session.command；**但宿主 profile 未启用 `permission`**（`apps/remote-host/cordis.patch.yml:117-122` 仍列为待确认） | **做**（需先启用宿主 `permission`，D5） | M |
| 追求目标（goal） | `ChatGoalPlanController` 的 goal 分支：`api.call {goals, get/create/pause/...}` + `session.projections.values.goal` + **`goal/activation-changed` 运行时事件**（`chat_goal_plan_state.dart:277-316`） | 前两项可走 `api.call`；激活态没有远程通知（protocol §8 是封闭清单 `remote.taskCompleted/approvalPending/deviceRevoked/sessionChanged`） | **延期**（D6） | L |
| 相机 | 本地无：`attachment.pick` 是 `ACTION_OPEN_DOCUMENT */*`（`AttachmentTransfers.kt:38-41`），没有拍照入口 | 无独立数据源（拍照只是「选文件」的一种来源） | **不做** | 0 |
| 照片 | 同上（文件选择器已能选图片） | 同上 | **不做**（并入「文件」） | 0 |
| 插件 | 本地是独立全屏目的地（`apps/android/lib/plugins.dart`），不在 composer 里 | 门面有 `pluginManager` 相关能力，但对应的是独立页面而非输入区 | **不做**（不属于输入区） | 0 |

**判据**：HANDOFF §6.2 / plan §12.7 要求「新增控件前先回答数据源是哪个门面方法」。上表中被判「不做」的四项（语音/相机/照片/插件）都无法给出**输入区级**的方法来源；而「追求目标」有方法来源却缺一条通知。

### 4.2 `+` 弹层（做，M）

**线上方法**：`session.ensure {sessionId}` → `api.call {namespace:'commands', method:'list', args:{agentId: sessionId}}`。两者都在冻结表内（`protocol.md:288`、`:289`），宿主侧无改动。

**App 侧改动点**：

1. `apps/android/lib/composer_commands.dart`：把 `ComposerCommands` 与 `loadComposerCatalog` 的 `RuntimeController` 依赖抽成 `ComposerCommandSurface`（`ensureSession` + `call` + `ready`），与 A 的 `AttachmentCallSurface`、终端的 `TerminalCallSurface` 同形（同一个 `RuntimeController` 天然满足）。
2. `apps/android/lib/remote_commands.dart`（新）：`RemoteComposerCommandSource`——用 `RemoteConversationSource` 实现；`commands/list` 走 `api.call`（与 `remote_dsh_live_source.dart:1356-1361` 的既有直呼先例同形）。
3. `apps/android/lib/remote_dsh_conversation.dart`：`_openAddSheet` 改为弹出 `CommonPopup` 里的 `ComposerCommands`（本地即如此，`main.dart:1442-1470`）；选中项的分发复用既有 `pickCommand` 语义（`main.dart:639-687`），远程只支持子集：
   - `file` → A 的 `drafts.pick`（未落地前该行置灰 + 原因）；
   - `model` → 既有模型 sheet（已实现）；
   - `plan` → §4.3；
   - `export` → 远程只能「导出到电脑」：`session.export.prepare` 在宿主生成 ZIP（`apps/android/lib/export.dart:54-70`），但把 ZIP 保存到手机要经过设备侧 `sessionExport.save` + `native.exports.directory`（`export.dart:88-102`），而后者在远程被宿主拦截成 PC 目录（`apps/remote-host/src/native-desktop.ts:350-356`）。**本轮不做**（下载方向与 A 同类，另开一项）；如需最小可用，只显示「已导出到电脑」并把路径写进文案。
   - 其它宿主指令（`compact` 等）→ 直接作为 `/name` 走 `session.command`（本地同路径）。
   - `skills` → **可做但不在本轮**：数据源是 `api.call {namespace:'skills', method:'list', args:{request:{sessionId}}}`（`apps/android/lib/skills.dart:175-183`），与 `session.projections` 同一套通用透传，宿主侧有该命名空间（`packages/client/connection/tests/node-half.host.spec.ts:373` 的端点表），落地时需要把 `SessionSkillsController` 也接口化；排到 B 之后。
4. `apps/android/lib/remote_dsh_page.dart`：首页输入条 `+` 保持不可用（首页不是会话，无 `sessionId`），文案改为「进入会话后可添加附件与指令」，避免「能点但没用」。
5. `apps/android/lib/remote_dsh_widgets.dart`：删除 `RemoteAddAction`/`RemoteAddActionSheet` 六项常量（换成数据驱动后无用），保留 `RemoteComposer` 的布局（`+`、盾牌、模型、麦克风四键）；`+` 的 `label` 文案改为「添加与指令」与本地一致。

**三态降级**：`api.call` 不可用（握手 `methods` 无）→ `+` 置灰 +「这台电脑不支持会话指令」；`commands/list` 返回失败 → 弹出层内「会话菜单暂不可用」+ 重试（本地已有该分支，`composer_commands.dart:464-490`）；未连接 → 「正在连接电脑…」。

**测试点**：fake source 下 `+` 打开即读目录、分组顺序与本地一致（添加/指令）、`file` 行置灰理由、命令选中后 `session.command` 的 line、`commands/list` 失败可重试、`api.call` unsupported 时 `+` 置灰。

### 4.3 方案模式（做，S）

**线上方法**（全部冻结表内）：`api.call {namespace:'session', method:'projections', args:{request:{sessionId}}}`、`api.subscribe {namespace:'session', method:'control'}`（协议 §6.1 通用参数）、写 `session.command {sessionId, line:'/plan' | '/plan off', attachmentIds:[]}`。

**实现要点**：

- 新文件 `apps/android/lib/remote_goal_plan.dart`：`RemoteGoalPlanController`——按 `ChatGoalPlanController` 的结构只做 plan 部分（`start/refresh/setPlan`；goal 分支按 D6 不做），依赖 `RemoteConversationSource` 的 `call` 与流订阅能力。
- `RemoteConversationLiveSource` 增加：`readProjections()`、`watchSessionControl()`（新 `streamId`，走既有 `AppApiStreams`，保持 `api.ack` 窗口语义）、`submitPlan(bool)`。
- 会话页输入区上方复用 `ChatPlanDock`（`apps/android/lib/chat_plan.dart:141-200`），`plan.target` 为 true 时显示「计划模式」条与「退出计划模式」。
- 计划提交卡片（`exit_plan_mode` 的审批）走既有 `interactions.*`，宿主侧已经原样透传问题对象（含 `intent`）：`apps/android/runtime/interactions.mjs:243-249`（`questions: record.request.questions`）。App 侧只差解析：`RemoteQuestion`（`apps/android/lib/remote_conversation_source.dart:268-297`）没有 `intent` 字段，`_questionOf`（`apps/android/lib/remote_conversation_live_source.dart:1015-1040`）也没读它。补上 `intent` 后即可复用本地 `planReviewOf` / `planReviewPreview`（`apps/android/lib/approvals_draft.dart:96-125`）渲染「计划审核」卡片与一屏计划原文（`detail` 已经在解析）。
- 计划原文的展示：远程提问对象已带 `detail`（计划 markdown）；卡片若只显示摘要，则点「查看计划」推入既有 `ChatPlanDocumentPage`（`apps/android/lib/chat_plan.dart:291-300`），不需要新页面。

**三态**：未连接 → 条不显示（不置灰一个不存在的条）；`session.projections` 失败 → 「无法确认计划模式状态」+ 重试；`session.command` 失败 → 保留草稿并提示（本地同语义，`chat_goal_plan_state.dart:378-384`）。

**测试点**：projection 里 `plan:{active,pending}` 四组组合的 UI；`/plan` 与 `/plan off` 的 line；`session/control` 增量更新；状态读失败降级；切换模型/重连后重读。

### 4.4 语音（不做）

不做理由按「数据源优先」排序：

1. **数据源问不出输入区级方法**：DSH 的语音是 Web 客户端插件 + 宿主 experimental bundle 的组合（`packages/experimental/voice-input-bundle`），录音在浏览器 `MediaRecorder`，转写在宿主 SenseVoice；手机侧要自己实现录音与 WAV 编码，等于新写客户端半边。
2. **experimental 不能进 shipped profile**：远程宿主是产品 profile，按 `packages/experimental/AGENTS.md` 不得依赖 experimental 包；要启用只能让用户像 Web 一样手动装插件，属于 P6 的插件市场问题。
3. **尺寸约束同一套问题**：`speech.transcribe` 默认单次音频 4 MiB（`packages/experimental/api-speech-to-text/src/index.ts:31`），base64 后已超 1 MiB 上行帧；真要做得先解决和 A 同类的字节上行——而 A 已经用掉了这条通道的额度。
4. **产品替代**：Android 输入法自带语音听写，用户长按键盘即可；App 内再做一套不增加能力。

结论：面板上的麦克风按钮在远程页面**移除**（当前 `RemoteComposer` 会画一个永远 disabled 的麦克风，`remote_dsh_widgets.dart:619-623`）；本地页面本来就没有麦克风，删掉不影响本地。

### 4.5 审批预设（做，M；依赖 D5）

**两条路对比**

| 维度 | 路线①：启用桌面审批预设（推荐） | 路线②：维持一次性审批 |
|---|---|---|
| 语义来源 | DSH 既有 `permissionPresets`：`read-only` / `workspace-write` / `danger-full-access` /（装了 auto-review 时）`auto`；写路径是 `/permission` 命令（`packages/interaction/permission-presets/src/index.ts:254-266`） | DSH 既有 `user-approval` 的一次性结果：只有 `allowed-once` 是授权（`packages/interaction/user-approval/src/types.ts:32`） |
| 远程可用性 | 宿主启用 `permission` 后，三件事一次到位：`runtime.permissions.presets.available=true`（`apps/android/runtime/index.mjs:803-821`）、`commands/list` 出现 `permission`、`session.projections.permissions` 有当前值 | 现状即可用，无需改动 |
| 语义来源补充 | 预设 = 沙箱模式 + 审批策略的组合（`permission-presets` 的 `resolve()`），且要求执行器可界定（`packages/interaction/permission-presets/src/index.ts:215-217`）；远程宿主已恢复 `bash-sandbox`/`pwsh-sandbox`（`apps/remote-host/cordis.patch.yml:52-65`），条件满足 | — |
| 用户价值 | 长任务不必逐条点；可解释「为什么不需要确认」 | 每个越界操作都要回到手机点一次，长任务不可用 |
| 安全面 | 手机可把宿主切到 `danger-full-access`（= 模型可无确认操作整台电脑）。配对本身已是「完全信任这台电脑」（HANDOFF §6.4），但仍是**权限提升的单点** | 每一步都要人确认，最保守 |
| 实现成本 | 宿主 patch 一行 + App 复用 `SessionPermissionPage`（接口化）+ 三态 + 测试 | 0 |
| 风险 | 需要真机验证「切到 danger-full-access 后桌面 agent 行为」并写进文案 | 无 |

**推荐路线①**，但加三道约束：
1. 宿主 patch 只加 `- id: permission / disabled: false`（`apps/remote-host/cordis.patch.yml`）；`auto` 预设依赖 `auto-review`，是否一起启用单独决定（不启用时 catalog 自然少一项，三态降级）。
2. 手机端**复用** `SessionPermissionPage` 的二次确认（`composer_commands.dart:602-611`、`:683-717`）：`danger-full-access`/`auto` 必须勾选风险确认后才能提交。
3. `RemoteApprovalSheet`（`remote_dsh_widgets.dart:632-697`，四项「请求批准/替我批准/完全访问/自定义」）**删除**：这四项是照截图抄的 Codex 词汇，与 DSH 的真实 preset 集合不对应（DSH 里没有「替我批准」，只有 auto-review 的 LLM 预审）。盾牌按钮改为打开 DSH preset 列表（数据来自 `permissionPresets.catalog`）。

**线上方法**（0 新增）：`api.call {permissionPresets, catalog}`、`api.call {session, projections}`、`session.command '/permission <值>'`、能力探测 `runtime.permissions`（冻结表内，`protocol.md:287`）。

**App 侧改动点**：`composer_commands.dart` 的 `SessionPermissionPage` 抽 `PermissionCallSurface`（同 A/B 的接口化范式）；新 `remote_permissions.dart`；`remote_dsh_conversation.dart` 的盾牌按钮 → preset 列表；会话页输入区上方显示当前 preset（数据来自 projections）。

**三态**：`runtime.permissions.presets.available == false`（宿主未启用）→ 盾牌置灰 +「这台电脑未启用权限预设」；握手未就绪 → 「正在连接电脑…」；`permissionPresets.catalog` 单次失败 → 弹层内错误 + 重试（**不写永久不支持缓存**，§10.2 第 3 条）。

注意 `permission_policy.dart:23-64` 的 `ExecutionPermissionPolicy.parse` 只认 Android 形状（`shell.tool == 'android_shell'`），远程形状是 `{tool:'desktop-host', …}`（`apps/android/runtime/index.mjs:803-808`），远程侧需要独立的宽松解析（只取 `presets.available` 与 `fileTools.sandboxMode`），不要复用这个严格解析器。

**测试点**：preset 列表来自 catalog（顺序/描述/当前值打勾）、`danger-full-access` 二次确认门槛、`/permission <值>` 命令 line、宿主未启用时置灰、catalog 失败可重试、切换后 projections 刷新、与一次性审批卡片共存（预设只影响新请求，不自动通过已挂起请求）。

### 4.6 B 的里程碑与验收

| 里程碑 | 交付 | 验收 |
|---|---|---|
| **B1 `+` 弹层** | `ComposerCommandSurface` 接口化 + `remote_commands.dart` + 会话页接入 + 删六项占位常量 | `flutter test`（`remote_composer_commands_test.dart`：分组、置灰、失败重试）+ 本地 `composer_commands_test.dart` 全绿 |
| **B2 方案模式** | `remote_goal_plan.dart` + 会话页 `ChatPlanDock` + live source 的 projections/control/plan 写 | `flutter test`（plan 四态、line 断言、control 增量、失败降级） |
| **B3 审批预设**（D5 通过后） | 宿主 patch 一行 + `SessionPermissionPage` 接口化 + `remote_permissions.dart` + 盾牌改造 | 宿主 `tsc` + 冒烟；`flutter test`；真机切换 preset 后 `session.projections` 复读 |
| **B4 真机** | ① `+` 打开看到宿主指令目录 ② 选 `/plan` 进入计划模式并提交计划审核 ③（D5 通过）切到 `workspace-write` 后新请求确认数下降 ④ 语音按钮消失 | 截图 `.cache/remote-device/p5c-b*.png` |

### 4.7 B 的风险

1. **`commands/list` 可能要求 Agent 已 attach**：`loadComposerCatalog` 先 `ensureSession`（`composer_commands.dart:80`），远程 `session.ensure` 需要宿主恢复会话；冷会话可能触发宿主唤醒（与终端一致，建议接受并写进文案）。
2. **`session/control` 流的额外订阅**：单连接并发流上限 32（`protocol.md:95`），会话页当前已用 `session.follow`，再加一条无压力；但断线重连要按 §7.2 顺序重订阅（`remote_conversation_live_source.dart:485-508` 已有范式）。
3. **`permission` 启用后的桌面行为变化**：同一条会话在桌面网页端也会看到 preset 变化（同一 session 投影），需要在真机/桌面同时回归一次。
4. **`auto` 预设**：不启用 auto-review 时 catalog 少一项；启用则每步调用都要额外 LLM 预审，成本可见性需要文案说明（本地已有该提示文案，`composer_commands.dart:683-717`）。

---

## 5. 主题 C：模型路由前置提示

### 5.1 现状与缺口（根因取证）

**已有**（不是待做项）：

| 能力 | 证据 |
|---|---|
| 会话路由来自窗口投影（`model/selection` / `request/header`） | `apps/android/lib/session_model_projection.dart:44-68`；`remote_conversation_live_source.dart:759-774` |
| 首屏异步判定「当前路由的服务商在电脑上是否可用」，不阻塞、失败不升级为页面错误 | `remote_conversation_live_source.dart:453-467`、`:779-834` |
| 输入区上方提示条 +「选择模型」动作；同一路由成功发送后不再显示 | `remote_dsh_conversation.dart:405`、`:1265-1282`、`:186-189` |
| 发送失败后的凭据类自动兜底：读 `settings.describe` 默认路由 → 不同则 `session.selectModel` → 重发一次 | `remote_dsh_conversation.dart:1073-1153`（`_retryWithDefaultRoute`）；`remote_conversation_live_source.dart:398-407` |
| 宿主默认模型设置页 | `remote_dsh_settings_page.dart`（P5b） |

**缺口的根因**：判定输入只有 `session.modelCatalog.failures[].id`，而「桌面创建、路由为 `deepseek-official`、宿主只带账号凭据」这一情况在目录里是**静默缺席**，不是 failure：

1. `deepseek-official` 的 `discoverModels` 在无 API Key 时**返回空数组、不抛错** → `packages/llm/llm-deepseek-api-key/src/index.ts:101-111`（`presentApiKey` 返回 undefined 时 `return []`）。
2. `listModels` 原样透传空数组 → `packages/llm/llm/src/index.ts:718-721`。
3. `buildModelCatalog` 只把**抛错**的服务商放进 `failures`，空 group 被过滤 → `packages/api/session-controller/src/catalog.ts:20-72`（`:65-71`）。
4. App 解析时只读 `failures`，不读 `routableProviders` → `remote_conversation_live_source.dart:1105-1121`。
5. 页面判定 `failedProviders.contains(choice.provider)` → 不命中 → **发送前无提示**；用户点发送后才失败，然后走自动兜底重发（HANDOFF §3.5 描述的真实体验）→ `remote_dsh_conversation.dart:1265-1282`。

这也解释了 HANDOFF §4.2 与代码现状看似矛盾：**机制已落地，判定口径漏了一路信号**。

### 5.2 最小实现方案

**在哪一层判定**：数据源（`RemoteConversationLiveSource._runModelAvailabilityCheck`），**不是**会话页首屏投影，也**不是**新增 `fetchDefaultModelRoute` 对照。理由：

- 判定所需信息（`modelCatalog`）本来就在数据源里按「打开/重连」周期缓存一次（`remote_conversation_live_source.dart:236-251`、`:829-834`），页面拿不到也不该拿；
- 首屏投影只有路由，没有可用性；
- `fetchDefaultModelRoute` 是另一条读（`settings.describe`），只在兜底重发时用；拿它做前置判定会多一次请求，且无法区分「默认路由未变、只是凭据缺失」。

**改动清单（App 侧 3 处，宿主 0 处）**：

| 文件 | 改动 |
|---|---|
| `remote_conversation_source.dart:555-578` | `RemoteModelCatalog` 增加 `routableProviders`（`Set<String>`） |
| `remote_conversation_live_source.dart:1072-1122` | `_catalogOf` 解析 `result['routableProviders']`（缺失时退化为非空 group 的 id 集合）；新增 `unavailableProviders = failedProviders ∪ 不在 routableProviders 里的服务商` |
| `remote_conversation_source.dart:239-245` | `RemoteConversationModelAvailability` 的字段由 `failedProviders` 改为 `unavailableProviders`（`remote_dsh_conversation.dart:300-304` 只做集合替换，语义不变） |

页面不改：`_modelRouteNotice` 继续用 `contains`；提示文案「当前会话绑定的模型在电脑上不可用，发送时会自动改用电脑默认模型」已经把两件事说清（不可用 + 会自动改用默认模型），无需改字。若要更准，可把默认路由名带进文案（`catalog.defaultChoice` 已有），但那会引入一次额外读，非必需。

**是否阻塞**：**不阻塞**。发送路径的自动兜底已经存在（`remote_dsh_conversation.dart:1073-1153`），提示只是提前告知；阻塞会让「用户只是打开历史会话什么都不发」的场景也要等目录读，违反 protocol §3.4 的就绪判据（`protocol.md:256-262`）。

**三态**：未连接 → 不显示；目录读取失败 → 不显示（不误报，`remote_conversation_live_source.dart:830-834` 已把失败缓存为 null）；命中 → 显示。

### 5.3 测试点

| 用例 | 断言 |
|---|---|
| catalog 有 `routableProviders` 且不含当前 provider，`failures` 为空 | 显示提示（这就是 HANDOFF §4.2 的场景） |
| provider 在 `failures` 里（凭据读取报错） | 显示提示（既有行为不回归） |
| provider 在 `routableProviders` 里 | 不显示 |
| 宿主返回旧形状（无 `routableProviders` 字段） | 用非空 group id 兜底，不误报 |
| 目录读取失败 | 不显示，发送不受影响 |
| 同一路由成功发送后 | 不再显示（`_routeConfirmed` 既有行为） |
| 切到可用路由后 | 提示消失 |

落点：`apps/android/test/remote_conversation_live_source_test.dart`（已有 failedProviders 用例，`:1385`、`:1427`、`:1495`）与 `apps/android/test/remote_conversation_page_test.dart:1070-1168`。

### 5.4 里程碑

| 里程碑 | 交付 | 验收 |
|---|---|---|
| **C1 数据源** | `routableProviders` 解析 + `unavailableProviders` 语义替换 | `flutter test apps/android/test/remote_conversation_live_source_test.dart` 全绿（新增 4 例） |
| **C2 页面** | 页面侧无需改；补一条「安静缺席的 provider 显示提示」widget 用例 | `flutter test apps/android/test/remote_conversation_page_test.dart` |
| **C3 真机** | 在宿主不配 `DEEPSEEK_API_KEY` 的环境打开桌面创建的 `deepseek-official` 会话，**发送前**看到提示 | 截图 `.cache/remote-device/p5c-c1.png`；点「选择模型」直接进模型 sheet |

C 的第二半（「是否允许按可用凭据自动选择默认模型」）**建议不做**：宿主设置页（`RemoteDshSettingsPage`）已经能改默认模型，自动改默认模型是跨会话的持久副作用，应由用户显式决定；发送时的一次性兜底已经覆盖「不想被打断」的场景。

---

## 6. 跨主题风险与开放问题

1. **协议修订的边界（D1/D2）**：A 只需要 §5.2 一行 + 一条注记。任何需要「新 App→宿主方法 / 新帧类型 / 新 capability / 版本号变化」的方案都视为越界，应重新回到本文件 §3.3 讨论，而不是在实现里悄悄加。
2. **并发施工**：`remote_dsh_conversation.dart`、`remote_dsh_page.dart` 正在被并行施工改动（最近一次写入 2026-11-15 23:44，与终端落地重叠）。A/B/C 落地时需要与终端 Agent 协调同一文件的改动顺序（A 与 B 都动 `remote_dsh_conversation.dart`，C 不动它，可先落 C）。
3. **`+` 弹层与附件的耦合**：B 的「文件」行依赖 A；建议 A 先落，B 的 `+` 再上，否则会出现「菜单里只有占位灰色项」的中间态。
4. **审批预设与一次性审批共存**：预设只影响**新**审批请求（`approval` 的 policy 由 preset 决定），已挂起的请求仍逐条答复；实现时不要在「切换预设」时批量自动通过——那会绕过 `user-approval` 的语义（`packages/interaction/user-approval/src/types.ts:32`）。
5. **远程预览上限（8 MiB）是产品妥协**：若产品要求「手机远程也能看原图」，正确做法是宿主侧生成缩略图（新方法/新能力，v2 议题），不是抬帧上限。
6. **A 与 C 都不新增能力声明**，所以握手 `methods`/`unsupported` 不需要改；A 的「旧 App 回 `-32601`」由协议 §5.3 的强制语义覆盖，手机侧展示 `attachment-file/unsupported`。
7. **`attachments.preview` 的错误包装**：A 落地时会把附件错误包成 `_pocket_error`（§3.4.3），这会**同时改变 Android 本地链路的错误形状**（若包装写在外层）。必须把包装放在 desktop 分支内部，或在 App 侧按 code 前缀兼容；否则本地附件文案会变。这是 A 里最容易踩的回归点。
8. **e2e 假 App 需要会「答反向请求」**：现有 e2e 对反向请求一律回 `-32601`（`apps/remote-host/scripts/e2e-remote-host.ts:972-991`），A2 要给它加一个真实的 `native.attachments.read` 应答器；这也顺便让 `HOST_LOCAL_NATIVE_METHODS` 的断言（`:89-99`）继续成立——新方法属于「转发给 App」，不在本机拦截表里。
9. **同类问题（本轮不修，需记录）**：历史附件读取 `session.attachmentFile.*` 在远程组合下把私有缓存写到**宿主**目录（`apps/android/runtime/index.mjs:610-614` 取 `native.attachmentFiles.directory`，被 `apps/remote-host/src/native-desktop.ts:350-356` 拦截成宿主目录），所以远程查看会话里的历史附件同样不可用。A 的反向通道是它未来的解法（方向相反：手机向宿主分页取字节）；本轮先记录，不扩范围。
10. **`+` 弹层里 `skills` 的可行性**：`skills/list` 与 `session.projections` 同为 typert Remote 命名空间、App 侧同样经 `api.call` 直呼（`apps/android/lib/skills.dart:175-183`），宿主侧在标准远端端点表内（`packages/client/connection/tests/node-half.host.spec.ts:373`）；因此它属于「下一轮可做」，不是「没有数据源」。

---

## 7. 明确不做（本轮）

| 项 | 理由 |
|---|---|
| 协议 v2 / 二进制帧 / 分块重组 | §3.3；收益只有带宽，成本是双端版本窗口 |
| 手机拍照直传（`ACTION_IMAGE_CAPTURE`） | 无 DSH 数据源，也无本地实现；文件选择器已覆盖 |
| 语音输入 | §4.4 |
| goal（追求目标）远程化 | 需要新增 `remote.*` 通知（protocol §8 封闭清单），D6 延期 |
| 远程附件「保存到手机」（`session.attachmentFile.*`） | 属于下载方向：协议已有分片读方法，但远程组合下私有缓存目录取错（见 §6 第 9 条），本轮不修；不在 P5 剩余范围内 |
| 自动改宿主默认模型 | 见 §5.4 末段；跨会话副作用应由宿主设置页显式执行 |
| 预览大图 / 原图预览 | 见 §6 第 5 条；需要宿主缩略图能力 |

---

## 附录 A · 协议修订文案（待 D1/D2 通过后由 lead 落 `protocol.md`）

§5.2「拦截与转发表」追加一行：

```markdown
| `native.attachments.read` | **转发给 App** | 分页读取手机附件草稿的私有副本（附件上行 P5）；v1 旧 App 回 `-32601`，宿主以 `attachment-file/unsupported` 失败 |
```

§11「v1 明确不做」表格中「二进制分块上传」一行追加一句注记（不改结论）：

```markdown
| 二进制分块上传 | …（原文不变）… 附件的字节读取仍以分片读推进：宿主用反向请求 `native.attachments.read` 逐页拉取手机草稿，App→宿主方法表不新增方法、不引入二进制帧、宿主侧不做分块重组。 |
```

不改动：§1.2 帧格式、§1.3 帧上限、§4.1/§4.2 方法表、§6 流控、§10 能力协商、`protocolVersion`。

## 附录 B · 证据索引（按文件）

| 文件 | 关键行 |
|---|---|
| `apps/android/docs/remote-dsh/protocol.md` | 89-98（帧上限）、266-304（方法表）、297（attachments 备注）、308-357（反向请求）、320-332（§5.2 表）、334-347（§5.3）、349-357（§5.4）、363-401（§6.1）、664-699（§10）、703-715（§11） |
| `apps/android/docs/remote-dsh/HANDOFF.md` | 264-277（§3.5 模型路由）、282-287（§4 剩余）、344-351（§6 硬约束） |
| `apps/android/runtime/attachments.mjs` | 6（uuid 正则）、8-9（32 MiB/20 MiB）、51-71（describe）、73-153（prepare/upload）、175-183（图片错误）、236-310（content/preview） |
| `apps/android/runtime/index.mjs` | 105-107（附件限额）、187-220（晚绑定传输）、564-575（attachments 构造）、803-821（runtime.permissions）、869-871（dispatch）、1004-1021（facade methods） |
| `apps/android/runtime/attachment-files.mjs` | 11-12（文件名规则）、114-173（分片写缓存） |
| `apps/android/runtime/sessions.mjs` | 78-105（send + attachmentIds） |
| `apps/android/runtime/streams.mjs` | 59-85（api.subscribe 通用参数） |
| `apps/android/lib/attachments.dart` | 29-119（drafts/pick）、124-167（prepare）、196-216（consume）、252-366（rail） |
| `apps/android/lib/remote_conversation_live_source.dart` | 236-251（目录缓存）、282-306（send/command）、398-407（默认路由）、453-467（首屏判定）、759-834（可用性判定）、1072-1122（catalog 解析） |
| `apps/android/lib/remote_conversation_source.dart` | 239-245（availability）、555-578（catalog 类型）、713+（抽象源） |
| `apps/android/lib/remote_dsh_conversation.dart` | 186-189（failedProviders 说明）、389-416（底部区）、743-880（输入区）、1189-1218（`+`/盾牌占位）、1265-1282（路由提示）、1891-1897（占位 preset 文案） |
| `apps/android/lib/remote_dsh_widgets.dart` | 484-629（输入区组件）、632-771（占位审批/添加弹层） |
| `apps/android/lib/composer_commands.dart` | 76-87（指令目录）、116-137（分组）、378-518（本地 `+`）、546-638（权限预设页） |
| `apps/android/lib/chat_goal_plan_state.dart` | 111-132（读投影/流）、344-391（`/plan` 写） |
| `apps/android/lib/session_model_projection.dart` | 44-68（`request/header` → 路由） |
| `apps/android/lib/permission_policy.dart` | 23-64（严格 Android 形状解析） |
| `apps/android/lib/terminal_runtime.dart` | 16-38（`TerminalCallSurface` 范式） |
| `apps/android/android/.../AttachmentTransfers.kt` | 19、31-46、65-130、158-164 |
| `apps/remote-host/src/index.ts` | 350-362（facade 服务面）、487-490（bind + dispatch）、782-795（createFacadeSink） |
| `apps/remote-host/src/native-desktop.ts` | 318-336（handles）、346-356（应答）、398-412（附件目录） |
| `apps/remote-host/cordis.patch.yml` | 43-45（attachment-local）、52-65（沙箱恢复）、117-122（permission 待确认） |
| `apps/android/runtime/cordis.patch.yml` | 18-21（permission/ui-permission 禁用）、28-29（attachment-local 禁用） |
| `packages/client/file-upload/src/index.ts` | 112-140（upload/uploadStream）、194-196（resolve） |
| `packages/api/session-controller/src/catalog.ts` | 20-72（目录构造，失败只来自抛错） |
| `packages/api/session-controller/src/index.ts` | 620-623（projections）、630-644（control 流）、343-346（modelCatalog） |
| `packages/api/session-controller/src/types.ts` | 134-141（`routableProviders`） |
| `packages/llm/llm-deepseek-api-key/src/index.ts` | 37-46（MISSING_CREDENTIAL）、101-111（无 Key 返回空目录） |
| `packages/llm/llm/src/index.ts` | 718-721（listModels 透传） |
| `packages/interaction/permission-presets/src/index.ts` | 215-217（需可界定执行器）、239-246（permissions 投影）、254-266（`/permission` 命令） |
| `packages/interaction/user-approval/src/types.ts` | 32（一次性授权语义） |
| `packages/plan/plan-mode/src/index.ts` | 136-137（plan 投影）、232-235（`/plan` 命令） |
| `packages/sdk/protocol/src/transport.ts` | 278-288（handler 失败 → `-32603`） |
| `packages/attachment/attachment-local/src/store.ts` | 349-388（流式入库与中止清理） |
| `apps/remote-host/scripts/e2e-remote-host.ts` | 61-70（REQUIRED_METHODS）、89-99（本机拦截表）、972-991（反向请求应答） |
| `apps/android/test/remote_conversation_page_test.dart` | 1070-1168（路由提示用例） |
