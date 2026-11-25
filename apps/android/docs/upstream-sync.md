# 上游同步计划：0.2.2-rc.1 → 0.2.2-rc.5

状态：**已执行（2026-11-25）**。合并与迁移完成，结果见 §11；真机验收与 Build 122 待做。
范围：`apps/android`（App + 内嵌运行时）、`apps/remote-host`、`packages/experimental/device-interconnect`
依赖的上游核心；不含 `apps/desktop`、CUA、Forge、Connector 等与 Android 无关的表面。
基线：本地 `android` @ `bb4363383c`；上次同步合并 `493fb02c87`（上游 `fcc0ad4621` = `dsh-v0.2.2-rc.1`）。
取证：只读 git（`rev-list` / `merge-tree --write-tree` / `diff` / `show`）；执行阶段的分支与提交见 §11。

---

## 0. 结论先行

1. **同步目标取 `dsh-v0.2.2-rc.5`（2026-11-18），不取 `0.2.3-alpha.2`。** 理由见 §3，关键点是
   内嵌 `libnode` 24.22.0 与上游 0.2.3 的 Node 24.22.3 下限冲突，以及 vendor cordis 4.2.0-alpha.1。
2. **规模**：776 个上游提交；28 处文本冲突；2 个包被上游删除必须迁移
   （`office-to-pdf` → `office-kit`、`deepseek-account-platform` → `deepseek-account`）；
   16 处本地补丁需要重放（多数能直接合并，少数必须按上游新结构重写：`core/tools`、
   `tool-workflow`、`app-boot`、`tool-fs*` 的首方定义）。
3. **估算 8–11 人日**（一人全职约两周，含真机验收窗口）。不含 0.2.3 的后续工作。
4. **三个开工前置条件**（缺一不可）：
   - 工作区有在飞改动：47 个已跟踪文件被改（`+3326/−935`），其中 `apps/android/lib/{attachments,pocket_composer,remote_goal_plan}.dart`
     今日 12:51 仍在修改 → 先提交或另起分支。
   - `android` 分支**没有推送任何远端**：`origin/android` 停在 2026-10-29，`github` 只有 `master`；
     本地只有 `sync/upstream-0.2.2-rc.1` 一张手动标签分支 → 先备份。
   - 生成物不要手解：`docs/config-catalog{,.zh}.md`、`pnpm-lock.yaml`、`slot-catalog.ts` 一律重生成。
5. **本次同步手机端渲染器基本不动**：`SESSION_FORMAT_VERSION` 仍为 4，已知事件仍是 64 个，
   payload 哈希在 rc.5 前无变化（新增 `workspace-root/change`、`action-cards/decision` 是
   0.2.3-alpha.1 的事）。

---

## 1. 基线与时点

| 项 | 值 |
| --- | --- |
| 本地同步点 | `493fb02c87`（fork）→ 上游 `fcc0ad4621`，`dsh-v0.2.2-rc.1`，2026-11-04 |
| 本地新增提交 | `493fb02c87..HEAD` 首个父链 112 个；`fcc0ad4621..android` 共 236 个（含重放的上游提交） |
| 上游候选 1 | `dsh-v0.2.2-rc.5` = `9c2670d3bc`，2026-11-18，距同步点 **776** 个提交 |
| 上游候选 2 | `dsh-v0.2.3-alpha.2` = `4b399c39a6`，2026-11-22，距同步点 **3124** 个提交 |
| 上游版本串 | `0.2.2-rc.1` → `rc.2`(11-11) → `rc.3`(11-13) → `rc.4`(11-17) → `rc.5`(11-18) → `0.2.3-alpha.1/.2`(11-22) |
| 0.2.2 是否有正式版 | 否。rc.5 是 0.2.2 线目前最新的 tag |

> **注意**：`docs/upgrade-guide/v<版本>/` 的目录名**不代表**改动落点。区间内该目录被大规模回填，
> 例如 `connection-page-peer`（连接鉴权）挂在 `v0.2.2-rc.2/`，但其提交 `71753fdf91` 实测在
> **rc.5 之后**。本计划所有"落在哪个版本"的判断都以 `git merge-base --is-ancestor` 实测为准。

---

## 2. 上游最近更新了什么（rc.1 → rc.5，776 提交）

类型分布：`fix` 180、`test` 111、`feat` 104、`docs` 55、`refactor` 54。主题是 Office 工具链重构、
账号体系统一、错误码体系化，加上桌面/Web 的功能增量。

### 2.1 与嵌入式 Android 宿主直接相关（必须处理）

| 改动 | 代表提交 | 对我们的影响 | 必须做什么 |
| --- | --- | --- | --- |
| Office 合并：`office-to-pdf` + engine-resolver → `office-kit`，新增 `tool-office` | `a220e017b5`、`50ba635949`、`edd38f1d66`、`78da437976` | 我们 patch 的 `office-to-pdf/{src/index.ts,src/subprocess.ts}` **整包消失** | 把 subprocess 转换 + `/system/fonts` 迁进 `office-kit`；命名空间 `officeToPdf`→`officeKit`；kit 0.2.0→0.2.3 |
| 账号统一：`deepseek-account-platform` → `deepseek-account`，删 `api/account-controller` | `d51d623bfc` | 我们的 `accountCallback` seam 挂在被删包上；`account-callback.mjs` 直接 import | 包迁移 + seam 重放（rc.5 仍用 `webServer.register`，改动很小） |
| 错误码体系化：fs / jobs / attachment / shell / llm | `4e4b4eb9b6`、`a0766d7573`、`7d6b1197dd`、`1b2cac01e4`、`eee5c94a41`、`0fe47c32ba` | 工具失败结构变成 `HarnessError` + code；`JOB_BACKGROUND_DISABLED` 删除、`IMAGE_UNSUPPORTED_MODEL`→`MODEL_DOES_NOT_SUPPORT_IMAGES` | 手机端工具卡片/错误分支对齐；`tool-fs*` 补丁与上游同区域 |
| Session 批量 append | `b5969f9e8d`、`b3d570cdf8`、`9d18b68095` | 序列分配时机变化，撞在我们的 jsonl publication 风险区 | jsonl 持久化包本版本只改 1 文件 5/2 行，补丁基本可留 |
| `plugin-manager` 支持从 Discover 更新 Git 安装插件 | `d2bed0238e` 等 6 个 | 与我们的 `protectModules` 同文件 | 直接重放，按上游结构调整 |
| DeepSeek 内容审查 + 拒答码改名 | `15762ffc03`、`f250e23202`、`e68c033493` | `MALFORMED_RESPONSE`→`CONTENT_REFUSED`；默认请求 safetyCheck | 手机端拒答 UI 判定串对齐；评估 Android 出网成本 |
| 预设表新增 `tool-office`、`skill-filesystem.customSkillDirs`、`tool-subagent-control.interrupt:false` | `packages/bundle/web-app/presets/standard.patch.yml` +7 行 | `stage-preset.mjs` 按固定 id 清单抄条目，不会自动带上；`!!js` 表达式引用了 `baseUrl` | 决定是否纳入 `tool-office`；验证 `!!js` 在 Android 组合能否求值；决定 `interrupt:false` |
| libreoffice-kit `0.2.0` → `0.2.3` | `ee06bf3f9b` | 我们固定在 0.2.0 | 跟随 0.2.3，并重跑 WASM 引擎 staging 校验 |

### 2.2 可以缓（不阻断，但不能长期悬空）

- **Session 事件与持久化**：rc.5 未改格式（见 §2.4）；SQLite 后端与 `workspace-root/change` 是 0.2.3 的事。
- **Client/Web 表面**：rc.5 内 `packages/client/connection` 只改了 `package.json`（6/3 行），
  我们的 `browser-auth` / `rotateBrowserCredentials` 补丁**本次不用重写**。
- **plugin-manager / Web UI 增量**：桌面向，Android 只用到服务面。
- **Forge / CUA**：与 Android 无关，同步时跟随但不需要验收。

### 2.3 明确跳过（不产生技术债）

CUA 全家（6 条 guide）、Forge 全家、`packages/connector/*`（0.2.3 才出现）、
个性化推荐/action card UI 细节、Python PTC 迁移。

### 2.4 数据面：本次不变

| 项 | 同步点 | rc.5 | 结论 |
| --- | --- | --- | --- |
| `SESSION_FORMAT_VERSION` | 4 | 4 | 不变 |
| `known-event-types` 事件数 | 64 | 64 | 不变（66 是 alpha.1） |
| `workspace-root/change` / `action-cards/decision` | 无 | 无 | 0.2.3 才加 |
| payload 哈希变化 | — | 无 | 0.2.3 才出现 5 处（`user/message` 等，均为 `MessageSource.kind` 增量） |

**意味**：本次同步不需要动 `chat_projection.dart` 的事件分支，也不需要重放录制会话快照来适配新事件。

---

## 3. 为什么建议停在 rc.5，而不是 0.2.3-alpha.2

| 维度 | rc.5 | 0.2.3-alpha.2 | 对我们的差别 |
| --- | --- | --- | --- |
| 上游提交 | 776 | 3124 | 4 倍 |
| 文本冲突（实测 `merge-tree`） | **28** | 41 | +13 处 |
| Node 下限 | `>=24.9`（不变） | `^24.22.3 \|\| >=26.13.1` | 内嵌 `libnode` 是 `24.22.0-0`（`tool/runtime-lock.json`），需换 nodejs-mobile 构建，**该版本是否存在未核实** |
| vendor cordis | 4.1.0（与同步点相同，仅 README 变动） | 4.2.0-alpha.1（家族 9 包同时跃迁） | 框架层整体 alpha 化 |
| `client/connection` | 仅 `package.json` | 鉴权整体重写（`71753fdf91`），`browser-auth.ts` 迁出到 `host/authentication-token` | 我们的 rotate 补丁从"零成本保留"变成"重写" |
| `session-persistence-jsonl` | 5/2 行 | +173/−57，新增 SQLite 后端 | publication 补丁从"保留"变成"重写" |
| Cordis Loader | 不变 | rc.9 + YAML 1.2 严格化 | `cordis.patch.yml` 的 `!!js` 可能加载失败 |
| 远程连接 | 不变 | 新增 `client/remote-connection`（QR + 浏览器配对） | 与我们自建配对职责重叠，需重新做归属决策 |

> 0.2.3-alpha.2 的合并试算里还有一类**静默破坏**：`packages/client/connection/src/rpc-host.ts`
> 不出冲突，合并结果却留下 `this.browserAuth.rotate()`，而上游已删除 `browserAuth` 字段与
> `browser-auth.ts` —— 只有 `tsc` 才能发现。这也说明**验收不能只看冲突数**。

---

## 4. 我们的现状（同步前必须确认）

### 4.1 git

- 远端：`origin` = gitee（`android` 停在 10-29）、`github` = fork（只有 `master`，停在 0.2.1-rc.2）。
- `android` 分支**未推送**；只有本地 `sync/upstream-0.2.2-rc.1`。
- 工作区脏：47 个已跟踪文件（`+3326/−935`）+ 若干未跟踪新文件
  （`device-interconnect/src/host/desktop-interactions.ts`、`desktop-session-window.ts` 等）。

### 4.2 补丁面

- fork 了 **117** 个上游既有文件（不含 `apps/android`、`apps/remote-host`、`device-interconnect`）。
- 其中 **101** 个上游也动过：88 个内容双改 + **13 个上游删除/迁走**（本次 rc.5 范围内是 **11** 个，
  对应 2 个包；`browser-auth.ts` 及其测试是 0.2.3 才迁走）。
- **4 个 fork 独有导出**（上游任何 tag 都不存在，必须每次重新落地）：
  `isFirstParty*Definition`（tool-fs / tool-fs-search / tool-web / tool-subagent-control）、
  `createWorkflowToolDefinition`、`establishAttachmentHome`、`applyWithPublication`；
  另有 `JsonRpcLineTransport.requestIdPrefix`、`pluginManager.protectModules`。

### 4.3 内嵌运行时装配（脆点排序）

1. `apps/android/runtime/cordis.patch.yml`：逐条引用约 35 个上游 entry id，改名/删除只会打印
   `patch: entry … not found` 后静默跳过。
2. `apps/android/tool/stage-preset.mjs`：从 `standard.patch.yml` 抄 18 个固定 id，每个必须"恰好 1 个"，
   否则生成器 throw。
3. `apps/android/runtime/host-guard.mjs`：`ANDROID_BUNDLES` 与 8 个 `dsh-app-boot` 内部导出。
4. `apps/android/runtime/package.json`：28 个 workspace 依赖，依赖闭包来自部署后的 CLI bundle manifest。
5. 29 个 `@deepseek-ai/dsh-*` 直接 import。

### 4.4 远程栈耦合点

手机 ↔ PC 是**自建 wss 行式 JSON-RPC**，复用上游 `JsonRpcLineTransport` 与 `typertGateway`；
真正耦合的是门面方法背后的上游服务：`sessionController.{projections,page,events,resolveAgent,cancel,updateQueue}`、
`sessionProjections.*`、`subagents.listDescendants`、`userQuestions`、`terminal` attach、`fileUploads.uploadStream`。

---

## 5. 冲突面：28 处

实测命令：`git merge-tree --write-tree --name-only android dsh-v0.2.2-rc.5`。

| 类别 | 数量 | 文件 | 处理方式 |
| --- | --- | --- | --- |
| 生成物 | 3 | `docs/config-catalog{,.zh}.md`、`pnpm-lock.yaml` | 取上游版本后重生成，不手解 |
| 包删除/迁移 | 14 | `deepseek-account-platform`×4、`deepseek-account/tests/account.spec.ts`、`office-kit`×4（add/add）、`office-to-pdf`×4、`experimental/README.i18n.yaml` | §6 P3 整体迁移 |
| 代码（同函数改写） | 6 | `core/tools/src/index.ts`、`fs/tool-fs/{read,write,edit}.ts`、`fs/tool-fs-search/{glob,grep}.ts` | §6 P4 逐文件小步重放 |
| 配置/版本 | 2 | `packages/bundle/web-app/package.json`（libreoffice-kit 0.2.0 vs **0.2.3**）、`tsconfig.base.json` | 取上游 0.2.3；补 fork 别名 |
| 策略白名单 | 3 | `scripts/{check-workspace-constraints,experimental-package-policy,translation-pairing}.ts` | 合并后再加回 fork 目录 |

**另需注意的非冲突风险**：`packages/boot/app-boot/src/index.ts`（fork 补丁在 `recompose`，上游改写了同一函数链，
无文本重叠但需重证等价）、`packages/core/agent/package.json` 存在**重复的 `dependencies` 键**
（L36 与 L67，上次同步遗留），本次先清理。

---

## 6. 执行计划

### P0 冻结与清理（0.5 人日）

- 提交或 stash 在飞改动；在 `android` 上打备份 tag（如 `pre-sync-0.2.2-rc.5`），
  **把 `android` 推到 `github`**（当前无任何远端备份，这是最大单点风险）。
- 清理非补丁残留：`.tmp/fork-*.ts`（6 个无引用快照）、`packages/core/agent/package.json` 重复
  `dependencies` 块、`packages/boot/plugin-manager/src/protection.ts`（无 importer，待确认）。
- 冻结 Build 121 基线产物（runtime sha256、APK hash、测试数），供回归对比。
- 从 `android` 切 `sync/upstream-0.2.2-rc.5` 作业分支。

**DoD**：`git status` 干净；备份 tag 已在远端；分支切好。

### P1 合并 rc.5（1 人日）

```powershell
git merge --no-commit dsh-v0.2.2-rc.5
# 生成物直接取上游：
git checkout --theirs docs/config-catalog.md docs/config-catalog.zh.md pnpm-lock.yaml
# 手工处理 14 处包迁移冲突，其余逐一 review
```

- 生成物重生成：`docs/config-catalog*`、`slot-catalog.ts`、`pnpm-lock.yaml`（删掉后按既有流程重装）。
- 包迁移冲突暂时保留 `ours` 版本，留给 P3 整体搬迁，避免在合并中做设计决策。

**DoD**：无冲突标记；`pnpm install` 可解；`pnpm run typecheck` 的失败项已归类（预期集中在 §5 的 6 个代码文件与 2 个迁移包）。

### P2 组合层修复（0.5–1 人日）

1. `cordis.patch.yml`：`office-to-pdf` → `office-kit`（补 `outputDirectory` 到 Android 可写目录）。
   实测 rc.5 的 bundle entry 变动只有 2 删 4 增：删 `account-controller`（我们未引用）、
   `office-to-pdf`（L42 需改）；增 `office-kit`、`skill-office`、`ui-account-notifications`、
   `workspace-dependencies`（后者 `disabled: !!js "profileContext?.name !== 'desktop' …"`，
   Android 下自动关闭，无需处理）。另确认 `deepseek-account` entry 的 id 未变、
   module 名变为 `@deepseek-ai/dsh-deepseek-account`。
   预检结论：`index.mjs` 的 `requiredEntries` 24 个 id 在 rc.5 全部可解析（其中 5 个是 fork 自有），
   本次唯一的 entry 重命名是 `office-to-pdf`→`office-kit`，它不在 `requiredEntries` 里。
2. `host-guard.mjs` / `index.mjs`：`ANDROID_BUNDLES`、`requiredEntries`、门面 `inject` 列表。
3. `stage-preset.mjs`：决定 `tool-office` 去留；验证 `customSkillDirs` 的 `!!js … baseUrl …` 在 Android
   组合能否求值（不能求值就必须在 overlay 里覆盖）；决定 `tool-subagent-control.interrupt:false`
   是否影响我们的 `subagents.interruptByParent` 入口。
4. `tsconfig.base.json` / `tsconfig.host.json` / `tsconfig.client.json`：删除指向已删包的 4 条别名，
   加回 `device-interconnect` 与 `apps/remote-host` 的引用；`pnpm-workspace.yaml` 的 kit 豁免改 0.2.3。
5. `scripts/*` 白名单加回 fork 目录；`gen-doc-graphs.ts` 的 `accountCallback` 条目随迁移改写或删除。

**DoD**：`dsh --profile android` 能起，`runtime.ready` 到达，Loader 日志无 `entry … not found`。

### P3 两个包迁移（2–3 人日）

**A. 账号（0.5–1 人日）**
- `packages/credentials/deepseek-account-platform` → `packages/credentials/deepseek-account`。
- rc.5 的替代包**仍用 `webServer.register('/oauth/callback')`**，所以 `AccountCallback` seam
  （`register(origin, route)` + `webServer` 缺失时走载体）可以**原样搬**过去，改动量很小。
- 连带：`apps/android/runtime/account-callback.mjs`（import 与基类）、`index.mjs`
  （`ctx.plugin`、`facadeDependencies`、`requiredEntries`、`ctx.accountCallback.signIn`）、
  `runtime/package.json`、`tsconfig.base.json`、`tool/parity-manifest.json`、`scripts/gen-doc-graphs.ts`。

**B. Office（1–1.5 人日）**
- 把 fork 的 `src/subprocess.ts`（子进程跑 kit CLI，释放 WASM 堆）与 Android `/system/fonts` 默认
  迁进 `packages/document/office-kit`；Config 新增必填 `outputDirectory`。
- 命名空间 `officeToPdf`→`officeKit`、`OfficeToPdfError`→`OfficeKitError`
  （`document-preview.mjs`、`index.mjs:789-798`、`document-preview-runtime.test.mjs`）。
- `libreoffice-kit` 0.2.0→**0.2.3**；重跑 `stage-office-runtime.mjs` / `office-runtime.test.mjs` /
  `pack-smoke` 的引擎资产断言（`pack-runtime.ps1:79,119-136`）。
- `tool/parity-manifest.json`、`preview/README*.md` 随包改名。

**DoD**：两个包的新路径下编译通过；`office-to-pdf` / `deepseek-account-platform` 在仓库内 grep 为 0。

### P4 补丁重放（1.5–2.5 人日）

按"上游是否已有等价能力"分三档（完整表见 §7）：

1. **必须重放（上游无等价）**：4 个 fork 导出、`applyWithPublication`/generation 的 `publishExclusive`、
   `requestIdPrefix`、`jobRegistry.snapshot()`、`pluginManager.protectModules`、
   `agents.withInitiator` 归属、`official-bundles` 的 `remote-host` profile。
2. **同上但同函数改写（需按上游新结构重写）**：`core/tools`（`registrationIdentity`/`begin`/`endExecution`
   + pipeline 的冻结定义）、`tool-workflow` 的 `createWorkflowToolDefinition`（4/4 hunk 重叠）、
   `app-boot` 的 loader 兜底（等价性需重证）。
3. **可退役**：`client-ui-cot-translation` 的 lint 行、`slot-catalog.ts`（重生成）、
   `docs/config-catalog*`（重生成）。

**DoD**：`pnpm run typecheck` 全绿；`requestIdPrefix` 的协议测试 22/22。

### P5 验证（1.5–2 人日）

见 §9。**关键**：冲突数为 0 ≠ 能跑，必须 `tsc` + 冒烟 + 真机。

### P6 真机验收与发布（1–2 人日）

- 真机：配对 → 会话首屏 → 流式 → 工具卡片（错误码）→ 审批 → 附件上行 → Office 预览 → 终端。
- 产出 Build 122：记录 runtime sha256、APK hash、`0.1.0+122`，更新 `README.md` 的 Build 段。

---

## 7. 补丁处置清单

| 补丁 | 文件 | 上游 rc.5 现状 | 处置 |
| --- | --- | --- | --- |
| 工具注册身份 + 活跃执行 | `core/tools/{index,pipeline}.ts` | 同区域改审批/取消/guard 错误信息 | 按新结构重放 |
| Agent 归属（owner/roots/isOwnedBy） | `core/agent/src/index.ts` | 无等价实现（仅文档描述） | 原样重放 |
| jsonl 发布钩子 | `session-persistence-jsonl/{index,generation}.ts` | 仅 5/2 行变动 | 直接保留，跑 publication 测试 |
| 连接鉴权轮换 | `client/connection/{rpc,rpc-host,browser-auth}.ts` | **本版本未改** | 原样保留（0.2.3 才需重写） |
| 账号回调载体 | `deepseek-account-platform` | 包已改名 | 随 P3-A 迁移 |
| Office 子进程转换 | `office-to-pdf` | 包已合并 | 随 P3-B 迁移进 office-kit |
| workflow 工具工厂 | `tool-workflow/src/index.ts` | 5 个提交改写同区域 | 优先重放，4/4 hunk 重叠 |
| 首方定义 attestation（8 个导出） | `tool-fs`×5、`tool-fs-search`×2、`tool-web`×2、`tool-subagent-control`×2 个文件 | 无等价，同区域加 `ToolArgsError`/`retirement` | 逐文件重放 |
| 附件发布 | `attachment-local/{store,index,file-store}.ts` | 无等价 | 原样保留 |
| 任务快照 | `jobs/{jobs,jobs-local}` + 5 个子类 | 无等价 | 保留并跑 jobs 套件 |
| 插件模块保护 | `boot/plugin-manager/src/index.ts` | 无等价 | 重放 |
| Loader include 兜底 | `boot/app-boot/src/index.ts` | 同函数改写 | 重写 + 重证等价 |
| 子代理父归属 | `subagent/src/index.ts` | 无等价 | 重放 |
| 请求 id 前缀 | `sdk/protocol/src/transport.ts` | **未改** | 原样保留 |
| remote-host profile | `util/official-bundles/src/bundles.ts` | 名单有小改 | 重放 |
| 构建/策略补丁 | `tsconfig.*`、`tsdown.config.ts`、`pnpm-workspace.yaml`、`scripts/*`、根 `package.json` | 多处改写 | P2 统一处理 |

---

## 8. 需要拍板的决策

| # | 决策 | 选项 | 推荐 |
| --- | --- | --- | --- |
| D1 | 同步目标 | rc.5 / 0.2.3-alpha.2 / 等 0.2.3-rc | **rc.5**（§3） |
| D2 | Office 能力取舍 | 完整迁移 / 只留 render+generation / 直接砍掉 | **只留 render+generation**：README 已记录 authoring 不完整，`tool-office` 的 convert/recalculate 在手机端没有入口 |
| D3 | `tool-office` 是否进 Android 预设 | 纳入 / 不纳入 | **不纳入**（P2 验证 `!!js` 后再定，先保持预设最小） |
| D4 | 账号是否一次跟到 `packages/account/` | 只跟 rc.5 的 `credentials/deepseek-account` / 直接跳 | **跟 rc.5 现状**：`packages/account` 迁移是 0.2.3 的事，现在跳会引入未验证的中间态 |
| D5 | 备份与推送 | 推 `android` 到 `github` / 只打 tag | **两条都做**：现在 112 个本地提交 + 工作区改动只存在于本机 |
| D6 | 同步窗口 | 现在 / 做完性能目标后 | 建议**现在**：性能是长期项，而补丁债每天在升值 |

---

## 9. 验证矩阵

```powershell
# 类型与单测（仓库根）
pnpm run typecheck
pnpm exec tsc -p apps/remote-host/tsconfig.json

# 宿主套件（apps/android/tool 下，README 记 1,235 项）
node --test apps/android/tool/*.test.mjs

# Flutter（README 记 1,517 项；基线仅 11 条 analyze 告警）
cd apps\android
& '..\..\.cache\flutter\bin\flutter.bat' analyze
& '..\..\.cache\flutter\bin\flutter.bat' test

# 宿主冒烟与自检（仓库根）
pnpm exec tsx apps/remote-host/scripts/smoke-remote-host.ts
node --import tsx/esm apps/remote-host/scripts/e2e-remote-host.ts --pair-url "<配对链接>" --send "请只回复两个字：收到"
# 以及 pairing-page / pairing-longterm / qr / discovery / public-origin / stream-lifecycle 六个 selfcheck

# 运行时与 APK
pnpm run build:artifacts
node node_modules/tsx/dist/cli.mjs apps/android/tool/stage-runtime.ts
node apps/android/tool/smoke-runtime.mjs
./apps/android/tool/pack-runtime.ps1
& '..\..\.cache\flutter\bin\flutter.bat' build apk --debug --target-platform android-arm64 --no-pub
./apps/android/tool/verify-apk.ps1 -ApkPath build/app/outputs/flutter-apk/app-debug.apk -ExpectedVersionName 0.1.0 -ExpectedVersionCode 122 -ExpectedRuntimeSha256 <新 hash>
node tool/verify-document-preview.mjs build/app/outputs/flutter-apk/app-debug.apk
```

**必须回归的活动面**（来自上次 0.2.2 同步的踩坑记录）：
启动看门狗（300 s 无进展才失败）、系统 picker 跨 `resumed` 的暂存副本、工作区根比较（noBackupFilesDir 符号链接）、
工具呈现的显式 profile 决定、Agent 归属取自运行期发起者、`session.readWindow` 的窗口语义、
`session.send` 写冲突回退的正则/错误码、桌面事件中继的批处理上界。

---

## 10. 0.2.3 的跟进条件

**触发条件**（满足再排期）：

1. `nodejs-mobile` 出现 ≥24.22.3 的 Android 构建（当前 `24.22.0-0`）——**待核实**；
2. vendor cordis 4.2.0 出稳定版（现在是 `4.2.0-alpha.1`）；
3. 0.2.3 进 rc，`SessionEventMap` 与 client 拆包定形。

**届时的额外工作**（估算 +4–6 人日）：连接鉴权整体重写（`browser-auth` → `connection.authentication`
provider + `authentication-token`，rotate 能力重建）、Cordis 4.0.0-rc.12 的 `ctx[Context.root]` 与
Loader rc.9 严格化、Client 拆包/改名与 `session-panel` 入口迁移、新增 2 个事件与 5 处 payload 增量、
`workspace-root/change` 与旧 `working-directory/change` 双兼容、SQLite 持久化的选边。

**同时值得评估**：上游 `packages/client/remote-connection`（QR 登录 + 浏览器配对请求）与我们自建配对的
归属关系 —— 上游给的是"浏览器 + owner 批准"模型，我们是"手机长连 + 长期配对码"，机制重叠但目标不同。

---

## 附录 A · 证据索引

| 事实 | 证据 |
| --- | --- |
| 同步点与规模 | `git rev-list --count fcc0ad4621..dsh-v0.2.2-rc.5` = 776；`..upstream/master` = 3124 |
| 冲突数 | `git merge-tree --write-tree --name-only android <ref>`：rc.5 = 28，alpha.2 = 41 |
| 包删除 | `a220e017b5`（office-kit）、`d51d623bfc`（account 统一） |
| 删除锚点清单 | `git diff --name-status fcc0ad4621..dsh-v0.2.2-rc.5` 的 `D` 行：11 个，属 2 个包 |
| 版本落点 | `git merge-base --is-ancestor <commit> dsh-v0.2.2-rc.5`（鉴权 `71753fdf91`、SQLite `a3c870e3e4`、cordis `1511a6ed44` 均在 rc.5 之后） |
| 数据面 | `packages/core/session/src/types.ts` 的 `SESSION_FORMAT_VERSION` 在 rc.5 = 4；`known-event-types` 64 → 66 发生在 alpha.1 |
| 内嵌 Node | `apps/android/tool/runtime-lock.json` `node.mobileVersion = 24.22.0-0` |
| 预设变化 | `git diff fcc0ad4621..dsh-v0.2.2-rc.5 -- packages/bundle/web-app/presets/standard.patch.yml`（+7 行） |
| kit 版本 | `packages/bundle/web-app/package.json`：同步点 `^0.1.5`、fork `0.2.0`、rc.5/master `0.2.3` |

---

## 11. 执行结果（2026-11-25）

**分支**：`sync/upstream-0.2.2-rc.5`（自 `android` @ `b345a64cff`，已打 tag `pre-sync-0.2.2-rc.5`
并落一份完整仓库 bundle 备份在 `.tmp/backup/android-pre-sync-rc5.bundle`）。

| 提交 | 内容 |
| --- | --- |
| `94d8ce2edb` | `merge: sync upstream dsh-v0.2.2-rc.5`：28 处冲突全部解析；两个被删包接受删除；生成物取上游版本 |
| `7ca677384c` | Office 迁移：`office-kit` 承载子进程转换与 `/system/fonts`，命名空间 `officeKit`，kit 0.2.3，禁用 `skill-office` |
| `ef45cfa063` | 账号迁移：`accountCallback` 载体接到 `deepseek-account`，凭据记录名不变 |
| `2c9e939616` | 生成物与台账：config/Cordis/subsystem/doc-graph 目录、lockfile、parity 台账（325 条声明） |
| `461562d933` | 4 个文件的行尾空行规范化 |
| `8d7d202f96` | 删除无引用的 `plugin-manager/src/protection.ts` |

### 与计划的差异

1. **补丁重放几乎为零**：12 项 fork 补丁在 rc.5 上全部原样存活（上游没有改到同一语义），
   只有 4 个文件的行尾规范化。计划里"按新结构重写"的 `tool-workflow` / `app-boot` / `list_agents`
   经复核**上游 rc.5 并未改动**，因此不需要重写。
2. **`accountCallback` 的实现形态微调**：fork 原补丁把"载体/WebServer 二选一"放在 `ctx.effect`
   回调里，末尾分支不可达，会打穿 per-file 100% 覆盖率；改为在 `run()` 顶部一次性选出注册器。
3. **`skill-office` 被禁用**（原计划只"不加入 preset"）：否则模型会看到描述不存在工具的技能。
4. **`protectModules` 保护模块的独立文件被删除**：实现早已在 manager 内部，文件无引用。

### 验证证据

| 检查 | 结果 |
| --- | --- |
| `pnpm run typecheck`（Host Typert / host compiler / client compiler / host aggregate / client aggregate） | **5/5 PASS**（136s） |
| `node apps/android/tool/parity-audit.mjs` | 325 条声明，exit 0 |
| `node --test parity-audit.test.mjs document-preview-runtime.test.mjs` | **49/49 PASS** |
| `node --test build-document-preview.test.mjs verify-document-preview.test.mjs` | **26/26 PASS**（先重建 preview 资源） |
| `packages/credentials/deepseek-account/tests`（vitest） | 287/287 PASS，`src/index.ts` 覆盖 100% |
| 补丁重放涉及 15 个包的 vitest 子集 | 全 PASS（`plugin-manager` 的两个真实 git 用例需放宽超时，环境相关） |
| `apps/android/preview/bridge.test.mjs` | 8/8 PASS |

### 未完成（下次开工从这里接）

1. **P6 真机验收与 Build 122 未做**：需要重跑 `build:artifacts` → `stage-runtime.ts` → `pack-runtime.ps1`
   → `flutter build apk`，再走 `verify-apk.ps1` 与 `verify-document-preview.mjs`。
2. **`office-runtime.test.mjs` 仍会失败**，因为它读旧的 `.cache/android/runtime-bundle`（还带 kit 0.2.0）；
   重新 stage 运行时后才有效。这是**缓存新鲜度**问题，不是源码问题。
3. **完整 136 个宿主测试文件的全量运行在本机 Windows 上会挂住**（两次尝试分别停在同一位置），
   未能取得全量结果；已改用聚焦子集。CI/本地按子集或分批判跑。
4. **文档漂移（既有，非本次引入）**：`tool-subagent-control/README.md:84` 的 attestation 描述
   与实现不符；`fs/tool-fs/README.md` 缺 read/write/edit 的 attestation 段落。
5. **`packages/api/session-controller/src/model-selection-projection.ts`** 仍无 TS 引用
   （App 侧 Dart 注释指它），属上次同步遗留，本次未动。
6. **分支尚未推送**：`sync/upstream-0.2.2-rc.5` 只在本地；合入 `android` 并推送前先跑一次
   `pnpm run doc-sync` 与子集回归。
