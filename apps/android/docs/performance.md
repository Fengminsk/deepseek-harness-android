# Android App 性能目标与验收：真机 60 fps

状态：目标已建立（2026-11-16），基线已测量，热点已定位，优化进行中。本文是真机帧率
目标的唯一入口：测量方法、当前基线、热点结论与后续计划都以这里为准。

目标：**连续交互场景在真机上稳定跑满 60 fps**——帧预算 16.67 ms（60 Hz），
逐帧 `totalSpan` p95 ≤ 16.67 ms、掉帧比例 ≤ 1%、滚动场景交互帧率 ≥ 55 fps。
验收必须来自真机 `FrameTiming` 采样，不接受只靠主机测试推断。

---

## 1. 测量方法（可复现）

测量入口与驱动都在仓库里，用 profile 构建 + 真机 adb 驱动：

```powershell
# 构建测量包（生产入口 + 帧统计，不影响 lib/main.dart）
$env:ANDROID_HOME = 'D:\Android\android-sdk'
$env:GRADLE_USER_HOME = '<repo>\.cache\gradle-user-home'
node apps/android/tool/device-frame-profile.mjs --build --install

# 只跑单个场景 / 指定预算
node apps/android/tool/device-frame-profile.mjs --skip-build --skip-install --scenario remote-session-stream
node apps/android/tool/device-frame-profile.mjs --skip-build --skip-install --budget-ms 16.667
```

- `apps/android/lib/main_perf.dart`：profile 测量入口，用 `SchedulerBinding.addTimingsCallback`
  每秒把 build/raster/totalSpan 的微秒数组写成一行 `DSH_FRAME {...}` 到 logcat；
  `--dart-define=DSH_PROFILE_WIDGETS=true` 时额外打开 widget 构建/布局事件（诊断用，有开销）。
- `apps/android/tool/device-frame-profile.mjs`：构建/安装/启动 App，用 adb 与 uiautomator
  驱动真实页面，采集 logcat 并按场景时间窗汇总；输出 JSON 到 `.cache/ui-perf-device/`。
- 场景：`remote-home`（首页滚动）、`remote-session-stream`（发消息 + 流式回复渲染）、
  `remote-terminal`（远程终端输出）、`remote-files`（电脑文件列表滚动）。
  连续滚动场景要求 fps；流式/终端按需出帧，只按帧耗时与掉帧比例判定。
- 设备：OnePlus6 / Android 11 / 1080×2280 / 面板 60 Hz；App 内 `refreshRate=60.0`
  （`DSH_FRAME_META` 可复核）。
- 设定项：`设置 → 外观与主题 → 液态玻璃` 的取值会显著影响栅格耗时，对比测量时必须记录。

诊断方法（定位「谁在拖慢帧」）：profile 包启动后从 logcat 拿 VM service 地址，
`adb forward` 后用 VM service 的 `Timeline` 流采集（B/E 事件配对 + 栈式归并算自耗时），
可配合 `DSH_PROFILE_WIDGETS=true` 看到 widget 构建/布局事件。

## 2. 基线（2026-11-16 01:0x，glass = 精细 / 默认）

> 热状态前提：`dumpsys thermalservice` 的 `Thermal Status` 必须 ≤ 1（none/light）；
> 2（moderate）以上表示设备正在降频，帧耗时整体抬高，测量结果不能用于验收。
> 驱动脚本会记录 `thermalBefore/thermalAfter`，`thermalBefore ≥ 2` 时直接判失败并提示先冷却。
>
> **本机实测补充（必须遵守）**：OnePlus6 的 `Thermal Status` 会粘滞在 3（厂商实现/充电状态），
> 即使电池 30°C 也不回 0/1，因此热状态不能单独作为依据。实际判据用**电池温度**：
> `dumpsys battery` 的 `temperature` ≤ 34°C（34.0）时为有效测量；≥ 35°C 时帧耗时整体翻倍
> （同一构建 home p95 17.4 → 50+ ms）。驱动脚本按场景记录电池温度，>34°C 时打印 WARN，
> 报告里也带上电池温度；冷却方式：熄屏 + 不跑构建/测试 15–25 分钟（USB 充电仍会缓慢加热，
> 30°C 左右是这台机器的最冷状态）。

| 场景 | frames | p50 total | p95 total | build p95 | raster p95 | 掉帧比例 | 结论 |
|---|---|---|---|---|---|---|---|
| remote-home | 674 | 14.31 ms | 17.26 ms | 3.02 ms | 7.82 ms | 9.2% | 未达标（栅格/合成） |
| remote-session-stream | 817 | 15.86 ms | 28.26 ms | 9.13 ms | 7.46 ms | 30.6% | 未达标（UI 线程构建） |
| remote-terminal | 1027 | 23.84 ms | 44.92 ms | 27.78 ms | 8.96 ms | 85.1% | 未达标（构建） |
| remote-files | 677 | 16.06 ms | 28.35 ms | 5.32 ms | 15.12 ms | 47.0% | 未达标（栅格 + 首帧着色） |

对照测量（同一设备/场景）：

| 条件 | remote-home | remote-files | remote-session-stream | 说明 |
|---|---|---|---|---|
| 液态玻璃 = 关闭 | p95 **9.61 ms**，0.9% | p95 21.86 ms，8.9% | p95 31.59 ms（build p95 21.6） | 首页达 60 fps；流式仍被构建拖住 |
| 液态玻璃 = 标准 | p95 17.84 ms，11.3% | p95 28.35 ms，47.0% | — | 「标准/精细」只改着色细节，不减少背景捕获开销 |
| B3/③ 后复测（`post-b3-perf.json`，**热状态 3**） | p95 26.37 ms，43.9% | p95 29.90 ms，31.1% | p95 39.00 ms，40.2%（build p95 10.46） | **降频中，不作为验收依据**：设备插 USB 充电 + 长时间亮屏，`Thermal Status: 3`（severe），CPU 59–61°C；需熄屏/断充冷却到 ≤1 后重测 |
| 多种连接方式后复测（`post-connections-perf.json`，thermalOverride，电池 35.9°C） | p95 16.97 ms，6.0%，activeFps 55.8 | p95 27.78 ms，27.4% | p95 49.32 ms，54.4%（build p95 22.68） | **仅参考**：熄屏冷却 24 min 后 CPU/电池温度已正常（39.8°C / 35.9°C），但该 ROM 的 `Thermal Status` 仍报 3（疑似厂商状态粘滞），用 `--allow-hot` 记录；home/files/terminal 与基线同量级（无新 UI 回归），session-stream p95 波动大（build 成本主导） |
| 后台通知批次「冷机重测」（2026-11-16 08:35–08:42，电池 33.4–33.8°C） | **p95 17.38 / 17.64 ms，jank 8.3% / 9.2%，activeFps 56.2 / 56.3**（连测两轮） | — | — | 长时间熄屏冷却后的 home 两轮与原始基线（17.26/9.2%）一致，**证明多种连接/通知两批 UI 没有回归**；home 仍未达 60 fps 门禁（jank >1%），瓶颈仍是液态玻璃背景捕获 |
| 同一批次热机重测（2026-11-16 08:42–08:55，电池 35.6–36.7°C） | p95 50.37–51.43 ms，100% | p95 29.98–31.5 ms | p95 61.66–96.08 ms（terminal build p95 42–46） | **无效数据**：电池 ≥35°C 后整机帧耗时约×2–3（Thermal Status 仍报 3），保留在 `post-notify-perf*.json` 仅作降频证据 |
| 后台通知批次（2026-11-16 04:2x 首次尝试） | — | — | — | 为拿 0/1 热状态重启设备后被 SIM PIN 锁屏（无跳过入口），自动化无法解锁；本批被测页面 UI 未变，通知只在系统通知栏 |

## 3. 热点结论

1. **液态玻璃的背景捕获是首页滚动的主要栅格成本**：关闭玻璃后首页 p95 从 17.26 → 9.61 ms、
   掉帧 9.2% → 0.9%；但「标准」与「精细」几乎一样贵，说明成本在背景捕获/离屏快照，
   不在着色器细节。帧采集里能看到每帧多次 `SnapshotDisplayList (impeller)` /
   `DoMakeRasterSnapshot`（约 2.5 ms/次 × 每帧 3 次）。
2. **流式回复与远程终端的瓶颈在 UI 线程构建**：关闭玻璃后 build p95 仍为 21–26 ms
   （流式）/ 45 ms（终端，含重建与首帧），与栅格无关。帧布局（`LAYOUT`）与绘制
   （`PAINT`）都很小，耗时集中在 widget 重建（`BUILD` 事件与 `Animator::BeginFrame`）。
   会话历史越长（长 markdown 消息越多）单次重建越贵。
3. **电脑文件列表**：关闭玻璃仍有 8.9% 掉帧（p95 21.86 ms，raster p95 16.29 ms），
   属于长列表滚动时的栅格/首帧着色成本，需要单独优化（行内容、图片/缩略图、字体图集）。
4. **发现的真实缺陷（已修）**：`RemoteGoalPlanController` 把 `session/control` 流结束
   当成「状态不可信」，在连接重建后弹「无法确认计划模式状态：会话同步已结束」始终可见；
   现在流结束按正常生命周期处理（保留最后一次投影 + 静默重订阅，连续结束 3 次才停）。

## 4. 优化计划（按收益排序）

1. **降低背景捕获开销（首页/文件页/会话页的玻璃背景）**：
   - 评估「静止时复用上一次背景截图、只在实际动画帧重新捕获」；
   - 评估滚动/流式期间降低捕获分辨率或帧率（视觉近似，需设计确认）；
   - 评估把模糊层与内容滚动解耦（仅对固定背景层做捕获）。
2. **缩短流式与终端的单次重建成本**：
   - 会话页长历史：把「已完成消息」的 markdown 解析/布局结果做缓存，使流式增量只重建
     活动消息（`PocketMarkdown` 的构建缓存 + `ChatTimeline` 的行级隔离）；
   - 终端：减少每帧重建范围（屏幕行与输入区解耦）、避免每帧重建整页；
   - 合并高频更新（同一帧内多次 `setState` 合并），减少无意义重建。
3. **文件列表滚动**：行级缓存 / 缩略图与字体预热，避免首帧栅格尖峰。
4. **门禁**：把场景脚本纳入常规验收（本机/真机），并在主机侧补 widget 级预算测试，
   防止流式渲染与列表滚动的重建成本回归。

## 5. 复跑与记录

- 每次优化后跑同一套场景并记录到本文件（或 `.cache/ui-perf-device/*.json` 的对比表）；
- 只有全部场景达到第 1 节判据才可宣称「60 fps 目标达成」；
- 涉及 UI 改动的优化同时跑 `flutter analyze` 与相关 widget 测试，避免以牺牲正确性换帧率。
