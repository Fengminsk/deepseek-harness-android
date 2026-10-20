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

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'documents.roots') {
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
