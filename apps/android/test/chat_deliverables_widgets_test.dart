import 'dart:async';

import 'package:dsh_android/chat_deliverables.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_deliverables_test.dart' as fixture;
import 'support/settings_layout_capture.dart';

Widget host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: PocketScaffold(title: const Text('会话'), body: child),
);

void main() {
  setUpAll(loadSettingsCaptureFonts);

  testWidgets(
    'cold transcript renders native recorded todo rows and opens all statuses',
    (tester) async {
      final events = [fixture.todoEvent(1, fixture.parallelTodos)];
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'session-a',
            projection: ChatProjection()..reconcile(events),
            events: events,
            controller: scroll,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('待办更新'), findsOneWidget);
      expect(find.textContaining('2 项进行中'), findsOneWidget);
      await tester.tap(find.text('待办更新'));
      await tester.pumpAndSettle();
      expect(find.text('待办记录'), findsOneWidget);
      expect(find.text('分析表格'), findsOneWidget);
      expect(find.text('生成报告'), findsOneWidget);
      expect(find.text('进行中'), findsNWidgets(2));
      expect(find.text('已完成'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'floating todo dock updates in place and clears on turn start or session change',
    (tester) async {
      final events = [fixture.todoEvent(1, fixture.parallelTodos)];
      Widget view(String session, List<Json> source) => host(
        PocketList(
          children: [ChatTodoDock(sessionId: session, events: source)],
        ),
      );
      await tester.pumpWidget(view('a', events));
      await tester.pumpAndSettle();
      expect(find.text('生成报告'), findsNothing);
      await tester.tap(find.textContaining('2 项进行中'));
      await tester.pumpAndSettle();
      expect(find.text('生成报告'), findsOneWidget);
      events.add(
        fixture.todoEvent(2, [
          {'content': '报告完成', 'status': 'completed'},
        ]),
      );
      await tester.pumpWidget(view('a', events));
      await tester.pumpAndSettle();
      expect(find.text('报告完成'), findsOneWidget);
      expect(find.text('分析表格'), findsNothing);
      events.add(fixture.endEvent(3, 1));
      await tester.pumpWidget(view('a', events));
      await tester.pumpAndSettle();
      expect(find.text('报告完成'), findsOneWidget);
      events.add(fixture.artifactEvent(4, 'turn/start', {'turn': 2}));
      await tester.pumpWidget(view('a', events));
      await tester.pumpAndSettle();
      expect(find.byType(GlassSurface), findsNothing);
      await tester.pumpWidget(view('other', []));
      expect(find.textContaining('项'), findsNothing);
    },
  );

  testWidgets(
    'present file callback carries owning session and exact literal reference',
    (tester) async {
      const path = './reports/原稿%20#?.pdf';
      final events = [
        fixture.presentEvent(1, 1, [
          {'path': path, 'description': '交付报告'},
        ]),
        fixture.replyEvent(2, 1, '文件已完成'),
        fixture.endEvent(3, 1),
      ];
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final opened = <ChatFileLink>[];
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'original-session',
            projection: ChatProjection()..reconcile(events),
            events: events,
            controller: scroll,
            onOpenFile: (file) async {
              opened.add(file);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('交付文件'), findsOneWidget);
      await tester.tap(find.text('原稿%20#?.pdf'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(opened.single.sessionId, 'original-session');
      expect(opened.single.path, path);
      expect(opened.single.line, isNull);
    },
  );

  testWidgets(
    'readable delivery cards expand beyond four and avoid repeated pending opens',
    (tester) async {
      final projection = ChatArtifactsProjection()
        ..reconcile([
          fixture.presentEvent(1, 1, [
            for (var i = 0; i < 6; i++) {'path': '/workspace/file-$i.pdf'},
          ]),
          fixture.endEvent(2, 1),
        ]);
      final delivery = projection.entries.whereType<ChatPresentedTurn>().single;
      final pending = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: ChatPresentedFiles(
              sessionId: 's',
              delivery: delivery,
              onOpen: (_) {
                calls++;
                return pending.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('file-4.pdf'), findsNothing);
      await tester.tap(find.text('file-0.pdf'));
      await tester.pump();
      await tester.tap(find.text('file-0.pdf'));
      await tester.pump();
      expect(calls, 1);
      pending.complete();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看全部 6 个文件'));
      await tester.tap(find.text('查看全部 6 个文件'));
      await tester.pumpAndSettle();
      expect(find.text('file-5.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late file-open errors cannot mark another session and unavailable callbacks are inert',
    (tester) async {
      ChatPresentedTurn delivery(String path) =>
          (ChatArtifactsProjection()..reconcile([
                fixture.presentEvent(1, 1, [
                  {'path': path},
                ]),
                fixture.endEvent(2, 1),
              ]))
              .entries
              .whereType<ChatPresentedTurn>()
              .single;
      final pending = Completer<void>();
      Widget view(
        String session,
        String path,
        Future<void> Function(ChatPresentedFile)? callback,
      ) => host(
        PocketList(
          children: [
            ChatPresentedFiles(
              sessionId: session,
              delivery: delivery(path),
              onOpen: callback,
            ),
          ],
        ),
      );
      await tester.pumpWidget(view('a', 'a.pdf', (_) => pending.future));
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.pdf'));
      await tester.pump();
      await tester.pumpWidget(view('b', 'b.pdf', null));
      pending.completeError(StateError('old session unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件未能打开'), findsNothing);
      expect(find.textContaining('文件预览暂不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed opening keeps a visible retry rather than discarding delivery',
    (tester) async {
      final delivery =
          (ChatArtifactsProjection()..reconcile([
                fixture.presentEvent(1, 1, [
                  {'path': 'a.pdf'},
                ]),
                fixture.endEvent(2, 1),
              ]))
              .entries
              .whereType<ChatPresentedTurn>()
              .single;
      var calls = 0;
      await tester.pumpWidget(
        host(
          PocketList(
            children: [
              ChatPresentedFiles(
                sessionId: 'a',
                delivery: delivery,
                onOpen: (_) async {
                  if (++calls == 1) throw StateError('read failed');
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.pdf'));
      await tester.pumpAndSettle();
      expect(find.textContaining('点按重试'), findsOneWidget);
      await tester.tap(find.text('a.pdf'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('点按重试'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('todo and delivery layout ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final events = [
          fixture.todoEvent(1, fixture.parallelTodos),
          fixture.presentEvent(2, 1, [
            {'path': '/workspace/每月经营分析报告.pdf', 'description': '汇总本月经营数据和待办事项'},
            {'path': '/workspace/数据明细.xlsx', 'description': '可编辑的数据表格'},
          ]),
          fixture.replyEvent(3, 1, '报告与表格已完成，可以打开查看。'),
          fixture.endEvent(4, 1),
        ];
        final capture = SettingsLayoutCapture();
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: pocketTheme(brightness),
            builder: (context, child) =>
                capture.wrap(context, child, scale: scale),
            home: PocketScaffold(
              title: const Text('会话'),
              body: ChatTimeline(
                sessionId: 'session',
                projection: ChatProjection()..reconcile(events),
                events: events,
                controller: scroll,
                onOpenFile: (_) async {},
              ),
              bottom: ChatTodoDock(sessionId: 'session', events: events),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await capture.save(
          tester,
          'chat-deliverables-${brightness.name}-$scale',
        );
        await tester.tap(find.textContaining('2 项进行中').last);
        await tester.pumpAndSettle();
        await capture.save(tester, 'chat-todos-${brightness.name}-$scale');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
