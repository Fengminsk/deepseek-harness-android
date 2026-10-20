import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/export.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _ExportRuntime extends RuntimeController {
  final calls = <({String method, Json params})>[];
  Completer<Json>? prepareBarrier;
  bool failRelease = false;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: Json.from(params)));
    if (method == 'session.export.prepare') {
      return prepareBarrier?.future ??
          {
            'id': params['id'],
            'filename': 'dsh-session-fixture.zip',
            'size': 120,
          };
    }
    if (method == 'session.export.release' && failRelease) {
      throw PlatformException(
        code: 'unavailable',
        message: 'Service unavailable',
      );
    }
    if (method == 'session.export.release' ||
        method == 'session.export.cancel') {
      return {'released': true};
    }
    throw StateError('Unexpected request $method');
  }
}

Widget _host(_ExportRuntime runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: SessionExportPage(
    runtime: runtime,
    sessionId: 'fixture',
    sessionTitle: '测试会话',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'saved archive uses native picker and releases only its temporary export',
    (tester) async {
      final runtime = _ExportRuntime();
      final native = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          native.add(call);
          return jsonEncode({'status': 'saved', 'bytes': 120});
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(runtime));
      await tester.tap(find.text('生成并保存 ZIP'));
      await tester.pumpAndSettle();
      expect(runtime.calls.map((call) => call.method).toList(), [
        'session.export.prepare',
        'session.export.release',
      ]);
      final request = runtime.calls.first.params;
      expect(request['sessionId'], 'fixture');
      expect(request['includeDescendants'], true);
      expect(native.single.method, 'sessionExport.save');
      expect(native.single.arguments, {
        'id': request['id'],
        'filename': 'dsh-session-fixture.zip',
      });
      expect(find.text('已保存 dsh-session-fixture.zip'), findsOneWidget);
    },
  );

  testWidgets(
    'save failure keeps the same prepared ZIP for a new target selection',
    (tester) async {
      final runtime = _ExportRuntime();
      var attempts = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          attempts++;
          if (attempts == 1) {
            throw PlatformException(code: 'provider', message: 'write failed');
          }
          return jsonEncode({'status': 'saved'});
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(runtime));
      await tester.tap(find.text('生成并保存 ZIP'));
      await tester.pumpAndSettle();
      expect(runtime.calls, hasLength(1));
      expect(find.textContaining('不完整的 ZIP'), findsOneWidget);
      await tester.tap(find.text('重新选择保存位置'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls.where((call) => call.method == 'session.export.prepare'),
        hasLength(1),
      );
      expect(runtime.calls.last.method, 'session.export.release');
      expect(attempts, 2);
    },
  );

  testWidgets(
    'cancelled Save As releases temporary ZIP without claiming a saved file',
    (tester) async {
      final runtime = _ExportRuntime();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => jsonEncode({'status': 'cancelled'}),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(runtime));
      await tester.tap(find.text('生成并保存 ZIP'));
      await tester.pumpAndSettle();
      expect(find.text('已取消保存。'), findsOneWidget);
      expect(find.textContaining('已保存'), findsNothing);
      expect(runtime.calls.last.method, 'session.export.release');
    },
  );

  testWidgets(
    'cancel during preparation prevents a late result opening the save picker',
    (tester) async {
      final runtime = _ExportRuntime()..prepareBarrier = Completer<Json>();
      final native = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          native.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(runtime));
      await tester.tap(find.text('生成并保存 ZIP'));
      await tester.pumpAndSettle();
      final id = runtime.calls.first.params['id'];
      await tester.tap(find.text('取消本次导出'));
      await tester.pumpAndSettle();
      runtime.prepareBarrier!.complete({
        'id': id,
        'filename': 'late.zip',
        'size': 120,
      });
      await tester.pumpAndSettle();
      expect(native, ['sessionExport.cancel']);
      expect(runtime.calls.last.method, 'session.export.cancel');
      expect(find.textContaining('本次导出已取消'), findsOneWidget);
    },
  );

  testWidgets(
    'cache cleanup failure retains the saved outcome and offers cleanup retry',
    (tester) async {
      final runtime = _ExportRuntime()..failRelease = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => call.method == 'sessionExport.save'
            ? jsonEncode({'status': 'saved'})
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(_host(runtime));
      await tester.tap(find.text('生成并保存 ZIP'));
      await tester.pumpAndSettle();
      expect(find.text('已保存 dsh-session-fixture.zip'), findsOneWidget);
      expect(find.textContaining('临时文件清理尚未确认'), findsOneWidget);
      expect(find.text('重试清理'), findsOneWidget);
      expect(find.text('生成并保存 ZIP'), findsNothing);
      await tester.tap(find.text('重试清理'));
      await tester.pumpAndSettle();
      expect(runtime.calls.last.method, 'session.export.cancel');
      expect(find.text('生成并保存 ZIP'), findsOneWidget);
      expect(find.text('已保存 dsh-session-fixture.zip'), findsOneWidget);
    },
  );
}
