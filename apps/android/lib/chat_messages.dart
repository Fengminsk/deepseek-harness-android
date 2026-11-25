import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:markdown/markdown.dart' as md;

import 'chat_message_actions.dart';
import 'chat_markdown_syntax.dart';
import 'chat_projection.dart';
import 'chat_deliverables.dart';
import 'chat_changes.dart';
import 'chat_skills.dart';
import 'chat_execution_chain.dart';
import 'chat_execution_data.dart';
import 'chat_user_references.dart';
import 'chat_turn_extras.dart';
import 'chat_turn_navigation.dart';
import 'chat_workflow_runs.dart';
import 'subagents_data.dart';
import 'chat_reading.dart';
import 'chat_progress.dart';
import 'chat_retry_row.dart';
import 'chat_stream_reveal.dart';
import 'image_preview.dart';
import 'tool_activity_details.dart' show ToolActivitySummaryRow;
import 'entry_motion.dart';
import 'runtime.dart';
import 'tool_activity.dart';
import 'ui.dart';
import 'workspace_changes.dart';

/// 消息列左右 gutter（DSH Web `ChatView` 手机尺寸）。
const double chatMessageGutter = 16;

/// 用户气泡最大宽度占消息列比例（DSH Web `MessageItem` 约 82%）。
const double chatUserBubbleMaxWidthFactor = .82;

/// 过程/工具/元信息辅助文字：13/18、次要色（对齐 DSH 手机 token）。
TextStyle chatAuxiliaryTextStyle(BuildContext context) => TextStyle(
  fontSize: 13,
  height: 18 / 13,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);
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
    this.messageImage,
    this.onBranch,
    this.onOpenWorkflowChild,
    this.onQuote,
    this.showTurnNavigation = true,
    this.compactTurns = false,
    this.animateRows = true,
    this.historyHeader,
    this.submittedAfterSeq,
    this.followSubmittedMessage = true,
    super.key,
  });
  final String sessionId;
  final RuntimeController? runtime;
  final bool running;
  final Future<void> Function(String name)? onOpenSkill;
  final ChatProjection projection;
  final ScrollController controller;
  final int? submittedAfterSeq;
  final bool followSubmittedMessage;

  /// Original loaded Session window, including log-only todo/present events.
  final List<Json> events;
  final ChatLiveMessage? live;
  final bool showTurnNavigation;

  /// Tighter process and answer rhythm used by the remote conversation page.
  final bool compactTurns;
  final bool animateRows;
  final Widget? historyHeader;
  final Widget? footer;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  final ChatOpenAttachment? onOpenAttachment;
  final ChatOpenAttachment? onOpenImage;
  final PocketImageSource Function(Json)? messageImage;
  final Future<String?> Function(int atSeq)? onBranch;
  final Future<void> Function(SubagentAddress address, String label)?
  onOpenWorkflowChild;

  /// Inserts one message as a Markdown blockquote into the active composer.
  final ValueChanged<String>? onQuote;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline>
    with TickerProviderStateMixin {
  final _sources = <String, ValueNotifier<ToolActivity?>>{};
  final _expanded = <String, bool>{};
  final _motions = <String, AnimationController>{};
  List<ChatExecutionDisplay> _groups = const [];
  List<ChatExecutionDisplay> _display = const [];
  List<Json>? _reconciledEvents;
  int? _reconciledProcessedCount, _reconciledEntryCount;
  bool _hasActiveExecution = false;
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
  final _listAnchor = PocketListAnchorController();
  Object? _observed;
  int _generation = 0;
  bool _loadingEarlier = false;
  String? _olderError;
  String? _submittedKey;

  @override
  void initState() {
    super.initState();
    _attachChanges();
  }

  Future<void> _readEarlier() async {
    final runtime = widget.runtime;
    if (runtime == null ||
        _loadingEarlier ||
        runtime.historyWindows[widget.sessionId]?.hasMore != true) {
      return;
    }
    final sessionId = widget.sessionId;
    setState(() {
      _loadingEarlier = true;
      _olderError = null;
    });
    try {
      final added = await runtime.loadOlderSession(sessionId);
      if (!mounted || widget.sessionId != sessionId) return;
      // Capture the actual painted row after any concurrent replies or user
      // scrolling. Sliver max extent is an estimate for unloaded row heights.
      final anchor = _listAnchor.capture(minIndex: 1);
      setState(() {
        _loadingEarlier = false;
        if (added > 0) {
          widget.projection.reconcile(widget.events);
          _observed = null;
        }
      });
      if (added > 0 && anchor != null) {
        _listAnchor.restore(anchor, widget.controller);
      }
    } catch (_) {
      if (mounted && widget.sessionId == sessionId) {
        setState(() {
          _loadingEarlier = false;
          _olderError = '读取更早消息失败，点击重试';
        });
      }
    }
  }

  void _attachChanges() {
    final runtime = widget.runtime;
    _extras = ChatTurnExtras(runtime: runtime, sessionId: widget.sessionId);
    if (runtime == null) return;
    _changesController = WorkspaceChangesController(
      runtime: runtime,
      sessionId: widget.sessionId,
    );
  }

  void _detachChanges() {
    _extras.dispose();
    _changesController?.dispose();
    _changesController = null;
  }

  @override
  void didUpdateWidget(ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.submittedAfterSeq != widget.submittedAfterSeq ||
        oldWidget.sessionId != widget.sessionId) {
      _submittedKey = null;
      _listAnchor.cancel(stopReveal: true);
    }
    if (oldWidget.followSubmittedMessage && !widget.followSubmittedMessage) {
      _listAnchor.cancel();
    }
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.runtime != widget.runtime) {
      _detachChanges();
      _attachChanges();
      _observed = null;
    }
    if (oldWidget.sessionId != widget.sessionId) {
      _reconciledEvents = null;
      _reconciledProcessedCount = null;
      _reconciledEntryCount = null;
      _listAnchor.cancel(discardSpace: true);
      _loadingEarlier = false;
      _olderError = null;
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
    _listAnchor.dispose();
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
    // A remote live token rebuilds this widget without changing its durable
    // events. Replaying every event through five projections per token makes
    // long sessions stutter on older phones. Local timelines keep their
    // existing reconciliation behavior because their event list can mutate.
    final durableChanged =
        !identical(_reconciledEvents, widget.events) ||
        _reconciledProcessedCount != projection.processedEventCount ||
        _reconciledEntryCount != projection.entries.length;
    if (!widget.compactTurns || durableChanged) {
      _artifacts.reconcile(widget.events);
      _changes.reconcile(widget.events);
      _references.reconcile(entries: projection.entries, events: widget.events);
      _workflows.reconcile(widget.events);
      _extras.reconcile(widget.events, projection.entries);
      _reconciledEvents = widget.events;
      _reconciledProcessedCount = projection.processedEventCount;
      _reconciledEntryCount = projection.entries.length;
    }
    final live = widget.live;
    final liveReasoning =
        live != null &&
        !projection.hasSettledAssistant(turn: live.turn, step: live.step) &&
        chatReasoningText(live.content) != null;
    final stamp = (
      projection,
      projection.processedEventCount,
      projection.entries.length,
      _artifacts.revision,
      _changes.revision,
      _extras.revision,
      _workflows.revision,
      widget.live?.turn,
      liveReasoning ? live.step : null,
      widget.running,
      live?.interrupted,
      live?.unconfirmed,
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
    final previousChains = {
      for (final item in _groups)
        if (item.chain != null) item.key: item.chain!,
    };
    final previousExpanded = {
      for (final entry in previousChains.entries)
        entry.key: _isExpanded(entry.value),
    };
    _groups = groupChatExecution(
      entries,
      widget.events,
      activeTurn:
          widget.running &&
              live?.interrupted != true &&
              live?.unconfirmed != true
          ? activeTurn
          : null,
      liveTurn: liveReasoning ? live.turn : null,
      liveStep: liveReasoning ? live.step : null,
    );
    _hasActiveExecution = _groups.any((item) => item.chain?.active == true);
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
      final group = item.chain;
      if (group == null) continue;
      if (!_expanded.containsKey(group.key)) {
        final saved = PageStorage.maybeOf(
          context,
        )?.readState(context, identifier: '${widget.sessionId}:${group.key}');
        if (saved is bool) _expanded[group.key] = saved;
      }
      final wasExpanded = previousExpanded[group.key];
      final nowExpanded = _isExpanded(group);
      if (wasExpanded != null && wasExpanded != nowExpanded) {
        final motion = _chainMotion(group.key, wasExpanded);
        if (wasExpanded && !nowExpanded && group.completed) {
          final replyKeys = <Key>{
            for (final row in _display)
              if (row.parent == null &&
                  row.entry?.kind == ChatEntryKind.assistant)
                ValueKey((widget.sessionId, _displayKeys[row.key] ?? row.key)),
            if (widget.live case final live?
                when _assistantReplyBlocks(live.content).isNotEmpty)
              ValueKey((
                widget.sessionId,
                'assistant-step:${live.turn}:${live.step}',
              )),
          };
          final anchor = _listAnchor.capture(keys: replyKeys);
          final scrolling =
              widget.controller.hasClients &&
              widget.controller.position.isScrollingNotifier.value;
          if (anchor != null && !scrolling) {
            _listAnchor.hold(
              anchor,
              motion,
              immediate: MediaQuery.disableAnimationsOf(context),
            );
          }
        }
        if (MediaQuery.disableAnimationsOf(context)) {
          motion.value = nowExpanded ? 1 : 0;
        } else if (nowExpanded) {
          motion.forward();
        } else {
          motion.reverse();
        }
      }
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
        if (item.chain != null &&
            (_isExpanded(item.chain!) || (_motions[item.key]?.value ?? 0) > 0))
          for (var i = 0; i < item.chain!.entries.length; i++)
            ChatExecutionDisplay.step(
              item.chain!.entries[i],
              item.chain,
              last: i == item.chain!.entries.length - 1,
              continuation:
                  i > 0 &&
                  item.chain!.entries[i].tool?.name == 'web_fetch' &&
                  item.chain!.entries[i - 1].tool?.name == 'web_fetch',
            ),
      ],
    ];
    _positions.clear();
    _displayKeys.clear();
    final seenAssistantSteps = <(int, int)>{};
    final seenReasoningSteps = <(int, int)>{};
    for (var i = 0; i < _display.length; i++) {
      final item = _display[i];
      final row = item.entry;
      var identity = item.key;
      if (row != null &&
          item.parent != null &&
          row.kind == ChatEntryKind.assistant &&
          row.turn != null &&
          row.step != null &&
          seenReasoningSteps.add((row.turn!, row.step!))) {
        identity = 'process:assistant-step:${row.turn}:${row.step}';
      }
      if (row != null &&
          item.parent == null &&
          row.kind == ChatEntryKind.assistant &&
          row.turn != null &&
          row.step != null &&
          seenAssistantSteps.add((row.turn!, row.step!))) {
        identity = 'assistant-step:${row.turn}:${row.step}';
      }
      if (row != null) _displayKeys[item.key] = identity;
      _positions[identity] = i;
    }
  }

  bool _isExpanded(ChatExecutionChain chain) => _expanded[chain.key] ?? false;

  AnimationController _chainMotion(String key, bool wasExpanded) =>
      _motions.putIfAbsent(key, () {
        final controller = AnimationController(
          vsync: this,
          value: wasExpanded ? 1 : 0,
          duration: PocketEntryMotion.duration,
        );
        controller.addStatusListener((status) {
          if (status == AnimationStatus.dismissed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(_flatten);
            });
          }
        });
        return controller;
      });

  void _toggle(ChatExecutionChain group) {
    final wasExpanded = _isExpanded(group);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final motion = _chainMotion(group.key, wasExpanded);
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
    if (widget.submittedAfterSeq case final after? when _submittedKey == null) {
      for (final entry in widget.projection.entries) {
        if (entry.kind != ChatEntryKind.user || entry.seq <= after) continue;
        _submittedKey = entry.key;
        final key = ValueKey((widget.sessionId, entry.key));
        final animate = !MediaQuery.disableAnimationsOf(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.followSubmittedMessage &&
              _submittedKey == entry.key) {
            _listAnchor.reveal(key, widget.controller, animate: animate);
          }
        });
        break;
      }
    }
    final rows = _display;
    final stream = widget.live;
    final sessionId = widget.sessionId;
    final footer = widget.footer;
    final activeTurn = widget.running ? _activeProgressTurn() : null;
    final hasLive =
        stream != null &&
        !widget.projection.hasSettledAssistant(
          turn: stream.turn,
          step: stream.step,
        );
    final showLive =
        hasLive &&
        (_assistantReplyBlocks(stream.content).isNotEmpty ||
            stream.interrupted ||
            stream.unconfirmed);
    final liveKey = showLive
        ? 'assistant-step:${stream.turn}:${stream.step}'
        : null;
    final reasoningOnly =
        showLive &&
        _assistantReasoningText(stream.content) != null &&
        _assistantReplyBlocks(stream.content).isEmpty;
    final showingAuthoredReply =
        showLive &&
        chatMessageText(_assistantReplyBlocks(stream.content)).isNotEmpty;
    final hasPendingActivity = chatHasPendingActivity(_progressCalls);
    final showProgress =
        widget.running &&
        !_hasActiveExecution &&
        stream?.interrupted != true &&
        stream?.unconfirmed != true &&
        !((reasoningOnly || showingAuthoredReply) && !hasPendingActivity);
    final progressIndex = rows.length + (showLive ? 1 : 0);
    final count =
        progressIndex + (showProgress ? 1 : 0) + (footer == null ? 0 : 1);
    final historyWindow = widget.showTurnNavigation
        ? widget.runtime?.historyWindows[sessionId]
        : null;
    final showNavigation = historyWindow != null;
    final headerCount = showNavigation || widget.historyHeader != null ? 1 : 0;
    return PocketList.builder(
      animateItems: widget.animateRows,
      controller: widget.controller,
      anchorController: _listAnchor,
      reserveEndSpace: true,
      endAnchorKey: _submittedKey == null
          ? null
          : ValueKey((sessionId, _submittedKey!)),
      padding: const EdgeInsets.symmetric(horizontal: chatMessageGutter),
      itemCount: count + headerCount,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<(String, String)> || key.value.$1 != sessionId) {
          return null;
        }
        final identity = key.value.$2;
        if (identity == 'turn-navigation' && headerCount == 1) return 0;
        if (identity == liveKey) return rows.length + headerCount;
        if (identity == 'progress' && showProgress) {
          return progressIndex + headerCount;
        }
        if (identity == 'footer' && footer != null) {
          return count - 1 + headerCount;
        }
        final row = _positions[identity];
        return row == null ? null : row + headerCount;
      },
      itemBuilder: (context, index) {
        if (headerCount == 1 && index == 0) {
          if (widget.historyHeader case final header?) {
            return KeyedSubtree(
              key: ValueKey((sessionId, 'turn-navigation')),
              child: header,
            );
          }
          return Padding(
            key: ValueKey((sessionId, 'turn-navigation')),
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push<void>(
                    PocketRoute(
                      builder: (_) => ChatTurnNavigatorPage(
                        runtime: widget.runtime!,
                        sessionId: sessionId,
                      ),
                    ),
                  ),
                  icon: const Icon(
                    Icons.format_list_numbered_rounded,
                    size: 18,
                  ),
                  label: const Text('会话轮次'),
                ),
                const Spacer(),
                if (historyWindow?.hasMore == true)
                  TextButton(
                    onPressed: _loadingEarlier ? null : _readEarlier,
                    child: Text(
                      _olderError ?? (_loadingEarlier ? '读取中…' : '更早消息'),
                    ),
                  ),
              ],
            ),
          );
        }
        final rowIndex = index - headerCount;
        if (rowIndex < rows.length) {
          final item = rows[rowIndex];
          if (item.chain case final group?) {
            return ChatExecutionHeader(
              key: ValueKey((sessionId, group.key)),
              chain: group,
              expanded: _isExpanded(group),
              onToggle: () => _toggle(group),
              compact: widget.compactTurns,
            );
          }
          final row = item.entry!;
          if (item.parent case final chain?) {
            final isLive = row.key.startsWith('live-reasoning:');
            final artifact = _artifactRows[row.key];
            Widget step = ChatExecutionStep(
              entry: row,
              storageId: '$sessionId:${_displayKeys[item.key] ?? item.key}',
              runtime: widget.runtime,
              last: item.last,
              continuation: item.continuation,
              live: isLive,
              thinking:
                  isLive &&
                  widget.running &&
                  widget.live?.interrupted != true &&
                  widget.live?.unconfirmed != true &&
                  _assistantReplyBlocks(widget.live?.content ?? const [])
                      .isEmpty,
              liveContent: isLive ? widget.live?.content ?? const [] : const [],
              todo: artifact is ChatTodoSnapshot ? artifact : null,
              plan: _extras.planFor(row.key),
              sessionId: sessionId,
              onOpenFile: widget.onOpenFile,
              activitySource: row.tool == null
                  ? null
                  : _sources[row.tool!.identity],
              onOpenLink: widget.onOpenLink,
            );
            final motion = _motions[chain.key];
            if (motion != null) {
              final animation = CurveTween(curve: PocketEntryMotion.curve)
                  .animate(motion);
              step = PocketBlurTransition(animation: animation, child: step);
              if (chain.entries.length <= 20) {
                step = SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: step,
                );
              }
            }
            return KeyedSubtree(
              key: ValueKey((sessionId, _displayKeys[item.key] ?? item.key)),
              child: step,
            );
          }
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
                  : ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => ChatChangesCard(
                        controller: controller,
                        change: change,
                        enabled: controller.enabled,
                      ),
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
              runtime: widget.runtime,
              parentSessionId: widget.sessionId,
              onOpenChild: widget.onOpenWorkflowChild,
            );
          }
          final message = ChatMessage(
            entry: row,
            showReasoning: !item.hideReasoning,
            activeTurn: row.retry != null && activeTurn == row.retry!.turn,
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
            messageImage: widget.messageImage,
            onOpenSkill: widget.onOpenSkill,
            skillNames: _references.namesFor(row.seq),
            sessionLabels: _references.sessionLabelsFor(row.seq),
            onQuote: widget.onQuote,
            compact: widget.compactTurns,
          );
          return KeyedSubtree(
            key: ValueKey((sessionId, _displayKeys[item.key] ?? item.key)),
            child: message,
          );
        }
        if (showLive && rowIndex == rows.length) {
          final reply = _assistantReplyBlocks(stream.content);
          return KeyedSubtree(
            key: ValueKey((sessionId, liveKey!)),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: widget.compactTurns ? 4 : 14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (reply.isNotEmpty)
                    ChatContent(
                      content: reply,
                      streaming: true,
                      plainStreaming: widget.compactTurns,
                      sessionId: sessionId,
                      storageId: '$sessionId:$liveKey',
                      onOpenLink: widget.onOpenLink,
                      onOpenAttachment: widget.onOpenAttachment,
                      onOpenImage: widget.onOpenImage,
                    ),
                  if (stream.unconfirmed)
                    Text('回复状态待确认', style: chatAuxiliaryTextStyle(context))
                  else if (stream.interrupted)
                    Text('回复已中断', style: chatAuxiliaryTextStyle(context)),
                ],
              ),
            ),
          );
        }
        if (showProgress && rowIndex == progressIndex) {
          return Padding(
            key: ValueKey((sessionId, 'progress')),
            padding: EdgeInsets.symmetric(
              vertical: widget.compactTurns ? 4 : 14,
            ),
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
    this.activeTurn = false,
    this.showReasoning = true,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
    this.onOpenAttachment,
    this.onOpenImage,
    this.activitySource,
    this.messageImage,
    this.onOpenSkill,
    this.skillNames = const [],
    this.sessionLabels = const [],
    this.onQuote,
    this.compact = false,
    super.key,
  });
  final ChatEntry entry;
  final RuntimeController? runtime;
  final bool activeTurn;
  final bool showReasoning;
  final String storageId;
  final String? sessionId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  final ChatOpenAttachment? onOpenAttachment;
  final ChatOpenAttachment? onOpenImage;
  final ValueListenable<ToolActivity?>? activitySource;
  final PocketImageSource Function(Json)? messageImage;
  final Future<void> Function(String name)? onOpenSkill;
  final List<String> skillNames, sessionLabels;
  final ValueChanged<String>? onQuote;
  final bool compact;

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
        if (entry.title == '/compact' || entry.compaction != null) {
          return _CompactCommandMessage(
            entry: entry,
            storageId: storageId,
            sessionId: sessionId,
            onOpenLink: onOpenLink,
            onOpenFile: onOpenFile,
          );
        }
        return _statusCard(context);
      case ChatEntryKind.notice:
        if (entry.retry case final retry?) {
          return ChatRetryRow(
            retry: retry,
            activeTurn: activeTurn,
            history: entry.details,
          );
        }
        return _statusCard(context);
      case ChatEntryKind.user:
      case ChatEntryKind.assistant:
        final user = entry.kind == ChatEntryKind.user;
        final photos = <Json>[];
        final body = <dynamic>[];
        if (user) {
          final canReadImages =
              messageImage != null || (runtime != null && sessionId != null);
          for (final part in entry.content) {
            final ref = part is Json && part['type'] == 'image'
                ? part['attachment']
                : null;
            if (canReadImages && ref is Json && ref['attachmentId'] is String) {
              photos.add(ref);
            } else {
              body.add(part);
            }
          }
        }
        final reply = user ? body : _assistantReplyBlocks(entry.content);
        final answer = Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth:
                  MediaQuery.sizeOf(context).width *
                  (user ? chatUserBubbleMaxWidthFactor : 1),
            ),
            margin: EdgeInsets.only(
              top: compact ? 3 : 10,
              bottom: user
                  ? 0
                  : compact
                  ? 3
                  : 10,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: user ? 18 : 0,
              vertical: user ? (compact ? 8 : 10) : (compact ? 2 : 6),
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
              text: chatMessageText(reply),
              onQuote: onQuote,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: photos.isEmpty
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.start,
                children: [
                  ChatContent(
                    content: reply,
                    shrinkWrap: photos.isNotEmpty,
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
                    Text('回复已中断', style: chatAuxiliaryTextStyle(context)),
                ],
              ),
            ),
          ),
        );
        if (user) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (photos.isNotEmpty)
                _UserPhotos(
                  photos: photos,
                  sourceFor:
                      messageImage ??
                      (ref) =>
                          PocketImageSource.session(runtime!, sessionId!, ref),
                ),
              if (reply.isNotEmpty) answer,
              ChatUserMessageActions(
                text: chatMessageText(reply),
                time: entry.event['time'] is int
                    ? entry.event['time'] as int
                    : null,
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showReasoning && _assistantReasoningText(entry.content) != null)
              _AssistantReasoningRow(
                text: _assistantReasoningText(entry.content)!,
                storageId: '$storageId:reasoning',
                runtime: runtime,
                sessionId: sessionId,
                onOpenLink: onOpenLink,
                onOpenFile: onOpenFile,
              ),
            if (reply.isNotEmpty || entry.interrupted) answer,
          ],
        );
    }
  }

  Widget _statusCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = entry.title ?? '会话状态';
    final summary = entry.text?.trim();
    return _ChatDisclosure(
      storageId: '$storageId:status',
      title:
          entry.kind == ChatEntryKind.command && !entry.error ||
              summary == null ||
              summary.isEmpty
          ? title
          : '$title · ${summary.split('\n').first}',
      icon: entry.kind == ChatEntryKind.command
          ? Icons.terminal_rounded
          : Icons.info_outline_rounded,
      color: entry.error ? colors.error : null,
      body: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (summary != null && summary.isNotEmpty)
            PocketMarkdown(
              data: entry.text!,
              sessionId: sessionId,
              onOpenLink: onOpenLink,
              onOpenFile: onOpenFile,
            ),
          if (entry.details case final String details) SelectableText(details),
        ],
      ),
    );
  }
}

/// A manual compaction occupies one transcript row and discloses its saved summary.
class _CompactCommandMessage extends StatefulWidget {
  const _CompactCommandMessage({
    required this.entry,
    required this.storageId,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
  });

  final ChatEntry entry;
  final String storageId;
  final String? sessionId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;

  @override
  State<_CompactCommandMessage> createState() => _CompactCommandMessageState();
}

class _CompactCommandMessageState extends State<_CompactCommandMessage> {
  bool expanded = false;
  bool restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (restored) return;
    restored = true;
    expanded =
        PageStorage.maybeOf(context)
            ?.readState(context, identifier: widget.storageId) ==
        true;
  }

  void _toggle() {
    setState(() => expanded = !expanded);
    PageStorage.maybeOf(context)
        ?.writeState(context, expanded, identifier: widget.storageId);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final summary = entry.compaction?.summary;
    final expandable = summary != null && summary.isNotEmpty;
    final count = entry.compaction?.shadowedItemCount;
    final tokens = entry.compaction?.shadowedTokenCount;
    final status = entry.error
        ? entry.text ?? '压缩未完成'
        : count != null && tokens != null
        ? '已压缩 $count 条历史记录 · 约 $tokens tokens'
        : entry.compaction != null
        ? entry.outcome == null
              ? '上下文已压缩'
              : entry.text ?? '上下文已压缩'
        : entry.outcome == null
        ? '正在压缩上下文…'
        : entry.text == 'No compactable history yet.'
        ? '暂无可压缩的历史记录'
        : entry.text ?? '上下文已压缩';
    final ink = entry.error
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            Icon(Icons.compress_rounded, size: 20, color: ink),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('压缩上下文', style: TextStyle(color: ink, fontSize: 14)),
                  Text(status, style: TextStyle(color: ink, fontSize: 13)),
                ],
              ),
            ),
            if (expandable)
              AnimatedRotation(
                turns: expanded ? .25 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: ink),
              ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        expandable
            ? Semantics(
                button: true,
                expanded: expanded,
                label: '压缩上下文，$status',
                onTap: _toggle,
                child: ExcludeSemantics(
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(onTap: _toggle, child: row),
                  ),
                ),
              )
            : row,
        if (expanded && expandable)
          PocketReveal(
            child: PocketCard(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  primary: false,
                  child: PocketMarkdown(
                    data: summary,
                    sessionId: widget.sessionId,
                    onOpenLink: widget.onOpenLink,
                    onOpenFile: widget.onOpenFile,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

List<dynamic> _assistantReplyBlocks(List<dynamic> content) => [
  for (final block in content)
    if (block is! Json || block['type'] != 'reasoning') block,
];

String? _assistantReasoningText(List<dynamic> content) {
  final parts = <String>[];
  for (final block in content) {
    if (block is Json && block['type'] == 'reasoning') {
      final text = block['text'];
      if (text is String && text.trim().isNotEmpty) parts.add(text);
    }
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}

/// The original assistant step presents reasoning as process activity; the
/// authored answer occupies its own reading row and copy target.
class _AssistantReasoningRow extends StatelessWidget {
  const _AssistantReasoningRow({
    required this.text,
    required this.storageId,
    this.runtime,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
  });

  final String text, storageId;
  final RuntimeController? runtime;
  final String? sessionId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;

  @override
  Widget build(BuildContext context) => _ChatDisclosure(
    storageId: storageId,
    title: '已思考',
    icon: Icons.psychology_outlined,
    body: (_) => PocketMarkdown(
      data: text,
      compact: true,
      runtime: runtime,
      sessionId: sessionId,
      onOpenLink: onOpenLink,
      onOpenFile: onOpenFile,
    ),
  );
}

class _UserPhotos extends StatelessWidget {
  const _UserPhotos({required this.photos, required this.sourceFor});

  final List<Json> photos;
  final PocketImageSource Function(Json) sourceFor;

  @override
  Widget build(BuildContext context) {
    final maxWidth =
        MediaQuery.sizeOf(context).width * chatUserBubbleMaxWidthFactor;
    const spacing = 5.0;
    final tile = math.min(92.0, (maxWidth - 2 * spacing) / 3);
    var size = Size.square(tile);
    if (photos.length == 1) {
      final ref = photos.single;
      final width = ref['width'];
      final height = ref['height'];
      final ratio = width is num && height is num && width > 0 && height > 0
          ? (width / height).clamp(.25, 4.0)
          : 1.0;
      final side = math.min(186.0, maxWidth);
      size = Size(side * math.min(1.0, ratio), side / math.max(1.0, ratio));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final ref in photos)
              PocketInlineImage(source: sourceFor(ref), thumbnailSize: size),
          ],
        ),
      ),
    );
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
    this.shrinkWrap = false,
    this.selectable = true,
    this.userReferences = false,
    this.streaming = false,
    this.plainStreaming = false,
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
  final bool shrinkWrap;
  final bool selectable;
  final bool userReferences;
  final bool streaming;
  final bool plainStreaming;
  final Future<void> Function(String name)? onOpenSkill;
  final List<String> skillNames, sessionLabels;
  final ChatOpenLink? onOpenLink;
  final ChatOpenFile? onOpenFile;
  final ChatOpenAttachment? onOpenAttachment;
  final ChatOpenAttachment? onOpenImage;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: shrinkWrap
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.stretch,
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
                        style: const TextStyle(fontSize: 14, height: 24 / 14),
                      )
                    : Text(
                        text,
                        style: const TextStyle(fontSize: 14, height: 24 / 14),
                      )
              : streaming && plainStreaming
              ? Text(
                  text,
                  style: pocketMarkdownStyleSheet(context, compact: true).p,
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
                  runtime: runtime,
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
            runtime: runtime,
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

/// DSH Web 手机尺寸的 markdown 排版 token。
///
/// 正文 14/24（compact 13/20）、块间距 16（compact 12）、标题固定字号而非
/// Material 大标题、列表缩进 18、引用左细线、代码块自动换行。字号仍受
/// [MediaQuery.textScalerOf] 缩放。
MarkdownStyleSheet pocketMarkdownStyleSheet(
  BuildContext context, {
  required bool compact,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final baseSize = compact ? 13.0 : 14.0;
  final baseLine = compact ? 20.0 : 24.0;
  final body = TextStyle(
    fontSize: baseSize,
    height: baseLine / baseSize,
    color: colors.onSurface,
    fontFamily: theme.textTheme.bodyMedium?.fontFamily,
  );
  TextStyle heading(double size, double line, FontWeight weight) =>
      body.copyWith(fontSize: size, height: line / size, fontWeight: weight);
  final h1Size = compact ? 18.0 : 21.0;
  final h2Size = compact ? 17.0 : 19.0;
  final h3Size = compact ? 16.0 : 18.0;
  final h4Size = compact ? 13.0 : 14.0;
  final headingTop = compact ? 12.0 : 16.0;
  final codeFont = body.copyWith(
    fontFamily: 'monospace',
    fontSize: baseSize * .875,
    height: 1.6,
  );
  return MarkdownStyleSheet(
    p: body,
    pPadding: EdgeInsets.zero,
    a: body.copyWith(
      color: colors.primary,
      fontWeight: FontWeight.w500,
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.dotted,
    ),
    h1: heading(h1Size, compact ? 26 : 30, FontWeight.w700),
    h1Padding: EdgeInsets.only(top: headingTop),
    h2: heading(h2Size, compact ? 24 : 28, FontWeight.w700),
    h2Padding: EdgeInsets.only(top: headingTop),
    h3: heading(h3Size, compact ? 22 : 26, FontWeight.w700),
    h3Padding: EdgeInsets.only(top: headingTop),
    h4: heading(h4Size, compact ? 20 : 24, FontWeight.w600),
    h4Padding: EdgeInsets.zero,
    h5: heading(h4Size, compact ? 20 : 24, FontWeight.w600),
    h5Padding: EdgeInsets.zero,
    h6: heading(h4Size, compact ? 20 : 24, FontWeight.w600),
    h6Padding: EdgeInsets.zero,
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: const TextStyle(fontStyle: FontStyle.italic),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    code: codeFont,
    codeblockPadding: const EdgeInsets.all(16),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    codeblockAlign: WrapAlignment.start,
    blockquote: body.copyWith(color: colors.onSurfaceVariant),
    blockquotePadding: const EdgeInsets.fromLTRB(14, 0, 0, 0),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: colors.outlineVariant, width: 2)),
    ),
    blockquoteAlign: WrapAlignment.start,
    listBullet: body.copyWith(color: colors.onSurfaceVariant),
    listBulletPadding: const EdgeInsets.only(right: 6),
    listIndent: 18,
    orderedListAlign: WrapAlignment.start,
    unorderedListAlign: WrapAlignment.start,
    tableHead: body.copyWith(fontWeight: FontWeight.w600),
    tableBody: body,
    tableBorder: TableBorder.all(color: colors.outlineVariant, width: .5),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    tableHeadCellsDecoration: BoxDecoration(
      color: colors.surfaceContainerHighest.withValues(alpha: .5),
    ),
    tableHeadAlign: TextAlign.left,
    tableScrollbarThumbVisibility: false,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.outlineVariant, width: .5)),
    ),
    textScaler: MediaQuery.textScalerOf(context),
    blockSpacing: compact ? 12 : 16,
  );
}

/// Markdown images use the explicit Session-scoped image reader only after a
/// reply settles. No default file or network image loader is installed.
class PocketMarkdown extends StatefulWidget {
  const PocketMarkdown({
    required this.data,
    this.runtime,
    this.sessionId,
    this.onOpenLink,
    this.onOpenFile,
    this.selectable = true,
    this.compact = false,
    super.key,
  });
  final String data;
  final RuntimeController? runtime;
  final String? sessionId;
  final bool selectable;
  final bool compact;
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
    if (oldWidget.compact != widget.compact) _updateStyle();
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
    _updateStyle();
  }

  void _updateStyle() {
    _style = pocketMarkdownStyleSheet(context, compact: widget.compact);
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
        extensionSet: pocketMarkdownExtensions,
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
          'pre': _PocketCodeBlockBuilder(
            style: _style.code!,
            decoration:
                _style.codeblockDecoration as BoxDecoration? ??
                const BoxDecoration(),
          ),
          'code': _PocketInlineCodeBuilder(
            style: _style.code!,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: .5,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          'hr': _PocketRuleBuilder(
            color: Theme.of(context).colorScheme.outlineVariant,
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
        imageBuilder: (uri, title, alt) {
          final destination = uri.toString();
          final file = _file(destination);
          if (file != null && widget.runtime != null) {
            return PocketInlineImage(
              key: ValueKey((file.sessionId, file.path)),
              source: PocketImageSource.workspaceFile(
                widget.runtime!,
                file.sessionId,
                file.path,
              ),
              onOpenFile: widget.onOpenFile == null
                  ? null
                  : () => widget.onOpenFile!(file),
            );
          }
          final external = chatExternalUri(destination);
          return PocketTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(alt?.isNotEmpty == true ? alt! : title ?? '图片链接'),
            subtitle: Text(external == null ? '图片暂不可预览' : '点击打开图片链接'),
            onTap: () => unawaited(_open(destination, allowFile: false)),
          );
        },
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

/// Fenced code uses the DSH mobile style: padded rounded block, `pre-wrap` so
/// long lines wrap instead of forcing a horizontal drag.
class _PocketCodeBlockBuilder extends MarkdownElementBuilder {
  _PocketCodeBlockBuilder({required this.style, required this.decoration});

  final TextStyle style;
  final BoxDecoration decoration;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: decoration,
      child: Text(text, style: style, softWrap: true),
    );
  }
}

/// Horizontal rules use the DSH 32px vertical rhythm around a 0.5px line.
class _PocketRuleBuilder extends MarkdownElementBuilder {
  _PocketRuleBuilder({required this.color});

  final Color color;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Container(height: .5, color: color),
  );
}

/// Inline code gets the DSH chip treatment: 0.875em monospace, subtle fill,
/// 0.5px border, radius 4 and horizontal padding 5.
class _PocketInlineCodeBuilder extends MarkdownElementBuilder {
  _PocketInlineCodeBuilder({required this.style, required this.decoration});

  final TextStyle style;
  final BoxDecoration decoration;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: decoration,
      child: Text(element.textContent, style: style),
    );
  }
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
    this.color,
  });
  final String storageId, title;
  final IconData icon;
  final WidgetBuilder body;
  final Color? color;
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
            color:
                widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        label: widget.title,
        color: widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
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
