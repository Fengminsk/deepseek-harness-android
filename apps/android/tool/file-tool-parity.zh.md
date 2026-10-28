# Android Agent 文件工具：授权与分页协议

原版 DSH 的 `read`、`read_image`、`write` 和 `edit` 使用 Android 的 `AndroidFileSystem` 提供方。模型文件守卫将 `read`、`read_image`、`write`、`edit`、`present` 限制在启动时固定的 App 工作区内。`write` 仍由提供方的 `workspace-write` 修改策略约束，但通用策略的临时目录例外不会授权模型 `write` 访问 App 私有临时文件；App 内部服务仍可使用该例外。[无密钥 ToolRuntime 投影](expected/model-file-write-guard.expected.json)记录工作区写入成功以及守卫和提供方各自的拒绝结果。

原版 `glob` 和 `grep` 通过受保护的子进程接口执行随包提供的 ripgrep。相对路径以固定的会话工作目录为基准。这些路径是普通文件路径，不能是 `content://` URI。`glob` 可报告工作区内匹配的文件路径；`android_files/list` 可列出明确 SAF 授权范围内的目录。原版 `str_replace_editor` 的目录 `view` 仍被拒绝：它会遍历两层并跟随子项符号链接，[无密钥 ToolRuntime 投影](expected/model-directory-guard.expected.json)记录了 App 私有文件名的泄露。`AndroidFileSystem.listDir` 还会在实际操作点拒绝模型上下文的目录枚举，包括检查时是文件、执行前变成目录的情况；App 内部服务仍可列目录。这条入口保持关闭，上述能力尚不能等同替代原版目录 `view`。模型上下文的 stat／read 操作会在实际读取时重新解析已保存的目标；延迟读取的文本流在消费时重新解析。这些可信代码检查缩小了旧目标的暴露范围，但无法防止同 UID 进程在检查和文件系统调用之间替换父目录的内核级竞态。

搜索钩子通过属性描述符核对是否已安装，不能比较经过跟踪包装的方法：Cordis 每次读取方法都会返回新的代理。[ToolRuntime 回归](model-file-read-guard.test.mjs)使用真实 Cordis `Service`，使正常工作区搜索和私有目录拒绝都经过正式服务的跟踪逻辑。

已上传文件通过 [`android_attachments`](../runtime/tool-android-attachments.mjs) 访问。它的宿主专用会话投影仅接纳明确消息载体中的结构化文件引用，模型不能指定其他会话、任意宿主路径，或当前会话未引用的摘要与文件名组合。`list` 分页列出这些引用。`read` 先完成原文件流的长度与 SHA-256 校验，再返回最多 16 KiB 的 UTF-8 或十六进制内容，UTF-8 续页位置保持完整字符边界。`materialize` 在 App 工作区创建独立、仅属主可访问的副本，并保留当前会话的沙箱写入策略，包括只读拒绝；它不会放开普通工具对附件仓库的访问。单附件上限 256 MiB，最多两个并发读取，卸载时会取消并等待活动文件流退出。[行为测试](model-attachments.test.mjs)覆盖会话归属、二进制分页、损坏文件、写入策略、取消以及原版附件仓库接入。

`inspect_archive` 在完整性校验后读取有界文件尾部，分页报告 ZIP／APK 中央目录元数据，并支持文件名的字面量筛选。目录元数据上限 8 MiB、条目上限 20,000，分卷归档、ZIP64 和越界目录会被拒绝。它不解压也不提取条目。读取器依据 [PKWARE ZIP 规范](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)实现；清单、DEX 和原生库计数只描述目录条目，不验证 APK 签名、文件正文、加固状态或运行行为。未声明 UTF-8 的旧式非 ASCII 文件名以原始十六进制报告，不猜测路径。

持久化的 Storage Access Framework（SAF）授权使用独立的模型工具 `android_files`，支持 `roots`、`list`、`read`、`read_image` 和字面量 `search`。`read` 返回有大小上限的 UTF-8 分页。第一页确立快照 `version`；模型请求非零位置的续页时必须提交该版本。Node 适配层会拒绝版本变化、与请求位置不符的 `offset`、无效或倒退的 `nextOffset`、超过 256 KiB 的分页、解码文字的 UTF-8 字节数与报告范围不符的分页，以及未前进却声称还有内容的分页，避免 Agent 在汇总时悄悄拼接缺段或重复文本。文件末尾允许空的最终页。App 阅读器可在连接变化后明确从零位置重新开始。

先调用 `roots`，将返回的不透明 `id` 原样填入 `root`，不能传目录显示名称。`path` 使用相对路径，授权根目录本身用 `""`，不能用 `"/"`。[公开工具载体](../runtime/tool-android-files.mjs)校验该协议，并在每次操作前重新核对当前授权列表，分别提示误传显示名称或授权已不存在。检查后若授权被撤销，最终权限仍由原生 SAF 判定。

SAF 授权不会放开普通工作区的 `read_image`。`android_files/read_image` 使用不透明的授权 ID 和相对路径（单文件授权用空路径），将 PNG、JPEG、WebP 或 GIF 转成持久化的模型图片块。读取前先核对当前模型的图片输入能力和附件策略。原生读取只解析持久授权，拒绝虚拟文档及已知超大的文件，最多读取 20 MiB，并通过完整双次读取和元数据比对确认文件未变化。Node 在提交附件前再次核对 SHA-256、规范的 base64 和图片签名。工具结果和会话文字不包含图片字节。中止操作会发送原生取消请求；撤销授权也会取消正在进行的读取。PDF 等其他二进制格式仍需要独立的模型接入方式。本次宿主测试没有运行 Android 真机或第三方 SAF 提供方；授权持久化、撤销和提供方差异仍需真机验收。

App 私有工作区的文本阅读器在替换当前显示页之前，会核对续页回应的请求版本、根目录、总字节数和字节范围。回应版本不符或分页不完整时，保留上一段已确认内容并允许重试；连接变化后的明确刷新可以建立新版本，但不会将它接到旧页面后面。

App 文本预览与 `android_files/read` 共用[有归属的原生请求](../runtime/document-reads.mjs)。App 请求归属由 Binder 提供；工具请求绑定会话与调用。准备阶段在 I/O 前固定授权根与读取期限。取消、断连、撤权和关闭都会请求取消 Provider 并关闭活动流；已取消的结果不能替换当前页面。只有读取线程和清理任务均结束才确认停止。不合作的 Provider 会继续占用请求名额，并明确报告尚未确认取消完成，用户仍可重试停止。`documentReadMaxDurationMs` 默认 30 秒，`documentReadMaxRequests` 默认两项；原生同时接纳的请求始终不超过四项。

文本快照缓存在 Provider I/O 前预留有界容量。Provider 打开、读取和元数据检查不持有全局缓存锁，锁仅保护预留、淘汰和发布。活动临时文件与正在读取的页面不会被淘汰。提交入口再次进行不调用 Provider 的取消检查；取消仍可能与已完成的私有缓存提交竞态，但请求归属管理会拒绝晚到页面。宿主检查将正式快照写入器、请求管理和 Provider 打开流程与可控 Android API 替身组合，覆盖首个流不响应取消时第二份文件仍可完成。[原生 SAF 验收入口](../android/app/src/androidTest/kotlin/com/minnnng/dsh_android/PtcSafAcceptanceInstrumentation.kt)在搜索／撤权检查前加入对应的普通文本用例。widget 测试覆盖等待停止确认与拒绝晚到页面，阅读器返回操作仍需真机 UI 证据。

<a id="build-118-device-evidence"></a>
## Build 118 真机证据

Build 118 r40 使用独立 Android 进程／UID 内的受控提供方，通过了原生文本读取用例：第一份文件仍在等待读取时，第二份文件已完成；提供方收到取消信号，取消完成，晚到结果被拒绝，请求管理完成关闭。同轮还通过了已有的受控搜索和执行中撤销授权检查。锁屏服务载体运行期间，两块物理屏幕始终为 Off。结果位于 `.cache/android/native-saf-118-r40-20261028.json.result.json`；`.cache/android/native-saf-118-r40-20261028.json` 保留屏幕保护和退出确认证据。

App APK 的 SHA-256 为 `1fc38e56bd200487aadbf8ddb57bce3b588c808b410192791806965f2225a692`，配套 AndroidTest APK 为 `de9925d16e8400331c314509a447dd25b12f91cb58eacd30f6af0f8d97f23745`。这是受控原生文件提供方的结果，不证明任意第三方提供方、用户原文件的点击 UI、全部图片读取路径均已通过，也不能确定此前闪退的根因。它不提升为完整文件工具等价声明。
