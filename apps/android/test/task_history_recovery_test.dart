import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tasks.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  final requests = <({String method, Json params})>[];
  Future<dynamic> Function(String, Json)? handler;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshTasks() async {}
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    requests.add((method: method, params: params));
    if (handler != null) return handler!(method, params);
    if (method == 'tasks.session') return _snapshot('A');
    throw StateError('Unexpected $method');
  }
}

Json _snapshot(String process) => {
  'epoch': process,
  'observation': 'live',
  'historyAvailable': true,
  'pending': [
    {
      'itemId': 'queue-1',
      'status': 'queued',
      'prompt': '$process 的输入',
      'cancellable': true,
    },
  ],
  'history': <Json>[],
  'nextBeforeSeq': 9,
};

void _status(MockStreamHandlerEventSink sink, String generation) =>
    sink.success(
      jsonEncode({
        'method': 'runtime.status',
        'params': {'phase': 'ready', 'generation': generation},
      }),
    );

Future<MockStreamHandlerEventSink> _start(
  WidgetTester tester,
  RuntimeController runtime, {
  bool list = false,
}) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final listening = Completer<MockStreamHandlerEventSink>();
  messenger.setMockStreamHandler(
    RuntimeController.events,
    MockStreamHandler.inline(onListen: (_, sink) => listening.complete(sink)),
  );
  messenger.setMockMethodCallHandler(
    RuntimeController.channel,
    (_) async => null,
  );
  addTearDown(() {
    runtime.dispose();
    messenger.setMockMethodCallHandler(RuntimeController.channel, null);
    messenger.setMockStreamHandler(RuntimeController.events, null);
  });
  await runtime.start();
  final sink = await listening.future;
  _status(sink, 'A');
  await tester.pump();
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: list
          ? TasksPage(runtime: runtime)
          : TaskHistoryPage(runtime: runtime, sessionId: 's', title: '会话'),
    ),
  );
  await tester.pumpAndSettle();
  return sink;
}

class _ListRuntime extends RuntimeController {
  final requests = <String>[];
  Future<dynamic> Function(String)? handler;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshInteractions() async {}
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    requests.add(method);
    if (handler != null) return handler!(method);
    if (method == 'tasks.list') return _listSnapshot('A');
    throw StateError('Unexpected $method');
  }
}

Json _listSnapshot(String process) => {
  'epoch': process,
  'revision': 1,
  'summary': {'backgroundJobs': 0, 'packageOperations': 0},
  'active': [
    {'sessionId': 's', 'status': 'running', 'queued': 1},
  ],
  'sessions': [
    {
      'sessionId': 's',
      'title': '$process 的会话',
      'historyAvailable': true,
      'history': <Json>[],
      'observation': 'live',
    },
  ],
  'nextOffset': 20,
};

void main() {
  testWidgets(
    'task list withdraws old status while replacement refresh bypasses pending old read',
    (tester) async {
      final runtime = _ListRuntime();
      final sink = await _start(tester, runtime, list: true);
      final old = Completer<Json>(), fresh = Completer<Json>();
      var reads = 0;
      runtime.handler = (method) {
        expectSync(method, 'tasks.list');
        return ++reads == 1 ? old.future : fresh.future;
      };
      await tester.tap(
        find.byWidgetPredicate((w) => w is GlassButton && w.label == '刷新任务状态'),
      );
      await tester.pump();
      expect(find.text('任务状态暂不可用'), findsNothing);
      expect(find.text('状态待确认 · 保留上次读取的记录'), findsNothing);
      _status(sink, 'B');
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('A 的会话'), findsOneWidget);
      expect(find.text('状态待确认 · 保留上次读取的记录'), findsOneWidget);
      expect(
        tester
            .widget<PocketButton>(find.widgetWithText(PocketButton, '更多会话'))
            .onPressed,
        isNull,
      );
      fresh.complete(_listSnapshot('B'));
      await tester.pumpAndSettle();
      old.completeError(StateError('A obsolete failure'));
      await tester.pumpAndSettle();
      expect(find.text('B 的会话'), findsWidgets);
      expect(find.textContaining('A obsolete failure'), findsNothing);
      expect(find.text('状态待确认 · 保留上次读取的记录'), findsNothing);
      expect(runtime.requests.where((r) => r == 'tasks.cancel'), isEmpty);
    },
  );

  testWidgets(
    'late stop failure cannot unlock a replacement stop for the same session',
    (tester) async {
      final runtime = _ListRuntime();
      final sink = await _start(tester, runtime, list: true);
      final old = Completer<Json>(), fresh = Completer<Json>();
      var stops = 0;
      runtime.handler = (method) async {
        if (method == 'tasks.list') return _listSnapshot('B');
        expectSync(method, 'tasks.cancel');
        return ++stops == 1 ? old.future : fresh.future;
      };
      await tester.tap(find.text('停止任务'));
      await tester.pumpAndSettle();
      _status(sink, 'B');
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止任务'));
      await tester.pumpAndSettle();
      expect(stops, 2);
      old.completeError(StateError('A obsolete stop'));
      await tester.pumpAndSettle();
      expect(find.text('正在停止'), findsOneWidget);
      expect(
        tester
            .widget<PocketButton>(find.widgetWithText(PocketButton, '停止任务'))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('A obsolete stop'), findsNothing);
      await tester.tap(find.text('停止任务'));
      expect(stops, 2);
      fresh.complete({'cancelled': true});
      await tester.pumpAndSettle();
    },
  );

  for (final oldFails in [false, true]) {
    testWidgets(
      'replacement reads queue without waiting for stale ${oldFails ? 'failure' : 'result'}',
      (tester) async {
        final runtime = _Runtime();
        final sink = await _start(tester, runtime);
        final old = Completer<Json>(), fresh = Completer<Json>();
        var reads = 0;
        runtime.handler = (method, _) {
          expectSync(method, 'tasks.session');
          return ++reads == 1 ? old.future : fresh.future;
        };
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is GlassButton && w.label == '刷新任务记录',
          ),
        );
        await tester.pump();
        expect(find.textContaining('任务记录待核实'), findsNothing);
        _status(sink, 'B');
        await tester.pumpAndSettle();
        expect(runtime.nativeGeneration, 'B');
        expect(reads, 2);
        expect(find.text('A 的输入'), findsOneWidget);
        expect(find.textContaining('任务记录待核实'), findsOneWidget);
        expect(
          tester
              .widget<PocketButton>(
                find.widgetWithText(PocketButton, '移除待处理输入'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<PocketButton>(find.widgetWithText(PocketButton, '更早的回合'))
              .onPressed,
          isNull,
        );
        fresh.complete(_snapshot('B'));
        await tester.pumpAndSettle();
        if (oldFails) {
          old.completeError(StateError('A stale read'));
        } else {
          old.complete(_snapshot('A'));
        }
        await tester.pumpAndSettle();
        expect(find.text('B 的输入'), findsOneWidget);
        expect(find.text('A 的输入'), findsNothing);
        expect(find.textContaining('A stale read'), findsNothing);
        expect(find.textContaining('任务记录待核实'), findsNothing);
        expect(
          runtime.requests.where((r) => r.method == 'tasks.removeQueued'),
          isEmpty,
        );
      },
    );
  }

  testWidgets(
    'failed replacement baseline retains queue as unconfirmed and revokes old confirmation',
    (tester) async {
      final runtime = _Runtime();
      final sink = await _start(tester, runtime);
      await tester.tap(find.text('移除待处理输入'));
      await tester.pumpAndSettle();
      expect(find.text('确认移除'), findsOneWidget);
      runtime.handler = (_, _) async => throw StateError('B unavailable');
      _status(sink, 'B');
      await tester.pumpAndSettle();
      expect(find.text('确认移除'), findsNothing);
      expect(find.text('A 的输入'), findsOneWidget);
      expect(find.textContaining('任务记录待核实'), findsOneWidget);
      expect(find.textContaining('B unavailable'), findsOneWidget);
      expect(
        tester
            .widget<PocketButton>(find.widgetWithText(PocketButton, '移除待处理输入'))
            .onPressed,
        isNull,
      );
      expect(
        runtime.requests.where((r) => r.method == 'tasks.removeQueued'),
        isEmpty,
      );
    },
  );

  for (final oldFails in [false, true]) {
    testWidgets(
      'late removal ${oldFails ? 'error' : 'receipt'} cannot dismiss replacement confirmation',
      (tester) async {
        final runtime = _Runtime();
        final sink = await _start(tester, runtime);
        final removal = Completer<Json>();
        runtime.handler = (method, _) async {
          if (method == 'tasks.removeQueued') return removal.future;
          return _snapshot('B');
        };
        await tester.tap(find.text('移除待处理输入'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认移除'));
        await tester.pump();
        _status(sink, 'B');
        await tester.pumpAndSettle();
        expect(find.text('B 的输入'), findsOneWidget);
        expect(find.text('确认移除'), findsNothing);
        await tester.tap(find.text('移除待处理输入'));
        await tester.pumpAndSettle();
        expect(find.text('确认移除'), findsOneWidget);
        final reads = runtime.requests
            .where((r) => r.method == 'tasks.session')
            .length;
        if (oldFails) {
          removal.completeError(StateError('A late remove'));
        } else {
          removal.complete({'accepted': true});
        }
        await tester.pumpAndSettle();
        expect(find.text('确认移除'), findsOneWidget);
        expect(find.textContaining('A late remove'), findsNothing);
        expect(
          runtime.requests.where((r) => r.method == 'tasks.session'),
          hasLength(reads),
        );
        expect(
          runtime.requests.where((r) => r.method == 'tasks.removeQueued'),
          hasLength(1),
        );
      },
    );
  }
}
