# 短时真机验收预检

只在候选 APK 已通过 `verify-apk.ps1`、并已记录 SHA-256 后运行：

```powershell
node apps/android/tool/device-readiness.mjs --apk .cache/android/pocket-harness-0.1.0+37-arm64-debug.apk --sha256 <已记录的-sha256>
```

命令以有界内存计算 APK 哈希，然后查询 `adb devices -l`。只有恰好一台设备已连接且授权时，才读取 Android API 等级、ABI、已安装包版本、悬浮窗 AppOp、当前窗口标题与 Agent 进程 ID。所有设备查询均为只读；此命令不会安装、启动、授予权限或保持屏幕亮起。

`connected` 仅表示 ADB 能寻址一台设备。`overlayWindow` 为 false 仅表示在该次快照中未观察到预期标题，不能证明悬浮窗从未显示。探针的 `ok: false` 表示信息不可得，并非值为 false。可选的 1px 悬浮窗仍需在实际任务期间运行 `acceptance-overlay-lease.mjs`，并在手机上验收其生命周期和后台行为。某些 Android 前台服务后台重启豁免要求可见悬浮窗；完全透明的 1px 悬浮窗不构成此豁免，也不能保证进程存活。

这个预检用于确定是否适合申请一段简短的手机测试时间。如果设备缺席、尚未授权或有多台设备，就继续做主机侧检查，避免安装请求停滞而占用手机。
