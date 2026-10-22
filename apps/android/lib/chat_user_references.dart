import 'package:material_ui/material_ui.dart';

import 'chat_skills.dart';

enum ChatReferenceKind { session, skill, file, folder }

class ChatUserReference {
  const ChatUserReference(
    this.start,
    this.end,
    this.kind,
    this.label,
    this.value,
  );
  final int start, end;
  final ChatReferenceKind kind;
  final String label, value;
}

/// The original UserText rules resolve overlapping UTF-16 ranges by position,
/// then Session (10), skill (20), path (30). No lookup changes authored text.
List<ChatUserReference> chatUserReferences(
  String text, {
  Iterable<String> skillNames = const [],
  Iterable<String> sessionLabels = const [],
}) {
  final candidates = <ChatUserReference>[
    for (final range in sessionReferenceRanges(text, sessionLabels))
      ChatUserReference(
        range.start,
        range.end,
        ChatReferenceKind.session,
        range.label,
        range.label,
      ),
    for (final range in skillReferenceRanges(text, skillNames))
      ChatUserReference(
        range.start,
        range.end,
        ChatReferenceKind.skill,
        '/${range.name}',
        range.name,
      ),
  ];
  final tokens = RegExp(r'(?<!\S)(@"[^"\n]+"|@[^\s]+)', unicode: true);
  for (final match in tokens.allMatches(text)) {
    final token = match[0]!;
    final raw = token.startsWith('@"')
        ? token
        : token.replaceFirst(RegExp(r'[.,;:!?，。；：！？]+$'), '');
    if (raw.length <= 1) continue;
    final path = raw.substring(1).replaceAll(RegExp(r'^"|"$'), '');
    final segments = path
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty);
    candidates.add(
      ChatUserReference(
        match.start,
        match.start + raw.length,
        path.endsWith('/') ? ChatReferenceKind.folder : ChatReferenceKind.file,
        segments.isEmpty ? raw.substring(1) : segments.last,
        path,
      ),
    );
  }
  candidates.sort((a, b) {
    final start = a.start.compareTo(b.start);
    return start == 0 ? a.kind.index.compareTo(b.kind.index) : start;
  });
  var consumed = 0;
  final resolved = <ChatUserReference>[];
  for (final candidate in candidates) {
    if (candidate.start < consumed) continue;
    resolved.add(candidate);
    consumed = candidate.end;
  }
  return resolved;
}

/// User text remains plain text. Only explicit/recorded reference spans become
/// chips; the surrounding message action owns copying the unchanged original.
class ChatUserText extends StatelessWidget {
  const ChatUserText({
    required this.text,
    required this.storageId,
    this.skillNames = const [],
    this.sessionLabels = const [],
    this.onOpenSkill,
    this.onOpenFile,
    super.key,
  });
  final String text, storageId;
  final List<String> skillNames, sessionLabels;
  final Future<void> Function(String name)? onOpenSkill;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 16, height: 1.6);
    final ranges = chatUserReferences(
      text,
      skillNames: skillNames,
      sessionLabels: sessionLabels,
    );
    if (ranges.isEmpty) return Text(text, style: style);
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, range.start)));
      }
      final open = switch (range.kind) {
        ChatReferenceKind.file => onOpenFile,
        ChatReferenceKind.skill => onOpenSkill,
        _ => null,
      };
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: ChatInlineReference(
            key: ValueKey((storageId, range.start, range.kind, range.value)),
            label: range.label,
            icon: switch (range.kind) {
              ChatReferenceKind.file => Icons.description_outlined,
              ChatReferenceKind.folder => Icons.folder_outlined,
              ChatReferenceKind.session => Icons.chat_bubble_outline_rounded,
              ChatReferenceKind.skill => null,
            },
            hint: switch (range.kind) {
              ChatReferenceKind.file => '打开文件',
              ChatReferenceKind.skill => '查看技能说明',
              _ => null,
            },
            interactive: open != null,
            onOpen: open == null ? null : () => open(range.value),
          ),
        ),
      );
      cursor = range.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}
