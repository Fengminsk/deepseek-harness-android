import 'chat_projection.dart';
import 'runtime.dart';
import 'tool_activity_data.dart';
import 'tool_activity_presentation.dart';

String? chatReasoningText(List<dynamic> content) {
  final parts = <String>[];
  for (final block in content) {
    if (block is Json &&
        block['type'] == 'reasoning' &&
        block['text'] is String &&
        (block['text'] as String).trim().isNotEmpty) {
      parts.add(block['text'] as String);
    }
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}

/// One original Turn's process, independent of its authored answer. Calls keep
/// their identities and PTC parentage; no prose or idle state implies success.
class ChatExecutionChain {
  ChatExecutionChain(this.turn, {required this.active, this.start, this.end});
  final int turn;
  final bool active;
  final Json? start, end;
  final List<ChatEntry> entries = [];
  String get key => 'execution:$turn';
  late final int attentionCount = entries
      .where(
        (entry) =>
            entry.tool != null && toolActivityNeedsAttention(entry.tool!),
      )
      .length;
  late final bool uncertain = entries.any(
    (entry) => entry.tool != null && _uncertainCall(entry.tool!),
  );
  bool _uncertainCall(ToolActivity activity) =>
      activity.phase == ToolActivityPhase.unknown ||
      (!active && activity.phase == ToolActivityPhase.pending) ||
      activity.children.any(_uncertainCall);
  String? get reason {
    final reason = end?['data']?['reason'];
    return reason is Map && reason['kind'] is String
        ? reason['kind'] as String
        : null;
  }

  bool get completed =>
      reason == 'completed' && !uncertain && attentionCount == 0;
  bool get needsAttention =>
      attentionCount > 0 ||
      const ['error', 'interrupted', 'max-tokens'].contains(reason);
  String get title {
    if (active && end == null) return '正在规划和执行任务';
    if (completed) return '已完成';
    if (reason == 'completed' && attentionCount > 0) {
      return '已结束 · $attentionCount 项需查看';
    }
    return switch (reason) {
      'error' || 'interrupted' || 'max-tokens' => '未完成',
      'aborted' => '已停止',
      'blocked' => '已暂停',
      'forked' => '已分支',
      _ => attentionCount > 0 ? '状态待确认 · $attentionCount 项需查看' : '状态待确认',
    };
  }

  String? get duration => chatEventDuration(start, end);
}

String? chatEventDuration(Json? start, Json? end) {
  final a = start?['time'], b = end?['time'];
  if (a is! num || b is! num || b < a || !a.isFinite || !b.isFinite) {
    return null;
  }
  final seconds = ((b - a) / 1000).round();
  return seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}m ${seconds % 60}s';
}

class ChatExecutionDisplay {
  const ChatExecutionDisplay.entry(this.entry, {this.hideReasoning = false})
    : chain = null,
      parent = null,
      continuation = false,
      last = false;
  const ChatExecutionDisplay.chain(this.chain)
    : entry = null,
      parent = null,
      hideReasoning = false,
      continuation = false,
      last = false;
  const ChatExecutionDisplay.step(
    this.entry,
    this.parent, {
    this.continuation = false,
    this.last = false,
  }) : chain = null,
       hideReasoning = false;
  final ChatEntry? entry;
  final ChatExecutionChain? chain, parent;
  final bool hideReasoning, continuation, last;
  String get key =>
      chain?.key ?? (parent == null ? entry!.key : 'process:${entry!.key}');
}

/// The header occupies the first process position. Within it, steps retain log
/// order. User messages, answers, files and review controls remain reading rows.
List<ChatExecutionDisplay> groupChatExecution(
  List<ChatEntry> entries,
  List<Json> events, {
  int? activeTurn,
  int? liveTurn,
  int? liveStep,
}) {
  final starts = <int, Json>{}, ends = <int, Json>{};
  final todoTurns = <int, int>{};
  int? currentTurn;
  for (final event in events) {
    final data = event['data'];
    if (data is! Map) continue;
    final turn = data['turn'];
    if (event['type'] == 'turn/start' && turn is int) {
      currentTurn = turn;
      starts[turn] = event;
    }
    if (event['type'] == 'todo/write' &&
        event['seq'] is int &&
        currentTurn != null) {
      todoTurns[event['seq'] as int] = currentTurn;
    }
    if (event['type'] == 'turn/end' && turn is int) {
      ends[turn] = event;
      if (currentTurn == turn) currentTurn = null;
    }
  }
  final chains = <int, ChatExecutionChain>{};
  final display = <ChatExecutionDisplay>[];
  void add(int turn, ChatEntry entry) {
    final chain = chains.putIfAbsent(turn, () {
      final chain = ChatExecutionChain(
        turn,
        active: activeTurn == turn && !ends.containsKey(turn),
        start: starts[turn],
        end: ends[turn],
      );
      display.add(ChatExecutionDisplay.chain(chain));
      return chain;
    });
    chain.entries.add(entry);
  }

  for (final entry in entries) {
    final activity = entry.tool;
    final reasoning =
        entry.kind == ChatEntryKind.assistant &&
        chatReasoningText(entry.content) != null;
    int? turn;
    if (activity != null) {
      // Orphan results and uncertain coordinates stay independently inspectable.
      for (final event in activity.events) {
        if (event['type'] == 'tool/call' && event['data']?['turn'] is int) {
          turn = event['data']['turn'] as int;
          break;
        }
      }
    } else if (reasoning) {
      turn = entry.turn;
    } else if (entry.key.startsWith('todo:')) {
      turn = todoTurns[entry.seq];
    } else if (entry.key.startsWith('submitted-plan:')) {
      turn = entry.turn;
    } else if (entry.key.startsWith('turn-end:')) {
      final value = entry.event['data']?['turn'];
      // Keep a standalone failure notice when there is no process to fold.
      if (value is int && chains.containsKey(value)) turn = value;
    }
    if (turn != null) {
      add(turn, entry);
      if (reasoning &&
          entry.content.any(
            (block) => block is! Json || block['type'] != 'reasoning',
          )) {
        display.add(ChatExecutionDisplay.entry(entry, hideReasoning: true));
      }
    } else {
      display.add(ChatExecutionDisplay.entry(entry));
    }
  }
  if (liveTurn != null && liveStep != null) {
    add(
      liveTurn,
      ChatEntry(
        key: 'live-reasoning:$liveTurn:$liveStep',
        seq: -1,
        kind: ChatEntryKind.assistant,
        event: const {},
        turn: liveTurn,
        step: liveStep,
      ),
    );
  }
  for (final chain in chains.values) {
    if (chain.completed) {
      chain.entries.add(
        ChatEntry(
          key: 'execution-end:${chain.turn}',
          seq: chain.end!['seq'] as int,
          kind: ChatEntryKind.notice,
          event: chain.end!,
          title: '已完成',
        ),
      );
    }
  }
  return display;
}
