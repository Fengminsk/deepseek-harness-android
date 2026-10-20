import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'approvals.dart';
import 'runtime.dart';
import 'ui.dart';

/// A view of the shared Agent state; leaving this page does not stop a task.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key, required this.runtime});
  final RuntimeController runtime;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> with WidgetsBindingObserver {
  final stopping = <String>{};
  final errors = <String, String>{};
  bool refreshing = false;
  String? refreshError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (refreshing || !widget.runtime.ready) return;
    setState(() => refreshing = true);
    try {
      await Future.wait([
        widget.runtime.refreshLive(),
        widget.runtime.refreshSessions(),
        widget.runtime.refreshInteractions(),
      ]);
      if (mounted) setState(() => refreshError = null);
    } catch (failure) {
      if (mounted) setState(() => refreshError = '无法刷新任务状态：$failure');
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> stop(String id) async {
    if (stopping.contains(id) || !widget.runtime.ready) return;
    setState(() {
      stopping.add(id);
      errors.remove(id);
    });
    try {
      await widget.runtime.call('session.cancel', {'sessionId': id});
    } catch (failure) {
      if (mounted) {
        setState(() {
          stopping.remove(id);
          errors[id] = '停止请求未成功：$failure';
        });
      }
    }
  }

  String title(String id) {
    for (final session in widget.runtime.sessions) {
      final header = session['header'] as Json;
      if (header['id'] == id) {
        return '${session['title'] ?? header['title'] ?? id}';
      }
    }
    return id;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final runtime = widget.runtime;
      final active = runtime.statuses.entries
          .where((entry) => entry.value == 'running')
          .map((entry) => entry.key)
          .toList();
      stopping.removeWhere((id) => !active.contains(id));
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
            if (!runtime.ready)
              const PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.cloud_off_rounded,
                    title: '任务状态暂不可用',
                    subtitle: '以下是上次读取的状态。服务重新连接后才能确认任务是否仍在运行。',
                  ),
                ],
              ),
            if (refreshError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(refreshError!),
              ),
            if (active.isEmpty && runtime.ready)
              const PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.check_circle_outline_rounded,
                    title: '当前没有运行中的任务',
                    subtitle: '发起对话后，运行中的任务会显示在这里。',
                  ),
                ],
              ),
            for (final id in active)
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.auto_awesome_outlined,
                    title: title(id),
                    subtitle: stopping.contains(id)
                        ? '正在停止'
                        : runtime.interactions.any(
                            (item) => item['sessionId'] == id,
                          )
                        ? '等待授权或回答'
                        : '运行中',
                    onTap: () => Navigator.pop(context, id),
                  ),
                  if (errors[id] != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 8,
                      ),
                      child: SelectableText(errors[id]!),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PocketButton.tonal(
                          onPressed: () => Navigator.pop(context, id),
                          child: const Text('打开对话'),
                        ),
                        if (runtime.interactions.any(
                          (item) => item['sessionId'] == id,
                        ))
                          PocketButton.tonal(
                            onPressed: () => Navigator.push(
                              context,
                              PocketRoute<void>(
                                builder: (_) => ApprovalsPage(runtime: runtime),
                              ),
                            ),
                            child: const Text('处理请求'),
                          ),
                        PocketButton.tonal(
                          onPressed: stopping.contains(id) || !runtime.ready
                              ? null
                              : () => stop(id),
                          child: const Text('停止任务'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('返回对话或切换页面不会停止任务。系统停止应用或服务时，任务可能中断。'),
            ),
          ],
        ),
      );
    },
  );
}
