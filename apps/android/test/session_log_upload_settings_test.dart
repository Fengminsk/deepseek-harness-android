import 'dart:async';

import 'package:dsh_android/configuration_boolean_preference.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_log_upload_settings.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json _descriptor({bool enabled = true}) => {
  'ns': 'session-log-deepseek',
  'revision': 5,
  'value': {'enabled': enabled},
  'base': {'enabled': true},
  'user': {'enabled': enabled},
  'schema': {
    'type': 'object',
    'dict': {
      'enabled': {'type': 'boolean'},
    },
  },
  'secrets': <Json>[],
};

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
    forms = [_descriptor()];
  }

  Json remote = _descriptor();
  bool writable = true;
  int generation = 0;
  final writes = <Json>[];
  Future<dynamic> Function()? onRead;
  Future<dynamic> Function(Json)? onWrite;

  @override
  int get connectionGeneration => generation;

  void reconnect() {
    generation++;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'api.call' || params['namespace'] != 'settings') {
      throw StateError('Unexpected call $method');
    }
    if (params['method'] == 'describe') {
      return onRead == null
          ? {
              'writable': writable,
              'namespaces': [cloneConfiguration(remote)],
            }
          : onRead!();
    }
    if (params['method'] == 'mutate') {
      final args = cloneConfiguration(params['args'] as Json);
      writes.add(args);
      if (onWrite != null) return onWrite!(args);
      expect(args['expectedRevision'], remote['revision']);
      for (final raw in args['ops'] as List) {
        applyConfigurationEdit(remote['value'] as Json, raw as Json);
        applyConfigurationEdit(remote['user'] as Json, raw);
      }
      remote['revision'] = (remote['revision'] as int) + 1;
      return cloneConfiguration(remote);
    }
    throw StateError('Unexpected settings method ${params['method']}');
  }
}

void main() {
  test(
    'reads the accepted Host value and saves one revisioned boolean',
    () async {
      final runtime = _Runtime();
      final preference = ConfigurationBooleanPreference(
        runtime,
        namespace: 'session-log-deepseek',
      );
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      final read = Completer<dynamic>();
      runtime.onRead = () => read.future;
      final start = preference.start();
      expect(preference.canChange, isFalse);
      expect(await preference.setValue(false), isFalse);
      read.complete({
        'writable': true,
        'namespaces': [cloneConfiguration(runtime.remote)],
      });
      await start;
      runtime.onRead = null;
      expect(preference.value, isTrue);
      expect(preference.canChange, isTrue);
      expect(await preference.setValue(false), isTrue);
      expect(preference.value, isFalse);
      expect(runtime.writes.single, {
        'ns': 'session-log-deepseek',
        'expectedRevision': 5,
        'ops': [
          {
            'op': 'set',
            'path': ['enabled'],
            'value': false,
          },
        ],
      });
    },
  );

  test('read-only and non-boolean Host fields never become editable', () async {
    final runtime = _Runtime()..writable = false;
    final preference = ConfigurationBooleanPreference(
      runtime,
      namespace: 'session-log-deepseek',
    );
    addTearDown(() {
      preference.dispose();
      runtime.dispose();
    });
    await preference.start();
    expect(preference.confirmed, isTrue);
    expect(preference.canChange, isFalse);
    runtime.writable = true;
    (runtime.remote['schema']['dict']['enabled'] as Json)['type'] = 'string';
    await preference.refresh();
    expect(preference.confirmed, isFalse);
    expect(await preference.setValue(false), isFalse);
    expect(runtime.writes, isEmpty);
  });

  test(
    'uncertain write cannot repeat and requires explicit reconciliation',
    () async {
      final runtime = _Runtime();
      final preference = ConfigurationBooleanPreference(
        runtime,
        namespace: 'session-log-deepseek',
      );
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      await preference.start();
      runtime.onWrite = (_) async => throw StateError('reply lost');
      expect(await preference.setValue(false), isFalse);
      expect(preference.value, isTrue);
      expect(preference.needsReview, isTrue);
      expect(await preference.setValue(false), isFalse);
      expect(runtime.writes, hasLength(1));
      await preference.refresh();
      expect(preference.canAdoptCurrent, isTrue);
      expect(runtime.writes, hasLength(1));
      preference.adoptCurrent();
      expect(preference.canChange, isTrue);
    },
  );

  test('connection change discards a stale read', () async {
    final runtime = _Runtime();
    final preference = ConfigurationBooleanPreference(
      runtime,
      namespace: 'session-log-deepseek',
    );
    addTearDown(() {
      preference.dispose();
      runtime.dispose();
    });
    await preference.start();
    final old = Completer<dynamic>();
    runtime.onRead = () => old.future;
    final stale = preference.refresh();
    runtime.remote['value']['enabled'] = false;
    runtime.onRead = () async => {
      'writable': true,
      'namespaces': [cloneConfiguration(runtime.remote)],
    };
    runtime.reconnect();
    await preference.refresh();
    old.complete({
      'writable': true,
      'namespaces': [_descriptor()],
    });
    await stale;
    expect(preference.value, isFalse);
  });

  testWidgets('only a served namespace gets a General switch', (tester) async {
    final runtime = _Runtime()..forms = [];
    addTearDown(runtime.dispose);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RuntimeController.channel, (call) async {
      if (call.method == 'app.metadata') {
        return '{"version":"0.1.0","build":51}';
      }
      throw StateError('Unexpected native method ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
    );
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SettingsPage(runtime: runtime),
      ),
    );
    await tester.pump();
    expect(find.byType(SessionLogUploadSettingsRow), findsNothing);
    runtime.forms = [_descriptor()];
    runtime.notifyListeners();
    await tester.pump();
    expect(find.byType(SessionLogUploadSettingsRow), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-log-upload-switch')),
      findsOneWidget,
    );
    expect(find.textContaining('JSON'), findsNothing);
    runtime.forms = [];
    runtime.notifyListeners();
    await tester.pump();
    expect(find.byType(SessionLogUploadSettingsRow), findsNothing);
  });
}
