# Linux 来宾镜像交接

[English](linux-guest-image-handoff.md) | 中文

可信 App 代码可在构造 `LinuxGuestBinderBinding` 时显式提供 `LinuxImageDescriptorBroker`；默认仍只做 Binder 握手。目前没有 Agent 工具或界面入口创建这种绑定，普通 APK 也未包含 Alpine 归档、PRoot 可执行文件或原生监管器。

在持久化准入的运行完成 `OPEN`／`HELLO` 后，App broker 校验已安装的锁定版 Alpine 归档，签发一次性、15 秒有效的租约。App 通过 Binder 仅传送锁定的版本、ABI、字节数和 SHA-256 元数据；隔离 Service 按编译期常量核对，然后返回随机调用 ID。App 消耗租约一次，把归档复制到封存的只读 `SharedMemory`，再传送该描述符。每条消息都核对运行 ID 与 nonce；App 还使用 Android Binder 实测发送 UID 核对隔离 UID，Service 核对实测 App UID。重放、元数据变化、过期、取消和可写描述符都会终止交接。

在 App 领取归档之前，Service 会检查缓存目录可用且没有旧的客体根目录；解包前再检查一次。Service 确认快照不可写后，由 `LinuxGuestRootfsStager.stagePinned` 核对完整摘要、归档上限和 tar 成员图，然后解包至隔离进程 `cacheDir` 下仅供本次运行使用的目录。普通文件变为仅所有者可读，只有归档中标记可执行的文件才保留所有者执行位；目录和文件均去除群组、其他用户及特殊权限位。暂存目录清理失败时同一 owner 可以重试。这些模式不代表 Android 已允许执行暂存文件。取消或 Service 销毁时清理。返回的 `IMAGE_STAGED` **只确认数据已暂存**，不代表任务完成、进程已运行，也不能据此向用户发布成功。App 在收到确认后释放描述符。暂存目录由隔离 UID 创建；如果 Android 拒绝写入，则按失败处理。[Android 16 隔离进程策略](https://android.googlesource.com/platform/system/sepolicy/+/android16-release/private/isolated_app_all.te)表明普通设备上的缓存路径很可能不可用；目前没有真机结果。

Service 没有原生启动器或 PRoot 调用。若隔离进程在目录发布与清理之间被杀，可能遗留按运行 ID 命名的缓存目录，直至系统清理；正式启用前还需做真机观测与恢复处理。Android 10 以上的执行限制、SELinux 行为、进程树收尾、文件／网络 broker 以及许可分发审查也分别待验。

`LinuxGuestImageHandoffInstrumentation` 检查未锁定的镜像报价和调用 ID 不匹配的快照，不安装或执行镜像。有效报价在普通设备上可能返回 `isolatedStorage=preflight-denied`；这是记录存储阻碍，不是暂存成功。另设可选的正向真机验收 `LinuxGuestPinnedImageInstrumentation`：由 `acceptance-linux-guest-pinned-image-device.mjs` 将准确锁定的 Alpine 归档放入唯一的 App 缓存测试文件。主机先验证来源锁定值，App 制作封存快照时再次验证。测试要求独立的隔离 UID、锁定镜像的 `IMAGE_CLAIM`、带固定摘要的 `IMAGE_STAGED`，随后取消并再次报价，以发现普通取消后遗留的暂存目录。拒绝、超时、预检阻断、清理失败均不能算通过。运行器只删除本次唯一的 App 和 `/data/local/tmp` 测试文件，不把归档打包进 APK，也不开放用户侧来宾执行。

只有在调试版主 APK、对应 AndroidTest APK、当地已验证来源的归档均就绪且获准使用手机时运行：

```text
node apps/android/tool/acceptance-linux-guest-pinned-image-device.mjs --apk <main.apk> --test-apk <androidTest.apk> --archive <alpine-minirootfs-3.24.3-aarch64.tar.gz>
```

这一验收尚未在真机运行。主机测试和 AndroidTest 编译均不能证明 Android 允许存储或执行。第二次报价只检验普通取消后的预检可见性，不能证明强制杀进程后的恢复；后者仍是独立阻碍。
