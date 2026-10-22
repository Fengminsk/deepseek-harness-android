import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_skills.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/text_document_page.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/settings_layout_capture.dart';
import 'tool_activity_fixture.dart';

Json message(int seq, String text, {Json source = const {'kind': 'user'}}) =>
    toolEvent(seq, 'user/message', {
      'source': source,
      'content': [
        {'type': 'text', 'text': text},
      ],
    }, surfaceOp: 'append');

Json invocation(int seq, String name) => message(
  seq,
  'Recorded instructions',
  source: {'kind': 'skill-invocation', 'name': name, 'form': 'instructions'},
);

Json assistant(int seq) => toolEvent(seq, 'assistant/message', {
  'turn': 1,
  'step': 1,
  'message': {
    'content': [
      {'type': 'text', 'text': 'done'},
    ],
  },
}, surfaceOp: 'append');

void replay(ChatSkillNameProjection facts, List<Json> events) {
  final chat = ChatProjection()..reconcile(events);
  facts.reconcile(entries: chat.entries, events: events);
}

ToolActivity skillActivity({
  String raw = '{"name":"dsh-manage-issues"}',
  String? output = 'Follow the issue workflow.\nKeep project fields in sync.',
  bool isError = false,
  Json? error,
  dynamic meta,
  List<dynamic>? blocks,
  bool orphan = false,
}) {
  final call = callEvent(1, name: 'skill');
  (call['data'] as Json)['arguments'] = raw;
  final result = resultEvent(
    2,
    text: output ?? '',
    isError: isError,
    error: error,
    meta: meta,
  );
  if (blocks != null) {
    ((result['data'] as Json)['message'] as Json)['content'] = blocks;
  }
  final projection = ToolActivityProjection()
    ..reconcile([
      if (!orphan) call,
      if (output != null || blocks != null || error != null) result,
    ]);
  return projection.byAnchorSeq.values.single;
}

Widget host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: PocketScaffold(
    title: const Text('会话'),
    body: PocketList(children: [child]),
  ),
);

void main() {
  setUpAll(loadSettingsCaptureFonts);

  // Durable sequence from ui-chat conversation-node-definitions' regression:
  // a confirmed first turn and an unconfirmed second occurrence of the name.
  test('cold history binds a skill only to its recorded message batch', () {
    final events = [
      toolEvent(1, 'turn/start', {'turn': 1}),
      message(2, '/demo-skill go'),
      toolEvent(3, 'step/start', {'turn': 1, 'step': 1}),
      message(4, 'instructions', source: {'kind': 'agent-instructions'}),
      invocation(5, 'demo-skill'),
      assistant(6),
      toolEvent(7, 'step/end', {'turn': 1, 'step': 1}),
      toolEvent(8, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
      toolEvent(9, 'turn/start', {'turn': 2}),
      message(10, '/demo-skill again?'),
      toolEvent(11, 'step/start', {'turn': 2, 'step': 1}),
      message(12, 'instructions', source: {'kind': 'agent-instructions'}),
    ];
    final facts = ChatSkillNameProjection();
    replay(facts, events);
    expect(facts.namesFor(2), ['demo-skill']);
    expect(facts.namesFor(10), isEmpty);
  });

  test(
    'transparent context, steering batches, deduplication and turn tails',
    () {
      final facts = ChatSkillNameProjection();
      replay(facts, [
        message(1, '/one'),
        message(2, '/two'),
        message(3, 'ordinary context', source: {'kind': 'other'}),
        invocation(4, 'one'),
        invocation(5, 'two'),
        invocation(6, 'one'),
        toolEvent(7, 'turn/end', {
          'turn': 1,
          'reason': {'kind': 'completed'},
        }),
        message(8, '/one'),
        invocation(9, 'three'),
      ]);
      expect(facts.namesFor(1), ['one', 'two']);
      expect(facts.namesFor(2), ['one', 'two']);
      expect(facts.namesFor(8), ['three']);
    },
  );

  test(
    'late injection updates old batch; replacement drops withdrawn facts',
    () {
      final facts = ChatSkillNameProjection();
      final events = [message(1, 'Use /review')];
      replay(facts, events);
      expect(facts.namesFor(1), isEmpty);
      events.add(invocation(2, 'review'));
      replay(facts, events);
      expect(facts.namesFor(1), ['review']);
      final same = facts.namesFor(1);
      replay(facts, events);
      expect(identical(facts.namesFor(1), same), isTrue);
      replay(facts, [message(1, 'Use /review'), invocation(2, '')]);
      expect(facts.namesFor(1), isEmpty);
      replay(facts, [message(1, 'different session')]);
      expect(facts.namesFor(1), isEmpty);
    },
  );

  test(
    'assistant/tool boundaries prevent later injections reaching earlier user',
    () {
      for (final boundary in [assistant(2), callEvent(2)]) {
        final facts = ChatSkillNameProjection();
        replay(facts, [
          message(1, '/review'),
          boundary,
          message(3, '/later'),
          invocation(4, 'later'),
        ]);
        expect(facts.namesFor(1), isEmpty);
        expect(facts.namesFor(3), ['later']);
      }
    },
  );

  test('recall labels attach only to exact preceding direct message seq', () {
    final facts = ChatSkillNameProjection();
    final source = {
      'kind': 'session-reference',
      'references': [
        {'label': '会话一', 'sessionId': 'old'},
        {'label': '会话一'},
        {'label': ''},
        {'label': 7},
        null,
        {'label': '会话二'},
      ],
    };
    replay(facts, [
      message(1, '@会话一'),
      message(2, 'recall', source: source),
      message(3, '@会话二'),
      message(4, 'other', source: {'kind': 'agent-instructions'}),
      message(5, 'recall', source: source),
    ]);
    expect(facts.sessionLabelsFor(1), ['会话一', '会话二']);
    expect(facts.sessionLabelsFor(3), isEmpty);
    expect(facts.sessionLabelsFor(4), isEmpty);
    replay(facts, [
      message(1, '@会话一'),
      message(2, 'no recall', source: {'kind': 'other'}),
    ]);
    expect(facts.sessionLabelsFor(1), isEmpty);
  });

  test('skill tokens retain original whitespace boundaries and UTF16 offsets', () {
    const text =
        '🙂 /review inside /review\n/review\t/review.md /review/path /review, /review。 prefix/review (/review) /unknown';
    final ranges = skillReferenceRanges(text, ['review']);
    expect(ranges.map((range) => range.start), [3, 18, 26]);
    expect(ranges.map((range) => text.substring(range.start, range.end)), [
      '/review',
      '/review',
      '/review',
    ]);
    expect(skillReferenceRanges(text, []), isEmpty);
  });

  test('session candidates prefer wire and longest exact label without boundary trimming', () {
    const text = '🙂 @[a](dsh-session:x) @会话一， @会话 @未知 @types/react';
    final ranges = sessionReferenceRanges(text, ['[a]', '会话', '会话一', 'types']);
    expect(ranges.map((range) => range.label), ['a', '会话一', '会话', 'types']);
    expect(ranges.first.start, 3);
    expect(
      text.substring(ranges.first.start, ranges.first.end),
      '@[a](dsh-session:x)',
    );
    expect(sessionReferenceRanges('@[a](dsh-session:x)', []).single.label, 'a');
    expect(sessionReferenceRanges('@[a](https://x) @unknown', []), isEmpty);
    expect(sessionReferenceRanges('@[a\nb](dsh-session:x)', []), isEmpty);
  });

  test(
    'session candidates keep interior ranges for other-rule competition',
    () {
      // A file beginning earlier can consume the first candidate; the scheduler
      // must still be able to consider a later @ inside that candidate's label.
      const text = '@src/@types @next';
      final ranges = sessionReferenceRanges(text, ['types @next', 'next']);
      expect(ranges.map((range) => range.label), ['types @next', 'next']);
      expect(skillReferenceRanges('@会话/plan', ['plan']), isEmpty);
    },
  );

  test(
    'skill row uses durable arguments and output, never catalog-like metadata',
    () {
      final activity = skillActivity(
        meta: {'name': 'today-name', 'description': 'not recorded output'},
      );
      final model = ChatSkillToolPresentation(activity);
      expect(ChatSkillToolPresentation.supports(activity), isTrue);
      expect(model.name, 'dsh-manage-issues');
      expect(
        model.output,
        'Follow the issue workflow.\nKeep project fields in sync.',
      );
      expect(model.status, '技能已加载');
      expect(
        ChatSkillToolPresentation.supports(skillActivity(orphan: true)),
        isFalse,
      );
    },
  );

  test(
    'recorded malformed and scalar argument fallbacks match original row',
    () {
      for (final entry in {
        '{"name":\n': '{"name":',
        '"raw-name"': '"raw-name"',
        '{"name":""}': '{"name":""}',
        '': 'call-0',
        '{"name":"first\\nsecond"}': 'first',
      }.entries) {
        expect(
          ChatSkillToolPresentation(skillActivity(raw: entry.key)).name,
          entry.value,
        );
      }
    },
  );

  test('failed, interrupted, pending and nontext records preserve original meaning', () {
    final failure = ChatSkillToolPresentation(
      skillActivity(
        output: 'SkillError: missing resource\nCheck SKILL.md.',
        isError: true,
      ),
    );
    expect(failure.summary, 'SkillError: missing resource');
    final stopped = ChatSkillToolPresentation(
      skillActivity(
        isError: false,
        error: {'name': 'Interrupted', 'code': 'interrupted'},
      ),
    );
    expect(stopped.summary, '技能加载已中止');
    expect(stopped.status, '技能加载已中止');
    final pending = ChatSkillToolPresentation(skillActivity(output: null));
    expect(pending.output, isNull);
    expect(pending.status, '正在加载技能');
    final emptyFailure = ChatSkillToolPresentation(
      skillActivity(
        blocks: [],
        isError: true,
        error: {'name': 'SkillError', 'code': 'missing'},
      ),
    );
    expect(emptyFailure.output, 'SkillError: missing');
    final block = {'type': 'reasoning', 'text': 'Recorded reasoning'};
    expect(
      ChatSkillToolPresentation(skillActivity(blocks: [block])).output,
      const JsonEncoder.withIndent('  ').convert(block),
    );
    expect(ChatSkillToolPresentation(skillActivity(output: '')).output, isNull);
  });

  testWidgets(
    'skill row opens exact read-only recorded instructions and inspector',
    (tester) async {
      await tester.pumpWidget(
        host(ChatSkillToolCard(activity: skillActivity())),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载技能'), findsOneWidget);
      expect(find.text('dsh-manage-issues'), findsOneWidget);
      await tester.tap(find.text('加载技能'));
      await tester.pumpAndSettle();
      final document = tester.widget<TextDocumentPage>(
        find.byType(TextDocumentPage),
      );
      expect(document.readOnly, isTrue);
      expect(document.selectable, isTrue);
      expect(
        document.text,
        'Follow the issue workflow.\nKeep project fields in sync.',
      );
      await tester.tap(
        find.byWidgetPredicate((w) => w is GlassButton && w.label == '返回'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is GlassButton && w.label == '查看技能原始调用',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('完整原始详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending or empty output offers no invented instruction action', (
    tester,
  ) async {
    for (final activity in [
      skillActivity(output: null),
      skillActivity(output: ''),
    ]) {
      await tester.pumpWidget(host(ChatSkillToolCard(activity: activity)));
      await tester.pumpAndSettle();
      expect(tester.widget<PocketTile>(find.byType(PocketTile)).onTap, isNull);
      expect(
        find.byWidgetPredicate(
          (w) => w is GlassButton && w.label == '查看技能原始调用',
        ),
        findsNothing,
      );
    }
  });

  testWidgets(
    'removed activity cannot open stale snapshot from its former row',
    (tester) async {
      final activity = skillActivity();
      final source = ValueNotifier<ToolActivity?>(activity);
      addTearDown(source.dispose);
      await tester.pumpWidget(
        host(ChatSkillToolCard(activity: activity, activitySource: source)),
      );
      await tester.pumpAndSettle();
      source.value = null;
      await tester.tap(find.text('加载技能'));
      await tester.pumpAndSettle();
      expect(find.byType(TextDocumentPage), findsNothing);
    },
  );

  testWidgets(
    'preview skill label is inert and pending activation cannot double open',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      Future<void> open(String name) {
        calls++;
        return pending.future;
      }

      await tester.pumpWidget(
        host(
          ChatSkillReference(name: 'review', interactive: false, onOpen: open),
        ),
      );
      await tester.tap(find.text('/review'));
      await tester.pump();
      expect(calls, 0);
      await tester.pumpWidget(
        host(ChatSkillReference(name: 'review', onOpen: open)),
      );
      await tester.tap(find.text('/review'));
      await tester.pump();
      await tester.tap(find.text('/review'));
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late failure from replaced skill leaves the new reference untouched',
    (tester) async {
      final pending = Completer<void>();
      Future<void> oldOpen(String name) => pending.future;
      Future<void> newOpen(String name) async {}
      await tester.pumpWidget(
        host(ChatSkillReference(name: 'old', onOpen: oldOpen)),
      );
      await tester.tap(find.text('/old'));
      await tester.pump();
      await tester.pumpWidget(
        host(ChatSkillReference(name: 'new', onOpen: newOpen)),
      );
      pending.completeError(StateError('old request failed'));
      await tester.pumpAndSettle();
      expect(find.text('/new'), findsOneWidget);
      expect(find.bySemanticsLabel('未能打开，点按重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared reference keeps pending guard across unrelated rebuilds',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      Widget view() => host(
        ChatInlineReference(
          label: 'report.pdf',
          icon: Icons.insert_drive_file_outlined,
          onOpen: () {
            calls++;
            return pending.future;
          },
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatInlineReference));
      await tester.pump();
      await tester.pumpWidget(view());
      await tester.tap(find.byType(ChatInlineReference));
      expect(calls, 1);
      pending.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatInlineReference));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('skill rows and document fit ${brightness.name} large text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 860));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capture = SettingsLayoutCapture();
      final activity = skillActivity(
        raw: '{"name":"android-authorized-file-workflow"}',
        output: '读取用户授权的文件\n\n先核对目录授权，再读取原始内容。\n保留文件来源与引用，不更改未经授权的文件。',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(brightness),
          builder: (context, child) => capture.wrap(context, child, scale: 1.8),
          home: PocketScaffold(
            title: const Text('技能记录'),
            body: PocketList(
              children: [
                const Wrap(
                  children: [
                    ChatSkillReference(name: 'review', interactive: false),
                  ],
                ),
                ChatSkillToolCard(activity: activity),
                ChatSkillToolCard(
                  activity: skillActivity(
                    output: 'SkillError: 找不到所需文件\n请检查技能资源。',
                    isError: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture.save(tester, 'chat-skills-${brightness.name}-1.8');
      await tester.tap(find.text('加载技能').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture.save(tester, 'chat-skill-document-${brightness.name}-1.8');
    });
  }
}
