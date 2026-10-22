import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'workspace_changes.dart';
import 'workspace_change_widgets.dart';
import 'workspace_diff.dart';

/// Original announcement coordinates plus the finished turn's timeline anchor.
/// An announcement is not a summary and never supplies file names or counts.
class ChatChangesTurn {
  const ChatChangesTurn({
    required this.event,
    required this.turn,
    required this.announcementSeq,
  });
  final Json event;
  final int turn, announcementSeq;
  int get seq => event['seq'] as int;
  String get key => 'changes:$turn';
}

class _ChangesTurn {
  Json? end;
  int? announcement;
}

/// Mirrors turn-deliverables' latest workspace/changes announcement per turn.
/// It consumes only the supplied original event window, never fetches a log.
/// Ending with an error or interruption is still a finished turn in DSH.
class ChatChangesProjection {
  final _seen = <Json>[];
  final _turns = <int, _ChangesTurn>{};
  final _rows = <int, ChatChangesTurn>{};
  List<Json>? _source;
  List<ChatChangesTurn> _entries = const [];
  List<ChatChangesTurn> get entries => _entries;
  int revision = 0;
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
      _turns.clear();
      _rows.clear();
      prefix = 0;
    }
    if (prefix == events.length && _entries.length == _rows.length) return;
    for (var at = prefix; at < events.length; at++) {
      final event = events[at];
      final data = event['data'];
      final seq = event['seq'];
      if (data is Map &&
          data['turn'] is int &&
          data['turn'] >= 1 &&
          data['turn'] <= 9007199254740991 &&
          seq is int &&
          seq >= 0 &&
          seq <= 9007199254740991) {
        final turn = data['turn'] as int;
        if (event['type'] == 'workspace/changes' ||
            event['type'] == 'turn/end') {
          final state = _turns.putIfAbsent(turn, _ChangesTurn.new);
          if (event['type'] == 'workspace/changes') state.announcement = seq;
          if (event['type'] == 'turn/end') state.end = event;
          if (state.end != null && state.announcement != null) {
            _rows[turn] = ChatChangesTurn(
              event: state.end!,
              turn: turn,
              announcementSeq: state.announcement!,
            );
          }
        }
      }
      _seen.add(event);
      processedEventCount++;
    }
    _entries = List.unmodifiable(
      _rows.values.toList()..sort((a, b) => a.seq.compareTo(b.seq)),
    );
    revision++;
  }
}

/// Only a served, nonempty summary gets a turn-tail card. The caller injects
/// the original developerTools.enabled preference through [enabled].
class ChatChangesCard extends StatefulWidget {
  const ChatChangesCard({
    required this.controller,
    required this.change,
    required this.enabled,
    super.key,
  });
  final WorkspaceChangesController controller;
  final ChatChangesTurn change;
  final bool enabled;
  @override
  State<ChatChangesCard> createState() => _ChatChangesCardState();
}

class _ChatChangesCardState extends State<ChatChangesCard> {
  bool expanded = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ChatChangesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.change.announcementSeq != widget.change.announcementSeq ||
        oldWidget.enabled != widget.enabled) {
      expanded = false;
      _load();
    }
  }

  void _load() {
    if (widget.enabled) {
      unawaited(widget.controller.loadSummary(widget.change.announcementSeq));
    }
  }

  void _open(int index) {
    Navigator.of(context).push<void>(
      PocketRoute(
        builder: (_) => WorkspaceDiffPage(
          controller: widget.controller,
          seq: widget.change.announcementSeq,
          turn: widget.change.turn,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return ValueListenableBuilder<WorkspaceRead<WorkspaceChangesSummary>>(
      valueListenable: widget.controller.summary(widget.change.announcementSeq),
      builder: (context, state, _) {
        final summary = state.value;
        if (state.phase != WorkspaceReadPhase.ready ||
            summary == null ||
            summary.turn != widget.change.turn ||
            summary.files.isEmpty) {
          return const SizedBox.shrink();
        }
        final single = summary.total == 1 ? summary.files.first : null;
        final visible = expanded
            ? summary.files.length
            : summary.files.length.clamp(0, 4);
        return PocketSection(
          divided: true,
          children: [
            PocketTile(
              leading: const Icon(Icons.difference_outlined),
              title: Text(single?.name ?? '${summary.total} 个文件已更改'),
              subtitle: WorkspaceChangeCounts(
                added: summary.added,
                deleted: summary.deleted,
                binary: single?.binary ?? false,
                oversized: single?.oversized ?? false,
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => _open(0),
            ),
            if (single == null)
              for (var index = 0; index < visible; index++)
                WorkspaceChangedFileTile(
                  file: summary.files[index],
                  onTap: () => _open(index),
                ),
            if (single == null && summary.files.length > 4)
              PocketTile(
                title: Text(
                  expanded ? '收起文件列表' : '查看全部 ${summary.files.length} 个文件',
                ),
                trailing: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                onTap: () => setState(() => expanded = !expanded),
              ),
            if (summary.total > summary.files.length)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Text(
                  '显示 ${summary.files.length} 个文件，共 ${summary.total} 个；行数包含全部改动。',
                ),
              ),
          ],
        );
      },
    );
  }
}
