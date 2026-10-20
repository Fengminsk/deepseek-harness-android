import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tasks.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _HistoryRuntime extends RuntimeController {
  _HistoryRuntime() {
    phase = 'ready';
    taskState = {'epoch': 'fixture', 'revision': 1};
  }
  final calls = <String>[];
  bool pending = true;
  bool failRemoval = false;

  @override
  Future<void> refreshTasks() async {}

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add(method);
    if (method == 'tasks.removeQueued') {
      if (failRemoval) throw StateError('reply lost');
      pending = false;
      return {'accepted': true};
    }
    if (method != 'tasks.session') throw StateError('Unexpected $method');
    return {
      'epoch': 'fixture',
      'historyAvailable': true,
      'observation': 'live',
      'pending': [
        if (pending)
          {
            'itemId': 'q1',
            'status': 'queued',
            'prompt': '保留的输入',
            'cancellable': true,
          },
      ],
      'history': [
        {
          'kind': 'turn',
          'turn': 2,
          'status': 'failed',
          'time': 1,
          'reason': {
            'kind': 'error',
            'error': {'code': 'PROVIDER_FAILED', 'message': 'fixture failure'},
          },
        },
        {'kind': 'job', 'label': '旧后台命令', 'status': 'unconfirmed', 'time': 1},
      ],
    };
  }
}

Widget _host(_HistoryRuntime runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: TaskHistoryPage(runtime: runtime, sessionId: 'fixture', title: '测试会话'),
);

void main() {
  testWidgets(
    'history exposes original failures and unconfirmed jobs without replaying requests',
    (tester) async {
      final runtime = _HistoryRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      expect(find.text('PROVIDER_FAILED fixture failure'), findsOneWidget);
      expect(find.text('旧后台命令 · 执行结果未确认'), findsOneWidget);
      expect(find.text('保留的输入'), findsOneWidget);
      expect(runtime.calls, ['tasks.session']);
    },
  );

  testWidgets(
    'removing a queued input requires confirmation and leaves the queue visible on failed acknowledgement',
    (tester) async {
      final runtime = _HistoryRuntime()..failRemoval = true;
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除待处理输入'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls.where((method) => method == 'tasks.removeQueued'),
        isEmpty,
      );
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('移除请求未确认'), findsOneWidget);
      expect(find.text('保留的输入'), findsOneWidget);
      expect(
        runtime.calls.where((method) => method == 'tasks.removeQueued'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'a new task revision refreshes queue history and disposal detaches observation',
    (tester) async {
      final runtime = _HistoryRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      runtime.pending = false;
      runtime.taskState = {'epoch': 'fixture', 'revision': 2};
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('保留的输入'), findsNothing);
      expect(
        runtime.calls.where((method) => method == 'tasks.session'),
        hasLength(2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.taskState = {'epoch': 'fixture', 'revision': 3};
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        runtime.calls.where((method) => method == 'tasks.session'),
        hasLength(2),
      );
    },
  );
}
