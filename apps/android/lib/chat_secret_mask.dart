import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'runtime.dart';
import 'ui.dart';

/// Original ui-secret-mask ranges use UTF-16 offsets into the unchanged text.
/// Merge these at priority 0 before Session (10), skill (20), and file (30).
class ChatSecretRange {
  const ChatSecretRange(this.start, this.end, this.masked);
  final int start, end;
  final String masked;

  static List<ChatSecretRange> parse(dynamic raw, String text) {
    if (raw is! Map || raw['ranges'] is! List) {
      throw const FormatException('消息显示结果不完整');
    }
    var consumed = 0;
    final ranges = <ChatSecretRange>[];
    for (final range in raw['ranges']) {
      if (range is! Map ||
          range['start'] is! int ||
          range['end'] is! int ||
          range['masked'] is! String ||
          range['start'] < consumed ||
          range['end'] <= range['start'] ||
          range['end'] > text.length) {
        throw const FormatException('消息显示范围不完整');
      }
      ranges.add(
        ChatSecretRange(range['start'], range['end'], range['masked']),
      );
      consumed = range['end'];
    }
    return List.unmodifiable(ranges);
  }
}

enum ChatSecretMaskPhase { loading, ready, unavailable }

/// A text value's display projection. The Host runs the exact original matcher;
/// errors never draw the original text as an implicit fallback.
class ChatSecretMaskController extends ChangeNotifier {
  ChatSecretMaskController({required this.runtime, required this.text})
    : _connection = runtime.connectionGeneration,
      _runtimePhase = runtime.phase {
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  final String text;
  ChatSecretMaskPhase phase = ChatSecretMaskPhase.loading;
  List<ChatSecretRange> ranges = const [];
  String? error;
  bool _disposed = false;
  int _connection, _epoch = 0;
  String _runtimePhase;
  Future<void>? _pending;

  bool _current(int epoch) => !_disposed && epoch == _epoch && runtime.ready;
  void _runtimeChanged() {
    if (_connection == runtime.connectionGeneration &&
        _runtimePhase == runtime.phase) {
      return;
    }
    _connection = runtime.connectionGeneration;
    _runtimePhase = runtime.phase;
    _epoch++;
    _pending = null;
    phase = ChatSecretMaskPhase.unavailable;
    ranges = const [];
    error = '连接恢复后重新显示此消息';
    notifyListeners();
    if (runtime.ready) unawaited(load());
  }

  Future<void> load() {
    if (_disposed || phase == ChatSecretMaskPhase.ready) return Future.value();
    if (_pending != null) return _pending!;
    if (!runtime.ready) {
      phase = ChatSecretMaskPhase.unavailable;
      error = '连接恢复后重新显示此消息';
      notifyListeners();
      return Future.value();
    }
    if (utf8.encode(text).length > 512 * 1024) {
      phase = ChatSecretMaskPhase.unavailable;
      error = '消息过长，暂时无法生成遮罩显示';
      notifyListeners();
      return Future.value();
    }
    final epoch = _epoch;
    phase = ChatSecretMaskPhase.loading;
    error = null;
    notifyListeners();
    late final Future<void> pending;
    pending = () async {
      try {
        final result = await runtime.call('userText.mask', {'text': text});
        if (!_current(epoch)) return;
        ranges = ChatSecretRange.parse(result, text);
        phase = ChatSecretMaskPhase.ready;
        notifyListeners();
      } catch (_) {
        if (!_current(epoch)) return;
        phase = ChatSecretMaskPhase.unavailable;
        error = '无法生成消息遮罩，点按重试';
        notifyListeners();
      } finally {
        if (identical(_pending, pending)) _pending = null;
      }
    }();
    return _pending = pending;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}

/// The builder runs only after the original mask rule has finished. The owning
/// message retains raw copy/selection outside this display-only widget.
class ChatSecretMask extends StatefulWidget {
  const ChatSecretMask({
    required this.runtime,
    required this.text,
    required this.builder,
    super.key,
  });
  final RuntimeController runtime;
  final String text;
  final Widget Function(BuildContext context, List<ChatSecretRange> ranges)
  builder;
  @override
  State<ChatSecretMask> createState() => _ChatSecretMaskState();
}

class _ChatSecretMaskState extends State<ChatSecretMask> {
  late ChatSecretMaskController _controller;
  void _connect() {
    _controller = ChatSecretMaskController(
      runtime: widget.runtime,
      text: widget.text,
    );
    unawaited(_controller.load());
  }

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(ChatSecretMask oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime || oldWidget.text != widget.text) {
      _controller.dispose();
      _connect();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      if (_controller.phase == ChatSecretMaskPhase.ready) {
        return PocketReveal(child: widget.builder(context, _controller.ranges));
      }
      return Semantics(
        liveRegion: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _controller.error ?? '正在处理消息显示…',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_controller.phase == ChatSecretMaskPhase.unavailable)
              GlassButton(
                icon: Icons.refresh_rounded,
                label: '重新生成消息遮罩',
                onPressed: widget.runtime.ready
                    ? () => unawaited(_controller.load())
                    : null,
              ),
          ],
        ),
      );
    },
  );
}

/// Revealing one value never persists and never reveals a replacement value.
/// Noninteractive preview text is always masked, as in original SecretText.
class ChatSecretValue extends StatefulWidget {
  const ChatSecretValue({
    required this.raw,
    required this.masked,
    this.interactive = true,
    this.style,
    super.key,
  });
  final String raw, masked;
  final bool interactive;
  final TextStyle? style;
  @override
  State<ChatSecretValue> createState() => _ChatSecretValueState();
}

class _ChatSecretValueState extends State<ChatSecretValue> {
  String? _revealedRaw;
  @override
  void didUpdateWidget(ChatSecretValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.raw != widget.raw ||
        oldWidget.interactive != widget.interactive) {
      _revealedRaw = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final revealed = widget.interactive && _revealedRaw == widget.raw;
    return PocketReveal(
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: revealed ? widget.raw : widget.masked),
            if (widget.interactive)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox.square(
                  dimension: 28,
                  child: Semantics(
                    selected: revealed,
                    child: GlassButton(
                      icon: revealed
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      label: revealed ? '隐藏凭据' : '显示凭据',
                      onPressed: () => setState(
                        () => _revealedRaw = revealed ? null : widget.raw,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        style: widget.style ?? const TextStyle(fontSize: 16, height: 1.6),
      ),
    );
  }
}
