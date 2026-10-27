# 真机验收期间的 OLED 保护

`device-screen-protection.mjs` 参考。包装器对所有内置面板执行 Android 的 `cmd display power-off`，包括折叠手机停用的面板，并在启动真机验收入口前核对 `SurfaceFlinger` 的实际电源状态。它不会唤醒或解锁手机、修改亮度、安装悬浮窗软件，也不替代已有的黑色验收 Activity。

## 仅检查屏幕

```powershell
node apps/android/tool/device-screen-protection.mjs --adb D:\Programs\adb\adb.exe --serial <serial> --seconds 12 --report <report.json>
```

不传 `--` 时仅采样面板状态。此时 `--seconds` 表示建立保护后的完整观察时长，包装器总截止时间额外预留最多 60 秒，用于预检查和最终核验；清理仍使用独立预算。报告包含要求与实际观察的毫秒数，并明确注明未运行 App 测试。此检查通过，不代表交互任务、进程终止或升级期间的保护已获验证。

## 运行验收入口

追加 `-- apps/android/tool/acceptance-<name>-device.mjs` 及该入口的参数。仅允许 `workflow-lifecycle`、`native-workflow`、`native-workflow-process-death`、`upgrade`、`ptc-process-death`、`ptc-callback`、`linux-vm-lifecycle` 和 `agent-service-recovery`；这些入口明确遵循 `--adb` 与 `--serial`。包装器在缺少参数时注入受保护的目标，拒绝重复或冲突值，并为后代进程设置 `ANDROID_SERIAL`。其他入口在接触手机前即被拒绝。只有所有面板都报告 `Off`，包装器才会使用当前 Node 程序启动普通入口。恢复入口则将网络恢复所有者保留在本进程内，取消后也继续等待，不经过可被直接杀死的子进程启动器；其独立报告与不可覆盖网络快照见[锁屏恢复验收](agent-service-recovery-driver.zh.md)。验收模式的 `--seconds` 仍表示包含保护初始化的完整截止时间，不额外增加预检查余量，最长一小时；较长套件须分别执行。各入口保留原有前提：即使面板电源被覆盖，基于 Activity 的入口仍要求 Android 会话已解锁且可交互；恢复入口要求已锁屏、不可交互，并且从不唤醒手机。

采样通常间隔两秒，另有受限的 ADB 命令耗时。USB 不可用、显示拓扑变化、收到可处理的 SIGINT/SIGTERM 或任何面板不为 `Off` 时，会立即开始重新关闭已知面板，再等待子进程退役。对于普通入口，包装器请求终止进程树，等待宿主子进程真正关闭，然后强停 App 及测试包，并通过完整的 `ps -A -w -o PID,ARGS` 名称检查 App、测试包及隔离服务进程是否仍然存活。子进程正常完成后也执行设备退役检查。仅有 force-stop 回执不能证明进程退役；整个过程不清除 App 数据。

普通宿主子进程与设备退役的预算为 20 秒；宿主预算耗尽后，仍有一次独立的强停尝试，最多八秒。失败或进程清单不可读时，报告退役未确认，并禁止重置面板电源。进程树终止失败后，即使直接子进程随后退出，也仍标为未确认。如果子进程一直未退出，包装器会先完成有界清理，再释放宿主句柄的事件循环引用；子进程此时可能仍活着。失败报告保留其 PID、实际关闭状态和句柄释放状态，释放引用不算终止证据。包装器提供采样证据，无法保证采样间的系统变动或主机终止不会影响保护。受保护的前台测试不算后台或锁屏存活证据。

## 清理与恢复

正常结束或捕获到中断时，包装器先发送 `KEYCODE_SLEEP`，要求所有已报告的唤醒状态组均为 `Asleep` 或 `Dozing`。厂商数字镜像只接受 Android 的 `0`（`Asleep`）和 `3`（`Dozing`），且镜像与命名状态必须全部一致；`1`、`2`、缺失、未知或不一致状态均禁止重置。只有验收进程退役已确认才允许 `power-reset`，仅检查屏幕的模式没有验收子进程。每次重置前检查不可交互状态，确认所有实际面板保持关闭后再次检查。单凭 `Dozing` 不能证明 OLED 已关闭，因此重置后面板亮起会使清理失败并重新施加关屏覆盖。显示清理有独立的 40 秒预算。任何重置失败、重置后状态不可读或面板亮起，都会对全部已知 ID 独立尝试重新关屏，即使此时无法重新枚举显示设备。紧急关屏最多八秒。清理失败保留采样，并明确将最终显示状态标为未知。第 2 版报告以 `restoredWhileNonInteractive` 表示成功恢复，不将其当作 `Asleep` 的证据。亮度、息屏显示偏好及充电保持唤醒设置不变。

主机中断或 USB 断开可能使电源覆盖仍生效，且退役或清理结果未确认。重置前先确认此前的宿主验收进程及所有目标 App／测试进程已退役。重新连接后保持手机完全休眠，读取 `cmd display get-displays --ids-only --type internal --category android.hardware.display.category.ALL_INCLUDING_DISABLED`，对返回的每个 ID 执行 `cmd display power-reset <id>`。通过 `dumpsys SurfaceFlinger` 确认实际面板仍为 `Off`，再继续测试。不要替换为 `power-on`，也不要重置 App 数据。定向宿主测试命令为 `node --test apps/android/tool/device-screen-protection.test.mjs`，不能替代交互或升级任务的设备证据。
