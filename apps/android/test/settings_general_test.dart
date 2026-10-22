import 'dart:async';

import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/settings_general.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/workspace_changes_preference.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json settingsDescriptor({bool enabled = true}) => {
  'ns': 'ui-settings',
  'revision': 1,
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

class GeneralRuntime extends RuntimeController {
  GeneralRuntime() {
    phase = 'ready';
  }

  Json remote = settingsDescriptor();
  int generation = 0, reads = 0;
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
    expect(method, 'api.call');
    expect(params['namespace'], 'settings');
    if (params['method'] == 'describe') {
      reads++;
      return onRead == null
          ? {
              'writable': true,
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
    throw StateError('Unexpected method ${params['method']}');
  }
}

class FallbackRuntime extends GeneralRuntime {
  FallbackRuntime() {
    remote = settingsDescriptor(enabled: false);
    onRead = () async => {
      'writable': true,
      'namespaces': [
        cloneConfiguration(remote),
        {
          'ns': 'agent-preset-registry',
          'revision': 7,
          'value': {'selectedDefault': 'minimal'},
        },
      ],
    };
  }

  int defaultWrites = 0;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'api.call' &&
        params['namespace'] == 'settings' &&
        params['method'] == 'describe') {
      return onRead!();
    }
    if (method == 'api.call' && params['namespace'] == 'agentPresets') {
      return {
        'presets': [
          {'id': 'standard', 'isDefault': false},
          {'id': 'minimal', 'isDefault': true},
        ],
      };
    }
    if (method == 'api.call' &&
        params['namespace'] == 'settings' &&
        params['method'] == 'update') {
      defaultWrites++;
      throw PlatformException(code: 'disconnected');
    }
    return super.call(method, params);
  }
}

void main() {
  test(
    'uses accepted Host value and one revisioned write for the switch',
    () async {
      final runtime = GeneralRuntime();
      final pending = Completer<dynamic>();
      runtime.onRead = () => pending.future;
      final preference = DeveloperToolsPreference(runtime);
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      final start = preference.start();
      expect(preference.confirmed, isFalse);
      expect(preference.canChange, isFalse);
      expect(await preference.setEnabled(false), isFalse);
      expect(runtime.writes, isEmpty);

      pending.complete({
        'writable': true,
        'namespaces': [cloneConfiguration(runtime.remote)],
      });
      await start;
      runtime.onRead = null;
      expect(preference.enabled, isTrue);
      expect(preference.canChange, isTrue);

      final result = await preference.setEnabled(false);
      expect(result, isTrue);
      expect(preference.enabled, isFalse);
      expect(runtime.writes.single, {
        'ns': 'ui-settings',
        'expectedRevision': 1,
        'ops': [
          {
            'op': 'set',
            'path': ['enabled'],
            'value': false,
          },
        ],
      });
      expect(await preference.setEnabled(false), isFalse);
      expect(runtime.writes.length, 1);
    },
  );

  test(
    'does not show an unacknowledged choice or duplicate a pending write',
    () async {
      final runtime = GeneralRuntime();
      final preference = DeveloperToolsPreference(runtime);
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      await preference.start();
      final pending = Completer<dynamic>();
      final submitted = Completer<void>();
      runtime.onWrite = (_) {
        submitted.complete();
        return pending.future;
      };
      final first = preference.setEnabled(false);
      await submitted.future;
      expect(preference.enabled, isTrue);
      expect(preference.canChange, isFalse);
      expect(await preference.setEnabled(false), isFalse);
      expect(runtime.writes.length, 1);
      pending.complete(cloneConfiguration(runtime.remote));
      expect(await first, isFalse);
      expect(preference.enabled, isTrue);
      expect(preference.needsReview, isTrue);
    },
  );

  test(
    'connection change fences stale observation and requires fresh Host state',
    () async {
      final runtime = GeneralRuntime();
      final preference = DeveloperToolsPreference(runtime);
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      await preference.start();
      expect(preference.enabled, isTrue);
      final old = Completer<dynamic>();
      runtime.onRead = () => old.future;
      final stale = preference.refresh();
      runtime.remote['value']['enabled'] = false;
      final reloaded = Completer<void>();
      runtime.onRead = () async {
        reloaded.complete();
        return {
          'writable': true,
          'namespaces': [cloneConfiguration(runtime.remote)],
        };
      };
      runtime.reconnect();
      await reloaded.future;
      await preference.refresh();
      expect(preference.enabled, isFalse);
      old.complete({
        'writable': true,
        'namespaces': [settingsDescriptor()],
      });
      await stale;
      expect(preference.enabled, isFalse);
      expect(preference.confirmed, isTrue);
    },
  );

  testWidgets('renders a normal switch with retry guidance rather than JSON', (
    tester,
  ) async {
    final runtime = GeneralRuntime();
    addTearDown(runtime.dispose);
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: const Scaffold(body: SizedBox.shrink()),
        builder: (context, child) =>
            Scaffold(body: DeveloperToolsSettingsRow(runtime: runtime)),
      ),
    );
    await tester.pump();
    expect(find.text('显示代码工作视图'), findsOneWidget);
    expect(find.textContaining('enabled'), findsNothing);
    expect(find.textContaining('JSON'), findsNothing);
    expect(
      find.byKey(const ValueKey('developer-tools-switch')),
      findsOneWidget,
    );
  });

  testWidgets('unknown default fallback is visible and review never resends', (
    tester,
  ) async {
    final runtime = FallbackRuntime();
    final owner = WorkspaceChangesPreference(runtime);
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() {
      owner.dispose();
      runtime.dispose();
    });
    await owner.start();
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
    expect(runtime.defaultWrites, 1);
    expect(owner.defaultReconciler.uncertain, isTrue);
    expect(owner.defaultReconciler.error, contains('不会自动重发'));

    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: Scaffold(body: DeveloperToolsSettingsRow(runtime: runtime)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('coding-tools-default-review')),
      findsOneWidget,
    );
    expect(find.text(owner.defaultReconciler.error!), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('coding-tools-default-review')));
    await tester.pump();
    expect(runtime.defaultWrites, 1);
    expect(owner.defaultReconciler.uncertain, isTrue);
  });
}
