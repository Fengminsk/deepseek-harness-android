import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'chat_reply_sources.dart';
import 'tool_activity_data.dart';

/// A current activity label uses actual pending calls, never estimated work.
String chatProgressLabel(Iterable<ToolActivity> calls, {bool writing = false}) {
  final pending = calls
      .where((call) => call.phase == ToolActivityPhase.pending)
      .toList();
  if (pending.isEmpty) return writing ? '正在回复' : '正在思考';
  final names = pending.map((call) => call.name).toSet();
  if (names.every(
    (name) =>
        const ['web_search', 'web_fetch', 'search', 'fetch'].contains(name),
  )) {
    return '正在搜索';
  }
  if (names.every((name) => const ['android_shell', 'shell'].contains(name))) {
    return '正在运行命令';
  }
  if (names.every((name) => name == 'read')) return '正在读取文件';
  if (names.every((name) => const ['write', 'edit'].contains(name))) {
    return '正在修改文件';
  }
  if (names.every((name) => name.contains('subagent'))) return '正在协作';
  return '正在处理';
}

class ChatProgressLine extends StatelessWidget {
  const ChatProgressLine({
    required this.calls,
    this.writing = false,
    super.key,
  });
  final List<ToolActivity> calls;
  final bool writing;
  @override
  Widget build(BuildContext context) {
    final sources = ChatReplySources.fromActivities(calls);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        ChatProgressLabel(text: chatProgressLabel(calls, writing: writing)),
        if (sources.entries.isNotEmpty)
          DefaultTextStyle(
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('· 已找到 '),
                ChatRollingCount(value: sources.entries.length),
                const Text(' 个来源'),
              ],
            ),
          ),
      ],
    );
  }
}

/// Quiet, paint-only sweep over one label. Reduced motion leaves a static label.
class ChatProgressLabel extends StatefulWidget {
  const ChatProgressLabel({required this.text, super.key});
  final String text;
  @override
  State<ChatProgressLabel> createState() => _ChatProgressLabelState();
}

class _ChatProgressLabelState extends State<ChatProgressLabel>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
    } else {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PocketReveal(
      child: Semantics(
        liveRegion: true,
        child: AnimatedBuilder(
          animation: _motion,
          child: Text(
            widget.text,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
              color: colors.onSurfaceVariant,
            ),
          ),
          builder: (_, child) => ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(-3 + _motion.value * 6, 0),
              end: Alignment(-1 + _motion.value * 6, 0),
              colors: [
                colors.onSurfaceVariant,
                colors.onSurface,
                colors.onSurfaceVariant,
              ],
              stops: const [0, .5, 1],
            ).createShader(bounds),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Digits roll only when an observed count changes. The label uses the actual
/// target value for accessibility and never invents intermediate work totals.
class ChatRollingCount extends StatelessWidget {
  const ChatRollingCount({required this.value, this.style, super.key});
  final int value;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$value',
    child: ExcludeSemantics(
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 190),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, .65),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Text('$value', key: ValueKey(value), style: style),
        ),
      ),
    ),
  );
}
