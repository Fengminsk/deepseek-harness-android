# Pocket Harness for Android

[English](README.md) | 中文

## 概述

本目录包含 Flutter App、Kotlin 前台服务和内嵌 ARM64 Node 运行时。当前产物是适用于 Android 9 及以上版本的开发预览；运行时与 App/Web 集成仍需真机验收。

## 目录

- [构建预览版](#build)
- [运行时与存储](#runtime)
- [界面与主题](#interface)
- [验证范围](#verification)

<a id="build"></a>
## 构建预览版

使用 Windows PowerShell 7、Node 24、仓库指定的 pnpm、JDK 17、Android SDK 36、NDK 28.2.13676358 和 CMake 3.22.1。Flutter 与原生依赖版本固定在 [tool/runtime-lock.json](tool/runtime-lock.json)。先将指定 Flutter 版本放到仓库忽略的 `.cache/flutter` 目录，并配置 Android SDK。

完成 `pnpm install` 后，在仓库根目录执行以下命令。deploy 命令创建新的暂存目录；仅修改 App 时可保留该目录复用。依赖锁文件变化后应重新部署暂存目录。后面的 install 用于恢复 pnpm deploy 后的工作区开发依赖。

```powershell
pnpm.cmd run build:artifacts
pnpm.cmd --filter dsh-python-runtime-closure deploy --legacy --prod --config.allow-unused-patches=true --config.node-linker=hoisted --config.auto-install-peers=false --config.link-workspace-packages=true --config.hoist-workspace-packages=false .cache/android/runtime-bundle
pnpm.cmd install --offline --frozen-lockfile --prod=false --ignore-scripts
node node_modules/tsx/dist/cli.mjs apps/android/tool/stage-runtime.ts
./apps/android/tool/prepare-native.ps1
node apps/android/tool/smoke-runtime.mjs
./apps/android/tool/pack-runtime.ps1
```

原生准备脚本默认使用 `http://127.0.0.1:7897`；可通过 `-Proxy` 指定其他代理。脚本校验 Node 压缩包的哈希，以及 Android require-builtin 插件的源码版本。暂存运行时冒烟测试在电脑上执行，不代表 Android 兼容性已通过。

在 `apps/android` 执行以下命令。APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`，使用开发签名。如果本地网络需要代理，请配置 Gradle 的 HTTP/HTTPS 代理。

```powershell
../../.cache/flutter/bin/flutter.bat pub get
../../.cache/flutter/bin/flutter.bat analyze --no-pub
../../.cache/flutter/bin/flutter.bat test --no-pub
../../.cache/flutter/bin/flutter.bat build apk --debug --target-platform android-arm64 --no-pub
```

<a id="runtime"></a>
## 运行时与存储

前台服务在独立的 Android 私有进程中持有一个 Node 实例。Flutter 经 Binder 和专用本地套接字上的 JSON-RPC 通信，不使用本机 HTTP 服务。标准输出与错误写入私有运行日志，与协议通道分离。较大的 Binder 响应通过只读共享内存传递。打包运行时由名为 `android` 的 dsh profile 启动，工作区和会话存放在应用私有目录。API 凭据使用 Android Keystore 支持的加密存储；授权文档目录使用 Storage Access Framework 的持久授权。

Android 附件、会话和 ZIP 发布会先完整复制并同步临时文件，再通过原生 `renameat2(RENAME_NOREPLACE)` 发布，避开部分设备禁止的硬链接，同时不覆盖已有目标、不暴露未写完的文件。原版 DSH 的摘要、碰撞校验、租约和追加行为仍由原服务负责；其他平台保留已有发布实现。

Web 偏好与浏览器可修改的运行时设置分开。App 控制监听、范围和端口；网络回调选择明确的 Wi-Fi／以太网 IPv4 地址，局域网地址不可用时显示等待。凭证轮换保留 Agent 上下文。这些生命周期行为仍需 App/Web 共同操作的真机测试。

Android Shell 工具通过原版 DSH 工具执行流程逐条请求授权，仅 `allowed-once` 允许执行；拒绝、取消及 `never` 授权策略都不会放行。命令使用应用现有 UID 和 Android 权限执行，不提供只读或仅工作区的操作系统沙箱。逐条审批是 Android 工具的规则，不代表桌面版默认策略。Root、ADB 控制、开机自启动和离线模型推理尚未实现。

**授权与提问** 页面及 Android 通知与 Web 展示同一份 DSH 待处理请求。授权按钮发送原有的 `allowed-once` 和 `rejected` 结果。简单问题可用通知选项或直接回复文字处理；复杂问题打开对应的 App 页面。等待、继续和取消由原问题控制器管理，通知投递令牌不会授予额外权限。旧通知或已回答请求不能重复作答，未确认的提交保留草稿且不会自动重发。App 提供系统通知权限与通知类别设置入口。

**后台任务** 展示运行中的 Agent 会话、待处理请求入口及明确的停止操作。停止请求成功后，界面会等待核心确认空闲才结束“正在停止”状态。子进程页面订阅原版任务目录及按字节游标续传的输出流，限制界面保留的输出量，并提供明确的停止请求。离开这两类页面不会取消任务，Android 系统仍可能停止进程。

**自动化任务** 使用原版任务目录、编辑、删除和投递记录。App 可筛选任务，修改活动任务的名称、指令和时间规则，并返回所属会话。创建入口打开对话，由 Agent 使用现有定时工具创建任务；App 不增加暂停或立即运行操作。编辑时比较原任务记录，发生冲突或结果未确认时保留草稿。投递记录表示提醒已到达会话，不代表模型执行完成。

**聊天加号菜单** 遵循 DSH 的“添加”和“指令”分组及运行时实际指令目录。Android 当前禁用桌面沙箱权限预设，不伪造替代权限菜单。尚未配置凭据时也能创建会话、添加文件及使用不调用模型的指令。文件使用系统文档选择器和原版会话上传收据，上传失败保留所选文件以便重试。此预览尚未启用图片。指令通过原命令服务执行。ZIP 导出使用原版会话日志格式和系统保存选择器。

**授权文件** 支持单文件、目录、分段 UTF-8 读取及撤销授权。App 与 Agent 共用持久 SAF 授权范围内的字面文本搜索，可选择区分大小写，并限制读取量、遍历范围和执行时间。结果标明跳过的文件与未完成的搜索；不完整结果为空不代表没有匹配。取消操作等待原生搜索实际结束，文档授权不会将 `content://` URI 转成 Shell 路径。

**工具活动卡片** 在原轮次与步骤内配对调用和结果，包括嵌套的 PTC 子调用。卡片区分未返回、失败与中断，不将 Agent 空闲状态当作工具结果。Shell 卡片展示记录的命令、stdout、stderr、退出码和超时状态，文件卡片展示路径与可读结果。未知工具保留完整原始详情，在展开时加载；结果到达后保持卡片展开状态。

**会话模型** 区分当前选择和待应用草稿，显示明确的勾选标记及模型专属推理选项。空白会话继承原版目录默认值，已保存但暂不可用的模型仍保持可见。App 在编辑前初始化会话，订阅原版模型投影，应用前检查变更，应用后回读服务归一化的结果。失败保留草稿，结果不确定时先核对再重试。原版 `selectModel` API 没有原子比较并交换操作；这些检查可以发现已观察到的冲突，不能阻止检查与写入之间的所有并发覆盖。

**账号与配置** 页面使用原版账号和模型服务。登录在 Android Custom Tab 中打开官方授权页，临时回环监听器仅处理授权回调，不会启用 Web。完成页的 `dsh://open` 链接返回原生账号页，不携带凭据、不改变登录状态；登录结果由原版账号服务确认。登录成功后调用原版默认模型初始化规则；初始化失败保留已登录账号，并提供独立重试。个人资料、余额和通知独立加载，模型／服务商凭据及默认值有原生编辑页面。异步模型错误显示在对应会话中，重连后仍可查看。插件管理读取真实清单与操作回执，但打包的 Android 运行时尚未包含 pnpm，在线安装仍不可用。

**诊断** 区分服务启动或故障与账号状态尚未确认。活动订阅诊断仅展示接口名称、投递阶段及已接收序号，不包含请求参数、响应内容和传输标识。复制或刷新这些观察结果不会重试业务操作。诊断页可明确请求重启服务进程，界面等待实际就绪事件后才报告恢复成功。

<a id="interface"></a>
## 界面与主题

对话首页、侧栏和设置使用 Flutter 原生页面。**外观与主题** 将显示模式、配色、配色风格、纯黑模式、玻璃等级、字号与减少动画独立保存在 Android 偏好中，不依赖 Agent 进程。系统的减少动画设置优先生效。标题栏与对话输入框悬浮在全高滚动区域上；内容内边距让首尾项目可以完整露出，同时不截断滚动视口。页面通过 `lib/ui.dart` 组合导入的 FlClash 组件，Material 基础控件只用于实现统一组件样式。

实际玻璃 Shader、背景采样、按压拖拽弹簧、组合按钮、分段选择器、开关、仪表盘卡片、填充输入框、超椭圆形状、字体、配色生成和页面动效来自 [licenses/flclash-source.json](licenses/flclash-source.json) 记录的版本适配。聊天加号菜单使用导入的 FlClash 弹层，从按钮锚点展开并支持按住拖选；在菜单项上释放才选中，取消不执行操作。App 受 [LICENSE](LICENSE) 约束；依赖许可证保留在 `licenses/`。Pocket Harness 显示名称不改变内部包名和应用 ID。

<a id="verification"></a>
## 验证范围

Flutter 测试覆盖草稿保留、主题、悬浮控件、弹层拖选、大字号适配、工具配对、自动化编辑及模型选择恢复。主机测试覆盖原版定时操作、Shell 审批结果和共用文件搜索的生命周期。电脑上的冒烟测试让真实 Agent 经过本地模拟模型、Android 工具回执和第二次模型调用；在第二次调用期间关闭 Web 后，任务继续运行。测试也覆盖浏览器认证、连接断开及凭据轮换。这些检查不能替代 Android 上真实服务商与工具调用的验证。

内嵌运行时、官方账号授权及个人资料／余额读取已在关闭 Web 的 ARM64 Android 真机上运行。本机 Web 认证和关闭监听也已在该设备检查。返回链接及账号默认模型初始化已在使用专用协议通道的真机上通过检查。弹层展开、收拢、按住拖选，Flash 与 Pro 双向切换并重新进入页面，以及授权合成文件的 UTF-8 读取和字面搜索，已通过真机检查。

构建 11 已完成使用登录账号的真实模型闭环：合成附件上传并被正确读取，两次 Shell 调用收到原版 `allowed-once` 决策，三个工具结果均成功，回合正常结束。结束并重新启动 App 进程后，同一对话、工具结果及已选 Pro 模型成功恢复，测试会话随后切回 Flash。原版 ZIP 经系统选择器保存后通过 CRC 检查，包含会话日志和逐字节一致的合成附件。这些检查实际使用了设备上的原生文件发布实现。

自动化、账号待确认恢复路径、锁屏通知操作和拔线后台运行仍需手机验收。完整管理覆盖与配置导入导出尚未完成，复杂配置仍使用 JSON 输入。设备截图、诊断日志、个人会话和生成的 APK 是本地文件，不进入 Git。
