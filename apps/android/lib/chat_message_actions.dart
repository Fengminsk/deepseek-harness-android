import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'design/popup.dart';
import 'runtime.dart';
import 'ui.dart';

/// Copy authored text, without hidden reasoning, attachment metadata or logs.
String chatMessageText(List<dynamic> content) => content
    .whereType<Json>()
    .where((block) => block['type'] == 'text' && block['text'] is String)
    .map((block) => block['text'] as String)
    .join('\n\n');

/// The same local-calendar cut as the original message IconActions clock.
String? chatMessageClock(int? time, {DateTime? now}) {
  if (time == null || time <= 0) return null;
  if (time > 8640000000000000) return null;
  final date = DateTime.fromMillisecondsSinceEpoch(time);
  final today = now ?? DateTime.now();
  final clock =
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  if (date.year == today.year &&
      date.month == today.month &&
      date.day == today.day) {
    return clock;
  }
  final day = date.year == today.year
      ? '${date.month}月${date.day}日'
      : '${date.year}年${date.month}月${date.day}日';
  return '$day $clock';
}

/// Compact visible actions for a human message. Internal context rows do not
/// get this chrome, and the copy payload is the authored text alone.
class ChatUserMessageActions extends StatefulWidget {
  const ChatUserMessageActions({required this.text, this.time, super.key});
  final String text;
  final int? time;

  @override
  State<ChatUserMessageActions> createState() => _ChatUserMessageActionsState();
}

class _ChatUserMessageActionsState extends State<ChatUserMessageActions> {
  Timer? _reset;
  int _generation = 0;
  bool _copying = false;
  bool _copied = false;
  String? _error;

  @override
  void didUpdateWidget(ChatUserMessageActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.time != widget.time) {
      _generation++;
      _reset?.cancel();
      _copying = false;
      _copied = false;
      _error = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    if (_copying || _copied || widget.text.isEmpty) return;
    final generation = _generation;
    final text = widget.text;
    setState(() {
      _copying = true;
      _error = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted || generation != _generation) return;
      setState(() {
        _copying = false;
        _copied = true;
      });
      _reset = Timer(const Duration(seconds: 1), () {
        if (mounted && generation == _generation) {
          setState(() => _copied = false);
        }
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _copying = false;
        _error = '复制失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = chatMessageClock(widget.time);
    if (widget.text.isEmpty && clock == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 12, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (clock != null)
                Flexible(
                  child: Text(
                    clock,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              if (widget.text.isNotEmpty)
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    tooltip: _copied ? '已复制消息' : '复制消息',
                    onPressed: _copying || _copied ? null : _copy,
                    style: ButtonStyle(
                      fixedSize: const WidgetStatePropertyAll(Size.square(44)),
                      shape: const WidgetStatePropertyAll(CircleBorder()),
                      backgroundColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      splashFactory: NoSplash.splashFactory,
                      overlayColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.pressed)
                            ? colors.onSurface.withValues(alpha: .08)
                            : null,
                      ),
                    ),
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          if (_error != null)
            PocketReveal(
              child: Semantics(
                liveRegion: true,
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> showChatMessageSelection(BuildContext context, String text) =>
    Navigator.of(context).push<void>(
      PocketRoute(builder: (_) => _MessageSelectionPage(text: text)),
    );

enum _MessageAction { copy, select, quote }

class ChatMessageActions extends StatefulWidget {
  const ChatMessageActions({
    required this.text,
    required this.child,
    this.onQuote,
    super.key,
  });
  final String text;
  final Widget child;

  /// Inserts this message as a Markdown blockquote into the composer. Absent
  /// when the transcript cannot reach the composer, which hides the action.
  final ValueChanged<String>? onQuote;
  @override
  State<ChatMessageActions> createState() => _ChatMessageActionsState();
}

class _ChatMessageActionsState extends State<ChatMessageActions> {
  bool _opening = false;
  String? _status;
  CommonPopupRoute<void>? _menuRoute;
  NavigatorState? _menuNavigator;

  @override
  void didUpdateWidget(ChatMessageActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _status = null;
  }

  @override
  void dispose() {
    final route = _menuRoute, navigator = _menuNavigator;
    // A lazy row may be removed during build. Remove only its own menu after
    // that frame, without popping another page or leaving an inert popup.
    scheduleMicrotask(() {
      if (route != null && navigator?.mounted == true && route.isActive) {
        navigator!.removeRoute(route);
      }
    });
    super.dispose();
  }

  Future<void> _menu([Offset? position]) async {
    if (_opening || widget.text.isEmpty) return;
    final box = context.findRenderObject();
    final navigator = Navigator.of(context);
    final overlay = navigator.overlay?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        overlay is! RenderBox ||
        !overlay.hasSize) {
      return;
    }
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final visible = rect.intersect(Offset.zero & overlay.size);
    final point = position == null
        ? visible.center
        : overlay.globalToLocal(position);
    final anchor = point & const Size(1, 1);
    // A route operates on the message the user actually long-pressed.
    final text = widget.text;
    _opening = true;
    unawaited(HapticFeedback.mediumImpact());
    _MessageAction? action;
    final route = CommonPopupRoute<void>(
      anchorOf: () => anchor,
      placement: PopupPlacement.belowPoint,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (_) => CommonPopupMenu(
        items: [
          CommonPopupMenuItem(
            label: '复制',
            glyph: Icons.copy_rounded,
            onPressed: () => action = _MessageAction.copy,
          ),
          if (widget.onQuote != null)
            CommonPopupMenuItem(
              label: '引用',
              glyph: Icons.format_quote_rounded,
              onPressed: () => action = _MessageAction.quote,
            ),
          CommonPopupMenuItem(
            label: '选择文本',
            glyph: Icons.text_fields_rounded,
            onPressed: () => action = _MessageAction.select,
          ),
        ],
      ),
    );
    _menuRoute = route;
    _menuNavigator = navigator;
    try {
      await navigator.push<void>(route);
      await route.completed;
      if (!mounted) return;
      if (action == _MessageAction.copy) {
        try {
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) setState(() => _status = '已复制');
        } catch (_) {
          if (mounted) setState(() => _status = '复制失败，请重试');
        }
      } else if (action == _MessageAction.select) {
        await navigator.push<void>(
          PocketRoute(builder: (_) => _MessageSelectionPage(text: text)),
        );
      } else if (action == _MessageAction.quote) {
        widget.onQuote!(text);
        if (mounted) setState(() => _status = '已引用');
      }
    } finally {
      _menuRoute = null;
      _menuNavigator = null;
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.isEmpty) return widget.child;
    return Semantics(
      onLongPress: _menu,
      hint: widget.onQuote == null ? '长按复制或选择文本' : '长按复制、引用或选择文本',
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        onLongPressStart: (details) => _menu(details.globalPosition),
        onSecondaryTapDown: (details) => _menu(details.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.child,
            if (_status != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _status!,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageSelectionPage extends StatelessWidget {
  const _MessageSelectionPage({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('选择文本'),
    body: PocketList(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 16, height: 1.6),
          ),
        ),
      ],
    ),
  );
}
