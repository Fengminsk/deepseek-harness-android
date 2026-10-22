import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_feedback.dart';
import 'chat_feedback_widgets.dart';
import 'chat_message_actions.dart';
import 'chat_reply_sources.dart';
import 'chat_reply_sources_sheet.dart';
import 'entry_motion.dart';
import 'flclash/popup.dart';
import 'ui.dart';

enum _ReplyAction { select, positive, negative, inspect }

/// One row for an original completed reply. The caller supplies its exact Turn
/// sources and durable message identity; this widget never guesses either.
class ChatReplyBar extends StatefulWidget {
  const ChatReplyBar({
    required this.text,
    required this.onShare,
    required this.onOpenSource,
    this.sources = ChatReplySources.empty,
    this.feedbackController,
    this.messageId,
    this.onInspect,
    super.key,
  }) : assert((feedbackController == null) == (messageId == null));
  final String text;
  final Future<void> Function(String) onShare;
  final Future<void> Function(Uri) onOpenSource;
  final ChatReplySources sources;
  final ChatFeedbackController? feedbackController;
  final String? messageId;
  final VoidCallback? onInspect;
  @override
  State<ChatReplyBar> createState() => _ChatReplyBarState();
}

class _ChatReplyBarState extends State<ChatReplyBar> {
  final _moreKey = GlobalKey();
  PopupRoute<void>? _route;
  NavigatorState? _navigator;
  int _generation = 0;
  bool _busy = false;
  String? _notice;
  Offset? _pressPosition;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  void _seed() {
    final owner = widget.feedbackController, generation = _generation;
    scheduleMicrotask(() {
      if (mounted && _generation == generation && owner?.retired == false) {
        unawaited(owner!.ensure());
      }
    });
  }

  @override
  void didUpdateWidget(ChatReplyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.feedbackController != widget.feedbackController ||
        oldWidget.text != widget.text) {
      _generation++;
      _busy = false;
      _notice = null;
      _closeRoute();
      _seed();
    }
  }

  void _closeRoute() {
    final route = _route, navigator = _navigator;
    _route = null;
    _navigator = null;
    scheduleMicrotask(() {
      if (navigator?.mounted == true && route?.isActive == true) {
        navigator!.removeRoute(route!);
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    _closeRoute();
    super.dispose();
  }

  Future<void> _operation(
    Future<void> Function() action,
    String failure, {
    String? success,
  }) async {
    if (_busy) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action();
      if (mounted && generation == _generation) {
        setState(() => _notice = success);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _notice = failure);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _showSources() async {
    if (_route != null || widget.sources.isEmpty) return;
    final route = chatReplySourcesRoute(
      context,
      widget.sources,
      onOpenSource: widget.onOpenSource,
    );
    await _present(route);
  }

  Future<void> _present(PopupRoute<void> route) async {
    final navigator = Navigator.of(context);
    _route = route;
    _navigator = navigator;
    try {
      await navigator.push<void>(route);
      await route.completed;
    } finally {
      if (identical(_route, route)) {
        _route = null;
        _navigator = null;
      }
    }
  }

  Future<void> _more() async {
    if (_route != null || _busy) return;
    final box = _moreKey.currentContext?.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        overlay is! RenderBox ||
        !overlay.hasSize) {
      return;
    }
    final generation = _generation;
    final owner = widget.feedbackController, messageId = widget.messageId;
    final connection = owner?.runtime.connectionGeneration;
    final text = widget.text, inspect = widget.onInspect;
    final point = _pressPosition == null
        ? box.localToGlobal(box.size.center(Offset.zero), ancestor: overlay)
        : overlay.globalToLocal(_pressPosition!);
    _pressPosition = null;
    final anchor = point & const Size(1, 1);
    _ReplyAction? action;
    Widget menu(BuildContext context) {
      final rating = owner?.current(messageId!)?.rating;
      return CommonPopupMenu(
        items: [
          if (text.isNotEmpty)
            CommonPopupMenuItem(
              label: '选择文本',
              glyph: Icons.text_fields_rounded,
              onPressed: () => action = _ReplyAction.select,
            ),
          if (owner != null && !owner.retired) ...[
            CommonPopupMenuItem(
              label: rating == ChatFeedbackRating.positive
                  ? '取消好的回答标记'
                  : '好的回答',
              glyph: rating == ChatFeedbackRating.positive
                  ? Icons.thumb_up_rounded
                  : Icons.thumb_up_outlined,
              onPressed: () => action = _ReplyAction.positive,
            ),
            CommonPopupMenuItem(
              label: rating == ChatFeedbackRating.negative
                  ? '取消有问题的回答标记'
                  : '有问题的回答',
              glyph: rating == ChatFeedbackRating.negative
                  ? Icons.thumb_down_rounded
                  : Icons.thumb_down_outlined,
              onPressed: () => action = _ReplyAction.negative,
            ),
          ],
          if (inspect != null)
            CommonPopupMenuItem(
              label: '会话记录',
              glyph: Icons.receipt_long_outlined,
              onPressed: () => action = _ReplyAction.inspect,
            ),
        ],
      );
    }

    final route = CommonPopupRoute<void>(
      anchorOf: () => anchor,
      placement: PopupPlacement.belowPoint,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (context) => owner == null
          ? menu(context)
          : AnimatedBuilder(
              animation: owner,
              builder: (context, _) => menu(context),
            ),
    );
    await _present(route);
    if (!mounted || generation != _generation) return;
    switch (action) {
      case _ReplyAction.select:
        await showChatMessageSelection(context, text);
      case _ReplyAction.inspect:
        inspect?.call();
      case _ReplyAction.positive:
      case _ReplyAction.negative:
        if (owner == null ||
            owner.retired ||
            owner.runtime.connectionGeneration != connection) {
          return;
        }
        setState(() {
          _busy = true;
          _notice = null;
        });
        final result = await chooseChatFeedback(
          context,
          controller: owner,
          messageId: messageId!,
          rating: action == _ReplyAction.positive
              ? ChatFeedbackRating.positive
              : ChatFeedbackRating.negative,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _busy = false;
          _notice = result?.ok == false ? result!.message : null;
        });
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => PocketReveal(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ReplyButton(
              icon: Icons.copy_rounded,
              label: '复制回答',
              onPressed: !_busy && widget.text.isNotEmpty
                  ? () {
                      final text = widget.text;
                      unawaited(
                        _operation(
                          () => Clipboard.setData(ClipboardData(text: text)),
                          '复制失败，请重试。',
                          success: '已复制',
                        ),
                      );
                    }
                  : null,
            ),
            _ReplyButton(
              icon: Icons.share_outlined,
              label: '分享回答',
              onPressed: !_busy && widget.text.isNotEmpty
                  ? () {
                      final text = widget.text, share = widget.onShare;
                      unawaited(_operation(() => share(text), '无法打开分享，请重试。'));
                    }
                  : null,
            ),
            Listener(
              key: _moreKey,
              onPointerDown: (event) => _pressPosition = event.position,
              onPointerCancel: (_) => _pressPosition = null,
              child: _ReplyButton(
                icon: Icons.more_horiz_rounded,
                label: '更多回答操作',
                onPressed: !_busy ? () => unawaited(_more()) : null,
              ),
            ),
            if (!widget.sources.isEmpty)
              _ReplyButton(
                icon: Icons.public_rounded,
                label: '来源',
                showLabel: true,
                onPressed: () => unawaited(_showSources()),
              ),
          ],
        ),
        if (_notice != null)
          PocketReveal(
            child: Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text(
                  _notice!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A restrained FlClash press surface: 20px glyph within a 44px target, no
/// permanent round fill. The circular target stays circular when pressed.
class _ReplyButton extends StatelessWidget {
  const _ReplyButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.showLabel = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool showLabel;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
      padding: WidgetStatePropertyAll(
        showLabel
            ? const EdgeInsets.symmetric(horizontal: 10)
            : EdgeInsets.zero,
      ),
      shape: WidgetStatePropertyAll(
        showLabel ? const StadiumBorder() : const CircleBorder(),
      ),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      backgroundBuilder: (context, states, child) => child ?? const SizedBox(),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => colors.onSurfaceVariant.withValues(
          alpha: states.contains(WidgetState.disabled) ? .4 : 1,
        ),
      ),
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.pressed)
            ? colors.onSurface.withValues(alpha: .08)
            : null,
      ),
    );
    return ElasticPress(
      enabled: onPressed != null,
      preserveAspectRatio: true,
      child: showLabel
          ? Tooltip(
              message: label,
              child: TextButton.icon(
                onPressed: onPressed,
                style: style,
                icon: Icon(icon, size: 20),
                label: Text(label),
              ),
            )
          : IconButton(
              tooltip: label,
              onPressed: onPressed,
              style: style.copyWith(
                fixedSize: const WidgetStatePropertyAll(Size.square(44)),
              ),
              icon: Icon(icon, size: 20),
            ),
    );
  }
}
