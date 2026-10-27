import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

class _ScheduleWakeStatus {
  _ScheduleWakeStatus(Json value)
    : enabled = value['enabled'] as bool,
      allowed = value['exactAlarmsAllowed'] as bool,
      projection = value['projectionState'] as String,
      activeCount = value['activeCount'] as int?,
      nextDueAtMs = value['nextDueAtMs'] as int?,
      alarm = value['alarmState'] as String,
      armedAtMs = value['armedAtMs'] as int? {
    if (!{'unknown', 'ready', 'unavailable'}.contains(projection) ||
        !{
          'disabled',
          'permission-required',
          'waiting',
          'scheduled',
          'waking',
          'error',
        }.contains(alarm) ||
        (activeCount != null && activeCount! < 0) ||
        [nextDueAtMs, armedAtMs].any(
          (time) => time != null && (time < 0 || time > 8640000000000000),
        )) {
      throw const FormatException('Invalid schedule wake status');
    }
  }

  final bool enabled, allowed;
  final String projection, alarm;
  final int? activeCount, nextDueAtMs, armedAtMs;

  String get label {
    if (alarm == 'error') return '唤醒设置暂不可用';
    if (!allowed) return '需要精确闹钟权限';
    if (!enabled) return '已关闭';
    if (alarm == 'waking') return '正在唤醒 Agent';
    if (projection != 'ready') return '定时任务状态待确认';
    if (alarm == 'waiting' && activeCount == 0) return '暂无待执行任务';
    if (alarm == 'scheduled' &&
        nextDueAtMs != null &&
        armedAtMs != null &&
        activeCount != null &&
        activeCount! > 0) {
      final due = DateTime.fromMillisecondsSinceEpoch(nextDueAtMs!);
      final hour = due.hour.toString().padLeft(2, '0');
      final minute = due.minute.toString().padLeft(2, '0');
      return '下次唤醒：${due.year}年${due.month}月${due.day}日 $hour:$minute';
    }
    return '唤醒时间待确认';
  }
}

/// Observes native scheduling separately from the user's enable preference.
/// Permission navigation never enables wake-up or replays a failed write.
class ScheduleWakeSettingsSection extends StatefulWidget {
  const ScheduleWakeSettingsSection({required this.runtime, super.key});
  final RuntimeController runtime;

  @override
  State<ScheduleWakeSettingsSection> createState() =>
      _ScheduleWakeSettingsSectionState();
}

class _ScheduleWakeSettingsSectionState
    extends State<ScheduleWakeSettingsSection>
    with WidgetsBindingObserver {
  _ScheduleWakeStatus? status;
  String? failure;
  bool active = true,
      reading = false,
      saving = false,
      openingPermission = false;
  int epoch = 0, sourceEpoch = 0;
  int? snapshotConnection;
  late (int, String) observedRuntime;
  Timer? timer;

  bool get confirmed =>
      snapshotConnection == widget.runtime.connectionGeneration &&
      status != null;

  @override
  void initState() {
    super.initState();
    active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    observeRuntime();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (active) unawaited(refresh());
    });
  }

  void observeRuntime() {
    observedRuntime = (
      widget.runtime.connectionGeneration,
      widget.runtime.phase,
    );
    widget.runtime.addListener(runtimeChanged);
  }

  void invalidate() {
    epoch++;
    sourceEpoch++;
    snapshotConnection = null;
    reading = false;
  }

  @override
  void didUpdateWidget(covariant ScheduleWakeSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime) return;
    oldWidget.runtime.removeListener(runtimeChanged);
    invalidate();
    status = null;
    failure = null;
    observeRuntime();
    unawaited(refresh());
  }

  void runtimeChanged() {
    final next = (widget.runtime.connectionGeneration, widget.runtime.phase);
    if (next == observedRuntime) return;
    observedRuntime = next;
    setState(invalidate);
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    active = value == AppLifecycleState.resumed;
    setState(invalidate);
    if (active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (!active || reading || saving) return;
    final ticket = ++epoch;
    final runtime = widget.runtime;
    final connection = runtime.connectionGeneration;
    bool owns() => mounted && active && ticket == epoch;
    setState(() => reading = true);
    try {
      final next = _ScheduleWakeStatus(
        await runtime.call('runtime.scheduleWake.status') as Json,
      );
      if (owns()) {
        setState(() {
          status = next;
          snapshotConnection = connection;
          failure = null;
        });
      }
    } catch (_) {
      if (owns()) {
        setState(() {
          snapshotConnection = null;
          failure = '无法读取唤醒状态';
        });
      }
    } finally {
      if (owns()) setState(() => reading = false);
    }
  }

  Future<void> configure(bool enabled) async {
    if (!active ||
        !confirmed ||
        reading ||
        saving ||
        openingPermission ||
        (enabled && (!widget.runtime.ready || !status!.allowed))) {
      return;
    }
    final ticket = ++epoch;
    final runtime = widget.runtime;
    final connection = runtime.connectionGeneration;
    bool owns() => mounted && active && ticket == epoch;
    setState(() {
      saving = true;
      failure = null;
    });
    try {
      final next = _ScheduleWakeStatus(
        await runtime.call('runtime.scheduleWake.configure', {
          'enabled': enabled,
        }) as Json,
      );
      if (owns()) {
        setState(() {
          status = next;
          snapshotConnection = connection;
        });
      }
    } catch (_) {
      if (owns()) {
        setState(() {
          snapshotConnection = null;
          failure = '保存结果待确认';
        });
      }
    } finally {
      if (mounted) {
        final stale = !owns();
        setState(() => saving = false);
        if (stale && active) unawaited(refresh());
      }
    }
  }

  Future<void> openPermission() async {
    if (!active || openingPermission || saving) return;
    final ticket = sourceEpoch;
    setState(() => openingPermission = true);
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'background.scheduleWake.openPermission',
      );
      if (mounted && active) await refresh();
    } catch (_) {
      if (mounted && active && ticket == sourceEpoch) {
        setState(() => failure = '无法打开精确闹钟设置');
      }
    } finally {
      if (mounted) setState(() => openingPermission = false);
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
  Widget build(BuildContext context) => PocketSection(
    title: '定时任务',
    children: [
      PocketSwitchRow(
        key: const ValueKey('schedule-wake-switch'),
        leading: const Icon(Icons.alarm_rounded),
        title: const Text('到时唤醒 Agent'),
        subtitle: Text(confirmed ? status!.label : '状态待确认'),
        value: status?.enabled ?? false,
        onChanged:
            active &&
                confirmed &&
                !reading &&
                !saving &&
                !openingPermission &&
                (status!.enabled || (widget.runtime.ready && status!.allowed))
            ? configure
            : null,
      ),
      if (confirmed && !status!.allowed)
        PocketRow(
          icon: Icons.open_in_new_rounded,
          title: '允许精确闹钟',
          onTap: active && !openingPermission && !saving
              ? openPermission
              : null,
        ),
      if (failure != null || (confirmed && status!.alarm == 'error'))
        PocketRow(
          icon: Icons.refresh_rounded,
          title: '重新读取',
          subtitle: failure,
          onTap: active && !reading && !saving ? refresh : null,
        ),
    ],
  );
}
