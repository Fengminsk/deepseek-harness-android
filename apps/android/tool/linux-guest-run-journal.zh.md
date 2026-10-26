# Linux guest 任务生命周期接口

[English](linux-guest-run-journal.md) | 中文

`LinuxGuestRunJournal` 是尚未启用的 App 侧执行接口；它不会启动 Linux guest，也不向模型开放 Shell。调用方必须使用 App 私有目录创建该 journal，并把 `admission()` 交给 `IsolatedExecutionPolicyOwner`，在绑定隔离 Service 之前持久保留 run ID。该目录与 V8 脚本回执目录隔离，不能交给现有脚本回执读取器。

成功收尾按以下顺序进行：验证 UID、镜像与启动器摘要、OS 事件管道里的全部 tracee 回收、broker 调用结清和仍有效的策略租约；写入并 fsync 候选回执；再次检查租约并调用 `markDurableSuccess()` 作内存决策；原子发布并 fsync 完成标记；最后调用 `markPublicationCommitted()`。只有 `LinuxGuestRunJournal.complete()` 返回 `true` 且 `mayPublishSuccess()` 为 `true` 才能给用户显示成功或发送完成通知。

取消、Service/Binder 死亡、进程中断和任何子进程回收未确认的情况都不能产生成功回执。重启时 `recover()` 把尚未结束的运行记为 `INTERRUPTED_UNCONFIRMED`；存在候选回执但没有有效完成标记时，读取结果也是不确定状态，且 run ID 不允许重放。重复收尾会被拒绝。标记与回执不一致时读取失败，不会降级为成功。

当前仍缺真实 guest 启动器、Binder 身份采集、内核/PRoot 事件管道接线、Service 生命周期调用方、任务通知接线以及真机验收。不得把主进程 Shell 或未受约束的网络能力接入此接口。
