import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/attachment_file.dart';
import 'package:dsh_android/attachment_file_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const reference = AttachmentFileReference(
  sessionId: 'existing-session',
  attachmentId: 'durable-file',
  name: '记录.txt',
);

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  int generation = 1;
  final calls = <({String method, Json params})>[];
  Future<dynamic> Function(String, Json)? respond;
  bool binary = false;
  @override
  int get connectionGeneration => generation;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: Json.from(params)));
    if (respond != null) return respond!(method, params);
    return answer(method, params);
  }

  dynamic answer(String method, Json params) {
    switch (method) {
      case 'session.attachmentFile.prepare':
        return {
          'id': params['id'],
          'filename': reference.name,
          'size': 10,
          'previewKind': binary ? 'binary' : 'text',
        };
      case 'session.attachmentFile.read':
        final offset = params['offset'] as int;
        return {
          'text': offset == 0 ? 'first' : 'later',
          'offset': offset,
          'nextOffset': offset == 0 ? 5 : 10,
          'eof': offset != 0,
          'size': 10,
        };
      case 'session.attachmentFile.release':
        return {'released': true};
      default:
        throw StateError('Unexpected call $method');
    }
  }

  void replace() {
    generation++;
    notifyListeners();
  }

  void disconnect() {
    phase = 'starting';
    notifyListeners();
  }

  void reconnect() {
    phase = 'ready';
    notifyListeners();
  }
}

final captureKey = GlobalKey();

Widget app(
  Widget child, {
  double scale = 1,
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: pocketTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: RepaintBoundary(key: captureKey, child: child!),
  ),
  home: child,
);

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['POCKET_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['POCKET_CAPTURE_FONT'];
    if (path == null) return;
    await (FontLoader('Roboto')..addFont(
          Future.value(ByteData.sublistView(await File(path).readAsBytes())),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  final native = <MethodCall>[];
  Future<dynamic> Function(MethodCall)? onNative;

  setUp(() {
    native.clear();
    onNative = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, (call) async {
          native.add(call);
          if (onNative != null) return onNative!(call);
          if (call.method == 'attachmentFile.cancelSave') return null;
          if (call.method == 'attachmentFile.save') {
            return jsonEncode({
              'status': 'saved',
              'filename': reference.name,
              'bytes': 10,
            });
          }
          throw StateError('Unexpected native call ${call.method}');
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, null);
  });

  test('message reference does not accept arbitrary paths or drafts', () {
    expect(
      () => AttachmentFileReference.fromMessage('s', {'path': '/private/a'}),
      throwsFormatException,
    );
    expect(
      () => AttachmentFileReference.fromMessage('', {
        'attachmentId': 'a',
        'name': 'b',
      }),
      throwsFormatException,
    );
    final ref = AttachmentFileReference.fromMessage('s', {
      'attachmentId': 'a',
      'name': 'b',
      'path': '/private/ignored',
      'url': 'file:///ignored',
    });
    expect(ref.attachmentId, 'a');
    expect(ref.name, 'b');
  });

  test('opens by conversation reference and never prepares an agent', () async {
    final runtime = _Runtime();
    final state = AttachmentFileController(runtime, reference);
    await state.prepare();
    expect(state.current, isTrue);
    expect(state.page!.text, 'first');
    expect(runtime.calls.map((c) => c.method), [
      'session.attachmentFile.prepare',
      'session.attachmentFile.read',
    ]);
    expect(runtime.calls.first.params.keys.toSet(), {
      'id',
      'sessionId',
      'attachmentId',
      'name',
    });
    expect(runtime.calls.first.params['sessionId'], 'existing-session');
    expect(runtime.calls.first.params['attachmentId'], 'durable-file');
    expect(runtime.calls.first.params['name'], '记录.txt');
    expect(native, isEmpty);
    await state.cancel();
    state.dispose();
    runtime.dispose();
  });

  test('paged navigation replaces text and revisits known offsets', () async {
    final runtime = _Runtime();
    final state = AttachmentFileController(runtime, reference);
    await state.prepare();
    await state.next();
    expect(state.page!.text, 'later');
    expect(state.canNext, isFalse);
    expect(state.pageIndex, 1);
    await state.previous();
    expect(state.page!.text, 'first');
    expect(
      runtime.calls
          .where((c) => c.method.endsWith('.read'))
          .map((c) => c.params['offset']),
      [0, 5, 0],
    );
    await state.cancel();
    state.dispose();
    runtime.dispose();
  });

  test(
    'failed next segment keeps current page and retries failed offset',
    () async {
      final runtime = _Runtime();
      final state = AttachmentFileController(runtime, reference);
      await state.prepare();
      var fail = true;
      runtime.respond = (method, params) async {
        if (method.endsWith('.read') && params['offset'] == 5 && fail) {
          fail = false;
          throw StateError('read interrupted');
        }
        return runtime.answer(method, params);
      };
      await state.next();
      expect(state.page!.text, 'first');
      expect(state.failureKind, AttachmentFileFailure.read);
      await state.retryRead();
      expect(state.page!.text, 'later');
      expect(
        runtime.calls
            .where((c) => c.method.endsWith('.read'))
            .map((c) => c.params['offset']),
        [0, 5, 5],
      );
      await state.cancel();
      state.dispose();
      runtime.dispose();
    },
  );

  test('binary file is saveable without attempting a text read', () async {
    final runtime = _Runtime()..binary = true;
    final state = AttachmentFileController(runtime, reference);
    await state.prepare();
    expect(state.file!.isText, isFalse);
    expect(state.canSave, isTrue);
    expect(state.canRead, isFalse);
    expect(runtime.calls.where((c) => c.method.endsWith('.read')), isEmpty);
    await state.save();
    expect(state.message, '已保存 记录.txt');
    expect(native.single.arguments.keys.toSet(), {'id', 'filename'});
    await state.cancel();
    state.dispose();
    runtime.dispose();
  });

  test(
    'save cancellation and partial destination never claim success',
    () async {
      final runtime = _Runtime()..binary = true;
      final state = AttachmentFileController(runtime, reference);
      await state.prepare();
      onNative = (call) async => call.method.endsWith('.save')
          ? jsonEncode({'status': 'cancelled', 'partialDestination': true})
          : null;
      await state.save();
      expect(state.message, contains('不完整'));
      expect(state.message, isNot(contains('已保存')));
      expect(state.canSave, isTrue);
      await state.cancel();
      state.dispose();
      runtime.dispose();
    },
  );

  test(
    'mismatching save response remains unconfirmed and can be retried',
    () async {
      final runtime = _Runtime()..binary = true;
      final state = AttachmentFileController(runtime, reference);
      await state.prepare();
      onNative = (call) async => call.method.endsWith('.save')
          ? jsonEncode({
              'status': 'saved',
              'filename': 'other.txt',
              'bytes': 10,
            })
          : null;
      await state.save();
      expect(state.message, isNull);
      expect(state.failureKind, AttachmentFileFailure.save);
      expect(state.canSave, isTrue);
      await state.cancel();
      state.dispose();
      runtime.dispose();
    },
  );

  test(
    'same-ready replacement retains unverified text with no automatic read',
    () async {
      final runtime = _Runtime();
      final state = AttachmentFileController(runtime, reference);
      await state.prepare();
      runtime.replace();
      await Future<void>.delayed(Duration.zero);
      expect(state.page!.text, 'first');
      expect(state.current, isFalse);
      expect(state.canSave, isFalse);
      expect(state.canNext, isFalse);
      expect(
        runtime.calls.where((c) => c.method.endsWith('.prepare')).length,
        1,
      );
      expect(runtime.calls.where((c) => c.method.endsWith('.read')).length, 1);
      expect(state.canPrepare, isTrue);
      await state.prepare();
      expect(state.current, isTrue);
      expect(
        runtime.calls.where((c) => c.method.endsWith('.prepare')).length,
        2,
      );
      await state.cancel();
      state.dispose();
      runtime.dispose();
    },
  );

  test(
    'disconnect invalidates late preparation and does not replay on reconnect',
    () async {
      final runtime = _Runtime();
      final pending = Completer<dynamic>();
      runtime.respond = (method, params) async => method.endsWith('.prepare')
          ? pending.future
          : runtime.answer(method, params);
      final state = AttachmentFileController(runtime, reference);
      final operation = state.prepare();
      final params = runtime.calls.first.params;
      runtime.disconnect();
      pending.complete(
        runtime.answer('session.attachmentFile.prepare', params),
      );
      await operation;
      await Future<void>.delayed(Duration.zero);
      runtime.reconnect();
      expect(state.file, isNull);
      expect(state.current, isFalse);
      expect(state.preparing, isFalse);
      expect(
        runtime.calls.where((c) => c.method.endsWith('.prepare')).length,
        1,
      );
      expect(runtime.calls.where((c) => c.method.endsWith('.read')), isEmpty);
      state.dispose();
      runtime.dispose();
    },
  );

  test('old page response cannot replace a newer prepared file', () async {
    final runtime = _Runtime();
    final state = AttachmentFileController(runtime, reference);
    await state.prepare();
    final pending = Completer<dynamic>();
    runtime.respond = (method, params) async =>
        method.endsWith('.read') && params['offset'] == 5
        ? pending.future
        : runtime.answer(method, params);
    final oldRead = state.next();
    runtime.replace();
    await Future<void>.delayed(Duration.zero);
    await state.prepare();
    pending.complete({
      'text': 'stale',
      'offset': 5,
      'nextOffset': 10,
      'size': 10,
      'eof': true,
    });
    await oldRead;
    expect(state.page!.text, 'first');
    expect(state.current, isTrue);
    expect(state.reading, isFalse);
    await state.cancel();
    state.dispose();
    runtime.dispose();
  });

  test(
    'save result from an old runtime cannot claim success after replacement',
    () async {
      final runtime = _Runtime()..binary = true;
      final state = AttachmentFileController(runtime, reference);
      await state.prepare();
      final pending = Completer<dynamic>();
      onNative = (call) async =>
          call.method == 'attachmentFile.save' ? pending.future : null;
      final oldSave = state.save();
      runtime.replace();
      pending.complete(
        jsonEncode({
          'status': 'saved',
          'filename': reference.name,
          'bytes': 10,
        }),
      );
      await oldSave;
      await Future<void>.delayed(Duration.zero);
      expect(state.message, isNull);
      expect(state.error, contains('保存结果尚未确认'));
      expect(state.saving, isFalse);
      state.dispose();
      runtime.dispose();
    },
  );

  test(
    'explicit cancel waits for native copy before releasing its file',
    () async {
      final runtime = _Runtime()..binary = true;
      final state = AttachmentFileController(runtime, reference);
      await state.prepare();
      final stopped = Completer<void>();
      onNative = (call) => stopped.future;
      final cancellation = state.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(
        runtime.calls.where((c) => c.method.endsWith('.release')),
        isEmpty,
      );
      expect(state.cleaning, isTrue);
      stopped.complete();
      await cancellation;
      expect(runtime.calls.last.method, 'session.attachmentFile.release');
      expect(state.cleaning, isFalse);
      expect(state.canPrepare, isTrue);
      state.dispose();
      runtime.dispose();
    },
  );

  test('cleanup failure stays visible and blocks another copy until explicit retry', () async {
    final runtime = _Runtime()..binary = true;
    final state = AttachmentFileController(runtime, reference);
    await state.prepare();
    onNative = (_) async => throw StateError('native copy still stopping');
    await state.cancel();
    expect(state.cleanupError, isNotNull);
    expect(state.canPrepare, isFalse);
    expect(runtime.calls.where((c) => c.method.endsWith('.release')), isEmpty);
    onNative = (_) async => null;
    await state.retryCleanup();
    expect(state.cleanupError, isNull);
    expect(state.canPrepare, isTrue);
    state.dispose();
    runtime.dispose();
  });

  test('empty file is one valid text page, malformed offsets are rejected', () {
    expect(
      AttachmentTextPage.parse(
        {'text': '', 'offset': 0, 'nextOffset': 0, 'size': 0, 'eof': true},
        0,
        0,
      ).eof,
      isTrue,
    );
    expect(
      () => AttachmentTextPage.parse(
        {'text': 'x', 'offset': 0, 'nextOffset': 0, 'size': 1, 'eof': false},
        0,
        1,
      ),
      throwsFormatException,
    );
    expect(
      () => AttachmentTextPage.parse(
        {'text': 'x', 'offset': 0, 'nextOffset': 1, 'size': 2, 'eof': true},
        0,
        2,
      ),
      throwsFormatException,
    );
  });

  testWidgets(
    'file page shows native text and save with floating round action',
    (tester) async {
      final runtime = _Runtime();
      await tester.pumpWidget(
        app(AttachmentFilePage(runtime: runtime, reference: reference)),
      );
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      final action = tester.getSize(
        find.byKey(const ValueKey('attachment-file-save')),
      );
      expect(action.width, closeTo(action.height, .01));
      await tester.tap(find.byKey(const ValueKey('attachment-file-next')));
      await tester.pumpAndSettle();
      expect(find.text('later'), findsOneWidget);
      expect(find.text('first'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      runtime.dispose();
    },
  );

  testWidgets(
    'binary page offers file save without JSON or fake text preview',
    (tester) async {
      final runtime = _Runtime()..binary = true;
      await tester.pumpWidget(
        app(
          AttachmentFilePage(runtime: runtime, reference: reference),
          scale: 1.4,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('此格式不支持文本预览'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.byKey(const ValueKey('attachment-file-save')));
      await tester.pumpAndSettle();
      expect(find.text('已保存 记录.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      runtime.dispose();
    },
  );

  testWidgets('late file preparation after leaving cannot reopen or render', (
    tester,
  ) async {
    final runtime = _Runtime();
    final pending = Completer<dynamic>();
    runtime.respond = (method, params) async => method.endsWith('.prepare')
        ? pending.future
        : runtime.answer(method, params);
    await tester.pumpWidget(
      app(AttachmentFilePage(runtime: runtime, reference: reference)),
    );
    await tester.pump();
    final params = runtime.calls.first.params;
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(runtime.answer('session.attachmentFile.prepare', params));
    await tester.pumpAndSettle();
    expect(runtime.calls.where((c) => c.method.endsWith('.read')), isEmpty);
    expect(native.any((c) => c.method == 'attachmentFile.cancelSave'), isTrue);
    expect(tester.takeException(), isNull);
    runtime.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('attachment reader fits phone ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const content =
          '工作记录\n\n'
          '今天整理了工作区中的文档。先核对文件内容，再提取需要跟进的事项。\n\n'
          '待办事项\n'
          '1. 补充会议结论。\n'
          '2. 确认负责人与截止时间。\n'
          '3. 保存完整附件，供后续查阅。\n\n'
          '这是一份本地合成文件，用于检查文字阅读、分页和保存入口。';
      final size = utf8.encode(content).length;
      final runtime = _Runtime();
      runtime.respond = (method, params) async => switch (method) {
        'session.attachmentFile.prepare' => {
          'id': params['id'],
          'filename': reference.name,
          'size': size,
          'previewKind': 'text',
        },
        'session.attachmentFile.read' => {
          'text': content,
          'offset': 0,
          'nextOffset': size,
          'eof': true,
          'size': size,
        },
        _ => runtime.answer(method, params),
      };
      await tester.pumpWidget(
        app(
          AttachmentFilePage(runtime: runtime, reference: reference),
          brightness: brightness,
          scale: brightness == Brightness.light ? 1.4 : 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(content), findsOneWidget);
      expect(tester.takeException(), isNull);
      final save = tester.getRect(
        find.byKey(const ValueKey('attachment-file-save')),
      );
      expect(save.width, closeTo(save.height, .01));
      expect(save.right, lessThanOrEqualTo(390));
      await capture(tester, 'attachment-reader-${brightness.name}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      runtime.dispose();
    });
  }
}
