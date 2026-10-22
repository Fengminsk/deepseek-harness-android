import 'dart:async';

import 'package:dsh_android/chat_references.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

TextEditingValue draft(String text, {int? cursor}) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor ?? text.length),
);
Json found({List<Json> files = const [], List<Json> sessions = const []}) => {
  'files': {'ok': true, 'value': files},
  'sessions': {'ok': true, 'value': sessions},
};

class ReferenceRuntime extends RuntimeController {
  ReferenceRuntime() {
    phase = 'ready';
  }
  int generation = 0;
  @override
  int get connectionGeneration => generation;
  final requests = <(String, Json)>[];
  Future<dynamic> Function(Json)? read;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    requests.add((method, params));
    if (method == 'references.cancel') return {'cancelled': true};
    expectSync(method, 'references.list');
    return read == null ? found() : read!(params);
  }

  void reconnect(String next) {
    generation++;
    phase = next;
    notifyListeners();
  }
}

void main() {
  test(
    'original @ grammar preserves UTF16 offsets, quoted path and draft suffix',
    () {
      expect(activeReferenceToken(draft('')), isNull);
      expect(activeReferenceToken(draft('me@example.com')), isNull);
      expect(activeReferenceToken(draft('@"done.txt"')), isNull);
      expect(activeReferenceToken(draft('@[对话](dsh-session:InMi)')), isNull);
      expect(activeReferenceToken(draft('@[d'))?.query, '[d');
      final bracketFolder = fileReferenceMention(
        '[draft]',
        directory: true,
        drill: true,
      )!;
      expect(activeReferenceToken(draft(bracketFolder))?.query, '[draft]/');
      expect(
        activeReferenceToken(draft('@[draft]/a.txt'))?.query,
        '[draft]/a.txt',
      );
      final value = draft(
        '😀\n看 @"my docs/rea 后续',
        cursor: '😀\n看 @"my docs/rea'.length,
      );
      final token = activeReferenceToken(value)!;
      expect(token.query, 'my docs/rea');
      expect(token.quoted, isTrue);
      expect(value.text.substring(token.start, token.end), '@"my docs/rea');
      final inserted = replaceReferenceToken(
        value,
        token,
        '@"my docs/read.md"',
      );
      expect(inserted.text, '😀\n看 @"my docs/read.md"  后续');
      expect(inserted.selection.end, '😀\n看 @"my docs/read.md" '.length);
    },
  );

  test(
    'IME composition and noncollapsed selections do not start discovery',
    () {
      expect(
        activeReferenceToken(
          draft('@file').copyWith(composing: const TextRange(start: 1, end: 5)),
        ),
        isNull,
      );
      expect(
        activeReferenceToken(
          draft('@file').copyWith(
            selection: const TextSelection(baseOffset: 1, extentOffset: 3),
          ),
        ),
        isNull,
      );
    },
  );

  test('directory drill keeps quote open, settled folder and file are complete tokens', () {
    expect(
      fileReferenceMention('my docs', directory: true, drill: true),
      '@"my docs/',
    );
    expect(fileReferenceMention('my docs', directory: true), '@"my docs/"');
    expect(
      fileReferenceMention('src', directory: true, quoted: true, drill: true),
      '@"src/',
    );
    expect(fileReferenceMention('notes.md', directory: false), '@notes.md');
    expect(fileReferenceMention('bad"name', directory: false), isNull);
    expect(fileReferenceMention('line\nbreak', directory: false), isNull);
  });

  test(
    'host order preserved within files, child agents, and other sessions',
    () {
      final rows = referenceCandidates(
        found(
          files: [
            {'path': 'src', 'kind': 'directory'},
            {'path': 'README.md', 'kind': 'file'},
          ],
          sessions: [
            {
              'sessionId': 'other',
              'label': '其他会话',
              'mention': '@[其他会话](dsh-session:Im90aGVyIg)',
              'sameWorkspace': false,
              'cwd': '/other',
            },
            {
              'sessionId': 'child',
              'label': 'fallback',
              'displayTitle': '子任务',
              'mention': '@[子任务](dsh-session:ImNoaWxkIg)',
              'sameWorkspace': true,
            },
          ],
        ),
        token: activeReferenceToken(draft('@'))!,
        sessionId: 'current',
        sessions: [
          {
            'header': {'id': 'child'},
            'origin': 'subagent',
            'parentId': 'current',
          },
        ],
      );
      expect(rows.map((r) => r.label), ['src/', 'README.md', '子任务', '其他会话']);
      expect(rows[2].location, isNull);
      expect(rows[3].location, '/other');
    },
  );

  testWidgets(
    'rapid query edits coalesce; late cancelled result cannot replace current candidates',
    (tester) async {
      final runtime = ReferenceRuntime();
      final calls = <Completer<dynamic>>[];
      runtime.read = (_) {
        final call = Completer<dynamic>();
        calls.add(call);
        return call.future;
      };
      var prepared = 0;
      final controller = ReferenceDiscoveryController(
        runtime,
        'one',
        prepare: () async {
          prepared++;
        },
      );
      controller.update(draft('@a'));
      await tester.pump(const Duration(milliseconds: 160));
      controller.update(draft('@b'));
      controller.update(draft('@be'));
      await tester.pump(const Duration(milliseconds: 160));
      expect(calls.length, 2);
      expect(prepared, 1);
      expect(
        runtime.requests.where((r) => r.$1 == 'references.cancel').length,
        1,
      );
      calls[1].complete(
        found(
          files: [
            {'path': 'beta.md', 'kind': 'file'},
          ],
        ),
      );
      await tester.pump();
      calls[0].complete(
        found(
          files: [
            {'path': 'alpha.md', 'kind': 'file'},
          ],
        ),
      );
      await tester.pump();
      expect(controller.candidates.single.path, 'beta.md');
      expect(runtime.requests.last.$2['sessionId'], 'one');
      controller.dispose();
      runtime.dispose();
    },
  );

  testWidgets(
    'disconnect during preparation requires a fresh generation before issuing a query',
    (tester) async {
      final runtime = ReferenceRuntime();
      final prepares = <Completer<void>>[];
      final controller = ReferenceDiscoveryController(
        runtime,
        'one',
        prepare: () {
          final result = Completer<void>();
          prepares.add(result);
          return result.future;
        },
      );
      controller.update(draft('@'));
      await tester.pump(const Duration(milliseconds: 160));
      runtime.reconnect('starting');
      runtime.reconnect('ready');
      await tester.pump(const Duration(milliseconds: 160));
      expect(prepares.length, 2);
      prepares[0].complete();
      await tester.pump();
      expect(runtime.requests, isEmpty);
      prepares[1].complete();
      await tester.pump();
      expect(runtime.requests.single.$1, 'references.list');
      controller.dispose();
      runtime.dispose();
    },
  );

  testWidgets(
    'dispose cancels pending query and rejects late UI publications',
    (tester) async {
      final runtime = ReferenceRuntime();
      final result = Completer<dynamic>();
      runtime.read = (_) => result.future;
      final controller = ReferenceDiscoveryController(
        runtime,
        'one',
        prepare: () async {},
      );
      controller.update(draft('@'));
      await tester.pump(const Duration(milliseconds: 160));
      controller.dispose();
      result.complete(
        found(
          files: [
            {'path': 'old', 'kind': 'file'},
          ],
        ),
      );
      await tester.pump();
      expect(controller.candidates, isEmpty);
      expect(runtime.requests.last.$1, 'references.cancel');
      runtime.dispose();
    },
  );

  testWidgets(
    'folder chevron browses in place; selecting a file only edits the composer draft',
    (tester) async {
      final runtime = ReferenceRuntime();
      runtime.read = (p) async => found(
        files: p['query'] == ''
            ? [
                {'kind': 'directory', 'path': 'my docs'},
              ]
            : [
                {'kind': 'file', 'path': 'my docs/read.md'},
              ],
      );
      final input = TextEditingController();
      final focus = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                ComposerReferenceSuggestions(
                  runtime: runtime,
                  sessionId: 'one',
                  input: input,
                  focus: focus,
                  prepare: () async {},
                ),
                TextField(controller: input, focusNode: focus),
              ],
            ),
          ),
        ),
      );
      focus.requestFocus();
      input.value = draft('@');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('my docs/'), findsOneWidget);
      await tester.tap(find.byTooltip('浏览 my docs/'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(input.text, '@"my docs/');
      expect(find.text('工作区'), findsOneWidget);
      await tester.tap(find.text('read.md'));
      await tester.pumpAndSettle();
      expect(input.text, '@"my docs/read.md" ');
      expect(find.text('引用文件或会话'), findsNothing);
      expect(
        runtime.requests.every((r) => r.$1.startsWith('references.')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      input.dispose();
      focus.dispose();
      runtime.dispose();
    },
  );
}
