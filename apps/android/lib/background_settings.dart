import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'overlay_keepalive_settings.dart';
import 'tasks.dart';
import 'ui.dart';

String backgroundStateLabel(Json state) => switch (state['taskState']) {
  'running' => '任务执行中',
  'packages' => '插件管理操作中',
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
  String? error, settingsError;
  bool loading = false, saving = false, active = true;
  bool? requestedSetting;
  int readAttempt = 0, writeAttempt = 0;
  int? snapshotConnection;
  late (int, String, bool) observedRuntime;
  Timer? timer;

  bool get confirmed =>
      widget.runtime.ready &&
      snapshotConnection == widget.runtime.connectionGeneration &&
      error == null;

  @override
  void initState() {
    super.initState();
    observedRuntime = (
      widget.runtime.connectionGeneration,
      widget.runtime.phase,
      widget.runtime.ready,
    );
    widget.runtime.addListener(runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (active) unawaited(refresh());
    });
  }

  void withdrawObservations() {
    background = background == null
        ? null
        : {...background!, 'fresh': false, 'taskState': 'unconfirmed'};
    snapshotConnection = null;
    system = null;
  }

  void runtimeChanged() {
    final next = (
      widget.runtime.connectionGeneration,
      widget.runtime.phase,
      widget.runtime.ready,
    );
    if (next == observedRuntime) return;
    observedRuntime = next;
    readAttempt++;
    writeAttempt++;
    setState(() {
      withdrawObservations();
      loading = false;
      saving = false;
      error = requestedSetting == null
          ? '连接已变化，后台状态待核对。'
          : '连接已变化，设置保存结果尚未确认；恢复后只读取设置进行核对。';
    });
    if (active) unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading || saving) return;
    final attempt = ++readAttempt;
    final connection = widget.runtime.connectionGeneration;
    final phase = widget.runtime.phase;
    bool ownsRead() =>
        mounted &&
        attempt == readAttempt &&
        connection == widget.runtime.connectionGeneration &&
        phase == widget.runtime.phase;
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
      if (ownsRead()) {
        setState(() {
          // Native policy remains readable during startup and recovery, but an
          // unavailable Agent cannot inherit an old working-state claim.
          background = widget.runtime.ready
              ? next
              : {...next, 'fresh': false, 'taskState': widget.runtime.phase};
          snapshotConnection = connection;
          system = policy;
          error = null;
        });
      }
    } catch (failure) {
      if (ownsRead()) {
        setState(() {
          // Old counts cannot become proof that work is still executing.
          withdrawObservations();
          error = '后台状态未确认，请刷新后再操作：$failure';
        });
      }
    } finally {
      if (ownsRead()) setState(() => loading = false);
    }
  }

  Future<void> configure(bool enabled) async {
    if (saving || loading || !confirmed) return;
    final attempt = ++writeAttempt;
    final connection = widget.runtime.connectionGeneration;
    bool ownsWrite() =>
        mounted &&
        attempt == writeAttempt &&
        connection == widget.runtime.connectionGeneration &&
        widget.runtime.ready;
    setState(() {
      saving = true;
      requestedSetting = enabled;
    });
    try {
      final result = await widget.runtime.call('runtime.background.configure', {
        'keepAwakeWhileWorking': enabled,
      }) as Json;
      if (ownsWrite()) {
        setState(() {
          background = result;
          snapshotConnection = connection;
          requestedSetting = null;
          error = null;
        });
      }
    } catch (failure) {
      if (ownsWrite()) setState(() => error = '设置保存未确认，请刷新后核对：$failure');
    } finally {
      if (ownsWrite()) setState(() => saving = false);
    }
  }

  Future<void> openSystemSettings() async {
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'background.openSystemSettings',
      );
      if (mounted) setState(() => settingsError = null);
    } catch (failure) {
      if (mounted) {
        setState(() => settingsError = '无法打开系统应用设置，请按上面的路径手动查找：$failure');
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.runtime.removeListener(runtimeChanged);
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
              if (state?['fresh'] == true)
                PocketRow(
                  icon: Icons.extension_outlined,
                  title: '插件管理操作',
                  subtitle: state?['packageOperations'] is int
                      ? '${state!['packageOperations']} 项进行中'
                      : '状态尚未确认，请刷新后查看',
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
            title: 'CPU 唤醒保护',
            children: [
              if (state != null)
                PocketSwitchRow(
                  title: const Text('执行任务时保持 CPU 运行'),
                  subtitle: const Text(
                    '在任务、后台作业或插件管理操作进行时使用，空闲和仅等待答复时释放。不点亮屏幕，使用期间可能增加耗电。',
                  ),
                  value: state['keepAwakeWhileWorking'] == true,
                  onChanged: loading || saving || !confirmed ? null : configure,
                ),
              if (requestedSetting != null && !saving)
                PocketRow(
                  icon: Icons.sync_problem_rounded,
                  title: '上次设置待核对',
                  subtitle:
                      '希望${requestedSetting! ? '开启' : '关闭'} CPU 唤醒保护。'
                      '${confirmed ? '当前读取为${state?['keepAwakeWhileWorking'] == true ? '开启' : '关闭'}；这是当前设置，不代表已收到上次操作的回执。' : '保存结果尚未确认，连接恢复后只读取设置。'}'
                      '不会自动重发；如需更改，请重新选择。',
                ),
              PocketRow(
                icon: Icons.battery_saver_rounded,
                title:
                    state?['fresh'] != true || state?['wakeLockHeld'] is! bool
                    ? 'CPU 唤醒锁状态待确认'
                    : state?['wakeLockHeld'] == true
                    ? '正在持有 CPU 唤醒锁'
                    : '当前未持有 CPU 唤醒锁',
                subtitle: 'CPU 唤醒锁不代表获得后台运行许可，不能代替系统或厂商的后台设置。',
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
            title: '保活策略',
            children: [
              PocketRow(
                icon: Icons.layers_outlined,
                title: '透明悬浮窗',
                subtitle: '由你选择是否使用辅助保活',
                onTap: () => Navigator.push(
                  context,
                  PocketRoute<void>(
                    builder: (_) =>
                        OverlayKeepaliveSettingsPage(runtime: widget.runtime),
                  ),
                ),
              ),
            ],
          ),
          PocketSection(
            title: 'Android 标准电池状态',
            children: [
              PocketRow(
                icon: Icons.battery_charging_full_rounded,
                title: '标准电池优化',
                subtitle: switch (policy?['batteryOptimizationsIgnored']) {
                  true => '已获得 Android 标准电池优化豁免',
                  false => '仍受 Android 标准电池优化管理',
                  _ => '未确认',
                },
              ),
              PocketRow(
                icon: Icons.settings_power_rounded,
                title: '标准后台限制',
                subtitle: switch (policy?['backgroundRestricted']) {
                  true => 'Android 已报告后台限制',
                  false => 'Android 标准接口未报告后台限制',
                  _ => '未确认',
                },
              ),
              PocketRow(
                icon: Icons.power_settings_new_rounded,
                title: '省电模式',
                subtitle: switch (policy?['powerSaveMode']) {
                  true => '已开启',
                  false => '未开启',
                  _ => '未确认',
                },
              ),
            ],
          ),
          PocketSection(
            title: '手机厂商后台策略',
            children: [
              const PocketRow(
                key: ValueKey('oem-background-policy'),
                icon: Icons.info_outline_rounded,
                title: '厂商后台许可需要手动确认',
                subtitle: 'App 无法读取厂商的耗电管理策略；标准电池优化已豁免或未报告后台限制，不代表厂商已允许后台运行。',
              ),
              const PocketRow(
                icon: Icons.route_rounded,
                title: '手动设置路径',
                subtitle: '打开系统应用设置 → 耗电管理或电池 → 后台活动。OPPO 示例：在 Pocket Harness 的耗电管理中，按需选择“完全允许后台行为”；选项名称随手机和系统版本变化。',
              ),
              const PocketRow(
                icon: Icons.battery_alert_rounded,
                title: '耗电与运行限制',
                subtitle: '允许更多后台活动可能增加耗电，请按需选择。后台运行仍受具体手机和系统策略影响，进程仍可能被暂停或停止，不能保证持续运行。',
              ),
              if (settingsError != null)
                PocketRow(
                  icon: Icons.error_outline_rounded,
                  title: settingsError!,
                ),
              PocketRow(
                icon: Icons.open_in_new_rounded,
                title: '打开系统应用设置',
                subtitle:
                    '仅打开 Pocket Harness 的应用详情，不自动更改策略；返回后刷新 Android 标准状态。',
                onTap: openSystemSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
