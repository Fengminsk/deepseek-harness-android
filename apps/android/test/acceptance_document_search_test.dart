import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dsh_android/document_search.dart';
import 'package:dsh_android/files.dart';

class SearchRuntime extends RuntimeController {
  SearchRuntime() {
    phase = 'ready';
  }
  int generation = 1;
  @override
  int get connectionGeneration => generation;
  void replaceConnection() {
    generation++;
    notifyListeners();
  }

  Future<dynamic> Function(String, Json)? handle;
  final calls = <Json>[];
  Completer<Json>? runGate, cancelGate;
  bool failSearch = false;
  Json response = {
    'matches': <Json>[],
    'skipped': <Json>[],
    'complete': true,
    'scannedFiles': 1,
    'bytesRead': 123,
  };
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add({'method': method, 'params': params});
    if (handle != null) return handle!(method, params);
    if (method == 'documents.roots') {
      return [
        {
          'id': 'a' * 64,
          'name': '笔记.txt',
          'directory': false,
          'available': true,
        },
      ];
    }
    if (method == 'documents.list') return <Json>[];
    if (method == 'documents.search.cancel') {
      return cancelGate?.future ?? {'cancelled': true};
    }
    if (method == 'documents.search') {
      if (failSearch) throw StateError('grant revoked');
      return runGate?.future ?? response;
    }
    throw StateError('unexpected $method');
  }
}

Widget host(SearchRuntime runtime, {double scale = 1}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: DocumentSearchPage(
    runtime: runtime,
    root: 'a' * 64,
    path: '子目录',
    name: '已授权目录',
  ),
);

Future<void> submit(WidgetTester tester, [String query = '中文🙂']) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.tap(find.text('搜索', findRichText: false));
  await tester.pump();
}

void main() {
  testWidgets('late failed-search stop cannot replace a newer search state', (
    tester,
  ) async {
    final runtime = SearchRuntime();
    addTearDown(runtime.dispose);
    final oldStop = Completer<Json>(), nextSearch = Completer<Json>();
    var searches = 0, stops = 0;
    runtime.handle = (method, _) async {
      if (method == 'documents.search') {
        if (++searches == 1) throw StateError('old search failed');
        return nextSearch.future;
      }
      if (++stops == 1) return oldStop.future;
      return {'cancelled': true};
    };
    await tester.pumpWidget(host(runtime));
    await tester.pumpAndSettle();
    try {
      await submit(tester, '旧查询');
      await tester.pumpAndSettle();
      expect(stops, 1);
      await tester.tap(find.text('停止搜索'));
      await tester.pumpAndSettle();
      await submit(tester, '新查询');
      await tester.pumpAndSettle();
      oldStop.complete({'cancelled': true});
      await tester.pumpAndSettle();
      expect(find.textContaining('old search failed'), findsNothing);
      expect(find.text('正在搜索…'), findsOneWidget);
      expect(searches, 2);
      nextSearch.complete(runtime.response);
      await tester.pumpAndSettle();
      expect(find.text('“新查询” · 0 条匹配行'), findsOneWidget);
    } finally {
      if (!oldStop.isCompleted) oldStop.complete({'cancelled': true});
      if (!nextSearch.isCompleted) nextSearch.complete(runtime.response);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'same-ready replacement preserves query and suppresses previous search and stop receipts',
    (tester) async {
      final runtime = SearchRuntime()
        ..runGate = Completer<Json>()
        ..cancelGate = Completer<Json>();
      addTearDown(runtime.dispose);
      final oldSearch = runtime.runGate!, oldStop = runtime.cancelGate!;
      await tester.pumpWidget(host(runtime));
      await tester.pumpAndSettle();
      try {
        await submit(tester, '保留查询');
        await tester.tap(find.text('停止搜索'));
        await tester.pump();
        runtime.replaceConnection();
        await tester.pumpAndSettle();
        expect(find.textContaining('这不表示搜索已停止'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留查询',
        );
        expect(
          runtime.calls.where((call) => call['method'] == 'documents.search'),
          hasLength(1),
        );
        runtime.runGate = null;
        runtime.cancelGate = null;
        await tester.tap(find.text('搜索'));
        await tester.pumpAndSettle();
        oldSearch.complete({
          ...runtime.response,
          'matches': [
            {'path': 'old.txt', 'lineNumber': 1, 'line': '不得回填'},
          ],
        });
        oldStop.complete({'cancelled': true});
        await tester.pumpAndSettle();
        expect(find.text('不得回填'), findsNothing);
        expect(find.text('搜索已取消，没有完成整个范围的检查。'), findsNothing);
        expect(find.text('本次范围已查完，没有匹配。'), findsOneWidget);
      } finally {
        if (!oldSearch.isCompleted) oldSearch.complete(runtime.response);
        if (!oldStop.isCompleted) oldStop.complete({'cancelled': true});
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );
  testWidgets(
    'single document grant search opens without picking a wider directory',
    (tester) async {
      final runtime = SearchRuntime();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: FilesPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('search-${'a' * 64}')));
      await tester.pumpAndSettle();
      final page = tester.widget<DocumentSearchPage>(
        find.byType(DocumentSearchPage),
      );
      expect(page.root, 'a' * 64);
      expect(page.path, '');
      await submit(tester);
      await tester.pumpAndSettle();
      expect(
        runtime.calls
            .where((call) => call['method'] == 'documents.search')
            .single['params']['path'],
        '',
      );
    },
  );

  testWidgets('directory search keeps the currently selected relative scope', (
    tester,
  ) async {
    final runtime = SearchRuntime();
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: FilesPage(runtime: runtime, root: 'a' * 64, path: 'notes/中文'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索此目录的文字'));
    await tester.pumpAndSettle();
    final page = tester.widget<DocumentSearchPage>(
      find.byType(DocumentSearchPage),
    );
    expect(page.path, 'notes/中文');
  });

  testWidgets(
    'back navigation waits for stopped acknowledgement before leaving the page',
    (tester) async {
      final runtime = SearchRuntime()
        ..runGate = Completer<Json>()
        ..cancelGate = Completer<Json>();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: Builder(
            builder: (context) => PocketButton(
              onPressed: () => Navigator.of(context).push(
                PocketRoute(
                  builder: (_) => DocumentSearchPage(
                    runtime: runtime,
                    root: 'a' * 64,
                    name: '笔记.txt',
                  ),
                ),
              ),
              child: const Text('打开搜索'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开搜索'));
      await tester.pumpAndSettle();
      await submit(tester);
      final context = tester.element(find.byType(DocumentSearchPage));
      unawaited(Navigator.of(context).maybePop());
      await tester.pump();
      expect(find.byType(DocumentSearchPage), findsOneWidget);
      expect(find.text('正在停止…'), findsOneWidget);
      runtime.cancelGate!.complete({'cancelled': true});
      await tester.pumpAndSettle();
      expect(find.byType(DocumentSearchPage), findsNothing);
      runtime.runGate!.complete(runtime.response);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'literal query preserves grant scope and reports a completed empty search',
    (tester) async {
      final runtime = SearchRuntime();
      await tester.pumpWidget(host(runtime));
      await tester.pumpAndSettle();
      await submit(tester, 'a.b');
      await tester.pumpAndSettle();
      final call = runtime.calls.first;
      expect(call['params']['root'], 'a' * 64);
      expect(call['params']['path'], '子目录');
      expect(call['params']['query'], 'a.b');
      expect(call['params']['owner'], isNull);
      expect(find.text('本次范围已查完，没有匹配。'), findsOneWidget);
    },
  );

  testWidgets(
    'binary and capped scans never claim no matches in the whole scope',
    (tester) async {
      final runtime = SearchRuntime()
        ..response = {
          'matches': <Json>[],
          'skipped': [
            {'path': 'data.bin', 'reason': 'binary'},
          ],
          'complete': false,
          'scannedFiles': 1,
          'bytesRead': 1024,
          'stoppedReason': 'total_bytes',
        };
      await tester.pumpWidget(host(runtime));
      await tester.pumpAndSettle();
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.text('本次范围已查完，没有匹配。'), findsNothing);
      expect(find.text('本次只完成了部分检查，不能据此判断其余文件没有匹配。'), findsOneWidget);
      expect(find.text('达到总读取字节上限'), findsOneWidget);
    },
  );

  testWidgets(
    'revoked read fails visibly and preserves typed query for retry',
    (tester) async {
      final runtime = SearchRuntime()..failSearch = true;
      await tester.pumpWidget(host(runtime));
      await tester.pumpAndSettle();
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('查询内容已保留'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '中文🙂',
      );
      runtime.failSearch = false;
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('本次范围已查完，没有匹配。'), findsOneWidget);
    },
  );

  testWidgets(
    'cancel waits for native acknowledgement and suppresses late result',
    (tester) async {
      final runtime = SearchRuntime()
        ..runGate = Completer<Json>()
        ..cancelGate = Completer<Json>();
      await tester.pumpWidget(host(runtime));
      await tester.pumpAndSettle();
      await submit(tester);
      await tester.tap(find.text('停止搜索'));
      await tester.pump();
      expect(find.text('正在停止…'), findsOneWidget);
      expect(find.textContaining('搜索已取消'), findsNothing);
      runtime.runGate!.complete(runtime.response);
      await tester.pump();
      expect(find.text('本次范围已查完，没有匹配。'), findsNothing);
      runtime.cancelGate!.complete({'cancelled': true});
      await tester.pumpAndSettle();
      expect(find.text('搜索已取消，没有完成整个范围的检查。'), findsOneWidget);
    },
  );

  testWidgets(
    'a provider that has not stopped stays actionable and blocks new search',
    (tester) async {
      final runtime = SearchRuntime()
        ..runGate = Completer<Json>()
        ..cancelGate = Completer<Json>();
      await tester.pumpWidget(host(runtime));
      await tester.pumpAndSettle();
      await submit(tester);
      await tester.tap(find.text('停止搜索'));
      runtime.cancelGate!.complete({'cancelled': false, 'stopping': true});
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未确认搜索已停止'), findsOneWidget);
      expect(find.text('停止搜索'), findsOneWidget);
      final start = tester.widget<PocketButton>(
        find.ancestor(
          of: find.text('正在搜索…'),
          matching: find.byType(PocketButton),
        ),
      );
      expect(start.onPressed, isNull);
      runtime.cancelGate = null;
      await tester.tap(find.text('停止搜索'));
      await tester.pumpAndSettle();
      runtime.runGate!.complete(runtime.response);
      await tester.pumpAndSettle();
      expect(find.text('本次范围已查完，没有匹配。'), findsNothing);
    },
  );

  testWidgets(
    'large system font and narrow viewport keep search controls reachable',
    (tester) async {
      final runtime = SearchRuntime();
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host(runtime, scale: 2));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('搜索'));
      expect(tester.takeException(), isNull);
    },
  );
}
