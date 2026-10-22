import 'dart:async';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;

Widget host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: PocketScaffold(title: const Text('会话'), body: child),
);

Iterable<TextSpan> spans(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* spans(child);
  }
}

TextSpan label(WidgetTester tester, String text) {
  final selectable = tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  );
  for (final widget in selectable) {
    if (widget.textSpan?.toPlainText() == text) return widget.textSpan!;
  }
  return tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((widget) => widget.text.toPlainText() == text)
          .text
      as TextSpan;
}

void main() {
  test('original Markdown fixtures retain Session paths and first line', () {
    final cases = <String, (String, int?)>{
      'src/index.ts': ('src/index.ts', null),
      '/workspace/src/index.ts#L24': ('/workspace/src/index.ts', 24),
      '../docs/My%20Notes.md#L24-L30': ('../docs/My Notes.md', 24),
      'C:/work/file.ts#L2': ('C:/work/file.ts', 2),
      'C:%5Cwork%5Cfile.ts': (r'C:\work\file.ts', null),
      'docs/%E4%B8%AD%E6%96%87.md': ('docs/中文.md', null),
      'file%23name%3F.txt': ('file#name?.txt', null),
      './docs/../a+b%2520.txt': ('./docs/../a+b%20.txt', null),
      'file.ts#L9007199254740991': ('file.ts', 9007199254740991),
    };
    for (final entry in cases.entries) {
      final result = chatFileLink(entry.key, sessionId: 'current')!;
      expect(
        (result.sessionId, result.path, result.line),
        ('current', entry.value.$1, entry.value.$2),
        reason: entry.key,
      );
    }
  });

  test(
    'original Markdown grammar rejects schemes, UNC, invalid lines and escapes',
    () {
      for (final destination in [
        '//example.com/file',
        '%2F%2Fexample.com/file',
        '%5C%5Cserver%5Cfile',
        'javascript:alert',
        'data:text/plain,hi',
        'file:///etc/passwd',
        'vscode:open',
        '%6Aavascript:alert',
        'content://documents/x',
        'intent://x',
        '#L2',
        'file.ts?raw=1',
        'file%ZZ.ts',
        'file%00.ts',
        'file%FF.ts',
        'file.ts#heading',
        'file.ts#L0',
        'file.ts#L3-L2',
        'file.ts#L9007199254740992',
        'file.ts#L1-L9007199254740992',
        'https://example.com/a.pdf',
        'http://example.com/a.pdf',
      ]) {
        expect(
          chatFileLink(destination, sessionId: 'current'),
          isNull,
          reason: destination,
        );
      }
    },
  );

  test(
    'resource grammar preserves segments and only binds the current Session',
    () {
      const prefix = 'dsh-resource://file/session/my%2Fsession/';
      final result = chatFileLink(
        '$prefix./docs/../a%2520%23%3F.txt?ignored=%ZZ#L9',
        sessionId: 'my/session',
      )!;
      expect(result.sessionId, 'my/session');
      expect(result.path, './docs/../a%20#?.txt');
      expect(result.line, isNull);
      expect(
        chatFileLink('$prefix/var/data.pdf', sessionId: 'my/session')!.path,
        '/var/data.pdf',
      );
      for (final destination in [
        '${prefix}report.pdf',
        'dsh-resource://file/absolute/etc/passwd',
        'dsh-resource://file/session/current',
        'dsh-resource://file/session//file',
        'DSH-RESOURCE://file/session/current/file',
        'dsh-resource://File/session/current/file',
        'dsh-resource://file/session/current/file%ZZ',
        'dsh-resource://file/session/current/file%FF',
      ]) {
        expect(
          chatFileLink(destination, sessionId: 'current'),
          isNull,
          reason: destination,
        );
      }
    },
  );

  testWidgets(
    'Markdown paths, line ranges, resources and web links dispatch separately',
    (tester) async {
      final files = <ChatFileLink>[];
      final web = <Uri>[];
      await tester.pumpWidget(
        host(
          PocketMarkdown(
            sessionId: 'a',
            selectable: false,
            data:
                '[本地](../docs/My%20Notes.md#L24-L30)\n\n'
                '[资源](dsh-resource://file/session/a/./docs/../report.pdf)\n\n'
                '[网站](https://example.com/report.pdf)',
            onOpenFile: (file) async => files.add(file),
            onOpenLink: (uri) async => web.add(uri),
          ),
        ),
      );
      for (final title in ['本地', '资源', '网站']) {
        await tester.tap(find.text(title, findRichText: true).last);
        await tester.pump();
      }
      expect(files.map((file) => (file.sessionId, file.path, file.line)), [
        ('a', '../docs/My Notes.md', 24),
        ('a', './docs/../report.pdf', null),
      ]);
      expect(web.single.toString(), 'https://example.com/report.pdf');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable file links keep nested labels without link styling or gestures',
    (tester) async {
      await tester.pumpWidget(
        host(
          PocketMarkdown(
            sessionId: 'a',
            selectable: false,
            data:
                '[**粗体** *斜体* `code` ![图示](image.png)](notes.md)\n\n'
                '[跨会话](dsh-resource://file/session/b/report.pdf)\n\n'
                '[网站](https://example.com)',
            onOpenLink: (_) async {},
          ),
        ),
      );
      final local = spans(label(tester, '粗体 斜体 code 图示')).toList();
      expect(local.every((span) => span.recognizer == null), true);
      expect(
        local.any((span) => span.style?.fontWeight == FontWeight.w700),
        true,
      );
      expect(
        local.any((span) => span.style?.fontStyle == FontStyle.italic),
        true,
      );
      expect(local.any((span) => span.style?.fontFamily == 'monospace'), true);
      expect(
        local.any((span) => span.style?.decoration == TextDecoration.underline),
        false,
      );
      expect(
        spans(label(tester, '跨会话')).every((span) => span.recognizer == null),
        true,
      );
      expect(
        spans(label(tester, '网站')).any((span) => span.recognizer != null),
        true,
      );
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('file links remain inline with surrounding paragraph text', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        PocketMarkdown(
          sessionId: 'a',
          selectable: false,
          data: '请阅读 [**说明** 和 `source`](notes.md) 后继续。',
          onOpenFile: (_) async {},
        ),
      ),
    );
    final paragraph = label(tester, '请阅读 说明 和 source 后继续。');
    expect(spans(paragraph).any((span) => span.recognizer != null), true);
    expect(
      spans(paragraph).any((span) => span.style?.fontFamily == 'monospace'),
      true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('streaming file text becomes actionable only after settlement', (
    tester,
  ) async {
    final files = <ChatFileLink>[];
    final projection = ChatProjection();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    const data = '[结果](report.pdf)';
    Widget view({required bool streaming}) => host(
      ChatTimeline(
        sessionId: 'a',
        projection: projection,
        controller: scroll,
        onOpenFile: (file) async => files.add(file),
        live: streaming
            ? const ChatLiveMessage(
                identity: 'request',
                turn: 1,
                step: 1,
                content: [
                  {'type': 'text', 'text': data},
                ],
              )
            : null,
      ),
    );
    await tester.pumpWidget(view(streaming: true));
    expect(
      spans(label(tester, '结果')).every((span) => span.recognizer == null),
      true,
    );
    projection.reconcile([fixture.assistant(0, data)]);
    await tester.pumpWidget(view(streaming: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结果', findRichText: true).last);
    await tester.pump();
    expect(files.single.sessionId, 'a');
    expect(files.single.path, 'report.pdf');
  });

  testWidgets('same text updates its opener availability and Session binding', (
    tester,
  ) async {
    final files = <ChatFileLink>[];
    Widget view(String session, {required bool enabled}) => host(
      PocketMarkdown(
        data: '[结果](report.pdf)',
        sessionId: session,
        selectable: false,
        onOpenFile: enabled ? (file) async => files.add(file) : null,
      ),
    );
    await tester.pumpWidget(view('a', enabled: false));
    expect(
      spans(label(tester, '结果')).every((span) => span.recognizer == null),
      true,
    );
    await tester.pumpWidget(view('a', enabled: true));
    await tester.tap(find.text('结果', findRichText: true).last);
    await tester.pumpWidget(view('b', enabled: true));
    await tester.tap(find.text('结果', findRichText: true).last);
    await tester.pump();
    expect(files.map((file) => file.sessionId), ['a', 'b']);
  });

  testWidgets(
    'opening failures from an old Session do not appear in a replacement',
    (tester) async {
      final pending = Completer<void>();
      Widget view(String session) => host(
        PocketMarkdown(
          data: '[结果](report.pdf)',
          sessionId: session,
          selectable: false,
          onOpenFile: (_) => pending.future,
        ),
      );
      await tester.pumpWidget(view('a'));
      await tester.tap(find.text('结果', findRichText: true).last);
      await tester.pumpWidget(view('b'));
      pending.completeError(StateError('old reader failure'));
      await tester.pump();
      expect(find.text('链接打开失败，请重试。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
