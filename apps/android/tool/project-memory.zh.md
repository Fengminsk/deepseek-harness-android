---
kind: reference
title: Android DSH 项目记忆
---

# Android DSH 项目记忆

[English](project-memory.md) | 中文

## 摘要

本记录保存截至 2026-10-30 的项目约定、已验证结果与继续开发入口。本轮跨越午夜，证据仍保存在 `.cache/android/build-hang-audit-20261029/`。它不表示六阶段迁移全部完成。后续工作先核对 Git 状态、实际 APK 与设备证据，再引用这里的结论。

## 用户约定

- 源码推送到 Gitee 的 `android` 分支；保留其他会话的未提交修改，按文件或代码块提交自己的改动。
- `apps/android/build` 使用项目 D 盘内的真实目录，不再联接到 C 盘。保留 SDK、依赖库、运行时资源和用户数据；不得为了清理空间重写 Git 历史。
- 手机目前无 Root，优先完成后台 Agent、本地文件和低权限能力。APK 的 ZIP、Manifest、DEX 与原生库检查不依赖 Linux 客体。
- 真机升级覆盖现有 App 并保留账号、会话和文件授权；设备测试期间双 OLED 面板必须保持 Off。构建通过、主机测试与真机验收分别报告。
- UI 使用磨砂、细噪点、高光边缘和克制的 PS5 风格光效；侧栏玻璃不带背景流光。交互参考 ChatGPT 手机版，去掉无用说明文案。
- 思维链紧凑展示，展开内容维持小字号，展开与折起有模糊动效；结束自动收起时保留用户正在阅读的回复位置。发送消息后将新一轮消息带入视野。
- 推理强度使用中文滑动选择器；“默认”作为独立选择持久化，不能返回页面后自动变成“高”。保留 DS 账号头像；会话资源不增加底部切换栏。
- PC 下载代理为 `127.0.0.1:7897`；手机使用 FlClash，用户提供的端口约为 `7890`，使用前核对实际配置。不要按猜测更改系统权限。

## 打包与当前安装包

当前普通 App 是启用 Linux 的 `0.1.0+120` ARM64 Release，归档为 `.cache/android/build-hang-audit-20261029/artifacts-final/pocket-harness-120-workflow-linux-release.apk`。包大小为 355,611,900 字节，SHA-256 为 `4a341bcd539727e447e70d863b7e5f8323470fefac3a60ac22b583986cf76319`。内嵌运行时为 240,075,953 字节，SHA-256 为 `67dc2b90ea835ec84d09296be9d900516fce3ca6697cf4849197307d867c488d`；运行时 ZIP 的 18,026 项与刷新后的暂存目录逐项一致，bootstrap 与当前源码一致。APK 来自共享工作区，不是单个干净提交。不同版本的仪器 APK 是独立产物；须核对每份报告记录的 App 与测试包摘要，不能把旧检查当作最新测试包的结果。

该审计目录中的 `release-startup-r2.json`、`release-startup-r3.json` 记录了普通 Activity 启动及运行时就绪，双面板实际保持 Off；测试夹具没有自行启动 Agent 服务。这些检查未检查 Dart VM 服务，也不证明整套 UI 渲染通过。`install-release-retained-r2.json` 确认同版本保留数据重装：93 个已记录会话文件、共 3,036,289 字节，三条 SAF 授权及一项合成 Keystore 凭据均保留，未清除 App 数据。这不是实际账号登录或令牌刷新的验收。

原 `debug.keystore` 已从 Windows 回收站找回，证书 SHA-256 核验为 `665169a9132865c4fb863bf408b06f0a359a9abc363d054c760972248cfce8a7`，并恢复到 `C:\Users\JZ_Colin\.android\debug.keystore`；`D:\JOB\CODE\Lab\deepseek-harness-android\apps\android\signing\debug.keystore` 是被 Git 忽略的备份。该签名目录不是缓存，不得作为清理对象。另行生成的密钥以不同文件名保存在该目录，不得替换已恢复的签名身份。恢复记录见 `signing-recovery.json`；原文件的删除原因尚未证实。

后续 Release 构建停顿已定位到依赖下载等待，并未证实 Gradle 客户端与 Kotlin daemon 互锁。捕获的 daemon 线程栈停在 HTTPS socket 读取；Kotlin daemon 标记文件访问失败是另一个权限问题。通过配置的代理获取官方依赖及元数据、核对上游校验和，再提供按精确版本过滤的本地 Maven 仓库；补齐缺失依赖后，离线构建成功。最初依赖不完整的离线尝试仍保留为失败记录。保留 `.cache/android/build-hang-audit-20261029/` 中的 `dependency-maven-manifest.json`、线程栈及 `release-original-signature.log`。不要通过关闭 TLS 校验、改依赖锁或删除缓存掩盖这类故障。操作入口见[打包文档](flutter-packaging.zh.md)。

### 历史 Debug 修复

2026-10-29 较早时已确认当时安装的 Debug APK 同时缺少 Dart 内核与 AOT `libapp.so`，随后修复构建目录别名引起的输出清单问题，并增加 Gradle 和独立 APK 内容检查。Debug 必须包含有效内核和 isolate 快照；固定 SDK 的 VM 快照允许零字节。Release/Profile 使用 AOT，不要求 `kernel_blob.bin`。

当时修复的 `0.1.0+120` ARM64 Debug 归档为 `.cache/android/flutter-startup-audit-20261029/` 下的 `pocket-harness-0.1.0+120-arm64-debug-project-local.apk`，SHA-256 为 `1bef9f079ff80ac37a70cade4aceb9ce6cf0a4ecde430a6e62c9e77f0802b63c`。该包由当时工作区构建，包含已有未提交修改，不能仅凭打包修复提交重建相同字节。它不是当前安装的 Release。

该历史 Debug 包完整 APK 检查通过；检查器 38 项用例通过，并能拒绝原缺少 Dart 的包。其保留数据覆盖安装保留了 101 个会话与配置文件摘要，普通 Dart 主 isolate 可运行，Agent 从 `starting` 进入 `ready`。这证明当时的启动和升级，不代表所有用户任务、文件授权与后台恢复均已验收。该 Debug 包未携带 Linux 客体候选资产，当时的 Linux 验收使用独立 Release 归档。

## Linux 与剩余验收

保留 `.cache/android/device-v120-20261028/r43/` 的历史 Linux Release、仪器包及记录，和 `.cache/android/linux-vm-candidates/` 下的 `alpine-ic8p90k9`、`alpine-tthk3anu` 完整候选及对应源码。前者对应 r43 APK，后者被[联网验收文档](linux-vm-network.zh.md)引用。当前普通 App 是上文标识的 Release，但仅有候选文件仍不能证明已安装 APK 启用了哪些能力。

[Build 120 验收记录](upgrade-120-acceptance.zh.md)保存了 PTC 检查和 r55 真实账号 `workflow-linux` 成功结果：一次完成的工作流、一个子会话、隔离 UID 的 `linux_exec` 退出码零、退役与临时清理确认。较早冻结、网络代理不可达及模型参数失败均保持为各自的失败记录，不由后来的成功抹去。

以下是 2026-10-29 使用当前 Release 的原生验收快照。报告与日志位于 `.cache/android/build-hang-audit-20261029/`；`device-matrix-native.json` 保留首次尝试，`device-matrix-native-rest.json` 记录成功的后续运行。较早失败仍保留为独立记录。

- `device-native-saf.json`、`device-ptc-saf.json` 的外层退役与保护检查通过。受控提供方覆盖原生搜索、进行中撤权和文本读取取消／迟到结果拒绝；PTC 覆盖四次回调、原生搜索，以及撤权后的读取／搜索拒绝。这不涵盖所有外部文档提供方或用户交互授权选择器。
- `final-native-workflow-r2` 通过五个阶段、十二项检查，包含预留子任务退役、取消、路由拒绝故障，以及保持未确认状态的冷启动恢复。`final-workflow-lifecycle` 通过 120 秒嵌套截止时间和 Binder 死亡／App 重启场景：子任务已退役，不确定结果仍要求审查，持久日志未变，没有重放模型调用或回调。
- `final-ptc-death` 通过派发中被终止后的恢复：旧 Agent 与客体停止，日志保持 `dispatch-unconfirmed`，原生重新绑定与执行重放均为零。它不把中断的操作改写成成功。
- `final-linux-cancel` 观察到正在运行的客体，确认取消、退役及未提交磁盘。`final-linux-death` 只覆盖“导入客体已退役、结果尚未发布”的窗口：恢复保留日志、要求审查并拒绝自动重放。它不证明任意客体命令执行期间的进程死亡均已验收。
- `final-completion-r2` 在 force-stop 后恢复合成的已提交完成回执，抑制无效回执，清除回执并确认清理／退役。其 `realAgentTaskReplayTested` 仍为 false，不是实际 Agent 任务成功续跑的证明。

后续组合运行时测试也通过外层保护与退役检查：`final-runtime-ptc.json` 的十二项选定检查全部通过，另有已通过的独立受控 SAF 场景；`final-runtime-workflow.json` 的十一项选定检查通过，另有独立截止时间及 Binder 死亡场景；`final-runtime-linux.json` 的六项选定检查通过，另有独立导入死亡场景。内部结果仍保留 `complete: false`，因为独立场景与清单中的剩余项另行报告。不得把原始报告改写为整体完成：普通版本升级的工作流记录保留及客体联网仍未闭环。

`final-model-transport.json` 在实际 Android 配置中使用本地 SSE 夹具，通过进行中的模型传输重试。`final-idle-recovery-result.json` 通过锁屏、不唤醒条件下空闲会话的断网／恢复，并恢复原始 Wi-Fi／数据设置，两者均为 `1`；网络恢复与进程退役已确认。该空闲报告明确为 `modelRequestRetryTested: false`、`activeAgentTaskSurvivalTested: false`。两者是独立测试，不是实际账号的进行中任务能经受无线网络中断的证据。

[屏幕保护包装器](device-screen-protection.zh.md)现支持不带值的 `--keep-display-off`，程序调用则传入 `restoreDisplayPower: false`，用于连续验收时避免释放覆盖而恢复 AOD。它仍要求实际面板 `Off`、拓扑稳定、不可交互和退役确认。成功保留报告 `retainedWhileNonInteractive: true`、`restoredWhileNonInteractive: false`；覆盖会持续生效，直到显式释放。上文普通启动及 `final-*` 原生运行均记录了这一保留关屏状态。不得更改系统 AOD 偏好，也不得把保留覆盖称为正常恢复。

后续以[功能清单](parity-manifest.json)、[模型 PTC/Linux 说明](model-ptc-linux.zh.md)和[自然闹钟测试](schedule-wakeup-device.zh.md)为入口。实际账号、`radio-linux` 及自然唤醒最终复测被自动审批拦截，待用户明确授权，尚未记为通过。权限变更、普通跨版本升级及工作流记录保留、重启／长时 Doze 恢复、一般 Linux 联网、不限范围的 PTC／工作流及完整 UI 交互仍是独立验收边界；上文同版本保留数据重装不闭环跨版本升级。闹钟投影就绪或测试 APK 修复不等于自然唤醒证据。清单按声明计数，不是用户功能数量。

## 空间清理与证据保留

本次按文件清单清理旧 Android 安装包、过期 Linux 候选及其生成资产、旧源码打包副本和非当前 Flutter 编译缓存。Alpine 的 `.apk` 是客体依赖，不是 Android 历史安装包，予以保留。模拟器数据、截图、会话导出、WIP 文件、Git、依赖和当前运行时资源不在清理范围内。

候选目录删除前，其小体积 JSON、日志和说明复制到 `.cache/cleanup-audit-20261029/candidate-evidence/` 并校验摘要。原始验收报告和打包诊断记录继续保留；旧 APK 的字节文件清除后，历史验收仅代表当时记录，不承诺旧包仍可安装。精确删除项目、释放空间、保留文件校验结果见该目录的 `cleanup-plan.json` 与 `cleanup-result.json`。

## 验证与继续开发

打包检查从实际 APK 读取内容；不通过文件名、`debuggable` 或旧构建目录判断完整性。SDK 权限被宿主沙箱阻止时，使用明确的 SDK 工具路径与必要的宿主执行授权，不通过放宽产品校验掩盖失败。

较早 Debug 打包修复时，文档快速检查为 21 项通过，完整文档检查为 38 项通过、5 项失败，集中于缺失 JSDoc 与过期持久化目录；这些历史结果保留在 `.cache/android/flutter-startup-audit-20261029/`。之后 `.cache/android/build-hang-audit-20261029/runtime-final-doc-sync.log` 记录当时工作区 43 项通过、零失败、零跳过；运行时产物构建通过七道门禁，后续聚合构建检查通过两道门禁。修复尚未结束的工具被提前折叠后，定向 Flutter UI 测试 357 项通过；分析保留十一条 info，无 error 或 warning。这些是主机检查，不是完整真机 UI 验收；后续修改仍须执行相应门禁。

## 开发备注

只在用户要求时打包、升级或继续旁支任务。更新这份记忆时写明证据日期和范围，优先链接现有权威记录，不把待验收项改写成已完成。
