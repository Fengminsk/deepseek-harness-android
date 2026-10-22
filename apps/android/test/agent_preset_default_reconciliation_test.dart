import 'dart:async';

import 'package:dsh_android/agent_preset_default_reconciliation.dart';
import 'package:dsh_android/agent_presets_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/workspace_changes_preference.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }

  bool toolsEnabled = false, writable = true, standardBroken = false;
  String defaultPreset = 'minimal';
  String? defaultName;
  int presetRevision = 7, toolsRevision = 2, generation = 0;
  int writes = 0;
  Json? lastWrite;
  Future<dynamic> Function()? rosterReply;
  Future<dynamic> Function()? writeReply;

  @override
  int get connectionGeneration => generation;

  Json get toolsDescriptor => {
    'ns': 'ui-settings',
    'revision': toolsRevision,
    'value': {'enabled': toolsEnabled},
    'base': {'enabled': true},
    'user': {'enabled': toolsEnabled},
    'schema': {
      'type': 'object',
      'dict': {
        'enabled': {'type': 'boolean'},
      },
    },
    'secrets': <Json>[],
  };

  Json get presetDescriptor => {
    'ns': agentPresetSettingsNamespace,
    'revision': presetRevision,
    'value': {'selectedDefault': defaultPreset},
  };

  Json get roster => {
    'presets': [
      {
        'id': 'standard',
        'isDefault': defaultPreset == 'standard',
        if (standardBroken) 'broken': 'unavailable',
      },
      if (defaultPreset != 'standard')
        {
          'id': defaultPreset,
          'isDefault': true,
          if (defaultName != null) 'name': defaultName,
        },
    ],
  };

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'api.call');
    final key = '${params['namespace']}.${params['method']}';
    switch (key) {
      case 'settings.describe':
        return {
          'writable': writable,
          'namespaces': [toolsDescriptor, presetDescriptor],
        };
      case 'agentPresets.list':
        return rosterReply == null ? roster : rosterReply!();
      case 'settings.update':
        writes++;
        lastWrite = params['args'] as Json;
        if (writeReply != null) return writeReply!();
        if (lastWrite!['expectedRevision'] != presetRevision) {
          throw PlatformException(code: 'settings/conflict');
        }
        defaultPreset = lastWrite!['patch']['selectedDefault'] as String;
        presetRevision++;
        return presetDescriptor;
      default:
        throw StateError('Unexpected $key');
    }
  }

  void changeTools(bool enabled) {
    toolsEnabled = enabled;
    toolsRevision++;
    forms = List.of(forms);
    notifyListeners();
  }

  void reconnect() {
    generation++;
    notifyListeners();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final id in ['ptc', 'minimal']) {
    test('accepted disabled Coding Tools resets built-in $id once', () async {
      final runtime = _Runtime()..defaultPreset = id;
      final preference = WorkspaceChangesPreference(runtime);
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      await preference.start();
      await _settle();
      expect(preference.confirmed, isTrue);
      expect(runtime.defaultPreset, 'standard');
      expect(runtime.lastWrite, {
        'ns': agentPresetSettingsNamespace,
        'patch': {'selectedDefault': 'standard'},
        'expectedRevision': 7,
      });
      runtime.changeTools(false);
      await _settle();
      expect(runtime.writes, 1);
    });
  }

  test(
    'multiple preferences over one Runtime share one Host correction',
    () async {
      final runtime = _Runtime();
      final chat = WorkspaceChangesPreference(runtime);
      final changes = WorkspaceChangesPreference(runtime);
      addTearDown(() {
        chat.dispose();
        changes.dispose();
        runtime.dispose();
      });
      expect(
        identical(chat.defaultReconciler, changes.defaultReconciler),
        isTrue,
      );
      await Future.wait([chat.start(), changes.start()]);
      await _settle();
      expect(runtime.defaultPreset, 'standard');
      expect(runtime.writes, 1);
    },
  );

  test(
    'bootstrap false is not a selection; enable then disable uses Host state',
    () async {
      final runtime = _Runtime()..toolsEnabled = true;
      final preference = WorkspaceChangesPreference(runtime);
      addTearDown(() {
        preference.dispose();
        runtime.dispose();
      });
      expect(preference.confirmed, isFalse);
      expect(runtime.writes, 0);
      await preference.start();
      expect(runtime.writes, 0);
      runtime.changeTools(false);
      await _settle();
      expect(runtime.writes, 1);
    },
  );

  test(
    'named override and unavailable Standard never change the default',
    () async {
      for (final customize in [true, false]) {
        final runtime = _Runtime()
          ..defaultPreset = 'ptc'
          ..defaultName = customize ? 'My PTC' : null
          ..standardBroken = !customize;
        final preference = WorkspaceChangesPreference(runtime);
        await preference.start();
        await _settle();
        expect(runtime.writes, 0);
        expect(runtime.defaultPreset, 'ptc');
        if (!customize) {
          expect(preference.defaultReconciler.error, contains('标准模式不可用'));
        }
        preference.dispose();
        runtime.dispose();
      }
    },
  );

  test('connection change while roster is loading fences the write', () async {
    final runtime = _Runtime();
    final pending = Completer<dynamic>();
    runtime.rosterReply = () => pending.future;
    final reconciler = AgentPresetDefaultReconciler(runtime);
    reconciler.attach(() => true);
    addTearDown(() {
      reconciler.dispose();
      runtime.dispose();
    });
    final task = reconciler.reconcile();
    await _settle();
    runtime.reconnect();
    pending.complete(runtime.roster);
    await task;
    expect(runtime.writes, 0);
  });

  test(
    'connection change after submit marks unknown and never resends',
    () async {
      final runtime = _Runtime();
      final pending = Completer<dynamic>();
      runtime.writeReply = () => pending.future;
      final reconciler = AgentPresetDefaultReconciler(runtime);
      reconciler.attach(() => true);
      addTearDown(() {
        reconciler.dispose();
        runtime.dispose();
      });
      final task = reconciler.reconcile();
      await _settle();
      expect(runtime.writes, 1);
      runtime.reconnect();
      pending.complete(runtime.presetDescriptor);
      await task;
      expect(reconciler.uncertain, isTrue);
      await reconciler.review();
      expect(runtime.writes, 1);
    },
  );

  test(
    'unknown write reply never replays the same default correction',
    () async {
      final runtime = _Runtime();
      runtime.writeReply = () async =>
          throw PlatformException(code: 'disconnected');
      final reconciler = AgentPresetDefaultReconciler(runtime);
      reconciler.attach(() => true);
      addTearDown(() {
        reconciler.dispose();
        runtime.dispose();
      });
      await reconciler.reconcile();
      expect(reconciler.uncertain, isTrue);
      expect(runtime.writes, 1);
      await reconciler.reconcile();
      expect(runtime.writes, 1);
      runtime.defaultPreset = 'standard';
      runtime.presetRevision++;
      await reconciler.reconcile();
      expect(reconciler.uncertain, isFalse);
      expect(runtime.writes, 1);
    },
  );

  test(
    'revision conflict does not replay against the stale revision',
    () async {
      final runtime = _Runtime();
      runtime.writeReply = () async =>
          throw PlatformException(code: 'settings/conflict');
      final reconciler = AgentPresetDefaultReconciler(runtime);
      reconciler.attach(() => true);
      addTearDown(() {
        reconciler.dispose();
        runtime.dispose();
      });
      await reconciler.reconcile();
      await reconciler.reconcile();
      expect(runtime.writes, 1);
      expect(reconciler.uncertain, isFalse);
      expect(runtime.defaultPreset, 'minimal');
    },
  );
}
