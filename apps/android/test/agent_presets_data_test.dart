import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/agent_presets_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

dynamic _copy(dynamic value) => jsonDecode(jsonEncode(value));

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  final calls = <({String method, Json params})>[];
  StreamController<Json> stream = StreamController<Json>.broadcast(sync: true);
  final overrides = <String, Future<dynamic> Function()>{};
  List<Json> presets = [
    {'id': 'android', 'name': 'Android', 'isDefault': true},
    {'id': 'custom', 'name': 'Custom', 'isDefault': false},
  ];
  String defaultPreset = 'android';
  String? sessionPreset = 'android';
  int revision = 1, generation = 1, observations = 0;
  bool exists = false, blank = true, writable = true;
  Object? writeFailure;

  @override
  int get connectionGeneration => generation;

  Json get descriptor => {
    'ns': agentPresetSettingsNamespace,
    'revision': revision,
    'value': {'default': 'android', 'selectedDefault': defaultPreset},
  };

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    observations++;
    return stream.stream;
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: _copy(params) as Json));
    final key = method == 'api.call'
        ? '${params['namespace']}.${params['method']}'
        : method;
    final override = overrides[key];
    if (override != null) return override();
    switch (key) {
      case 'agentPresets.list':
        return {'presets': _copy(presets)};
      case 'settings.describe':
        return {
          'writable': writable,
          'namespaces': [descriptor],
        };
      case 'session.list':
        return {
          'items': [
            if (exists) {'sessionId': 's', 'blank': blank},
          ],
        };
      case 'session.projections':
        return exists
            ? {
                'kind': 'sequenced',
                'asOfSeq': 7,
                'values': {'agentPreset': sessionPreset},
              }
            : null;
      case 'agentPresets.read':
        return {
          'agentPreset': params['args']['agentPreset'],
          'content': '- name: android-shell\n',
        };
      case 'settings.update':
        if (writeFailure != null) throw writeFailure!;
        if (params['args']['expectedRevision'] != revision) {
          throw PlatformException(
            code: 'settings/conflict',
            message: 'revision changed',
          );
        }
        defaultPreset = params['args']['patch']['selectedDefault'] as String;
        revision++;
        presets = [
          for (final row in presets)
            {...row, 'isDefault': row['id'] == defaultPreset},
        ];
        return descriptor;
      case 'session.selectPreset':
        if (writeFailure != null) throw writeFailure!;
        exists = true;
        sessionPreset = params['agentPreset'] as String;
        return sessionPreset;
      default:
        throw StateError('Unexpected operation: $key');
    }
  }

  List<({String method, Json params})> get writes => calls
      .where(
        (call) =>
            call.method == 'session.selectPreset' ||
            call.method == 'api.call' && call.params['method'] == 'update',
      )
      .toList();

  void reconnect() {
    generation++;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stream.close());
    super.dispose();
  }
}

void main() {
  test(
    'default management reads actual roster and writes the observed revision',
    () async {
      final runtime = _Runtime();
      final controller = AgentPresetsController(runtime);
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      expect(controller.appliedId, 'android');
      controller.select('custom');
      expect(controller.canApply, isTrue);
      await controller.apply();
      await controller.load();
      expect(runtime.writes.single.params['args'], {
        'ns': agentPresetSettingsNamespace,
        'patch': {'selectedDefault': 'custom'},
        'expectedRevision': 1,
      });
      expect(controller.appliedId, 'custom');
      expect(controller.hasDraft, isFalse);
    },
  );

  test(
    'reading a missing session and its declaration never creates an Agent',
    () async {
      final runtime = _Runtime();
      final controller = AgentPresetsController(runtime, sessionId: 's');
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      expect(controller.sessionExists, isFalse);
      expect(controller.sessionStarted, isFalse);
      expect(controller.appliedId, 'android');
      expect(
        (await controller.readDocument('android')).content,
        contains('android-shell'),
      );
      expect(runtime.writes, isEmpty);
      expect(
        runtime.calls.any((call) => call.method == 'session.ensure'),
        isFalse,
      );
      controller.select('custom');
      await controller.apply();
      expect(runtime.writes.single.params, {
        'sessionId': 's',
        'agentPreset': 'custom',
      });
      await controller.load();
      expect(controller.sessionExists, isTrue);
      expect(controller.appliedId, 'custom');
    },
  );

  test(
    'existing session displays its composition instead of the global default',
    () async {
      final runtime = _Runtime()
        ..exists = true
        ..blank = false
        ..sessionPreset = 'custom';
      final controller = AgentPresetsController(runtime, sessionId: 's');
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      expect(controller.defaultId, 'android');
      expect(controller.appliedId, 'custom');
      expect(controller.sessionStarted, isTrue);
      expect(controller.canChoose, isFalse);
      controller.select('android');
      await controller.apply();
      expect(runtime.writes, isEmpty);
    },
  );

  test('failed projection keeps the known session instead of substituting a default', () async {
    final runtime = _Runtime()
      ..exists = true
      ..sessionPreset = 'custom';
    final controller = AgentPresetsController(runtime, sessionId: 's');
    addTearDown(controller.dispose);
    addTearDown(runtime.dispose);
    await controller.load();
    runtime.overrides['session.projections'] = () async =>
        throw PlatformException(code: 'gateway/internal');
    await controller.refresh();
    expect(controller.appliedId, 'custom');
    expect(controller.fresh, isFalse);
    expect(controller.canChoose, isFalse);
    expect(runtime.writes, isEmpty);
  });

  test(
    'migration hints and inconsistent absence cannot authorize a selection',
    () async {
      final runtime = _Runtime()..exists = true;
      final controller = AgentPresetsController(runtime, sessionId: 's');
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      runtime.overrides['session.projections'] = () async => {
        'kind': 'migration-required',
        'values': {'agentPreset': 'custom'},
      };
      await controller.load();
      expect(controller.fresh, isFalse);
      expect(controller.appliedId, isNull);
      runtime.overrides['session.projections'] = () async => null;
      await controller.load();
      expect(controller.fresh, isFalse);
      expect(controller.sessionStarted, isNull);
      expect(runtime.writes, isEmpty);
    },
  );

  test(
    'single flight and connection generation reject a late old roster',
    () async {
      final runtime = _Runtime();
      final old = Completer<dynamic>();
      runtime.overrides['agentPresets.list'] = () => old.future;
      final controller = AgentPresetsController(runtime);
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      final first = controller.load();
      expect(controller.load(), same(first));
      runtime.overrides.remove('agentPresets.list');
      runtime.presets = [
        {'id': 'android', 'name': 'New roster', 'isDefault': true},
      ];
      runtime.reconnect();
      await controller.load();
      expect(controller.options.single.name, 'New roster');
      old.complete({
        'presets': [
          {'id': 'old', 'isDefault': true},
        ],
      });
      await first;
      expect(controller.options.single.name, 'New roster');
      expect(controller.fresh, isTrue);
    },
  );

  test(
    'external settings change retains draft and requires explicit rebase',
    () async {
      final runtime = _Runtime();
      final controller = AgentPresetsController(runtime);
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      controller.select('custom');
      runtime.revision = 2;
      await controller.load();
      expect(controller.draftId, 'custom');
      expect(controller.conflict, isTrue);
      await controller.apply();
      expect(runtime.writes, isEmpty);
      controller.rebaseDraft();
      await controller.apply();
      expect(runtime.writes.single.params['args']['expectedRevision'], 2);
    },
  );

  test('write conflict retains the draft without retrying', () async {
    final runtime = _Runtime()
      ..writeFailure = PlatformException(code: 'settings/conflict');
    final controller = AgentPresetsController(runtime);
    addTearDown(controller.dispose);
    addTearDown(runtime.dispose);
    await controller.load();
    controller.select('custom');
    await controller.apply();
    await controller.load();
    expect(controller.draftId, 'custom');
    expect(controller.conflict, isTrue);
    expect(controller.uncertain, isFalse);
    expect(runtime.writes, hasLength(1));
    await controller.apply();
    expect(runtime.writes, hasLength(1));
  });

  test(
    'unknown write remains blocked through reads until observed state matches',
    () async {
      final runtime = _Runtime()..writeFailure = StateError('transport lost');
      final controller = AgentPresetsController(runtime);
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      controller.select('custom');
      await controller.apply();
      await controller.load();
      expect(controller.uncertain, isTrue);
      expect(controller.draftId, 'custom');
      expect(controller.canChoose, isFalse);
      controller.select('android');
      expect(controller.draftId, 'custom');
      await controller.apply();
      controller.rebaseDraft();
      expect(controller.uncertain, isTrue);
      expect(runtime.writes, hasLength(1));
      runtime.defaultPreset = 'custom';
      runtime.revision++;
      await controller.load();
      expect(controller.uncertain, isFalse);
      expect(controller.hasDraft, isFalse);
      expect(controller.error, isNull);
      expect(runtime.writes, hasLength(1));
    },
  );

  test('generation change during selection does not publish an old success or retry', () async {
    final runtime = _Runtime();
    final receipt = Completer<dynamic>();
    final submitted = Completer<void>();
    runtime.overrides['session.selectPreset'] = () {
      submitted.complete();
      return receipt.future;
    };
    final controller = AgentPresetsController(runtime, sessionId: 's');
    addTearDown(controller.dispose);
    addTearDown(runtime.dispose);
    await controller.load();
    controller.select('custom');
    final applying = controller.apply();
    await submitted.future;
    runtime.reconnect();
    receipt.complete('custom');
    await applying;
    await controller.load();
    expect(controller.uncertain, isTrue);
    expect(controller.appliedId, 'android');
    expect(controller.draftId, 'custom');
    expect(runtime.writes, hasLength(1));
  });

  test('first turn race preserves the original locked refusal', () async {
    final runtime = _Runtime()..exists = true;
    runtime.overrides['session.selectPreset'] = () async {
      runtime.blank = false;
      throw PlatformException(
        code: 'agent-preset/locked',
        message: 'already started',
      );
    };
    final controller = AgentPresetsController(runtime, sessionId: 's');
    addTearDown(controller.dispose);
    addTearDown(runtime.dispose);
    await controller.load();
    controller.select('custom');
    await controller.apply();
    await controller.load();
    expect(controller.sessionStarted, isTrue);
    expect(controller.draftId, 'custom');
    expect(controller.canApply, isFalse);
    expect(controller.uncertain, isFalse);
    expect(runtime.writes, hasLength(1));
  });

  test(
    'broken and removed presets stay visible but cannot be applied',
    () async {
      final runtime = _Runtime();
      runtime.presets.add({
        'id': 'broken',
        'isDefault': false,
        'broken': 'load failure',
      });
      final controller = AgentPresetsController(runtime);
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      controller.select('broken');
      expect(controller.draftId, 'android');
      expect(controller.options.last.broken, 'load failure');
      controller.select('custom');
      runtime.presets.removeWhere((row) => row['id'] == 'custom');
      await controller.apply();
      expect(controller.draftId, 'custom');
      expect(controller.canApply, isFalse);
      expect(runtime.writes, isEmpty);
    },
  );

  test('optional missing roster is a valid empty catalog', () async {
    final runtime = _Runtime();
    runtime.overrides['agentPresets.list'] = () async =>
        throw PlatformException(code: 'gateway/invocation-unavailable');
    runtime.overrides['settings.describe'] = () async => {
      'writable': true,
      'namespaces': [],
    };
    final controller = AgentPresetsController(runtime);
    addTearDown(controller.dispose);
    addTearDown(runtime.dispose);
    await controller.load();
    expect(controller.options, isEmpty);
    expect(controller.fresh, isTrue);
    expect(controller.error, isNull);
    expect(controller.canApply, isFalse);
  });

  test('read-only settings do not admit a default write', () async {
    final runtime = _Runtime()..writable = false;
    final controller = AgentPresetsController(runtime);
    addTearDown(controller.dispose);
    addTearDown(runtime.dispose);
    await controller.load();
    controller.select('custom');
    expect(controller.canApply, isFalse);
    await controller.apply();
    expect(runtime.writes, isEmpty);
    expect(controller.error, contains('不允许'));
  });

  test(
    'preset projection notification refreshes only the addressed session',
    () async {
      final runtime = _Runtime()..exists = true;
      final controller = AgentPresetsController(runtime, sessionId: 's');
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      runtime.sessionPreset = 'custom';
      runtime.stream.add({
        'type': 'item',
        'value': {
          'type': 'projection',
          'sessionId': 'other',
          'key': 'agentPreset',
          'value': 'custom',
          'seq': 8,
        },
      });
      expect(controller.fresh, isTrue);
      expect(controller.appliedId, 'android');
      runtime.stream.add({
        'type': 'item',
        'value': {
          'type': 'projection',
          'sessionId': 's',
          'key': 'agentPreset',
          'value': 'custom',
          'seq': 8,
        },
      });
      expect(controller.fresh, isFalse);
      await controller.load();
      expect(controller.appliedId, 'custom');
      expect(runtime.observations, 1);
      expect(runtime.writes, isEmpty);
    },
  );

  test('disposal and reconnect discard stale declaration reads', () async {
    final runtime = _Runtime();
    final read = Completer<dynamic>();
    runtime.overrides['agentPresets.read'] = () => read.future;
    final controller = AgentPresetsController(runtime);
    addTearDown(runtime.dispose);
    final reading = controller.readDocument('android');
    controller.dispose();
    read.complete({'agentPreset': 'android', 'content': 'old declaration'});
    await expectLater(reading, throwsStateError);
    expect(runtime.writes, isEmpty);
  });

  test(
    'refresh replaces an ended observation but not a transient stream error',
    () async {
      final runtime = _Runtime();
      final controller = AgentPresetsController(runtime, sessionId: 's');
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      runtime.stream.addError(StateError('temporary read failure'));
      await controller.refresh();
      expect(runtime.observations, 1);
      final ended = runtime.stream;
      runtime.stream = StreamController<Json>.broadcast(sync: true);
      await ended.close();
      expect(controller.fresh, isFalse);
      await controller.refresh();
      expect(runtime.observations, 2);
      expect(controller.fresh, isTrue);
      expect(runtime.writes, isEmpty);
    },
  );

  test(
    'observation recovery preserves mutation refusal until explicit revision',
    () async {
      final runtime = _Runtime()
        ..writeFailure = PlatformException(
          code: 'settings/rejected',
          message: 'configuration is read-only now',
        );
      final controller = AgentPresetsController(runtime);
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      controller.select('custom');
      await controller.apply();
      await controller.load();
      expect(controller.error, contains('configuration is read-only now'));
      expect(controller.draftId, 'custom');
      runtime.overrides['agentPresets.list'] = () async =>
          throw PlatformException(
            code: 'gateway/internal',
            message: 'read failed',
          );
      await controller.load();
      expect(controller.error, contains('read failed'));
      expect(controller.error, contains('configuration is read-only now'));
      runtime.overrides.remove('agentPresets.list');
      await controller.load();
      expect(controller.error, isNot(contains('read failed')));
      expect(controller.error, contains('configuration is read-only now'));
      expect(runtime.writes, hasLength(1));
      controller.select('android');
      expect(controller.error, isNull);
    },
  );

  for (final interruption in [
    'opening',
    'disconnected',
    'error',
    'end',
    'onError',
    'onDone',
  ]) {
    test(
      '$interruption invalidates a pending projection and preserves an uncertain choice',
      () async {
        final runtime = _Runtime()
          ..exists = true
          ..writeFailure = StateError('receipt lost');
        final controller = AgentPresetsController(runtime, sessionId: 's');
        addTearDown(controller.dispose);
        addTearDown(runtime.dispose);
        await controller.load();
        controller.select('custom');
        await controller.apply();
        await controller.load();
        expect(controller.uncertain, isTrue);
        final projection = Completer<dynamic>();
        final requested = Completer<void>();
        runtime.overrides['session.projections'] = () {
          requested.complete();
          return projection.future;
        };
        final observedLoading = <bool>[];
        controller.addListener(() => observedLoading.add(controller.loading));
        final obsolete = controller.refresh();
        await requested.future;
        expect(controller.loading, isTrue);
        if (interruption == 'onError') {
          runtime.stream.addError(StateError('observation unavailable'));
        } else if (interruption == 'onDone') {
          final ended = runtime.stream;
          runtime.stream = StreamController<Json>.broadcast(sync: true);
          await ended.close();
        } else {
          runtime.stream.add({'type': interruption});
        }
        expect(controller.loading, isFalse);
        expect(observedLoading.last, isFalse);
        projection.complete({
          'kind': 'sequenced',
          'asOfSeq': 8,
          'values': {'agentPreset': 'custom'},
        });
        await obsolete;
        expect(controller.fresh, isFalse);
        expect(controller.uncertain, isTrue);
        expect(controller.appliedId, 'android');
        expect(controller.draftId, 'custom');
        expect(controller.canApply, isFalse);
        runtime.overrides.remove('session.projections');
        runtime.sessionPreset = 'custom';
        await controller.refresh();
        expect(controller.fresh, isTrue);
        expect(controller.uncertain, isFalse);
        expect(controller.appliedId, 'custom');
        expect(runtime.writes, hasLength(1));
      },
    );
  }

  test(
    'explicit refresh can recover before an interrupted read completes',
    () async {
      final runtime = _Runtime()..exists = true;
      final controller = AgentPresetsController(runtime, sessionId: 's');
      addTearDown(controller.dispose);
      addTearDown(runtime.dispose);
      await controller.load();
      final projection = Completer<dynamic>();
      final requested = Completer<void>();
      runtime.overrides['session.projections'] = () {
        requested.complete();
        return projection.future;
      };
      final obsolete = controller.refresh();
      await requested.future;
      runtime.stream.addError(StateError('temporary observation failure'));
      runtime.overrides.remove('session.projections');
      final retry = controller.refresh();
      expect(retry, isNot(same(obsolete)));
      await retry;
      expect(controller.fresh, isTrue);
      projection.complete({
        'kind': 'sequenced',
        'asOfSeq': 8,
        'values': {'agentPreset': 'custom'},
      });
      await obsolete;
      expect(controller.appliedId, 'android');
      expect(controller.fresh, isTrue);
      expect(controller.loading, isFalse);
      expect(runtime.observations, 1);
      expect(runtime.writes, isEmpty);
    },
  );
}
