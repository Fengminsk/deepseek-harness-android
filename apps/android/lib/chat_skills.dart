import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection.dart';
import 'entry_motion.dart';
import 'runtime.dart';
import 'text_document_page.dart';
import 'tool_activity_data.dart';
import 'tool_activity_details.dart';
import 'ui.dart';

/// Confirmed names come from this message batch's recorded skill injections,
/// never today's catalog. Mirrors ui-chat's SkillNameProjector: other context
/// is transparent; every other visible node and every turn tail closes a batch.
class ChatSkillNameProjection {
  List<Json>? _events;
  int _eventCount = -1;
  final _names = <int, List<String>>{};
  final _sessionLabels = <int, List<String>>{};

  List<String> namesFor(int messageSeq) => _names[messageSeq] ?? const [];
  List<String> sessionLabelsFor(int messageSeq) =>
      _sessionLabels[messageSeq] ?? const [];

  void reconcile({
    required List<ChatEntry> entries,
    required List<Json> events,
  }) {
    if (identical(_events, events) && _eventCount == events.length) return;
    _events = events;
    _eventCount = events.length;
    _names.clear();
    _sessionLabels.clear();
    final messageSeqs = entries
        .where((entry) => entry.kind == ChatEntryKind.user)
        .map((entry) => entry.seq)
        .toSet();
    final records = <({int seq, bool message, String? name})>[];
    for (final entry in entries) {
      if (entry.kind == ChatEntryKind.user) {
        records.add((seq: entry.seq, message: true, name: null));
      } else if (entry.kind == ChatEntryKind.context) {
        final source = entry.source;
        if (source?['kind'] == 'skill-invocation' &&
            source?['name'] is String &&
            source?['name'] != '') {
          records.add((
            seq: entry.seq,
            message: false,
            name: source!['name'] as String,
          ));
        }
        // Unlike skill batches, the original recall projector binds only the
        // immediately preceding durable seq, never a nearby earlier message.
        final references = source?['references'];
        if (source?['kind'] == 'session-reference' &&
            references is List &&
            messageSeqs.contains(entry.seq - 1)) {
          final labels = <String>[];
          for (final reference in references) {
            if (reference is! Map) continue;
            final label = reference['label'];
            if (label is String &&
                label.isNotEmpty &&
                !labels.contains(label)) {
              labels.add(label);
            }
          }
          if (labels.isNotEmpty) {
            _sessionLabels[entry.seq - 1] = List.unmodifiable(labels);
          }
        }
      } else {
        records.add((seq: entry.seq, message: false, name: null));
      }
    }
    // Successful turn/end events have no generic native notice, but the Web
    // always materializes a turn-tail, including interrupted/error outcomes.
    for (final event in events) {
      if (event['type'] == 'turn/end' && event['seq'] is int) {
        records.add((seq: event['seq'] as int, message: false, name: null));
      }
    }
    records.sort((a, b) => a.seq.compareTo(b.seq));
    final messages = <int>[];
    final names = <String>[];
    void finish() {
      final confirmed = List<String>.unmodifiable(names);
      for (final seq in messages) {
        if (confirmed.isNotEmpty) _names[seq] = confirmed;
      }
      messages.clear();
      names.clear();
    }

    for (final record in records) {
      if (record.message) {
        messages.add(record.seq);
      } else if (record.name case final name?) {
        if (!names.contains(name)) names.add(name);
      } else {
        finish();
      }
    }
    finish();
  }
}

/// Original-text UTF-16 offsets, suitable for merging with other text rules.
class ChatSkillReferenceRange {
  const ChatSkillReferenceRange(this.start, this.end, this.name);
  final int start, end;
  final String name;
}

List<ChatSkillReferenceRange> skillReferenceRanges(
  String text,
  Iterable<String> confirmedNames,
) {
  final names = confirmedNames.toSet();
  if (names.isEmpty) return const [];
  // Match the original UserText rule, including interior/newline tokens. Do
  // not strip punctuation or reinterpret paths such as /review.md as skills.
  return [
    for (final match in RegExp(r'(?<!\S)/([\w-]+)(?!\S)').allMatches(text))
      if (names.contains(match.group(1)))
        ChatSkillReferenceRange(match.start, match.end, match.group(1)!),
  ];
}

class ChatSessionReferenceRange {
  const ChatSessionReferenceRange(this.start, this.end, this.label);
  final int start, end;
  final String label;
}

/// Candidates in original UTF-16 coordinates. Explicit wire spellings are
/// self-identifying; bare labels require the adjacent recorded recall. At each
/// @ the wire spelling wins, then the longest known label, without trimming.
/// Candidates can overlap: the caller merges all rule candidates by start and
/// priority (Session before file at the same start), skipping consumed ranges.
List<ChatSessionReferenceRange> sessionReferenceRanges(
  String text,
  Iterable<String> confirmedLabels,
) {
  final labels = confirmedLabels.where((label) => label.isNotEmpty).toSet();
  final wire = RegExp(r'@\[([^\]\n]+)\]\(dsh-session:[^)\s]+\)', unicode: true);
  final ranges = <ChatSessionReferenceRange>[];
  for (
    var start = text.indexOf('@');
    start >= 0;
    start = text.indexOf('@', start + 1)
  ) {
    final explicit = wire.matchAsPrefix(text, start);
    if (explicit != null) {
      ranges.add(
        ChatSessionReferenceRange(start, explicit.end, explicit.group(1)!),
      );
      continue;
    }
    String? best;
    for (final label in labels) {
      if (text.startsWith(label, start + 1) &&
          (best == null || label.length > best.length)) {
        best = label;
      }
    }
    if (best != null) {
      ranges.add(
        ChatSessionReferenceRange(start, start + 1 + best.length, best),
      );
    }
  }
  return ranges;
}

String _firstLine(String text) => text.split('\n').first;

/// The original skill row reads only call/result data. Metadata and current
/// catalog entries must not rewrite an old name, failure, or instruction body.
class ChatSkillToolPresentation {
  ChatSkillToolPresentation(this.activity);
  final ToolActivity activity;
  static bool supports(ToolActivity activity) =>
      activity.hasCall && activity.name == 'skill';

  late final String name = () {
    final raw =
        activity.argumentsRaw ??
        (activity.argumentsValue == null
            ? ''
            : jsonEncode(activity.argumentsValue));
    try {
      final value = jsonDecode(raw);
      if (value is Json && value['name'] is String && value['name'] != '') {
        return _firstLine(value['name'] as String);
      }
    } on FormatException {
      // A recorded or streaming prefix remains visible as in the Web row.
    }
    return raw.isEmpty ? activity.callId : _firstLine(raw);
  }();

  late final String? output = () {
    if (!activity.hasResult) return null;
    final parts = [
      for (final block in activity.content)
        block is Json && block['type'] == 'text' && block['text'] is String
            ? block['text'] as String
            : const JsonEncoder.withIndent('  ').convert(block),
    ];
    if (parts.isEmpty && activity.error != null) {
      parts.add('${activity.error!['name']}: ${activity.error!['code']}');
    }
    final text = parts.join('\n');
    return text.isEmpty ? null : text;
  }();

  String get summary => switch (activity.phase) {
    ToolActivityPhase.interrupted => '技能加载已中止',
    ToolActivityPhase.failed => output == null ? name : _firstLine(output!),
    _ => name,
  };

  String get status => switch (activity.phase) {
    ToolActivityPhase.pending => '正在加载技能',
    ToolActivityPhase.completed => '技能已加载',
    ToolActivityPhase.failed => '技能加载失败',
    ToolActivityPhase.interrupted => '技能加载已中止',
    ToolActivityPhase.unknown => '技能状态待确认',
  };
}

/// A skill-specific transcript row with exact recorded instructions. Full
/// call inspection remains delegated to the existing original-record viewer.
class ChatSkillToolCard extends StatefulWidget {
  const ChatSkillToolCard({
    super.key,
    required this.activity,
    this.activitySource,
  });
  final ToolActivity activity;
  final ValueListenable<ToolActivity?>? activitySource;
  @override
  State<ChatSkillToolCard> createState() => _ChatSkillToolCardState();
}

class _ChatSkillToolCardState extends State<ChatSkillToolCard> {
  ToolActivityDetailsController? _inspect;
  bool _opening = false;
  int _generation = 0;

  @override
  void didUpdateWidget(ChatSkillToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.identity != widget.activity.identity ||
        oldWidget.activitySource != widget.activitySource) {
      _generation++;
      _opening = false;
      _inspect?.close();
    } else if (widget.activitySource == null) {
      _inspect?.update(widget.activity);
    }
  }

  @override
  void dispose() {
    _generation++;
    if (widget.activitySource == null) _inspect?.close();
    super.dispose();
  }

  Future<void> _open() async {
    if (_opening) return;
    final snapshot = widget.activitySource?.value ?? widget.activity;
    if (widget.activitySource != null && widget.activitySource!.value == null) {
      return;
    }
    final model = ChatSkillToolPresentation(snapshot);
    if (model.output == null) return;
    final generation = _generation;
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push<void>(
        PocketRoute<void>(
          builder: (_) => TextDocumentPage(
            title: '技能说明',
            text: model.output!,
            selectable: true,
            helperText: '${model.name}\n${model.status}',
          ),
        ),
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _openInspection() async {
    if (_inspect != null) return;
    if (widget.activitySource != null && widget.activitySource!.value == null) {
      return;
    }
    final details = ToolActivityDetailsController.open(
      context,
      widget.activity,
      source: widget.activitySource,
    );
    _inspect = details;
    await details.closed;
    if (mounted && identical(_inspect, details)) _inspect = null;
  }

  @override
  Widget build(BuildContext context) {
    final model = ChatSkillToolPresentation(widget.activity);
    final color = widget.activity.phase == ToolActivityPhase.failed
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Semantics(
      label: model.status,
      child: PocketTile(
        key: ValueKey('skill-tool:${widget.activity.identity}'),
        leading: Icon(Icons.auto_stories_outlined, color: color, size: 20),
        title: const Text('加载技能'),
        subtitle: Text(
          model.summary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color),
        ),
        onTap: model.output == null || _opening ? null : _open,
        trailing: model.output == null
            ? null
            : GlassButton(
                icon: Icons.manage_search_rounded,
                label: '查看技能原始调用',
                onPressed: _openInspection,
              ),
      ),
    );
  }
}

/// An inline chip; the owning Session supplies preview activation. Preview
/// copies pass interactive:false and remain labels even with an action present.
class ChatSkillReference extends StatelessWidget {
  const ChatSkillReference({
    super.key,
    required this.name,
    this.interactive = true,
    this.onOpen,
  });
  final String name;
  final bool interactive;
  final Future<void> Function(String name)? onOpen;
  @override
  Widget build(BuildContext context) => ChatInlineReference(
    label: '/$name',
    hint: '查看技能说明',
    interactive: interactive,
    onOpen: onOpen == null ? null : () => onOpen!(name),
  );
}

/// Shared inline reference material for recorded skill/file/folder/Session
/// tokens. The owner supplies a stable key tied to the source Session/message
/// when callbacks can change between otherwise identically named references.
class ChatInlineReference extends StatefulWidget {
  const ChatInlineReference({
    super.key,
    required this.label,
    this.icon,
    this.hint,
    this.interactive = true,
    this.onOpen,
  });
  final String label;
  final IconData? icon;
  final String? hint;
  final bool interactive;
  final Future<void> Function()? onOpen;
  @override
  State<ChatInlineReference> createState() => _ChatInlineReferenceState();
}

class _ChatInlineReferenceState extends State<ChatInlineReference> {
  bool _busy = false, _failed = false;
  int _generation = 0;

  @override
  void didUpdateWidget(ChatInlineReference oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Callback closures routinely change during unrelated transcript builds.
    // Keep the pending guard for the same reference; a different owner uses a
    // different widget key, while these changes replace the reference itself.
    if (oldWidget.label != widget.label ||
        oldWidget.icon != widget.icon ||
        oldWidget.interactive != widget.interactive ||
        (oldWidget.onOpen == null) != (widget.onOpen == null)) {
      _generation++;
      _busy = _failed = false;
    }
  }

  Future<void> _open() async {
    if (_busy || !widget.interactive || widget.onOpen == null) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.onOpen!();
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.interactive && widget.onOpen != null && !_busy;
    final color = _failed ? colors.error : colors.primary;
    return PocketReveal(
      child: Semantics(
        label: widget.label,
        hint: _failed ? '未能打开，点按重试' : widget.hint,
        button: widget.interactive && widget.onOpen != null,
        child: FocusableActionDetector(
          enabled: enabled,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                unawaited(_open());
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: enabled ? _open : null,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (widget.icon != null)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Icon(widget.icon, size: 14, color: color),
                          ),
                        ),
                      TextSpan(text: widget.label),
                    ],
                  ),
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
