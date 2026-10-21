import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/attachments.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  final calls = <({String method, Json params})>[];
  bool failUpload = false;
  Completer<void>? uploadBarrier;
  final uploadStarted = Completer<void>();
  Json? prepared;
  int generation = 0;
  @override
  int get connectionGeneration => generation;

  void replaceConnection({String nextPhase = 'ready'}) {
    generation++;
    phase = nextPhase;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: Json.from(params)));
    if (method == 'attachments.prepare') {
      if (!uploadStarted.isCompleted) uploadStarted.complete();
      await uploadBarrier?.future;
      if (failUpload) {
        throw PlatformException(code: 'fixture', message: '文件仍保留');
      }
      return prepared ??
          {
            'id': params['id'],
            'kind': 'file',
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

  test('image preparation accepts original inline-image descriptor without a file receipt', () async {
    final runtime = _Runtime()
      ..prepared = {
        'id': 'photo',
        'kind': 'image',
        'name': 'photo.png',
        'mediaType': 'image/png',
        'bytes': 10,
      };
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    picker(
      (_) async => jsonEncode({
        'items': [
          {...selection('photo'), 'mediaType': 'image/png'},
        ],
      }),
    );
    await drafts.pick('one');
    expect(drafts.snapshotIds('one'), ['photo']);
    expect(drafts.items('one').single.name, 'photo.png');
    expect(drafts.items('one').single.isImage, isTrue);
  });

  for (final response in <Json>[
    {
      'id': 'photo',
      'kind': 'image',
      'name': 'photo.png',
      'mediaType': 'image/jpeg',
      'bytes': 10,
    },
    {
      'id': 'photo',
      'kind': 'file',
      'name': 'photo.png',
      'receiptId': 'wrong-file',
      'bytes': 10,
    },
    {
      'id': 'other',
      'kind': 'image',
      'name': 'photo.png',
      'mediaType': 'image/png',
      'bytes': 10,
    },
    {
      'id': 'photo',
      'kind': 'image',
      'name': 'photo.png',
      'mediaType': 'image/png',
      'bytes': -1,
    },
    {
      'id': 'photo',
      'kind': 'image',
      'name': 'photo.png',
      'mediaType': 'image/png',
      'bytes': 0,
    },
  ]) {
    test(
      'invalid image preparation cannot authorize send: $response',
      () async {
        final runtime = _Runtime()..prepared = response;
        final drafts = AttachmentDrafts(runtime);
        addTearDown(drafts.dispose);
        picker(
          (_) async => jsonEncode({
            'items': [
              {...selection('photo'), 'mediaType': 'image/png'},
            ],
          }),
        );
        await drafts.pick('one');
        expect(drafts.ready('one'), isFalse);
        expect(drafts.items('one').single.status, 'error');
        expect(() => drafts.snapshotIds('one'), throwsStateError);
      },
    );
  }

  test('prepare response from a prior runtime generation cannot mark a draft ready', () async {
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
    runtime.generation++;
    runtime.uploadBarrier!.complete();
    await picking;
    expect(drafts.ready('one'), isFalse);
    expect(drafts.items('one').single.error, contains('服务已重启'));
  });

  test('ready connection replacement withdraws all receipts without uploading again', () async {
    final runtime = _Runtime();
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    var selected = 'first';
    var picks = 0;
    picker((_) async {
      picks++;
      return jsonEncode({
        'items': [selection(selected)],
      });
    });
    await drafts.pick('one');
    selected = 'second';
    await drafts.pick('two');
    expect(drafts.ready('one'), isTrue);
    expect(drafts.ready('two'), isTrue);
    final before = runtime.calls.length;
    runtime.replaceConnection();
    expect(drafts.ready('one'), isFalse);
    expect(drafts.ready('two'), isFalse);
    expect(drafts.items('one').single.error, contains('服务已重启'));
    expect(drafts.items('two').single.id, 'second');
    expect(
      runtime.calls.length,
      before,
      reason: 'reconnection never uploads automatically',
    );
    expect(() => drafts.snapshotIds('one'), throwsStateError);
    await drafts.retry('one', 'first');
    expect(drafts.snapshotIds('one'), ['first']);
    expect(drafts.ready('two'), isFalse);
    expect(picks, 2, reason: 'explicit retry reuses the native selected copy');
  });

  test('unrelated runtime observations keep prepared receipts ready', () async {
    final runtime = _Runtime();
    final drafts = AttachmentDrafts(runtime);
    addTearDown(drafts.dispose);
    picker(
      (_) async => jsonEncode({
        'items': [selection('first')],
      }),
    );
    await drafts.pick('one');
    runtime.notifyListeners();
    expect(drafts.snapshotIds('one'), ['first']);
    expect(runtime.calls.length, 1);
    runtime.phase = 'failed';
    runtime.notifyListeners();
    expect(drafts.ready('one'), isFalse);
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
