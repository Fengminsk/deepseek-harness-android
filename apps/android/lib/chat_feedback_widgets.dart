import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'chat_feedback.dart';
import 'entry_motion.dart';
import 'feedback_draft.dart';
import 'ui.dart';

/// The same action is used by the compact reply menu and accessibility actions.
/// Choosing a new rating opens an empty draft; only submission writes feedback.
Future<ChatFeedbackResult?> chooseChatFeedback(
  BuildContext context, {
  required ChatFeedbackController controller,
  required String messageId,
  required ChatFeedbackRating rating,
}) async {
  final connection = controller.runtime.connectionGeneration;
  await controller.ensure();
  if (!context.mounted) return null;
  if (controller.retired) {
    return const ChatFeedbackResult.failure('disposed');
  }
  if (connection != controller.runtime.connectionGeneration) {
    return const ChatFeedbackResult.failure('connection-changed');
  }
  if (controller.current(messageId)?.rating == rating &&
      controller.phase == ChatFeedbackPhase.ready) {
    return controller.retract(messageId, rating);
  }
  final recorded = await Navigator.of(context).push<bool>(
    PocketRoute(
      builder: (_) => ChatFeedbackPage(
        controller: controller,
        messageId: messageId,
        rating: rating,
      ),
    ),
  );
  return recorded == true ? const ChatFeedbackResult.success() : null;
}

/// Mount only for original, settled assistant-message identities. The caller
/// owns the Session controller; array positions and turn numbers are not IDs.
class ChatFeedbackActions extends StatefulWidget {
  const ChatFeedbackActions({
    required this.controller,
    required this.messageId,
    super.key,
  });
  final ChatFeedbackController controller;
  final String messageId;
  @override
  State<ChatFeedbackActions> createState() => _ChatFeedbackActionsState();
}

class _ChatFeedbackActionsState extends State<ChatFeedbackActions> {
  bool _busy = false;
  int _generation = 0;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  void _seed() {
    final owner = widget.controller;
    final generation = _generation;
    // Mobile has no hover. Visible action rows share one read; defer its
    // notifications until the parent has finished mounting sibling rows.
    scheduleMicrotask(() {
      if (mounted && generation == _generation && !owner.retired) {
        unawaited(owner.ensure());
      }
    });
  }

  @override
  void didUpdateWidget(ChatFeedbackActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.messageId != widget.messageId) {
      _generation++;
      _busy = false;
      _notice = null;
      _seed();
    }
  }

  Future<void> _choose(ChatFeedbackRating rating) async {
    if (_busy || !widget.controller.available) return;
    final generation = _generation;
    final owner = widget.controller;
    final messageId = widget.messageId;
    final connection = owner.runtime.connectionGeneration;
    bool current() =>
        mounted &&
        generation == _generation &&
        !owner.retired &&
        owner.runtime.connectionGeneration == connection;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final loaded = await owner.ensure();
    if (!current()) {
      if (mounted && generation == _generation) setState(() => _busy = false);
      return;
    }
    if (loaded.ok && owner.current(messageId)?.rating == rating) {
      final result = await owner.retract(messageId, rating);
      if (!current()) {
        if (mounted && generation == _generation) setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _notice = result.ok ? null : result.message;
      });
      return;
    }
    // Like and dislike both open an empty draft; choosing is not a mutation.
    setState(() => _busy = false);
    if (!mounted) return;
    final recorded = await Navigator.of(context).push<bool>(
      PocketRoute(
        builder: (_) => ChatFeedbackPage(
          controller: owner,
          messageId: messageId,
          rating: rating,
        ),
      ),
    );
    if (current() && recorded == true) setState(() => _notice = '感谢你的反馈');
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final rating = widget.controller.current(widget.messageId)?.rating;
      final enabled = !_busy && widget.controller.available;
      return PocketReveal(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  selected: rating == ChatFeedbackRating.positive,
                  child: GlassButton(
                    icon: rating == ChatFeedbackRating.positive
                        ? Icons.thumb_up_rounded
                        : Icons.thumb_up_outlined,
                    label: rating == ChatFeedbackRating.positive
                        ? '取消好的回答标记'
                        : '好的回答',
                    onPressed: enabled
                        ? () => unawaited(_choose(ChatFeedbackRating.positive))
                        : null,
                  ),
                ),
                const SizedBox(width: 6),
                Semantics(
                  selected: rating == ChatFeedbackRating.negative,
                  child: GlassButton(
                    icon: rating == ChatFeedbackRating.negative
                        ? Icons.thumb_down_rounded
                        : Icons.thumb_down_outlined,
                    label: rating == ChatFeedbackRating.negative
                        ? '取消有问题的回答标记'
                        : '有问题的回答',
                    onPressed: enabled
                        ? () => unawaited(_choose(ChatFeedbackRating.negative))
                        : null,
                  ),
                ),
              ],
            ),
            if (_notice != null ||
                widget.controller.phase == ChatFeedbackPhase.error)
              PocketReveal(
                child: Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _notice ?? '反馈状态加载失败，点按后可重试',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// The original optional category and note form, presented on a floating native
/// page. An error retains the exact draft, including a CAS conflict.
class ChatFeedbackPage extends StatefulWidget {
  const ChatFeedbackPage({
    required this.controller,
    required this.messageId,
    required this.rating,
    super.key,
  });
  final ChatFeedbackController controller;
  final String messageId;
  final ChatFeedbackRating rating;
  @override
  State<ChatFeedbackPage> createState() => _ChatFeedbackPageState();
}

class _ChatFeedbackPageState extends State<ChatFeedbackPage> {
  final _text = TextEditingController();
  String? _category, _failure;
  bool _submitting = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !widget.controller.available) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitting = true;
      _failure = null;
    });
    final result = await widget.controller.rate(
      widget.messageId,
      widget.rating,
      category: _category,
      text: _text.text,
    );
    if (!mounted) return;
    if (result.ok) {
      if (route?.isCurrent == true) {
        navigator.pop(true);
      } else if (route?.isActive == true) {
        // A successful old draft must never pop an unrelated newer page.
        navigator.removeRoute(route!, true);
      }
    } else {
      setState(() {
        _submitting = false;
        _failure = result.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final enabled = widget.controller.available && !_submitting;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: PocketScaffold(
          title: const Text('提交反馈'),
          leading: GlassButton(
            icon: Icons.close_rounded,
            label: '关闭反馈',
            onPressed: () => Navigator.maybePop(context),
          ),
          body: FeedbackDraftBody(
            text: _text,
            category: _category,
            enabled: enabled,
            hint: '填写详情以帮助我们改进体验',
            explanation: '提交内容会包括当前对话的日志。',
            onCategory: (category) => setState(() {
              _category = _category == category ? null : category;
            }),
          ),
          bottom: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_failure != null || !widget.controller.available)
                PocketReveal(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _failure ??
                            (widget.controller.retired
                                ? '这段会话已关闭。'
                                : '服务连接恢复后可继续提交，填写内容已保留。'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                ),
              PocketButton(
                onPressed: enabled ? _submit : null,
                child: Text(_submitting ? '正在提交' : '提交'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
