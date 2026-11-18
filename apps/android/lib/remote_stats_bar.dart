// 远程会话页的底部统计条与它的详情弹层。
//
// 统计条是一行紧凑读数，分三段：轮/步、缓存命中、上下文占用。
// 每一段只在宿主真的给出对应读数时出现：缓存命中率没有计费输入 token 时整段不写，
// 上下文缺已用量或容量时不写百分比，会话统计 0 轮 0 步时也不写——不拿 0 当读数。
//
// 手机宽度先缩短分段文案；仍放不下时只保留最关键的一项读数。
// 左右滑动可以把长胶囊收纳到对应边缘，成为只显示上下文的圆球。
//
// 读数由页面给，组件没有订阅或定时器。详情弹层复用 App 现有底部弹层。

import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'remote_dsh_widgets.dart';
import 'remote_session_insights.dart';
import 'ui.dart';

/// 行首与展开提示图标的尺寸。
const double _statsGlyph = 14;

/// 行首图标与读数之间的间距。
const double _statsGap = 6;

/// 读数之后的展开提示图标间距。
const double _statsTrailingGap = 4;

/// 分段之间的「·」两侧留白。
const double _statsSeparator = 7;

/// 统计行左右内边距。
const double _statsLineInset = 8;

/// 一行读数的测量余量：字形宽度相加与 Row 排版的取整误差。
const double _statsFitMargin = 4;

/// 展开胶囊与收纳圆球共用高度。
const double _statsDockHeight = 40;

/// 长胶囊相对输入框两侧各退让的宽度。
const double _statsSideInset = 8;

/// 远程会话的底部统计条：一行紧凑读数，点按打开详情弹层。
class RemoteStatsBar extends StatefulWidget {
  /// 创建统计条。
  const RemoteStatsBar({
    super.key,
    required this.insights,
    this.onTap,
    this.expanded = true,
    this.onExpandedChanged,
  });

  /// 当前会话洞察读数；没有可展示的读数时整条不渲染。
  final RemoteSessionInsights insights;

  /// 点按回调（打开详情弹层）；null 时只展示不可点。
  final VoidCallback? onTap;

  /// 当前是否展开成长胶囊；false 时显示为收纳圆球。
  final bool expanded;

  /// 展开/收起变化回调；页面据此按设备+会话持久化偏好。
  final ValueChanged<bool>? onExpandedChanged;

  /// 统计条根节点的测试与无障碍标识。
  static const Key barKey = ValueKey('remote-stats-bar');

  /// 一行读数（宽屏）的测试标识。
  static const Key lineKey = ValueKey('remote-stats-line');

  /// 折叠胶囊（窄屏）的测试标识。
  static const Key capsuleKey = ValueKey('remote-stats-capsule');

  /// 这组读数是否会渲染统计条：至少有一个可展示的分段。
  ///
  /// 页面用它决定要不要为详情弹层提供入口；只有待办读数的会话不会渲染统计条，
  /// 也就不应打开一个没有任何统计小节的弹层。
  static bool hasReadings(RemoteSessionInsights insights) =>
      _RemoteStatsBarState._segmentsOf(insights).isNotEmpty;

  @override
  State<RemoteStatsBar> createState() => _RemoteStatsBarState();
}

enum _DockSide { expanded, left, right }

class _RemoteStatsBarState extends State<RemoteStatsBar> {
  late _DockSide _side = widget.expanded ? _DockSide.expanded : _DockSide.left;
  double _dragDistance = 0;

  @override
  void didUpdateWidget(RemoteStatsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    _side = widget.expanded ? _DockSide.expanded : _DockSide.left;
  }

  /// 切换到紧凑圆球并上报；重复收起不重复写偏好。
  void _collapse(_DockSide side) {
    if (_side == side) return;
    setState(() => _side = side);
    if (side != _DockSide.expanded) widget.onExpandedChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsOf(widget.insights);
    if (segments.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final style = AppTextStyle.caption1
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final contextPercent = widget.insights.contextPercent;
    return Semantics(
      key: RemoteStatsBar.barKey,
      button: true,
      label: _side == _DockSide.expanded
          ? '会话统计：${segments.join(' · ')}；左右滑动收纳，点按查看详情'
          : '上下文${contextPercent == null ? '暂无读数' : '$contextPercent%'}；点按展开会话统计',
      onTap: _side == _DockSide.expanded
          ? widget.onTap
          : () => setState(() => _side = _DockSide.expanded),
      child: ExcludeSemantics(
        child: GestureDetector(
          onHorizontalDragStart: (_) => _dragDistance = 0,
          onHorizontalDragUpdate: (details) =>
              _dragDistance += details.primaryDelta ?? 0,
          onHorizontalDragEnd: (details) {
            final movement = _dragDistance.abs() >= 44
                ? _dragDistance
                : (details.primaryVelocity ?? 0).abs() >= 300
                ? details.primaryVelocity!
                : 0;
            if (movement == 0) return;
            _collapse(movement < 0 ? _DockSide.left : _DockSide.right);
          },
          child: LayoutBuilder(
            builder: (context, constraints) => AnimatedAlign(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              curve: Curves.easeInOutCubic,
              alignment: switch (_side) {
                _DockSide.expanded => Alignment.center,
                _DockSide.left => Alignment.centerLeft,
                _DockSide.right => Alignment.centerRight,
              },
              child: AnimatedSize(
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: Curves.easeInOutCubic,
                child: _side == _DockSide.expanded
                    ? _expanded(context, constraints.maxWidth, segments, style)
                    : _ball(context, contextPercent, style),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _expanded(
    BuildContext context,
    double available,
    List<String> segments,
    TextStyle style,
  ) {
    final width = (available - _statsSideInset * 2)
        .clamp(0.0, 480.0)
        .toDouble();
    final fits =
        _lineWidth(context, segments, style) +
            _statsLineInset * 2 +
            _statsFitMargin <=
        width;
    final shortSegments = fits ? segments : _shortSegmentsOf(widget.insights);
    final shortFits =
        _lineWidth(context, shortSegments, style) +
            _statsLineInset * 2 +
            _statsFitMargin <=
        width;
    return SizedBox(
      width: width,
      height: _statsDockHeight,
      child: GlassSurface(
        radius: AppCorner.full,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: AppShape.full,
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _statsLineInset),
              child: Center(
                child: shortFits
                    ? _line(shortSegments, style)
                    : _capsule(context, segments, style),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ball(BuildContext context, int? percent, TextStyle style) =>
      SizedBox.square(
        dimension: _statsDockHeight,
        child: GlassSurface(
          key: const ValueKey('remote-stats-ball'),
          radius: AppCorner.full,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: AppShape.full,
              onTap: () {
                setState(() => _side = _DockSide.expanded);
                widget.onExpandedChanged?.call(true);
              },
              child: Center(
                child: Text(
                  percent == null ? '—' : '$percent%',
                  style: style.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// 一行读数：图标、三个分段、展开提示。
  Widget _line(List<String> segments, TextStyle style) {
    final color = style.color;
    return Row(
      key: RemoteStatsBar.lineKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.query_stats_rounded, size: _statsGlyph, color: color),
        const SizedBox(width: _statsGap),
        for (var index = 0; index < segments.length; index++) ...[
          if (index > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _statsSeparator),
              child: Text('·', style: style),
            ),
          Text(segments[index], maxLines: 1, style: style),
        ],
        const SizedBox(width: _statsTrailingGap),
        Icon(Icons.unfold_more_rounded, size: _statsGlyph, color: color),
      ],
    );
  }

  /// 放不下一行时的折叠胶囊：一项关键读数，点按仍打开详情。
  Widget _capsule(
    BuildContext context,
    List<String> segments,
    TextStyle style,
  ) {
    final colors = Theme.of(context).colorScheme;
    final reading = _capsuleReadingOf(widget.insights) ?? segments.first;
    return Padding(
      key: RemoteStatsBar.capsuleKey,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.query_stats_rounded,
            size: _statsGlyph,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: _statsGap),
          Flexible(
            child: Text(
              reading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: _statsTrailingGap),
          Icon(
            Icons.unfold_more_rounded,
            size: _statsGlyph,
            color: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  /// 统计条当前可展示的分段；空列表表示整条隐藏。
  static List<String> _segmentsOf(RemoteSessionInsights insights) {
    final segments = <String>[];
    final stats = insights.stats;
    if (stats != null && (stats.turns > 0 || stats.steps > 0)) {
      segments.add('轮 ${stats.turns} · 步 ${stats.steps}');
    }
    final usage = insights.usage;
    if (usage != null && usage.totalTokens > 0) {
      final cacheHit = insights.cacheHitPercent;
      segments.add(
        cacheHit == null
            ? '${_formatCompactTokens(usage.totalTokens)} tok'
            : '缓存命中 $cacheHit%',
      );
    }
    final contextPercent = insights.contextPercent;
    if (contextPercent != null) {
      segments.add('上下文 $contextPercent%');
    }
    return segments;
  }

  /// 普通手机屏幕用更短的标签完整保留步数、缓存与上下文三项。
  static List<String> _shortSegmentsOf(RemoteSessionInsights insights) {
    final segments = <String>[];
    final stats = insights.stats;
    if (stats != null && (stats.turns > 0 || stats.steps > 0)) {
      segments.add('步 ${stats.steps}');
    }
    final usage = insights.usage;
    if (usage != null && usage.totalTokens > 0) {
      final cacheHit = insights.cacheHitPercent;
      segments.add(
        cacheHit == null
            ? '${_formatCompactTokens(usage.totalTokens)} tok'
            : '缓存 $cacheHit%',
      );
    }
    final contextPercent = insights.contextPercent;
    if (contextPercent != null) segments.add('上下文 $contextPercent%');
    return segments;
  }

  /// 折叠胶囊里保留的那一项读数。
  static String? _capsuleReadingOf(RemoteSessionInsights insights) {
    final contextPercent = insights.contextPercent;
    if (contextPercent != null) return '上下文 $contextPercent%';
    final cacheHit = insights.cacheHitPercent;
    if (cacheHit != null) return '缓存命中 $cacheHit%';
    final usage = insights.usage;
    if (usage != null && usage.totalTokens > 0) {
      return '${_formatCompactTokens(usage.totalTokens)} tok';
    }
    final stats = insights.stats;
    if (stats != null && (stats.turns > 0 || stats.steps > 0)) {
      return '轮 ${stats.turns} · 步 ${stats.steps}';
    }
    return null;
  }

  /// 一行读数的排版宽度（图标、分段、分隔符与展开提示之和）。
  static double _lineWidth(
    BuildContext context,
    List<String> segments,
    TextStyle style,
  ) {
    var width = _statsGlyph + _statsGap;
    for (var index = 0; index < segments.length; index++) {
      if (index > 0) {
        width += _statsSeparator * 2 + _singleLineWidth(context, '·', style);
      }
      width += _singleLineWidth(context, segments[index], style);
    }
    return width + _statsTrailingGap + _statsGlyph;
  }
}

/// 打开会话统计详情弹层。
///
/// 与模型选择、权限预设使用同一套模态外壳：透明背景的 `showModalBottomSheet`、
/// 减少动态效果时不做入场动画，内容自己在玻璃面里滚动。
Future<void> showRemoteStatsSheet(
  BuildContext context, {
  required RemoteSessionInsights insights,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (_) => _RemoteStatsSheet(insights: insights),
);

/// 统计详情弹层：玻璃顶角、把手、居中标题与关闭按钮。
class _RemoteStatsSheet extends StatelessWidget {
  const _RemoteStatsSheet({required this.insights});

  /// 打开这一层时的读数；弹层不订阅后续更新，按打开时的快照展示。
  final RemoteSessionInsights insights;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('remote-stats-sheet'),
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      child: RemoteSheet(
        title: '会话统计',
        closeLabel: '关闭会话统计',
        children: [
          _StatsSummary(insights: insights),
          ..._sections(context),
        ],
      ),
    );
  }

  /// 详情内容：会话统计、token 四桶、上下文占用；缺哪项就不出哪一节。
  List<Widget> _sections(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final stats = insights.stats;
    final usage = insights.usage;
    final pressure = insights.pressure;
    final sections = <Widget>[];

    if (stats != null) {
      final ttft = stats.averageTtftMs;
      final speed = stats.decodeTokensPerSecond;
      sections.add(
        PocketSection(
          title: '进度与用时',
          divided: true,
          children: [
            _DetailRow(label: '轮次', value: '${stats.turns}'),
            _DetailRow(label: '步数', value: '${stats.steps}'),
            if (stats.llmMs > 0)
              _DetailRow(label: '模型用时', value: _formatDuration(stats.llmMs)),
            if (stats.toolMs > 0)
              _DetailRow(label: '工具调用用时', value: _formatDuration(stats.toolMs)),
            if (ttft != null)
              _DetailRow(
                label: '首 token 平均（TTFT）',
                value: _formatDuration(ttft.round()),
              ),
            if (speed != null)
              _DetailRow(
                label: '输出速度（TPS）',
                value: '${_formatSpeed(speed)} tok/s',
              ),
          ],
        ),
      );
    }

    if (usage != null) {
      final cacheHit = insights.cacheHitPercent;
      sections.add(
        PocketSection(
          title: 'Token 用量',
          divided: true,
          children: [
            if (cacheHit != null)
              _DetailRow(label: '缓存命中', value: '$cacheHit%'),
            _DetailRow(
              label: '未缓存输入',
              value: '${_formatExactTokens(usage.uncachedInputTokens)} tok',
            ),
            _DetailRow(
              label: '缓存读取',
              value: '${_formatExactTokens(usage.cacheReadTokens)} tok',
            ),
            _DetailRow(
              label: '缓存写入',
              value: '${_formatExactTokens(usage.cacheWriteTokens)} tok',
            ),
            _DetailRow(
              label: '输出',
              value: '${_formatExactTokens(usage.outputTokens)} tok',
            ),
            _DetailRow(
              label: '合计',
              value: '${_formatExactTokens(usage.totalTokens)} tok',
              emphasized: true,
            ),
          ],
        ),
      );
    }

    if (pressure != null) {
      final used = pressure.usedTokens;
      final contextPercent = insights.contextPercent;
      sections.add(
        PocketSection(
          title: '上下文',
          divided: true,
          children: [
            if (used != null)
              _DetailRow(
                label: pressure.projectedTokens != null ? '预测下次提示' : '最近一次提示',
                value: '${_formatExactTokens(used)} tok',
              ),
            if (pressure.contextWindow != null)
              _DetailRow(
                label: '模型容量',
                value: '${_formatExactTokens(pressure.contextWindow!)} tok',
              ),
            if (contextPercent != null)
              _DetailRow(
                label: '占用',
                value: '$contextPercent%',
                emphasized: true,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
              child: Text(
                '按提示侧 token（输入与缓存读写，不含输出）相对当前模型容量估算。',
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    return sections;
  }
}

/// A quick reading before the detailed, grouped iOS-style rows.
class _StatsSummary extends StatelessWidget {
  const _StatsSummary({required this.insights});

  final RemoteSessionInsights insights;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final percent = insights.contextPercent;
    final hit = insights.cacheHitPercent;
    final steps = insights.stats?.steps;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: AppRadius.xl,
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '会话概览',
                style: AppTextStyle.footnote
                    .of(context, emphasized: true)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (steps != null)
                    _SummaryReading(label: '执行步骤', value: '$steps 步'),
                  if (hit != null)
                    _SummaryReading(label: '缓存', value: '$hit% 命中'),
                  if (percent != null)
                    _SummaryReading(label: '上下文占用', value: '$percent% 已用'),
                ],
              ),
              if (percent != null) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: AppRadius.full,
                  child: LinearProgressIndicator(
                    value: (percent / 100).clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: colors.outlineVariant.withValues(
                      alpha: .45,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryReading extends StatelessWidget {
  const _SummaryReading({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppTextStyle.title3.of(context, emphasized: true)),
        const SizedBox(height: 3),
        Text(
          label,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

/// 详情里的一行「名称 — 数值」。
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;

  /// 关键读数用强调字重，避免与明细行混在一起。
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: AppTextStyle.subheadline.of(
                context,
                emphasized: emphasized,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单行文本的排版宽度（当前字号与字体缩放下）。
double _singleLineWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// 紧凑 token 数：1000 以下原样，1000–999999 用 K，再大用 M；与 Web 同规则。
String _formatCompactTokens(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return '${_compactScaled(value / 1000)}K';
  return '${_compactScaled(value / 1000000)}M';
}

String _compactScaled(double value) {
  if (value >= 100) return '${value.round()}';
  return _trimmedOneDecimal(value);
}

/// 一位小数，但整数不留 `.0`（与 Web 的读数格式一致）。
String _trimmedOneDecimal(double value) {
  final scaled = (value * 10).round() / 10;
  return scaled == scaled.roundToDouble()
      ? '${scaled.round()}'
      : scaled.toStringAsFixed(1);
}

/// 精确 token 数：三位一逗号（与 Web 的精确读数一致）。
String _formatExactTokens(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

/// 紧凑时长：一分钟内保留一位小数秒（整数秒不带 `.0`），之后用「分秒」。
String _formatDuration(int milliseconds) {
  final seconds = milliseconds / 1000;
  if (seconds < 60) return '${_trimmedOneDecimal(seconds)}秒';
  final whole = seconds.round();
  return '${whole ~/ 60}分${whole % 60}秒';
}

/// 解码速度：10 tok/s 以上取整，以下保留一位小数（与 Web 一致）。
String _formatSpeed(double tokensPerSecond) {
  final clamped = tokensPerSecond < 0 ? 0.0 : tokensPerSecond;
  return clamped >= 10 ? '${clamped.round()}' : _trimmedOneDecimal(clamped);
}
