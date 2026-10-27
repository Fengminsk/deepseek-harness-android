# Android 模型 PTC 入口

[English](tool-isolated-ptc.md) | 中文

Android 的 `android_ptc` 工具运行一个受审查的 TypeScript 异步函数体，支持顶层 `await` 与 `return`。模型只提供 `code` 和 `description`。它独立于原版 DSH `run_code` 传输及不受限的 Node PTC 执行器：客体仍不能直接访问 Node API、导入模块、App UID Shell、文件系统或网络。

运行时通过原生隔离执行桥、持久回调日志与原版 Agent／ToolRuntime 服务组合 [App 自有 PTC 所有者](model-ptc-readonly.zh.md)。源码中的 `MODEL_PTC_DEVICE_ACCEPTED=true` 开放其模型注册。该开关不是模型参数、profile 设置或远程值。原版 `ptc-runtime`、`workflow-ptc` 和 `tool-workflow` 插件仍受保护且禁用；独立的受审查原生 workflow 注册已在 Build 116 候选源码中开放，包含 workflow 的正式 profile 仍待端到端验证。

所有者捕获真实活动 ToolRunContext、Agent、Session 与精确的原厂工具注册。[受审查回调表](model-ptc-readonly.zh.md#经审查的调用)覆盖当前会话文件和附件、实时策略允许的工作区修改、已配置的网页提供方、直接子 Agent 查询，以及父级存在时的四个 Linux 工具。每次嵌套调用都经原版 ToolRuntime 复查注册和策略。客体没有直接的原生文件或网络授权。复制定义、失效父执行、递归委派与任意工具名均被拒绝。

限制仍为 32 次回调、包含回调等待的 120 秒总时限，以及 5 秒执行线程 CPU。Linux 启动与执行等待会消耗共享墙钟时限，串行步骤必须在其中完成。取消与退役不确定会隐藏程序返回值，但持久回调与发布事实仍可核对。作用域释放会取消并等待活动运行结束。这些限制及被禁用的直接 Node 环境，不等同于完整原版 PTC 对齐。

已安装 Build 115 r15 执行了真实 AgentLoop／ToolRuntime 调用、文件／网页／附件／APK 操作、CPU 超时、取消及 PTC 到 Linux 分析链。r17 进程死亡检查与 r21 SAF 撤权检查覆盖各自记录的用例。离线调用链成功不能证明嵌套 Linux 取消、共享时限到期或联网审批。r26 [所装正式 profile](production-profile-device.zh.md)另已通过脚本模型驱动的 PTC 工作区读取及后续离线 Linux Python 分析，客体与 App UID 不同，退役已确认且有持久 Session 证据，全程锁屏息屏。普通 Build 116 升级仍待验证。

定向主机 ToolRuntime 与所有者测试使用模拟原生传输，不能认证 Binder UID 隔离或 Android 进程退役。[PTC 生命周期样例](ptc-lifecycle-device.zh.md)、[SAF 样例](device-runtime-acceptance.zh.md)及 [PTC 到 Linux 样例](model-ptc-linux.zh.md)分别拥有其设备观察。不能仅根据注册就推断缺失或不确定的证据已满足。
