import 'package:dsh_android/automations.dart';
import 'package:dsh_android/automations_data.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'automations_fixture.dart';

Widget host(Widget child) =>
    MaterialApp(theme: pocketTheme(Brightness.light), home: child);

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<String> fieldText(WidgetTester tester, String name) async {
  final finder = find.byKey(ValueKey('automation-$name'));
  if (finder.evaluate().isEmpty) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1600));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }
  return tester.widget<TextField>(finder).controller!.text;
}

void main() {
  testWidgets('session link uses SessionListEntry header identity', (
    tester,
  ) async {
    final runtime = AutomationRuntime();
    final catalog = AutomationsController(runtime);
    await catalog.refresh();
    addTearDown(() {
      catalog.dispose();
      runtime.dispose();
    });
    final opened = <String>[];
    await tester.pumpWidget(
      host(
        AutomationDetailPage(
          catalog: catalog,
          record: taskFixture(),
          onOpenSession: opened.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('原会话'));
    expect(opened, ['conversation-a']);
    runtime.sessions = [
      {
        'header': {'id': 'another-conversation'},
      },
    ];
    await catalog.refresh();
    await tester.pumpAndSettle();
    final row = tester.widget<PocketRow>(find.widgetWithText(PocketRow, '原会话'));
    expect(row.onTap, isNull);
    expect(find.textContaining('原会话当前不可用'), findsOneWidget);
  });

  testWidgets(
    'catalog uses real filters and creation only opens a conversation',
    (tester) async {
      final runtime = AutomationRuntime()
        ..tasks = [
          taskFixture(),
          taskFixture(id: 'done', title: '已完成提醒', status: 'inactive'),
        ];
      addTearDown(runtime.dispose);
      var creations = 0;
      await tester.pumpWidget(
        host(
          AutomationsPage(
            runtime: runtime,
            onNewTask: () => creations++,
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('整理进度'), findsOneWidget);
      expect(find.text('已完成提醒'), findsOneWidget);
      await tapVisible(tester, find.text('新建任务对话'));
      expect(creations, 1);
      expect(runtime.requests.map((item) => item.method), ['catalog']);
      await tapVisible(tester, find.widgetWithText(PocketChoice, '已结束'));
      expect(find.text('整理进度'), findsNothing);
      expect(find.text('已完成提醒'), findsOneWidget);
      expect(find.text('暂停'), findsNothing);
      expect(find.text('立即运行'), findsNothing);
    },
  );

  testWidgets(
    'conflict keeps inputs and explicit rebase adopts untouched remote fields',
    (tester) async {
      final runtime = AutomationRuntime();
      final catalog = AutomationsController(runtime);
      await catalog.refresh();
      addTearDown(() {
        catalog.dispose();
        runtime.dispose();
      });
      runtime.handler = (method, _) async {
        if (method == 'update') {
          return {
            'id': 'task-a',
            'updated': false,
            'code': 'schedule_conflict',
          };
        }
        if (method == 'catalog') {
          return [
            {
              ...taskFixture(title: 'Web 名称'),
              'prompt': 'Web 指令',
              'everySeconds': 7200,
            },
          ];
        }
        throw StateError(method);
      };
      await tester.pumpWidget(
        host(
          AutomationDetailPage(
            catalog: catalog,
            record: taskFixture(),
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('automation-title')),
        '我的名称',
      );
      await tapVisible(tester, find.text('保存任务'));
      expect(find.textContaining('任务已被修改'), findsOneWidget);
      expect(await fieldText(tester, 'title'), '我的名称');
      expect(await fieldText(tester, 'prompt'), '检查任务进度并总结。');
      final update = runtime.requests.firstWhere(
        (item) => item.method == 'update',
      );
      expect(update.args['request']['expected']['title'], '整理进度');
      expect(update.args['request'].containsKey('change'), isFalse);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 1600));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('保留草稿，采用当前比较记录'));
      expect(await fieldText(tester, 'title'), '我的名称');
      expect(await fieldText(tester, 'prompt'), 'Web 指令');
      expect(await fieldText(tester, 'seconds'), '7200');
    },
  );

  testWidgets(
    'lost save acknowledgement keeps draft and requires explicit discard on back',
    (tester) async {
      final runtime = AutomationRuntime();
      final catalog = AutomationsController(runtime);
      await catalog.refresh();
      addTearDown(() {
        catalog.dispose();
        runtime.dispose();
      });
      runtime.handler = (_, _) => throw StateError('connection lost');
      await tester.pumpWidget(host(const SizedBox()));
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            PocketRoute<void>(
              builder: (_) => AutomationDetailPage(
                catalog: catalog,
                record: taskFixture(),
                onOpenSession: (_) {},
              ),
            ),
          );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('automation-title')),
        '保留此草稿',
      );
      await tapVisible(tester, find.text('保存任务'));
      expect(find.textContaining('未能确认保存结果'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('automation-title')))
            .controller!
            .text,
        '保留此草稿',
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '返回',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('离开当前编辑？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('automation-title')))
            .controller!
            .text,
        '保留此草稿',
      );
      expect(
        runtime.requests.where((item) => item.method == 'update'),
        hasLength(1),
      );
    },
  );

  testWidgets('deletion requires confirmation and original session binding', (
    tester,
  ) async {
    final runtime = AutomationRuntime();
    final catalog = AutomationsController(runtime);
    await catalog.refresh();
    addTearDown(() {
      catalog.dispose();
      runtime.dispose();
    });
    runtime.handler = (method, _) async {
      if (method == 'delete') return {'id': 'task-a', 'deleted': true};
      if (method == 'catalog') return [];
      throw StateError(method);
    };
    await tester.pumpWidget(
      host(
        AutomationDetailPage(
          catalog: catalog,
          record: taskFixture(),
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(PocketButton, '删除任务'));
    expect(runtime.requests.where((item) => item.method == 'delete'), isEmpty);
    await tapVisible(tester, find.text('保留任务'));
    expect(runtime.requests.where((item) => item.method == 'delete'), isEmpty);
    await tapVisible(tester, find.widgetWithText(PocketButton, '删除任务'));
    await tapVisible(tester, find.text('确认删除任务'));
    final request = runtime.requests.singleWhere(
      (item) => item.method == 'delete',
    );
    expect(request.args, {
      'request': {'id': 'task-a', 'sessionId': 'conversation-a'},
    });
    expect(find.text('任务已删除。'), findsOneWidget);
    expect(find.text('确认删除任务'), findsNothing);
  });

  testWidgets(
    'inactive tasks are read-only and history is labeled as delivery',
    (tester) async {
      final runtime = AutomationRuntime()
        ..tasks = [taskFixture(status: 'inactive')];
      final catalog = AutomationsController(runtime);
      await catalog.refresh();
      addTearDown(() {
        catalog.dispose();
        runtime.dispose();
      });
      runtime.handler = (method, _) async => {
        'records': [
          {
            'messageId': 'receipt',
            'scheduledAt': '2030-01-01T10:00:00.000Z',
            'deliveredAt': '2030-01-01T10:00:01.000Z',
            'prompt': '当时发送的指令',
          },
        ],
        'earlierRecordsPruned': true,
        'earlierRecordsUnavailable': true,
        'retention': {'days': 30, 'records': 200},
      };
      await tester.pumpWidget(
        host(
          AutomationDetailPage(
            catalog: catalog,
            record: taskFixture(status: 'inactive'),
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('automation-title')))
            .enabled,
        isFalse,
      );
      await tapVisible(tester, find.text('投递记录'));
      expect(find.textContaining('不是模型执行结果'), findsOneWidget);
      expect(find.text('当时发送的指令'), findsOneWidget);
      expect(find.textContaining('30 天、最多 200 条'), findsOneWidget);
    },
  );

  testWidgets('acknowledged save survives failed catalog readback', (
    tester,
  ) async {
    final runtime = AutomationRuntime();
    final catalog = AutomationsController(runtime);
    await catalog.refresh();
    addTearDown(() {
      catalog.dispose();
      runtime.dispose();
    });
    runtime.handler = (method, args) async {
      if (method == 'update') {
        return {
          'id': 'task-a',
          'updated': true,
          'record': <String, dynamic>{
            ...args['request']['expected'],
            'title': args['request']['title'],
          },
        };
      }
      throw StateError('Readback disconnected');
    };
    await tester.pumpWidget(
      host(
        AutomationDetailPage(
          catalog: catalog,
          record: taskFixture(),
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('automation-title')),
      '已确认保存的名称',
    );
    await tapVisible(tester, find.text('保存任务'));
    expect(find.text('已保存任务。'), findsOneWidget);
    expect(find.textContaining('无法读取任务列表'), findsOneWidget);
    expect(await fieldText(tester, 'title'), '已确认保存的名称');
    expect(
      runtime.requests.where((item) => item.method == 'update'),
      hasLength(1),
    );
  });
}
