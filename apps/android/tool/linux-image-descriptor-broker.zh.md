# Linux 镜像只读文件描述符边界

这是**内部数据传输**，不是可执行的 Linux 容器。模型、Node 运行时、Flutter 界面和隔离 Linux 命令服务都不能调用它。`LinuxImageLeaseOwner` 只认 `linux-userland-source-lock.mjs` 锁定的 Alpine 3.24.3 ARM64 镜像，位置由 App 从 `noBackupFilesDir/linux-userland/versions/<sha256>/image.tar.gz` 构造。客体或 Binder 请求不能指定路径、URL、版本、摘要或文件名。App 必须先安装并独立核验候选镜像；目前尚无 App 内安装器。

受信 App 可以为一个 `runId` 签发一次性不透明令牌，有效期最多 60 秒。签发及领取时都会完整核对归档；领取令牌先被消耗，核验失败也不能重试。Android 适配器用 `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` 打开文件，把已打开的内容拷贝到独立的 `SharedMemory` 快照（最大 8 MiB，同时最多两份）。拷贝时核对源文件身份、长度和 SHA-256；先解除唯一的可写映射，再执行 `setProtect(PROT_READ)`，最后重读快照核对摘要。任何失败都关闭快照。领取后源归档即使被改写，也不能改变已封存的字节。发送前必须把接收方绑定到获准运行的精确隔离 UID；这段 Binder 绑定与客体接收端尚未实现。

**撤销限制：** `SharedMemory` 描述符一旦传给客体，发送端关闭副本或撤销令牌也无法收回接收端的副本。发送端在传递后必须关闭自己的描述符，取消时必须回收客体进程。归档只是数据，不能从 App 可写存储直接 `execve()`；PRoot 也不形成安全边界。真正的客体进程仍须受隔离 UID、文件／网络代理、时限、子进程回收和 Android 真机验收约束。在这些部分接通并验收前，通用 Linux／PRoot 入口保持关闭。

主机测试使用 `javac` 编译 `LinuxImageLeaseOwner.java` 与 `LinuxImageLeaseOwnerTest.java`，然后运行测试主类；覆盖伪造运行 ID／令牌、到期、撤销、重放和同长度归档替换。`linux-image-descriptor-broker.test.mjs` 核对 Android 固定摘要与独立审查的上游锁定来源一致。真机专用的 `LinuxImageSnapshotInstrumentation` 会在领取后改写源文件，检查快照不变，并检查封存后无法新增可写映射。单靠编译不能证明系统保护行为或客体传输；真机验收前客体入口保持关闭。

参考：[Android 隔离 Service 权限边界](https://developer.android.com/guide/topics/manifest/service-element#isolatedProcess)、[SharedMemory 映射与权限保护](https://developer.android.com/reference/android/os/SharedMemory)、[Android App 可写目录执行限制](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)。
