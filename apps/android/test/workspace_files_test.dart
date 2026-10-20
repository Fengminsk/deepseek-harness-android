import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/workspace_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const workspaceRoot =
    '/data/user/0/com.minnnng.dsh_android/no_backup/dsh/workspace';

Json listing(
  String path, {
  List<Json>? entries,
  String version = 'directory-1',
  int? nextOffset,
}) => {
  'root': workspaceRoot,
  'path': path,
  'version': version,
  'offset': 0,
  'entries':
      entries ??
      [
        if (path.isEmpty) ...[
          {'name': 'notes', 'path': 'notes', 'kind': 'directory'},
          {
            'name': 'escape',
            'path': 'escape',
            'kind': 'link',
            'blockedReason': 'symlink',
          },
        ] else
          {
            'name': 'report.txt',
            'path': 'notes/report.txt',
            'kind': 'file',
            'bytes': 20,
          },
      ],
  'nextOffset': nextOffset,
  'truncated': false,
  'listedEntries': entries?.length ?? 2,
};

Json textPage({
  String path = 'notes/report.txt',
  int offset = 0,
  int next = 20,
  bool eof = true,
  String text = '工作区报告',
  String version = 'file-1',
}) => {
  'root': workspaceRoot,
  'path': path,
  'version': version,
  'bytes': 20,
  'offset': offset,
  'nextOffset': next,
  'eof': eof,
  'text': text,
};

Json results({
  bool complete = true,
  List<Json> matches = const [],
  List<Json> skipped = const [],
}) => {
  'root': workspaceRoot,
  'path': '',
  'query': 'needle',
  'mode': 'content',
  'matches': matches,
  'skipped': skipped,
  'complete': complete,
  'stoppedBy': complete ? null : 'matches',
  'scanned': {'entries': 2, 'files': 1, 'bytes': 20},
};

class WorkspaceRuntime extends RuntimeController {
  WorkspaceRuntime() {
    phase = 'ready';
  }
  final calls = <(String, Json)>[];
  Future<dynamic> Function(String, Json)? handle;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    if (handle != null) return handle!(method, params);
    return switch (method) {
      'workspace.files.info' => {
        'root': workspaceRoot,
        'limits': {
          'search': {'maxDurationMs': 10000},
        },
      },
      'workspace.files.list' => listing(params['path'] as String),
      'workspace.files.read' => textPage(
        path: params['path'] as String,
        offset: params['offset'] as int,
      ),
      'workspace.files.search' => results(),
      'workspace.files.search.cancel' => {'cancelled': true},
      _ => throw StateError('Unexpected $method'),
    };
  }
}

Future<void> open(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(480, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (_, child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(480, 1100),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'private root, nested directory and text use relative RPC paths and block links',
    (tester) async {
      final runtime = WorkspaceRuntime();
      addTearDown(runtime.dispose);
      await open(tester, WorkspaceFilesPage(runtime: runtime));
      expect(find.text(workspaceRoot), findsOneWidget);
      final link = tester.widget<PocketRow>(
        find.byKey(const ValueKey('workspace-entry-escape')),
      );
      expect(link.onTap, isNull);
      await tap(tester, find.text('notes'));
      expect(runtime.calls.last.$1, 'workspace.files.list');
      expect(runtime.calls.last.$2, {'path': 'notes', 'offset': 0});
      await tap(tester, find.text('report.txt'));
      expect(find.text('工作区报告'), findsOneWidget);
      expect(runtime.calls.last.$1, 'workspace.files.read');
      expect(runtime.calls.last.$2, {'path': 'notes/report.txt', 'offset': 0});
      expect(
        runtime.calls.every((call) => !call.$2.containsKey('root')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'changed directory pagination preserves visible rows and permits a fresh listing',
    (tester) async {
      final runtime = WorkspaceRuntime();
      addTearDown(runtime.dispose);
      var firstReads = 0;
      runtime.handle = (method, params) async {
        if (params['offset'] == 1) {
          throw PlatformException(
            code: 'workspace-files/changed',
            message: '目录已变化，请从头刷新。',
          );
        }
        firstReads++;
        return listing(
          '',
          entries: [
            {
              'name': firstReads == 1 ? 'original.txt' : 'refreshed.txt',
              'path': firstReads == 1 ? 'original.txt' : 'refreshed.txt',
              'kind': 'file',
              'bytes': 4,
            },
          ],
          nextOffset: 1,
          version: 'directory-$firstReads',
        );
      };
      await open(tester, WorkspaceFilesPage(runtime: runtime));
      await tap(tester, find.text('更多目录项目'));
      expect(runtime.calls.last.$2['version'], 'directory-1');
      expect(find.text('original.txt'), findsOneWidget);
      expect(find.text('目录已变化，请从头刷新。'), findsOneWidget);
      expect(find.text('此目录为空。'), findsNothing);
      await tap(tester, find.byTooltip('刷新工作区目录'));
      expect(find.text('refreshed.txt'), findsOneWidget);
      expect(find.text('original.txt'), findsNothing);
      expect(runtime.calls.last.$2.containsKey('version'), isFalse);
      await close(tester);
    },
  );

  testWidgets(
    'failed text continuation preserves the old page and retries its exact version',
    (tester) async {
      final runtime = WorkspaceRuntime();
      addTearDown(runtime.dispose);
      var fail = true;
      runtime.handle = (method, params) async {
        if (params['offset'] == 8 && fail) {
          throw PlatformException(
            code: 'workspace-files/changed',
            message: '文件已变化，旧内容保留。',
          );
        }
        return textPage(
          offset: params['offset'] as int,
          next: params['offset'] == 0 ? 8 : 20,
          eof: params['offset'] != 0,
          text: params['offset'] == 0 ? '第一段' : '第二段',
        );
      };
      await open(
        tester,
        WorkspaceTextPage(runtime: runtime, path: 'notes/report.txt'),
      );
      await tap(tester, find.text('下一段'));
      expect(find.text('第一段'), findsOneWidget);
      expect(find.text('文件已变化，旧内容保留。'), findsOneWidget);
      expect(runtime.calls.last.$2, {
        'path': 'notes/report.txt',
        'offset': 8,
        'version': 'file-1',
      });
      fail = false;
      await tap(tester, find.text('重试读取'));
      expect(find.text('第二段'), findsOneWidget);
      await tap(tester, find.text('上一段'));
      expect(find.text('第一段'), findsOneWidget);
      await tap(tester, find.byTooltip('从头重新读取工作区文件'));
      expect(runtime.calls.last.$2, {'path': 'notes/report.txt', 'offset': 0});
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'content results show incomplete scope and open the matched file version and offset',
    (tester) async {
      final runtime = WorkspaceRuntime();
      addTearDown(runtime.dispose);
      runtime.handle = (method, params) async => switch (method) {
        'workspace.files.info' => {
          'limits': {
            'search': {'maxDurationMs': 10000},
          },
        },
        'workspace.files.search' => results(
          complete: false,
          matches: [
            {
              'path': 'notes/report.txt',
              'name': 'report.txt',
              'kind': 'file',
              'line': 2,
              'offset': 8,
              'version': 'hit-version',
              'preview': 'needle result',
            },
          ],
          skipped: [
            {'path': 'escape', 'reason': 'symlink'},
          ],
        ),
        'workspace.files.read' => textPage(
          offset: 8,
          text: 'needle result',
          version: 'hit-version',
        ),
        _ => throw StateError('Unexpected $method'),
      };
      await open(tester, WorkspaceSearchPage(runtime: runtime));
      await tester.enterText(
        find.byKey(const Key('workspace-search-query')),
        'needle',
      );
      await tap(tester, find.text('文本内容'));
      await tap(tester, find.byKey(const Key('workspace-start-search')));
      final request = runtime.calls
          .singleWhere((call) => call.$1 == 'workspace.files.search')
          .$2;
      expect(request['mode'], 'content');
      expect(request['path'], '');
      expect(request['requestId'], isA<String>());
      expect(find.textContaining('搜索范围未全部检查'), findsOneWidget);
      expect(find.text('符号链接不在此入口的读取范围内'), findsOneWidget);
      await tap(tester, find.text('notes/report.txt'));
      expect(runtime.calls.last.$2, {
        'path': 'notes/report.txt',
        'offset': 8,
        'version': 'hit-version',
      });
      expect(find.text('needle result'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'search waits for confirmed cancellation and ignores a late result',
    (tester) async {
      final runtime = WorkspaceRuntime();
      addTearDown(runtime.dispose);
      final search = Completer<Json>(), cancelled = Completer<Json>();
      runtime.handle = (method, params) async => switch (method) {
        'workspace.files.info' => {
          'limits': {
            'search': {'maxDurationMs': 10000},
          },
        },
        'workspace.files.search' => search.future,
        'workspace.files.search.cancel' => cancelled.future,
        _ => throw StateError('Unexpected $method'),
      };
      await open(tester, WorkspaceSearchPage(runtime: runtime));
      await tester.enterText(
        find.byKey(const Key('workspace-search-query')),
        'needle',
      );
      await tap(tester, find.byKey(const Key('workspace-start-search')));
      await tap(tester, find.byKey(const Key('workspace-stop-search')));
      expect(find.text('正在停止…'), findsOneWidget);
      expect(find.text('搜索已停止，未完成整个范围的检查。'), findsNothing);
      cancelled.complete({'cancelled': true});
      await tester.pumpAndSettle();
      expect(find.text('搜索已停止，未完成整个范围的检查。'), findsOneWidget);
      search.complete(
        results(
          matches: [
            {'path': 'late.txt', 'name': 'late.txt', 'kind': 'file'},
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('late.txt'), findsNothing);
      final sent = runtime.calls
          .singleWhere((call) => call.$1 == 'workspace.files.search')
          .$2;
      expect(
        runtime.calls
            .singleWhere((call) => call.$1 == 'workspace.files.search.cancel')
            .$2,
        {'requestId': sent['requestId']},
      );
      expect(find.text('needle'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'old directory replies cannot overwrite a restarted runtime result',
    (tester) async {
      final runtime = WorkspaceRuntime();
      addTearDown(runtime.dispose);
      final old = Completer<Json>();
      var reads = 0;
      runtime.handle = (_, _) async => reads++ == 0
          ? old.future
          : listing(
              '',
              entries: [
                {
                  'name': 'current.txt',
                  'path': 'current.txt',
                  'kind': 'file',
                  'bytes': 1,
                },
              ],
            );
      await open(tester, WorkspaceFilesPage(runtime: runtime));
      runtime.phase = 'starting';
      runtime.notifyListeners();
      runtime.phase = 'ready';
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      old.complete(
        listing(
          '',
          entries: [
            {
              'name': 'stale.txt',
              'path': 'stale.txt',
              'kind': 'file',
              'bytes': 1,
            },
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('current.txt'), findsOneWidget);
      expect(find.text('stale.txt'), findsNothing);
      await close(tester);
    },
  );
}
