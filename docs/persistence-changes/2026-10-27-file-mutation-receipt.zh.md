---
description: "记录持久化类型更改及其兼容性确认。"
kind: persistence-change
---

# 2026-10-27-file-mutation-receipt

[English](2026-10-27-file-mutation-receipt.md) | 中文

## 概述

为已完成的 write 和 edit 效果添加 file-mutation-receipt 归属信息，使其在取消或观察失败后仍保留。

## 目录

- [声明](#declaration)
- [兼容性](#compatibility)
- [验证](#verification)
- [开发备注](#dev-note)

<a id="declaration"></a>
## 声明

```yaml persistence-change
schemaVersion: 1
id: 2026-10-27-file-mutation-receipt
baseline: false
changes:
  - root: "event:agent/inbox/spliced"
    previous: "2026-10-13-user-rpc-principal"
    after: "91fcc85353cef9f2c2ebb8a76eb52694affac7a3ae3309ae2abb369482d1f1ab"
    decision: same-version
  - root: "event:developer/message"
    previous: "2026-10-13-user-rpc-principal"
    after: "5ad5f4d16858c46356484ed60c991589b8494392c4a594ab1be5507690ac306d"
    decision: same-version
  - root: "event:session/title-llm-request"
    previous: "2026-10-13-user-rpc-principal"
    after: "d5742f81b66fa3c622e956454759928c15ebe15fe51db181c6fd5b4e339aa337"
    decision: same-version
  - root: "event:user/message"
    previous: "2026-10-13-user-rpc-principal"
    after: "ba40e93e4d66bcbf056e030b8f6ad36148b200312f68ebe7539cce7857d2eead"
    decision: same-version
```

<a id="compatibility"></a>
## 兼容性

已有消息和排队输入记录无需修改即可读取。新 source kind 仅标记一条普通 user 角色文本上下文，不增加回放操作、权限、校验要求或必需插件。生产方仅在文件系统提供方成功后记录完整规范路径和操作。当前及较早读取器无需安装生产方即可保留未知 source kind 及其 JSON 元数据，因此回执文本仍可读取，回放不会再次修改文件。缺少回执时保留原有行为。若执行后策略明确阻断结果，ToolRuntime 仍可丢弃工具正文附带的上下文；该回执不覆盖此决定。Session 格式版本不变。

<a id="verification"></a>
## 验证

pnpm exec vitest run packages/fs/tool-fs/tests/integration.spec.ts：38 项通过，涵盖实际落盘后取消、fs/observed 监听器抛错及普通成功。修改生产方前，5 个回执断言均失败。pnpm exec vitest run packages/fs/tool-fs/tests/tools.spec.ts：99 项通过。pnpm exec vitest run packages/session/session-persistence-jsonl/tests/native-source-admission.spec.ts -t 'preserves external attribution'：4 项通过，涵盖读写句柄及普通、Zstandard 文件，未安装生产方时仍保留外部来源元数据和已存字节。pnpm exec tsc -b packages/fs/tool-fs 通过。不宣称已执行真机或已发布二进制验证。

<a id="dev-note"></a>
## 开发备注

无。
