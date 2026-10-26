# DSH 原版工具设置的手机交互

此轮对照原版配置结构，不改变 Cordis 字段名、默认值或插件行为。手机页通过 `settings.describe` 读取实际结构和当前值，编辑时先形成草稿；返回命名空间主页后，按 `expectedRevision` 一次性保存。版本变化由原有合并流程处理，传输结果不确定时保留待核对状态，不自动重试写入。

| DSH 原版来源 | 配置字段 | Android 交互 |
| --- | --- | --- |
| `packages/fs/tool-fs/src/index.ts` | `read`、`readImage`、`write`、`edit` | 「文件能力」分组内原生开关 |
| 同上 | `readLimit`、`readMaxLineLength`、`readMaxBytes`、`readStreamMinSize` | 高级「读取限制」中的独立数值页 |
| `packages/fs/tool-fs-search/src/index.ts` | `sampleOverCapGlobResults` | 「搜索行为」中的原生开关，解释超额取样方式 |
| 同上 | glob、grep、输出及超时预算 | 高级「搜索限制」中的独立数值页 |
| `packages/web/tool-web/src/index.ts` | `search`、`fetch` | 「联网能力」分组内原生开关 |
| 同上 | 搜索数、查询数、输出和超时预算 | 高级「联网限制」中的独立数值页 |
| `packages/interaction/tool-ask-user/src/index.ts` | `mode` | 「向用户提问」中的「常规提问／带超时的提问」选择页 |
| 同上 | `timeout` | 「一直等待」即 `-1`，常用时长选项和其他正整数秒数 |

开关只决定工具是否提供给 Agent；文件访问仍受 Android 工作区授权和沙箱约束，网页调用仍须有可用提供方和联网权限。`timeout` 只用于原版 `timed` 模式；`legacy` 模式保持原版阻塞行为。未知命名空间和后续新增字段继续由结构驱动的通用编辑器展示，避免因本地映射遗漏而隐藏配置。

组件回归覆盖原版字段分组、布尔开关、提问枚举与秒数、版本化保存及中途刷新后的草稿合并。真机展示仍需随整包验收。
