import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/background_settings.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json snapshot({
  String taskState = 'running',
  int running = 2,
  int queued = 1,
  int jobs = 3,
  int? packageOperations = 0,
  bool keepAwake = false,
}) => {
  'keepAwakeWhileWorking': keepAwake,
  'wakeLockHeld': keepAwake && running > 0,
  'taskState': taskState,
  'fresh': true,
  'running': running,
  'queued': queued,
  'waiting': 0,
  'failed': 0,
  'backgroundJobs': jobs,
  'packageOperations': packageOperations,
  'powerError': null,
  'notificationError': null,
};

class BackgroundRuntime extends RuntimeController {
  BackgroundRuntime() {
    phase = 'ready';
  }
  Json background = snapshot();
  Object? statusFailure;
  Future<Json>? configureResult, statusResult;
  final calls = <(String, Json)>[];

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    switch (method) {
      case 'runtime.status':
        expect(params, isEmpty);
        if (statusFailure case final Object failure) throw failure;
        if (statusResult case final Future<Json> result) return result;
        return {
          'phase': 'ready',
          'error': null,
          'background': jsonDecode(jsonEncode(background)),
        };
      case 'runtime.background.configure':
        expect(params.keys, ['keepAwakeWhileWorking']);
        return configureResult ??
            Future.value({
              ...background,
              'keepAwakeWhileWorking': params['keepAwakeWhileWorking'],
            });
      default:
        throw StateError('Unexpected runtime call: $method');
    }
  }

  int get reads => calls.where((call) => call.$1 == 'runtime.status').length;
  int get writes =>
      calls.where((call) => call.$1 == 'runtime.background.configure').length;

  void readyAgain() {
    phase = 'ready';
    notifyListeners();
  }
}

class SystemPolicy {
  Json value = {
    'batteryOptimizationsIgnored': true,
    'backgroundRestricted': false,
    'powerSaveMode': true,
  };
  Object? failure, openFailure;
  final calls = <String>[];

  Future<dynamic> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'background.systemStatus':
        if (failure case final Object error) throw error;
        return jsonEncode(value);
      case 'background.openSystemSettings':
        if (openFailure case final Object error) throw error;
        return null;
      default:
        throw StateError('Unexpected native call: ${call.method}');
    }
  }
}

Future<void> open(
  WidgetTester tester,
  BackgroundRuntime runtime,
  SystemPolicy policy,
) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(RuntimeController.channel, policy.handle);
  addTearDown(
    () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: BackgroundSettingsPage(runtime: runtime),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get refresh => find.byWidgetPredicate(
  (widget) => widget is GlassButton && widget.label == '刷新状态',
);
Finder get toggle => find.byType(PocketSwitchRow);

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connection loss immediately withdraws task facts and controls', (
    tester,
  ) async {
    final runtime = BackgroundRuntime()..background = snapshot(keepAwake: true);
    await open(tester, runtime, SystemPolicy());
    expect(find.text('正在持有 CPU 唤醒锁'), findsOneWidget);
    runtime.fail(StateError('lost service'));
    await tester.pumpAndSettle();
    expect(find.text('任务执行中'), findsNothing);
    expect(find.text('正在持有 CPU 唤醒锁'), findsNothing);
    expect(find.text('3 个活动作业'), findsNothing);
    expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
    expect(
      runtime.reads,
      2,
      reason: 'native policy can be reread without granting task state',
    );
    expect(runtime.writes, 0);
    await close(tester);
    runtime.readyAgain();
    await tester.pump();
    expect(runtime.reads, 2, reason: 'the disposed page releases its listener');
  });

  for (final lateFailure in [false, true]) {
    testWidgets(
      'connection replacement ignores late status ${lateFailure ? 'failure' : 'success'}',
      (tester) async {
        final runtime = BackgroundRuntime();
        final pending = Completer<Json>();
        await open(tester, runtime, SystemPolicy());
        runtime.statusResult = pending.future;
        await tap(tester, refresh);
        expect(runtime.reads, 2);
        runtime.fail(StateError('lost service'));
        runtime.statusResult = null;
        runtime.background = snapshot(
          taskState: 'idle',
          running: 0,
          queued: 0,
          jobs: 0,
        );
        runtime.readyAgain();
        await tester.pumpAndSettle();
        expect(
          runtime.reads,
          4,
          reason: 'a new connection may read independently',
        );
        expect(find.text('已就绪 · 暂无任务'), findsOneWidget);
        if (lateFailure) {
          pending.completeError(StateError('late old read failure'));
        } else {
          pending.complete({'background': snapshot(keepAwake: true)});
        }
        await tester.pumpAndSettle();
        expect(find.text('已就绪 · 暂无任务'), findsOneWidget);
        expect(find.text('任务执行中'), findsNothing);
        expect(find.textContaining('late old read failure'), findsNothing);
        expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNotNull);
        expect(runtime.writes, 0);
        await close(tester);
      },
    );
  }

  testWidgets(
    'connection replacement retains an unconfirmed choice without replay',
    (tester) async {
      final runtime = BackgroundRuntime();
      final pending = Completer<Json>();
      runtime.configureResult = pending.future;
      await open(tester, runtime, SystemPolicy());
      await tap(tester, find.text('执行任务时保持 CPU 运行'));
      expect(runtime.writes, 1);
      runtime.fail(StateError('lost service during save'));
      await tester.pumpAndSettle();
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      expect(find.textContaining('希望开启'), findsOneWidget);
      runtime.background = snapshot(
        taskState: 'idle',
        running: 0,
        queued: 0,
        jobs: 0,
      );
      runtime.readyAgain();
      await tester.pumpAndSettle();
      expect(runtime.reads, 3);
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      expect(find.textContaining('当前读取为关闭'), findsOneWidget);
      pending.complete(snapshot(keepAwake: true));
      await tester.pumpAndSettle();
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      expect(find.textContaining('希望开启'), findsOneWidget);
      expect(find.text('正在持有 CPU 唤醒锁'), findsNothing);
      expect(runtime.writes, 1);
      await close(tester);
    },
  );

  testWidgets(
    'phase change withdraws observations even without a generation increment',
    (tester) async {
      final runtime = BackgroundRuntime();
      await open(tester, runtime, SystemPolicy());
      final generation = runtime.connectionGeneration;
      runtime.phase = 'starting';
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(runtime.connectionGeneration, generation);
      expect(find.text('任务执行中'), findsNothing);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      await close(tester);
    },
  );

  testWidgets(
    'native battery policy stays readable when the Agent is unavailable',
    (tester) async {
      final runtime = BackgroundRuntime()
        ..phase = 'failed'
        ..background = snapshot(keepAwake: true);
      final policy = SystemPolicy();
      await open(tester, runtime, policy);
      expect(find.text('服务异常 · 任务可能已中断'), findsOneWidget);
      expect(find.text('任务执行中'), findsNothing);
      expect(find.text('正在持有 CPU 唤醒锁'), findsNothing);
      expect(find.text('已获得 Android 标准电池优化豁免'), findsOneWidget);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      await tap(tester, refresh);
      expect(runtime.reads, 2);
      expect(runtime.writes, 0);
      expect(policy.calls, [
        'background.systemStatus',
        'background.systemStatus',
      ]);
      await close(tester);
    },
  );

  testWidgets('plugin activity is separate and withdrawn on failed refresh', (
    tester,
  ) async {
    final runtime = BackgroundRuntime()
      ..background = snapshot(
        taskState: 'packages',
        running: 0,
        queued: 0,
        jobs: 0,
        packageOperations: 2,
        keepAwake: true,
      );
    await open(tester, runtime, SystemPolicy());
    expect(find.text('插件管理操作中'), findsOneWidget);
    expect(find.text('2 项进行中'), findsOneWidget);
    expect(find.text('0 个任务执行 · 0 条输入排队 · 0 项等待处理'), findsOneWidget);
    runtime.statusFailure = StateError('disconnected');
    await tap(tester, refresh);
    expect(find.text('2 项进行中'), findsNothing);
    expect(find.text('插件管理操作中'), findsNothing);
    expect(find.text('任务状态尚未确认'), findsOneWidget);
    await close(tester);
  });

  testWidgets('unknown plugin count is not presented as zero', (tester) async {
    final runtime = BackgroundRuntime()
      ..background = snapshot(packageOperations: null);
    await open(tester, runtime, SystemPolicy());
    expect(find.text('状态尚未确认，请刷新后查看'), findsOneWidget);
    expect(find.text('0 项进行中'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'opening reads service and system state without changing policy',
    (tester) async {
      final runtime = BackgroundRuntime();
      final policy = SystemPolicy();
      await open(tester, runtime, policy);
      expect(runtime.reads, 1);
      expect(runtime.writes, 0);
      expect(policy.calls, ['background.systemStatus']);
      expect(find.text('任务执行中'), findsOneWidget);
      expect(find.text('2 个任务执行 · 1 条输入排队 · 0 项等待处理'), findsOneWidget);
      expect(find.text('3 个活动作业'), findsOneWidget);
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      await close(tester);
    },
  );

  testWidgets(
    'failed status refresh withdraws old task counts and system policy facts',
    (tester) async {
      final runtime = BackgroundRuntime();
      final policy = SystemPolicy();
      await open(tester, runtime, policy);
      expect(find.text('已获得 Android 标准电池优化豁免'), findsOneWidget);
      runtime.statusFailure = PlatformException(code: 'disconnected');
      await tap(tester, refresh);
      expect(find.text('任务状态尚未确认'), findsOneWidget);
      expect(find.text('任务执行中'), findsNothing);
      expect(find.text('2 个任务执行 · 1 条输入排队 · 0 项等待处理'), findsNothing);
      expect(find.text('3 个活动作业'), findsNothing);
      expect(find.text('已获得 Android 标准电池优化豁免'), findsNothing);
      expect(find.text('Android 标准接口未报告后台限制'), findsNothing);
      expect(find.text('未确认'), findsNWidgets(3));
      expect(find.text('CPU 唤醒锁状态待确认'), findsOneWidget);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      await close(tester);
    },
  );

  testWidgets(
    'first read failure shows unconfirmed state rather than an endless loading claim',
    (tester) async {
      final runtime = BackgroundRuntime()
        ..statusFailure = PlatformException(code: 'unavailable');
      await open(tester, runtime, SystemPolicy());
      expect(find.text('任务状态尚未确认'), findsOneWidget);
      expect(find.text('正在读取后台状态'), findsNothing);
      expect(find.textContaining('后台状态未确认'), findsOneWidget);
      expect(find.text('未确认'), findsNWidgets(3));
      expect(toggle, findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'system policy read failure does not keep previous battery exemptions',
    (tester) async {
      final runtime = BackgroundRuntime();
      final policy = SystemPolicy();
      await open(tester, runtime, policy);
      policy.failure = PlatformException(code: 'system-unavailable');
      await tap(tester, refresh);
      expect(find.text('已获得 Android 标准电池优化豁免'), findsNothing);
      expect(find.text('未确认'), findsNWidgets(3));
      expect(find.text('任务执行中'), findsNothing);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      await close(tester);
    },
  );

  testWidgets(
    'toggle remains at acknowledged value while saving and after failure',
    (tester) async {
      final runtime = BackgroundRuntime();
      final pending = Completer<Json>();
      runtime.configureResult = pending.future;
      await open(tester, runtime, SystemPolicy());
      await tap(tester, find.text('执行任务时保持 CPU 运行'));
      expect(runtime.writes, 1);
      expect(runtime.calls.last.$2, {'keepAwakeWhileWorking': true});
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      pending.completeError(PlatformException(code: 'save-unknown'));
      await tester.pumpAndSettle();
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      expect(find.textContaining('设置保存未确认'), findsOneWidget);
      runtime.configureResult = null;
      runtime.background = snapshot(keepAwake: true);
      await tap(tester, refresh);
      expect(tester.widget<PocketSwitchRow>(toggle).value, isTrue);
      expect(find.text('正在持有 CPU 唤醒锁'), findsOneWidget);
      expect(find.textContaining('设置保存未确认'), findsNothing);
      expect(runtime.writes, 1);
      await close(tester);
    },
  );

  testWidgets(
    'standard exemptions and a held wake lock never confirm the manufacturer policy',
    (tester) async {
      final runtime = BackgroundRuntime()
        ..background = snapshot(keepAwake: true);
      final policy = SystemPolicy();
      await open(tester, runtime, policy);
      expect(find.text('正在持有 CPU 唤醒锁'), findsOneWidget);
      expect(find.text('已获得 Android 标准电池优化豁免'), findsOneWidget);
      expect(find.text('Android 标准接口未报告后台限制'), findsOneWidget);
      expect(find.text('厂商后台许可需要手动确认'), findsOneWidget);
      final manufacturer = tester.widget<PocketRow>(
        find.byKey(const ValueKey('oem-background-policy')),
      );
      expect(manufacturer.onTap, isNull);
      expect(manufacturer.subtitle, contains('不代表厂商已允许后台运行'));
      policy.value = {
        'batteryOptimizationsIgnored': false,
        'backgroundRestricted': true,
        'powerSaveMode': false,
      };
      runtime.background = snapshot();
      await tap(tester, refresh);
      expect(find.text('当前未持有 CPU 唤醒锁'), findsOneWidget);
      expect(find.text('仍受 Android 标准电池优化管理'), findsOneWidget);
      expect(find.text('Android 已报告后台限制'), findsOneWidget);
      expect(find.text('厂商后台许可需要手动确认'), findsOneWidget);
      expect(runtime.writes, 0);
      expect(policy.calls, everyElement('background.systemStatus'));
      await close(tester);
    },
  );

  testWidgets(
    'missing or malformed policy fields remain unknown instead of reporting no restrictions',
    (tester) async {
      final runtime = BackgroundRuntime()
        ..background = {...snapshot(), 'wakeLockHeld': null};
      final policy = SystemPolicy()
        ..value = {
          'batteryOptimizationsIgnored': 'true',
          'backgroundRestricted': null,
        };
      await open(tester, runtime, policy);
      expect(find.text('未确认'), findsNWidgets(3));
      expect(find.text('CPU 唤醒锁状态待确认'), findsOneWidget);
      expect(find.text('Android 标准接口未报告后台限制'), findsNothing);
      expect(find.text('当前未持有 CPU 唤醒锁'), findsNothing);
      expect(find.text('厂商后台许可需要手动确认'), findsOneWidget);
      expect(runtime.writes, 0);
      await close(tester);
    },
  );

  testWidgets(
    'manual settings entry stays reachable on a phone and returning only rereads standard status',
    (tester) async {
      final runtime = BackgroundRuntime();
      final policy = SystemPolicy();
      await open(tester, runtime, policy);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('手动设置路径'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('完全允许后台行为'), findsOneWidget);
      expect(find.textContaining('可能增加耗电，请按需选择'), findsOneWidget);
      expect(
        policy.calls.where(
          (method) => method == 'background.openSystemSettings',
        ),
        isEmpty,
      );
      await tap(tester, find.text('打开系统应用设置'));
      expect(
        policy.calls.where(
          (method) => method == 'background.openSystemSettings',
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      expect(runtime.writes, 0);
      final reads = runtime.reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 6));
      expect(runtime.reads, reads);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(runtime.reads, reads + 1);
      expect(find.text('厂商后台许可需要手动确认'), findsOneWidget);
      expect(runtime.writes, 0);
      await close(tester);
    },
  );

  testWidgets(
    'system settings failure is visible and resume refreshes actual policy without writes',
    (tester) async {
      final runtime = BackgroundRuntime();
      final policy = SystemPolicy()
        ..openFailure = PlatformException(code: 'settings');
      await open(tester, runtime, policy);
      await tap(tester, find.text('打开系统应用设置'));
      expect(find.textContaining('无法打开系统应用设置'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is PocketSection && widget.title == '手机厂商后台策略',
          ),
          matching: find.textContaining('无法打开系统应用设置'),
        ),
        findsOneWidget,
      );
      expect(find.text('手动设置路径'), findsOneWidget);
      expect(find.text('厂商后台许可需要手动确认'), findsOneWidget);
      expect(runtime.writes, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 20));
      expect(runtime.reads, 1);
      runtime.background = snapshot(
        taskState: 'idle',
        running: 0,
        queued: 0,
        jobs: 0,
      );
      policy.value = {
        'batteryOptimizationsIgnored': false,
        'backgroundRestricted': true,
        'powerSaveMode': false,
      };
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(runtime.reads, 2);
      expect(find.text('已就绪 · 暂无任务'), findsOneWidget);
      expect(find.text('仍受 Android 标准电池优化管理'), findsOneWidget);
      expect(find.text('Android 已报告后台限制'), findsOneWidget);
      expect(runtime.writes, 0);
      policy.openFailure = null;
      await tap(tester, find.text('打开系统应用设置'));
      expect(find.textContaining('无法打开系统应用设置'), findsNothing);
      expect(find.text('厂商后台许可需要手动确认'), findsOneWidget);
      expect(runtime.writes, 0);
      await close(tester);
      final reads = runtime.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(runtime.reads, reads);
    },
  );
}
