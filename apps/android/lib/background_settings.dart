import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'tasks.dart';
import 'ui.dart';

String backgroundStateLabel(Json state) => switch (state['taskState']) {
  'running' => '任务执行中',
  'waiting' => '等待授权或答复',
  'queued' => '有输入等待处理',
  'idle' => '已就绪 · 暂无任务',
  'attention' => '最近有任务失败',
  'partial' => '后台作业状态尚未确认',
  'starting' => '服务启动中',
  'restarting' => '服务重启中',
  'failed' => '服务异常 · 任务可能已中断',
  'stopped' => '服务已停止',
  _ => '任务状态尚未确认',
};

/// Displays service-owned state; merely visiting this page changes no system policy.
class BackgroundSettingsPage extends StatefulWidget {
  const BackgroundSettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<BackgroundSettingsPage> createState() => _BackgroundSettingsPageState();
}

class _BackgroundSettingsPageState extends State<BackgroundSettingsPage>
    with WidgetsBindingObserver {
  Json? background, system;
  String? error;
  bool loading = false, saving = false, active = true;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (active) unawaited(refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading || saving) return;
    setState(() => loading = true);
    try {
      final values = await Future.wait<dynamic>([
        widget.runtime.call('runtime.status'),
        RuntimeController.channel.invokeMethod<String>(
          'background.systemStatus',
        ),
      ]);
      final next = (values[0] as Json)['background'] as Json;
      final policy = jsonDecode(values[1] as String) as Json;
      if (mounted) {
        setState(() {
          background = next;
          system = policy;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          // Old counts cannot become proof that work is still executing.
          background = background == null
              ? null
              : {...background!, 'fresh': false, 'taskState': 'unconfirmed'};
          system = null;
          error = '后台状态未确认，请刷新后再操作：$failure';
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> configure(bool enabled) async {
    if (saving || loading) return;
    setState(() => saving = true);
    try {
      final result = await widget.runtime.call('runtime.background.configure', {
        'keepAwakeWhileWorking': enabled,
      }) as Json;
      if (mounted) {
        setState(() {
          background = result;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = '设置保存未确认，请刷新后核对：$failure');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> openSystemSettings() async {
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'background.openSystemSettings',
      );
    } catch (failure) {
      if (mounted) setState(() => error = '无法打开系统应用设置：$failure');
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = background;
    final policy = system;
    return PocketScaffold(
      title: const Text('后台执行'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新状态',
        onPressed: loading || saving ? null : refresh,
      ),
      body: PocketList(
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          PocketSection(
            title: '当前状态',
            children: [
              PocketRow(
                icon: Icons.play_circle_outline_rounded,
                title: state == null
                    ? loading
                          ? '正在读取后台状态'
                          : '任务状态尚未确认'
                    : backgroundStateLabel(state),
                subtitle: state?['fresh'] == true
                    ? '${state!['running']} 个任务执行 · ${state['queued']} 条输入排队 · '
                          '${state['waiting']} 项等待处理'
                    : '状态以手机上的实际运行时为准',
              ),
              if (state?['fresh'] == true && state?['backgroundJobs'] is int)
                PocketRow(
                  icon: Icons.terminal_rounded,
                  title: '后台作业',
                  subtitle: '${state!['backgroundJobs']} 个活动作业',
                ),
              PocketRow(
                icon: Icons.task_alt_rounded,
                title: '查看任务与历史',
                onTap: () => Navigator.push(
                  context,
                  PocketRoute<void>(
                    builder: (_) => TasksPage(runtime: widget.runtime),
                  ),
                ),
              ),
            ],
          ),
          PocketSection(
            title: '锁屏执行',
            children: [
              if (state != null)
                PocketSwitchRow(
                  title: const Text('执行任务时保持 CPU 运行'),
                  subtitle: const Text('只在任务或后台作业运行时使用，空闲和等待答复时释放。不点亮屏幕。'),
                  value: state['keepAwakeWhileWorking'] == true,
                  onChanged: loading || saving || error != null
                      ? null
                      : configure,
                ),
              PocketRow(
                icon: Icons.battery_saver_rounded,
                title: state?['fresh'] != true
                    ? '执行保护状态待确认'
                    : state?['wakeLockHeld'] == true
                    ? '正在维持任务执行'
                    : '当前未持有执行保护',
                subtitle: '系统省电、后台限制或强行停止仍可能中断服务。',
              ),
              for (final name in ['powerError', 'notificationError'])
                if (state?[name] is String)
                  PocketRow(
                    icon: Icons.info_outline_rounded,
                    title: state![name] as String,
                  ),
            ],
          ),
          PocketSection(
            title: '系统电池管理',
            children: [
              PocketRow(
                icon: Icons.battery_charging_full_rounded,
                title: '电池优化',
                subtitle: policy == null
                    ? '未确认'
                    : policy['batteryOptimizationsIgnored'] == true
                    ? '系统已豁免电池优化'
                    : '仍受系统电池优化管理',
              ),
              PocketRow(
                icon: Icons.settings_power_rounded,
                title: '后台限制',
                subtitle: policy == null
                    ? '未确认'
                    : policy['backgroundRestricted'] == true
                    ? '系统已限制后台运行'
                    : '系统未报告后台限制',
              ),
              PocketRow(
                icon: Icons.power_settings_new_rounded,
                title: '省电模式',
                subtitle: policy == null
                    ? '未确认'
                    : policy['powerSaveMode'] == true
                    ? '已开启'
                    : '未开启',
              ),
              PocketRow(
                icon: Icons.open_in_new_rounded,
                title: '打开系统应用设置',
                subtitle: '按需调整电池与后台运行权限；不同手机的选项名称可能不同',
                onTap: openSystemSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
