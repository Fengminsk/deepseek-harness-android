import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/recovery.dart';
import 'package:dsh_android/recovery_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class RecoveryTestRuntime extends RuntimeController {
  void status(String value, String generation) {
    phase = value;
    nativeGeneration = generation;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    throw StateError('Recovery must not depend on Node: $method');
  }
}

class NativeRecovery {
  final calls = <(String, Json)>[];
  Json document = {
    'id': 'profile-patch',
    'text': 'original',
    'sha256': 'hash-original',
    'exists': true,
  };
  Json snapshot = {
    'mode': 'maintenance',
    'generation': 'generation-1',
    'nodeStarted': false,
    'mutationAllowed': true,
    'files': [
      {
        'id': 'profile-patch',
        'label': 'Android 配置补丁',
        'exists': true,
        'bytes': 8,
      },
    ],
    'backups': [],
    'operations': [],
    'boot': {'stage': 'maintenance', 'runtimeSha256': 'runtime-hash'},
  };
  Json receipt = {'state': 'unknown'};
  Future<Json> Function(String, Json)? intercept;

  Future<Object?> handle(MethodCall call) async {
    final params = call.method == 'recovery.call'
        ? jsonDecode(call.arguments as String) as Json
        : Map<String, dynamic>.from(call.arguments as Map);
    final method = call.method == 'recovery.call'
        ? params['method'] as String
        : call.method;
    final args = call.method == 'recovery.call'
        ? params['params'] as Json
        : params;
    calls.add((method, Map.of(args)));
    Json value;
    if (intercept != null) {
      value = await intercept!(method, args);
    } else {
      value = response(method, args);
    }
    return jsonEncode(value);
  }

  Json response(String method, Json args) {
    switch (method) {
      case 'inspect':
        return snapshot;
      case 'read':
        return document;
      case 'receipt':
        return {...receipt, 'requestId': args['requestId']};
      case 'write':
        document = {...document, 'text': args['text'], 'sha256': 'hash-saved'};
        return {
          'state': 'saved',
          'sha256': 'hash-saved',
          'requestId': args['requestId'],
        };
      case 'recovery.enter':
      case 'recovery.resume':
        final mode = method == 'recovery.enter' ? 'maintenance' : 'active';
        snapshot = {...snapshot, 'mode': mode, 'generation': 'generation-2'};
        return {'mode': mode, 'generation': 'generation-2'};
      case 'readBackup':
        return {
          'id': 'profile-patch',
          'text': '',
          'exists': false,
          'sha256': 'missing',
        };
      case 'restore':
      case 'runtimeRepair':
        return {
          'state': 'saved',
          'sha256': 'missing',
          'requestId': args['requestId'],
        };
      default:
        throw StateError('Unexpected native request $method');
    }
  }

  int count(String method) => calls.where((call) => call.$1 == method).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecoveryTestRuntime runtime;
  late RecoveryController controller;
  late NativeRecovery native;
  setUp(() {
    runtime = RecoveryTestRuntime()..phase = 'failed';
    controller = RecoveryController(runtime);
    native = NativeRecovery();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, native.handle);
  });
  tearDown(() {
    controller.dispose();
    runtime.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, null);
  });

  test(
    'failed Node still permits native inspect, original document and save',
    () async {
      await controller.load();
      expect(controller.maintenance, true);
      final document = await controller.open('profile-patch');
      document.draft = 'new content';
      await controller.save(document);
      expect(document.base, 'new content');
      expect(document.requestId, null);
      final write = native.calls.singleWhere((call) => call.$1 == 'write').$2;
      expect(write['expectedSha256'], 'hash-original');
      expect(write['generation'], 'generation-1');
      expect(
        write['requestId'],
        matches(
          RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ),
        ),
      );
      expect(runtime.ready, false);
      expect(controller.notice, contains('尚未验证'));
    },
  );

  test('refresh and conflict never discard draft; explicit new baseline retains it', () async {
    await controller.load();
    final document = await controller.open('profile-patch');
    document.draft = 'my draft';
    native.document = {
      ...native.document,
      'text': 'external',
      'sha256': 'other',
    };
    expect(await controller.open('profile-patch'), same(document));
    expect(document.draft, 'my draft');
    expect(document.conflict, true);
    await controller.save(document);
    expect(native.count('write'), 0);
    controller.useLatest(document);
    expect(document.draft, 'my draft');
    await controller.save(document);
    expect(
      native.calls
          .singleWhere((call) => call.$1 == 'write')
          .$2['expectedSha256'],
      'other',
    );
  });

  test('later edits survive a delayed successful write', () async {
    await controller.load();
    final document = await controller.open('profile-patch');
    document.draft = 'submitted';
    final pending = Completer<Json>();
    native.intercept = (method, args) async =>
        method == 'write' ? pending.future : native.response(method, args);
    final write = controller.save(document);
    await Future<void>.delayed(Duration.zero);
    document.draft = 'later draft';
    pending.complete({'state': 'saved', 'sha256': 'new-hash'});
    await write;
    expect(document.draft, 'later draft');
    expect(document.base, 'submitted');
    expect(document.dirty, true);
  });

  testWidgets(
    'timeout keeps exact ownership across routes and refresh, no replay',
    (tester) async {
      await controller.load();
      final document = await controller.open('profile-patch');
      document.draft = 'unknown edit';
      final pending = Completer<Json>();
      native.intercept = (method, args) async =>
          method == 'write' ? pending.future : native.response(method, args);
      final write = controller.save(document);
      await tester.pump();
      await tester.pump(const Duration(seconds: 26));
      await write;
      expect(document.requestId, isNotNull);
      await controller.load();
      await controller.open('profile-patch');
      await controller.save(document);
      expect(native.count('write'), 1);
      expect(document.draft, 'unknown edit');
      expect(controller.canResolveDocument(document), false);
      native.snapshot = {...native.snapshot, 'generation': 'new-maintenance'};
      await controller.load();
      expect(controller.canResolveDocument(document), true);
      await controller.resolveDocument(document);
      expect(document.requestId, null);
      expect(document.draft, 'unknown edit');
      expect(native.count('write'), 1);
      pending.complete({'state': 'saved', 'sha256': 'old'});
      await tester.pump();
      expect(document.sha256, 'hash-original');
    },
  );

  test(
    'saved receipt only reconciles matching disk content and keeps newer draft',
    () async {
      await controller.load();
      final document = await controller.open('profile-patch');
      document
        ..draft = 'later'
        ..requestId = 'request'
        ..requestGeneration = 'generation-1';
      native.receipt = {'state': 'saved', 'sha256': 'saved-hash'};
      native.document = {
        ...native.document,
        'text': 'submitted',
        'sha256': 'saved-hash',
      };
      await controller.checkReceipt(document);
      expect(document.requestId, null);
      expect(document.base, 'submitted');
      expect(document.draft, 'later');
    },
  );

  test(
    'definitive native rejection preserves draft and releases only its request',
    () async {
      await controller.load();
      final document = await controller.open('profile-patch');
      document.draft = 'invalid document';
      native.intercept = (method, args) async {
        if (method == 'write') {
          throw PlatformException(
            code: 'recovery/json-invalid',
            message: '必须是 JSON 对象',
            details: {'outcome': 'not-started', 'requestId': args['requestId']},
          );
        }
        return native.response(method, args);
      };
      await controller.save(document);
      expect(document.requestId, null);
      expect(document.draft, 'invalid document');
      expect(document.error, contains('JSON'));
      expect(native.count('receipt'), 0);
      native.intercept = null;
      document.draft = 'corrected';
      await controller.save(document);
      expect(document.base, 'corrected');
    },
  );

  test('error code alone never proves a request did not begin', () async {
    await controller.load();
    final document = await controller.open('profile-patch');
    document.draft = 'draft';
    native.intercept = (method, args) async {
      if (method == 'write') {
        throw PlatformException(code: 'recovery/json-invalid');
      }
      return native.response(method, args);
    };
    await controller.save(document);
    expect(document.requestId, isNotNull);
    expect(native.count('receipt'), 1);
  });

  test(
    'concurrent receipt checks share one read and cannot clear a newer request',
    () async {
      await controller.load();
      final document = await controller.open('profile-patch');
      document.requestId = 'request-a';
      native.receipt = {'state': 'saved', 'sha256': 'saved-hash'};
      final delayed = Completer<Json>();
      native.intercept = (method, args) async =>
          method == 'read' ? delayed.future : native.response(method, args);
      final first = controller.checkReceipt(document);
      await Future<void>.delayed(Duration.zero);
      await controller.checkReceipt(document);
      expect(native.count('receipt'), 1);
      document.requestId = 'request-b';
      delayed.complete({...native.document, 'sha256': 'saved-hash'});
      await first;
      expect(document.requestId, 'request-b');
      expect(document.sha256, 'hash-original');
    },
  );

  testWidgets(
    'resume waits for the matching generation, deadline is not success',
    (tester) async {
      await controller.load();
      await controller.changeMode(enter: false);
      expect(controller.awaitingReady, true);
      runtime.status('ready', 'stale-generation');
      await tester.pump();
      expect(controller.awaitingReady, true);
      await tester.pump(const Duration(seconds: 61));
      expect(controller.awaitingReady, false);
      expect(controller.startupUnconfirmed, true);
      expect(native.count('recovery.resume'), 1);
      expect(native.count('recovery.enter'), 0);
      runtime.status('ready', 'generation-2');
      await tester.pump();
      expect(controller.startupUnconfirmed, false);
      expect(controller.notice, contains('就绪'));
    },
  );

  test(
    'same phase but new generation invalidates old inspect result',
    () async {
      await controller.load();
      final delayed = Completer<Json>();
      var reads = 0;
      native.intercept = (method, args) async {
        if (method == 'inspect' && ++reads == 1) return delayed.future;
        return {...native.snapshot, 'generation': 'new-generation'};
      };
      final loading = controller.load();
      runtime.status('failed', 'new-generation');
      await Future<void>.delayed(Duration.zero);
      delayed.complete(native.snapshot);
      await loading;
      expect(controller.generation, 'new-generation');
    },
  );

  test(
    'maintenance with a started Node never enables write operations',
    () async {
      native.snapshot = {...native.snapshot, 'nodeStarted': true};
      await controller.load();
      expect(controller.maintenance, false);
      expect(await controller.trackedMutation('runtimeRepair', {}), null);
      expect(native.count('runtimeRepair'), 0);
    },
  );

  test('maintenance with unconfirmed descendants is read-only', () async {
    native.snapshot = {...native.snapshot, 'mutationAllowed': false};
    await controller.load();
    final document = await controller.open('profile-patch');
    document.draft = 'cannot write yet';
    await controller.save(document);
    expect(controller.maintenance, false);
    expect(native.count('write'), 0);
    expect(document.draft, 'cannot write yet');
  });

  testWidgets(
    'unknown restore keeps receipt across page changes and blocks duplication',
    (tester) async {
      await controller.load();
      final pending = Completer<Json>();
      native.intercept = (method, args) async =>
          method == 'restore' ? pending.future : native.response(method, args);
      final restore = controller.trackedMutation('restore', {
        'backupId': 'backup-1',
        'expectedSha256': 'hash-original',
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 26));
      await restore;
      expect(controller.pendingAction, isNotNull);
      await controller.trackedMutation('restore', {'backupId': 'backup-1'});
      expect(native.count('restore'), 1);
      expect(controller.canAcknowledgeAction, false);
      native.snapshot = {...native.snapshot, 'generation': 'new-generation'};
      await controller.load();
      expect(controller.canAcknowledgeAction, true);
      controller.acknowledgeAction();
      expect(controller.pendingAction, null);
      expect(native.count('restore'), 1);
      pending.complete({'state': 'saved'});
      await tester.pump();
    },
  );

  Future<void> mount(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1100, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: pocketTheme(Brightness.light), home: page),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('maintenance entry is explicit and usable while Node is failed', (
    tester,
  ) async {
    native.snapshot = {...native.snapshot, 'mode': 'active'};
    await mount(tester, RecoveryPage(controller: controller));
    expect(native.count('recovery.enter'), 0);
    await tester.tap(find.byKey(const ValueKey('recovery-enter')));
    await tester.pumpAndSettle();
    expect(native.count('recovery.enter'), 0);
    await tester.tap(find.byKey(const ValueKey('recovery-confirm-enter')));
    await tester.pumpAndSettle();
    expect(native.count('recovery.enter'), 1);
    expect(find.text('维护模式'), findsOneWidget);
  });

  testWidgets(
    'broken configuration inspection does not disable native maintenance admission',
    (tester) async {
      native.intercept = (method, args) async {
        if (method == 'inspect') {
          throw PlatformException(code: 'recovery/path-invalid');
        }
        return native.response(method, args);
      };
      await mount(tester, RecoveryPage(controller: controller));
      expect(controller.current, false);
      await tester.tap(find.byKey(const ValueKey('recovery-enter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recovery-confirm-enter')));
      await tester.pumpAndSettle();
      expect(native.count('recovery.enter'), 1);
      expect(controller.maintenance, false);
      expect(native.count('write'), 0);
    },
  );

  testWidgets(
    'unconfirmed document writes disable restore and resource repair with an explanation',
    (tester) async {
      await controller.load();
      final document = await controller.open('profile-patch');
      document.requestId = 'unconfirmed-request';
      await mount(
        tester,
        RecoveryBackupPage(controller: controller, backupId: 'backup-1'),
      );
      expect(find.text('先返回编辑文件核对保存回执，再恢复备份。'), findsOneWidget);
      expect(
        tester
            .widget<PocketButton>(
              find.byKey(const ValueKey('recovery-restore')),
            )
            .onPressed,
        null,
      );
      await mount(tester, RecoveryPage(controller: controller));
      await tester.ensureVisible(find.byKey(const ValueKey('recovery-repair')));
      expect(find.text('先返回编辑文件核对保存回执，再修复运行资源。'), findsOneWidget);
      expect(
        tester
            .widget<PocketButton>(find.byKey(const ValueKey('recovery-repair')))
            .onPressed,
        null,
      );
      expect(native.count('restore'), 0);
      expect(native.count('runtimeRepair'), 0);
    },
  );

  testWidgets(
    'restoring an absent backup states deletion and requires confirmation',
    (tester) async {
      await controller.load();
      await mount(
        tester,
        RecoveryBackupPage(controller: controller, backupId: 'absent-backup'),
      );
      expect(find.textContaining('恢复将移除当前配置文件'), findsOneWidget);
      final button = find.byKey(const ValueKey('recovery-restore'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(native.count('restore'), 0);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(native.count('restore'), 1);
      final params = native.calls
          .singleWhere((call) => call.$1 == 'restore')
          .$2;
      expect(params['expectedSha256'], 'hash-original');
      expect(params['backupId'], 'absent-backup');
    },
  );
}
