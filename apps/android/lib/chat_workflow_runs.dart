import 'dart:async';
import 'dart:collection';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'subagents_data.dart';

enum WorkflowRunStatus { running, completed, failed, cancelled, interrupted }

extension WorkflowRunStatusLabel on WorkflowRunStatus {
  String get label => switch (this) {
    WorkflowRunStatus.running => '运行中',
    WorkflowRunStatus.completed => '已完成',
    WorkflowRunStatus.failed => '失败',
    WorkflowRunStatus.cancelled => '已取消',
    WorkflowRunStatus.interrupted => '已中断',
  };
}

/// One durable member. A missing phase and an explicitly empty phase differ.
class WorkflowRunMember {
  const WorkflowRunMember({
    required this.seq,
    required this.label,
    required this.childId,
    required this.status,
  });

  final int seq;
  final String label, childId;
  final WorkflowRunStatus status;
}

class WorkflowRunPhase {
  const WorkflowRunPhase({required this.phase, required this.members});
  final String? phase;
  final List<WorkflowRunMember> members;
  String get title => phase == null
      ? '未分阶段'
      : phase!.isEmpty
      ? '空阶段名'
      : phase!;
}

class WorkflowRunRecord {
  const WorkflowRunRecord({
    required this.runId,
    required this.name,
    required this.seq,
    required this.event,
    required this.status,
    required this.phases,
  });

  final String runId, name;
  final int seq;
  final Json event;
  final WorkflowRunStatus status;
  final List<WorkflowRunPhase> phases;
  int get memberCount =>
      phases.fold(0, (count, phase) => count + phase.members.length);
  String get key => 'workflow-run:$runId';
}

class _MemberState {
  _MemberState(this.seq, this.label, this.childId, this.phase);
  final int seq;
  final String label, childId;
  final String? phase;
  WorkflowRunStatus status = WorkflowRunStatus.running;
}

class _RunState {
  _RunState(this.runId, this.name, this.event, this.turn);
  final String runId, name;
  final Json event;
  final int? turn;
  final members = <_MemberState>[];
  final bySeq = <int, _MemberState>{};
  WorkflowRunStatus status = WorkflowRunStatus.running;

  WorkflowRunRecord snapshot() {
    // Linked insertion order preserves the first-started phase and member order.
    final groups = <(bool, String?), List<WorkflowRunMember>>{};
    for (final member in members) {
      final key = (member.phase == null, member.phase);
      groups
          .putIfAbsent(key, () => [])
          .add(
            WorkflowRunMember(
              seq: member.seq,
              label: member.label,
              childId: member.childId,
              status:
                  member.status == WorkflowRunStatus.running &&
                      status == WorkflowRunStatus.interrupted
                  ? WorkflowRunStatus.interrupted
                  : member.status,
            ),
          );
    }
    return WorkflowRunRecord(
      runId: runId,
      name: name,
      seq: event['seq'] as int,
      event: event,
      status: status,
      phases: List.unmodifiable([
        for (final entry in groups.entries)
          WorkflowRunPhase(
            phase: entry.key.$2,
            members: List.unmodifiable(entry.value),
          ),
      ]),
    );
  }
}

/// Replays only original `tool-workflow/*` facts already in the Session log.
///
/// Update-only history tails stay pending until their start page arrives. A
/// prepended or replaced window replays; ordinary appends inspect new events
/// once. No workflow engine or execution endpoint is called from this view.
class ChatWorkflowRunProjection {
  final _seen = <Json>[];
  final _runs = <String, _RunState>{};
  List<Json>? _source;
  int? _turn;
  List<WorkflowRunRecord> _records = const [];
  List<WorkflowRunRecord> get records => _records;
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
    var changed = false;
    if (prefix != _seen.length) {
      changed = _runs.isNotEmpty;
      _seen.clear();
      _runs.clear();
      _turn = null;
      prefix = 0;
    }
    for (var index = prefix; index < events.length; index++) {
      final event = events[index];
      changed = _consume(event) || changed;
      _seen.add(event);
      processedEventCount++;
    }
    if (changed) {
      _records = UnmodifiableListView(
        _runs.values.map((run) => run.snapshot()).toList()
          ..sort((a, b) => a.seq.compareTo(b.seq)),
      );
      revision++;
    }
  }

  bool _consume(Json event) {
    final data = event['data'];
    if (data is! Json || event['seq'] is! int) return false;
    switch (event['type']) {
      case 'turn/start':
        _turn = data['turn'] is int ? data['turn'] as int : null;
        return false;
      case 'step/start':
        if (data['turn'] is int) _turn = data['turn'] as int;
        return false;
      case 'tool-workflow/run-start':
        final id = data['runId'], name = data['name'];
        if (id is! String ||
            id.isEmpty ||
            name is! String ||
            _runs.containsKey(id)) {
          return false;
        }
        _runs[id] = _RunState(id, name, event, _turn);
        return true;
      case 'tool-workflow/agent-start':
        final run = _run(data);
        final seq = data['seq'], label = data['label'], child = data['childId'];
        final phase = data['phase'];
        if (run == null ||
            seq is! int ||
            label is! String ||
            child is! String ||
            (phase != null && phase is! String) ||
            run.bySeq.containsKey(seq)) {
          return false;
        }
        final member = _MemberState(seq, label, child, phase as String?);
        run.members.add(member);
        run.bySeq[seq] = member;
        return true;
      case 'tool-workflow/agent-end':
        final member = _run(data)?.bySeq[data['seq']];
        final status = _outcome(data['outcome']);
        if (member == null || status == null || member.status == status) {
          return false;
        }
        member.status = status;
        return true;
      case 'tool-workflow/run-end':
        final run = _run(data);
        final status = _reason(data['stopReason']);
        if (run == null || status == null || run.status == status) return false;
        run.status = status;
        return true;
      case 'turn/end':
        final turn = data['turn'];
        final reason = data['reason'];
        final kind = reason is Json ? reason['kind'] : null;
        if (turn is! int || kind != 'interrupted' && kind != 'forked') {
          return false;
        }
        var changed = false;
        for (final run in _runs.values) {
          if (run.turn == turn && run.status == WorkflowRunStatus.running) {
            run.status = WorkflowRunStatus.interrupted;
            changed = true;
          }
        }
        return changed;
      default:
        return false;
    }
  }

  _RunState? _run(Json data) =>
      data['runId'] is String ? _runs[data['runId'] as String] : null;

  WorkflowRunStatus? _outcome(dynamic value) => switch (value) {
    'completed' => WorkflowRunStatus.completed,
    'failed' => WorkflowRunStatus.failed,
    'cancelled' => WorkflowRunStatus.cancelled,
    _ => null,
  };

  WorkflowRunStatus? _reason(dynamic value) => switch (value) {
    'completed' => WorkflowRunStatus.completed,
    'error' => WorkflowRunStatus.failed,
    'cancelled' => WorkflowRunStatus.cancelled,
    _ => null,
  };
}

/// A compact read-only disclosure. This deliberately offers no Run action.
class ChatWorkflowRunCard extends StatefulWidget {
  const ChatWorkflowRunCard({
    required this.record,
    this.runtime,
    this.parentSessionId,
    this.onOpenChild,
    super.key,
  });
  final WorkflowRunRecord record;
  final RuntimeController? runtime;
  final String? parentSessionId;
  final Future<void> Function(SubagentAddress address, String label)?
  onOpenChild;
  @override
  State<ChatWorkflowRunCard> createState() => _ChatWorkflowRunCardState();
}

class _ChatWorkflowRunCardState extends State<ChatWorkflowRunCard> {
  late bool open = widget.record.status != WorkflowRunStatus.completed;
  final phaseOpen = <String, bool>{};
  final _navigable = <String, SubagentAddress>{};
  Timer? _refreshTimer;
  bool _checking = false;
  int _read = 0;
  int? _connection;

  @override
  void initState() {
    super.initState();
    _connection = widget.runtime?.connectionGeneration;
    widget.runtime?.addListener(_runtimeChanged);
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (open && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_refreshChildren());
      }
    });
    if (open) _scheduleRefresh();
  }

  void _scheduleRefresh() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) unawaited(_refreshChildren());
  });

  void _runtimeChanged() {
    final runtime = widget.runtime;
    if (runtime == null) return;
    final changedConnection = _connection != runtime.connectionGeneration;
    if (changedConnection || !runtime.ready) {
      _connection = runtime.connectionGeneration;
      _read++;
      if (_navigable.isNotEmpty && mounted) setState(_navigable.clear);
    }
    if (changedConnection && runtime.ready && open) _scheduleRefresh();
  }

  @override
  void dispose() {
    _read++;
    _refreshTimer?.cancel();
    widget.runtime?.removeListener(_runtimeChanged);
    super.dispose();
  }

  Future<void> _refreshChildren() async {
    final runtime = widget.runtime;
    final parent = widget.parentSessionId;
    if (_checking ||
        !open ||
        runtime == null ||
        !runtime.ready ||
        parent == null ||
        widget.onOpenChild == null) {
      return;
    }
    final candidates = {
      for (final phase in widget.record.phases)
        for (final member in phase.members)
          if (member.status == WorkflowRunStatus.running) member.childId,
    };
    final read = ++_read;
    final connection = runtime.connectionGeneration;
    _checking = true;
    try {
      final available = <String, SubagentAddress>{};
      var offset = 0;
      while (candidates.isNotEmpty) {
        final result =
            await runtime
                    .call('subagents.catalog', {
                      'parentSessionId': parent,
                      'offset': offset,
                      'limit': 100,
                    })
                    .timeout(subagentRequestTimeout)
                as Json;
        if (!mounted ||
            read != _read ||
            !runtime.ready ||
            runtime.connectionGeneration != connection) {
          return;
        }
        if (result['parentSessionId'] != parent) {
          throw const FormatException('Mismatched workflow parent catalog');
        }
        for (final entry in (result['entries'] as List).cast<Json>()) {
          final id = entry['id'];
          if (id is! String || !candidates.contains(id)) continue;
          candidates.remove(id);
          final raw = entry['address'];
          if (raw is! Json ||
              entry['attached'] != true ||
              entry['running'] != true ||
              raw['parentSessionId'] != parent ||
              raw['childSessionId'] != id ||
              !const [
                'continuable',
                'one-shot',
                'unknown',
              ].contains(raw['mode'])) {
            continue;
          }
          var address = SubagentAddress.fromJson(raw);
          if (address.mode == 'unknown') {
            // A parent catalog can outlive an unreadable child descriptor.
            // Only the child's own inspected identity may resolve this mode.
            try {
              final inspection =
                  await runtime
                          .call('subagents.inspect', {
                            'address': address.json,
                            'maxMessages': 1,
                          })
                          .timeout(subagentRequestTimeout)
                      as Json;
              if (!mounted ||
                  read != _read ||
                  !runtime.ready ||
                  runtime.connectionGeneration != connection) {
                return;
              }
              final verified = inspection['address'];
              final capabilities = inspection['capabilities'];
              if (verified is! Json ||
                  capabilities is! Json ||
                  verified['parentSessionId'] != parent ||
                  verified['childSessionId'] != id ||
                  !const [
                    'continuable',
                    'one-shot',
                  ].contains(verified['mode']) ||
                  capabilities['attached'] != true ||
                  capabilities['running'] != true) {
                continue;
              }
              address = SubagentAddress.fromJson(verified);
            } catch (_) {
              // An unreadable child cannot be made navigable by its parent row.
              continue;
            }
          }
          available[id] = address;
        }
        final next = result['nextOffset'];
        if (next == null) break;
        if (next is! int || next <= offset) {
          throw const FormatException('Workflow catalog did not advance');
        }
        offset = next;
      }
      if (mounted &&
          read == _read &&
          runtime.connectionGeneration == connection) {
        setState(() {
          _navigable
            ..clear()
            ..addAll(available);
        });
      }
    } catch (_) {
      // A failed live read cannot authorize navigation from historical events.
      if (mounted && read == _read) setState(_navigable.clear);
    } finally {
      _checking = false;
    }
  }

  Future<void> _openMember(WorkflowRunMember member) async {
    final runtime = widget.runtime;
    final parent = widget.parentSessionId;
    final address = _navigable[member.childId];
    if (runtime == null ||
        !runtime.ready ||
        parent == null ||
        address == null ||
        widget.onOpenChild == null ||
        member.status != WorkflowRunStatus.running) {
      return;
    }
    final connection = runtime.connectionGeneration;
    try {
      final result =
          await runtime
                  .call('subagents.inspect', {
                    'address': address.json,
                    'maxMessages': 1,
                  })
                  .timeout(subagentRequestTimeout)
              as Json;
      if (!mounted ||
          !runtime.ready ||
          runtime.connectionGeneration != connection ||
          widget.parentSessionId != parent ||
          !_navigable.containsKey(member.childId) ||
          !widget.record.phases.any(
            (phase) => phase.members.any(
              (current) =>
                  current.seq == member.seq &&
                  current.childId == member.childId &&
                  current.status == WorkflowRunStatus.running,
            ),
          )) {
        return;
      }
      final verified = result['address'];
      final capabilities = result['capabilities'];
      if (verified is! Json ||
          capabilities is! Json ||
          verified['parentSessionId'] != parent ||
          verified['childSessionId'] != member.childId ||
          verified['mode'] != address.mode ||
          capabilities['attached'] != true ||
          capabilities['running'] != true) {
        _navigationUnavailable(member.childId);
        return;
      }
      await widget.onOpenChild!(address, member.label);
    } catch (_) {
      if (mounted && runtime.connectionGeneration == connection) {
        _navigationUnavailable(member.childId);
      }
    }
  }

  void _navigationUnavailable(String childId) {
    setState(() => _navigable.remove(childId));
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('子会话状态已变化，请刷新后重试。')));
  }

  String phaseKey(String? phase) =>
      phase == null ? 'missing' : 'value:${phase.length}:$phase';

  @override
  void didUpdateWidget(ChatWorkflowRunCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime?.removeListener(_runtimeChanged);
      widget.runtime?.addListener(_runtimeChanged);
      _connection = widget.runtime?.connectionGeneration;
      _read++;
      _navigable.clear();
    }
    if (oldWidget.record.runId != widget.record.runId) {
      open = widget.record.status != WorkflowRunStatus.completed;
      phaseOpen.clear();
      _read++;
      _navigable.clear();
      if (open) _scheduleRefresh();
      return;
    }
    if (oldWidget.parentSessionId != widget.parentSessionId) {
      _read++;
      _navigable.clear();
    }
    _navigable.removeWhere(
      (id, _) => !widget.record.phases.any(
        (phase) => phase.members.any(
          (member) =>
              member.childId == id &&
              member.status == WorkflowRunStatus.running,
        ),
      ),
    );
    final previous = {
      for (final phase in oldWidget.record.phases) phaseKey(phase.phase): phase,
    };
    for (final phase in widget.record.phases) {
      final key = phaseKey(phase.phase);
      final old = previous[key];
      if (old == null) continue;
      final oldClean = old.members.every(
        (member) => member.status == WorkflowRunStatus.completed,
      );
      final nowClean = phase.members.every(
        (member) => member.status == WorkflowRunStatus.completed,
      );
      final newAbnormal = phase.members.any(
        (member) =>
            member.status == WorkflowRunStatus.failed ||
            member.status == WorkflowRunStatus.cancelled ||
            member.status == WorkflowRunStatus.interrupted,
      );
      final oldAbnormal = old.members.any(
        (member) =>
            member.status == WorkflowRunStatus.failed ||
            member.status == WorkflowRunStatus.cancelled ||
            member.status == WorkflowRunStatus.interrupted,
      );
      if (oldClean &&
          (!nowClean || old.members.length != phase.members.length)) {
        phaseOpen[key] = true;
        open = true;
      } else if (!oldAbnormal && newAbnormal) {
        phaseOpen[key] = true;
        open = true;
      } else if (!oldClean && nowClean) {
        phaseOpen[key] = false;
      }
    }
    if (oldWidget.record.status != widget.record.status) {
      if (widget.record.status == WorkflowRunStatus.completed) open = false;
      if (widget.record.status == WorkflowRunStatus.failed ||
          widget.record.status == WorkflowRunStatus.interrupted ||
          widget.record.status == WorkflowRunStatus.cancelled) {
        open = true;
      }
    }
    if (open && oldWidget.record.phases != widget.record.phases) {
      _scheduleRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: open,
            label:
                '${record.name}，${record.memberCount} 个成员，${record.status.label}',
            child: InkWell(
              onTap: () {
                setState(() => open = !open);
                if (open) _scheduleRefresh();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      open ? Icons.expand_more : Icons.chevron_right,
                      size: 20,
                      color: color,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        record.name.isEmpty ? '未命名工作流' : record.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${record.memberCount} 个成员',
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                    const SizedBox(width: 6),
                    _Status(status: record.status),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: record.phases.isEmpty
                  ? Text('没有启动成员', style: TextStyle(color: color))
                  : Column(
                      children: [
                        for (final phase in record.phases)
                          _phase(context, phase),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  Widget _phase(BuildContext context, WorkflowRunPhase phase) {
    final key = phaseKey(phase.phase);
    final abnormal = phase.members.any(
      (member) =>
          member.status == WorkflowRunStatus.failed ||
          member.status == WorkflowRunStatus.cancelled ||
          member.status == WorkflowRunStatus.interrupted,
    );
    final running = phase.members.any(
      (member) => member.status == WorkflowRunStatus.running,
    );
    final expanded = phaseOpen[key] ?? (abnormal || running);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          label: '${phase.title}，${phase.members.length} 个成员',
          child: InkWell(
            onTap: () => setState(() => phaseOpen[key] = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      phase.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${phase.members.length} 个成员',
                    style: TextStyle(color: color, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Column(
              children: [
                for (final member in phase.members)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: InkWell(
                      onTap:
                          _navigable.containsKey(member.childId) &&
                              member.status == WorkflowRunStatus.running
                          ? () => _openMember(member)
                          : null,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              member.label.isEmpty ? '空成员名' : member.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _Status(status: member.status),
                          if (_navigable.containsKey(member.childId) &&
                              member.status == WorkflowRunStatus.running) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.status});
  final WorkflowRunStatus status;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      WorkflowRunStatus.failed => scheme.error,
      WorkflowRunStatus.completed => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 7, color: color),
        const SizedBox(width: 4),
        Text(status.label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}
