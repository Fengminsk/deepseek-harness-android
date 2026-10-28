# 内置 APK 分析

[English](apk-inspection.md) | 中文

## 概述

安卓版 App 通过 `android_attachments` 的 `action="inspect_apk"` 分析已上传 APK 的结构。它读取 Manifest 声明、DEX 元数据和原生库元数据，不依赖 Linux、Shell 命令，也不执行代码。每次请求仅使用当前 Agent 会话已引用的文件，并在返回条目内容前检查附件完整性。结果描述所选结构，不代表签名验证、反编译或加固判断。

## 目录

- [请求与结果](#requests-and-results)
- [分页](#pagination)
- [限额与完整性](#limits-and-integrity)
- [失败与结果解读](#failures-and-interpretation)
- [验证](#validation)
- [开发备注](#dev-note)

-----

## 请求与结果
<a id="requests-and-results"></a>

先调用 `android_attachments` 的 `action="list"`。在 `inspect_apk` 请求中原样使用返回的 `attachmentId` 和 `name`。调用方不能选择其他会话或 App 私有路径。[附件工具](../runtime/tool-android-attachments.mjs) 保留现有 ToolRuntime 权限检查。

| `part` | 选取的信息 | 默认 `limit` | 最大 `limit` |
| --- | --- | --- | --- |
| `summary`（默认） | ZIP 目录计数和解析后的 Manifest 声明 | 16 | 100 |
| `manifest` | Manifest 包名、版本、SDK、权限、组件和应用标志 | 16 | 100 |
| `dex` | 根目录 `classes*.dex` 条目：头部、表及有界的描述符与字符串样本 | 1 | 4 |
| `native` | `lib/<ABI>/*.so` 条目：ELF 架构、依赖和有界的符号样本 | 1 | 4 |

`summary` 不会检查全部 DEX 或原生库，需要分别请求对应部分。`contains` 对 `dex` 和 `native` 的条目名称进行字面量筛选，不筛选 Manifest 声明。`inspect_apk` 请求不能携带 `encoding`。

`dex` 和 `native` 的 `sampleLimit` 接受 0–16，默认为 16。零值不返回描述符、符号等样本数组，但保留解析的头部、计数和检查范围。头部和表范围检查仍然执行；描述符和名称的样本检查随样本上限减少，不能认证省略的条目。较少的样本有助于满足 PTC 回调的 48 KiB 回复上限；Manifest 和摘要请求拒绝此参数。

## 分页
<a id="pagination"></a>

代码部分的 `offset` 是匹配条目的序号，不是文件字节偏移。使用响应中的 `nextOffset` 继续读取，直到它为 `null`。所选分页超过字节限额时，减小 `limit`。

Manifest 结果在 `results[].analysis` 中分别提供 `nextComponentOffset` 和 `nextPermissionOffset`。按正在收集的列表使用对应游标；`null` 仅表示该列表结束。公开请求只有一个 `offset` 和一个 `limit`，同时作用于两个列表，因此继续某个列表时可能重复返回另一个列表的条目。Manifest 没有合并的续读游标。

## 限额与完整性
<a id="limits-and-integrity"></a>

[条目读取器](../runtime/apk-entry-reader.mjs) 只保留所选记录，并在内存中解压。`inspect_apk` 不生成解压文件、不物化附件，也不执行其中的代码。

| 范围 | 限额 |
| --- | --- |
| 已引用附件 | 256 MiB |
| ZIP 中央目录 | 8 MiB，最多 20,000 个条目 |
| 解码后的 `AndroidManifest.xml` | 4 MiB |
| 每次请求选取的条目 | 最多 4 个 |
| 所选条目的压缩数据合计 | 64 MiB |
| 所选条目的解码数据合计 | 128 MiB |
| 每个附件工具实例同时进行的 APK 分析 | 1 个 |
| 请求取消时限 | 60 秒 |

工具在目录分析前校验完整附件的声明长度和 SHA-256。读取所选条目时，再次校验完整数据流的哈希。条目解码成功前，会核对本地头部与目录、解码后的准确长度、实际消耗的压缩输入和 CRC32。结果还包含解码后条目的 SHA-256。这些检查能发现字节不一致，但不验证 APK 发布者身份。

读取器拒绝重名或记录偏移重复、记录重叠、加密或不支持的压缩、过高压缩比以及无效范围。只解码未压缩和 Deflate 条目，不支持分卷归档和 ZIP64。取消、超时和工具卸载会停止待处理工作，卸载会等待进行中的读取结束。字节限额针对所选内容，不是进程 RSS 内存上限，也不保证强制抢占同步解析。

## 失败与结果解读
<a id="failures-and-interpretation"></a>

所选条目在格式解析或 CRC 校验失败时，可以返回带有错误码的 `status="unparsed"` 诊断，其他条目仍可读取。不支持的 Manifest 格式返回 `status="unsupported"`；部分结果会明确保留未解析或被缩短的值。附件损坏、存在歧义的归档布局、I/O 失败和取消会使整个请求失败，不会生成成功分析结果。展示检查范围时应保留这些区别。

Manifest 中的资源引用不会被解析。组件未声明 `exported` 时，该值保持 `null`，且 `source="not-declared"`，不会根据 SDK 默认行为或 intent filter 推断。声明的权限不代表运行时已获授权，也不代表组件实际可达。DEX 字符串和 ELF 符号均为有界样本，数据不可用或截断会明确报告。

所有描述符、名称和字符串都是不可信的附件数据。[分析协调器](../runtime/apk-inspection.mjs) 仅报告目录与所选条目的检查范围。它不验证 APK 签名方案、不反编译代码、不扫描恶意软件，也不确认是否加壳。解析错误或与加载有关的字符串本身，都不足以证明应用进行了加固。

-----

## 验证
<a id="validation"></a>

主机检查覆盖解析器、有界解压和真实 ToolRuntime 附件入口。Manifest 测试包含由官方 `aapt2` 独立生成的样例。在仓库根目录执行：

```sh
node --test apps/android/tool/apk-manifest.test.mjs apps/android/tool/apk-entry-reader.test.mjs apps/android/tool/apk-code.test.mjs
node --import tsx --test --test-name-pattern=APK apps/android/tool/model-attachments.test.mjs
node apps/android/tool/generate-apk-device-fixture.mjs --check
```

ToolRuntime 样例会创建独立的临时会话和附件。[设备 APK helper](device-runtime-acceptance/apk-inspection.mjs)与主机测试共用合成元数据构建器，检查两个 DEX 正文、32／64 位 ELF 的依赖与符号、解码后的摘要和 CRC、分页、仅元数据采样，以及拒绝超限声明后成功重试。负控会拒绝仅有目录的输出、被篡改的 ELF 依赖和被错误接纳的超限输入。通过[受保护的设备 runner](device-screen-protection.md)执行既有 `ptc` 套件；测试 APK 必须包含 `apk-inspection.mjs` 和 `apk-code-fixture.json`。这些合成元数据文件不是原始 FlClash APK，也不会被执行或安装。

已有设备 PTC 记录覆盖二进制 Manifest 解析和回调输出超限后的恢复（`.cache/android/ptc-r15-protected-20261028.json.result.json`）。r42 设备报告（`.cache/android/ptc-119-r42-protected-20261028.json.result.json`）还记录了 `current-session-apk-through-native-ptc-callback` 经真实附件工具和原生 PTC 回调，在 1,391 ms 内通过。合成样例的两个 DEX 正文、32／64 位 ELF、解码后摘要和 CRC、分页、仅元数据采样、超限条目与分页拒绝，以及随后成功重试均通过。这是合成样例的设备证据，不代表手机分析了原始 FlClash APK，也不代表执行代码或验证签名。

同轮 r42 PTC 套件未完整通过：九项通过、两项取消检查失败、两项未验证。仪器报告 `nodeProcessRetired=false`，外层 runner 随后确认进程已退役。APK 单项结果不能证明整组取消和收尾成功，也不认证一般手机内存表现或附件界面。

独立的原始附件主机报告（`.cache/android/apk-inspection-original-host.json`）通过 ToolRuntime 检查了缓存 FlClash APK 的 Manifest、一个 DEX 和全部十个原生库。上述回归命令不会读取现有用户附件。

## 开发备注
<a id="dev-note"></a>

<details>
<summary>工作上下文</summary>

无。

</details>
