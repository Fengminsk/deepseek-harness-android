import 'package:material_ui/material_ui.dart';

import 'chat_feedback.dart';
import 'chat_feedback_projection.dart';
import 'chat_reply_bar.dart';
import 'chat_reply_sources.dart';
import 'chat_reading.dart';
import 'chat_messages.dart' show ChatOpenFile, ChatOpenLink;
import 'chat_plan.dart';
import 'chat_projection.dart';
import 'runtime.dart';
import 'tool_activity_data.dart';

/// Session-owned turn-tail contributions. The timeline only places these rows;
/// original feature projections decide which completed turns have a control.
class ChatTurnExtras {
  ChatTurnExtras({required this.sessionId, RuntimeController? runtime})
    : feedback = runtime == null
          ? null
          : ChatFeedbackController(runtime: runtime, sessionId: sessionId);

  final String sessionId;
  final ChatFeedbackController? feedback;
  final _plans = ChatPlanProjection();
  final _feedback = ChatFeedbackProjection();
  final _planRows = <String, ChatSubmittedPlan>{};
  final _replyRows = <String, ChatReplyClosing>{};
  final _sources = <int, ChatReplySources>{};
  List<ChatEntry> _records = const [];
  List<ChatEntry> rows = const [];
  int revision = 0;
  (int, int)? _observed;

  void reconcile(List<Json> events, List<ChatEntry> entries) {
    _plans.reconcile(events);
    _feedback.reconcile(events);
    final next = (_plans.processedEventCount, _feedback.processedEventCount);
    if (_observed == next) return;
    _observed = next;
    _planRows
      ..clear()
      ..addEntries(_plans.entries.map((plan) => MapEntry(plan.key, plan)));
    _replyRows
      ..clear()
      ..addEntries(
        _feedback.allClosing.map(
          (target) => MapEntry('feedback:${target.turn}', target),
        ),
      );
    final anchors = {for (final event in events) event['seq']: event};
    _records = List.unmodifiable(
      entries.where((entry) => !chatReadingEntry(entry)),
    );
    final byTurn = <int, List<ToolActivity>>{};
    for (final entry in entries) {
      final activity = entry.tool;
      if (activity == null) continue;
      final turn = activity.events
          .where((event) => event['type'] == 'tool/call')
          .map((event) => event['data']?['turn'])
          .whereType<int>()
          .firstOrNull;
      if (turn != null) byTurn.putIfAbsent(turn, () => []).add(activity);
    }
    _sources
      ..clear()
      ..addEntries(
        byTurn.entries.map(
          (entry) =>
              MapEntry(entry.key, ChatReplySources.fromActivities(entry.value)),
        ),
      );
    rows = List.unmodifiable([
      for (final plan in _planRows.values)
        ChatEntry(
          key: plan.key,
          seq: plan.seq,
          kind: ChatEntryKind.notice,
          event: anchors[plan.seq]!,
        ),
      for (final entry in _replyRows.entries)
        ChatEntry(
          key: entry.key,
          seq: entry.value.turnEndSeq,
          kind: ChatEntryKind.notice,
          event: anchors[entry.value.turnEndSeq]!,
        ),
    ]);
    revision++;
  }

  Widget? render(
    BuildContext context,
    String key, {
    ChatOpenFile? onOpenFile,
    ChatOpenLink? onOpenLink,
  }) {
    final plan = _planRows[key];
    if (plan != null) {
      return ChatSubmittedPlanCard(
        plan: plan,
        sessionId: sessionId,
        onOpenFile: onOpenFile,
        onOpenLink: onOpenLink,
      );
    }
    final target = _replyRows[key], controller = feedback;
    if (target == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ChatReplyBar(
        text: target.text,
        feedbackController: target.messageId == null ? null : controller,
        messageId: controller == null ? null : target.messageId,
        sources: _sources[target.turn] ?? ChatReplySources.empty,
        onShare: (text) =>
            RuntimeController.channel.invokeMethod<void>('shareText', text),
        onOpenSource:
            onOpenLink ??
            (uri) => RuntimeController.channel.invokeMethod<void>(
              'openUrl',
              uri.toString(),
            ),
        onInspect: _records.isEmpty
            ? null
            : () => openChatRecords(context, _records),
      ),
    );
  }

  void dispose() => feedback?.dispose();
}
