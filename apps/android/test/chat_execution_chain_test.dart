import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/chat_execution_chain.dart';
import 'package:dsh_android/chat_execution_data.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_plan.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_source_identity.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'tool_activity_fixture.dart' as tool;

Json end(int seq, String kind) => fixture.event(seq, 'turn/end', {
  'turn': 1,
  'reason': {'kind': kind},
});
Json reasoning(int seq, {String text = '核对来源和发布时间。', String? answer}) =>
    fixture.event(seq, 'assistant/message', {
      'turn': 1,
      'step': seq,
      'message': {
        'id': 'reasoning-$seq',
        'role': 'assistant',
        'content': [
          {'type': 'reasoning', 'text': text},
          if (answer != null) {'type': 'text', 'text': answer},
        ],
      },
    }, surface: 'append');

Json sampleSnapshot() => jsonDecode(
  File('test/fixtures/chat_execution_chain.expected.json').readAsStringSync(),
) as Json;
List<Json> sample() => (sampleSnapshot()['events'] as List).cast<Json>();

Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool preview = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: preview
      ? pocketTheme(brightness).copyWith(
          textTheme: pocketTheme(brightness).textTheme
              .apply(fontFamily: 'ChainPreview'),
        )
      : pocketTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: PocketScaffold(title: const Text('Pocket Harness'), body: child),
);

void main() {
  test(
    'one chain per original turn keeps the answer separate and requires an end',
    () {
      final events = [
        fixture.event(0, 'turn/start', {'turn': 1}),
        reasoning(1, answer: '正文'),
        tool.callEvent(2),
        tool.resultEvent(3),
      ];
      final projection = ChatProjection()..reconcile(events);
      var rows = groupChatExecution(projection.entries, events);
      expect(rows.where((row) => row.chain != null), hasLength(1));
      expect(rows.first.chain!.title, '状态待确认');
      expect(rows.first.chain!.entries.map((row) => row.kind), [
        ChatEntryKind.assistant,
        ChatEntryKind.tool,
      ]);
      expect(
        rows.where((row) => row.entry != null).single.hideReasoning,
        isTrue,
      );
      events.add(end(4, 'completed'));
      projection.reconcile(events);
      rows = groupChatExecution(projection.entries, events);
      expect(rows.first.chain!.title, '已完成');
      expect(rows.first.chain!.duration, '4s');
    },
  );

  test('failed, interrupted, stopped, unknown and orphan calls cannot become a successful chain', () {
    for (final kind in ['error', 'interrupted', 'aborted', 'blocked']) {
      final events = [tool.callEvent(0), end(2, kind)];
      final projection = ChatProjection()..reconcile(events);
      final rows = groupChatExecution(projection.entries, events);
      expect(rows.first.chain!.completed, isFalse);
      expect(rows.first.chain!.entries.last.key, startsWith('turn-end:'));
    }
    final events = [
      tool.callEvent(0),
      tool.resultEvent(1, text: '{"stdout":"","exitCode":7}'),
      end(2, 'completed'),
    ];
    final projection = ChatProjection()..reconcile(events);
    final chain = groupChatExecution(projection.entries, events).first.chain!;
    expect(chain.title, '已结束 · 1 项需查看');
    final orphan = ChatProjection()..reconcile([tool.resultEvent(0)]);
    expect(groupChatExecution(orphan.entries, []).single.chain, isNull);
    expect(chatEventDuration({'time': 20}, {'time': 10}), isNull);
  });

  test(
    'site marks use exact host suffixes and the most specific Web mapping',
    () {
      expect(
        chatSiteMarkPath('gist.github.com'),
        chatSiteMarkPath('github.com'),
      );
      expect(chatSiteMarkPath('GITHUB.COM'), isNotNull);
      expect(chatSiteMarkPath('github.com.evil.example'), isNull);
      expect(chatSiteMarkPath('notgithub.com'), isNull);
      expect(
        chatSiteMarkPath('weixin.qq.com'),
        isNot(chatSiteMarkPath('qq.com')),
      );
    },
  );

  testWidgets(
    'completed chain folds to one row; sources preview and detail remain actionable',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = sample(),
          projection = ChatProjection()..reconcile(sample());
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final opened = <Uri>[];
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'chain',
            projection: projection,
            events: events,
            controller: scroll,
            onOpenLink: (uri) async => opened.add(uri),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已完成'), findsOneWidget);
      expect(tester.getSize(find.byType(ChatExecutionHeader)).height, 48);
      expect(find.byType(ChatExecutionStep), findsNothing);
      expect(find.textContaining('已整理来源', findRichText: true), findsWidgets);
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(find.text('读取网页'), findsOneWidget);
      expect(find.text('GitHub · dotnet/announcements'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ChatExecutionStep),
          matching: find.byType(ChatSourceHostMark),
        ),
        findsNWidgets(4),
      );
      await tester.tap(find.text('GitHub · dotnet/announcements'));
      await tester.pump();
      expect(opened.single.host, 'github.com');
      await tester.tap(find.text('查看更多结果（1 项）'));
      await tester.pumpAndSettle();
      expect(find.text('MDN Web Docs'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭来源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('https://example.org/security').first);
      await tester.pumpAndSettle();
      expect(find.text('结果'), findsWidgets);
      await tester.tap(find.byTooltip('关闭调用详情'));
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsNothing);
      expect(find.text('已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'active defaults open, completion folds, and a manual choice survives updates',
    (tester) async {
      final events = <Json>[
        fixture.event(0, 'turn/start', {'turn': 1}),
        tool.callEvent(1),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view() => host(
        ChatTimeline(
          sessionId: 'active',
          projection: projection,
          events: events,
          controller: scroll,
          running: !events.any((event) => event['type'] == 'turn/end'),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsOneWidget);
      events.addAll([tool.resultEvent(2), end(3, 'completed')]);
      projection.reconcile(events);
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsNothing);
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsNWidgets(2));
      events.add(fixture.assistant(4, '后续正文'));
      projection.reconcile(events);
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final manuallyFolded in [false, true]) {
    testWidgets(
      'unconfirmed calls retain the visible chain until resolved (manual=$manuallyFolded)',
      (tester) async {
        final events = <Json>[
          fixture.event(0, 'turn/start', {'turn': 1}),
          tool.callEvent(1, id: 'unconfirmed-call'),
          fixture.assistant(2, '回复仍然可见'),
        ];
        final projection = ChatProjection();
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        Widget view() => host(
          ChatTimeline(
            sessionId: 'unconfirmed-completion',
            projection: projection..reconcile(events),
            events: events,
            controller: scroll,
            running: !events.any((event) => event['type'] == 'turn/end'),
          ),
        );
        ChatExecutionHeader header() => tester.widget<ChatExecutionHeader>(
          find.byType(ChatExecutionHeader),
        );

        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        expect(header().expanded, isTrue);
        expect(find.byType(ChatExecutionStep), findsOneWidget);
        if (manuallyFolded) {
          await tester.tap(find.byType(ChatExecutionHeader));
          await tester.pumpAndSettle();
        }

        events.add(end(3, 'completed'));
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        expect(header().chain.completed, isFalse);
        expect(header().expanded, !manuallyFolded);
        expect(
          find.byType(ChatExecutionStep),
          manuallyFolded ? findsNothing : findsOneWidget,
        );
        expect(find.text('已完成'), findsNothing);
        expect(find.text('回复仍然可见', findRichText: true), findsOneWidget);

        events.add(tool.resultEvent(4, id: 'unconfirmed-call'));
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        expect(header().chain.completed, isTrue);
        expect(header().expanded, isFalse);
        expect(find.byType(ChatExecutionStep), findsNothing);
        expect(find.text('已完成'), findsOneWidget);
        expect(find.text('回复仍然可见', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'submitted plan folds into the chain and opens its original document',
    (tester) async {
      final events = [
        fixture.event(0, 'turn/start', {'turn': 1}),
        tool.callEvent(
          1,
          name: 'exit_plan_mode',
          args: {'plan': '# 核对计划\n\n核对官方来源。'},
        ),
        tool.resultEvent(2),
        end(3, 'completed'),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          ChatTimeline(
            sessionId: 'plan',
            projection: projection,
            events: events,
            controller: scroll,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('核对计划'), findsNothing);
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      expect(find.text('已提交计划'), findsOneWidget);
      await tester.tap(find.text('核对计划'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPlanDocumentPage), findsOneWidget);
      expect(find.textContaining('核对官方来源。', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live reasoning is replaced by the durable step without repeating the answer',
    (tester) async {
      final events = <Json>[
        fixture.event(0, 'turn/start', {'turn': 1}),
      ];
      final projection = ChatProjection();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view() => host(
        ChatTimeline(
          sessionId: 'stream',
          projection: projection..reconcile(events),
          events: events,
          controller: scroll,
          running: true,
          live: const ChatLiveMessage(
            identity: 'attempt',
            turn: 1,
            step: 1,
            content: [
              {'type': 'reasoning', 'text': '核对来源和发布时间。'},
              {'type': 'text', 'text': '正文'},
            ],
          ),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsOneWidget);
      await tester.tap(find.text('已思考'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ChatExecutionStep),
          matching: find.byType(PocketMarkdown),
        ),
        findsOneWidget,
      );
      events.add(reasoning(1, answer: '正文'));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ChatExecutionStep),
          matching: find.byType(PocketMarkdown),
        ),
        findsOneWidget,
      );
      expect(find.text('正文', findRichText: true), findsOneWidget);
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      events.add(end(2, 'completed'));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byType(ChatExecutionStep), findsNothing);
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('正文', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('execution preview ${brightness.name} and large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = sample(),
          projection = ChatProjection()..reconcile(sample());
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final boundary = GlobalKey();
      if (const bool.fromEnvironment('DSH_CHAIN_PREVIEWS')) {
        await tester.runAsync(() async {
          for (final entry in {
            'ChainPreview': r'C:\Windows\Fonts\msyh.ttc',
            'MaterialIcons': '../../.cache/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(entry.key)..addFont(
                  File(entry.value)
                      .readAsBytes()
                      .then((bytes) => ByteData.sublistView(bytes)),
                ))
                .load();
          }
        });
      }
      Widget view(double scale) => RepaintBoundary(
        key: boundary,
        child: host(
          ChatTimeline(
            sessionId: 'preview',
            projection: projection,
            events: events,
            controller: scroll,
          ),
          brightness: brightness,
          scale: scale,
          preview: const bool.fromEnvironment('DSH_CHAIN_PREVIEWS'),
        ),
      );
      await tester.pumpWidget(view(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatExecutionHeader));
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('DSH_CHAIN_PREVIEWS')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.cache/ui-chain-previews/${brightness.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(view(2));
      await tester.pumpAndSettle();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
