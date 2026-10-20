import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'approvals.dart';
import 'jobs.dart';
import 'runtime.dart';
import 'subagents.dart';
import 'ui.dart';

String taskStatusLabel(String? status) => switch (status) {
  'running' => '运行中',
  'waiting' => '等待授权或回答',
  'queued' => '待处理',
  'suspended' => '待处理 · 尚未恢复执行',
  'completed' => '已完成',
  'failed' => '失败',
  'cancelled' => '已取消',
  'interrupted' => '已中断',
  'blocked' => '被策略阻止',
  'limited' => '达到输出上限',
  'forked' => '分支边界已结束',
  'unverified' => '旧记录未结束 · 需读取确认',
  'unconfirmed' => '执行结果未确认',
  'stopping' => '正在停止',
  _ => '状态未知',
};

String taskFailure(Json row) {
  final reason = row['reason'];
  if (reason is Json && reason['error'] is Json) {
    final failure = reason['error'] as Json;
    return '${failure['code'] ?? ''} ${failure['message'] ?? ''}'.trim();
  }
  return '${row['error'] ?? ''}';
}

/// Lists the original Agent inbox and turn records without scheduling or replaying work.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key, required this.runtime, this.sessionId});
  final RuntimeController runtime;
  final String? sessionId;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> with WidgetsBindingObserver {
  final stopping = <String>{};
  final errors = <String, String>{};
  bool refreshing = false;
  bool refreshAgain = false;
  String? refreshError;
  Object? observedRevision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(changed);
    unawaited(refresh());
  }

  void changed() {
    final key =
        '${widget.runtime.phase}:${widget.runtime.taskState['epoch']}:${widget.runtime.taskState['revision']}';
    if (key == observedRevision) return;
    observedRevision = key;
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (!widget.runtime.ready) return;
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshAgain = false;
    setState(() => refreshing = true);
    try {
      await Future.wait([
        widget.runtime.refreshTasks(),
        widget.runtime.refreshInteractions(),
      ]);
      if (mounted) setState(() => refreshError = null);
    } catch (failure) {
      if (mounted) setState(() => refreshError = '无法刷新任务状态：$failure');
    } finally {
      if (mounted) setState(() => refreshing = false);
      if (mounted && refreshAgain) unawaited(refresh());
    }
  }

  Future<void> stop(String id) async {
    if (stopping.contains(id) || !widget.runtime.ready) return;
    setState(() {
      stopping.add(id);
      errors.remove(id);
    });
    try {
      await widget.runtime.call('tasks.cancel', {'sessionId': id});
      await widget.runtime.refreshTasks();
    } catch (failure) {
      if (mounted) {
        setState(() {
          stopping.remove(id);
          errors[id] = '停止请求未确认，请刷新状态后再操作：$failure';
        });
      }
    }
  }

  String title(String id) {
    for (final row in widget.runtime.taskSessions) {
      if (row['sessionId'] == id) return '${row['title']}';
    }
    return id;
  }

  Future<void> history(Json row) async {
    if (row.containsKey('subagent')) {
      await openConversation(row);
      return;
    }
    final id = await Navigator.push<String>(
      context,
      PocketRoute<String>(
        builder: (_) => TaskHistoryPage(
          runtime: widget.runtime,
          sessionId: row['sessionId'] as String,
          title: '${row['title']}',
        ),
      ),
    );
    if (mounted && id != null) Navigator.pop(context, id);
  }

  Future<void> openConversation(Json row) async {
    if (!row.containsKey('subagent')) {
      Navigator.pop(context, row['sessionId']);
      return;
    }
    final address = row['subagent'];
    if (address is! Json) {
      setState(
        () => errors[row['sessionId'] as String] = '子 Agent 的父级地址不可用，请从父会话查看。',
      );
      return;
    }
    await Navigator.push<void>(
      context,
      PocketRoute<void>(
        builder: (_) => SubagentConversationPage(
          runtime: widget.runtime,
          address: SubagentAddress.fromJson(address),
          label: title(row['sessionId'] as String),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.runtime.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final runtime = widget.runtime;
      final active = ((runtime.taskState['active'] as List?) ?? [])
          .cast<Json>();
      final backgroundJobs =
          (runtime.taskState['summary'] as Json?)?['backgroundJobs'] as int?;
      stopping.removeWhere(
        (id) => !active.any(
          (row) =>
              row['sessionId'] == id &&
              ['running', 'waiting'].contains(row['status']),
        ),
      );
      return PocketScaffold(
        title: const Text('后台任务'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新任务状态',
          onPressed: refreshing || !runtime.ready ? null : refresh,
        ),
        body: PocketList(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            if (widget.sessionId != null)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.terminal_rounded,
                    title: '当前对话的后台作业',
                    subtitle: '查看命令状态与实时输出',
                    onTap: () => Navigator.push(
                      context,
                      PocketRoute<void>(
                        builder: (_) => JobsPage(
                          runtime: runtime,
                          sessionId: widget.sessionId!,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            if (!runtime.ready)
              const PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.cloud_off_rounded,
                    title: '任务状态暂不可用',
                    subtitle: '以下保留上次读取的记录，不代表任务仍在执行。重新连接后才能确认。',
                  ),
                ],
              ),
            if (refreshError ?? runtime.tasksError case final String message)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(message),
              ),
            if (runtime.ready && runtime.taskState.isNotEmpty && active.isEmpty)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.check_circle_outline_rounded,
                    title: backgroundJobs == null
                        ? 'Agent 暂无运行任务'
                        : backgroundJobs > 0
                        ? '$backgroundJobs 个后台作业仍在执行'
                        : '当前没有运行中的任务',
                    subtitle: backgroundJobs == null
                        ? '后台作业状态尚未确认，请刷新后查看。'
                        : backgroundJobs > 0
                        ? 'Agent 当前空闲；可从对应会话查看作业状态与输出。'
                        : '历史结果保留在下方；进程恢复不会自动重放旧请求。',
                  ),
                ],
              ),
            for (final row in active)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.auto_awesome_outlined,
                    title: title(row['sessionId'] as String),
                    subtitle: !runtime.ready
                        ? '状态待确认'
                        : stopping.contains(row['sessionId'])
                        ? '正在停止'
                        : '${taskStatusLabel(row['status'] as String?)}'
                              '${(row['queued'] as int? ?? 0) > 0 ? ' · ${row['queued']} 条待处理' : ''}',
                    onTap: () => openConversation(row),
                  ),
                  if (taskFailure(row).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(taskFailure(row)),
                    ),
                  if (errors[row['sessionId']] case final String message)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(message),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PocketButton.tonal(
                          onPressed: () => openConversation(row),
                          child: Text(
                            row.containsKey('subagent') ? '查看子 Agent' : '打开对话',
                          ),
                        ),
                        if ((row['blockingRequests'] as int? ?? 0) > 0)
                          PocketButton.tonal(
                            onPressed: () => Navigator.push(
                              context,
                              PocketRoute<void>(
                                builder: (_) => ApprovalsPage(runtime: runtime),
                              ),
                            ),
                            child: const Text('处理请求'),
                          ),
                        if (!row.containsKey('subagent') &&
                            ['running', 'waiting'].contains(row['status']))
                          PocketButton.tonal(
                            onPressed:
                                stopping.contains(row['sessionId']) ||
                                    !runtime.ready
                                ? null
                                : () => stop(row['sessionId'] as String),
                            child: const Text('停止任务'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            const Padding(padding: EdgeInsets.all(12), child: Text('会话任务历史')),
            for (final row in runtime.taskSessions)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.history_rounded,
                    title: '${row['title']}',
                    subtitle: row['historyAvailable'] != true
                        ? '尚无缓存记录 · 点按读取'
                        : '${(row['history'] as List).isEmpty ? '尚无执行回合' : taskStatusLabel(((row['history'] as List).first as Json)['status'] as String?)}'
                              '${row['observation'] == 'cached' ? ' · 缓存记录' : ''}',
                    onTap: runtime.ready ? () => history(row) : null,
                  ),
                  if (errors[row['sessionId']] != null &&
                      !active.any(
                        (item) => item['sessionId'] == row['sessionId'],
                      ))
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        errors[row['sessionId']]!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            if (runtime.tasksNextOffset != null)
              PocketButton.tonal(
                onPressed: refreshing || !runtime.ready
                    ? null
                    : () async {
                        try {
                          await runtime.loadMoreTasks();
                        } catch (failure) {
                          if (mounted) {
                            setState(() => refreshError = '无法读取更多任务：$failure');
                          }
                        }
                      },
                child: const Text('更多会话'),
              ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('停止当前回合会保留排队输入。任务历史记录的是整个回合的结果，不能据此断言某条排队消息已完成。'),
            ),
          ],
        ),
      );
    },
  );
}

class TaskHistoryPage extends StatefulWidget {
  const TaskHistoryPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.title,
  });
  final RuntimeController runtime;
  final String sessionId, title;
  @override
  State<TaskHistoryPage> createState() => _TaskHistoryPageState();
}

class _TaskHistoryPageState extends State<TaskHistoryPage> {
  Json? snapshot;
  String? error, confirming, busyItem;
  bool loading = false;
  bool readAgain = false;
  Object? observedRevision;
  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(changed);
    unawaited(read());
  }

  void changed() {
    final key =
        '${widget.runtime.phase}:${widget.runtime.taskState['epoch']}:${widget.runtime.taskState['revision']}';
    if (key == observedRevision) return;
    observedRevision = key;
    unawaited(read());
  }

  @override
  void dispose() {
    widget.runtime.removeListener(changed);
    super.dispose();
  }

  Future<void> read({bool more = false}) async {
    if (!widget.runtime.ready) return;
    if (loading) {
      if (!more) readAgain = true;
      return;
    }
    readAgain = false;
    setState(() => loading = true);
    try {
      final next = await widget.runtime.call('tasks.session', {
        'sessionId': widget.sessionId,
        if (more) 'beforeSeq': snapshot!['nextBeforeSeq'],
      }) as Json;
      if (!mounted || !widget.runtime.ready) return;
      final epoch = widget.runtime.taskState['epoch'];
      if (epoch != null && next['epoch'] != epoch) return;
      setState(() {
        if (more) {
          next['history'] = [
            ...snapshot!['history'] as List,
            ...next['history'] as List,
          ];
        }
        snapshot = next;
        error = null;
      });
    } catch (failure) {
      if (mounted) setState(() => error = '无法读取任务历史：$failure');
    } finally {
      if (mounted) setState(() => loading = false);
      if (mounted && readAgain) unawaited(read());
    }
  }

  Future<void> remove(Json row) async {
    setState(() {
      busyItem = row['itemId'] as String;
      error = null;
    });
    try {
      await widget.runtime.call('tasks.removeQueued', {
        'sessionId': widget.sessionId,
        'itemId': row['itemId'],
      });
      if (mounted) setState(() => confirming = null);
      await read();
      await widget.runtime.refreshTasks();
    } catch (failure) {
      if (mounted) setState(() => error = '移除请求未确认，先刷新队列核对：$failure');
    } finally {
      if (mounted) setState(() => busyItem = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) => PocketScaffold(
      title: const Text('任务记录'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新任务记录',
        onPressed: loading || !widget.runtime.ready ? null : read,
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.chat_bubble_outline_rounded,
                title: widget.title,
                subtitle: '打开对话查看原始输入、工具调用与完整结果',
                onTap: () => Navigator.pop(context, widget.sessionId),
              ),
            ],
          ),
          if (!widget.runtime.ready)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('服务未连接，以下状态尚未重新确认。'),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(error!),
            ),
          if (snapshot?['observation'] == 'cached')
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('显示缓存提示；当前格式需迁移，尚不能确认最终执行结果。'),
            ),
          for (final row
              in ((snapshot?['pending'] as List?) ?? []).cast<Json>())
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.schedule_rounded,
                  title: taskStatusLabel(row['status'] as String?),
                  subtitle:
                      '${row['prompt'] == '' ? '附件或系统输入' : row['prompt']}',
                ),
                if (row['cancellable'] == true)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (confirming == row['itemId']) ...[
                          const Text('移除这条尚未执行的输入？'),
                          PocketButton.tonal(
                            onPressed: busyItem != null
                                ? null
                                : () => setState(() => confirming = null),
                            child: const Text('保留'),
                          ),
                          PocketButton.tonal(
                            onPressed: busyItem != null || !widget.runtime.ready
                                ? null
                                : () => remove(row),
                            child: const Text('确认移除'),
                          ),
                        ] else
                          PocketButton.tonal(
                            onPressed: busyItem != null || !widget.runtime.ready
                                ? null
                                : () => setState(
                                    () => confirming = row['itemId'] as String,
                                  ),
                            child: const Text('移除待处理输入'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          for (final row
              in ((snapshot?['history'] as List?) ?? []).cast<Json>())
            PocketSection(
              children: [
                PocketRow(
                  icon: row['status'] == 'failed'
                      ? Icons.error_outline_rounded
                      : Icons.history_rounded,
                  title: row['kind'] == 'discarded'
                      ? '已取消 ${row['count']} 条待处理输入'
                      : row['kind'] == 'job'
                      ? '${row['label']} · ${taskStatusLabel(row['status'] as String?)}'
                      : '第 ${row['turn']} 回合 · ${taskStatusLabel(row['status'] as String?)}',
                  subtitle: DateTime.fromMillisecondsSinceEpoch(
                    (row['endTime'] ?? row['finishedAt'] ?? row['time']) as int,
                  ).toLocal().toString(),
                ),
                if (taskFailure(row).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(taskFailure(row)),
                  ),
              ],
            ),
          if (snapshot?['historyAvailable'] == false)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('任务投影暂不可用，不能把空列表当成没有历史。'),
            ),
          if (snapshot?['nextBeforeSeq'] != null)
            PocketButton.tonal(
              onPressed: loading || !widget.runtime.ready
                  ? null
                  : () => read(more: true),
              child: const Text('更早的回合'),
            ),
        ],
      ),
    ),
  );
}
