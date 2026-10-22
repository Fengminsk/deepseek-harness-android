import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'chat_goal_plan_state.dart';
import 'chat_messages.dart' show PocketMarkdown, ChatOpenLink, ChatOpenFile;
import 'entry_motion.dart';
import 'runtime.dart';
import 'ui.dart';

/// The complete plan attached to one original exit_plan_mode invocation.
/// A submitted document is not evidence of approval or execution.
class ChatSubmittedPlan {
  const ChatSubmittedPlan({
    required this.callId,
    required this.title,
    required this.markdown,
    required this.anchorSeq,
    required this.turn,
    this.closingSeq,
  });
  final String callId, title, markdown;
  final int anchorSeq;
  final int? turn, closingSeq;
  String get key => 'submitted-plan:$callId';
  int get seq => closingSeq ?? anchorSeq;

  static ChatSubmittedPlan? fromEvent(Json event, {int? turn}) {
    final type = event['type'];
    if (!const [
      'tool/call',
      'tool/ptc-dispatch-start',
      'tool/ptc-dispatch',
    ].contains(type)) {
      return null;
    }
    final data = event['data'];
    if (data is! Map ||
        data['name'] != 'exit_plan_mode' ||
        event['seq'] is! int) {
      return null;
    }
    final id = data[type == 'tool/call' ? 'callId' : 'subCallId'];
    if (id is! String || id.isEmpty) return null;
    dynamic args = data['arguments'];
    if (type == 'tool/call') {
      if (args is! String) return null;
      try {
        args = jsonDecode(args);
      } on FormatException {
        return null;
      }
    }
    if (args is! Map || args['plan'] is! String) return null;
    final text = args['plan'] as String;
    // Same acceptance rule as ui-plan/submittedPlan, not a guessed first line.
    final title = RegExp(r'^#\s+(\S[^\r\n]*)')
        .firstMatch(text.trim())
        ?.group(1);
    if (title == null) return null;
    return ChatSubmittedPlan(
      callId: id,
      title: title,
      markdown: text,
      anchorSeq: event['seq'] as int,
      turn: data['turn'] is int ? data['turn'] as int : turn,
    );
  }

  ChatSubmittedPlan closedAt(int seq) => ChatSubmittedPlan(
    callId: callId,
    title: title,
    markdown: markdown,
    anchorSeq: anchorSeq,
    turn: turn,
    closingSeq: seq,
  );
}

/// Read-only transcript projection. PTC settlement retains the first document;
/// rejected and dismissed reviews remain valid submitted plans. Only ended
/// turns publish cards, matching the original turn-tail slot.
class ChatPlanProjection {
  final _seen = <Json>[];
  final _plans = <String, ChatSubmittedPlan>{};
  final _ends = <int, int>{};
  List<Json>? _source;
  int? _turn;
  List<ChatSubmittedPlan> entries = const [];
  int processedEventCount = 0;

  void reconcile(List<Json> events) {
    if (identical(_source, events) && _seen.length == events.length) return;
    var prefix = 0;
    if (identical(_source, events) &&
        events.length >= _seen.length &&
        (_seen.isEmpty || identical(events[_seen.length - 1], _seen.last))) {
      prefix = _seen.length;
    } else {
      while (prefix < _seen.length &&
          prefix < events.length &&
          identical(_seen[prefix], events[prefix])) {
        prefix++;
      }
    }
    _source = events;
    if (prefix != _seen.length) {
      _seen.clear();
      _plans.clear();
      _ends.clear();
      _turn = null;
      prefix = 0;
    }
    for (var index = prefix; index < events.length; index++) {
      final event = events[index], data = events[index]['data'];
      if (data is Map && data['turn'] is int) {
        if (event['type'] == 'turn/start' || event['type'] == 'step/start') {
          _turn = data['turn'] as int;
        }
        if (event['type'] == 'turn/end' && event['seq'] is int) {
          _ends[data['turn'] as int] = event['seq'] as int;
        }
      }
      final plan = ChatSubmittedPlan.fromEvent(event, turn: _turn);
      if (plan != null) _plans.putIfAbsent(plan.callId, () => plan);
      _seen.add(event);
      processedEventCount++;
    }
    entries = List.unmodifiable(
      [
        for (final plan in _plans.values)
          if (_ends[plan.turn] != null) plan.closedAt(_ends[plan.turn]!),
      ]..sort((a, b) {
        final closing = a.seq.compareTo(b.seq);
        return closing == 0 ? a.anchorSeq.compareTo(b.anchorSeq) : closing;
      }),
    );
  }
}

class ChatPlanDock extends StatelessWidget {
  const ChatPlanDock({required this.controller, super.key});
  final ChatGoalPlanController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final failure = controller.actionKind == 'plan'
          ? controller.actionError
          : null;
      if (controller.plan?.target != true && failure == null) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: PocketReveal(
          child: GlassSurface(
            radius: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PocketTile(
                  leading: const Icon(Icons.edit_note_rounded, size: 22),
                  title: Text(
                    controller.plan?.target == true ? '计划模式' : '计划模式操作未确认',
                  ),
                  subtitle: !controller.fresh
                      ? const Text('状态待确认')
                      : controller.plan?.pending == true
                      ? const Text('将在下一步生效')
                      : null,
                  trailing: GlassButton(
                    icon: Icons.close_rounded,
                    label: '退出计划模式',
                    onPressed:
                        controller.canMutate && controller.plan?.target == true
                        ? () => controller.setPlan(false)
                        : null,
                  ),
                  onTap: () => openChatPlanMode(context, controller),
                ),
                if (failure != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Text(failure),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> openChatPlanMode(
  BuildContext context,
  ChatGoalPlanController controller,
) => Navigator.of(context).push<void>(
  PocketRoute(builder: (_) => ChatPlanModePage(controller: controller)),
);

class ChatPlanModePage extends StatelessWidget {
  const ChatPlanModePage({required this.controller, super.key});
  final ChatGoalPlanController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('计划模式'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新计划模式',
        onPressed: controller.busy || controller.loading
            ? null
            : controller.refresh,
      ),
      body: PocketList(
        children: [
          PocketSection(
            children: [
              if (controller.plan == null)
                PocketRow(
                  icon: Icons.edit_note_rounded,
                  title: controller.loading ? '正在读取计划模式' : '启用计划模式',
                  subtitle: '先梳理步骤，提交计划后由你审核。',
                  onTap: controller.canMutate
                      ? () => controller.setPlan(true)
                      : null,
                )
              else
                PocketSwitchRow(
                  title: const Text('先制定计划'),
                  subtitle: Text(
                    controller.plan?.pending == true
                        ? '将在下一步生效'
                        : '先梳理步骤，提交计划后由你审核。',
                  ),
                  value: controller.plan?.target ?? false,
                  onChanged: controller.canMutate && controller.plan != null
                      ? controller.setPlan
                      : null,
                ),
            ],
          ),
          if (controller.busy)
            const Padding(padding: EdgeInsets.all(20), child: Text('正在更新…')),
          for (final text in [controller.error, controller.actionError])
            if (text != null)
              Padding(padding: const EdgeInsets.all(20), child: Text(text)),
        ],
      ),
    ),
  );
}

class ChatSubmittedPlanCard extends StatelessWidget {
  const ChatSubmittedPlanCard({
    required this.plan,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
    super.key,
  });
  final ChatSubmittedPlan plan;
  final String? sessionId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  @override
  Widget build(BuildContext context) => PocketReveal(
    child: PocketTile(
      leading: const Icon(Icons.article_outlined),
      title: Text(plan.title),
      subtitle: const Text('已提交的计划'),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () => Navigator.of(context).push<void>(
        PocketRoute(
          builder: (_) => ChatPlanDocumentPage(
            title: plan.title,
            markdown: plan.markdown,
            sessionId: sessionId,
            onOpenLink: onOpenLink,
            onOpenFile: onOpenFile,
          ),
        ),
      ),
    ),
  );
}

/// Used by both persisted cards and a pending plan-review question. This viewer
/// has no Agent, approval, command or mutation dependency.
class ChatPlanDocumentPage extends StatelessWidget {
  const ChatPlanDocumentPage({
    required this.title,
    required this.markdown,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
    super.key,
  });
  final String title, markdown;
  final String? sessionId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    body: PocketList(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
          child: PocketMarkdown(
            data: markdown,
            sessionId: sessionId,
            onOpenLink: onOpenLink,
            onOpenFile: onOpenFile,
          ),
        ),
      ],
    ),
  );
}
