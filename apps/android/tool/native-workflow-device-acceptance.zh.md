# Android 内部工作流 Binder 验收

这是可选的真机验收，覆盖 App 持有的内部工作流准入链路。`NativeWorkflowAcceptanceInstrumentation` 在 App 的 `:agent` 进程运行，启动真实隔离 Binder 客体。七个用例检查有序回调及持久成功终态、客体报告失败的持久终态、畸形 DSL 结果需要检查、子智能体预留与结果及收尾、执行前取消、120 秒上限及 12 秒期限内的 5.5 秒回调，还检查子智能体结果待返回时取消、收尾，以及重建 App owner 后不重放结果。最后一个用例还检查子级在激活前仅完成预留时，经回调关闭确认及取消后可退役。测试仅用生成的标识，不授予用户文件或网络能力。测试回执会保留在 App 私有目录，因此应使用开发安装包。

两个 APK 使用相同源码和签名构建、取得手机测试授权后运行：

先在不操作手机的情况下核验安装包与清单：

```sh
node apps/android/tool/acceptance-native-workflow-device.mjs --apk <app.apk> --test-apk <androidTest.apk> --preflight-only
```

真机测试取得授权后运行：

```sh
node apps/android/tool/acceptance-native-workflow-device.mjs --apk <app.apk> --test-apk <androidTest.apk> [--serial <adb-serial>] [--allow-existing]
```

脚本安装前核验 APK 包名、相同签名证书及 AndroidTest 精确清单声明，再以保留 App 数据的 `adb install -r` 安装。未授权或不唯一的设备会被拒绝；若 App 已安装，须明确传入 `--allow-existing` 才会使用该安装。七项 instrumentation 断言必须各通过一次。宿主解析测试：`node --test apps/android/tool/acceptance-native-workflow-device.test.mjs`。

探针编译通过不等于真机证据。重建 App owner 的断言发生在同一个仍在运行的 App 进程内；单独的[进程终止验收](native-workflow-process-death-device-acceptance.zh.md)测试真实的应用停止。即使此处真机通过，也不证明原版 DSH 工作流函数体语义、安全子智能体启动、进程终止恢复或任意文件及网络访问。面向模型的工作流入口继续关闭。
