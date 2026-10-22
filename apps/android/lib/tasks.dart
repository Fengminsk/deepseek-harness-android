import 'dart:async';
import 'dart:convert';

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
  final stopAttempts = <String, int>{};
  bool refreshing = false;
  bool loadingMore = false;
  bool refreshAgain = false;
  String? refreshError;
  Json? lastInterruption;
  String? interruptionError;
  int interruptionRead = 0;
  Object? observedRevision;
  late int connection;
  int? snapshotConnection;
  int readAttempt = 0, stopAttempt = 0, moreAttempt = 0;
  bool get confirmed =>
      widget.runtime.ready &&
      snapshotConnection == widget.runtime.connectionGeneration &&
      refreshError == null;
  bool get current => confirmed && !refreshing && !loadingMore;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(changed);
    unawaited(readInterruption());
    unawaited(refresh());
  }

  void changed() {
    if (connection != widget.runtime.connectionGeneration) {
      connection = widget.runtime.connectionGeneration;
      snapshotConnection = null;
      readAttempt++;
      moreAttempt++;
      refreshing = false;
      loadingMore = false;
      refreshAgain = false;
      refreshError = null;
      for (final id in stopping) {
        errors[id] = '连接已变化，停止结果尚未确认。请核对当前任务。';
      }
      stopping.clear();
      stopAttempts.clear();
      unawaited(readInterruption());
    }
    final key =
        '$connection:${widget.runtime.phase}:${widget.runtime.taskState['epoch']}:${widget.runtime.taskState['revision']}';
    if (key == observedRevision) return;
    observedRevision = key;
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(readInterruption());
      unawaited(refresh());
    }
  }

  Future<void> readInterruption() async {
    final attempt = ++interruptionRead;
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'background.lastInterruption',
      );
      final decoded = raw == null ? null : jsonDecode(raw);
      final record = decoded is Json ? decoded : null;
      final kind = record?['kind'];
      final time = record?['timeMillis'];
      final valid =
          (kind == 'runtime-lost' || kind == 'service-timeout') &&
          time is int &&
          time > 0;
      if (!mounted || attempt != interruptionRead) return;
      setState(() {
        lastInterruption = valid ? record : null;
        interruptionError = decoded == null || valid
            ? null
            : '本地中断摘要无法确认，请查看原会话记录。';
      });
    } catch (_) {
      if (!mounted || attempt != interruptionRead) return;
      setState(() => interruptionError = '无法读取上次后台中断摘要，请查看原会话记录。');
    }
  }

  Future<void> refresh() async {
    if (!widget.runtime.ready) return;
    if (refreshing || loadingMore) {
      refreshAgain = true;
      return;
    }
    refreshAgain = false;
    final attempt = ++readAttempt;
    final generation = widget.runtime.connectionGeneration;
    bool ownsRead() =>
        mounted &&
        widget.runtime.ready &&
        attempt == readAttempt &&
        generation == widget.runtime.connectionGeneration;
    setState(() => refreshing = true);
    try {
      await Future.wait([
        widget.runtime.refreshTasks(),
        widget.runtime.refreshInteractions(),
      ]);
      if (ownsRead()) {
        setState(() {
          snapshotConnection = generation;
          refreshError = null;
        });
      }
    } catch (failure) {
      if (ownsRead()) setState(() => refreshError = '无法刷新任务状态：$failure');
    } finally {
      if (ownsRead()) {
        setState(() => refreshing = false);
        if (refreshAgain) unawaited(refresh());
      }
    }
  }

  Future<void> stop(String id) async {
    if (stopping.contains(id) || !current) return;
    final generation = widget.runtime.connectionGeneration;
    final attempt = ++stopAttempt;
    stopAttempts[id] = attempt;
    bool ownsStop() =>
        mounted &&
        generation == widget.runtime.connectionGeneration &&
        stopAttempts[id] == attempt;
    setState(() {
      stopping.add(id);
      errors.remove(id);
    });
    try {
      await widget.runtime.call('tasks.cancel', {'sessionId': id});
      if (!ownsStop()) return;
      await widget.runtime.refreshTasks();
    } catch (failure) {
      if (ownsStop()) {
        setState(() {
          stopping.remove(id);
          errors[id] = '停止请求未确认，请刷新状态后再操作：$failure';
        });
      }
    }
  }

  Future<void> more() async {
    if (!current) return;
    final generation = widget.runtime.connectionGeneration;
    final attempt = ++moreAttempt;
    bool ownsRead() =>
        mounted &&
        generation == widget.runtime.connectionGeneration &&
        attempt == moreAttempt;
    setState(() => loadingMore = true);
    try {
      await widget.runtime.loadMoreTasks();
    } catch (failure) {
      if (ownsRead()) setState(() => refreshError = '无法读取更多任务：$failure');
    } finally {
      if (ownsRead()) {
        setState(() => loadingMore = false);
        if (refreshAgain) unawaited(refresh());
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
      final packageOperations =
          (runtime.taskState['summary'] as Json?)?['packageOperations'] as int?;
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
            if (lastInterruption case final Json record)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.error_outline_rounded,
                    title: record['kind'] == 'service-timeout'
                        ? '上次后台运行时段已结束'
                        : '上次本地运行时异常退出',
                    subtitle:
                        '${MaterialLocalizations.of(context).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(record['timeMillis'] as int))} ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(record['timeMillis'] as int)).format(context)} · 任务结果需在原会话核对；不会自动重试。',
                  ),
                ],
              ),
            if (interruptionError case final String message)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.warning_amber_rounded,
                    title: '后台中断记录暂不可用',
                    subtitle: message,
                  ),
                ],
              ),
            if (!confirmed)
              const PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.cloud_off_rounded,
                    title: '任务状态暂不可用',
                    subtitle: '以下保留上次读取的记录，不代表任务仍在执行。读取最新状态后才能确认。',
                  ),
                ],
              ),
            if (refreshError ?? runtime.tasksError case final String message)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(message),
              ),
            if (confirmed && runtime.taskState.isNotEmpty && active.isEmpty)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.check_circle_outline_rounded,
                    title: backgroundJobs == null
                        ? 'Agent 暂无运行任务'
                        : backgroundJobs > 0
                        ? '$backgroundJobs 个后台作业仍在执行'
                        : packageOperations == null || packageOperations > 0
                        ? 'Agent 暂无运行任务'
                        : '当前没有运行中的任务',
                    subtitle: backgroundJobs == null
                        ? '后台作业状态尚未确认，请刷新后查看。'
                        : backgroundJobs > 0
                        ? 'Agent 当前空闲；可从对应会话查看作业状态与输出。'
                        : packageOperations == null
                        ? '插件管理操作状态尚未确认，请刷新后查看。'
                        : packageOperations > 0
                        ? '插件操作仍在进行，完成后再进入维护模式。'
                        : '历史结果保留在下方；进程恢复不会自动重放旧请求。',
                  ),
                ],
              ),
            if (confirmed && (packageOperations ?? 0) > 0)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.extension_outlined,
                    title: '插件管理操作',
                    subtitle: '$packageOperations 项进行中',
                  ),
                ],
              ),
            for (final row in active)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.auto_awesome_outlined,
                    title: title(row['sessionId'] as String),
                    subtitle: !confirmed
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
                                stopping.contains(row['sessionId']) || !current
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
                    subtitle: !confirmed
                        ? '状态待确认 · 保留上次读取的记录'
                        : row['historyAvailable'] != true
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
                onPressed: current ? more : null,
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
  late int connection;
  int? snapshotConnection;
  int readAttempt = 0, mutationAttempt = 0;
  bool get confirmed =>
      widget.runtime.ready &&
      snapshotConnection == widget.runtime.connectionGeneration &&
      error == null;
  bool get current => confirmed && !loading;
  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    widget.runtime.addListener(changed);
    unawaited(read());
  }

  void changed() {
    if (connection != widget.runtime.connectionGeneration) {
      connection = widget.runtime.connectionGeneration;
      readAttempt++;
      mutationAttempt++;
      snapshotConnection = null;
      loading = false;
      readAgain = false;
      error = busyItem == null ? null : '连接已变化，移除结果尚未确认。请核对当前队列。';
      busyItem = null;
      confirming = null;
    }
    final key =
        '$connection:${widget.runtime.phase}:${widget.runtime.taskState['epoch']}:${widget.runtime.taskState['revision']}';
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
    if (!widget.runtime.ready || (more && !current)) return;
    if (loading) {
      if (!more) readAgain = true;
      return;
    }
    readAgain = false;
    final attempt = ++readAttempt;
    final generation = widget.runtime.connectionGeneration;
    bool ownsRead() =>
        mounted &&
        widget.runtime.ready &&
        attempt == readAttempt &&
        generation == widget.runtime.connectionGeneration;
    setState(() => loading = true);
    try {
      final next = await widget.runtime.call('tasks.session', {
        'sessionId': widget.sessionId,
        if (more) 'beforeSeq': snapshot!['nextBeforeSeq'],
      }) as Json;
      if (!ownsRead()) return;
      final epoch = widget.runtime.taskState['epoch'];
      if (epoch != null && next['epoch'] != epoch) {
        setState(() {
          snapshotConnection = null;
          error = '任务记录已变化，请刷新后核对队列。';
        });
        return;
      }
      setState(() {
        if (more) {
          next['history'] = [
            ...snapshot!['history'] as List,
            ...next['history'] as List,
          ];
        }
        snapshot = next;
        snapshotConnection = generation;
        error = null;
      });
    } catch (failure) {
      if (ownsRead()) setState(() => error = '无法读取任务历史：$failure');
    } finally {
      if (ownsRead()) {
        setState(() => loading = false);
        if (readAgain) unawaited(read());
      }
    }
  }

  Future<void> remove(Json row) async {
    if (!current || busyItem != null || confirming != row['itemId']) return;
    final attempt = ++mutationAttempt;
    final generation = widget.runtime.connectionGeneration;
    bool ownsMutation() =>
        mounted &&
        attempt == mutationAttempt &&
        generation == widget.runtime.connectionGeneration;
    setState(() {
      busyItem = row['itemId'] as String;
      error = null;
    });
    try {
      await widget.runtime.call('tasks.removeQueued', {
        'sessionId': widget.sessionId,
        'itemId': row['itemId'],
      });
      if (!ownsMutation()) return;
      setState(() => confirming = null);
      await read();
      if (!ownsMutation()) return;
      await widget.runtime.refreshTasks();
    } catch (failure) {
      if (ownsMutation()) {
        setState(() => error = '移除请求未确认，先刷新队列核对：$failure');
      }
    } finally {
      if (ownsMutation()) setState(() => busyItem = null);
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
          if (widget.runtime.ready && !confirmed && snapshot != null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('任务记录待核实。以下是上次读取的状态，暂不能移除输入。'),
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
                            onPressed: busyItem != null || !current
                                ? null
                                : () => remove(row),
                            child: const Text('确认移除'),
                          ),
                        ] else
                          PocketButton.tonal(
                            onPressed: busyItem != null || !current
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
              onPressed: !current ? null : () => read(more: true),
              child: const Text('更早的回合'),
            ),
        ],
      ),
    ),
  );
}
