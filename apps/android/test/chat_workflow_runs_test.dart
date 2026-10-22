import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_workflow_runs.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;

Json record(int seq, String type, Json data) =>
    fixture.event(seq, type, data, surface: 'append');

List<Json> completeRun() => [
  record(1, 'turn/start', {'turn': 1}),
  record(2, 'step/start', {'turn': 1, 'step': 1}),
  record(3, 'tool-workflow/run-start', {'runId': 'run-1', 'name': '审核'}),
  record(4, 'tool-workflow/agent-start', {
    'runId': 'run-1',
    'seq': 1,
    'label': '成员一',
    'phase': '',
    'childId': 'child-1',
  }),
  record(5, 'tool-workflow/agent-start', {
    'runId': 'run-1',
    'seq': 2,
    'label': '成员二',
    'childId': 'child-2',
  }),
  record(6, 'tool-workflow/agent-end', {
    'runId': 'run-1',
    'seq': 1,
    'outcome': 'completed',
  }),
  record(7, 'tool-workflow/agent-end', {
    'runId': 'run-1',
    'seq': 2,
    'outcome': 'failed',
  }),
  record(8, 'tool-workflow/run-end', {'runId': 'run-1', 'stopReason': 'error'}),
];

void main() {
  test(
    'replays real run and member facts, preserving empty versus missing phase',
    () {
      final projection = ChatWorkflowRunProjection()..reconcile(completeRun());
      final run = projection.records.single;
      expect(run.seq, 3);
      expect(run.status, WorkflowRunStatus.failed);
      expect(run.memberCount, 2);
      expect(run.phases.map((phase) => phase.phase).toList(), ['', null]);
      expect(run.phases[0].members.single.status, WorkflowRunStatus.completed);
      expect(run.phases[1].members.single.status, WorkflowRunStatus.failed);
      expect(run.phases[0].title, '空阶段名');
      expect(run.phases[1].title, '未分阶段');
      expect(
        (ChatProjection()..reconcile(completeRun())).entries,
        isEmpty,
        reason: 'workflow facts must not become unknown/debug rows',
      );
    },
  );

  test(
    'an update-only history tail remains hidden until the start page arrives',
    () {
      final events = completeRun();
      final projection = ChatWorkflowRunProjection()
        ..reconcile(events.sublist(3));
      expect(projection.records, isEmpty);
      projection.reconcile(events);
      final full = ChatWorkflowRunProjection()..reconcile(events);
      expect(
        projection.records.single.memberCount,
        full.records.single.memberCount,
      );
      expect(projection.records.single.status, full.records.single.status);
      expect(
        projection.records.single.phases.map((p) => p.phase),
        full.records.single.phases.map((p) => p.phase),
      );
    },
  );

  test(
    'live append and complete replay converge, unchanged frames are O(1)',
    () {
      final events = completeRun();
      final projection = ChatWorkflowRunProjection();
      final loaded = <Json>[];
      for (final event in events) {
        loaded.add(event);
        projection.reconcile(loaded);
      }
      final before = projection.processedEventCount;
      projection.reconcile(loaded);
      expect(projection.processedEventCount, before);
      final full = ChatWorkflowRunProjection()..reconcile(events);
      expect(projection.records.single.status, full.records.single.status);
      expect(
        projection.records.single.memberCount,
        full.records.single.memberCount,
      );
    },
  );

  test('ordinary turn close does not imply a background run has ended', () {
    final events = completeRun().sublist(0, 4)
      ..add(
        record(5, 'turn/end', {
          'turn': 1,
          'reason': {'kind': 'completed'},
        }),
      );
    final projection = ChatWorkflowRunProjection()..reconcile(events);
    expect(projection.records.single.status, WorkflowRunStatus.running);
    expect(
      projection.records.single.phases.single.members.single.status,
      WorkflowRunStatus.running,
    );
  });

  test(
    'crash or fork of owning turn marks only unterminated run interrupted',
    () {
      final events = completeRun().sublist(0, 4)
        ..add(
          record(5, 'turn/end', {
            'turn': 1,
            'reason': {'kind': 'interrupted'},
          }),
        );
      final projection = ChatWorkflowRunProjection()..reconcile(events);
      expect(projection.records.single.status, WorkflowRunStatus.interrupted);
      expect(
        projection.records.single.phases.single.members.single.status,
        WorkflowRunStatus.interrupted,
      );
      events.add(
        record(6, 'tool-workflow/run-end', {
          'runId': 'run-1',
          'stopReason': 'completed',
        }),
      );
      projection.reconcile(events);
      expect(projection.records.single.status, WorkflowRunStatus.completed);
    },
  );

  test('no start means no fabricated run, malformed updates do not throw', () {
    final projection = ChatWorkflowRunProjection()
      ..reconcile([
        record(1, 'tool-workflow/agent-end', {
          'runId': 'absent',
          'seq': 9,
          'outcome': 'failed',
        }),
        record(2, 'tool-workflow/run-end', {
          'runId': 'absent',
          'stopReason': 'error',
        }),
      ]);
    expect(projection.records, isEmpty);
  });

  testWidgets(
    'run and phase disclosure shows compact status without controls',
    (tester) async {
      final run = (ChatWorkflowRunProjection()..reconcile(completeRun()))
          .records
          .single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatWorkflowRunCard(record: run)),
        ),
      );
      expect(find.text('审核'), findsOneWidget);
      expect(find.text('空阶段名'), findsOneWidget);
      expect(find.text('未分阶段'), findsOneWidget);
      expect(find.text('成员一'), findsNothing);
      expect(find.text('成员二'), findsOneWidget);
      expect(find.text('运行'), findsNothing);
      await tester.tap(find.text('空阶段名'));
      await tester.pump();
      expect(find.text('成员一'), findsOneWidget);
      await tester.tap(find.text('审核'));
      await tester.pump();
      expect(find.text('成员一'), findsNothing);
    },
  );

  testWidgets('historical workflow is one nested chat item, not debug events', (
    tester,
  ) async {
    final events = completeRun();
    final projection = ChatProjection()..reconcile(events);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PocketScaffold(
          title: const Text('会话'),
          body: ChatTimeline(
            sessionId: 'parent',
            projection: projection,
            events: events,
            controller: scroll,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatWorkflowRunCard), findsOneWidget);
    expect(find.text('审核'), findsOneWidget);
    expect(find.textContaining('未识别的会话内容'), findsNothing);
  });

  testWidgets(
    'a new member reopens a completed phase without replacing the run',
    (tester) async {
      final events = <Json>[
        record(1, 'tool-workflow/run-start', {'runId': 'r', 'name': '长期任务'}),
        record(2, 'tool-workflow/agent-start', {
          'runId': 'r',
          'seq': 1,
          'label': '第一轮',
          'phase': '检查',
          'childId': 'child-1',
        }),
      ];
      final projection = ChatWorkflowRunProjection()..reconcile(events);
      Widget view() => MaterialApp(
        home: Scaffold(
          body: ChatWorkflowRunCard(
            key: const ValueKey('run'),
            record: projection.records.single,
          ),
        ),
      );
      await tester.pumpWidget(view());
      expect(find.text('第一轮'), findsOneWidget);
      events.add(
        record(3, 'tool-workflow/agent-end', {
          'runId': 'r',
          'seq': 1,
          'outcome': 'completed',
        }),
      );
      projection.reconcile(events);
      await tester.pumpWidget(view());
      expect(find.text('第一轮'), findsNothing);
      events.add(
        record(4, 'tool-workflow/agent-start', {
          'runId': 'r',
          'seq': 2,
          'label': '第二轮',
          'phase': '检查',
          'childId': 'child-2',
        }),
      );
      projection.reconcile(events);
      await tester.pumpWidget(view());
      expect(find.text('第二轮'), findsOneWidget);
      expect(find.text('第一轮'), findsOneWidget);
    },
  );
}
