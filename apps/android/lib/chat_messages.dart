import 'dart:async';
import 'dart:convert';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:markdown/markdown.dart' as md;

import 'chat_message_actions.dart';
import 'chat_projection.dart';
import 'chat_deliverables.dart';
import 'chat_changes.dart';
import 'chat_skills.dart';
import 'chat_tool_groups.dart';
import 'chat_user_references.dart';
import 'chat_turn_extras.dart';
import 'chat_workflow_runs.dart';
import 'chat_reading.dart';
import 'chat_progress.dart';
import 'chat_stream_reveal.dart';
import 'tool_activity_details.dart' show ToolActivitySummaryRow;
import 'entry_motion.dart';
import 'runtime.dart';
import 'tool_activity.dart';
import 'ui.dart';
import 'workspace_changes.dart';

typedef ChatOpenLink = Future<void> Function(Uri uri);
typedef ChatOpenFile = Future<void> Function(ChatFileLink file);
typedef ChatOpenAttachment = Future<void> Function(Json attachment);

@immutable
class ChatFileLink {
  const ChatFileLink({required this.sessionId, required this.path, this.line});
  final String sessionId, path;
  final int? line;
}

/// Mirrors ui-primitives/markdown/file-link.ts and workspace-path/file-address.ts.
/// Paths remain unresolved: only the original Session Host decides their scope.
ChatFileLink? chatFileLink(String value, {required String sessionId}) {
  if (sessionId.isEmpty) return null;
  const resourcePrefix = 'dsh-resource://file/session/';
  try {
    if (value.startsWith(resourcePrefix)) {
      final end = value.indexOf(RegExp(r'[?#]'));
      final segments = value
          .substring(resourcePrefix.length, end < 0 ? null : end)
          .split('/');
      if (segments.length < 2 || segments.first.isEmpty) return null;
      final owner = Uri.decodeComponent(segments.first);
      if (owner != sessionId) return null;
      return ChatFileLink(
        sessionId: owner,
        path: segments.skip(1).map(Uri.decodeComponent).join('/'),
      );
    }
    final hash = value.indexOf('#');
    final destination = hash < 0 ? value : value.substring(0, hash);
    if (destination.contains('?')) return null;
    final path = Uri.decodeComponent(destination);
    if (path.isEmpty ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) ||
        RegExp(r'^[\\/]{2}').hasMatch(path) ||
        (RegExp(r'^[a-z][a-z\d+.-]*:', caseSensitive: false).hasMatch(path) &&
            !RegExp(r'^[a-z]:[\\/]', caseSensitive: false).hasMatch(path))) {
      return null;
    }
    if (hash < 0) return ChatFileLink(sessionId: sessionId, path: path);
    final match = RegExp(r'^L([1-9]\d*)(?:-L([1-9]\d*))?$')
        .firstMatch(value.substring(hash + 1));
    if (match == null) return null;
    final line = int.tryParse(match[1]!);
    final end = int.tryParse(match[2] ?? match[1]!);
    const maxSafeInteger = 9007199254740991;
    if (line == null ||
        end == null ||
        line > maxSafeInteger ||
        end > maxSafeInteger ||
        end < line) {
      return null;
    }
    return ChatFileLink(sessionId: sessionId, path: path, line: line);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// Only ordinary web destinations may reach MainActivity.openUrl. Relative
/// document paths and content/file/intent URLs require an explicit file flow.
Uri? chatExternalUri(String destination) {
  if (RegExp(r'[\x00-\x20\x7f]').hasMatch(destination)) return null;
  final uri = Uri.tryParse(destination);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

/// An attempt-correlated snapshot from the original assistant stream. The
/// carrier owns accumulation and retries; rendering never joins text by guess.
class ChatLiveMessage {
  const ChatLiveMessage({
    required this.identity,
    required this.content,
    required this.turn,
    required this.step,
    this.interrupted = false,
    this.unconfirmed = false,
  });
  final String identity;
  final List<dynamic> content;
  final int turn, step;
  final bool interrupted, unconfirmed;
}

/// Lazy transcript sharing PocketScaffold's floating chrome insets.
class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    required this.sessionId,
    required this.projection,
    required this.controller,
    this.events = const [],
    this.runtime,
    this.running = false,
    this.onOpenSkill,
    this.live,
    this.footer,
    this.onOpenLink,
    this.onOpenFile,
    this.onOpenAttachment,
    this.onOpenImage,
    this.onBranch,
    super.key,
  });
  final String sessionId;
  final RuntimeController? runtime;
  final bool running;
  final Future<void> Function(String name)? onOpenSkill;
  final ChatProjection projection;
  final ScrollController controller;

  /// Original loaded Session window, including log-only todo/present events.
  final List<Json> events;
  final ChatLiveMessage? live;
  final Widget? footer;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  final ChatOpenAttachment? onOpenAttachment;
  final ChatOpenAttachment? onOpenImage;
  final Future<String?> Function(int atSeq)? onBranch;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline>
    with TickerProviderStateMixin {
  final _sources = <String, ValueNotifier<ToolActivity?>>{};
  final _expanded = <String, bool>{};
  final _motions = <String, AnimationController>{};
  List<ChatDisplayItem> _groups = const [];
  List<ChatDisplayItem> _display = const [];
  final _positions = <String, int>{};
  final _displayKeys = <String, String>{};
  ChatArtifactsProjection _artifacts = ChatArtifactsProjection();
  final _artifactRows = <String, ChatArtifact>{};
  ChatChangesProjection _changes = ChatChangesProjection();
  ChatSkillNameProjection _references = ChatSkillNameProjection();
  ChatWorkflowRunProjection _workflows = ChatWorkflowRunProjection();
  final _workflowRows = <String, WorkflowRunRecord>{};
  WorkspaceChangesController? _changesController;
  late ChatTurnExtras _extras;
  List<ToolActivity> _progressCalls = const [];
  final _changeRows = <String, ChatChangesTurn>{};
  (ChatProjection, int, int, int, int, int, int, int?)? _observed;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _attachChanges();
  }

  void _attachChanges() {
    final runtime = widget.runtime;
    _extras = ChatTurnExtras(runtime: runtime, sessionId: widget.sessionId);
    if (runtime == null) return;
    _changesController = WorkspaceChangesController(
      runtime: runtime,
      sessionId: widget.sessionId,
    )..addListener(_changesChanged);
  }

  void _changesChanged() {
    if (mounted) setState(() {});
  }

  void _detachChanges() {
    _extras.dispose();
    _changesController?.removeListener(_changesChanged);
    _changesController?.dispose();
    _changesController = null;
  }

  @override
  void didUpdateWidget(ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.runtime != widget.runtime) {
      _detachChanges();
      _attachChanges();
      _observed = null;
    }
    if (oldWidget.sessionId != widget.sessionId) {
      _retire(_sources.values.toList());
      _sources.clear();
      _expanded.clear();
      _disposeMotions();
      _artifacts = ChatArtifactsProjection();
      _changes = ChatChangesProjection();
      _references = ChatSkillNameProjection();
      _workflows = ChatWorkflowRunProjection();
      _artifactRows.clear();
      _changeRows.clear();
      _workflowRows.clear();
      _observed = null;
      _generation++;
    }
  }

  void _retire(List<ValueNotifier<ToolActivity?>> sources) {
    // Route listeners may dirty the overlay; never notify during a row build.
    scheduleMicrotask(() {
      for (final source in sources) {
        source.value = null;
        source.dispose();
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    _detachChanges();
    _retire(_sources.values.toList());
    _disposeMotions();
    super.dispose();
  }

  void _disposeMotions() {
    for (final motion in _motions.values) {
      motion.dispose();
    }
    _motions.clear();
  }

  void _synchronize() {
    final projection = widget.projection;
    _artifacts.reconcile(widget.events);
    _changes.reconcile(widget.events);
    _references.reconcile(entries: projection.entries, events: widget.events);
    _workflows.reconcile(widget.events);
    _extras.reconcile(widget.events, widget.projection.entries);
    final stamp = (
      projection,
      projection.processedEventCount,
      projection.entries.length,
      _artifacts.revision,
      _changes.revision,
      _extras.revision,
      _workflows.revision,
      widget.live?.turn,
    );
    if (_observed == stamp) return;
    _observed = stamp;
    final activeTurn = _activeProgressTurn();
    _progressCalls = projection.entries
        .where(
          (entry) =>
              activeTurn != null &&
              entry.tool != null &&
              entry.tool!.events.any(
                (event) =>
                    event['type'] == 'tool/call' &&
                    (event['data'] as Json?)?['turn'] == activeTurn,
              ),
        )
        .map((entry) => entry.tool)
        .whereType<ToolActivity>()
        .toList();
    _changeRows
      ..clear()
      ..addEntries(_changes.entries.map((entry) => MapEntry(entry.key, entry)));
    _artifactRows
      ..clear()
      ..addEntries(
        _artifacts.entries.map((entry) => MapEntry(entry.key, entry)),
      );
    _workflowRows
      ..clear()
      ..addEntries(
        _workflows.records.map((record) => MapEntry(record.key, record)),
      );
    final entries = [
      ...projection.entries.where(chatReadingEntry),
      ..._extras.rows,
      for (final change in _changes.entries)
        ChatEntry(
          key: change.key,
          seq: change.seq,
          kind: ChatEntryKind.notice,
          event: change.event,
        ),
      for (final artifact in _artifacts.entries)
        ChatEntry(
          key: artifact.key,
          seq: artifact.seq,
          kind: ChatEntryKind.notice,
          event: artifact.event,
        ),
      for (final workflow in _workflows.records)
        ChatEntry(
          key: workflow.key,
          seq: workflow.seq,
          kind: ChatEntryKind.notice,
          event: workflow.event,
        ),
    ];
    final orderByKey = {
      for (var index = 0; index < entries.length; index++)
        entries[index].key: index,
    };
    entries.sort((a, b) {
      final order = a.seq.compareTo(b.seq);
      // A turn/end error or interruption notice precedes that turn's files.
      if (order != 0) return order;
      return orderByKey[a.key]!.compareTo(orderByKey[b.key]!);
    });
    _groups = groupChatTools(entries);
    final snapshots = <String, ToolActivity>{};
    for (final row in projection.entries) {
      final activity = row.tool;
      if (activity == null) continue;
      snapshots[activity.identity] = activity;
      _sources.putIfAbsent(activity.identity, () => ValueNotifier(activity));
    }
    final retired = <ValueNotifier<ToolActivity?>>[];
    for (final key in _sources.keys.toList()) {
      if (!snapshots.containsKey(key)) retired.add(_sources.remove(key)!);
    }
    _retire(retired);
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      for (final entry in snapshots.entries) {
        final source = _sources[entry.key];
        if (source != null && !identical(source.value, entry.value)) {
          source.value = entry.value;
        }
      }
    });
    for (final item in _groups) {
      final group = item.group;
      if (group == null || _expanded.containsKey(group.key)) continue;
      _expanded[group.key] =
          PageStorage.maybeOf(context)?.readState(
            context,
            identifier: '${widget.sessionId}:${group.key}',
          ) ==
          true;
    }
    _flatten();
  }

  int? _activeProgressTurn() {
    int? observedCallTurn;
    // The user bubble is not a turn boundary: a runtime/context message can
    // initiate another turn without a new human message. Prefer the newest
    // durable turn/start, and do not reuse the previous turn while a freshly
    // submitted human message is waiting for its start event.
    for (final event in widget.events.reversed) {
      final data = event['data'] as Json?;
      if (event['type'] == 'turn/start') return data?['turn'] as int?;
      if (event['type'] == 'turn/end') return observedCallTurn;
      if (event['type'] == 'tool/call') {
        observedCallTurn ??= data?['turn'] as int?;
      }
      if (event['type'] == 'user/message' &&
          (data?['source'] as Json?)?['kind'] == 'user') {
        return observedCallTurn;
      }
    }
    return observedCallTurn ?? widget.live?.turn;
  }

  void _flatten() {
    _display = [
      for (final item in _groups) ...[
        item,
        if (item.group != null &&
            (_expanded[item.key] == true ||
                (_motions[item.key]?.value ?? 0) > 0))
          for (final row in item.group!.entries)
            ChatDisplayItem.entry(row, parent: item.group),
      ],
    ];
    _positions.clear();
    _displayKeys.clear();
    final seenAssistantSteps = <(int, int)>{};
    for (var i = 0; i < _display.length; i++) {
      final item = _display[i];
      final row = item.entry;
      var identity = item.key;
      if (row != null &&
          row.kind == ChatEntryKind.assistant &&
          row.turn != null &&
          row.step != null &&
          seenAssistantSteps.add((row.turn!, row.step!))) {
        identity = 'assistant-step:${row.turn}:${row.step}';
      }
      if (row != null) _displayKeys[row.key] = identity;
      _positions[identity] = i;
    }
  }

  void _toggle(ChatToolGroup group) {
    final wasExpanded = _expanded[group.key] == true;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final motion = _motions.putIfAbsent(group.key, () {
      final controller = AnimationController(
        vsync: this,
        value: wasExpanded ? 1 : 0,
        duration: const Duration(milliseconds: 220),
      );
      controller.addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted) setState(_flatten);
      });
      return controller;
    });
    setState(() {
      _expanded[group.key] = !wasExpanded;
      if (reduced) motion.value = wasExpanded ? 0 : 1;
      _flatten();
    });
    if (!reduced) {
      if (wasExpanded) {
        motion.reverse();
      } else {
        motion.forward();
      }
    }
    PageStorage.maybeOf(context)?.writeState(
      context,
      _expanded[group.key],
      identifier: '${widget.sessionId}:${group.key}',
    );
  }

  @override
  Widget build(BuildContext context) {
    _synchronize();
    final rows = _display;
    final stream = widget.live;
    final sessionId = widget.sessionId;
    final footer = widget.footer;
    final showLive =
        stream != null &&
        !widget.projection.hasSettledAssistant(
          turn: stream.turn,
          step: stream.step,
        );
    final liveKey = showLive
        ? 'assistant-step:${stream.turn}:${stream.step}'
        : null;
    final showProgress =
        widget.running &&
        stream?.interrupted != true &&
        stream?.unconfirmed != true;
    final progressIndex = rows.length + (showLive ? 1 : 0);
    final count =
        progressIndex + (showProgress ? 1 : 0) + (footer == null ? 0 : 1);
    return PocketList.builder(
      controller: widget.controller,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: count,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<(String, String)> || key.value.$1 != sessionId) {
          return null;
        }
        final identity = key.value.$2;
        if (identity == liveKey) return rows.length;
        if (identity == 'progress' && showProgress) return progressIndex;
        if (identity == 'footer' && footer != null) return count - 1;
        return _positions[identity];
      },
      itemBuilder: (context, index) {
        if (index < rows.length) {
          final item = rows[index];
          if (item.group case final group?) {
            return ChatToolGroupHeader(
              key: ValueKey((sessionId, group.key)),
              group: group,
              expanded: _expanded[group.key] == true,
              onToggle: () => _toggle(group),
            );
          }
          final row = item.entry!;
          final extra = _extras.render(
            context,
            row.key,
            onOpenFile: widget.onOpenFile,
            onOpenLink: widget.onOpenLink,
            onBranch: widget.onBranch,
          );
          if (extra != null) {
            return KeyedSubtree(
              key: ValueKey((sessionId, row.key)),
              child: extra,
            );
          }
          final change = _changeRows[row.key];
          if (change != null) {
            final controller = _changesController;
            return KeyedSubtree(
              key: ValueKey((sessionId, row.key)),
              child: controller == null
                  ? const SizedBox.shrink()
                  : ChatChangesCard(
                      controller: controller,
                      change: change,
                      enabled: controller.enabled,
                    ),
            );
          }
          final artifact = _artifactRows[row.key];
          if (artifact != null) {
            return KeyedSubtree(
              key: ValueKey((sessionId, row.key)),
              child: switch (artifact) {
                ChatTodoSnapshot() => ChatTodoRow(snapshot: artifact),
                ChatPresentedTurn() => ChatPresentedFiles(
                  sessionId: sessionId,
                  delivery: artifact,
                  onOpen: widget.onOpenFile == null
                      ? null
                      : (file) => widget.onOpenFile!(
                          ChatFileLink(sessionId: sessionId, path: file.path),
                        ),
                ),
              },
            );
          }
          final workflow = _workflowRows[row.key];
          if (workflow != null) {
            return ChatWorkflowRunCard(
              key: ValueKey((sessionId, row.key)),
              record: workflow,
            );
          }
          final message = ChatMessage(
            entry: row,
            runtime: widget.runtime,
            sessionId: sessionId,
            storageId: '$sessionId:${row.key}',
            activitySource: row.tool == null
                ? null
                : _sources[row.tool!.identity],
            onOpenLink: widget.onOpenLink,
            onOpenFile: widget.onOpenFile,
            onOpenAttachment: widget.onOpenAttachment,
            onOpenImage: widget.onOpenImage,
            onOpenSkill: widget.onOpenSkill,
            skillNames: _references.namesFor(row.seq),
            sessionLabels: _references.sessionLabelsFor(row.seq),
          );
          final group = item.parent;
          final motion = group == null ? null : _motions[group.key];
          Widget child = message;
          if (motion != null) {
            final animation = CurveTween(curve: Curves.easeOutCubic)
                .animate(motion);
            child = PocketBlurTransition(animation: animation, child: child);
            // Shrinking thousands of row extents would make them all visible
            // in the last frame. Large groups fade while retaining lazy layout.
            if (group!.entries.length <= 20) {
              child = SizeTransition(
                sizeFactor: animation,
                alignment: Alignment.topCenter,
                child: child,
              );
            }
          }
          return KeyedSubtree(
            key: ValueKey((sessionId, _displayKeys[row.key] ?? row.key)),
            child: child,
          );
        }
        if (showLive && index == rows.length) {
          return KeyedSubtree(
            key: ValueKey((sessionId, liveKey!)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ChatContent(
                    content: stream.content,
                    streaming: true,
                    sessionId: sessionId,
                    storageId: '$sessionId:$liveKey',
                    onOpenLink: widget.onOpenLink,
                    onOpenAttachment: widget.onOpenAttachment,
                    onOpenImage: widget.onOpenImage,
                  ),
                  if (stream.unconfirmed)
                    Text(
                      '回复状态待确认',
                      style: Theme.of(context).textTheme.labelSmall,
                    )
                  else if (stream.interrupted)
                    Text(
                      '回复已中断',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            ),
          );
        }
        if (showProgress && index == progressIndex) {
          return Padding(
            key: ValueKey((sessionId, 'progress')),
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: ChatProgressLine(
              calls: _progressCalls,
              writing:
                  stream != null && chatMessageText(stream.content).isNotEmpty,
            ),
          );
        }
        return KeyedSubtree(
          key: ValueKey((sessionId, 'footer')),
          child: footer!,
        );
      },
    );
  }
}

class ChatMessage extends StatelessWidget {
  const ChatMessage({
    required this.entry,
    required this.storageId,
    this.runtime,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
    this.onOpenAttachment,
    this.onOpenImage,
    this.activitySource,
    this.onOpenSkill,
    this.skillNames = const [],
    this.sessionLabels = const [],
    super.key,
  });
  final ChatEntry entry;
  final RuntimeController? runtime;
  final String storageId;
  final String? sessionId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  final ChatOpenAttachment? onOpenAttachment;
  final ChatOpenAttachment? onOpenImage;
  final ValueListenable<ToolActivity?>? activitySource;
  final Future<void> Function(String name)? onOpenSkill;
  final List<String> skillNames, sessionLabels;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    switch (entry.kind) {
      case ChatEntryKind.tool:
        if (ChatSkillToolPresentation.supports(entry.tool!)) {
          return ChatSkillToolCard(
            activity: entry.tool!,
            activitySource: activitySource,
          );
        }
        return ToolActivityCard(
          activity: entry.tool!,
          activitySource: activitySource,
        );
      case ChatEntryKind.systemPrompt:
      case ChatEntryKind.context:
      case ChatEntryKind.unknown:
        return _ChatDisclosure(
          storageId: storageId,
          title: entry.title ?? '上下文',
          icon: entry.kind == ChatEntryKind.systemPrompt
              ? Icons.tune_rounded
              : Icons.info_outline_rounded,
          body: (context) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              primary: false,
              child: entry.kind == ChatEntryKind.unknown
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (entry.text != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: SelectableText(
                              entry.text!,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        SelectableText(_json(entry.event['data'])),
                      ],
                    )
                  : entry.text != null
                  ? SelectableText(entry.text!)
                  : ChatContent(
                      content: entry.content,
                      sessionId: sessionId,
                      storageId: storageId,
                      opaqueText: true,
                      onOpenLink: onOpenLink,
                      onOpenFile: onOpenFile,
                      onOpenAttachment: onOpenAttachment,
                      onOpenImage: onOpenImage,
                    ),
            ),
          ),
        );
      case ChatEntryKind.command:
      case ChatEntryKind.notice:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: PocketCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  entry.title ?? '会话状态',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: entry.error ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
                if (entry.text?.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  PocketMarkdown(
                    data: entry.text!,
                    sessionId: sessionId,
                    onOpenLink: onOpenLink,
                    onOpenFile: onOpenFile,
                  ),
                ],
                if (entry.details != null)
                  _ChatDisclosure(
                    storageId: '$storageId:details',
                    title: entry.detailsTitle ?? '详情',
                    icon: Icons.history_rounded,
                    body: (_) => SelectableText(entry.details!),
                  ),
              ],
            ),
          ),
        );
      case ChatEntryKind.user:
      case ChatEntryKind.assistant:
        final user = entry.kind == ChatEntryKind.user;
        return Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * (user ? .8 : 1),
            ),
            margin: const EdgeInsets.symmetric(vertical: 10),
            padding: EdgeInsets.symmetric(
              horizontal: user ? 18 : 0,
              vertical: user ? 10 : 6,
            ),
            decoration: user
                ? BoxDecoration(
                    color: Color.alphaBlend(
                      colors.primary.withValues(alpha: .10),
                      colors.surfaceContainer,
                    ),
                    borderRadius: BorderRadius.circular(24),
                  )
                : null,
            child: ChatMessageActions(
              text: chatMessageText(entry.content),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChatContent(
                    content: entry.content,
                    runtime: runtime,
                    sessionId: sessionId,
                    storageId: storageId,
                    opaqueText: user,
                    userReferences: user,
                    onOpenSkill: onOpenSkill,
                    skillNames: skillNames,
                    sessionLabels: sessionLabels,
                    selectable: false,
                    onOpenLink: onOpenLink,
                    onOpenFile: onOpenFile,
                    onOpenAttachment: onOpenAttachment,
                    onOpenImage: onOpenImage,
                  ),
                  if (entry.interrupted)
                    Text(
                      '回复已中断',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            ),
          ),
        );
    }
  }
}

/// Blocks stay in authored order; unsupported blocks remain inspectable.
class ChatContent extends StatelessWidget {
  const ChatContent({
    required this.content,
    required this.storageId,
    this.runtime,
    this.sessionId,
    this.opaqueText = false,
    this.selectable = true,
    this.userReferences = false,
    this.streaming = false,
    this.onOpenSkill,
    this.skillNames = const [],
    this.sessionLabels = const [],
    this.onOpenLink,
    this.onOpenFile,
    this.onOpenAttachment,
    this.onOpenImage,
    super.key,
  });
  final List<dynamic> content;
  final RuntimeController? runtime;
  final String storageId;
  final String? sessionId;
  final bool opaqueText;
  final bool selectable;
  final bool userReferences;
  final bool streaming;
  final Future<void> Function(String name)? onOpenSkill;
  final List<String> skillNames, sessionLabels;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  final ChatOpenAttachment? onOpenAttachment;
  final ChatOpenAttachment? onOpenImage;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var index = 0; index < content.length; index++)
        _block(context, content[index], index),
    ],
  );

  Widget _block(BuildContext context, dynamic value, int index) {
    final block = value is Json ? value : null;
    final key = ValueKey('$storageId:block:$index');
    switch (block?['type']) {
      case 'text':
        final text = block!['text'] as String? ?? '';
        return Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: 6),
          child: opaqueText
              ? userReferences
                    ? ChatUserText(
                        text: text,
                        runtime: runtime,
                        storageId: '$storageId:block:$index',
                        skillNames: skillNames,
                        sessionLabels: sessionLabels,
                        onOpenSkill: onOpenSkill,
                        onOpenFile: onOpenFile == null || sessionId == null
                            ? null
                            : (path) => onOpenFile!(
                                ChatFileLink(sessionId: sessionId!, path: path),
                              ),
                      )
                    : selectable
                    ? SelectableText(
                        text,
                        style: const TextStyle(fontSize: 16, height: 1.6),
                      )
                    : Text(
                        text,
                        style: const TextStyle(fontSize: 16, height: 1.6),
                      )
              : streaming
              ? ChatStreamReveal(
                  revision: text,
                  child: PocketMarkdown(
                    data: text,
                    sessionId: sessionId,
                    selectable: false,
                    onOpenLink: onOpenLink,
                    onOpenFile: onOpenFile,
                  ),
                )
              : PocketMarkdown(
                  data: text,
                  sessionId: sessionId,
                  selectable: selectable,
                  onOpenLink: onOpenLink,
                  onOpenFile: onOpenFile,
                ),
        );
      case 'reasoning':
        final text = block!['text'] as String? ?? '';
        if (text.trim().isEmpty) return SizedBox.shrink(key: key);
        return _ChatDisclosure(
          key: key,
          storageId: '$storageId:reasoning:$index',
          title: '思考过程',
          icon: Icons.psychology_outlined,
          body: (context) => PocketMarkdown(
            data: text,
            sessionId: sessionId,
            onOpenLink: onOpenLink,
            onOpenFile: onOpenFile,
          ),
        );
      case 'image':
      case 'file':
        final attachment = block!['attachment'];
        return _AttachmentRow(
          key: key,
          attachment: attachment is Json ? attachment : block,
          image: block['type'] == 'image',
          onOpen: block['type'] == 'image'
              ? (onOpenImage ?? onOpenAttachment)
              : onOpenAttachment,
        );
      case 'tool-call':
        // The durable tool/call/result projection owns this protocol block.
        return SizedBox.shrink(key: key);
      default:
        return _ChatDisclosure(
          key: key,
          storageId: '$storageId:unknown:$index',
          title: '内容详情 · ${block?['type'] ?? '未知类型'}',
          icon: Icons.data_object_rounded,
          body: (context) => SelectableText(_json(value)),
        );
    }
  }
}

/// The maintained Markdown renderer receives Pocket's explicit theme. It never
/// invokes a default image loader, so model-authored paths cannot read files.
class PocketMarkdown extends StatefulWidget {
  const PocketMarkdown({
    required this.data,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
    this.selectable = true,
    super.key,
  });
  final String data;
  final String? sessionId;
  final bool selectable;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  @override
  State<PocketMarkdown> createState() => _PocketMarkdownState();
}

class _PocketMarkdownState extends State<PocketMarkdown> {
  late MarkdownStyleSheet _style;
  String? _linkError;
  int _openGeneration = 0;
  final _linkRecognizers = <String, TapGestureRecognizer>{};

  void _disposeLinkRecognizers() {
    for (final recognizer in _linkRecognizers.values) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  @override
  void dispose() {
    _disposeLinkRecognizers();
    super.dispose();
  }

  @override
  void didUpdateWidget(PocketMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.data != widget.data) {
      _openGeneration++;
      _linkError = null;
      _disposeLinkRecognizers();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context), colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge!.copyWith(
      color: colors.onSurface,
      fontSize: 16,
      height: 1.6,
    );
    // Keep this object stable across delta-only rebuilds. MarkdownBody reparses
    // changed text, while settled rows reuse their parsed widget trees.
    _style = MarkdownStyleSheet(
      p: body,
      a: body.copyWith(
        color: colors.primary,
        decoration: TextDecoration.underline,
      ),
      h1: theme.textTheme.headlineMedium?.copyWith(color: colors.onSurface),
      h2: theme.textTheme.headlineSmall?.copyWith(color: colors.onSurface),
      h3: theme.textTheme.titleLarge?.copyWith(color: colors.onSurface),
      h4: theme.textTheme.titleMedium?.copyWith(color: colors.onSurface),
      h5: body.copyWith(fontWeight: FontWeight.w600),
      h6: body.copyWith(fontWeight: FontWeight.w600),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      em: const TextStyle(fontStyle: FontStyle.italic),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      code: body.copyWith(fontFamily: 'monospace', fontSize: 14),
      codeblockPadding: const EdgeInsets.all(14),
      codeblockDecoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      blockquote: body.copyWith(color: colors.onSurfaceVariant),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      listBullet: body,
      listIndent: 22,
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      tableBorder: TableBorder.all(color: colors.outlineVariant),
      tableCellsPadding: const EdgeInsets.all(8),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      blockSpacing: 12,
    );
  }

  ChatFileLink? _file(String destination) => widget.sessionId == null
      ? null
      : chatFileLink(destination, sessionId: widget.sessionId!);

  bool _canOpen(String destination) =>
      (chatExternalUri(destination) != null && widget.onOpenLink != null) ||
      (_file(destination) != null && widget.onOpenFile != null);

  Future<void> _open(String destination, {bool allowFile = true}) async {
    final uri = chatExternalUri(destination);
    final file = allowFile ? _file(destination) : null;
    final openLink = widget.onOpenLink, openFile = widget.onOpenFile;
    final generation = ++_openGeneration;
    if ((uri == null || openLink == null) &&
        (file == null || openFile == null)) {
      setState(
        () => _linkError = uri == null && file == null
            ? '此链接不能直接打开。'
            : '当前无法打开链接。',
      );
      return;
    }
    try {
      if (uri != null && openLink != null) {
        await openLink(uri);
      } else {
        await openFile!(file!);
      }
      if (mounted && generation == _openGeneration) {
        setState(() => _linkError = null);
      }
    } catch (_) {
      // The opener owns platform diagnostics; avoid echoing a URL's secrets.
      if (mounted && generation == _openGeneration) {
        setState(() => _linkError = '链接打开失败，请重试。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MarkdownBody(
        key: ValueKey((
          widget.sessionId,
          widget.onOpenFile != null,
          widget.onOpenLink != null,
          widget.selectable,
        )),
        data: widget.data,
        selectable: widget.selectable,
        styleSheet: _style,
        builders: {
          'a': _PocketLinkBuilder(
            style: _style,
            selectable: widget.selectable,
            linkRecognizer: (destination) => !_canOpen(destination)
                ? null
                : _linkRecognizers.putIfAbsent(
                    destination,
                    () =>
                        TapGestureRecognizer()
                          ..onTap = () => unawaited(_open(destination)),
                  ),
          ),
        },
        onTapLink: (_, href, _) {
          if (href != null) unawaited(_open(href));
        },
        checkboxBuilder: (checked) => Icon(
          checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        imageBuilder: (uri, title, alt) => PocketTile(
          leading: const Icon(Icons.image_outlined),
          title: Text(alt?.isNotEmpty == true ? alt! : title ?? '图片链接'),
          subtitle: Text(
            chatExternalUri(uri.toString()) == null ? '需要通过文件入口访问' : '点击打开图片链接',
          ),
          onTap: () => unawaited(_open(uri.toString(), allowFile: false)),
        ),
      ),
      if (_linkError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _linkError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}

/// Unavailable links keep their inline formatting, without a link gesture or
/// link color. Images inside labels contribute alt text, never an implicit read.
class _PocketLinkBuilder extends MarkdownElementBuilder {
  _PocketLinkBuilder({
    required this.style,
    required this.selectable,
    required this.linkRecognizer,
  });
  final MarkdownStyleSheet style;
  final bool selectable;
  final TapGestureRecognizer? Function(String) linkRecognizer;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final destination = element.attributes['href'] ?? '';
    final recognizer = linkRecognizer(destination);
    final textStyle = recognizer == null
        ? parentStyle
        : parentStyle?.merge(preferredStyle);
    final span = TextSpan(
      children: [
        for (final node in element.children ?? const <md.Node>[])
          ..._spans(node, textStyle, recognizer),
      ],
    );
    return selectable
        ? SelectableText.rich(span, textScaler: style.textScaler)
        : Text.rich(span, textScaler: style.textScaler);
  }

  Iterable<TextSpan> _spans(
    md.Node node,
    TextStyle? inherited,
    TapGestureRecognizer? recognizer,
  ) sync* {
    if (node is md.Text) {
      yield TextSpan(text: node.text, style: inherited, recognizer: recognizer);
      return;
    }
    final element = node as md.Element;
    final textStyle = inherited?.merge(style.styles[element.tag]);
    if (element.tag == 'img' || element.tag == 'br') {
      yield TextSpan(
        text: element.tag == 'img' ? element.attributes['alt'] ?? '' : '\n',
        style: textStyle,
        recognizer: recognizer,
      );
    }
    for (final child in element.children ?? const <md.Node>[]) {
      yield* _spans(child, textStyle, recognizer);
    }
  }
}

class _AttachmentRow extends StatefulWidget {
  const _AttachmentRow({
    super.key,
    required this.attachment,
    required this.image,
    this.onOpen,
  });
  final Json attachment;
  final bool image;
  final ChatOpenAttachment? onOpen;
  @override
  State<_AttachmentRow> createState() => _AttachmentRowState();
}

class _AttachmentRowState extends State<_AttachmentRow> {
  String? error;
  bool busy = false;
  Future<void> open() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onOpen!(widget.attachment);
    } catch (_) {
      if (mounted) setState(() => error = '附件打开失败，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketTile(
    leading: Icon(
      widget.image ? Icons.image_outlined : Icons.attach_file_rounded,
    ),
    title: Text(
      '${widget.attachment['name'] ?? (widget.image ? '图片附件' : '文件附件')}',
    ),
    subtitle: Text(
      error ??
          (busy
              ? '正在打开…'
              : widget.onOpen == null
              ? '附件已随会话保存'
              : '查看附件'),
    ),
    onTap: widget.onOpen == null || busy ? null : open,
  );
}

/// Only expanded content is built. PageStorage preserves disclosures across
/// lazy row eviction without keeping every long conversation row alive.
class _ChatDisclosure extends StatefulWidget {
  const _ChatDisclosure({
    super.key,
    required this.storageId,
    required this.title,
    required this.icon,
    required this.body,
  });
  final String storageId, title;
  final IconData icon;
  final WidgetBuilder body;
  @override
  State<_ChatDisclosure> createState() => _ChatDisclosureState();
}

class _ChatDisclosureState extends State<_ChatDisclosure> {
  bool expanded = false;
  bool restored = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!restored) {
      expanded =
          PageStorage.maybeOf(context)
              ?.readState(context, identifier: widget.storageId) ==
          true;
      restored = true;
    }
  }

  void toggle() {
    setState(() => expanded = !expanded);
    PageStorage.maybeOf(context)
        ?.writeState(context, expanded, identifier: widget.storageId);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ToolActivitySummaryRow(
        icon: widget.icon,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        label: widget.title,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        opened: expanded,
        onTap: toggle,
      ),
      if (MediaQuery.disableAnimationsOf(context))
        expandedBody(context)
      else
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expandedBody(context),
        ),
    ],
  );

  Widget expandedBody(BuildContext context) => expanded
      ? PocketReveal(
          child: PocketCard(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                primary: false,
                child: widget.body(context),
              ),
            ),
          ),
        )
      : const SizedBox(width: double.infinity);
}

String _json(dynamic value) =>
    const JsonEncoder.withIndent('  ').convert(value);
