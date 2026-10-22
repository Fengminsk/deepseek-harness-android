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

Word 和 PowerPoint 仍需要将原版 Office 转换提供方适配到 Android。在完成适配之前，客户端显示原版不可用结果；不会仅因客户端完成注册就将这些格式标为已支持。
