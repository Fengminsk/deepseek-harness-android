# PRoot 主机预检与调试真机探针闸门

[English](PROBE-READINESS.md) | 中文

锁定版本的 PRoot 与加载器目前只是**主机构建产物**，不是 Android App
功能。当前 APK 不能包含这两个 ELF，也不能包含 Alpine 根文件系统。
在 `build.ps1` 后执行不启动程序的主机检查：

```powershell
python apps/android/tool/linux-proot-candidate/probe-readiness.py --candidate-dir .cache/android/linux-proot-source/build-arm64-v8a
python -m unittest apps/android/tool/linux-proot-candidate/test_probe_readiness.py
```

检查器核对精确 SHA-256、小端 AArch64 ELF 文件头、可执行入口所在的段，
以及 PRoot 事件管道协议标记。它只报告 `hostIdentityAndElfReady`；
`distributionApproved`、`apkPayloadAllowed`、`deviceExecutionProven` 仍为
false。它不运行二进制，不复制到 Android 源码目录，也不读取 APK。

Android Gradle 配置会阻止源码目录中的已知候选文件名，以及改名后的这两个
精确 ELF 摘要。最终 APK 校验器同样按文件名和锁定摘要拒绝候选；摘要计算
只对解压长度等于这两个 ELF 的 ZIP 条目执行，避免遍历大型运行时归档。
此闸门无法识别修改后的二进制、任意改名的根文件系统，或藏在 `runtime.zip`
等嵌套归档里的候选字节；分发审查仍然必需。

打过事件补丁的 PRoot 若没有继承由操作系统拥有的
`DSH_TRACEE_EVENT_FD` 管道描述符及规范的 `DSH_TRACEE_RUN_ID`，会拒绝启动；
还需要 `PROOT_LOADER` 指向已安装加载器。单靠 Java `ProcessBuilder`
无法建立这条描述符和全进程树证据。独立的原生监管器正在默认关闭的构建
选项后开发；其计划中的固定诊断命令为 `/bin/true`，不接受模型输入、
用户文件或网络。待源码及许可交付审查完成后，才能把精确二进制对放入
专用内部诊断包，在用户授权的设备上安装测试。主机预检或 Gradle 编译
成功均不能算 Linux 已运行的证据。
