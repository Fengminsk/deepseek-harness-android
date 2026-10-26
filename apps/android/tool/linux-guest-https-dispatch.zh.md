# Linux 客体 HTTPS 代理边界

`LinuxGuestHttpsDispatch` 属于 App。它把已准入的 `LinuxGuestBrokerWire` v2
`HTTPS_HOST` 帧接到 `IsolatedNetworkBroker`。该操作承载规范化的 ASCII HTTPS
完整 URL；`HTTPS_HOST` 是保留的枚举名称。客体拿不到 socket、网络权限、Cookie、
请求体、任意请求头或 App 文件路径。

每次请求先核对 wire 中待处理对象的身份、有效租约和精确主机名。网络代理只允许 GET，
单次期限最多十秒；Android DNS 有期限并绑定所选网络，非公网地址会被拒绝；TLS
连接使用检查过的地址和主机名；每次重定向都重新接受相同的精确主机白名单检查。
App 私有审计日志在 DNS 前登记调用 ID，返回前写入终态。适配层再次读取终态并比对
调用 ID、主机名和状态。审计缺失、不确定、重放或损坏时，取消客体运行，不返回结果。
租约撤销会关闭正在使用的连接。

结果载荷使用 `DSHH` v1：4 字节魔数、1 字节版本、1 字节固定网络状态码、2 字节
HTTP 状态码、1 字节重定向次数，随后是三个 2 字节长度及 ASCII 最终 URL、UTF-8
内容类型和原始响应体。多字节整数为大端序。响应体上限 1536 字节，单个回复上限
4096 字节，同一个适配器全部回复累计上限 64 KiB。非 OK 状态表示请求失败。
状态码固定为：0 成功，1 策略拒绝，2 离线，3 超时，4 响应过大，5 失败，
6 已取消，7 审计不可用，8 审计已满，9 审计不确定，10 重放拒绝。其中 7 到 10
不会发回客体，而是取消运行。

`AndroidLinuxGuestHttpsDispatch.open` 复用 `:agent` 进程的持久审计、限时
Android DNS 和固定地址 TLS 实现。这只是接线组件：原生客体 IPC、镜像校验、进程
收尾和 Agent 工具开放仍需独立实现与验收。运行
`node apps/android/tool/acceptance-linux-guest-https-dispatch.mjs` 可执行仅限
主机的合成 DNS/传输测试，不能替代 Android 真机验收。

一次准入的运行应保持一个适配器；关闭适配器会撤销网络并关闭 wire，从而取消尚未
完成的运行。不要为每次调用单独创建并立即关闭适配器。
