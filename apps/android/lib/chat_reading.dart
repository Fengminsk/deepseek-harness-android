import 'package:material_ui/material_ui.dart';

import 'chat_messages.dart';
import 'chat_projection.dart';
import 'ui.dart';

/// Internal inputs are available for inspection without interrupting reading.
/// Authored replies, tool activity, command results and failures stay ordered.
bool chatReadingEntry(ChatEntry entry) => switch (entry.kind) {
  ChatEntryKind.systemPrompt || ChatEntryKind.context => false,
  ChatEntryKind.unknown => entry.error,
  _ => true,
};

Future<void> openChatRecords(BuildContext context, List<ChatEntry> entries) =>
    Navigator.of(context).push<void>(
      PocketRoute(
        builder: (_) => ChatRecordsPage(entries: List.unmodifiable(entries)),
      ),
    );

class ChatRecordsPage extends StatelessWidget {
  const ChatRecordsPage({required this.entries, super.key});
  final List<ChatEntry> entries;
  @override
  Widget build(BuildContext context) {
    final records = entries.where((entry) => !chatReadingEntry(entry)).toList();
    return PocketScaffold(
      title: const Text('会话记录'),
      body: records.isEmpty
          ? const PocketEmpty(child: Text('暂无额外记录'))
          : PocketList.builder(
              itemCount: records.length,
              itemBuilder: (_, index) => ChatMessage(
                entry: records[index],
                storageId: 'record:${records[index].key}',
              ),
            ),
    );
  }
}
