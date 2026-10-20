import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/attachments.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  final calls = <({String method, Json params})>[];
  bool failUpload = false;
  Completer<void>? uploadBarrier;
  final uploadStarted = Completer<void>();

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: Json.from(params)));
    if (method == 'attachments.prepare') {
      if (!uploadStarted.isCompleted) uploadStarted.complete();
      await uploadBarrier?.future;
      if (failUpload) {
        throw PlatformException(code: 'fixture', message: '文件仍保留');
      }
      return {
        'id': params['id'],
        'name': '${params['id']}.txt',
        'bytes': 10,
        'receiptId': 'receipt-${params['id']}',
      };
    }
    if (method == 'attachments.release') return {'released': true};
    throw StateError('Unexpected $method');
  }
}

Json selection(String id) => {
  'id': id,
  'name': '$id.txt',
  'bytes': 10,
  'mediaType': 'text/plain',
};

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  void picker(Future<dynamic> Function(MethodCall) handler) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      handler,
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        null,
      ),
    );
  }

  test('cancelled picker never uploads or changes the current draft', () async {
    final runtime = _Runtime();
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    picker((_) async => jsonEncode({'cancelled': true}));
    await drafts.pick('one');
    expect(drafts.items('one'), isEmpty);
    expect(runtime.calls, isEmpty);
  });

  test('late selection remains owned by its original conversation', () async {
    final runtime = _Runtime();
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    final selected = Completer<String>();
    picker((_) => selected.future);
    final picking = drafts.pick('one');
    expect(drafts.ready('one'), isFalse);
    expect(drafts.items('two'), isEmpty);
    selected.complete(
      jsonEncode({
        'items': [selection('first')],
      }),
    );
    await picking;
    expect(drafts.snapshotIds('one'), ['first']);
    expect(drafts.snapshotIds('two'), isEmpty);
    expect(runtime.calls.single.params['sessionId'], 'one');
  });

  test('failed upload blocks send, keeps the selected file and retries without reopening picker', () async {
    final runtime = _Runtime()..failUpload = true;
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    var opened = 0;
    picker((_) async {
      opened++;
      return jsonEncode({
        'items': [selection('first')],
      });
    });
    await drafts.pick('one');
    expect(drafts.ready('one'), isFalse);
    expect(() => drafts.snapshotIds('one'), throwsStateError);
    expect(drafts.items('one').single.error, contains('文件仍保留'));
    runtime.failUpload = false;
    await drafts.retry('one', 'first');
    expect(drafts.snapshotIds('one'), ['first']);
    expect(opened, 1);
  });

  test('consume clears only the successfully submitted snapshot, retaining later same-chat attachments', () async {
    final runtime = _Runtime();
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    var next = 'first';
    picker(
      (_) async => jsonEncode({
        'items': [selection(next)],
      }),
    );
    await drafts.pick('one');
    final submitted = drafts.snapshotIds('one');
    next = 'later';
    await drafts.pick('one');
    await drafts.consume('one', submitted);
    expect(drafts.snapshotIds('one'), ['later']);
    expect(runtime.calls.last.params, {'sessionId': 'one', 'id': 'first'});
  });

  test(
    'removing during upload prevents its late receipt restoring the draft',
    () async {
      final runtime = _Runtime()..uploadBarrier = Completer<void>();
      final drafts = AttachmentDrafts(runtime);
      addTearDown(drafts.dispose);
      picker(
        (_) async => jsonEncode({
          'items': [selection('first')],
        }),
      );
      final picking = drafts.pick('one');
      await runtime.uploadStarted.future;
      await drafts.remove('one', 'first');
      runtime.uploadBarrier!.complete();
      await picking;
      expect(drafts.items('one'), isEmpty);
    },
  );

  testWidgets(
    'attachment rail keeps retry and remove readable at large text scale',
    (tester) async {
      final runtime = _Runtime()..failUpload = true;
      final drafts = AttachmentDrafts(runtime);
      addTearDown(drafts.dispose);
      picker(
        (_) async => jsonEncode({
          'items': [selection('long-selected-file')],
        }),
      );
      await drafts.pick('one');
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PocketAttachmentRail(drafts: drafts, sessionId: 'one'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('重试上传'), findsOneWidget);
      expect(find.byTooltip('移除 long-selected-file.txt'), findsOneWidget);
    },
  );
}
