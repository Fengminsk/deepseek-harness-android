import 'dart:async';

import 'package:dsh_android/automations.dart';
import 'package:dsh_android/automations_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'automations_connection_fixture.dart';
import 'automations_fixture.dart';
import 'automations_test.dart' show fieldText, tapVisible;

void main() {
  testWidgets(
    'same connection catalog refresh retains confirmed list without an unconfirmed banner',
    (tester) async {
      final runtime = AutomationConnectionRuntime();
      final sink = await attachAutomationConnection(runtime);
      automationConnection(sink, 'A');
      await tester.pump();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AutomationsPage(
            runtime: runtime,
            onNewTask: () {},
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final refresh = Completer<List<Json>>();
      runtime.handler = (_, _) => refresh.future;
      await tester.tap(
        find.byWidgetPredicate((w) => w is GlassButton && w.label == '刷新任务列表'),
      );
      await tester.pumpAndSettle();
      expect(find.text('整理进度'), findsOneWidget);
      expect(find.textContaining('任务列表待核实'), findsNothing);
      refresh.complete([taskFixture()]);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('same connection delivery refresh keeps its confirmed rows', (
    tester,
  ) async {
    final runtime = AutomationConnectionRuntime();
    final sink = await attachAutomationConnection(runtime);
    automationConnection(sink, 'A');
    await tester.pump();
    final catalog = AutomationsController(runtime)..start();
    addTearDown(() {
      catalog.dispose();
      runtime.dispose();
    });
    await tester.pump();
    final baseline = {
      'records': [
        {
          'messageId': 'm',
          'scheduledAt': '2030-01-01',
          'deliveredAt': '2030-01-01',
          'prompt': '保留的投递',
        },
      ],
    };
    runtime.handler = (_, _) async => baseline;
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: AutomationHistoryPage(catalog: catalog, record: taskFixture()),
      ),
    );
    await tester.pumpAndSettle();
    final refresh = Completer<Json>();
    runtime.handler = (_, _) => refresh.future;
    await tester.tap(
      find.byWidgetPredicate((w) => w is GlassButton && w.label == '刷新投递记录'),
    );
    await tester.pumpAndSettle();
    expect(find.text('保留的投递'), findsOneWidget);
    expect(find.textContaining('投递记录待核实'), findsNothing);
    refresh.complete(baseline);
    await tester.pumpAndSettle();
  });

  for (final oldFails in [false, true]) {
    testWidgets(
      'ready replacement rejects stale catalog ${oldFails ? 'error' : 'result'} and disables writes until fresh',
      (tester) async {
        final runtime = AutomationConnectionRuntime();
        final sink = await attachAutomationConnection(runtime);
        automationConnection(sink, 'A');
        await tester.pump();
        expect(runtime.nativeGeneration, 'A');
        final catalog = AutomationsController(runtime)..start();
        addTearDown(() {
          catalog.dispose();
          runtime.dispose();
        });
        await tester.pump();
        expect(catalog.current, isTrue);
        final old = Completer<List<Json>>(), fresh = Completer<List<Json>>();
        var reads = 0;
        runtime.handler = (method, _) {
          expectSync(method, 'catalog');
          return ++reads == 1 ? old.future : fresh.future;
        };
        final pending = catalog.refresh();
        final generation = runtime.connectionGeneration;
        automationConnection(sink, 'B');
        await tester.pump();
        expect(runtime.nativeGeneration, 'B');
        expect(runtime.ready, isTrue);
        expect(runtime.connectionGeneration, greaterThan(generation));
        expect(reads, 2);
        expect(catalog.current, isFalse);
        expect(catalog.settled, isFalse);
        expect(catalog.records.single['title'], '整理进度');
        await expectLater(
          catalog.update(AutomationDraft(taskFixture()).request()),
          throwsA(isA<AutomationCatalogUnconfirmed>()),
        );
        await expectLater(
          catalog.delete(taskFixture()),
          throwsA(isA<AutomationCatalogUnconfirmed>()),
        );
        fresh.complete([taskFixture(title: 'B 当前记录')]);
        await tester.pump();
        expect(catalog.current, isTrue);
        if (oldFails) {
          old.completeError(StateError('A stale failure'));
        } else {
          old.complete([taskFixture(title: 'A 旧记录')]);
        }
        await pending;
        expect(catalog.current, isTrue);
        expect(catalog.error, isNull);
        expect(catalog.records.single['title'], 'B 当前记录');
        expect(runtime.requests.where((r) => r.method != 'catalog'), isEmpty);
      },
    );
  }

  testWidgets(
    'same receipt on ready replacement replaces history and rejects old pagination',
    (tester) async {
      final runtime = AutomationConnectionRuntime();
      final sink = await attachAutomationConnection(runtime);
      automationConnection(sink, 'A');
      await tester.pump();
      final old = Completer<Json>(), fresh = Completer<Json>();
      var reads = 0;
      runtime.handler = (method, args) async {
        if (method == 'catalog') return runtime.tasks;
        expectSync(method, 'history');
        reads++;
        if (reads == 1) {
          return {
            'records': [
              {'messageId': 'a'},
            ],
            'nextBefore': 'a',
          };
        }
        if (reads == 2) {
          expectSync(args['request']['before'], 'a');
          return old.future;
        }
        expectSync(args['request'].containsKey('before'), isFalse);
        return fresh.future;
      };
      final catalog = AutomationsController(runtime)..start();
      await tester.pump();
      final history = AutomationHistory(catalog, taskFixture())..start();
      addTearDown(() {
        history.dispose();
        catalog.dispose();
        runtime.dispose();
      });
      await tester.pump();
      expect(history.current, isTrue);
      final pending = history.load(before: 'a');
      automationConnection(sink, 'B');
      await tester.pump();
      expect(reads, 3);
      expect(history.current, isFalse);
      expect(history.records.single['messageId'], 'a');
      await history.load(before: 'a');
      expect(reads, 3);
      fresh.complete({
        'records': [
          {'messageId': 'b'},
        ],
        'nextBefore': 'b',
      });
      await tester.pump();
      old.complete({
        'records': [
          {'messageId': 'old-a'},
        ],
        'nextBefore': 'old-a',
      });
      await pending;
      expect(history.current, isTrue);
      expect(history.records.single['messageId'], 'b');
      expect(history.page!['nextBefore'], 'b');
      expect(history.error, isNull);
    },
  );

  for (final method in ['update', 'delete']) {
    testWidgets(
      '$method acknowledgement cannot cross connection during catalog readback',
      (tester) async {
        final runtime = AutomationConnectionRuntime();
        final sink = await attachAutomationConnection(runtime);
        automationConnection(sink, 'A');
        await tester.pump();
        final catalog = AutomationsController(runtime)..start();
        addTearDown(() {
          catalog.dispose();
          runtime.dispose();
        });
        await tester.pump();
        final readback = Completer<List<Json>>();
        var reads = 0;
        runtime.handler = (name, _) async {
          if (name == 'catalog') {
            return ++reads == 1
                ? readback.future
                : [taskFixture(title: 'B 当前记录')];
          }
          expectSync(name, method);
          return method == 'update'
              ? {'record': taskFixture(title: 'A 已保存')}
              : {'deleted': true};
        };
        final result = method == 'update'
            ? catalog.update(AutomationDraft(taskFixture()).request())
            : catalog.delete(taskFixture());
        final rejected = expectLater(
          result,
          throwsA(isA<AutomationCatalogUnconfirmed>()),
        );
        await tester.pump();
        automationConnection(sink, 'B');
        await tester.pump();
        expect(catalog.current, isTrue);
        readback.complete([taskFixture(title: 'A 已保存')]);
        await rejected;
        expect(catalog.records.single['title'], 'B 当前记录');
        expect(runtime.requests.where((r) => r.method == method), hasLength(1));
      },
    );
  }

  for (final method in ['update', 'delete']) {
    testWidgets(
      'pending $method preserves draft on replacement and ignores late acknowledgement',
      (tester) async {
        final runtime = AutomationConnectionRuntime();
        final sink = await attachAutomationConnection(runtime);
        automationConnection(sink, 'A');
        await tester.pump();
        final catalog = AutomationsController(runtime)..start();
        addTearDown(() {
          catalog.dispose();
          runtime.dispose();
        });
        await tester.pump();
        final pending = Completer<Json>(), fresh = Completer<List<Json>>();
        runtime.handler = (name, _) {
          if (name == 'catalog') return fresh.future;
          expectSync(name, method);
          return pending.future;
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: pocketTheme(Brightness.light),
            home: AutomationDetailPage(
              catalog: catalog,
              record: taskFixture(),
              onOpenSession: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('automation-title')),
          '保留我的草稿',
        );
        if (method == 'update') {
          await tapVisible(tester, find.text('保存任务'));
        } else {
          await tapVisible(tester, find.widgetWithText(PocketButton, '删除任务'));
          await tapVisible(tester, find.text('确认删除任务'));
        }
        expect(runtime.requests.where((r) => r.method == method), hasLength(1));
        automationConnection(sink, 'B');
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 2400));
        await tester.pumpAndSettle();
        expect(find.textContaining('操作结果尚未确认'), findsOneWidget);
        expect(find.textContaining('当前任务待核实'), findsOneWidget);
        expect(await fieldText(tester, 'title'), '保留我的草稿');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('automation-title')))
              .enabled,
          isFalse,
        );
        fresh.complete([taskFixture(title: 'B 服务记录')]);
        await tester.pumpAndSettle();
        expect(await fieldText(tester, 'title'), '保留我的草稿');
        pending.complete(
          method == 'update'
              ? {'record': taskFixture(title: 'A 已保存')}
              : {'deleted': true},
        );
        await tester.pumpAndSettle();
        expect(await fieldText(tester, 'title'), '保留我的草稿');
        expect(find.text('已保存任务。'), findsNothing);
        expect(find.text('任务已删除。'), findsNothing);
        expect(find.text('确认删除任务'), findsNothing);
        expect(runtime.requests.where((r) => r.method == method), hasLength(1));
        expect(catalog.records.single['title'], 'B 服务记录');
      },
    );
  }
}
