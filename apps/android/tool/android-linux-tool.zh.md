# Android Linux 工具

`android_linux` 是 Agent 可调用的七种固定命令工具，经由 App 原生命令管理器在
Android 隔离 UID 服务中执行。工具不接受可执行文件名、Shell 代码、文件路径、
环境变量、网址或网络目标。

| 命令 | 输入 | 结果 |
| --- | --- | --- |
| `kernel` | 无 | `uname -a` |
| `identity` | 无 | 数字形式的隔离 UID |
| `sha256` | 本次提供的文本 | SHA-256 摘要 |
| `count_bytes` | 本次提供的文本 | 字节数 |
| `count_lines` | 本次提供的文本 | 行数 |
| `sort_lines` | 本次提供的文本 | 排序后的行 |
| `filter_literal` | 本次提供的文本及字面量 | 匹配行；退出码 1 表示无匹配 |

文本输入至多 64 KiB，字面量至多 128 个 UTF-8 字节，原生输出至多 4 KiB，
同时至多运行两条命令。Node 载体设置 6.5 秒请求期限及取消，子进程期限为
1.5 秒。Agent 只会看到已完成命令的输出。App 所有者会记录先于准入到达的取消，
避免已中止的工具调用稍后才启动命令。
对已经派发的取消，App 会等待隔离客体在直接子进程回收后发回终态回执。
子进程回收无法确认或宿主时限到期时，不会返回成功输出。
取消 RPC 仅在运行尚未派发，或经核验的客体回执确认直接子进程已回收时
返回 `settled=true`。即使 `settled=false`，本次 owner 存活期间未确认运行 ID
也会被阻止重放，而且 owner 停止准入新命令。
Node 载体会严格核验 `{cancelRequested, settled}` 回执。已派发请求的取消回执
缺失、格式错误或 `settled=false` 时，载体会抛出明确的 `outcome-uncertain` 错误并
关闭，不会把原始中止当作安全取消或重放该命令。`WORKER_DIED` 也按结果未确认
处理。已确认收尾时保留调用方原来的中止或超时原因，同时不展示迟到输出。
执行 RPC 现在携带 `retirementConfirmed`。Node 对每种终态均检查这一事实；
缺失或为 `false` 时不展示结果，标记结果不确定并关闭该命令载体，不能仅凭
`ERROR`、`CANCELLED` 等状态名推断子进程已经回收。

Android 服务在启动固定的系统可执行文件前，会验证隔离 UID、无法读取 App
私有数据以及无法创建网络 socket。验证不通过时直接失败。这只是小范围实用命令，
不是可任意运行进程、挂载目录或使用网络的完整 Linux 发行版或容器。可选的
Alpine rootfs 候选镜像未通过该工具挂载或执行。
这些固定工具都是单进程命令。杀死直接子进程不能证明未来的 Shell 或 PRoot
运行派生的子孙进程都已结束。通用 Linux 执行保持关闭，仍需受信的进程组
启动器和真机终止证据；Android 杀死 Service 进程时不保证调用 `onDestroy()`。

源码和 JVM 测试覆盖请求上限、取消准入和回执投影。仅仅编译 APK 无法证明手机上
隔离 UID 和进程清理的实际行为；设备可用后需运行
`acceptance-linux-command-device.mjs` 验证。
