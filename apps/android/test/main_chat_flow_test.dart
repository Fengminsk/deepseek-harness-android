import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tasks.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;

class _ChatRuntime extends RuntimeController {
  _ChatRuntime(this.history) {
    phase = 'ready';
    sessions = [
      {
        'header': {'id': 'history', 'title': '历史会话'},
      },
    ];
  }
  final List<Json> history;
  final calls = <({String method, Json params})>[];
  int draft = 0;

  @override
  String newSession() {
    final id = 'draft-${draft++}';
    timelines[id] = [];
    return id;
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    switch (method) {
      case 'session.read':
        if (params['sessionId'] != 'history') {
          throw StateError('Unexpected session read');
        }
        return {
          'events': history
              .where((row) => (row['seq'] as int) >= (params['offset'] as int))
              .take(200)
              .toList(),
        };
      case 'tasks.list':
        return {
          'epoch': 'fixture-epoch',
          'revision': 1,
          'summary': {'running': 0, 'waiting': 0, 'backgroundJobs': 0},
          'active': <Json>[],
          'sessions': <Json>[],
          'nextOffset': null,
        };
      case 'interactions.list':
        return {'revision': 1, 'requests': <Json>[]};
    }
    throw StateError('Unexpected $method');
  }

  void append(Json event) {
    timelines['history']!.add(event);
    notifyListeners();
  }

  void live({required int revision}) {
    liveMessages['history'] = {
      'attemptId': 'fixture-attempt',
      'revision': revision,
      'turn': 2,
      'step': 1,
      'content': [
        {'type': 'text', 'text': 'Live delta $revision'},
      ],
      'interrupted': false,
    };
    notifyListeners();
  }

  void routeTasks() {
    navigationRequest = {'route': 'tasks'};
    notifyListeners();
  }
}

Widget _host(_ChatRuntime runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (_, child) => MediaQuery(
    data: const MediaQueryData(size: Size(390, 844), disableAnimations: true),
    child: child!,
  ),
  home: ChatPage(runtime: runtime),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openHistory(WidgetTester tester) async {
  await tester.tap(find.byTooltip('打开侧栏'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('历史会话'));
  await tester.tap(find.text('历史会话'));
  await tester.pumpAndSettle();
}

ScrollController _scroll(WidgetTester tester) =>
    tester.widget<ChatTimeline>(find.byType(ChatTimeline)).controller;

void main() {
  testWidgets(
    'opening variable-height long history reaches the actual last reply',
    (tester) async {
      _phone(tester);
      final history = <Json>[
        ...List.generate(
          300,
          (index) => fixture.assistant(
            index,
            index < 270
                ? 'Reply $index'
                : 'Reply $index\n\n${'A longer paragraph in the final portion of the saved conversation.\n\n' * 8}',
            step: index + 1,
          ),
        ),
        fixture.assistant(300, 'LAST_SAVED_REPLY', step: 301),
      ];
      final runtime = _ChatRuntime(history);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      expect(
        runtime.calls.where((call) => call.method == 'session.read'),
        hasLength(2),
      );
      expect(
        _scroll(tester).position.extentAfter,
        lessThan(2),
        reason:
            'One jump to an estimated ListView extent is not the true tail.',
      );
      expect(find.text('LAST_SAVED_REPLY', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reading older messages is not displaced by live deltas or appended replies',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime(
        List.generate(
          80,
          (index) =>
              fixture.assistant(index, 'Saved reply $index', step: index + 1),
        ),
      );
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      final scroll = _scroll(tester);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final position = scroll.offset;
      runtime.live(revision: 1);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(position, .01));
      runtime.live(revision: 2);
      runtime.append(fixture.assistant(80, 'New settled reply', turn: 2));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(position, .01));
      expect(find.text('Saved reply 0', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'loaded session title updates its sidebar entry without a second history read',
    (tester) async {
      _phone(tester);
      final runtime = _ChatRuntime([fixture.input(0, 'Question')]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await _openHistory(tester);
      runtime.append(fixture.event(1, 'session/title', {'title': '可读的新标题'}));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开侧栏'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('可读的新标题'));
      expect(find.text('可读的新标题'), findsOneWidget);
      expect(find.text('历史会话'), findsNothing);
      expect(
        runtime.calls.where((call) => call.method == 'session.read'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final ready in [true, false]) {
    testWidgets(
      'tasks notification opens native task page and preserves draft when ready=$ready',
      (tester) async {
        _phone(tester);
        final runtime = _ChatRuntime([]);
        if (!ready) runtime.phase = 'failed';
        addTearDown(runtime.dispose);
        await tester.pumpWidget(_host(runtime));
        await tester.enterText(find.byType(TextField), '保留的聊天草稿');
        runtime.routeTasks();
        await tester.pumpAndSettle();
        expect(find.byType(TasksPage), findsOneWidget);
        expect(runtime.navigationRequest, isNull);
        if (ready) {
          expect(find.text('当前没有运行中的任务'), findsOneWidget);
        } else {
          expect(find.text('任务状态暂不可用'), findsOneWidget);
          expect(runtime.calls, isEmpty);
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(TasksPage), findsNothing);
        expect(find.text('保留的聊天草稿'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
