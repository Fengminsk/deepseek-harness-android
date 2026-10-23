import 'package:material_ui/material_ui.dart';

import 'chat_feedback.dart';
import 'entry_motion.dart';
import 'feedback_draft.dart';
import 'runtime.dart';
import 'ui.dart';

/// The original `sessionFeedback.record` acknowledges a log append, not a disk
/// flush. An unacknowledged write may have landed, so it is never retried here.
class SessionFeedbackOutcome {
  const SessionFeedbackOutcome._(this.recorded, this.uncertain, this.message);

  const SessionFeedbackOutcome.recorded() : this._(true, false, null);
  const SessionFeedbackOutcome.rejected(String message)
    : this._(false, false, message);
  const SessionFeedbackOutcome.uncertain()
    : this._(false, true, '提交结果未确认。请先查看当前会话记录，再决定是否重新提交。');

  final bool recorded, uncertain;
  final String? message;
}

/// Records one session-level remark through DSH's original Host service.
/// Only the explicit page submit calls this method; transport failure cannot
/// cause another submission or fall through to a model request.
Future<SessionFeedbackOutcome> recordSessionFeedback(
  RuntimeController runtime,
  String sessionId, {
  required String text,
  String? category,
}) async {
  if (category != null && !chatFeedbackCategories.containsKey(category)) {
    return const SessionFeedbackOutcome.rejected('反馈分类已不可用，请重新选择。');
  }
  final connection = runtime.connectionGeneration;
  try {
    await runtime.ensureSession(sessionId);
  } catch (_) {
    return const SessionFeedbackOutcome.rejected('当前会话暂不可用，请稍后重试。');
  }
  if (!runtime.ready || runtime.connectionGeneration != connection) {
    return const SessionFeedbackOutcome.rejected('服务连接已变化，请重新打开反馈页面。');
  }

  dynamic response;
  try {
    final note = text.trim();
    response = await runtime.call('api.call', {
      'namespace': 'sessionFeedback',
      'method': 'record',
      'args': {
        'sessionId': sessionId,
        if (note.isNotEmpty) 'text': note,
        'category': ?category,
      },
    });
  } catch (_) {
    return const SessionFeedbackOutcome.uncertain();
  }
  if (response is! Map || response['ok'] is! bool) {
    return const SessionFeedbackOutcome.uncertain();
  }
  if (response['ok'] == true) {
    final value = response['value'];
    return value is Map && value['recorded'] == true
        ? const SessionFeedbackOutcome.recorded()
        : const SessionFeedbackOutcome.uncertain();
  }
  final error = response['error'];
  if (error is Map && error['code'] == 'session-not-found') {
    return const SessionFeedbackOutcome.rejected('这段会话已不可用，请返回会话列表核对。');
  }
  return const SessionFeedbackOutcome.uncertain();
}

/// Bare `/feedback` opens the same category-and-detail form as original DSH.
/// A typed `/feedback <text>` remains the original text command.
class SessionFeedbackPage extends StatefulWidget {
  const SessionFeedbackPage({
    required this.runtime,
    required this.sessionId,
    super.key,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<SessionFeedbackPage> createState() => _SessionFeedbackPageState();
}

class _SessionFeedbackPageState extends State<SessionFeedbackPage> {
  final _text = TextEditingController();
  String? _category, _message;
  bool _submitting = false, _uncertain = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _uncertain || !widget.runtime.ready) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitting = true;
      _message = null;
    });
    final result = await recordSessionFeedback(
      widget.runtime,
      widget.sessionId,
      text: _text.text,
      category: _category,
    );
    if (!mounted) return;
    if (result.recorded) {
      if (route?.isCurrent == true) {
        navigator.pop(true);
      } else if (route?.isActive == true) {
        navigator.removeRoute(route!, true);
      }
      return;
    }
    setState(() {
      _submitting = false;
      _uncertain = result.uncertain;
      _message = result.message;
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.runtime,
    builder: (context, _) {
      final enabled = !_submitting && !_uncertain && widget.runtime.ready;
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
            hint: '描述这段会话的使用体验（可选）',
            explanation: '反馈与当前会话关联，记录在会话日志中。',
            onCategory: (category) => setState(() {
              _category = _category == category ? null : category;
            }),
          ),
          bottom: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_message != null || !widget.runtime.ready)
                PocketReveal(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _message ?? '本地服务恢复后可继续提交，填写内容已保留。',
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
