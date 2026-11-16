// 远程会话页的「会话洞察」数据：待办、会话统计、token 用量与上下文占用。
//
// 四个读数都来自宿主 `session.projections` 的 `values`（同一份快照里还有 plan /
// permissions 等键，各自的控制器在自己的文件里解析）。字段形状以宿主 wire 投影为
// 准：
//
// - `todos`：`TodoItem[] | null`（`packages/todo/tool-todo/src/index.ts` 的
//   `todos` 投影，whole-list replacement，`turn/start` 清空、`turn/end` 保留）；
// - `sessionStats`：`{turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs,
//   decodeTokens}`（`packages/session/session-stats/src/projection.ts`）；
// - `tokenUsage`：`{uncachedInputTokens, outputTokens, cacheReadTokens,
//   cacheWriteTokens}`（`packages/llm/token-meter/src/usage-projection.ts`；投影
//   只有这四个桶，没有单独的 reasoningTokens）；
// - `contextPressure`：`{pressureTokens?, projectedTokens?, contextWindow?}`（同文件
//   的 `contextPressure` 投影；三个字段互相独立，可能只有容量没有分子）。
//
// 解析原则：宿主没给、给 null、给坏类型都只让对应的那一项为 null（或跳过坏条目），
// 绝不抛异常、也不编默认值。读取失败由数据源承担，本文件只做纯解析与派生。
//
// 派生读数对齐 Web GUI 的同一套规则：
// - 缓存命中率 = `cacheReadTokens / billedInput`，`billedInput =
//   uncachedInputTokens + cacheReadTokens + cacheWriteTokens`
//   （`packages/client/ui-chat/src/client/chat/StatsPills.tsx`）；整数四舍五入会把
//   部分命中显示成 100% 时，用能够保持低于 100% 的最少小数位（同
//   `token-format.ts` 的 `formatCacheHitPercent`）。
// - 上下文占用 = `(projectedTokens ?? pressureTokens) / contextWindow`，四舍五入成
//   0–100 的整数；缺分子或容量时没有读数（同 `context-occupancy.ts`）。

library;

/// `todos` 投影在 `values` 里的键。
const String remoteInsightsTodosKey = 'todos';

/// `sessionStats` 投影在 `values` 里的键。
const String remoteInsightsSessionStatsKey = 'sessionStats';

/// `tokenUsage` 投影在 `values` 里的键。
const String remoteInsightsTokenUsageKey = 'tokenUsage';

/// `contextPressure` 投影在 `values` 里的键。
const String remoteInsightsContextPressureKey = 'contextPressure';

/// 会话洞察读取的投影键；数据源据此判断一次变更是否与洞察有关（刷新时机用）。
const Set<String> remoteSessionInsightsProjectionKeys = <String>{
  remoteInsightsTodosKey,
  remoteInsightsSessionStatsKey,
  remoteInsightsTokenUsageKey,
  remoteInsightsContextPressureKey,
};

/// 待办条目的状态；与宿主 `TodoItem.status` 的三个取值一一对应。
enum RemoteTodoStatus {
  /// 还没开始。
  pending,

  /// 正在做（并行工作时可能同时有多条）。
  inProgress,

  /// 已完成。
  completed,
}

/// 一条待办，字段与宿主 `TodoItem` 同名同义。
///
/// 顺序即宿主给出的顺序，页面据此渲染清单。
class RemoteTodoItem {
  /// 创建一条待办。
  const RemoteTodoItem({required this.content, required this.status});

  /// 待办内容（宿主已保证非空；这里保留原文，不裁剪）。
  final String content;

  /// 待办状态。
  final RemoteTodoStatus status;

  @override
  bool operator ==(Object other) =>
      other is RemoteTodoItem &&
      other.content == content &&
      other.status == status;

  @override
  int get hashCode => Object.hash(content, status);

  @override
  String toString() => 'RemoteTodoItem($content, ${status.name})';
}

/// 一次会话统计（`sessionStats` 投影的 view）。
///
/// `turns` / `steps` 是计数的权威读数；时间字段在宿主没有上报时为 0。
class RemoteSessionStats {
  /// 创建一份会话统计。
  const RemoteSessionStats({
    required this.turns,
    required this.steps,
    required this.llmMs,
    required this.toolMs,
    required this.ttftMs,
    required this.ttftSteps,
    required this.decodeMs,
    required this.decodeTokens,
  });

  /// 至少结束过一个 step 的轮次数。
  final int turns;

  /// 已结束的 step 数。
  final int steps;

  /// 模型墙钟时间总和（step 开始到助手消息落盘），毫秒。
  final int llmMs;

  /// 工具调用时间总和（call → result），毫秒。
  final int toolMs;

  /// 首 token 延迟总和，毫秒。
  final int ttftMs;

  /// 记录到首 token 的 step 数（[ttftMs] 的除数）。
  final int ttftSteps;

  /// 解码时间总和，毫秒。
  final int decodeMs;

  /// 解码时间覆盖的 step 的输出 token 总和。
  final int decodeTokens;

  /// 平均首 token 延迟；没有记录时为 null。
  double? get averageTtftMs => ttftSteps > 0 ? ttftMs / ttftSteps : null;

  /// 平均解码速度（token/秒）；没有可用的解码时间时为 null。
  double? get decodeTokensPerSecond =>
      decodeMs > 0 ? decodeTokens / (decodeMs / 1000) : null;

  @override
  bool operator ==(Object other) =>
      other is RemoteSessionStats &&
      other.turns == turns &&
      other.steps == steps &&
      other.llmMs == llmMs &&
      other.toolMs == toolMs &&
      other.ttftMs == ttftMs &&
      other.ttftSteps == ttftSteps &&
      other.decodeMs == decodeMs &&
      other.decodeTokens == decodeTokens;

  @override
  int get hashCode => Object.hash(
    turns,
    steps,
    llmMs,
    toolMs,
    ttftMs,
    ttftSteps,
    decodeMs,
    decodeTokens,
  );

  @override
  String toString() =>
      'RemoteSessionStats(turns: $turns, steps: $steps, '
      'llmMs: $llmMs, toolMs: $toolMs, decode: $decodeTokens/$decodeMs)';
}

/// 整个会话的 provider token 用量（`tokenUsage` 投影的 view）。
///
/// 四个桶互不重叠：`uncachedInputTokens` 是未命中缓存的输入，
/// `cacheReadTokens` / `cacheWriteTokens` 是缓存读写的输入，`outputTokens` 是输出。
class RemoteTokenUsage {
  /// 创建一份用量读数。
  const RemoteTokenUsage({
    required this.uncachedInputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.outputTokens,
  });

  /// 未命中缓存、按输入计费的 token。
  final int uncachedInputTokens;

  /// 命中缓存读取的输入 token。
  final int cacheReadTokens;

  /// 写入缓存的输入 token。
  final int cacheWriteTokens;

  /// 输出 token（工具调用的输出在会话日志里算作后续请求的输入）。
  final int outputTokens;

  /// 三个输入计费桶之和（缓存命中率的分母）。
  int get billedInputTokens =>
      uncachedInputTokens + cacheReadTokens + cacheWriteTokens;

  /// 输入与输出的计费总量。
  int get totalTokens => billedInputTokens + outputTokens;

  @override
  bool operator ==(Object other) =>
      other is RemoteTokenUsage &&
      other.uncachedInputTokens == uncachedInputTokens &&
      other.cacheReadTokens == cacheReadTokens &&
      other.cacheWriteTokens == cacheWriteTokens &&
      other.outputTokens == outputTokens;

  @override
  int get hashCode => Object.hash(
    uncachedInputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    outputTokens,
  );

  @override
  String toString() =>
      'RemoteTokenUsage(uncached: $uncachedInputTokens, '
      'cacheRead: $cacheReadTokens, cacheWrite: $cacheWriteTokens, '
      'output: $outputTokens)';
}

/// 上下文占用读数（`contextPressure` 投影的 view）。
///
/// 三个字段互相独立：`pressureTokens` 是最近一次请求的提示侧压力，
/// `projectedTokens` 是加上 surface 变化后的预测值（页面优先用它），
/// `contextWindow` 是模型容量。字段缺失表示宿主还没观测到。
class RemoteContextPressure {
  /// 创建一份上下文读数。
  const RemoteContextPressure({
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
  });

  /// 最近一次请求的提示侧 token（输入 + 缓存读写，不含输出）。
  final int? pressureTokens;

  /// 预测的下一次请求提示侧 token；没有 pressureTokens 时为 null。
  final int? projectedTokens;

  /// 模型上下文容量；宿主没有上报时为 null。
  final int? contextWindow;

  /// 页面优先展示的已用量：预测值优先，其次最近一次观测值。
  int? get usedTokens => projectedTokens ?? pressureTokens;

  @override
  bool operator ==(Object other) =>
      other is RemoteContextPressure &&
      other.pressureTokens == pressureTokens &&
      other.projectedTokens == projectedTokens &&
      other.contextWindow == contextWindow;

  @override
  int get hashCode =>
      Object.hash(pressureTokens, projectedTokens, contextWindow);

  @override
  String toString() =>
      'RemoteContextPressure(pressure: $pressureTokens, '
      'projected: $projectedTokens, window: $contextWindow)';
}

/// 远程会话页的一组洞察读数。
///
/// 四个字段都可以为 null：宿主没有注册对应投影（旧宿主/其他组合）、这次读取没
/// 拿到值、或值形状不认识时为 null，页面据此不显示对应读数，而不是显示 0。
class RemoteSessionInsights {
  /// 创建一组洞察读数；没有读数的项传 null。
  const RemoteSessionInsights({
    this.todos,
    this.stats,
    this.usage,
    this.pressure,
  });

  /// 没有任何读数的空快照。
  static const RemoteSessionInsights none = RemoteSessionInsights();

  /// 从 `session.projections` 的 `values` 解析一组读数。
  ///
  /// [values] 是宿主返回的 `values` 对象。任何缺失、null 或坏类型都只让对应的那一
  /// 项为 null；坏待办条目逐条跳过。本方法不抛异常。
  factory RemoteSessionInsights.fromProjectionValues(Object? values) {
    if (values is! Map) return none;
    return RemoteSessionInsights(
      todos: _todosOf(values[remoteInsightsTodosKey]),
      stats: _statsOf(values[remoteInsightsSessionStatsKey]),
      usage: _usageOf(values[remoteInsightsTokenUsageKey]),
      pressure: _pressureOf(values[remoteInsightsContextPressureKey]),
    );
  }

  /// 当前待办列表：null 表示这个会话没有待办记录（投影为 null / 缺失 / 坏类型），
  /// 空列表表示记录存在但已清空。
  final List<RemoteTodoItem>? todos;

  /// 会话统计；投影缺失或形状不认识时为 null。
  final RemoteSessionStats? stats;

  /// token 用量；投影缺失或形状不认识时为 null。
  final RemoteTokenUsage? usage;

  /// 上下文占用；投影缺失或一个有用字段都没有时为 null。
  final RemoteContextPressure? pressure;

  /// 是否有任何可展示的读数。
  bool get hasAny =>
      todos != null || stats != null || usage != null || pressure != null;

  /// 是否所有读数都为空（页面据此整块隐藏）。
  bool get isEmpty => !hasAny;

  /// 缓存命中率（0–1，`cacheReadTokens / billedInput`）；没有输入 token 时为 null。
  double? get cacheHitRatio {
    final usage = this.usage;
    if (usage == null) return null;
    final billed = usage.billedInputTokens;
    if (billed <= 0) return null;
    return usage.cacheReadTokens / billed;
  }

  /// 展示用的缓存命中率文本（不带 `%`）；没有输入 token 时为 null。
  ///
  /// 规则与 Web GUI 一致：整数百分比；如果四舍五入会把部分命中显示成 100%，
  /// 就提高到能保持低于 100% 的最少小数位（例如 `99.95`）。全部命中返回 `100`。
  String? get cacheHitPercent {
    final usage = this.usage;
    if (usage == null) return null;
    final billed = usage.billedInputTokens;
    if (billed <= 0) return null;
    final cached = usage.cacheReadTokens;
    if (cached <= 0) return '0';
    if (cached >= billed) return '100';
    final bigCached = BigInt.from(cached);
    final bigBilled = BigInt.from(billed);
    final integer = _roundedPercentUnits(bigCached, bigBilled, 0);
    if (integer < BigInt.from(100)) return integer.toString();
    // 整数四舍五入会把部分命中显示成 100%；提高精度直到读数仍低于 100%。
    for (var places = 1; places <= _maxCacheHitDecimals; places++) {
      final units = _roundedPercentUnits(bigCached, bigBilled, places);
      final full = BigInt.from(100) * BigInt.from(10).pow(places);
      if (units >= full) continue;
      return _formatPercentUnits(units, places);
    }
    // 比值与 100% 的距离超过 12 位小数（不现实的 token 规模）：保持低于 100%。
    return '99.${'9' * _maxCacheHitDecimals}';
  }

  /// 上下文占用百分比（0–100 的整数）；缺已用量或容量时为 null。
  int? get contextPercent {
    final pressure = this.pressure;
    final used = pressure?.usedTokens;
    final window = pressure?.contextWindow;
    if (used == null || window == null || window <= 0) return null;
    final percent = (used * 200 + window) ~/ (window * 2);
    return percent.clamp(0, 100);
  }

  /// 缓存命中百分比最多保留的小数位；再长的精度对展示没有意义。
  static const int _maxCacheHitDecimals = 12;

  /// 四舍五入到 `places` 位小数的百分比整数单位（1 位小数 = 10 单位）。
  ///
  /// [cached] / [billed] 的比值乘 100 再乘 `10^places`，正数半进位；用 BigInt
  /// 避免大 token 数在乘除中溢出或丢精度。
  static BigInt _roundedPercentUnits(
    BigInt cached,
    BigInt billed,
    int places,
  ) {
    final scale = BigInt.from(100) * BigInt.from(10).pow(places);
    return (cached * scale * BigInt.two + billed) ~/ (billed * BigInt.two);
  }

  /// 把按 `places` 位小数放大的百分比整数单位格式化成文本。
  static String _formatPercentUnits(BigInt units, int places) {
    final scale = BigInt.from(10).pow(places);
    final whole = units ~/ scale;
    final fraction = (units % scale).toString().padLeft(places, '0');
    final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.isEmpty ? whole.toString() : '$whole.$trimmed';
  }

  /// 解析 `todos` 投影：null / 缺失 / 不是数组 → null；坏条目逐条跳过。
  static List<RemoteTodoItem>? _todosOf(Object? raw) {
    if (raw is! List) return null;
    final items = <RemoteTodoItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final content = entry['content'];
      if (content is! String || content.trim().isEmpty) continue;
      final status = switch (entry['status']) {
        'pending' => RemoteTodoStatus.pending,
        'in_progress' => RemoteTodoStatus.inProgress,
        'completed' => RemoteTodoStatus.completed,
        _ => null,
      };
      if (status == null) continue;
      items.add(RemoteTodoItem(content: content, status: status));
    }
    return List<RemoteTodoItem>.unmodifiable(items);
  }

  /// 解析 `sessionStats` 投影：八个计数都必须是非负整数，否则整项为 null。
  static RemoteSessionStats? _statsOf(Object? raw) {
    if (raw is! Map) return null;
    final turns = _nonNegativeInt(raw['turns']);
    final steps = _nonNegativeInt(raw['steps']);
    if (turns == null || steps == null) return null;
    return RemoteSessionStats(
      turns: turns,
      steps: steps,
      llmMs: _nonNegativeInt(raw['llmMs']) ?? 0,
      toolMs: _nonNegativeInt(raw['toolMs']) ?? 0,
      ttftMs: _nonNegativeInt(raw['ttftMs']) ?? 0,
      ttftSteps: _nonNegativeInt(raw['ttftSteps']) ?? 0,
      decodeMs: _nonNegativeInt(raw['decodeMs']) ?? 0,
      decodeTokens: _nonNegativeInt(raw['decodeTokens']) ?? 0,
    );
  }

  /// 解析 `tokenUsage` 投影：四个桶都必须是非负整数，否则整项为 null
  /// （缺一个桶就报出错误的缓存命中率，不如不显示）。
  static RemoteTokenUsage? _usageOf(Object? raw) {
    if (raw is! Map) return null;
    final uncached = _nonNegativeInt(raw['uncachedInputTokens']);
    final output = _nonNegativeInt(raw['outputTokens']);
    final cacheRead = _nonNegativeInt(raw['cacheReadTokens']);
    final cacheWrite = _nonNegativeInt(raw['cacheWriteTokens']);
    if (uncached == null ||
        output == null ||
        cacheRead == null ||
        cacheWrite == null) {
      return null;
    }
    return RemoteTokenUsage(
      uncachedInputTokens: uncached,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      outputTokens: output,
    );
  }

  /// 解析 `contextPressure` 投影：三个字段各自可选，全是坏值时为 null。
  static RemoteContextPressure? _pressureOf(Object? raw) {
    if (raw is! Map) return null;
    final pressure = _nonNegativeInt(raw['pressureTokens']);
    final projected = _nonNegativeInt(raw['projectedTokens']);
    final window = _positiveInt(raw['contextWindow']);
    if (pressure == null && projected == null && window == null) return null;
    return RemoteContextPressure(
      pressureTokens: pressure,
      projectedTokens: projected,
      contextWindow: window,
    );
  }

  /// 非负整数；其它类型（含负数、小数、NaN）为 null。
  static int? _nonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;

  /// 正整数；其它类型（含 0、负数）为 null。
  static int? _positiveInt(Object? value) =>
      value is int && value > 0 ? value : null;

  @override
  bool operator ==(Object other) =>
      other is RemoteSessionInsights &&
      _sameTodos(other.todos, todos) &&
      other.stats == stats &&
      other.usage == usage &&
      other.pressure == pressure;

  @override
  int get hashCode => Object.hash(
    todos == null ? null : Object.hashAll(todos!),
    stats,
    usage,
    pressure,
  );

  @override
  String toString() =>
      'RemoteSessionInsights(todos: ${todos?.length ?? 'none'}, '
      'stats: $stats, usage: $usage, pressure: $pressure)';

  /// 两个待办列表是否逐项相等（null 与空列表不相等：前者表示没有记录）。
  static bool _sameTodos(
    List<RemoteTodoItem>? left,
    List<RemoteTodoItem>? right,
  ) {
    if (identical(left, right)) return true;
    if (left == null || right == null) return false;
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
