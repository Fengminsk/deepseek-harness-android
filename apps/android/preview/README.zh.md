# Android 文档预览

[English](README.md) | 中文

此入口在仅用于文档的 Cordis 客户端中装配原版 DSH 文档预览插件。Flutter 负责标题和导航；文档管理、资源 face、渲染器、生命周期、文件变更流和取消机制继续沿用原版实现。此入口不嵌入完整 Web 应用，也不启动其 HTTP 监听器。

`tool/build-document-preview.mjs` 打包小型原生容器及其现有平台单例依赖，再原样复制已构建的原版客户端代码块。原版源码发生变化时，先运行仓库构建。输出位于 `.cache/android/document-preview`；`asset-manifest.json` 记录源代码块的哈希，以及每个分发资源的路径、字节长度和 SHA-256。每次构建仅安全替换经过检查的 Android 缓存目录。

```powershell
node apps/android/tool/build-document-preview.mjs
node --test apps/android/preview/bridge.test.mjs apps/android/tool/build-document-preview.test.mjs
node --test apps/android/preview/browser.test.mjs
```

浏览器检查使用已安装的 Edge 浏览器、隔离的临时用户配置和测试数据。位于 `.cache/android/document-preview-smoke` 的 412 像素宽截图包含模拟悬浮标题，用于检查布局；这些截图不能作为 Android WebView 或真机验收的证据。

## 原生通信约定

唯一通道为 `window.PocketDocument.postMessage(JSON.stringify(frame))`；响应通过 `PocketDocument.onmessage` 接收。每条消息都有唯一 `id`，无需等待响应的取消、ACK、取消订阅和释放消息也不例外。

- `ready` 返回固定会话、路径、语言区域、主题、可选行号，以及原生标题和底部预留空间。预留空间设在文档滚动内容内，使内容仍可从原生悬浮标题后方滚过。
- `call` 将原版服务的位置参数转为具名参数。原生宿主独立限制文档客户端只能访问绑定会话及允许的 `workspaceFiles`/`officeToPdf` 方法。调用返回原版 `RemoteResult` 结构。
- 二进制结果使用字节租约。`bytes` 每条消息最多读取 256 KiB；解码成功或失败时均执行 `release`。关闭或中止会取消未完成的调用，并由原生文档生命周期回收废弃租约。
- `subscribe` 打开原版文件变更流。事件可能先于订阅回执到达。只有原版消费者处理事件之后，`ack` 才携带该事件的序号和代次发送；`unsubscribe` 关闭事件流。
- `external` 通过原版 Markdown 委托转发用户点击的 HTTP(S) 链接。原生宿主校验 URL 后打开系统浏览器；文档 WebView 不跳转，也不创建新窗口。本地文件委托保持原有行为。

原生宿主只允许精确的应用资源源地址和已打包的文档资源。静态资源 URL 不带查询参数。原版 HTML 保留沙箱 iframe，且不授予脚本执行权限。Markdown 内嵌本地图片使用原版 `api/file?path=...` 路由，需要独立的原生媒体适配器绑定会话；该适配器并非通用网络或文件系统桥接。

## 当前验证范围

宿主浏览器检查覆盖原版文本、含本地图片的 Markdown、源代码、图片、PDF、CSV、XLSX 和静态 HTML 渲染器，以及 PDF/Excel worker、实时文件变更、字节租约释放和 HTML 隔离。原版 PDF 资源和 Excel worker 保留在未改动的渲染器代码块内；清单包含打包字体及许可证。Excel 保留原版网格、公式栏和工作表标签，包括桌面尺寸的单元格字体及横向滚动。

Word 和 PowerPoint 沿用原版 `office-to-pdf` 提供方，配套锁定版本 0.2.0 的 LibreOffice-kit WASM 引擎。Android 配置限制单个活动转换、10 MiB 输入、20 MiB 输出、队列与缓存、字体加载及 90 秒转换期限。原版会话文件授权、取消、来源版本检查、字节租约与 PDF 渲染器均保留在调用链内。运行时 staging 校验 npm SHA-512 和引擎资产 SHA-256，打包时重新校验实际 ZIP 文件及许可证。

宿主检查已通过 staging 引擎将真实 DOCX 与 XLSX 样本转为 PDF，并通过原版授权提供方转换 DOCX，同时验证缓存复用、损坏或超限输入拒绝及 runtime ZIP 内容。引擎每次转换结束后会终止 worker。重复宿主测试中，转换 DOCX 时进程峰值 RSS 达到约 958 MiB，继续转换 XLSX 后约 1.26 GiB；转换结束、释放转换器并显式 GC 后，当前 RSS 仍约为 439 MiB。这是显著的常驻内存，宿主内存表现不能证明 Android 应用在系统限制下能存活。

Office 功能仍须标记为待验收：必须在 ARM64 真机的文档界面打开 DOCX 和 PPTX，重复转换，取消一次转换，在转换中切到后台再返回，并确认进程未被杀、Agent 任务未丢失。还要检查 Android 系统字体替换与 PDF 页面内容，不能只检查 `%PDF-` 文件头。若手机杀进程或转换无法在配置限制内完成，应保留明确的失败/重试状态，不得宣称 Office 预览已验收；需重新评估低内存引擎或需用户明确选择的外部转换路径。完整文档预览 profile 测试在调用 Office 前，被 Windows 测试宿主对原版 workspace 存储原子重命名的 `EPERM` 阻断。宿主转换与 APK 包内存在都不能证明 WebView 或真机 Office 阅读成功。
