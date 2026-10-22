import 'package:material_ui/material_ui.dart';

import 'chat_projection.dart';
import 'chat_progress.dart';
import 'runtime.dart';
import 'tool_activity_data.dart';
import 'tool_activity_details.dart';
import 'tool_activity_presentation.dart';

/// Display grouping only. Original calls, ordering and results stay untouched.
class ChatToolGroup {
  ChatToolGroup(List<ChatEntry> entries) : entries = List.unmodifiable(entries);
  final List<ChatEntry> entries;
  String get key => 'tool-group:${entries.first.key}';

  String get family => toolActivityFamily(entries.first.tool!);
  late final int pendingCount = entries
      .where((entry) => entry.tool!.phase == ToolActivityPhase.pending)
      .length;
  late final int attentionCount = entries
      .where((entry) => toolActivityNeedsAttention(entry.tool!))
      .length;
  late final int unknownCount = entries
      .where((entry) => entry.tool!.phase == ToolActivityPhase.unknown)
      .length;
  bool get needsAttention => attentionCount > 0 || unknownCount > 0;
  String get countUnit =>
      family == 'shell' ? '条命令' : '次${toolActivityName(entries.first.tool!)}';
  // A group can contain both settled and pending calls. Never label its full
  // count as running when only some members are still awaiting a result.
  String get titlePrefix => needsAttention
      ? ''
      : pendingCount == entries.length
      ? '正在调用 '
      : pendingCount > 0
      ? ''
      : '已运行 ';
  String get titleSuffix {
    final parts = [
      if (attentionCount > 0) '$attentionCount 项需查看',
      if (unknownCount > 0) '$unknownCount 项待确认',
      if (pendingCount > 0 &&
          (pendingCount < entries.length || needsAttention))
        '$pendingCount 项等待结果',
    ];
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }

  String get title {
    return '$titlePrefix${entries.length} $countUnit$titleSuffix';
  }

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
      while (end < entries.length &&
          _callTurn(entries[end]) == turn &&
          toolActivityFamily(entries[end].tool!) ==
              toolActivityFamily(first.tool!)) {
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

/// One line in the conversation; expanded members remain independent calls.
class ChatToolGroupHeader extends StatelessWidget {
  const ChatToolGroupHeader({
    required this.group,
    required this.expanded,
    required this.onToggle,
    super.key,
  });
  final ChatToolGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) {
    final ink = group.needsAttention
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: ink);
    return ToolActivitySummaryRow(
      opened: expanded,
      label: '${group.title}，${group.status}',
      color: ink,
      icon: switch (group.family) {
        'shell' => Icons.terminal_rounded,
        'web_search' || 'web_fetch' => Icons.language_rounded,
        'file-search' => Icons.search_rounded,
        'read' || 'write' || 'edit' => Icons.description_outlined,
        _ => Icons.build_outlined,
      },
      onTap: onToggle,
      title: ExcludeSemantics(
        child: Row(
          children: [
            if (group.titlePrefix.isNotEmpty)
              Text(group.titlePrefix, style: style),
            ChatRollingCount(value: group.entries.length, style: style),
            Expanded(
              child: Text(
                ' ${group.countUnit}${group.titleSuffix}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
