import 'dart:async';

import 'package:dsh_android/credentials.dart';
import 'package:dsh_android/credentials_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/settings_layout_capture.dart';

Json referenceForm(String namespace, String reference) => {
  'ns': namespace,
  'schema': {
    'type': 'object',
    'dict': {
      'apiKeyEnv': {
        'type': 'string',
        'meta': {'role': 'credential-ref'},
      },
    },
  },
  'value': {'apiKeyEnv': reference},
};

class CredentialRuntime extends RuntimeController {
  CredentialRuntime() {
    phase = 'ready';
  }

  List<Json> descriptors = [
    referenceForm('web-search-deepseek', 'SHARED_KEY'),
    referenceForm('llm-deepseek', 'SHARED_KEY'),
  ];
  final sent = <(String, Json)>[];
  final configured = <String>{'SHARED_KEY'};
  final readonly = <String>{};
  final notifications = StreamController<Json>.broadcast(sync: true);
  Future<dynamic> Function(String, Json)? handle;

  @override
  Stream<Json> get remoteEvents => notifications.stream;

  List<(String, Json)> calls(String method) =>
      sent.where((call) => call.$1 == method).toList();

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'settings.describe') return descriptors;
    expect(method, 'api.call');
    expect(params['namespace'], 'credentials');
    final operation = params['method'] as String;
    final args = params['args'] as Json;
    sent.add((operation, Map.of(args)));
    if (handle != null) return handle!(operation, args);
    switch (operation) {
      case 'describe':
        return {
          for (final ref in args['refs'] as List)
            ref as String: {
              'configured': configured.contains(ref),
              'writable': !readonly.contains(ref),
              'source': 'android-keystore',
            },
        };
      case 'set':
        configured.add(args['ref'] as String);
        return null;
      case 'unset':
        configured.remove(args['ref'] as String);
        return null;
      default:
        throw StateError('Unexpected credentials operation');
    }
  }

  void connection(String value) {
    phase = value;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(notifications.close());
    super.dispose();
  }
}

final layoutCapture = SettingsLayoutCapture();

Future<void> mount(
  WidgetTester tester,
  CredentialsController controller, {
  Brightness brightness = Brightness.light,
  Size size = const Size(1000, 2200),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(brightness),
      builder: (context, child) =>
          layoutCapture.wrap(context, child, scale: scale),
      home: CredentialsPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openShared(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('credential-SHARED_KEY')));
  await tester.pumpAndSettle();
}

Future<void> editValue(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('credential-value-row')));
  await tester.pumpAndSettle();
}

Future<void> finishEditing(WidgetTester tester) async {
  await tester.tap(find.byTooltip('完成编辑'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSettingsCaptureFonts);

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'credential summaries stay private and readable ${brightness.name} $scale',
        (tester) async {
          final runtime = CredentialRuntime();
          final controller = CredentialsController(runtime);
          addTearDown(runtime.dispose);
          addTearDown(controller.dispose);
          await mount(
            tester,
            controller,
            brightness: brightness,
            size: const Size(420, 900),
            scale: scale,
          );
          controller.edit('SHARED_KEY', 'synthetic-secret-never-in-summary');
          await openShared(tester);
          expect(find.byType(TextField), findsNothing);
          expect(find.text('已填写'), findsOneWidget);
          expect(find.text('synthetic-secret-never-in-summary'), findsNothing);
          await layoutCapture.save(
            tester,
            'credentials-${brightness.name}-$scale',
          );
          await editValue(tester);
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const ValueKey('credential-value-input')),
                )
                .obscureText,
            isTrue,
          );
          await layoutCapture.save(
            tester,
            'credential-editor-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          expect(runtime.calls('set'), isEmpty);
        },
      );
    }
  }

  test(
    'schema roles discover shared and nested references without secrets',
    () {
      final found = credentialUses([
        referenceForm('search', 'SHARED_KEY'),
        referenceForm('models', 'SHARED_KEY'),
        {
          'ns': 'plugin',
          'schema': {
            'uid': 1,
            'refs': {
              '1': {
                'type': 'object',
                'dict': {'tools': 2, 'secret': 5, 'apiKeyEnv': 6},
              },
              '2': {'type': 'array', 'inner': 3},
              '3': {
                'type': 'object',
                'dict': {'key': 4},
              },
              '4': {
                'type': 'string',
                'meta': {'role': 'credential-ref'},
              },
              '5': {
                'type': 'object',
                'meta': {'role': 'secret'},
                'dict': {'key': 4},
              },
              '6': {'type': 'string'},
            },
          },
          'value': {
            'tools': [
              {'key': 'TOOL_KEY'},
            ],
            'secret': {'key': 'PRIVATE_VALUE'},
            'apiKeyEnv': 'UNDECLARED_VALUE',
          },
        },
      ]);
      expect(found.keys, ['SHARED_KEY', 'TOOL_KEY']);
      expect(found['SHARED_KEY']!.map((use) => use.namespace), [
        'search',
        'models',
      ]);
      expect(found['TOOL_KEY']!.single.path, ['tools', '0', 'key']);
    },
  );

  test('metadata batches honor the original 64 reference bound', () async {
    final runtime = CredentialRuntime()
      ..descriptors = List.generate(
        65,
        (i) => referenceForm('tool-$i', 'KEY_$i'),
      );
    final controller = CredentialsController(runtime);
    addTearDown(runtime.dispose);
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(
      runtime.calls('describe').map((call) => (call.$2['refs'] as List).length),
      [64, 1],
    );
    expect(controller.entries.length, 65);
    expect(controller.entries.values.every((row) => row.fresh), isTrue);
    expect(runtime.sent.every((call) => call.$1 == 'describe'), isTrue);
  });

  test('writes preserve original non-empty value and clear only acknowledged input', () async {
    final runtime = CredentialRuntime();
    final controller = CredentialsController(runtime);
    addTearDown(runtime.dispose);
    addTearDown(controller.dispose);
    await controller.refresh();
    await controller.save('SHARED_KEY');
    expect(runtime.calls('set'), isEmpty);
    controller.edit('SHARED_KEY', ' 本次工具凭据 with spaces ');
    await controller.save('SHARED_KEY');
    expect(runtime.calls('set').single.$2['value'], ' 本次工具凭据 with spaces ');
    expect(controller.entry('SHARED_KEY').draft, isEmpty);
    expect(controller.entry('SHARED_KEY').write!.state, 'confirmed');
  });

  test('late acknowledgement keeps edits typed after submission', () async {
    final runtime = CredentialRuntime();
    final controller = CredentialsController(runtime);
    addTearDown(runtime.dispose);
    addTearDown(controller.dispose);
    await controller.refresh();
    final reply = Completer<dynamic>();
    runtime.handle = (method, args) async {
      if (method == 'set') return reply.future;
      return {
        'SHARED_KEY': {'configured': true, 'writable': true},
      };
    };
    controller.edit('SHARED_KEY', 'submitted-fixture');
    final write = controller.save('SHARED_KEY');
    controller.edit('SHARED_KEY', 'later-fixture');
    await controller.save('SHARED_KEY');
    expect(runtime.calls('set'), hasLength(1));
    reply.complete(null);
    await write;
    expect(controller.entry('SHARED_KEY').draft, 'later-fixture');
    expect(controller.entry('SHARED_KEY').write!.state, 'confirmed');
  });

  test('unknown writes retain drafts and configured status cannot acknowledge their value', () async {
    final runtime = CredentialRuntime();
    final controller = CredentialsController(runtime);
    addTearDown(runtime.dispose);
    addTearDown(controller.dispose);
    await controller.refresh();
    runtime.handle = (method, args) async {
      if (method == 'set') {
        throw PlatformException(
          code: 'runtime',
          message: 'synthetic-secret-do-not-display',
        );
      }
      return {
        'SHARED_KEY': {'configured': true, 'writable': true},
      };
    };
    controller.edit('SHARED_KEY', 'synthetic-secret-do-not-display');
    await controller.save('SHARED_KEY');
    await controller.refresh();
    final row = controller.entry('SHARED_KEY');
    expect(row.draft, 'synthetic-secret-do-not-display');
    expect(row.status!.configured, isTrue);
    expect(row.write!.state, 'unconfirmed');
    expect(
      row.write!.notice,
      isNot(contains('synthetic-secret-do-not-display')),
    );
    await controller.save('SHARED_KEY');
    expect(runtime.calls('set'), hasLength(1));
    await controller.save('SHARED_KEY', acknowledgeUnknown: true);
    expect(runtime.calls('set'), hasLength(2));
  });

  test(
    'read-only metadata and an absent removal confirmation prevent writes',
    () async {
      final runtime = CredentialRuntime()..readonly.add('SHARED_KEY');
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await controller.refresh();
      controller.edit('SHARED_KEY', 'fixture');
      await controller.save('SHARED_KEY');
      await controller.remove('SHARED_KEY', confirmed: true);
      expect(runtime.calls('set'), isEmpty);
      expect(runtime.calls('unset'), isEmpty);
      runtime.readonly.clear();
      await controller.readReference('SHARED_KEY');
      await controller.remove('SHARED_KEY', confirmed: false);
      expect(runtime.calls('unset'), isEmpty);
      await controller.remove('SHARED_KEY', confirmed: true);
      expect(runtime.calls('unset'), hasLength(1));
      expect(controller.entry('SHARED_KEY').draft, 'fixture');
    },
  );

  test(
    'reconnect never replays a write or trusts a previous connection receipt',
    () async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      controller.start();
      await controller.refresh();
      final reply = Completer<dynamic>();
      runtime.handle = (method, args) async {
        if (method == 'set') return reply.future;
        return {
          'SHARED_KEY': {'configured': true, 'writable': true},
        };
      };
      controller.edit('SHARED_KEY', 'unconfirmed-fixture');
      final write = controller.save('SHARED_KEY');
      runtime.connection('starting');
      runtime.connection('ready');
      reply.complete(null);
      await write;
      await controller.refresh();
      expect(runtime.calls('set'), hasLength(1));
      expect(controller.entry('SHARED_KEY').draft, 'unconfirmed-fixture');
      expect(controller.entry('SHARED_KEY').write!.state, 'unconfirmed');
    },
  );

  test(
    'out-of-order describe and shared credential events keep the newest status',
    () async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      controller.start();
      await controller.refresh();
      final older = Completer<dynamic>();
      var pending = true;
      runtime.handle = (method, args) async {
        if (pending) return older.future;
        return {
          'SHARED_KEY': {'configured': false, 'writable': true},
        };
      };
      final read = controller.readReference('SHARED_KEY');
      pending = false;
      runtime.notifications.add({
        'event': 'credentials/reference-updated',
        'args': ['SHARED_KEY'],
      });
      await Future<void>.delayed(Duration.zero);
      older.complete({
        'SHARED_KEY': {'configured': true, 'writable': true},
      });
      await read;
      expect(controller.entry('SHARED_KEY').status!.configured, isFalse);
      expect(controller.entry('SHARED_KEY').fresh, isTrue);
    },
  );

  testWidgets(
    'timeout retains ownership of the original request until its receipt',
    (tester) async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await controller.refresh();
      final reply = Completer<dynamic>();
      runtime.handle = (method, args) async {
        if (method == 'set') return reply.future;
        return {
          'SHARED_KEY': {'configured': true, 'writable': true},
        };
      };
      controller.edit('SHARED_KEY', 'pending-fixture');
      final write = controller.save('SHARED_KEY');
      await tester.pump(credentialRequestTimeout);
      await write;
      final row = controller.entry('SHARED_KEY');
      expect(row.write!.state, 'unconfirmed');
      expect(row.write!.inFlight, isTrue);
      expect(row.draft, 'pending-fixture');
      await controller.save('SHARED_KEY', acknowledgeUnknown: true);
      expect(runtime.calls('set'), hasLength(1));
      reply.complete(null);
      await tester.pump();
      expect(row.write!.state, 'confirmed');
      expect(row.draft, isEmpty);
    },
  );

  testWidgets(
    'failed input survives page navigation and removal requires its own confirmation',
    (tester) async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await mount(tester, controller);
      await openShared(tester);
      expect(find.byType(TextField), findsNothing);
      await editValue(tester);
      final field = find.byKey(const ValueKey('credential-value-input'));
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      runtime.handle = (method, args) async {
        if (method == 'set') throw PlatformException(code: 'disconnected');
        if (method == 'unset') return null;
        return {
          'SHARED_KEY': {'configured': true, 'writable': true},
        };
      };
      await tester.enterText(field, 'kept-draft-fixture');
      await finishEditing(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('kept-draft-fixture'), findsNothing);
      expect(find.text('已填写'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('credential-save')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '返回',
        ),
      );
      await tester.pumpAndSettle();
      await openShared(tester);
      await editValue(tester);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'kept-draft-fixture',
      );
      await finishEditing(tester);
      expect(runtime.calls('set'), hasLength(1));
      await tester.ensureVisible(find.text('移除保存的凭据'));
      await tester.tap(find.text('移除保存的凭据'));
      await tester.pumpAndSettle();
      expect(runtime.calls('unset'), isEmpty);
      final confirm = find.text('确认移除');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(runtime.calls('unset'), hasLength(1));
      expect(controller.entry('SHARED_KEY').draft, 'kept-draft-fixture');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual references use the same service without reading a stored value',
    (tester) async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await mount(tester, controller);
      await tester.tap(find.text('指定其他凭据引用'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('credential-reference-row')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('credential-reference-input')),
        'bad/key',
      );
      await finishEditing(tester);
      expect(find.textContaining('使用字母或下划线开头'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('credential-reference-input')),
        'PLUGIN_TOKEN',
      );
      await finishEditing(tester);
      await tester.tap(find.text('查看凭据'));
      await tester.pumpAndSettle();
      expect(find.byType(CredentialReferencePage), findsOneWidget);
      expect(controller.entries.containsKey('PLUGIN_TOKEN'), isTrue);
      expect(runtime.sent.every((call) => call.$1 == 'describe'), isTrue);
      await editValue(tester);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('credential-value-input')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discarding a secret editor leaves its original draft untouched',
    (tester) async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await mount(tester, controller);
      await openShared(tester);
      await editValue(tester);
      await tester.enterText(
        find.byKey(const ValueKey('credential-value-input')),
        'unsaved-secret-fixture',
      );
      expect(controller.entry('SHARED_KEY').draft, isEmpty);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃编辑并返回'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('未填写'), findsOneWidget);
      expect(find.text('unsaved-secret-fixture'), findsNothing);
      expect(controller.entry('SHARED_KEY').draft, isEmpty);
      expect(runtime.calls('set'), isEmpty);
    },
  );

  testWidgets(
    'a changed credential draft cannot be overwritten by an older editor',
    (tester) async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await mount(tester, controller);
      await openShared(tester);
      await editValue(tester);
      final field = find.byKey(const ValueKey('credential-value-input'));
      await tester.enterText(field, 'local-secret-fixture');
      controller.edit('SHARED_KEY', 'newer-secret-fixture');
      await tester.pumpAndSettle();
      final done = tester.widget<GlassButton>(
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '完成编辑',
        ),
      );
      expect(done.onPressed, isNull);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'local-secret-fixture',
      );
      expect(controller.entry('SHARED_KEY').draft, 'newer-secret-fixture');
      expect(runtime.calls('set'), isEmpty);
    },
  );

  testWidgets(
    'unknown credential writes need a fresh explicit overwrite confirmation',
    (tester) async {
      final runtime = CredentialRuntime();
      final controller = CredentialsController(runtime);
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      await mount(tester, controller);
      controller.edit('SHARED_KEY', 'fixture-secret');
      runtime.handle = (method, args) async {
        if (method == 'set') throw PlatformException(code: 'disconnected');
        return {
          'SHARED_KEY': {'configured': true, 'writable': true},
        };
      };
      await controller.save('SHARED_KEY');
      await tester.pumpAndSettle();
      await openShared(tester);
      await tester.tap(find.byKey(const ValueKey('credential-save')));
      await tester.pumpAndSettle();
      expect(find.text('重新保存凭据？'), findsOneWidget);
      expect(runtime.calls('set'), hasLength(1));
      await tester.tap(find.text('继续核对'));
      await tester.pumpAndSettle();
      expect(runtime.calls('set'), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('credential-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认重新保存'));
      await tester.pumpAndSettle();
      expect(runtime.calls('set'), hasLength(2));
      expect(controller.entry('SHARED_KEY').draft, 'fixture-secret');
      expect(find.text('fixture-secret'), findsNothing);
    },
  );
}
