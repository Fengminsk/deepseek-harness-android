import 'dart:async';

import 'package:dsh_android/overlay_keepalive_settings.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json overlay({
  bool enabled = false,
  bool granted = false,
  bool attached = false,
  String state = 'disabled',
  String? error,
}) => {
  'enabled': enabled,
  'permissionGranted': granted,
  'attached': attached,
  'activeWork': attached,
  'state': state,
  'error': error,
};

class OverlayRuntime extends RuntimeController {
  OverlayRuntime() {
    phase = 'ready';
  }
  Json value = overlay();
  final writes = <Json>[];
  int reads = 0;
  Future<Json>? pendingRead, pendingWrite;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'runtime.status') {
      reads++;
      return pendingRead ??
          {
            'background': {'overlay': Map.of(value)},
          };
    }
    if (method == 'runtime.background.overlay.configure') {
      expect(params.keys, ['enabled']);
      writes.add(Map.of(params));
      if (pendingWrite != null) return pendingWrite;
      value = overlay(
        enabled: params['enabled'] == true,
        state: params['enabled'] == true ? 'permission-required' : 'disabled',
      );
      return value;
    }
    throw StateError('Unexpected call $method');
  }

  void reconnected() {
    phase = 'ready';
    notifyListeners();
  }
}

Future<List<String>> open(WidgetTester tester, OverlayRuntime runtime) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  final nativeCalls = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(RuntimeController.channel, (call) async {
    nativeCalls.add(call.method);
    expect(call.method, 'background.overlay.openPermission');
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: OverlayKeepaliveSettingsPage(runtime: runtime),
    ),
  );
  await tester.pumpAndSettle();
  return nativeCalls;
}

Finder get toggle => find.byKey(const ValueKey('overlay-keepalive-switch'));

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening reads only and opt-in does not launch permission UI', (
    tester,
  ) async {
    final runtime = OverlayRuntime();
    final native = await open(tester, runtime);
    expect(runtime.reads, 1);
    expect(runtime.writes, isEmpty);
    expect(native, isEmpty);
    expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
    await tester.tap(find.text('使用透明悬浮窗辅助保活'));
    await tester.pumpAndSettle();
    expect(runtime.writes, [
      {'enabled': true},
    ]);
    expect(native, isEmpty);
    expect(find.text('等待悬浮窗授权'), findsOneWidget);
    expect(find.text('未允许'), findsOneWidget);
    expect(find.text('透明窗口已附着'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'permission return refreshes actual attachment without replaying choice',
    (tester) async {
      final runtime = OverlayRuntime()
        ..value = overlay(enabled: true, state: 'permission-required');
      final native = await open(tester, runtime);
      await tester.tap(find.text('系统悬浮窗设置'));
      await tester.pumpAndSettle();
      expect(native, ['background.overlay.openPermission']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      runtime.value = overlay(enabled: true, granted: true, state: 'idle');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('已允许'), findsOneWidget);
      expect(find.text('暂无执行中的任务'), findsOneWidget);
      expect(find.text('透明窗口已附着'), findsNothing);
      expect(runtime.writes, isEmpty);
      expect(native, hasLength(1));
      await close(tester);
    },
  );

  testWidgets('failure and true attachment remain separate from enabled', (
    tester,
  ) async {
    final runtime = OverlayRuntime()
      ..value = overlay(
        enabled: true,
        granted: true,
        state: 'failed',
        error: 'attach-failed',
      );
    await open(tester, runtime);
    expect(tester.widget<PocketSwitchRow>(toggle).value, isTrue);
    expect(find.text('窗口暂不可用'), findsOneWidget);
    expect(find.text('透明窗口已附着'), findsNothing);
    runtime.value = overlay(
      enabled: true,
      granted: true,
      attached: true,
      state: 'attached',
    );
    await tester.tap(
      find.byWidgetPredicate((w) => w is GlassButton && w.label == '刷新状态'),
    );
    await tester.pumpAndSettle();
    expect(find.text('透明窗口已附着'), findsOneWidget);
    expect(runtime.writes, isEmpty);
    await close(tester);
  });

  testWidgets(
    'connection loss withdraws attachment and fences late write receipt',
    (tester) async {
      final runtime = OverlayRuntime()
        ..value = overlay(
          enabled: true,
          granted: true,
          attached: true,
          state: 'attached',
        );
      final pending = Completer<Json>();
      runtime.pendingWrite = pending.future;
      final native = await open(tester, runtime);
      await tester.tap(find.text('使用透明悬浮窗辅助保活'));
      await tester.pumpAndSettle();
      expect(runtime.writes, [
        {'enabled': false},
      ]);
      runtime.fail(StateError('disconnected'));
      await tester.pumpAndSettle();
      expect(find.text('透明窗口已附着'), findsNothing);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      runtime.value = overlay(enabled: true, granted: true, state: 'idle');
      runtime.reconnected();
      await tester.pumpAndSettle();
      pending.complete(overlay());
      await tester.pumpAndSettle();
      expect(tester.widget<PocketSwitchRow>(toggle).value, isTrue);
      expect(find.text('暂无执行中的任务'), findsOneWidget);
      expect(find.textContaining('上次关闭的保存结果待核对'), findsOneWidget);
      expect(runtime.writes, hasLength(1));
      expect(native, isEmpty);
      await close(tester);
    },
  );

  testWidgets(
    'stale read cannot restore an old attached window after reconnection',
    (tester) async {
      final runtime = OverlayRuntime();
      final pending = Completer<Json>();
      await open(tester, runtime);
      runtime.pendingRead = pending.future;
      await tester.tap(
        find.byWidgetPredicate((w) => w is GlassButton && w.label == '刷新状态'),
      );
      await tester.pump();
      runtime.fail(StateError('disconnected'));
      runtime.pendingRead = null;
      runtime.reconnected();
      await tester.pumpAndSettle();
      pending.complete({
        'background': {
          'overlay': overlay(
            enabled: true,
            granted: true,
            attached: true,
            state: 'attached',
          ),
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('透明窗口已附着'), findsNothing);
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      await close(tester);
    },
  );
}
