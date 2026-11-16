// 远程会话页的底部统计条与它的详情弹层。
//
// 统计条是一行紧凑读数，分三段：`轮 X · 步 Y`（sessionStats）、
// `N tok · 缓存命中 P%`（tokenUsage 派生）、`上下文 Q%`（contextPressure 派生）。
// 每一段只在宿主真的给出对应读数时出现：缓存命中率没有计费输入 token 时整段不写，
// 上下文缺已用量或容量时不写百分比，会话统计 0 轮 0 步时也不写——不拿 0 当读数。
//
// 空间不足时（实测一行放不下，例如窄屏或放大字体）折叠成一枚仍可点的小胶囊，
// 只保留最关键的一项读数（上下文占用 > 缓存命中 > token 总量 > 轮/步），点按
// 照常打开同一个详情弹层；正常一行时点按整条也能打开详情。
//
// 组件是纯展示：读数由页面给，组件没有订阅、定时器或动画，因此只有页面收到新的
// 会话洞察时才重建。详情弹层的排版沿用 App 现有底部弹层（玻璃顶角、把手、居中
// 标题与圆形关闭按钮，见 `remote_dsh_widgets.dart` 的权限弹层）。

import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
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

/// 远程会话的底部统计条：一行紧凑读数，点按打开详情弹层。
class RemoteStatsBar extends StatelessWidget {
  /// 创建统计条。
  const RemoteStatsBar({super.key, required this.insights, this.onTap});

  /// 当前会话洞察读数；没有可展示的读数时整条不渲染。
  final RemoteSessionInsights insights;

  /// 点按回调（打开详情弹层）；null 时只展示不可点。
  final VoidCallback? onTap;

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
      _segmentsOf(insights).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsOf(insights);
    if (segments.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final style = AppTextStyle.caption1
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return Semantics(
      key: barKey,
      button: onTap != null,
      label: '会话统计：${segments.join(' · ')}；点按查看详情',
      onTap: onTap,
      child: ExcludeSemantics(
        child: ElasticPress(
          enabled: onTap != null,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: AppShape.full,
              onTap: onTap,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final fits =
                      _lineWidth(context, segments, style) +
                          _statsLineInset * 2 +
                          _statsFitMargin <=
                      constraints.maxWidth;
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _statsLineInset,
                        vertical: 6,
                      ),
                      child: fits
                          ? _line(segments, style)
                          : _capsule(context, segments, style),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一行读数：图标、三个分段、展开提示。
  Widget _line(List<String> segments, TextStyle style) {
    final color = style.color;
    return Row(
      key: lineKey,
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
    final reading = _capsuleReadingOf(insights) ?? segments.first;
    return GlassSurface(
      key: capsuleKey,
      radius: AppCorner.full,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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
            : '${_formatCompactTokens(usage.totalTokens)} tok · 缓存命中 $cacheHit%',
      );
    }
    final contextPercent = insights.contextPercent;
    if (contextPercent != null) {
      segments.add('上下文 $contextPercent%');
    }
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
    final colors = Theme.of(context).colorScheme;
    final shape = AppShape.top(AppCorner.xxl);
    return Semantics(
      key: const ValueKey('remote-stats-sheet'),
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .82,
            ),
            child: GlassSurface(
              radius: AppCorner.xxl,
              child: Material(
                type: MaterialType.transparency,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 18,
                        child: Center(
                          child: Container(
                            width: 32,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colors.onSurfaceVariant.withValues(
                                alpha: .5,
                              ),
                              borderRadius: AppRadius.full,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            const SizedBox(width: 48),
                            Expanded(
                              child: Text(
                                '会话统计',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: AppTextStyle.headline.of(
                                  context,
                                  emphasized: true,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 48,
                              child: GlassButton(
                                icon: Icons.close_rounded,
                                label: '关闭会话统计',
                                onPressed: () => Navigator.maybePop(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _sections(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
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
