---
kind: reference
title: Build 120 升级与执行验收
---

# Build 120 升级与执行验收

[English](upgrade-120-acceptance.md) | 中文

## 摘要

Build 120 r43 已保留数据覆盖安装到现有 App。它修正了已确认的回调取消被报告成退役不确定的问题；[嵌套 PTC/Linux 证据](model-ptc-linux.zh.md#verification)记录真机结果。这是限定范围的执行与升级证据，不代表 Android 迁移已全部完成。

## 产物与升级

归档位于 `.cache/android/device-v120-20261028/r43`。正式 APK 大小为 355,537,108 字节，SHA-256 为 `56316b0ad4215d5808e85d5bf6d993f105f8783b686c2f9311fe431df146385a`；AndroidTest 为 649,441 字节，SHA-256 为 `5ee3f7e566b97dc33ef5f1c3844579234587afb2ee6d1ce522114c4f420ec3ce`。PackageManager 报告版本 `0.1.0+120`，签名身份保持原值。归档检查内嵌运行时和夹具字节与源码一致；包信息、26 个仪器入口、DEX 链接及独立 SAF 提供方链接检查均通过。这些静态检查不能替代实际执行。

`.cache/android/upgrade-119-120-r43-20261028.log` 记录普通 119→120 覆盖升级：67 个 Session 文件共 1,846,034 字节、三项 SAF 授权和合成 Keystore 凭据的哈希均保持一致，随后移除了测试金丝雀。此前的 118→119 记录为 `.cache/android/upgrade-118-119-r42-20261028.log`。两次检查都不证明所有保留文档可读，也不证明用户中断任务可以恢复执行。

## 执行与剩余检查

`.cache/android/ptc-120-r43-protected-20261028.json.result.json` 记录十二项已执行 PTC 检查通过，失败为零。独立的 SAF 撤权／搜索检查在该套件中仍为未验证，因此 `complete` 为 false。外层报告记录了 71 次双物理屏幕 Off 采样和测试进程退出确认。r42 的取消失败仍保留；[APK 检查参考](apk-inspection.zh.md)单独说明其合成正文检查通过的事实。

真实账号 `workflow-linux` 的 r42 尝试仍为失败：严格参数检查拒绝了斜杠转义的不同写法，而 `.cache/android/workflow-linux-r42-diagnostic-under-120-r43-20261028.json.result.json` 是零新提交的只读诊断，不是工作流验收。[账号验收参考](agent-service-task-device.zh.md#programmatic)记录了本次修订：验收改为解码经审核的包装、比较解析后的子参数，并为失败回合保留有界的提供方错误码；重建的 AndroidTest（SHA-256 `fbe87fff10147b7d2b7620c686211849fe05215c59c454da7313216157ed98fc`，正式 App 未变）通过 135 项宿主断言。真机尝试保留了各自的失败：r44 被 OEM 灭屏冻结器阻塞（`cgroup.freeze=1`，而 AMS 报告 `isFrozen=false`），在 319,535 毫秒后失败；r45 至 r49 各提交一次后以 `SESSION_FAILED` 与提供方错误码 `TRANSPORT` 失败，原因是 App 侧网络代理已启用但没有可达的代理；r51 在缓慢冷启动中触达 120 秒回合上限；r54 因模型写出了另一段程序而被拒绝。随后 `.cache/android/real-account-workflow-linux-120-r55-protected-20261028.json.result.json` 以 33,178 毫秒通过：一次已完成的工作流运行、一个子会话、一份隔离的 `linux_exec` 回执（客体 UID 99,028 与 App UID 10,496 不同、退出码为零、确认退役与临时清理），以及确认的父会话与子会话归档。r42 的冻结没有留存厂商日志；本次复现的特征与 r32 记录的 OEM 冻结器一致。对该旧案情的诊断发现一个工作流运行和零条持久成员记录，这不证明子任务从未创建，也不授权子会话清理。

[自然闹钟驱动](schedule-wakeup-device.zh.md)现保留有界失败阶段，并在只读状态检查失败后独立验证测试客户端退出。`.cache/android/schedule-natural-status-119-r42-stages-20261028.json` 成功读到精确闹钟权限已允许，但 App 启用偏好为 false，活动提醒为零。它没有提交任务，并保留原主进程。此前的状态检查超时仍有记录；后续成功不能解释它们。自然触发、权限撤销和重启恢复仍未验收。

## 验证边界

回调、原生桥、生命周期、账号证据及驱动的专项检查通过，暂存运行时冒烟检查和 release 构建也通过。全仓库 lint 在 12 个未修改的包文件中报告 16 项诊断；`.cache/android/ptc-closure-120-lint-baseline.json` 记录这些文件均与各自 HEAD blob 一致。该轮 lint 没有报告 Android 文件。这不是全量 lint 通过，也没有修改这些无关包文件。

## 开发备注

分别保留失败与成功记录。仅源码检查、合成 APK 元数据和屏幕采样不能认证所有提供方、原文件打开界面、长时间 Doze、无限制 Node PTC／工作流、Linux 联网或全部六阶段迁移目标。
