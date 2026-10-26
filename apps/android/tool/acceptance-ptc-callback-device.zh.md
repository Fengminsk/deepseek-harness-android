# 隔离式 PTC 回调真机验收

[English](acceptance-ptc-callback-device.md) | 中文

这个需主动运行的 instrumentation 阶段在 Android 真机上检查内部 PTC Binder 中继，不注册模型可见工具。隔离进程中的测试脚本以 `{scope:"children"}` 调用 `list_agents`，由 App 私有测试 transport 返回空子智能体列表。断言包括：隔离 UID 与 App UID 不同、一次准确的回调及回收、持久化成功回执、执行前取消后不能调用或重放，以及伪造回调响应不能生成成功回执。

私有 transport 是**测试桩**，不是生产环境的第一方 `list_agents` 定义。它不能证明 Node `ToolRuntime` 注册身份、有效父 Agent 或 App 审核策略。这些属性需要另由宿主侧模型式 PTC 审核测试验证。生产 `AgentService` 用 `native.toolCallback` 向 Node 发送工具回调；本 instrumentation 有意不创建父 Agent，也不注册模型工具。不得把本阶段描述为生产 ToolRuntime 端到端验收。

先构建相互匹配的 App APK 和 AndroidTest APK。预检会核对两份 APK 的 SHA-256 指纹、包名、相同签名证书，以及准确的 `:agent` instrumentation 声明；不使用手机：

```sh
node apps/android/tool/acceptance-ptc-callback-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --preflight-only
```

用户授权真机测试且 ADB 可用时，去掉 `--preflight-only`。如果连接多台设备，用 `--serial SERIAL`。若 App 已安装，runner 默认拒绝覆盖；仅在明确允许后使用 `--allow-existing`，因为安装可能改变 App 状态。只有安装和三项真机断言全部通过，runner 才输出 `result: pass`。预检通过不等于真机通过。

```sh
node apps/android/tool/acceptance-ptc-callback-device.mjs --apk /path/to/app-debug.apk --test-apk /path/to/app-debug-androidTest.apk --serial SERIAL
```

使用 `node --test apps/android/tool/acceptance-ptc-callback-device.test.mjs` 检查结果解析器。该测试不能证明 Android Binder 的实际行为。
