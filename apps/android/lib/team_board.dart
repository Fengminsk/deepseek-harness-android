import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

/// Platform failure code when the bridge reports one, else a neutral label.
String teamFailureCode(Object failure) =>
    failure is PlatformException ? failure.code : 'unconfirmed';

/// One visible task of the shared Team board.
///
/// The Host projection already resolves readiness and advisory write-scope
/// overlaps; this type only renames the wire fields for display.
class TeamTaskRow {
  const TeamTaskRow({
    required this.id,
    required this.subject,
    required this.description,
    required this.status,
    required this.owner,
    required this.ready,
    required this.warnings,
  });

  final String id;
  final String subject;
  final String description;

  /// `pending`, `in_progress`, or `completed`; deleted rows never reach the app.
  final String status;
  final String owner;
  final bool ready;
  final List<String> warnings;

  /// A pending task whose blockers are unfinished.
  bool get blocked => status == 'pending' && !ready;
}

/// Display state of one Session's Team board from the `agentTeam` projection.
class TeamBoardState {
  const TeamBoardState({
    required this.enabled,
    required this.tasks,
    this.failure,
  });

  final bool enabled;
  final List<TeamTaskRow> tasks;
  final String? failure;

  int get completed => tasks.where((task) => task.status == 'completed').length;
  int get active => tasks.where((task) => task.status == 'in_progress').length;
  int get pending => tasks.length - completed - active;

  /// Parse one `agentTeam` projection value; `null` when the value is absent.
  static TeamBoardState? fromJson(dynamic value) {
    if (value is! Map) return null;
    final enabled = value['enabled'];
    final tasks = value['tasks'];
    if (enabled is! bool || tasks is! List) {
      throw const FormatException('团队任务状态格式无效');
    }
    final failure = value['failure'];
    if (failure != null && failure is! String) {
      throw const FormatException('团队任务错误信息格式无效');
    }
    return TeamBoardState(
      enabled: enabled,
      failure: failure as String?,
      tasks: [
        for (final raw in tasks)
          if (raw is Map && raw['status'] != 'deleted')
            TeamTaskRow(
              id: _string(raw['id'], 'id'),
              subject: _string(raw['subject'], 'subject'),
              description: raw['description'] is String
                  ? raw['description'] as String
                  : '',
              status: _status(raw['status']),
              owner: (raw['ownerName'] ?? raw['ownerId']) is String
                  ? (raw['ownerName'] ?? raw['ownerId']) as String
                  : '未指派',
              ready: raw['ready'] == true,
              warnings: [
                if (raw['warnings'] is List)
                  for (final warning in raw['warnings'] as List)
                    if (warning is String) warning,
              ],
            ),
      ],
    );
  }

  static String _string(Object? value, String field) {
    if (value is String && value.isNotEmpty) return value;
    throw FormatException('团队任务 $field 无效');
  }

  static String _status(Object? value) {
    if (value == 'pending' || value == 'in_progress' || value == 'completed') {
      return value as String;
    }
    throw const FormatException('团队任务状态无效');
  }
}

/// `已完成 N · 进行中 N · 待处理 N`, omitting empty counts.
String teamProgressLabel(TeamBoardState board) {
  final parts = <String>[
    if (board.completed > 0) '已完成 ${board.completed}',
    if (board.active > 0) '进行中 ${board.active}',
    if (board.pending > 0) '待处理 ${board.pending}',
  ];
  return parts.join('  ·  ');
}

/// Read-only task board appended to the shared subagent catalog.
///
/// The Web places this section under its subagent panel; the Android catalog is
/// a page, so the same section opens above that page's list. Membership listing
/// and teammate conversations stay with the ordinary subagent entries.
class TeamBoardSection extends StatefulWidget {
  const TeamBoardSection({
    required this.runtime,
    required this.sessionId,
    super.key,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<TeamBoardSection> createState() => TeamBoardSectionState();
}

class TeamBoardSectionState extends State<TeamBoardSection> {
  TeamBoardState? board;
  String? error;
  bool loading = false;
  bool switching = false;
  String? expandedTask;
  int generation = 0;
  late int connectionGeneration;
  late String phase;

  @override
  void initState() {
    super.initState();
    connectionGeneration = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(runtimeChanged);
    unawaited(reload());
  }

  @override
  void dispose() {
    widget.runtime.removeListener(runtimeChanged);
    super.dispose();
  }

  void runtimeChanged() {
    if (phase == widget.runtime.phase &&
        connectionGeneration == widget.runtime.connectionGeneration) {
      return;
    }
    phase = widget.runtime.phase;
    connectionGeneration = widget.runtime.connectionGeneration;
    generation++;
    if (widget.runtime.ready) unawaited(reload());
  }

  /// Read the Team projection again; stale responses are discarded.
  Future<void> reload() async {
    if (!widget.runtime.ready || loading) return;
    final attempt = generation;
    setState(() => loading = true);
    try {
      final value = await widget.runtime.call('api.call', {
        'namespace': 'session',
        'method': 'projections',
        'args': {
          'request': {'sessionId': widget.sessionId},
        },
      });
      if (!mounted || attempt != generation) return;
      final projections = value is Map ? value['values'] : null;
      final team = projections is Map ? projections['agentTeam'] : null;
      final parsed = TeamBoardState.fromJson(team);
      setState(() {
        board = parsed;
        error = null;
      });
    } catch (failure) {
      if (!mounted || attempt != generation) return;
      setState(() => error = '团队任务未能读取。${teamFailureCode(failure)}');
    } finally {
      if (mounted && attempt == generation) setState(() => loading = false);
    }
  }

  /// Ask before hiding a board that already records tasks.
  Future<void> _toggle() async {
    final current = board;
    if (current == null || switching) return;
    final next = !current.enabled;
    if (!next && current.tasks.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('关闭团队模式？'),
          content: const Text('共享任务板将不再显示；已经记录的任务仍保留在会话日志中。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => switching = true);
    try {
      await widget.runtime.call('api.call', {
        'namespace': 'agentTeams',
        'method': 'setEnabled',
        'args': {'agentId': widget.sessionId, 'enabled': next},
      });
      if (!mounted) return;
      setState(() => error = null);
      await reload();
    } catch (failure) {
      if (mounted) {
        setState(() => error = '团队模式未能切换。${teamFailureCode(failure)}');
      }
    } finally {
      if (mounted) setState(() => switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = board;
    final failure = current?.failure;
    final rows = current?.tasks ?? const <TeamTaskRow>[];
    final enabled = current?.enabled == true;
    return PocketSection(
      title: '团队任务',
      children: [
        PocketRow(
          icon: Icons.checklist_rounded,
          title: enabled ? '团队模式已开启' : '团队模式未开启',
          subtitle: enabled
              ? '共享任务板只读展示；成员与对话仍在子 Agent 列表中。'
              : '开启后，本会话的共享任务会显示在这里。',
          trailing: switching || (current == null && loading)
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Switch(
                  value: enabled,
                  onChanged: current == null || !widget.runtime.ready
                      ? null
                      : (_) => unawaited(_toggle()),
                ),
        ),
        if (current != null && current.enabled &&
            teamProgressLabel(current).isNotEmpty)
          PocketRow(
            icon: Icons.timeline_rounded,
            title: teamProgressLabel(current),
          ),
        if (failure != null)
          PocketRow(icon: Icons.error_outline_rounded, title: failure),
        if (error != null)
          PocketRow(icon: Icons.error_outline_rounded, title: error!),
        if (enabled && rows.isEmpty)
          const PocketRow(
            icon: Icons.checklist_rounded,
            title: '暂无团队任务',
          ),
        if (enabled)
          for (final row in rows) _TeamTaskTile(
            key: ValueKey('team-task-${row.id}'),
            task: row,
            expanded: expandedTask == row.id,
            onToggle: () => setState(
              () => expandedTask = expandedTask == row.id ? null : row.id,
            ),
          ),
      ],
    );
  }
}

class _TeamTaskTile extends StatelessWidget {
  const _TeamTaskTile({
    required this.task,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final TeamTaskRow task;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (task.status) {
      'completed' => colors.tertiary,
      'in_progress' => colors.primary,
      _ => task.blocked ? colors.error : colors.outline,
    };
    final statusLabel = switch (task.status) {
      'completed' => '已完成',
      'in_progress' => '进行中',
      _ => task.blocked ? '被阻塞' : '待处理',
    };
    return Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      task.subject,
                      maxLines: expanded ? null : 1,
                      overflow: expanded ? null : TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              if (expanded) ...[
                if (task.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 6, 0, 0),
                    child: Text(
                      task.description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 0, 0),
                  child: Text(
                    '负责人：${task.owner}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final warning in task.warnings)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 0, 0),
                    child: Text(
                      warning,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
