---
kind: reference
title: Android DSH 项目记忆
---

# Android DSH 项目记忆

[English](project-memory.md) | 中文

## 摘要

本记录保存截至 2026-10-29 的项目约定、已验证结果与继续开发入口。它不表示六阶段迁移全部完成。后续工作先核对 Git 状态、实际 APK 与设备证据，再引用这里的结论。

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

2026-10-29 已确认原 Debug APK 同时缺少 Dart 内核与 AOT `libapp.so`，随后修复构建目录别名引起的输出清单问题，并增加 Gradle 和独立 APK 内容检查。Debug 必须包含有效内核和 isolate 快照；固定 SDK 的 VM 快照允许零字节。Release/Profile 使用 AOT，不要求 `kernel_blob.bin`。操作入口见[打包文档](flutter-packaging.zh.md)。

当前保留的普通 App 为 `0.1.0+120` arm64 Debug，归档名 `pocket-harness-0.1.0+120-arm64-debug-project-local.apk`，位于项目 `.cache/android/flutter-startup-audit-20261029/`。APK SHA-256 为 `1bef9f079ff80ac37a70cade4aceb9ce6cf0a4ecde430a6e62c9e77f0802b63c`。该包由当时工作区构建，包含已有未提交修改，不能仅凭打包修复提交重建相同字节。

该包完整 APK 检查通过；检查器 38 项用例通过，并能拒绝原缺少 Dart 的包。保留数据覆盖安装后，101 个会话与配置文件摘要一致，普通 Dart 主 isolate 可运行，Agent 从 `starting` 进入 `ready`。这证明该次启动和升级，不代表所有用户任务、文件授权与后台恢复均已验收。该 Debug 包未携带 Linux VM 候选资产；Linux 验收使用下述独立 Release 归档。

## Linux 与剩余验收

保留 `.cache/android/device-v120-20261028/r43/` 的 Linux Release、仪器包及记录，和 `.cache/android/linux-vm-candidates/` 下的 `alpine-ic8p90k9`、`alpine-tthk3anu` 完整候选及对应源码。前者对应 r43 APK，后者被[联网验收文档](linux-vm-network.zh.md)引用；不得把候选文件存在当作默认 App 已开启 Linux 的证据。

[Build 120 验收记录](upgrade-120-acceptance.zh.md)保存了 PTC 检查和 r55 真实账号 `workflow-linux` 成功结果：一次完成的工作流、一个子会话、隔离 UID 的 `linux_exec` 退出码零、退役与临时清理确认。较早冻结、网络代理不可达及模型参数失败均保持为各自的失败记录，不由后来的成功抹去。

剩余验收以[功能清单](parity-manifest.json)、[模型 PTC/Linux 说明](model-ptc-linux.zh.md)和[自然闹钟测试](schedule-wakeup-device.zh.md)为入口。SAF 撤权／搜索、自然闹钟触发、权限撤销、重启／长时 Doze 恢复、一般 Linux 联网及不限范围的 PTC／工作流不可仅凭上述证据标记完成。清单按声明计数，不是用户功能数量。

## 空间清理与证据保留

本次按文件清单清理旧 Android 安装包、过期 Linux 候选及其生成资产、旧源码打包副本和非当前 Flutter 编译缓存。Alpine 的 `.apk` 是客体依赖，不是 Android 历史安装包，予以保留。模拟器数据、截图、会话导出、WIP 文件、Git、依赖和当前运行时资源不在清理范围内。

候选目录删除前，其小体积 JSON、日志和说明复制到 `.cache/cleanup-audit-20261029/candidate-evidence/` 并校验摘要。原始验收报告和打包诊断记录继续保留；旧 APK 的字节文件清除后，历史验收仅代表当时记录，不承诺旧包仍可安装。精确删除项目、释放空间、保留文件校验结果见该目录的 `cleanup-plan.json` 与 `cleanup-result.json`。

## 验证与继续开发

打包检查从实际 APK 读取内容；不通过文件名、`debuggable` 或旧构建目录判断完整性。SDK 权限被宿主沙箱阻止时，使用明确的 SDK 工具路径与必要的宿主执行授权，不通过放宽产品校验掩盖失败。

打包修复时文档快速检查为 21 项通过，完整文档检查为 38 项通过、5 项既有失败，集中于缺失 JSDoc 与过期持久化目录。源码检查与设备检查的具体记录保存在 `.cache/android/flutter-startup-audit-20261029/`；后续改动需重新验证相关部分。

## 开发备注

只在用户要求时打包、升级或继续旁支任务。更新这份记忆时写明证据日期和范围，优先链接现有权威记录，不把待验收项改写成已完成。
