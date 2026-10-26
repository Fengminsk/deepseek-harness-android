# 隔离客体 HTTP 能力基础

[English](isolated-network-broker.md) | 中文

`IsolatedNetworkBroker` 是内部隔离 V8 客体的 App 侧网络能力。`IsolatedScriptRunController` 可选接收 App 持有的网络策略，要求有效的执行策略租约、精确域名集合和持久化日志；没有明确宿主策略时，客体没有网络 API 或宿主对象。**目前没有模型调用的 PTC 提供方、策略设置页、用户审批流程或生产调用点。** 非空主机策略必须提供 App 私有的 `IsolatedNetworkJournal`，并为每次 `get(callId, url)` 提供调用方持有的稳定 UUID；单参数方法不能绕过这一要求。这不代表 PTC 或工作流已对齐。

代理只接受明确列入白名单的、规范化的 ASCII DNS 主机名和 HTTPS URL；默认 `Policy.off()` 为空。它拒绝 IP 字面量 URL、URL 用户名密码、片段、非 443 端口、本地或特殊用途域名、非 ASCII URL、过长 URL、越过白名单的重定向、非公网 IPv4 DNS 回答及仅有 IPv6 的回答。初版只提供 GET，不接收调用方自定义请求头、请求体、Cookie、认证、WebSocket、客户端证书或代理。上限为每个代理 5 分钟有效期内 64 次调用、3 次重定向、1 MiB 响应、32 KiB 响应头、单次调用 10 秒截止时间。每一跳都重新解析、授权和固定地址；失败时不会放宽域名策略。

返回状态区分：域名、URL、重定向或配额不获准时是 `POLICY_DENIED`；单次调用的总时限耗尽（包括重定向之后）是 `DEADLINE_EXCEEDED`；响应正文或响应头超限是 `RESPONSE_TOO_LARGE`，不再误报为域名策略拒绝。`AUDIT_UNAVAILABLE` 表示网络 I/O 前无法确认接纳记录已持久化；`AUDIT_FULL` 表示持久审计容量已满；`AUDIT_UNCERTAIN` 表示已接纳的调用意外失败，或终态同步失败。即使传输层抛出未检查异常，代理也会撤销后续 I/O，并尝试记录不确定结果。重复使用调用 ID 返回 `REPLAY_DENIED`，不进行 DNS 或传输。调用方可选择更短的单次时限，但不能超过 10 秒。超限响应不会返回部分正文。

`AndroidNetworkJournal.open(context)` 只接受 `:agent` 进程，并为日志提供 Android 目录 fsync。DNS 之前，日志写入调用 ID、规范主机名和时间戳组成的 `ADMITTED` 记录，再同步文件和目录。代理确定结果后，先原子替换为包含终态、是否进入传输阶段的记录并同步目录，才对调用方发布结果。崩溃或终态同步失败会留下无法确定的服务器端效果；调用方不得自动生成新 ID 重试。审计不保存 URL 路径、查询参数或响应内容。每个调用 ID 都会保留；文件达到 8192 个，或当前文件加上一条最大长度记录将超过 16 MiB 时，接纳会拒绝。崩溃遗留的临时文件同时计入文件数和字节数。系统不会自动删除旧记录，开放功能前仍需确定保留与导出策略。

`PinnedTlsTransport` 通过 DNS 回答携带的 socket 路由连接至已校验的 `Inet4Address`，然后在**这条已连接的 socket**上使用原 DNS 主机名进行 TLS SNI 与 HTTPS 端点校验。HTTP 层不再次按主机名解析，也不创建走进程默认网络的 socket；因此既避免 DNS 重绑定，也避免默认网络切换把已固定的 IP 偷换到另一条路由。它只读取有界 HTTP/1.1 固定长度、分块或连接关闭定界的响应，不解压响应，也不保存 Cookie。Android 官方 [`Network.getSocketFactory()`](https://developer.android.com/reference/android/net/Network#getSocketFactory()) 说明该工厂创建绑定指定 Network 的 socket；主机名校验参见 [SSLParameters](https://developer.android.com/reference/javax/net/ssl/SSLParameters)。保守拒绝的 IPv4 地址参考 IANA [特殊用途地址登记表](https://www.iana.org/assignments/iana-ipv4-special-registry)。IPv6 路由在初版明确不支持。

内部桥只提供 `host.call({action:'HTTPS_GET',callId,url})`；App 核对精确域名集合和每次租约的网络调用额度，再调用已审计的代理。只有网络能力的租约无需文件工作区，`host.grants` 为空。桥将正文限制在 64 KiB：UTF-8 文本作为 `bodyText` 返回，其他字节作为 `bodyBase64` 返回；超限结果记为 `RESPONSE_TOO_LARGE`。网络审计无法确认终态落盘时，脚本输出被扣留。这**还不是可用的用户实时网络授权**。代理没有使用无法证明截止时间的阻塞式 Java `InetAddress.getAllByName()`。`AndroidDeadlineResolver` 在 API 29 及以上使用 Android 的异步 [`DnsResolver.query(Network, ..., TYPE_A, ...)`](https://developer.android.com/reference/android/net/DnsResolver) 实现解析器接口。它选择非空、已验证且具备互联网能力的默认 [`Network`](https://developer.android.com/reference/android/net/ConnectivityManager#getActiveNetwork())，拒绝进程绑定网络与其不一致的情况，指定该 Network 发起查询，并在 DNS 回调中再次核对默认网络。解析结果同时携带 DNS 地址快照与该 Network 的 socket 工厂；重定向后的每一跳各有独立解析结果。如果原 Network 断连，其工厂创建的 socket 将失效，而不会回退到新的默认网络。查询绕过 DNS 缓存，使用取消信号，拒绝空或过量回答，忽略晚到回调；单调截止时间约束调用方等待。只有一个工作线程、无排队的执行器限制了可能卡在 Binder 提交中的线程数量。在可能阻塞的网络状态读取和 `DnsResolver.getInstance()` 之后、调用 `query` 之前再次检查取消状态和截止时间。API 28 因缺少异步 API 直接拒绝。门禁检查之后到 Android 实际发出查询之间仍有竞态，不能声称绝无逾期 DNS 报文。

路由关联已进入接口约束：传输层没有进程默认 socket 后备路径，Android 解析器只提供选定 Network 的 socket 工厂。解析器在 DNS 回调时再次检查该 Network 的资格；之后即使默认网络或 VPN 改变，已绑定的 socket 不会被转发到新网络，但原网络仍连接时，请求仍可能经原网络完成。撤销会关闭已登记的在途 TCP socket，并标记租约取消；DNS 等待在轮询间隔内发现同一标记并取消 Android 查询信号。路由创建等待期间也检查撤销，调用方离开后返回的 socket 会关闭。一个工作线程、无排队的路由开启器约束调用方等待 socket 创建的时间，并关闭超时后返回的 socket；如果平台调用不响应中断，后续请求将一直拒绝，直到该线程返回。传输层在设置 socket 超时前拒绝过期截止时间，避免 `SO_TIMEOUT=0` 变成无限等待；守护计时器会在总截止时间关闭底层 TCP socket，覆盖 TLS 握手及请求写入。这些是主机测试的中止机制，尚非 Android Binder、原生 TLS 或进程终止的真机级硬时限证明。撤销无法撤回服务器已接收的字节，也无法证明没有晚到的远端效果。尚无真机验证。

主机测试：`node apps/android/tool/acceptance-isolated-network-broker.mjs` 和 `node apps/android/tool/acceptance-android-dns-resolver.mjs`。它们验证审计接纳及终态失败、重复 ID、存储上限和崩溃遗留临时文件计数、在途 socket 关闭、DNS 撤销、重定向路由传递、只使用选定工厂创建 socket、固定 IP、回答快照、晚到回调、总截止时间、解析提交容量耗尽和无效响应。Android 仪器测试已编译网络专用租约、模拟 DNS 与传输、拒绝域名和畸形请求场景，但尚未在设备执行。宿主检查和编译均不能证明 Android `DnsResolver`、真实 TLS 或设备 UID／网络策略。启用模型可见网络工具前，需要加入用户审批的持久记录与审计保留策略，并在无 Root 设备上验证 TLS、代理绕过、重定向、网络切换与断开及进程终止。隔离进程不应持有 INTERNET 或直接 socket 权限；经批准的网络 I/O 只能由 App 侧代理执行。

App 持有的执行策略租约在运行、父运行或策略撤销时同步取消网络代理。每次调用的截止时间受父子租约中最早的到期时间约束。因此，在 DNS 完成后、进入传输层前撤销会阻止请求写入；与写入重叠或已经发出的请求仍可能产生远端效果，不能当作已确认成功。
