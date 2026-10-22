import 'package:dsh_android/chat_message_actions.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/chat_skills.dart';
import 'package:dsh_android/chat_changes.dart';
import 'package:dsh_android/chat_user_references.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'tool_activity_fixture.dart';
import 'workspace_changes_fixtures.dart';

Widget host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: PocketScaffold(title: const Text('会话'), body: child),
);

void main() {
  test('original reference precedence keeps paths, skill facts and canonical labels distinct', () {
    const text =
        '😀 **原样** @"my docs/a.txt"， @src/ @[会话](dsh-session:InMi) /review /unknown';
    final refs = chatUserReferences(text, skillNames: ['review']);
    expect(refs.map((ref) => ref.kind), [
      ChatReferenceKind.file,
      ChatReferenceKind.folder,
      ChatReferenceKind.session,
      ChatReferenceKind.skill,
    ]);
    expect(refs.map((ref) => ref.value), [
      'my docs/a.txt',
      'src/',
      '会话',
      'review',
    ]);
    expect(
      text.substring(refs.first.start, refs.first.end),
      '@"my docs/a.txt"',
    );
    expect(
      text.substring(refs[2].start, refs[2].end),
      '@[会话](dsh-session:InMi)',
    );
    expect(chatUserReferences('me@example.com /review'), isEmpty);
  });

  test('recorded bare session label wins over path and preserves punctuation outside references', () {
    const text = '@earlier session看一下 @src/a.txt。 @[draft]/';
    final refs = chatUserReferences(
      text,
      sessionLabels: ['earlier', 'earlier session'],
    );
    expect(refs.map((ref) => ref.kind), [
      ChatReferenceKind.session,
      ChatReferenceKind.file,
      ChatReferenceKind.folder,
    ]);
    expect(refs.first.label, 'earlier session');
    expect(text.substring(refs[1].end, refs[1].end + 1), '。');
    expect(refs.last.value, '[draft]/');
  });

  testWidgets(
    'timeline renders historical references without changing copied original and rebinds on Session change',
    (tester) async {
      const source = '请 /review 读取 @"my docs/a.txt" 和 @[旧会话](dsh-session:InMi)';
      final events = <Json>[
        fixture.input(1, source),
        fixture.input(
          2,
          'recorded instructions',
          source: {
            'kind': 'skill-invocation',
            'name': 'review',
            'form': 'instructions',
          },
        ),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      ChatFileLink? opened;
      String? skill;
      Widget view(String id, List<Json> loaded) => host(
        ChatTimeline(
          sessionId: id,
          projection: projection..reconcile(loaded),
          events: loaded,
          controller: scroll,
          onOpenFile: (file) async {
            opened = file;
          },
          onOpenSkill: (name) async {
            skill = name;
          },
        ),
      );
      await tester.pumpWidget(view('session-a', events));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInlineReference), findsNWidgets(3));
      final actions = tester.widget<ChatMessageActions>(
        find.byType(ChatMessageActions),
      );
      expect(actions.text, source);
      await tester.tap(find.text('/review', findRichText: true));
      await tester.pumpAndSettle();
      expect(skill, 'review');
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is ChatInlineReference && widget.label == 'a.txt',
        ),
      );
      await tester.pumpAndSettle();
      expect(opened?.sessionId, 'session-a');
      expect(opened?.path, 'my docs/a.txt');
      await tester.pumpWidget(view('session-b', [fixture.input(1, source)]));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInlineReference), findsNWidgets(2));
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is ChatInlineReference && widget.label == 'a.txt',
        ),
      );
      await tester.pumpAndSettle();
      expect(opened?.sessionId, 'session-b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('skill tool record uses its specialized row in actual timeline', (
    tester,
  ) async {
    final events = <Json>[
      callEvent(1, name: 'skill', args: {'name': 'review'}),
      resultEvent(2, text: 'Follow the recorded review instructions.'),
    ];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ChatTimeline(
          sessionId: 'a',
          projection: ChatProjection()..reconcile(events),
          events: events,
          controller: scroll,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatSkillToolCard), findsOneWidget);
    await tester.tap(find.text('加载技能'));
    await tester.pumpAndSettle();
    expect(
      find.text('Follow the recorded review instructions.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'actual timeline gates changes by the shared preference and rebinds summary reads to the viewed Session',
    (tester) async {
      final runtime = ChangesRuntime();
      final events = <Json>[
        fixture.assistant(1, 'done'),
        changeEvent(2, 'workspace/changes', 1),
        changeEvent(3, 'turn/end', 1),
      ];
      final projection = ChatProjection()..reconcile(events);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget view(String id) => host(
        ChatTimeline(
          runtime: runtime,
          sessionId: id,
          projection: projection,
          events: events,
          controller: scroll,
        ),
      );
      await tester.pumpWidget(view('a'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatChangesCard), findsOneWidget);
      expect(find.text('example.dart'), findsOneWidget);
      expect(
        runtime.reads('workspaceChanges.summary').single.$2['sessionId'],
        'a',
      );
      runtime.settingsChanged(false);
      await tester.pumpAndSettle();
      expect(find.text('example.dart'), findsNothing);
      runtime.settingsChanged(true);
      await tester.pumpAndSettle();
      expect(find.text('example.dart'), findsOneWidget);
      await tester.pumpWidget(view('b'));
      await tester.pumpAndSettle();
      expect(
        runtime.reads('workspaceChanges.summary').last.$2['sessionId'],
        'b',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      runtime.dispose();
    },
  );

  testWidgets(
    'mixed references wrap at phone width with large text without Markdown interpretation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: const Padding(
              padding: EdgeInsets.all(24),
              child: ChatUserText(
                storageId: 'a:1',
                text: '**原样** @src/long-file-name.txt /review 与 @[会话](dsh-session:InMi)',
                skillNames: ['review'],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatInlineReference), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );
}
