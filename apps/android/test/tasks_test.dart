import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tasks.dart';
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
      'summary': {'backgroundJobs': 0},
    };
    notifyListeners();
  }
}

Widget _host(RuntimeController runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: TasksPage(runtime: runtime),
);

void main() {
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
