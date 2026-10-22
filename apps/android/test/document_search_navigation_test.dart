import 'package:dsh_android/document_search.dart';
import 'package:dsh_android/files.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _SearchRuntime extends RuntimeController {
  _SearchRuntime(this.path) {
    phase = 'ready';
  }

  final String path;
  final calls = <({String method, Json params})>[];
  Object? readError;
  int generation = 1;

  @override
  int get connectionGeneration => generation;

  void invalidate({required bool replace}) {
    if (replace) {
      generation++;
    } else {
      phase = 'stopped';
    }
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: Map.of(params)));
    switch (method) {
      case 'documents.search':
        return {
          'matches': [
            {
              'path': path,
              'lineNumber': 27,
              'line': '中文🙂命中片段',
              'previewTruncated': true,
            },
          ],
          'skipped': <Json>[],
          'complete': true,
          'scannedFiles': 1,
          'bytesRead': 123,
        };
      case 'documents.read':
        if (readError != null) throw readError!;
        return {
          'text': '从文件开头读取的当前内容',
          'offset': 0,
          'nextOffset': 39,
          'truncated': false,
        };
      default:
        throw StateError('Unexpected $method');
    }
  }
}

Widget _host(
  _SearchRuntime runtime, {
  String path = '',
  String name = '授权目录',
}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: DocumentSearchPage(
    runtime: runtime,
    root: 'a' * 64,
    path: path,
    name: name,
  ),
);

Future<void> _search(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '中文🙂');
  await tester.tap(find.text('搜索'));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String title) async {
  await _showHit(tester, title);
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

Future<void> _showHit(WidgetTester tester, String title) async {
  final hit = find.text(title);
  await tester.scrollUntilVisible(
    hit,
    240,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  // Content scrolls behind floating chrome. Center the row before tapping it.
  await Scrollable.ensureVisible(tester.element(hit), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _backToSearch(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(TextFilePage))).pop();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'opening a nested Unicode hit uses the original grant and root-relative path',
    (tester) async {
      final runtime = _SearchRuntime('notes/中文/说明.txt');
      addTearDown(runtime.dispose);
      final nativeCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          nativeCalls.add(call.method);
          throw StateError('Search navigation must not open a picker');
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(runtime, path: 'notes/中文'));
      await tester.pumpAndSettle();
      await _search(tester);
      expect(find.text('点开结果可从头阅读当前文件；搜索行号不会自动定位。'), findsOneWidget);
      await _open(tester, runtime.path);

      final page = tester.widget<TextFilePage>(find.byType(TextFilePage));
      expect(page.root, 'a' * 64);
      expect(page.path, 'notes/中文/说明.txt');
      expect(page.name, '说明.txt');
      expect(runtime.calls.last.params, {
        'root': 'a' * 64,
        'path': 'notes/中文/说明.txt',
        'offset': 0,
      });
      expect(find.text('从文件开头读取的当前内容'), findsOneWidget);

      await _backToSearch(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '中文🙂',
      );
      expect(find.text('中文🙂命中片段'), findsOneWidget);
      expect(runtime.calls.map((call) => call.method), [
        'documents.search',
        'documents.read',
      ]);
      expect(nativeCalls, isEmpty);
    },
  );

  testWidgets('single-file grant hit keeps the empty relative path', (
    tester,
  ) async {
    final runtime = _SearchRuntime('');
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime, name: '单独授权.txt'));
    await tester.pumpAndSettle();
    await _search(tester);
    await _open(tester, '单独授权.txt');

    final page = tester.widget<TextFilePage>(find.byType(TextFilePage));
    expect(page.path, '');
    expect(page.name, '单独授权.txt');
    expect(runtime.calls.last.params, {
      'root': 'a' * 64,
      'path': '',
      'offset': 0,
    });
    expect(runtime.calls.map((call) => call.method), [
      'documents.search',
      'documents.read',
    ]);
  });

  for (final replace in [true, false]) {
    testWidgets(
      '${replace ? 'same-ready replacement' : 'disconnect'} disables opening a retained hit',
      (tester) async {
        final runtime = _SearchRuntime('notes/旧结果.txt');
        addTearDown(runtime.dispose);
        await tester.pumpWidget(_host(runtime));
        await tester.pumpAndSettle();
        await _search(tester);
        runtime.invalidate(replace: replace);
        await tester.pumpAndSettle();

        await _showHit(tester, runtime.path);
        final row = tester.widget<PocketTile>(
          find.ancestor(
            of: find.text(runtime.path),
            matching: find.byType(PocketTile),
          ),
        );
        expect(row.onTap, isNull);
        await tester.tap(find.text(runtime.path));
        await tester.pumpAndSettle();
        expect(find.byType(TextFilePage), findsNothing);
        expect(find.text('中文🙂命中片段'), findsOneWidget);
        expect(runtime.calls.map((call) => call.method), ['documents.search']);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '中文🙂',
        );
      },
    );
  }

  for (final failure in ['文件授权不存在或已撤销，请重新授权', '文件已移动或删除']) {
    testWidgets('opening a hit reports $failure and preserves the search', (
      tester,
    ) async {
      final runtime = _SearchRuntime('notes/记录.txt')
        ..readError = StateError(failure);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      await _search(tester);
      await _open(tester, runtime.path);
      expect(find.textContaining(failure), findsOneWidget);
      expect(find.text('重试读取'), findsOneWidget);
      expect(find.text('从文件开头读取的当前内容'), findsNothing);

      await _backToSearch(tester);
      expect(find.text('中文🙂命中片段'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '中文🙂',
      );
      expect(runtime.calls.map((call) => call.method), [
        'documents.search',
        'documents.read',
      ]);
    });
  }
}
