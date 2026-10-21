import 'chat_projection.dart';
import 'runtime.dart';
import 'tool_activity_data.dart';

/// Display grouping only. Original calls, ordering and results stay untouched.
class ChatToolGroup {
  ChatToolGroup(List<ChatEntry> entries) : entries = List.unmodifiable(entries);
  final List<ChatEntry> entries;
  String get key => 'tool-group:${entries.first.key}';

  String get title => '${entries.length} 项工具调用';
  late final String status = _status();
  String _status() {
    final counts = <ToolActivityPhase, int>{};
    for (final entry in entries) {
      final phase = entry.tool!.phase;
      counts[phase] = (counts[phase] ?? 0) + 1;
    }
    return [
      if (counts[ToolActivityPhase.pending] case final int count)
        '$count 项等待结果',
      if (counts[ToolActivityPhase.failed] case final int count) '$count 项失败',
      if (counts[ToolActivityPhase.interrupted] case final int count)
        '$count 项中断',
      if (counts[ToolActivityPhase.unknown] case final int count) '$count 项待确认',
      if (counts[ToolActivityPhase.completed] case final int count)
        '$count 项已返回',
    ].join(' · ');
  }
}

class ChatDisplayItem {
  const ChatDisplayItem.entry(this.entry, {this.parent}) : group = null;
  const ChatDisplayItem.group(this.group) : entry = null, parent = null;
  final ChatEntry? entry;
  final ChatToolGroup? group;
  final ChatToolGroup? parent;
  String get key => entry?.key ?? group!.key;
}

/// Never group across authored text, notices, or an uncertain turn boundary.
/// PTC descendants already belong to their actual root and are not reparented.
List<ChatDisplayItem> groupChatTools(List<ChatEntry> entries) {
  final display = <ChatDisplayItem>[];
  var index = 0;
  while (index < entries.length) {
    final first = entries[index];
    final turn = _callTurn(first);
    var end = index + 1;
    if (turn != null) {
      while (end < entries.length && _callTurn(entries[end]) == turn) {
        end++;
      }
    }
    if (end - index > 1) {
      display.add(
        ChatDisplayItem.group(ChatToolGroup(entries.sublist(index, end))),
      );
    } else {
      display.add(ChatDisplayItem.entry(first));
    }
    index = end;
  }
  return display;
}

int? _callTurn(ChatEntry entry) {
  final activity = entry.tool;
  if (entry.kind != ChatEntryKind.tool ||
      activity == null ||
      !activity.hasCall) {
    return null;
  }
  for (final event in activity.events) {
    if (event['type'] != 'tool/call') continue;
    final data = event['data'];
    return data is Json && data['turn'] is int ? data['turn'] as int : null;
  }
  return null;
}
