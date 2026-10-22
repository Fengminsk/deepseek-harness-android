import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/popup.dart';
import 'runtime.dart';
import 'ui.dart';

/// Copy authored text, without hidden reasoning, attachment metadata or logs.
String chatMessageText(List<dynamic> content) => content
    .whereType<Json>()
    .where((block) => block['type'] == 'text' && block['text'] is String)
    .map((block) => block['text'] as String)
    .join('\n\n');

Future<void> showChatMessageSelection(BuildContext context, String text) =>
    Navigator.of(context).push<void>(
      PocketRoute(builder: (_) => _MessageSelectionPage(text: text)),
    );

enum _MessageAction { copy, select }

class ChatMessageActions extends StatefulWidget {
  const ChatMessageActions({
    required this.text,
    required this.child,
    super.key,
  });
  final String text;
  final Widget child;
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
      hint: '长按复制或选择文本',
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
