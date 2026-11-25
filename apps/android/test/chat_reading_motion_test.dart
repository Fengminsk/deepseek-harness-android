import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/chat_execution_chain.dart';
import 'package:dsh_android/chat_markdown_syntax.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

import 'chat_execution_chain_test.dart' as chain;
import 'chat_projection_test.dart' as fixture;

Widget host(Widget child, {bool reduced = false}) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: PocketScaffold(title: const Text('Pocket Harness'), body: child),
);

void main() {
  final expected = jsonDecode(
    File('test/fixtures/chat_reading.expected.json').readAsStringSync(),
  ) as Json;
  test(
    'numeric ranges remain literal while explicit deletion and code survive',
    () {
      final html = md.markdownToHtml(
        expected['markdown'] as String,
        extensionSet: pocketMarkdownExtensions,
      );
      expect(html, contains(expected['ranges']));
      expect(html, contains('<del>已撤回</del>'));
      expect(html, contains('<code>a~b</code>'));
      expect(RegExp('<del>').allMatches(html), hasLength(1));
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'reasoning stays small, animates both ways and folds on completion (reduced=$reduced)',
      (tester) async {
        final events = [
          fixture.event(0, 'turn/start', {'turn': 1}),
          chain.reasoning(1),
        ];
        final projection = ChatProjection();
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        Widget view() => host(
          ChatTimeline(
            sessionId: 'reading',
            projection: projection..reconcile(events),
            events: events,
            controller: scroll,
            running: events.length == 2,
          ),
          reduced: reduced,
        );
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ChatExecutionHeader));
        await tester.pumpAndSettle();
        await tester.tap(find.text('已思考'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 70));
        bool blurred() => tester
            .widgetList<ImageFiltered>(
              find.descendant(
                of: find.byType(ChatExecutionStep),
                matching: find.byType(ImageFiltered),
              ),
            )
            .any((filter) => filter.enabled);
        expect(blurred(), !reduced);
        await tester.pumpAndSettle();
        final markdown = tester.widget<MarkdownBody>(
          find.descendant(
            of: find.byType(ChatExecutionStep),
            matching: find.byType(MarkdownBody),
          ),
        );
        expect(markdown.styleSheet!.p!.fontSize, expected['reasoningFontSize']);
        await tester.tap(find.text('已思考'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(blurred(), !reduced);
        await tester.pumpAndSettle();
        // A manual expansion survives completion; the chain never folds by
        // itself behind the reader.
        await tester.tap(find.byType(ChatExecutionHeader));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ChatExecutionHeader));
        await tester.pumpAndSettle();
        events.addAll([
          fixture.assistant(2, '完成后的正文'),
          chain.end(3, 'completed'),
        ]);
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        final header = tester.widget<ChatExecutionHeader>(
          find.byType(ChatExecutionHeader),
        );
        expect(header.expanded, isTrue);
        expect(find.byType(ChatExecutionStep), findsWidgets);
        expect(find.text('完成后的正文', findRichText: true), findsOneWidget);
        expect(
          tester
              .widgetList<MarkdownBody>(find.byType(MarkdownBody))
              .singleWhere((body) => body.data == '完成后的正文')
              .styleSheet!
              .p!
              .fontSize,
          expected['answerFontSize'],
        );
        await tester.tap(find.byType(ChatExecutionHeader));
        await tester.pumpAndSettle();
        expect(find.byType(ChatExecutionStep), findsNothing);
        expect(find.text(expected['completed'] as String), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'sent question moves above the active chain and remaining space shrinks with the reply',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = <Json>[
        for (var i = 0; i < 30; i++) fixture.assistant(i, '较早回复 $i\n' * 4),
      ];
      final projection = ChatProjection();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      int? after;
      Widget view() => host(
        ChatTimeline(
          sessionId: 'send',
          projection: projection..reconcile(events),
          events: events,
          controller: scroll,
          running: after != null,
          submittedAfterSeq: after,
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      after = 29;
      events.addAll([
        fixture.event(30, 'user/message', {
          'id': 'sent',
          'role': 'user',
          'source': {'kind': 'user'},
          'content': [
            {'type': 'text', 'text': '最新问题'},
          ],
        }, surface: 'append'),
        fixture.event(31, 'turn/start', {'turn': 1}),
        chain.reasoning(32),
      ]);
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      final question = find.text('最新问题', findRichText: true);
      expect(question, findsOneWidget);
      expect(tester.getTopLeft(question).dy, lessThan(180));
      expect(
        tester.getTopLeft(find.byType(ChatExecutionHeader)).dy,
        greaterThan(tester.getBottomLeft(question).dy),
      );
      final originalY = tester.getTopLeft(question).dy;
      events.add(fixture.assistant(33, '逐步输出的正文。\n' * 40));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(question).dy, closeTo(originalY, 1));
      // There is no permanent extra screen of blank space after a long answer.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      // No full screen of reserved blank space remains after the answer grew;
      // only the ordinary trailing inset stays below the last paragraph.
      expect(
        tester
            .getBottomLeft(
              find.textContaining('逐步输出的正文。', findRichText: true).last,
            )
            .dy,
        greaterThan(600),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
