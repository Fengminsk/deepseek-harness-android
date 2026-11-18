// 「后台保活」设置页与状态文案的测试：页面对 ANR/厂商限制如实说明，不假装能绕过。
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_sync_service.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;

RemoteSyncServiceStatus _status({
  bool running = false,
  bool degraded = false,
  bool ignored = false,
  bool abnormal = false,
}) => RemoteSyncServiceStatus(
  running: running,
  degraded: degraded,
  recoveryPending: degraded,
  wakeLockHeld: running,
  wakeLockExpiries: 1,
  batteryOptimizationsIgnored: ignored,
  backgroundRestricted: false,
  powerSaveMode: false,
  uiAlive: true,
  previousRunAbnormal: abnormal,
  previousRunStartedAt: abnormal ? DateTime.utc(2026, 11, 18, 17, 50) : null,
  startedAt: DateTime.utc(2026, 11, 18, 17, 58),
  lastHeartbeatAt: DateTime.now().subtract(const Duration(seconds: 5)),
  lastTaskRemovedAt: null,
  lastStartReason: 'app-start',
  lastStopReason: degraded ? 'heartbeat-timeout' : null,
  storedLastAction: 'running',
  storedLastActionAt: DateTime.utc(2026, 11, 18, 17, 58),
  storedStopReason: null,
);

RemoteSyncDiagnostics _diagnostics({
  RemoteSyncServiceStatus? service,
  RemoteConnectionPhase? phase,
  bool enabled = true,
  bool previousRunAbnormal = false,
}) => RemoteSyncDiagnostics(
  service: service ?? _status(abnormal: previousRunAbnormal),
  backgroundSyncEnabled: enabled,
  pageOpen: false,
  serviceRequested: service?.running ?? false,
  serviceStarts: 1,
  serviceStops: 0,
  heartbeatActive: service?.running ?? false,
  phase: phase,
  deviceLabel: '客厅的电脑',
  pairedDeviceCount: 1,
  lastError: null,
  lastErrorCode: null,
  lastDisconnectReason: null,
  lastServiceError: null,
  lastRestoreError: null,
);

void main() {
  group('后台保活状态文案', () {
    test('运行中的服务显示同步中', () {
      expect(
        remoteSyncServiceLabel(
          _diagnostics(service: _status(running: true)),
        ),
        '后台同步运行中',
      );
    });

    test('心跳超时降级后提示点按恢复', () {
      expect(
        remoteSyncServiceLabel(
          _diagnostics(service: _status(degraded: true)),
        ),
        '后台同步已中断 · 可在通知栏点按恢复',
      );
    });

    test('没有原生状态时如实说未确认/未运行', () {
      final missing = RemoteSyncDiagnostics(
        service: null,
        backgroundSyncEnabled: true,
        pageOpen: false,
        serviceRequested: false,
        serviceStarts: 0,
        serviceStops: 0,
        heartbeatActive: false,
        phase: null,
        deviceLabel: null,
        pairedDeviceCount: 0,
        lastError: null,
        lastErrorCode: null,
        lastDisconnectReason: null,
        lastServiceError: null,
        lastRestoreError: null,
      );
      expect(remoteSyncServiceLabel(missing), '后台同步服务未运行');
    });

    test('连接阶段文案覆盖失败与重连', () {
      expect(
        remoteSyncPhaseLabel(RemoteConnectionPhase.ready),
        '连接就绪',
      );
      expect(
        remoteSyncPhaseLabel(RemoteConnectionPhase.reconnecting),
        '连接断开，正在重连',
      );
      expect(remoteSyncPhaseLabel(null), '尚未建立远程连接');
    });
  });

  testWidgets('后台保活页展示开关、电池优化引导与保活边界', (tester) async {
    final runtime = LibraryRuntime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: RemoteBackgroundSyncPage(runtime: runtime),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('remote-background-sync-switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('remote-background-request-battery')),
      findsOneWidget,
      reason: '电池优化状态未知时仍给出显式引导入口',
    );
    expect(
      find.byKey(const ValueKey('remote-background-oem-settings')),
      findsOneWidget,
    );
    expect(find.textContaining('不能绕过主线程无响应'), findsOneWidget);
    expect(find.textContaining('与电脑保持同步'), findsWidgets);

    // 计时器随页面销毁取消，避免测试结束时报 pending timer。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
