import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_deliverables.dart';
import 'chat_execution_data.dart';
import 'chat_messages.dart'
    show ChatOpenLink, ChatOpenFile, PocketMarkdown, chatExternalUri;
import 'chat_plan.dart';
import 'chat_projection.dart';
import 'chat_reply_sources.dart';
import 'chat_reply_sources_sheet.dart';
import 'chat_source_identity.dart';
import 'runtime.dart';
import 'tool_activity_data.dart';
import 'tool_activity_details.dart';
import 'tool_activity_presentation.dart';
import 'ui.dart';

/// Transparent, single-line resting state. Only an explicit completed Turn
/// without unresolved calls receives the completion mark.
class ChatExecutionHeader extends StatelessWidget {
  const ChatExecutionHeader({
    required this.chain,
    required this.expanded,
    required this.onToggle,
    super.key,
  });
  final ChatExecutionChain chain;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ink = chain.needsAttention ? colors.error : colors.onSurfaceVariant;
    final title = expanded && chain.completed ? '规划与执行' : chain.title;
    return Semantics(
      button: true,
      expanded: expanded,
      label: title,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    chain.completed && !expanded
                        ? Icons.check_circle_rounded
                        : chain.needsAttention
                        ? Icons.error_outline_rounded
                        : Icons.psychology_outlined,
                    size: 22,
                    color: chain.completed ? colors.primary : ink,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: ink, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (expanded && chain.duration != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      chain.duration!,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: ink,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Each step is its own lazy-list child, including large tool histories. Only
/// the visible search previews decode structured results; raw logs stay in the
/// existing live detail route instead of expanding the transcript.
class ChatExecutionStep extends StatefulWidget {
  const ChatExecutionStep({
    required this.entry,
    required this.storageId,
    required this.last,
    this.continuation = false,
    this.live = false,
    this.thinking = false,
    this.liveContent = const [],
    this.todo,
    this.plan,
    this.sessionId,
    this.runtime,
    this.onOpenFile,
    this.activitySource,
    this.onOpenLink,
    super.key,
  });
  final ChatEntry entry;
  final String storageId;
  final bool last, continuation, live, thinking;
  final String? sessionId;
  final RuntimeController? runtime;
  final ChatOpenFile? onOpenFile;
  final ChatSubmittedPlan? plan;
  final List<dynamic> liveContent;
  final ChatTodoSnapshot? todo;
  final ValueListenable<ToolActivity?>? activitySource;
  final ChatOpenLink? onOpenLink;
  @override
  State<ChatExecutionStep> createState() => _ChatExecutionStepState();
}

class _ChatExecutionStepState extends State<ChatExecutionStep>
    with AutomaticKeepAliveClientMixin {
  bool? _expanded;
  ToolActivityDetailsController? _details;
  PopupRoute<void>? _sourcesRoute;
  NavigatorState? _navigator;
  bool _openingLink = false;
  @override
  bool get wantKeepAlive => _details != null || _sourcesRoute != null;

  @override
  void didUpdateWidget(covariant ChatExecutionStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId ||
        oldWidget.activitySource != widget.activitySource) {
      _details?.close();
      _details = null;
      _expanded = null;
      _closeSources();
    } else if (!identical(oldWidget.entry.tool, widget.entry.tool)) {
      if (widget.activitySource == null && widget.entry.tool != null) {
        _details?.update(widget.entry.tool!);
      }
      _closeSources();
    }
  }

  void _closeSources() {
    final route = _sourcesRoute, navigator = _navigator;
    _sourcesRoute = null;
    if (route == null || navigator == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    });
  }

  @override
  void dispose() {
    // A timeline-owned source keeps a detail route alive through lazy folding.
    if (widget.activitySource == null) _details?.close();
    _closeSources();
    super.dispose();
  }

  Future<void> _inspect() async {
    if (_details != null ||
        widget.entry.tool == null ||
        (widget.activitySource != null &&
            widget.activitySource!.value == null)) {
      return;
    }
    final details = ToolActivityDetailsController.open(
      context,
      widget.entry.tool!,
      source: widget.activitySource,
    );
    _details = details;
    updateKeepAlive();
    await details.closed;
    if (!mounted || !identical(_details, details)) return;
    _details = null;
    updateKeepAlive();
  }

  Future<void> _openLink(Uri uri) async {
    if (_openingLink) return;
    _openingLink = true;
    try {
      await (widget.onOpenLink?.call(uri) ??
          RuntimeController.channel.invokeMethod<void>(
            'openUrl',
            uri.toString(),
          ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    } finally {
      _openingLink = false;
    }
  }

  Future<void> _allSources(ChatReplySources sources) async {
    if (_sourcesRoute != null) return;
    final navigator = Navigator.of(context);
    final route = chatReplySourcesRoute(
      context,
      sources,
      answerLinks: const {},
      onOpenSource: _openLink,
    );
    _navigator = navigator;
    _sourcesRoute = route;
    updateKeepAlive();
    await navigator.push<void>(route);
    if (!mounted) return;
    if (identical(_sourcesRoute, route)) _sourcesRoute = null;
    updateKeepAlive();
  }

  bool get expanded => _expanded ??=
      PageStorage.maybeOf(context)
          ?.readState(context, identifier: widget.storageId) ==
      true;
  void _toggle() {
    setState(() => _expanded = !expanded);
    PageStorage.maybeOf(context)
        ?.writeState(context, expanded, identifier: widget.storageId);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).colorScheme;
    final entry = widget.entry, activity = entry.tool, todo = widget.todo;
    final completion = entry.key.startsWith('execution-end:');
    final reasoning = chatReasoningText(
      widget.live ? widget.liveContent : entry.content,
    );
    final presentation = activity == null
        ? null
        : ToolActivityPresentation.from(activity);
    final attention =
        entry.error ||
        (activity != null && toolActivityNeedsAttention(activity));
    final ink = attention
        ? colors.error
        : completion
        ? colors.primary
        : colors.onSurfaceVariant;
    final title = activity != null
        ? toolActivityName(activity)
        : todo != null
        ? '计划'
        : widget.plan != null
        ? '已提交计划'
        : entry.kind == ChatEntryKind.assistant
        ? (widget.thinking ? '正在思考' : '已思考')
        : entry.title ?? '任务状态';
    final duration = activity == null || activity.events.isEmpty
        ? null
        : chatEventDuration(
            activity.events.firstWhere(
              (event) => event['type'] == 'tool/call',
              orElse: () => const {},
            ),
            activity.events
                .where((event) => event['type'] == 'tool/result')
                .lastOrNull,
          );
    final family = activity == null ? '' : toolActivityFamily(activity);
    final icon = completion
        ? Icons.check_rounded
        : activity == null
        ? (todo == null ? Icons.psychology_outlined : Icons.checklist_rounded)
        : switch (family) {
            'web_search' || 'web_fetch' => Icons.language_rounded,
            'shell' => Icons.terminal_rounded,
            'file-search' => Icons.search_rounded,
            _ => Icons.description_outlined,
          };
    final body = <Widget>[];
    if (activity != null) {
      final args = activity.args;
      final raw = activity.name == 'web_fetch'
          ? (args?['url'])
          : activity.name == 'web_search'
          ? (args?['query'])
          : presentation!.preview;
      final preview = raw is String && raw.trim().isNotEmpty
          ? raw
          : presentation!.status(activity);
      final uri = activity.name == 'web_fetch'
          ? chatExternalUri(preview)
          : null;
      body.add(
        _compactRow(
          label: preview,
          leading: uri != null
              ? ChatSourceHostMark(host: uri.host, size: 24)
              : activity.name == 'web_search'
              ? Icon(Icons.search_rounded, size: 19, color: ink)
              : null,
          trailing: _statusMark(activity, presentation!, colors),
          onTap: _inspect,
          semantics: '$title，${presentation.status(activity)}，$preview，查看调用详情',
        ),
      );
      if (activity.name == 'web_search') {
        final sources = ChatReplySources.fromActivities([activity]);
        for (final source in sources.entries.take(2)) {
          body.add(
            _compactRow(
              label: source.label,
              subtitle: source.snippet?.isNotEmpty == true
                  ? source.snippet
                  : source.host,
              leading: ChatSourceHostMark(host: source.host, size: 24),
              onTap: source.destination == null
                  ? null
                  : () => _openLink(source.destination!),
              semantics: '打开来源 ${source.label}，${source.host}',
            ),
          );
        }
        if (sources.entries.length > 2) {
          body.add(
            _compactRow(
              label: '查看更多结果（${sources.entries.length - 2} 项）',
              leading: const Icon(Icons.more_horiz_rounded, size: 18),
              onTap: () => _allSources(sources),
              fill: false,
            ),
          );
        }
      }
      if (attention) {
        body.add(
          Padding(
            padding: const EdgeInsets.only(left: 10, top: 2, bottom: 4),
            child: Text(
              presentation.status(activity),
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.error),
            ),
          ),
        );
      }
    } else if (widget.plan case final plan?) {
      body.add(
        _compactRow(
          label: plan.title,
          onTap: () => Navigator.of(context).push<void>(
            PocketRoute(
              builder: (_) => ChatPlanDocumentPage(
                title: plan.title,
                markdown: plan.markdown,
                sessionId: widget.sessionId,
                onOpenLink: widget.onOpenLink,
                onOpenFile: widget.onOpenFile,
              ),
            ),
          ),
        ),
      );
    } else if (todo != null) {
      final items = todo.items;
      if (items == null || items.isEmpty) {
        body.add(_compactRow(label: todo.summary, onTap: null));
      } else {
        Widget itemAt(int index) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${index + 1}.',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
              Expanded(
                child: Text(
                  items[index].content,
                  maxLines: expanded ? null : 2,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 5),
              Icon(
                items[index].status == ChatTodoStatus.completed
                    ? Icons.check_rounded
                    : items[index].status == ChatTodoStatus.inProgress
                    ? Icons.more_horiz_rounded
                    : Icons.circle_outlined,
                size: 14,
                color: items[index].status == ChatTodoStatus.inProgress
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            ],
          ),
        );
        body.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 4, 8),
            child: expanded && items.length > 3
                ? SizedBox(
                    height: 260,
                    child: ListView.builder(
                      primary: false,
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      itemBuilder: (_, index) => itemAt(index),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var index = 0;
                        index < items.length.clamp(0, 3);
                        index++
                      )
                        itemAt(index),
                    ],
                  ),
          ),
        );
        if (items.length > 3) {
          body.add(
            _compactRow(
              label: expanded ? '收起计划' : '查看全部 ${items.length} 项',
              onTap: _toggle,
              fill: false,
            ),
          );
        }
      }
    } else {
      final text = reasoning ?? entry.text ?? '';
      if (expanded) {
        body.add(
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PocketMarkdown(
                      data: text,
                      runtime: widget.runtime,
                      sessionId: widget.sessionId,
                      onOpenLink: widget.onOpenLink,
                      onOpenFile: widget.onOpenFile,
                    ),
                    if (entry.details case final String details)
                      SelectableText(details),
                  ],
                ),
              ),
            ),
          ),
        );
      } else if (text.isNotEmpty) {
        body.add(
          _compactRow(
            label: text.replaceAll(RegExp(r'\s+'), ' ').trim(),
            onTap: _toggle,
            fill: false,
          ),
        );
      }
    }
    return Stack(
      children: [
        Positioned(
          left: 10,
          top: 0,
          bottom: widget.last ? 14 : 0,
          child: ColoredBox(
            color: colors.outlineVariant.withValues(alpha: .6),
            child: const SizedBox(width: 1),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(
            left: 34,
            bottom: activity?.name == 'web_fetch' && !widget.last ? 0 : 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.continuation)
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: completion
                        ? null
                        : activity == null
                        ? _toggle
                        : _inspect,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: attention
                                        ? colors.error
                                        : colors.onSurface,
                                  ),
                            ),
                          ),
                          if (duration != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              duration,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                          if (!completion) ...[
                            const SizedBox(width: 4),
                            Icon(
                              activity == null && expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.chevron_right_rounded,
                              size: 16,
                              color: ink,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ...body,
            ],
          ),
        ),
        if (!widget.continuation)
          Positioned(
            left: 0,
            top: 9,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.alphaBlend(
                  colors.onSurface.withValues(alpha: .12),
                  colors.surface,
                ),
              ),
              child: Icon(icon, size: 14, color: ink),
            ),
          ),
      ],
    );
  }

  Widget _statusMark(
    ToolActivity activity,
    ToolActivityPresentation presentation,
    ColorScheme colors,
  ) {
    final bad = toolActivityNeedsAttention(activity);
    final pending = activity.phase == ToolActivityPhase.pending;
    return Semantics(
      label: presentation.status(activity),
      child: Icon(
        bad
            ? Icons.error_outline_rounded
            : pending
            ? Icons.more_horiz_rounded
            : activity.phase == ToolActivityPhase.completed
            ? Icons.check_circle_rounded
            : Icons.help_outline_rounded,
        size: 17,
        color: bad
            ? colors.error
            : activity.phase == ToolActivityPhase.completed
            ? colors.primary
            : colors.onSurfaceVariant,
      ),
    );
  }

  Widget _compactRow({
    required String label,
    required VoidCallback? onTap,
    String? subtitle,
    Widget? leading,
    Widget? trailing,
    String? semantics,
    bool fill = true,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        label: semantics,
        button: onTap != null,
        child: Material(
          color: fill
              ? colors.onSurface.withValues(alpha: .035)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    if (leading != null) ...[
                      leading,
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (subtitle != null && subtitle != label)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    fontWeight: FontWeight.w400,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null || onTap != null) ...[
                      const SizedBox(width: 6),
                      trailing ??
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
