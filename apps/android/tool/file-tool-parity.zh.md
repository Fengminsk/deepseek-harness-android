# Android Agent 文件工具：授权与分页协议

原版 DSH 的 `read`、`read_image`、`write` 和 `edit` 使用 Android 的 `AndroidFileSystem` 提供方。模型文件守卫将 `read`、`read_image`、`write`、`edit`、`present` 限制在启动时固定的 App 工作区内。`write` 仍由提供方的 `workspace-write` 修改策略约束，但通用策略的临时目录例外不会授权模型 `write` 访问 App 私有临时文件；App 内部服务仍可使用该例外。[无密钥 ToolRuntime 投影](expected/model-file-write-guard.expected.json)记录工作区写入成功以及守卫和提供方各自的拒绝结果。

原版 `glob` 和 `grep` 通过受保护的子进程接口执行随包提供的 ripgrep。相对路径以固定的会话工作目录为基准。这些路径是普通文件路径，不能是 `content://` URI。`glob` 可报告工作区内匹配的文件路径；`android_files/list` 可列出明确 SAF 授权范围内的目录。原版 `str_replace_editor` 的目录 `view` 仍被拒绝：它会遍历两层并跟随子项符号链接，[无密钥 ToolRuntime 投影](expected/model-directory-guard.expected.json)记录了 App 私有文件名的泄露。`AndroidFileSystem.listDir` 还会在实际操作点拒绝模型上下文的目录枚举，包括检查时是文件、执行前变成目录的情况；App 内部服务仍可列目录。这条入口保持关闭，上述能力尚不能等同替代原版目录 `view`。模型上下文的 stat／read 操作会在实际读取时重新解析已保存的目标；延迟读取的文本流在消费时重新解析。这些可信代码检查缩小了旧目标的暴露范围，但无法防止同 UID 进程在检查和文件系统调用之间替换父目录的内核级竞态。

持久化的 Storage Access Framework（SAF）授权使用独立的模型工具 `android_files`，支持 `roots`、`list`、`read`、`read_image` 和字面量 `search`。`read` 返回有大小上限的 UTF-8 分页。第一页确立快照 `version`；模型请求非零位置的续页时必须提交该版本。Node 适配层会拒绝版本变化、与请求位置不符的 `offset`、无效或倒退的 `nextOffset`、超过 256 KiB 的分页、解码文字的 UTF-8 字节数与报告范围不符的分页，以及未前进却声称还有内容的分页，避免 Agent 在汇总时悄悄拼接缺段或重复文本。文件末尾允许空的最终页。App 阅读器可在连接变化后明确从零位置重新开始。

SAF 授权不会放开普通工作区的 `read_image`。`android_files/read_image` 使用不透明的授权 ID 和相对路径（单文件授权用空路径），将 PNG、JPEG、WebP 或 GIF 转成持久化的模型图片块。读取前先核对当前模型的图片输入能力和附件策略。原生读取只解析持久授权，拒绝虚拟文档及已知超大的文件，最多读取 20 MiB，并通过完整双次读取和元数据比对确认文件未变化。Node 在提交附件前再次核对 SHA-256、规范的 base64 和图片签名。工具结果和会话文字不包含图片字节。中止操作会发送原生取消请求；撤销授权也会取消正在进行的读取。PDF 等其他二进制格式仍需要独立的模型接入方式。本次宿主测试没有运行 Android 真机或第三方 SAF 提供方；授权持久化、撤销和提供方差异仍需真机验收。

App 私有工作区的文本阅读器在替换当前显示页之前，会核对续页回应的请求版本、根目录、总字节数和字节范围。回应版本不符或分页不完整时，保留上一段已确认内容并允许重试；连接变化后的明确刷新可以建立新版本，但不会将它接到旧页面后面。
