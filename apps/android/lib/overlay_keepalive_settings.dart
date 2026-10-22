import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

String overlayStateLabel(Json? state) => switch (state?['state']) {
  'disabled' => '已关闭',
  'permission-required' => '等待悬浮窗授权',
  'idle' => '暂无执行中的任务',
  'attaching' => '正在附着窗口',
  'attached' when state?['attached'] == true => '透明窗口已附着',
  'failed' => '窗口暂不可用',
  'stopped' => '后台服务已停止',
  _ => '窗口状态待确认',
};

String overlayFailureLabel(Object? code) => switch (code) {
  'permission-monitor-unavailable' => '无法确认权限变化，暂不启用悬浮窗。',
  'permission-check-unavailable' => '暂时无法读取悬浮窗权限，请刷新后再试。',
  'attach-failed' => '系统未允许附着窗口，可检查授权后重新尝试。',
  'remove-failed' => '窗口移除结果尚未确认，请刷新状态。',
  'detached' => '窗口已被系统移除，可重新尝试。',
  _ => '请刷新窗口状态后再试。',
};

/// The preference, permission and attached window remain independent observations.
class OverlayKeepaliveSettingsPage extends StatefulWidget {
  const OverlayKeepaliveSettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;

  @override
  State<OverlayKeepaliveSettingsPage> createState() =>
      _OverlayKeepaliveSettingsPageState();
}

class _OverlayKeepaliveSettingsPageState
    extends State<OverlayKeepaliveSettingsPage>
    with WidgetsBindingObserver {
  Json? state;
  String? error;
  bool loading = false,
      saving = false,
      active = true,
      openingPermission = false;
  bool? requested;
  int attempt = 0;
  int? snapshotConnection;
  late (int, String) observedRuntime;
  Timer? timer;

  bool get confirmed =>
      state != null &&
      widget.runtime.ready &&
      snapshotConnection == widget.runtime.connectionGeneration &&
      error == null;

  @override
  void initState() {
    super.initState();
    observedRuntime = (
      widget.runtime.connectionGeneration,
      widget.runtime.phase,
    );
    widget.runtime.addListener(runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (active) unawaited(refresh());
    });
  }

  void runtimeChanged() {
    final next = (widget.runtime.connectionGeneration, widget.runtime.phase);
    if (next == observedRuntime) return;
    observedRuntime = next;
    attempt++;
    setState(() {
      snapshotConnection = null;
      loading = false;
      saving = false;
      error = '连接已变化，悬浮窗状态待核对。';
    });
    if (active) unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    active = value == AppLifecycleState.resumed;
    if (active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading || saving) return;
    final ticket = ++attempt;
    final connection = widget.runtime.connectionGeneration;
    bool owns() =>
        mounted &&
        ticket == attempt &&
        connection == widget.runtime.connectionGeneration;
    setState(() => loading = true);
    try {
      final result = await widget.runtime.call('runtime.status') as Json;
      final background = result['background'] as Json;
      final overlay = background['overlay'];
      if (overlay is! Json) throw StateError('悬浮窗状态不可用');
      if (owns()) {
        setState(() {
          state = overlay;
          snapshotConnection = connection;
          error = null;
        });
      }
    } catch (_) {
      if (owns()) {
        setState(() {
          snapshotConnection = null;
          error = '悬浮窗状态未确认，请刷新后再操作。';
        });
      }
    } finally {
      if (owns()) setState(() => loading = false);
    }
  }

  Future<void> configure(bool enabled) async {
    if (!confirmed || loading || saving) return;
    final ticket = ++attempt;
    final connection = widget.runtime.connectionGeneration;
    bool owns() =>
        mounted &&
        ticket == attempt &&
        connection == widget.runtime.connectionGeneration;
    setState(() {
      saving = true;
      requested = enabled;
    });
    try {
      final result = await widget.runtime.call(
        'runtime.background.overlay.configure',
        {'enabled': enabled},
      ) as Json;
      if (owns()) {
        setState(() {
          state = result;
          snapshotConnection = connection;
          requested = null;
          error = null;
        });
      }
    } catch (_) {
      if (owns()) {
        setState(() {
          snapshotConnection = null;
          error = '设置保存未确认，请刷新后核对。';
        });
      }
    } finally {
      if (owns()) setState(() => saving = false);
    }
  }

  Future<void> openPermission() async {
    if (openingPermission) return;
    setState(() => openingPermission = true);
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'background.overlay.openPermission',
      );
    } catch (_) {
      if (mounted) {
        setState(() => error = '无法打开授权页面，请在系统设置中查找“显示在其他应用上层”。');
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
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('透明悬浮窗'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新状态',
      onPressed: loading || saving ? null : refresh,
    ),
    body: PocketList(
      children: [
        PocketSection(
          children: [
            PocketSwitchRow(
              key: const ValueKey('overlay-keepalive-switch'),
              title: const Text('使用透明悬浮窗辅助保活'),
              subtitle: const Text('默认关闭，由你决定是否启用。'),
              value: state?['enabled'] == true,
              onChanged: confirmed && !loading && !saving ? configure : null,
            ),
          ],
        ),
        PocketSection(
          title: '当前状态',
          children: [
            PocketRow(
              icon: Icons.layers_outlined,
              title: '窗口状态',
              subtitle: confirmed ? overlayStateLabel(state) : '窗口状态待确认',
            ),
            PocketRow(
              icon: Icons.verified_user_outlined,
              title: '悬浮窗权限',
              subtitle: !confirmed
                  ? '待确认'
                  : switch (state?['permissionGranted']) {
                      true => '已允许',
                      false => '未允许',
                      _ => '待确认',
                    },
            ),
            if (confirmed && state?['state'] == 'failed')
              PocketRow(
                icon: Icons.info_outline_rounded,
                title: overlayFailureLabel(state?['error']),
              ),
            if (confirmed &&
                state?['state'] == 'failed' &&
                state?['enabled'] == true)
              PocketRow(
                icon: Icons.refresh_rounded,
                title: '重新尝试',
                onTap: loading || saving ? null : () => configure(true),
              ),
            PocketRow(
              icon: Icons.open_in_new_rounded,
              title: '系统悬浮窗设置',
              onTap: openingPermission ? null : openPermission,
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (requested != null && !saving)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '上次${requested! ? '开启' : '关闭'}的保存结果待核对；'
              '当前显示为重新读取的状态，不会自动重发操作。',
            ),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '授权后，仅在任务、后台作业或插件管理操作执行期间附着 1 像素透明窗口。'
            '不接收触摸、不获取焦点，也不会点亮屏幕；任务停止或状态无法确认时移除。\n\n'
            '这是一项辅助策略，效果取决于手机系统，不能保证进程不被停止。'
            '系统可能显示悬浮窗提示。',
          ),
        ),
      ],
    ),
  );
}
