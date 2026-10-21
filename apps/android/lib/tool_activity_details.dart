import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'flclash/surface.dart';
import 'flclash/typography.dart';
import 'tool_activity_data.dart';
import 'tool_activity_presentation.dart';
import 'ui.dart';

/// Owns a detail route and its snapshots until the route has fully unmounted.
/// Updates never change the call identity or fetch another Session window.
class ToolActivityDetailsController {
  ToolActivityDetailsController._(this._navigator, ToolActivity activity)
    : _snapshots = ValueNotifier(activity),
      _pending = activity;

  static ToolActivityDetailsController open(
    BuildContext context,
    ToolActivity activity, {
    ValueListenable<ToolActivity?>? source,
  }) {
    final navigator = Navigator.of(context);
    final controller = ToolActivityDetailsController._(navigator, activity);
    controller._source = source;
    controller._route = _ToolDetailsRoute(
      snapshots: controller._snapshots,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    );
    source?.addListener(controller._sourceChanged);
    controller.closed = controller._run();
    if (source != null) controller._sourceChanged();
    return controller;
  }

  final NavigatorState _navigator;
  final ValueNotifier<ToolActivity> _snapshots;
  late final _ToolDetailsRoute _route;
  late final Future<void> closed;
  ToolActivity _pending;
  ValueListenable<ToolActivity?>? _source;
  bool _scheduled = false, _closing = false, _disposed = false;

  Future<void> _run() async {
    try {
      await _navigator.push<void>(_route);
      await _route.completed;
    } finally {
      _disposed = true;
      _source?.removeListener(_sourceChanged);
      _snapshots.dispose();
    }
  }

  void _sourceChanged() {
    final next = _source?.value;
    if (next == null || next.identity != _pending.identity) {
      close();
    } else {
      update(next);
    }
  }

  void update(ToolActivity activity) {
    if (_disposed || _closing || activity.identity != _pending.identity) return;
    _pending = activity;
    if (_scheduled) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // A transcript rebuild cannot dirty a sibling route during that build.
      // Publish the latest snapshot at the end of this Flutter frame.
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!_disposed && !_closing) _snapshots.value = _pending;
      });
    } else {
      _snapshots.value = _pending;
    }
  }

  void close() {
    if (_closing || _disposed) return;
    _closing = true;
    void remove() {
      if (!_disposed && _navigator.mounted && _route.isActive) {
        _navigator.removeRoute(_route);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }
}

/// Shared compact treatment for top-level calls and real PTC child calls.
class ToolActivityRow extends StatelessWidget {
  const ToolActivityRow({
    required this.activity,
    required this.onTap,
    this.opened = false,
    super.key,
  });
  final ToolActivity activity;
  final VoidCallback onTap;
  final bool opened;

  @override
  Widget build(BuildContext context) {
    final presentation = ToolActivityPresentation.from(activity);
    final colors = Theme.of(context).colorScheme;
    final ink = presentation.needsAttention(activity)
        ? colors.error
        : colors.onSurfaceVariant;
    final icon = switch (presentation.kind) {
      'shell' => Icons.terminal_rounded,
      'file' => Icons.description_outlined,
      'search' => Icons.search_rounded,
      _ => Icons.build_outlined,
    };
    return Semantics(
      button: true,
      label:
          '${presentation.title(activity)}，${presentation.summary(activity)}',
      hint: '打开调用详情',
      onTap: onTap,
      child: ExcludeSemantics(
        child: ElasticPress(
          child: FocusRing(
            shape: AppShape.md,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('tool-row:${activity.identity}'),
                customBorder: AppShape.md,
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(icon, size: 20, color: ink),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            presentation.summary(activity),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.subheadline
                                .of(context)
                                .copyWith(color: ink),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          opened
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          size: 18,
                          color: ink,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolDetailsRoute extends PopupRoute<void> {
  _ToolDetailsRoute({
    required this.snapshots,
    required this.themes,
    required this.reduceMotion,
    required this.barrierLabel,
  });
  final ValueNotifier<ToolActivity> snapshots;
  final CapturedThemes themes;
  final bool reduceMotion;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor => const Color(0x66000000);
  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 320);
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 220);
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => reduceMotion
      ? child
      : SlideTransition(
          position: animation
              .drive(CurveTween(curve: Curves.easeOutCubic))
              .drive(Tween(begin: const Offset(0, 1), end: Offset.zero)),
          child: PocketBlurTransition(
            animation: animation.drive(
              CurveTween(curve: PocketEntryMotion.curve),
            ),
            child: child,
          ),
        );
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    ValueListenableBuilder<ToolActivity>(
      valueListenable: snapshots,
      builder: (context, activity, _) => _ToolDetailsSheet(
        key: ValueKey(activity.identity),
        activity: activity,
      ),
    ),
  );
}

class _ToolDetailsSheet extends StatefulWidget {
  const _ToolDetailsSheet({required this.activity, super.key});
  final ToolActivity activity;
  @override
  State<_ToolDetailsSheet> createState() => _ToolDetailsSheetState();
}

class _ToolDetailsSheetState extends State<_ToolDetailsSheet> {
  final _extent = DraggableScrollableController();
  final _path = <String>[];
  bool _dismissing = false;
  static const _minimum = .34, _initial = .72, _maximum = .96;

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  List<ToolActivity> get _trail {
    final result = [widget.activity];
    for (final identity in _path) {
      final match = result.last.children
          .where((child) => child.identity == identity)
          .firstOrNull;
      if (match == null) break;
      result.add(match);
    }
    return result;
  }

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final trail = _trail;
    final activity = trail.last;
    final presentation = ToolActivityPresentation.from(activity);
    final colors = Theme.of(context).colorScheme;
    final surface = SurfaceLevel.floatingOf(colors).colorOf(colors);
    final toolbarHeight = (MediaQuery.textScalerOf(context).scale(20) * 1.4)
        .clamp(48.0, 88.0);
    final headerHeight = 28 + toolbarHeight + 10;
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, viewport) => Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: DraggableScrollableSheet(
                controller: _extent,
                expand: false,
                initialChildSize: _initial,
                minChildSize: _minimum,
                maxChildSize: _maximum,
                shouldCloseOnMinExtent: false,
                builder: (context, scroll) => Material(
                  key: const Key('tool-details-sheet'),
                  color: surface,
                  shape: const RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(AppCorner.xxl),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SurfaceScope(
                    level: SurfaceLevel.floatingOf(colors),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ListView(
                            key: ValueKey(
                              'tool-details-body:${activity.identity}',
                            ),
                            controller: scroll,
                            // This space belongs to the scrollable content;
                            // logs continue behind the floating header.
                            padding: EdgeInsets.fromLTRB(
                              20,
                              headerHeight + 4,
                              20,
                              24 + MediaQuery.paddingOf(context).bottom,
                            ),
                            children: [
                              _ToolDetailsBody(
                                activity: activity,
                                presentation: presentation,
                                onChild: (child) => setState(() {
                                  _path
                                    ..clear()
                                    ..addAll(
                                      trail
                                          .skip(1)
                                          .map((item) => item.identity),
                                    )
                                    ..add(child.identity);
                                }),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: FloatingHeader(
                            key: const Key('tool-details-header'),
                            backgroundColor: surface,
                            overhang: 28,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  key: const Key('tool-details-drag-handle'),
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragUpdate: (details) {
                                    if (_extent.isAttached) {
                                      _extent.jumpTo(
                                        (_extent.size -
                                                details.delta.dy /
                                                    viewport.maxHeight)
                                            .clamp(_minimum, _maximum),
                                      );
                                    }
                                  },
                                  onVerticalDragEnd: (details) {
                                    if (_extent.isAttached &&
                                        (_extent.size <= _minimum + .01 ||
                                            (details.primaryVelocity ?? 0) >
                                                900)) {
                                      _dismiss();
                                    }
                                  },
                                  child: SizedBox(
                                    height: 28,
                                    width: double.infinity,
                                    child: Center(
                                      child: Container(
                                        width: 32,
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: colors.onSurfaceVariant
                                              .withValues(alpha: .5),
                                          borderRadius: AppRadius.full,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    10,
                                  ),
                                  child: SizedBox(
                                    height: toolbarHeight,
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 48,
                                          child: trail.length > 1
                                              ? GlassButton(
                                                  icon:
                                                      Icons.arrow_back_rounded,
                                                  label: '返回上级调用',
                                                  onPressed: () => setState(
                                                    () => _path.removeLast(),
                                                  ),
                                                )
                                              : null,
                                        ),
                                        Expanded(
                                          child: IgnorePointer(
                                            child: Text(
                                              presentation.title(activity),
                                              key: const Key(
                                                'tool-details-title',
                                              ),
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTextStyle.headline.of(
                                                context,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 48,
                                          child: GlassButton(
                                            key: const Key(
                                              'tool-details-close',
                                            ),
                                            icon: Icons.close_rounded,
                                            label: '关闭调用详情',
                                            onPressed: _dismiss,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
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
      ),
    );
  }
}

const _outputFields = {
  'stdout',
  'stderr',
  '输出',
  '读取内容',
  '文件列表',
  '匹配路径',
  '匹配结果',
  '结果',
};

class _ToolDetailsBody extends StatelessWidget {
  const _ToolDetailsBody({
    required this.activity,
    required this.presentation,
    required this.onChild,
  });
  final ToolActivity activity;
  final ToolActivityPresentation presentation;
  final ValueChanged<ToolActivity> onChild;

  @override
  Widget build(BuildContext context) {
    final fields = presentation.fields;
    final colors = Theme.of(context).colorScheme;
    final code = <String, String>{
      if (fields.containsKey('命令')) '命令': fields['命令']!,
      for (final entry in fields.entries)
        if (_outputFields.contains(entry.key)) entry.key: entry.value,
      if (fields.isEmpty && activity.resultText.isNotEmpty)
        '结果': activity.resultText,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          toolActivityStatus(activity),
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(
                color: presentation.needsAttention(activity)
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
        ),
        if (activity.name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              activity.name,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        if (!activity.hasCall)
          const _ToolNotice('缺少调用开始记录；未记录的名称、参数或开始时间不作推测。'),
        if (!activity.hasResult)
          _ToolNotice(
            activity.phase == ToolActivityPhase.interrupted
                ? '所属步骤或回合已结束，但未记录工具结果。'
                : !activity.hasCall
                ? '当前记录只包含子调用；上级调用的开始与结果未记录。'
                : '尚未收到工具结果；可能仍在等待执行或授权。',
          ),
        if (activity.error != null)
          _ToolNotice(
            '错误：${activity.error!['name'] ?? '未命名'} · ${activity.error!['code'] ?? '未知代码'}${activity.error!['reason'] == null ? '' : '\n${activity.error!['reason']}'}',
            error: true,
          ),
        if (code.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 18),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: AppShape.xl.copyWith(
                  side: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .55),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, entry) in code.entries.indexed) ...[
                    if (index > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Divider(
                          height: 1,
                          color: colors.outlineVariant.withValues(alpha: .55),
                        ),
                      ),
                    _CopyBlock(
                      key: ValueKey('${activity.identity}:${entry.key}'),
                      title: entry.key,
                      text: entry.value,
                    ),
                  ],
                ],
              ),
            ),
          ),
        for (final entry in fields.entries)
          if (entry.key != '命令' && !_outputFields.contains(entry.key))
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.key,
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    entry.value,
                    style: AppTextStyle.body.of(context),
                  ),
                ],
              ),
            ),
        for (final warning in activity.warnings) _ToolNotice(warning),
        if (activity.children.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '子调用 · ${activity.children.length}',
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: colors.onSurfaceVariant),
          ),
          for (final child in activity.children)
            ToolActivityRow(
              key: ValueKey(child.identity),
              activity: child,
              onTap: () => onChild(child),
            ),
        ],
        const SizedBox(height: 12),
        _RawDetails(
          key: ValueKey('raw:${activity.identity}'),
          activity: activity,
        ),
      ],
    );
  }
}

class _CopyBlock extends StatefulWidget {
  const _CopyBlock({required this.title, required this.text, super.key});
  final String title, text;
  @override
  State<_CopyBlock> createState() => _CopyBlockState();
}

class _CopyBlockState extends State<_CopyBlock> {
  bool _all = false, _busy = false;
  String? _feedback;
  int _request = 0;

  @override
  void didUpdateWidget(_CopyBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _request++;
      _busy = false;
      _feedback = null;
    }
  }

  Future<void> _copy() async {
    if (_busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    String feedback;
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
      feedback = '已复制';
    } catch (_) {
      // The local clipboard operation failed; the complete source stays here.
      feedback = '复制失败，请重试';
    }
    if (mounted && request == _request) {
      setState(() {
        _busy = false;
        _feedback = feedback;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > 6000;
    final preview = long && !_all ? _prefix(widget.text, 6000) : widget.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.title,
                        style: AppTextStyle.footnote
                            .of(context)
                            .copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      if (_feedback != null)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _feedback!,
                            style: AppTextStyle.footnote.of(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              GlassButton(
                key: ValueKey('tool-copy:${widget.title}'),
                icon: _feedback == '已复制'
                    ? Icons.check_rounded
                    : Icons.copy_rounded,
                label: '复制${widget.title}',
                onPressed: _busy ? null : _copy,
              ),
            ],
          ),
          SelectableText(
            preview.isEmpty ? '（空）' : preview,
            style: AppTextStyle.subheadline
                .of(context)
                .copyWith(fontFamily: 'monospace', height: 1.5),
          ),
          if (long && !_all) ...[
            const SizedBox(height: 8),
            Text(
              '显示前 6000 个字符；复制包含本次记录的全部内容',
              style: AppTextStyle.footnote.of(context),
            ),
            PocketButton.tonal(
              onPressed: () => setState(() => _all = true),
              child: const Text('显示完整内容'),
            ),
          ],
        ],
      ),
    );
  }
}

class _RawDetails extends StatefulWidget {
  const _RawDetails({required this.activity, super.key});
  final ToolActivity activity;
  @override
  State<_RawDetails> createState() => _RawDetailsState();
}

class _RawDetailsState extends State<_RawDetails> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PocketRow(
        icon: Icons.data_object_rounded,
        title: '完整原始详情',
        onTap: () => setState(() => _expanded = !_expanded),
        trailing: Icon(
          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
        ),
      ),
      AnimatedSize(
        alignment: Alignment.topCenter,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        child: _expanded
            ? _CopyBlock(title: '原始记录', text: widget.activity.rawJson)
            : const SizedBox(width: double.infinity),
      ),
    ],
  );
}

class _ToolNotice extends StatelessWidget {
  const _ToolNotice(this.text, {this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: SelectableText(
      text,
      style: AppTextStyle.footnote
          .of(context)
          .copyWith(
            color: error
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    ),
  );
}

String _prefix(String text, int length) {
  var end = length;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  return '${text.substring(0, end)}…';
}
