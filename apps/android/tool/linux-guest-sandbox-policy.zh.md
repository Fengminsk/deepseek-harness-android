# Linux 来宾 broker 请求策略

[English](linux-guest-sandbox-policy.md) | 中文

可信 App 只能从已持久登记且仍有效的 `IsolatedExecutionPolicyOwner.Lease` 创建 `LinuxGuestSandboxPolicy`。默认范围拒绝文件和网络。该策略仅在原生来宾请求 broker 前检查范围；它不隔离原生进程、不建立挂载、不发放文件描述符、不打开套接字，也不授权 Shell 命令。每次请求仍须由 App 侧文件或 HTTPS broker 根据同一有效租约检查次数、版本、目标和持久审计。

文件请求使用 `/workspace/<相对文件名>`。`/workspace/` 是虚拟 broker 命名空间，绝不是 App 私有工作区的绑定挂载。真实 App 路径只留在策略所有者和文件 broker 中。现有 `IsolatedCapabilityBroker.GrantSpec` 拒绝绝对目标、上级路径段、空路径段、反斜杠、冒号、控制字符、无效 UTF-8，以及过深或过长的名称。读取和搜索需要已批准的可读路径；写入还需要可写路径，即使较宽的目录可写，也拒绝 `.git`、`.agents`、`.codex` 和 `.aws` 路径段。目录名称本身不能当作文件操作。

网络预检只把规范化的 ASCII DNS 主机名与租约内的精确主机集合比较，且网络调用额度必须大于零。预检不解析 URL，也不放行重定向。`IsolatedNetworkBroker` 仍须逐次要求 HTTPS、在期限内解析 DNS、绑定网络路由及 TLS 对端、检查每次重定向、限制响应并记录调用。原生来宾没有原始网络授权。子任务只能通过 `IsolatedExecutionPolicyOwner.admitChild` 缩小所有者、会话、路径、主机、额度和租约时间。

撤销、策略替换或租约过期后，后续预检都会拒绝。预检结果不能证明已启动的 Linux 子进程停止，也不能证明 PRoot 隔离了宿主路径或直接套接字。Agent 获得通用 Linux 命令前，仍需完成进程树和无 Root 真机验证。

主机检查：`node apps/android/tool/acceptance-linux-guest-sandbox-policy.mjs`。覆盖默认拒绝、路径与主机精确匹配、受保护路径写入、子任务缩权和撤销；不证明真机隔离或实际 PRoot 执行。
