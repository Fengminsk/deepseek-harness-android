import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tasks.dart';
import 'package:dsh_android/subagents.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _TasksRuntime extends RuntimeController {
  _TasksRuntime() {
    phase = 'ready';
    statuses['task-a'] = 'running';
    taskState = {
      'epoch': 'fixture',
      'revision': 1,
      'active': [
        {
          'sessionId': 'task-a',
          'status': 'running',
          'queued': 1,
          'blockingRequests': 0,
        },
      ],
    };
    taskSessions = [
      {
        'sessionId': 'task-a',
        'title': '整理文件',
        'historyAvailable': true,
        'history': [],
        'pending': [],
      },
    ];
    sessions = [
      {
        'header': {'id': 'task-a', 'title': '整理文件'},
      },
    ];
  }
  int stops = 0;
  bool rejectStop = false;
  Completer<void>? stopResponse;
  Json? inspectedChild;

  @override
  Future<void> refreshLive() async {}
  @override
  Future<void> refreshSessions() async {}
  @override
  Future<void> refreshInteractions() async {}
  @override
  Future<void> refreshTasks() async {}
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'subagents.inspect') {
      inspectedChild = params['address'] as Json;
      throw StateError('Read unavailable in this navigation fixture');
    }
    if (method != 'tasks.cancel' || params['sessionId'] != 'task-a') {
      throw StateError('Unexpected call');
    }
    stops++;
    if (rejectStop) throw StateError('服务连接中断');
    await stopResponse?.future;
    return {'cancelled': true};
  }

  void finishTask() {
    statuses['task-a'] = 'idle';
    taskState = {
      'epoch': 'fixture',
      'revision': 2,
      'active': <Json>[],
      'summary': {'backgroundJobs': 0, 'packageOperations': 0},
    };
    notifyListeners();
  }
}

Widget _host(RuntimeController runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: TasksPage(runtime: runtime),
);

void main() {
  testWidgets('task page reads last interruption without replaying task work', (
    tester,
  ) async {
    final runtime = _TasksRuntime();
    addTearDown(runtime.dispose);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    String? record = jsonEncode({
      'kind': 'runtime-lost',
      'timeMillis': 1782000000000,
    });
    messenger.setMockMethodCallHandler(RuntimeController.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'background.lastInterruption') return record;
      throw StateError('Unexpected native call ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
    );
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    expect(find.text('上次本地运行时异常退出'), findsOneWidget);
    expect(find.textContaining('任务结果需在原会话核对；不会自动重试'), findsOneWidget);
    expect(calls, everyElement('background.lastInterruption'));
    expect(runtime.stops, 0);

    record = jsonEncode({'kind': 'raw-secret', 'timeMillis': 1782000000000});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('上次本地运行时异常退出'), findsNothing);
    expect(find.text('后台中断记录暂不可用'), findsOneWidget);
    expect(runtime.stops, 0);
  });

  for (final count in <int?>[2, null]) {
    testWidgets('idle Agent does not imply plugin operations idle: $count', (
      tester,
    ) async {
      final runtime = _TasksRuntime()
        ..taskState = {
          'epoch': 'fixture',
          'revision': 2,
          'active': <Json>[],
          'summary': {'backgroundJobs': 0, 'packageOperations': count},
        };
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      expect(find.text('当前没有运行中的任务'), findsNothing);
      expect(find.text('Agent 暂无运行任务'), findsOneWidget);
      expect(
        find.text(count == null ? '插件管理操作状态尚未确认，请刷新后查看。' : '2 项进行中'),
        findsOneWidget,
      );
      runtime.phase = 'failed';
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('2 项进行中'), findsNothing);
      expect(find.text('任务状态暂不可用'), findsOneWidget);
      expect(runtime.stops, 0);
    });
  }

  testWidgets('cold child without its parent address reports a visible error', (
    tester,
  ) async {
    final runtime = _TasksRuntime()
      ..taskState = {
        'epoch': 'fixture',
        'revision': 2,
        'active': <Json>[],
        'summary': {'backgroundJobs': 0},
      };
    runtime.taskSessions.first['subagent'] = null;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.tap(find.text('整理文件'));
    await tester.pumpAndSettle();
    expect(find.text('子 Agent 的父级地址不可用，请从父会话查看。'), findsOneWidget);
    expect(find.byType(TasksPage), findsOneWidget);
    expect(find.byType(TaskHistoryPage), findsNothing);
    expect(runtime.inspectedChild, isNull);
    expect(runtime.stops, 0);
  });

  testWidgets('child tasks open addressed history without generic cancel', (
    tester,
  ) async {
    final runtime = _TasksRuntime();
    const address = {
      'parentSessionId': 'parent',
      'childSessionId': 'task-a',
      'mode': 'unknown',
    };
    (runtime.taskState['active'] as List).first['subagent'] = address;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    expect(find.text('停止任务'), findsNothing);
    await tester.tap(find.text('查看子 Agent'));
    await tester.pumpAndSettle();
    expect(find.byType(SubagentConversationPage), findsOneWidget);
    expect(runtime.inspectedChild, address);
    expect(runtime.stops, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final count in <int?>[2, null]) {
    testWidgets('Agent idle does not imply background jobs idle: $count', (
      tester,
    ) async {
      final runtime = _TasksRuntime()
        ..taskState = {
          'epoch': 'fixture',
          'revision': 2,
          'active': <Json>[],
          'summary': {'backgroundJobs': count},
        };
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      expect(find.text('当前没有运行中的任务'), findsNothing);
      expect(
        find.text(count == null ? '后台作业状态尚未确认，请刷新后查看。' : '2 个后台作业仍在执行'),
        findsOneWidget,
      );
    });
  }
  testWidgets('stop remains pending until shared Agent state finishes', (
    tester,
  ) async {
    final runtime = _TasksRuntime()..stopResponse = Completer<void>();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止任务'));
    await tester.pumpAndSettle();
    expect(find.text('正在停止'), findsOneWidget);
    await tester.tap(find.text('停止任务'));
    expect(runtime.stops, 1);
    runtime.stopResponse!.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在停止'), findsOneWidget);
    runtime.finishTask();
    await tester.pumpAndSettle();
    expect(find.text('当前没有运行中的任务'), findsOneWidget);
  });

  testWidgets('a failed stop stays visible and can be retried', (tester) async {
    final runtime = _TasksRuntime()..rejectStop = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止任务'));
    await tester.pumpAndSettle();
    expect(find.textContaining('停止请求未确认'), findsOneWidget);
    expect(find.text('整理文件'), findsWidgets);
    runtime.rejectStop = false;
    await tester.tap(find.text('停止任务'));
    await tester.pumpAndSettle();
    expect(runtime.stops, 2);
    expect(find.textContaining('停止请求未确认'), findsNothing);
  });

  testWidgets('a lost service shows stale status without allowing a stop', (
    tester,
  ) async {
    final runtime = _TasksRuntime()..phase = 'failed';
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    expect(find.text('任务状态暂不可用'), findsOneWidget);
    await tester.tap(find.text('停止任务'));
    expect(runtime.stops, 0);
  });
}
