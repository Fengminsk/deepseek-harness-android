import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'chat_progress.dart';
import 'chat_projection.dart';

/// The original Web retry row counts down from its first visible render, not
/// from a Host timestamp that may use another clock.
int chatRetrySeconds(int delayMs, int elapsedMs) =>
    math.max(1, ((delayMs - elapsedMs) / 1000).ceil());

String chatRetryLabel(ChatRetry retry, int seconds, {required bool active}) {
  final status = active
      ? '正在重试模型请求'
      : switch (retry.state) {
          ChatRetryState.started => '已重试模型请求',
          ChatRetryState.cancelled => '模型请求重试已取消',
          ChatRetryState.scheduled => '等待模型请求重试',
        };
  return '$status（${retry.number}/${retry.maximum}） · $seconds 秒';
}

/// A compact, expandable retry record. Only the current running turn owns a
/// live countdown; an incomplete old Session log remains a static record.
class ChatRetryRow extends StatefulWidget {
  const ChatRetryRow({
    required this.retry,
    required this.activeTurn,
    this.history,
    this.now,
    super.key,
  });

  final ChatRetry retry;
  final bool activeTurn;
  final String? history;
  final DateTime Function()? now;

  @override
  State<ChatRetryRow> createState() => _ChatRetryRowState();
}

class _ChatRetryRowState extends State<ChatRetryRow>
    with WidgetsBindingObserver {
  Timer? _ticker;
  DateTime? _deadline;
  int _seconds = 1;
  bool _expanded = false;

  bool get _active =>
      widget.activeTurn && widget.retry.state == ChatRetryState.scheduled;
  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetAttempt();
  }

  void _resetAttempt() {
    _ticker?.cancel();
    _ticker = null;
    _seconds = chatRetrySeconds(widget.retry.delayMs, 0);
    _deadline = _active
        ? _now().add(Duration(milliseconds: widget.retry.delayMs))
        : null;
    if (_active && _seconds > 1) {
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        _refreshCountdown();
      });
    }
  }

  void _refreshCountdown() {
    final deadline = _deadline;
    if (!mounted || !_active || deadline == null) return;
    final remaining = chatRetrySeconds(
      deadline.difference(_now()).inMilliseconds,
      0,
    );
    if (remaining != _seconds) setState(() => _seconds = remaining);
    if (remaining == 1) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void didUpdateWidget(ChatRetryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.retry.attemptSeq != oldWidget.retry.attemptSeq ||
        widget.retry.state != oldWidget.retry.state ||
        widget.activeTurn != oldWidget.activeTurn) {
      _resetAttempt();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshCountdown();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = chatRetryLabel(widget.retry, _seconds, active: _active);
    final textStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('chat-retry-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.refresh_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _active
                          ? ChatProgressLabel(text: label)
                          : Text(label, style: textStyle),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(26, 4, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '重试延迟：${widget.retry.delayMs} 毫秒',
                          style: textStyle,
                        ),
                        const SizedBox(height: 6),
                        Text('失败原因：${widget.retry.failure}', style: textStyle),
                        if (widget.history != null) ...[
                          const SizedBox(height: 10),
                          Text('重试记录', style: textStyle),
                          const SizedBox(height: 4),
                          Text(widget.history!, style: textStyle),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
