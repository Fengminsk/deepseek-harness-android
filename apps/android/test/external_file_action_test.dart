import 'package:dsh_android/external_file_action.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<BuildContext> _page(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return context;
}

void _mock(
  WidgetTester tester,
  List<MethodCall> calls,
  Future<Object?> Function(MethodCall call) handler,
) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    RuntimeController.channel,
    (call) {
      calls.add(call);
      return handler(call);
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      null,
    ),
  );
}

void main() {
  testWidgets('save stages the file then reports the picker outcome', (tester) async {
    final calls = <MethodCall>[];
    _mock(tester, calls, (call) async {
      if (call.method == 'file.savePrepared') {
        expect(call.arguments, {'requestId': calls.first.arguments['requestId']});
        return '{"status":"saved","filename":"a.txt","bytes":3}';
      }
      return null;
    });
    final context = await _page(tester);
    final controller = ExternalFileOpenController();
    addTearDown(controller.dispose);
    expect(await controller.save(context, path: 'notes/a.txt'), 'saved');
    expect(calls.map((call) => call.method), ['file.openWorkspace', 'file.savePrepared']);
    expect(calls.first.arguments, isA<Map<Object?, Object?>>());
    expect(calls.first.arguments['path'], 'notes/a.txt');
  });

  testWidgets('a cancelled picker reports cancellation without an error', (tester) async {
    final calls = <MethodCall>[];
    _mock(tester, calls, (call) async =>
        call.method == 'file.savePrepared' ? '{"status":"cancelled"}' : null);
    final context = await _page(tester);
    final controller = ExternalFileOpenController();
    addTearDown(controller.dispose);
    expect(await controller.save(context, root: 'r', path: 'a.txt'), 'cancelled');
    expect(calls.map((call) => call.method), ['file.openDocument', 'file.savePrepared']);
    expect(calls.first.arguments['root'], 'r');
  });

  testWidgets('copying an image stages the session file before the clipboard call', (tester) async {
    final calls = <MethodCall>[];
    _mock(tester, calls, (call) async => null);
    final context = await _page(tester);
    final controller = ExternalFileOpenController();
    addTearDown(controller.dispose);
    expect(await controller.copyImage(context, sessionId: 's1', path: 'diagram.png'), isTrue);
    expect(calls.map((call) => call.method), ['file.openSession', 'file.copyPrepared']);
    expect(calls.first.arguments['sessionId'], 's1');
  });

  testWidgets('a rejected copy keeps the native reason visible', (tester) async {
    final calls = <MethodCall>[];
    _mock(tester, calls, (call) async {
      if (call.method == 'file.copyPrepared') {
        throw PlatformException(code: 'file-open/not-image', message: '只有图片可以复制为剪贴板内容');
      }
      return null;
    });
    final context = await _page(tester);
    final controller = ExternalFileOpenController();
    addTearDown(controller.dispose);
    expect(await controller.copyImage(context, path: 'notes.txt'), isFalse);
    await tester.pump();
    expect(find.text('只有图片可以复制为剪贴板内容'), findsOneWidget);
  });

  testWidgets('a failed preparation reports the native message and does not act', (tester) async {
    final calls = <MethodCall>[];
    _mock(tester, calls, (call) async {
      throw PlatformException(code: 'file-open/path', message: '文件链接无效，请重新选择');
    });
    final context = await _page(tester);
    final controller = ExternalFileOpenController();
    addTearDown(controller.dispose);
    expect(await controller.save(context, path: 'bad'), 'cancelled');
    expect(calls.map((call) => call.method), ['file.openWorkspace']);
    await tester.pump();
    expect(find.text('文件链接无效，请重新选择'), findsOneWidget);
  });
}
