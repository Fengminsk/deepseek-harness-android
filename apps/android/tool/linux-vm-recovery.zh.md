---
kind: reference
title: Linux 客体恢复记录
---

# Linux 客体恢复记录

[English](linux-vm-recovery.md) | 中文

## 摘要

Linux 客体分别记录接纳、派发、退役和磁盘发布。冷启动后的所有者可以报告已核实的发布事实，而不重放命令。不确定或需要核对的记录会阻止该会话继续执行。[运行时参考](linux-vm-runtime.zh.md) 负责说明模型工具的可用性与查询行为。

## 目录

- [读取恢复结果](#reading-recovery-results)
- [持久记录](#durable-records)
- [兼容性](#compatibility)
- [验证](#verification)
- [开发备注](#dev-note)

<a id="reading-recovery-results"></a>
## 读取恢复结果

`native.linuxVm.inspect` 只读，不会启动客体、创建存储、确认记录或重新开启执行所有者。准入同时拒绝 `blocked` 和 `needsReview`；查询记录不会清除任一条件。当前没有确认或解锁操作。核对者必须检查记录中的效果；重复提交命令不能解除屏障。

| 最后一个持久阶段 | 冷启动所有者的判定 | 后续准入 |
| --- | --- | --- |
| 已接纳 | 派发未越过其持久边界；磁盘发布为 false | 需要核对 |
| 已派发 | worker 退役情况与磁盘效果未知 | 阻断 |
| 已退役 | 将原子磁盘指针与此运行及前一个指针摘要比较 | 需要核对 |
| 导出已准备 | 宿主发布情况未知，即使目标字节相同 | 阻断 |
| 终态 | 保留明确的退役与发布事实 | 仅在没有记录需要核对时允许 |

App 的独占文件锁保护磁盘发布。锁释放不代表隔离 worker 已退出。冷启动遇到“已派发”记录仍会阻断，因为当前协议没有跨所有者的 Binder 退役证明。经身份校验的原生返回或 Binder 死亡可以在原所有者中证明退役。

<a id="durable-records"></a>
## 持久记录

[LinuxVmRecoveryStore](../android/app/src/main/java/com/minnnng/dsh_android/LinuxVmRecoveryStore.java) 将带校验和的二进制接纳记录写入 `runs-v2/<runId>.bin`。记录包含会话、操作、前一个指针摘要及单调推进的执行阶段，并在任何 Binder 派发前同步。指针 `state-v3.bin` 原子包含提交运行的身份与完整磁盘元数据；报告提交前会校验它引用的不可变块。临时文件与未发布块会保留。

每份记录先写入新的同目录文件，再同步文件、原子重命名并同步目录。Android 适配器还会在接纳前同步新建的祖先目录。重命名后的失败不得恢复成前一阶段。属于已退役运行的指针能证明 `diskCommitted: true`，即使终态记录发布失败；在核对恢复事实前会拒绝后续运行。查询报告当前已验证的指针，不单独保证未来断电后的结果。

导出单独记录发布：宿主重命名前，`filePublished` 变为未知；仅根据明确的发布结果落定。新的 `export-<runId>.json` 文件保留来源、目标、大小与哈希作为补充诊断；`runs-v2` 是权威执行记录。目标哈希相同不能证明是哪次运行创建了它。

<a id="compatibility"></a>
## 兼容性

读取器保留已有的 `state.json`、`run-*.json` 和 `export-*.json` 文件。只有 `state-v3.bin` 不存在时才读取旧磁盘指针；新指针损坏时绝不回退。旧运行记录缺乏经过身份验证的退役事实，因此其终态名称不能解锁写入。明确的旧发布事实可以与未知退役状态一起报告。不会自动迁移、回滚、删除或重放命令。

存储有界：完整扫描最多接纳 1,024 条运行记录，查询最多返回 32 条，优先展示需要核对的记录。指定运行身份时，只有完整可信的扫描才返回匹配记录或确认不存在。读取失败产生 `status: unknown` 与 `requestedRunFound: null`，不能证明不存在。数据损坏、扫描不完整或引用块无效都会阻止新准入。

<a id="verification"></a>
## 验证

从仓库根目录运行 `node apps/android/tool/acceptance-linux-vm-recovery.mjs`。主机测试器将报告保留在 `.cache/android/linux-vm-recovery-tests/`，并使用与 Android 适配器相同的 Java 编码器生成 `.cache/android/linux-recovery-native-contract.json`。它使用真实文件与原子移动，包括在派发后及指针发布后终止子进程。目录 fsync、Binder 退役和 Android 进程死亡行为仍需真机证据；Windows 主机检查不能认证这些边界。

<a id="dev-note"></a>
## 开发备注

无。
