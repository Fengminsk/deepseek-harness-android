# 回答来源呈现

[English](chat-source-presentation.md) | 中文

原版 `tool-web` 除了提供给模型的文字，还返回 `web_search` 与 `web_fetch` 的结构化元数据。Android 只读取当前回答所属回合中已成功完成的元数据，不从正文、代码块或无关工具输出推断来源。

回答底部保留一个紧凑的“来源”操作。小型域名标识从已校验结果的主机名在本地生成；打开聊天不会为图标请求外网，也不会向第三方发送浏览记录。抽屉先显示回答中明确链接的 URL，再显示其他已观察到的结果，各组内仍按原检索顺序排列。打开前可看到原始 URL；若已记录的网页读取返回 400 及以上状态码，则显示该状态。搜索与读取的诊断细节仍在可展开的工具记录内，不占据每条来源的主要空间。

只有具备主机名、没有内嵌凭据及原始空白或控制字符的 HTTP(S) URL 可点击。链接仍由现有原生外部打开路径处理。关闭或替换回答会移除对应来源抽屉；排序与域名标识都不改写已保存的工具结果或模型回复。

宿主验证命令：`flutter test --no-pub test/chat_reply_bar_test.dart test/chat_reply_sources_test.dart test/chat_source_presentation_test.dart`。设备截图及外部浏览器打开仍需手机验收。
