import 'dart:async';

import 'package:dsh_android/files.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FilesRuntime extends RuntimeController {
  _FilesRuntime() {
    phase = 'ready';
  }

  final grants = <Json>[
    {'id': 'file-id', 'name': '笔记.txt', 'directory': false, 'available': true},
  ];
  final reads = <Json>[];
  final revocations = <String>[];
  bool failNextPage = false;
  bool failFirstPage = false;
  Completer<Json>? readBarrier;
  Completer<List<Json>>? rootsBarrier;
  Object? rootsError;
  int generation = 1;
  @override
  int get connectionGeneration => generation;
  void replaceConnection() {
    generation++;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'documents.roots') {
      if (rootsError != null) throw rootsError!;
      if (rootsBarrier != null) return rootsBarrier!.future;
      return grants.map((entry) => Json.from(entry)).toList();
    }
    if (method == 'documents.revoke') {
      revocations.add(params['root'] as String);
      grants.removeWhere((entry) => entry['id'] == params['root']);
      return {'revoked': true};
    }
    if (method == 'documents.read') {
      reads.add(Json.from(params));
      if (readBarrier != null) return readBarrier!.future;
      if (params['offset'] == 0) {
        if (failFirstPage) {
          throw PlatformException(
            code: 'document-unavailable',
            message: '授权已撤销',
          );
        }
        return {
          'text': '第一段中文🙂',
          'offset': 0,
          'nextOffset': 19,
          'truncated': true,
        };
      }
      if (failNextPage) {
        throw PlatformException(
          code: 'provider-unavailable',
          message: '文件提供方暂不可用',
        );
      }
      return {
        'text': '第二段',
        'offset': 19,
        'nextOffset': 28,
        'truncated': false,
      };
    }
    throw StateError('Unexpected call $method $params');
  }
}

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'same-ready replacement discards old granted roots and reloads the current list',
    (tester) async {
      final runtime = _FilesRuntime();
      addTearDown(runtime.dispose);
      final older = Completer<List<Json>>();
      runtime.rootsBarrier = older;
      await tester.pumpWidget(_host(FilesPage(runtime: runtime)));
      await tester.pumpAndSettle();
      try {
        runtime.grants.clear();
        runtime.rootsBarrier = null;
        runtime.replaceConnection();
        await tester.pumpAndSettle();
        expect(find.textContaining('这里还没有文件'), findsOneWidget);
        older.complete([
          {'id': 'old', 'name': '已撤销.txt', 'directory': false},
        ]);
        await tester.pumpAndSettle();
        expect(find.text('已撤销.txt'), findsNothing);
        expect(runtime.revocations, isEmpty);
      } finally {
        if (!older.isCompleted) older.complete([]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'failed grant refresh marks retained entries unverified and blocks opening them',
    (tester) async {
      final runtime = _FilesRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(FilesPage(runtime: runtime)));
      await tester.pumpAndSettle();
      runtime.rootsError = StateError('provider unavailable');
      await tester.tap(find.byTooltip('刷新授权文件'));
      await tester.pumpAndSettle();
      expect(find.text('笔记.txt'), findsOneWidget);
      expect(find.textContaining('当前状态尚未核实'), findsOneWidget);
      final entry = tester.widget<PocketRow>(
        find.ancestor(
          of: find.text('笔记.txt'),
          matching: find.byType(PocketRow),
        ),
      );
      expect(entry.onTap, isNull);
      expect(runtime.reads, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'connection replacement preserves the read page and ignores its old continuation',
    (tester) async {
      final runtime = _FilesRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        _host(TextFilePage(runtime: runtime, root: 'file-id', path: '')),
      );
      await tester.pumpAndSettle();
      final older = Completer<Json>();
      runtime.readBarrier = older;
      await tester.tap(find.text('下一段'));
      await tester.pump();
      try {
        runtime.replaceConnection();
        await tester.pumpAndSettle();
        expect(find.text('第一段中文🙂'), findsOneWidget);
        expect(find.textContaining('已显示的内容尚未核实'), findsOneWidget);
        final next = tester.widget<PocketButton>(
          find.ancestor(
            of: find.text('下一段'),
            matching: find.byType(PocketButton),
          ),
        );
        expect(next.onPressed, isNull);
        expect(runtime.reads, hasLength(2));
        runtime.readBarrier = null;
        await tester.tap(find.text('重新确认当前段'));
        await tester.pumpAndSettle();
        expect(runtime.reads.last['offset'], 0);
        older.complete({
          'text': '旧连接下一段',
          'offset': 19,
          'nextOffset': 28,
          'truncated': false,
        });
        await tester.pumpAndSettle();
        expect(find.text('旧连接下一段'), findsNothing);
        expect(find.text('第一段中文🙂'), findsOneWidget);
      } finally {
        if (!older.isCompleted) {
          older.complete({
            'text': '',
            'offset': 19,
            'nextOffset': 19,
            'truncated': false,
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'reconfirming after replacement starts a new cursor at the visible page',
    (tester) async {
      final runtime = _FilesRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        _host(TextFilePage(runtime: runtime, root: 'file-id', path: '')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一段'));
      await tester.pumpAndSettle();
      runtime.replaceConnection();
      await tester.pumpAndSettle();
      expect(find.text('第二段'), findsOneWidget);
      expect(runtime.reads, hasLength(2));
      await tester.tap(find.text('重新确认当前段'));
      await tester.pumpAndSettle();
      expect(runtime.reads.last['offset'], 19);
      expect(find.textContaining('从上次阅读位置开始'), findsOneWidget);
      final previous = tester.widget<PocketButton>(
        find.ancestor(
          of: find.text('上一段'),
          matching: find.byType(PocketButton),
        ),
      );
      expect(previous.onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'single file grants open their granted document with an empty path',
    (tester) async {
      final runtime = _FilesRuntime();
      await tester.pumpWidget(_host(FilesPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('笔记.txt'));
      await tester.pumpAndSettle();
      expect(find.text('第一段中文🙂'), findsOneWidget);
      expect(runtime.reads.single, {
        'root': 'file-id',
        'path': '',
        'offset': 0,
      });
    },
  );

  testWidgets(
    'cancelled system file selection leaves grants and content unchanged',
    (tester) async {
      final runtime = _FilesRuntime();
      final methods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          methods.add(call.method);
          if (call.method == 'pickDocument') return false;
          throw StateError('Unexpected method ${call.method}');
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(FilesPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();
      expect(methods, ['pickDocument']);
      expect(runtime.grants, hasLength(1));
      expect(runtime.reads, isEmpty);
      expect(runtime.revocations, isEmpty);
      expect(find.text('笔记.txt'), findsOneWidget);
    },
  );

  testWidgets(
    'revocation requires confirmation and removes only the selected grant',
    (tester) async {
      final runtime = _FilesRuntime();
      runtime.grants.add({
        'id': 'directory-id',
        'name': '文档',
        'directory': true,
        'available': true,
      });
      await tester.pumpWidget(_host(FilesPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('revoke-file-id')));
      await tester.pumpAndSettle();
      expect(runtime.revocations, isEmpty);
      await tester.tap(find.text('保留授权'));
      await tester.pumpAndSettle();
      expect(runtime.revocations, isEmpty);
      await tester.tap(find.byKey(const ValueKey('revoke-file-id')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认撤销'));
      await tester.tap(find.text('确认撤销'));
      await tester.pumpAndSettle();
      expect(runtime.revocations, ['file-id']);
      expect(find.text('笔记.txt'), findsNothing);
      expect(find.text('文档'), findsOneWidget);
    },
  );

  testWidgets(
    'failed next page preserves text and retry does not skip the failed offset',
    (tester) async {
      final runtime = _FilesRuntime()..failNextPage = true;
      await tester.pumpWidget(
        _host(TextFilePage(runtime: runtime, root: 'file-id', path: '')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一段'));
      await tester.pumpAndSettle();
      expect(find.text('第一段中文🙂'), findsOneWidget);
      expect(find.textContaining('文件提供方暂不可用'), findsOneWidget);
      runtime.failNextPage = false;
      await tester.tap(find.text('重试读取'));
      await tester.pumpAndSettle();
      expect(find.text('第二段'), findsOneWidget);
      expect(runtime.reads.map((item) => item['offset']).toList(), [0, 19, 19]);
      await tester.tap(find.text('上一段'));
      await tester.pumpAndSettle();
      expect(find.text('第一段中文🙂'), findsOneWidget);
      expect(runtime.reads.last['offset'], 0);
    },
  );

  testWidgets(
    'initial read failure offers retry without requiring a successful first page',
    (tester) async {
      final runtime = _FilesRuntime()..failFirstPage = true;
      await tester.pumpWidget(
        _host(TextFilePage(runtime: runtime, root: 'file-id', path: '')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('授权已撤销'), findsOneWidget);
      runtime.failFirstPage = false;
      await tester.tap(find.text('重试读取'));
      await tester.pumpAndSettle();
      expect(find.text('第一段中文🙂'), findsOneWidget);
      expect(runtime.reads.map((item) => item['offset']).toList(), [0, 0]);
    },
  );

  testWidgets(
    'inaccessible grants stay visible with recovery and revoke actions at large font',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = _FilesRuntime();
      runtime.grants.single['available'] = false;
      runtime.grants.single['error'] = '文件已移动或授权失效，请重新授权。';
      await tester.pumpWidget(_host(FilesPage(runtime: runtime), scale: 2));
      await tester.pumpAndSettle();
      expect(find.text('笔记.txt'), findsOneWidget);
      expect(find.textContaining('授权失效'), findsOneWidget);
      expect(find.byKey(const ValueKey('revoke-file-id')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
