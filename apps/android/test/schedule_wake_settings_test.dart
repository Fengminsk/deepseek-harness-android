import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/schedule_wake_settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json snapshot({
  bool enabled = false,
  bool allowed = true,
  String projection = 'ready',
  int? activeCount = 0,
  int? nextDueAtMs,
  String alarm = 'disabled',
  int? armedAtMs,
}) => {
  'enabled': enabled,
  'exactAlarmsAllowed': allowed,
  'projectionState': projection,
  'activeCount': activeCount,
  'nextDueAtMs': nextDueAtMs,
  'alarmState': alarm,
  'error': null,
  'armedAtMs': armedAtMs,
};

class ScheduleRuntime extends RuntimeController {
  ScheduleRuntime() {
    phase = 'ready';
  }
  Json value = snapshot();
  int reads = 0, generation = 0;
  final writes = <Json>[];
  Future<Json>? pendingRead, pendingWrite;
  Object? readFailure, writeFailure;

  @override
  int get connectionGeneration => generation;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'runtime.scheduleWake.status') {
      expect(params, isEmpty);
      reads++;
      if (readFailure case final Object failure) throw failure;
      return pendingRead ?? Map.of(value);
    }
    if (method == 'runtime.scheduleWake.configure') {
      expect(params.keys, ['enabled']);
      expect(params['enabled'], isA<bool>());
      writes.add(Map.of(params));
      if (writeFailure case final Object failure) throw failure;
      if (pendingWrite != null) return pendingWrite;
      value = {
        ...value,
        'enabled': params['enabled'],
        'alarmState': params['enabled'] == true ? 'waiting' : 'disabled',
      };
      return Map.of(value);
    }
    throw StateError('Unexpected call $method');
  }

  void reconnect() {
    generation++;
    notifyListeners();
  }
}

class PermissionPage {
  int opens = 0;
  Future<void>? pending;
  Object? failure;

  Future<dynamic> handle(MethodCall call) async {
    expect(call.method, 'background.scheduleWake.openPermission');
    expect(call.arguments, isNull);
    opens++;
    if (failure case final Object error) throw error;
    await pending;
    return null;
  }
}

Finder get toggle => find.byKey(const ValueKey('schedule-wake-switch'));
PocketSwitchRow row(WidgetTester tester) => tester.widget(toggle);

Future<void> open(
  WidgetTester tester,
  ScheduleRuntime runtime, [
  PermissionPage? permission,
]) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    RuntimeController.channel,
    (permission ?? PermissionPage()).handle,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.dark),
      home: PocketScaffold(
        title: const Text('后台执行'),
        body: PocketList(
          children: [ScheduleWakeSettingsSection(runtime: runtime)],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

Future<void> poll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening reads without enabling or launching system settings', (
    tester,
  ) async {
    final runtime = ScheduleRuntime()..value = snapshot(allowed: false);
    final permission = PermissionPage();
    await open(tester, runtime, permission);
    expect(runtime.reads, 1);
    expect(runtime.writes, isEmpty);
    expect(permission.opens, 0);
    expect(row(tester).value, isFalse);
    expect(row(tester).onChanged, isNull);
    expect(find.text('需要精确闹钟权限'), findsOneWidget);
    expect(find.text('允许精确闹钟'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'permission denial and grant only refresh until an explicit opt-in',
    (tester) async {
      final runtime = ScheduleRuntime()..value = snapshot(allowed: false);
      final permission = PermissionPage();
      await open(tester, runtime, permission);
      await tester.tap(find.text('允许精确闹钟'));
      await tester.pumpAndSettle();
      expect(permission.opens, 1);
      expect(runtime.reads, 2);
      expect(row(tester).onChanged, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final reads = runtime.reads;
      await poll(tester);
      expect(runtime.reads, reads);
      runtime.value = snapshot();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(row(tester).value, isFalse);
      expect(row(tester).onChanged, isNotNull);
      expect(runtime.writes, isEmpty);
      expect(find.text('允许精确闹钟'), findsNothing);
      await tester.tap(find.text('到时唤醒 Agent'));
      await tester.pumpAndSettle();
      expect(runtime.writes, [
        {'enabled': true},
      ]);
      expect(row(tester).value, isTrue);
      expect(find.text('暂无待执行任务'), findsOneWidget);
      expect(permission.opens, 1);
      await close(tester);
    },
  );

  testWidgets(
    'opening permission is single flight and reports a safe failure',
    (tester) async {
      final runtime = ScheduleRuntime()..value = snapshot(allowed: false);
      final pending = Completer<void>();
      final permission = PermissionPage()..pending = pending.future;
      await open(tester, runtime, permission);
      await tester.tap(find.text('允许精确闹钟'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许精确闹钟'));
      await tester.pumpAndSettle();
      expect(permission.opens, 1);
      await poll(tester);
      pending.completeError(
        PlatformException(code: 'settings', message: 'secret'),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法打开精确闹钟设置'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(runtime.writes, isEmpty);
      await close(tester);
    },
  );

  testWidgets('native storage error is visible even when enabled is false', (
    tester,
  ) async {
    final runtime = ScheduleRuntime()
      ..value = {
        ...snapshot(projection: 'unavailable', alarm: 'error'),
        'error': 'storage_corrupt',
      };
    await open(tester, runtime);
    expect(row(tester).value, isFalse);
    expect(find.text('唤醒设置暂不可用'), findsOneWidget);
    expect(find.text('已关闭'), findsNothing);
    expect(find.text('重新读取'), findsOneWidget);
    runtime.value['exactAlarmsAllowed'] = false;
    await poll(tester);
    expect(find.text('唤醒设置暂不可用'), findsOneWidget);
    expect(find.text('允许精确闹钟'), findsOneWidget);
    expect(find.text('已关闭'), findsNothing);
    expect(runtime.writes, isEmpty);
    await close(tester);
  });

  testWidgets('enable preference does not claim a scheduled alarm', (
    tester,
  ) async {
    final runtime = ScheduleRuntime()
      ..value = snapshot(
        enabled: true,
        projection: 'unknown',
        alarm: 'waiting',
      );
    await open(tester, runtime);
    expect(row(tester).value, isTrue);
    expect(find.text('定时任务状态待确认'), findsOneWidget);
    expect(find.textContaining('下次唤醒'), findsNothing);
    final due = DateTime(2026, 11, 3, 9, 5).millisecondsSinceEpoch;
    runtime.value = snapshot(
      enabled: true,
      activeCount: 2,
      nextDueAtMs: due,
      alarm: 'scheduled',
      armedAtMs: due,
    );
    await poll(tester);
    expect(find.text('下次唤醒：2026年11月3日 09:05'), findsOneWidget);
    expect(tester.takeException(), isNull);
    runtime.value['armedAtMs'] = null;
    await poll(tester);
    expect(find.textContaining('下次唤醒'), findsNothing);
    expect(find.text('唤醒时间待确认'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'revoked permission withdraws the alarm and still allows disabling',
    (tester) async {
      final runtime = ScheduleRuntime()
        ..value = snapshot(enabled: true, alarm: 'waiting');
      await open(tester, runtime);
      runtime.value = snapshot(
        enabled: true,
        allowed: false,
        alarm: 'permission-required',
      );
      await poll(tester);
      expect(find.text('需要精确闹钟权限'), findsOneWidget);
      expect(row(tester).onChanged, isNotNull);
      await tester.tap(find.text('到时唤醒 Agent'));
      await tester.pumpAndSettle();
      expect(runtime.writes, [
        {'enabled': false},
      ]);
      expect(row(tester).value, isFalse);
      expect(row(tester).onChanged, isNull);
      await close(tester);
    },
  );

  testWidgets('failed Agent still allows native disable but cannot enable', (
    tester,
  ) async {
    final runtime = ScheduleRuntime()
      ..value = snapshot(enabled: true, alarm: 'waiting');
    await open(tester, runtime);
    runtime.phase = 'failed';
    runtime.notifyListeners();
    await tester.pumpAndSettle();
    expect(runtime.reads, 2);
    expect(row(tester).value, isTrue);
    expect(row(tester).onChanged, isNotNull);
    await tester.tap(find.text('到时唤醒 Agent'));
    await tester.pumpAndSettle();
    expect(runtime.writes, [
      {'enabled': false},
    ]);
    expect(row(tester).value, isFalse);
    expect(row(tester).onChanged, isNull);
    expect(find.text('已关闭'), findsOneWidget);
    await close(tester);
  });

  testWidgets('pending and rejected writes retain the acknowledged value', (
    tester,
  ) async {
    final runtime = ScheduleRuntime();
    final pending = Completer<Json>();
    runtime.pendingWrite = pending.future;
    await open(tester, runtime);
    await tester.tap(find.text('到时唤醒 Agent'));
    await tester.pumpAndSettle();
    expect(row(tester).value, isFalse);
    expect(row(tester).onChanged, isNull);
    pending.completeError(PlatformException(code: 'permission-required'));
    await tester.pumpAndSettle();
    expect(row(tester).value, isFalse);
    expect(find.text('保存结果待确认'), findsOneWidget);
    runtime.value = snapshot(allowed: false);
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(find.text('需要精确闹钟权限'), findsOneWidget);
    expect(runtime.writes, hasLength(1));
    await close(tester);
  });

  testWidgets('late read from the old connection cannot overwrite new status', (
    tester,
  ) async {
    final runtime = ScheduleRuntime();
    await open(tester, runtime);
    final old = Completer<Json>();
    runtime.pendingRead = old.future;
    await poll(tester);
    runtime.pendingRead = null;
    runtime.value = snapshot(allowed: false);
    runtime.reconnect();
    await tester.pumpAndSettle();
    old.complete(snapshot(enabled: true, alarm: 'waiting'));
    await tester.pumpAndSettle();
    expect(row(tester).value, isFalse);
    expect(find.text('需要精确闹钟权限'), findsOneWidget);
    expect(row(tester).onChanged, isNull);
    expect(runtime.writes, isEmpty);
    await close(tester);
  });

  testWidgets('reconnect fences a late write and rereads without replay', (
    tester,
  ) async {
    final runtime = ScheduleRuntime();
    final old = Completer<Json>();
    runtime.pendingWrite = old.future;
    await open(tester, runtime);
    await tester.tap(find.text('到时唤醒 Agent'));
    await tester.pumpAndSettle();
    runtime.reconnect();
    await tester.pumpAndSettle();
    expect(find.text('状态待确认'), findsOneWidget);
    expect(row(tester).onChanged, isNull);
    old.complete(snapshot(enabled: true, alarm: 'waiting'));
    await tester.pumpAndSettle();
    expect(runtime.reads, 2);
    expect(row(tester).value, isFalse);
    expect(runtime.writes, hasLength(1));
    await close(tester);
  });

  testWidgets('background reads are discarded and disposal stops polling', (
    tester,
  ) async {
    final runtime = ScheduleRuntime();
    await open(tester, runtime);
    final old = Completer<Json>();
    runtime.pendingRead = old.future;
    await poll(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    old.complete(snapshot(enabled: true, alarm: 'waiting'));
    await tester.pumpAndSettle();
    final resumed = Completer<Json>();
    runtime.pendingRead = resumed.future;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('状态待确认'), findsOneWidget);
    expect(row(tester).value, isFalse);
    resumed.complete(snapshot());
    runtime.pendingRead = null;
    await tester.pumpAndSettle();
    expect(row(tester).value, isFalse);
    await close(tester);
    final reads = runtime.reads;
    await poll(tester);
    expect(runtime.reads, reads);
  });

  testWidgets(
    'failed and malformed reads withdraw controls without raw errors',
    (tester) async {
      final runtime = ScheduleRuntime();
      await open(tester, runtime);
      runtime.readFailure = StateError('secret');
      await poll(tester);
      expect(find.text('状态待确认'), findsOneWidget);
      expect(find.text('无法读取唤醒状态'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(row(tester).onChanged, isNull);
      runtime.readFailure = null;
      runtime.value['exactAlarmsAllowed'] = 'true';
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(row(tester).onChanged, isNull);
      expect(find.text('无法读取唤醒状态'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      await close(tester);
    },
  );
}
