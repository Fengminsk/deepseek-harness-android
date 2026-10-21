import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/configuration_state.dart';
import 'package:dsh_android/runtime.dart';

Json descriptor() => {
  'ns': 'test-settings',
  'revision': 1,
  'value': {'endpoint': 'old', 'limit': 10},
  'base': {'endpoint': 'default', 'limit': 10},
  'user': {'endpoint': 'old'},
  'secrets': [
    {
      'path': ['apiKey'],
      'set': true,
    },
  ],
  'schema': {
    'type': 'object',
    'dict': {
      'endpoint': {'type': 'string'},
      'limit': {'type': 'number'},
      'apiKey': {
        'type': 'string',
        'meta': {'role': 'secret'},
      },
    },
  },
};

class ConfigurationRuntime extends RuntimeController {
  ConfigurationRuntime() {
    phase = 'ready';
  }
  Json remote = cloneConfiguration(descriptor());
  bool writable = true, available = true;
  int generation = 0, reads = 0;
  final writes = <Json>[];
  Future<dynamic> Function()? onRead;
  Future<dynamic> Function(Json)? onWrite;

  @override
  int get connectionGeneration => generation;

  Json describe() => {
    'writable': writable,
    'namespaces': [if (available) cloneConfiguration(remote)],
  };

  void reconnect({bool ready = true}) {
    generation++;
    phase = ready ? 'ready' : 'restarting';
    notifyListeners();
  }

  void hint() {
    // Only a refresh trigger, not an authoritative source of edited state.
    forms = [descriptor()..['revision'] = 999];
    notifyListeners();
  }

  Json commit(Json args) {
    if (args['expectedRevision'] != remote['revision']) {
      throw PlatformException(code: 'settings/conflict');
    }
    for (final raw in args['ops'] as List) {
      final op = raw as Json;
      applyConfigurationEdit(remote['user'] as Json, op);
      if (op['op'] == 'unset') {
        final path = (op['path'] as List).cast<String>();
        final inherited = configurationValueAt(remote['base'], path);
        applyConfigurationEdit(
          remote['value'] as Json,
          configurationHasValue(inherited)
              ? {'op': 'set', 'path': path, 'value': inherited}
              : op,
        );
      } else {
        applyConfigurationEdit(remote['value'] as Json, op);
      }
    }
    remote['revision'] = (remote['revision'] as int) + 1;
    return cloneConfiguration(remote);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'api.call');
    expect(params['namespace'], 'settings');
    switch (params['method']) {
      case 'describe':
        reads++;
        return onRead == null ? describe() : await onRead!();
      case 'mutate':
        final args = cloneConfiguration(params['args'] as Json);
        writes.add(args);
        return onWrite == null ? commit(args) : await onWrite!(args);
      default:
        throw StateError('Unexpected method ${params['method']}');
    }
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late ConfigurationRuntime runtime;
  late ConfigurationEditingController state;
  setUp(() {
    runtime = ConfigurationRuntime();
    state = ConfigurationEditingController(
      runtime,
      namespace: 'test-settings',
      descriptor: descriptor(),
    );
  });
  tearDown(() {
    state.dispose();
    runtime.dispose();
  });

  test(
    'display context is stale until original settings describes it',
    () async {
      expect(state.accepted!['revision'], 1);
      expect(state.fresh, isFalse);
      state.edit(['endpoint'], 'mine');
      expect(state.canSave, isFalse);
      await state.start();
      expect(state.canSave, isTrue);
      expect(await state.save(), isTrue);
      expect(runtime.writes.single, {
        'ns': 'test-settings',
        'expectedRevision': 1,
        'ops': [
          {
            'op': 'set',
            'path': ['endpoint'],
            'value': 'mine',
          },
        ],
      });
      expect(state.hasDraft, isFalse);
      expect(state.accepted!['revision'], 2);
    },
  );

  test('single flight and connection fence ignore delayed old reads', () async {
    final old = Completer<dynamic>();
    runtime.onRead = () => old.future;
    final first = state.start();
    final second = state.refresh();
    expect(identical(first, second), isTrue);
    expect(runtime.reads, 1);
    runtime.onRead = null;
    runtime.remote['revision'] = 2;
    runtime.remote['value']['endpoint'] = 'new-host';
    runtime.reconnect();
    await tick();
    expect(state.accepted!['revision'], 2);
    old.complete({
      'writable': true,
      'namespaces': [descriptor()],
    });
    await first;
    expect(state.accepted!['value']['endpoint'], 'new-host');
    expect(state.fresh, isTrue);
  });

  test(
    'same connection hints invalidate reads and never copy runtime forms',
    () async {
      final old = Completer<dynamic>();
      runtime.onRead = () => old.future;
      final first = state.start();
      runtime.hint();
      runtime.onRead = null;
      runtime.remote['revision'] = 2;
      old.complete({
        'writable': true,
        'namespaces': [descriptor()],
      });
      await first;
      await tick();
      expect(runtime.reads, 2);
      expect(state.accepted!['revision'], 2);
      expect(state.fresh, isTrue);
    },
  );

  test('preflight exposes conflict before a write and explicit rebase keeps remote fields', () async {
    await state.start();
    state.edit(['endpoint'], 'mine');
    runtime.remote['revision'] = 2;
    runtime.remote['value'] = {'endpoint': 'other', 'limit': 20};
    expect(await state.save(), isFalse);
    expect(runtime.writes, isEmpty);
    expect(state.draft!['endpoint'], 'mine');
    expect(state.conflict, isTrue);
    expect(state.rebase(), isFalse);
    expect(state.rebase(useLocal: {'["endpoint"]': true}), isTrue);
    expect(state.draft, {'endpoint': 'mine', 'limit': 20});
    expect(await state.save(), isTrue);
    expect(runtime.writes.single['expectedRevision'], 2);
  });

  test(
    'known conflict is a refusal but retains draft and never retries',
    () async {
      await state.start();
      state.edit(['endpoint'], 'mine');
      runtime.onWrite = (_) async {
        runtime.remote['revision'] = 2;
        runtime.remote['value']['limit'] = 20;
        throw PlatformException(code: 'settings/conflict');
      };
      expect(await state.save(), isFalse);
      expect(state.uncertain, isFalse);
      expect(state.conflict, isTrue);
      expect(state.error, contains('配置版本已变化'));
      await state.refresh();
      expect(state.error, contains('配置版本已变化'));
      expect(await state.save(), isFalse);
      expect(runtime.writes, hasLength(1));
      expect(state.draft!['endpoint'], 'mine');
    },
  );

  for (final code in ['transport/unavailable', 'settings/rejected']) {
    test(
      '$code without matching observation stays uncertain until explicit adoption',
      () async {
        await state.start();
        state.edit(['endpoint'], 'mine');
        runtime.onWrite = (_) async => throw PlatformException(code: code);
        expect(await state.save(), isFalse);
        expect(state.uncertain, isTrue);
        expect(state.fresh, isTrue);
        expect(state.canEdit, isFalse);
        expect(state.draft!['endpoint'], 'mine');
        expect(state.latest!['value']['endpoint'], 'old');
        expect(await state.save(), isFalse);
        await state.refresh();
        expect(runtime.writes, hasLength(1));
        expect(state.uncertain, isTrue);
        state.discardDraft();
        expect(state.uncertain, isFalse);
        expect(state.draft!['endpoint'], 'old');
      },
    );
  }

  test(
    'post-commit settings/rejected reconciles actual state without replay',
    () async {
      await state.start();
      state.edit(['endpoint'], 'mine');
      runtime.onWrite = (args) async {
        runtime.commit(args);
        throw PlatformException(code: 'settings/rejected');
      };
      expect(await state.save(), isFalse);
      expect(state.uncertain, isFalse);
      expect(state.hasDraft, isFalse);
      expect(state.notice, '已核对当前配置与目标一致。');
      expect(state.accepted!['value']['endpoint'], 'mine');
      await state.refresh();
      expect(runtime.writes, hasLength(1));
    },
  );

  test('late receipt from an old host cannot confirm a new host', () async {
    await state.start();
    state.edit(['endpoint'], 'mine');
    final entered = Completer<void>(), receipt = Completer<dynamic>();
    runtime.onWrite = (_) {
      entered.complete();
      return receipt.future;
    };
    final saving = state.save();
    await entered.future;
    runtime.reconnect(ready: false);
    final oldReceipt = descriptor();
    oldReceipt['revision'] = 2;
    oldReceipt['value'] = {'endpoint': 'mine', 'limit': 10};
    receipt.complete(oldReceipt);
    expect(await saving, isFalse);
    expect(state.uncertain, isTrue);
    expect(state.fresh, isFalse);
    expect(state.accepted!['revision'], 1);
    runtime.reconnect();
    await tick();
    expect(state.uncertain, isTrue);
    expect(state.latest!['value']['endpoint'], 'old');
    expect(runtime.writes, hasLength(1));
  });

  test(
    'a connection change during save preflight never submits the old intention',
    () async {
      await state.start();
      state.edit(['endpoint'], 'mine');
      final delayed = Completer<dynamic>();
      runtime.onRead = () => delayed.future;
      final saving = state.save();
      runtime.onRead = null;
      runtime.reconnect();
      await tick();
      delayed.complete(runtime.describe());
      expect(await saving, isFalse);
      expect(state.draft!['endpoint'], 'mine');
      expect(runtime.writes, isEmpty);
      expect(state.canSave, isTrue);
    },
  );

  test('an in-flight mutation cannot be sent twice', () async {
    await state.start();
    state.edit(['endpoint'], 'mine');
    final entered = Completer<void>(), receipt = Completer<dynamic>();
    runtime.onWrite = (_) {
      entered.complete();
      return receipt.future;
    };
    final saving = state.save();
    await entered.future;
    expect(await state.save(), isFalse);
    receipt.complete(runtime.commit(runtime.writes.single));
    expect(await saving, isTrue);
    expect(runtime.writes, hasLength(1));
  });

  test('unset is confirmed against inherited effective values', () async {
    await state.start();
    final reset = configurationReset(state.accepted!);
    runtime.onWrite = (args) async {
      runtime.commit(args);
      throw PlatformException(code: 'settings/rejected');
    };
    expect(await state.save(operations: reset.operations), isFalse);
    expect(state.uncertain, isFalse);
    expect(state.draft!['endpoint'], 'default');
    expect(state.accepted!['user'], isEmpty);
    expect(runtime.writes.single['ops'], [
      {
        'op': 'unset',
        'path': ['endpoint'],
      },
    ]);
  });

  test(
    'partial unset may retain an inherited value in the full user config',
    () async {
      runtime.remote['user']['limit'] = 20;
      runtime.remote['value']['limit'] = 20;
      await state.start();
      runtime.onWrite = (args) async {
        runtime.commit(args);
        // ConfigEditor writes the full next config while another override remains.
        runtime.remote['user']['endpoint'] = 'default';
        throw PlatformException(code: 'settings/rejected');
      };
      expect(
        await state.save(
          operations: [
            {
              'op': 'unset',
              'path': ['endpoint'],
            },
          ],
        ),
        isFalse,
      );
      expect(state.uncertain, isFalse);
      expect(state.draft, {'endpoint': 'default', 'limit': 20});
      expect(state.accepted!['user'], {'endpoint': 'default', 'limit': 20});
      expect(runtime.writes, hasLength(1));
    },
  );

  test(
    'read-only and missing namespace never use cached write permission',
    () async {
      await state.start();
      state.edit(['endpoint'], 'mine');
      runtime.writable = false;
      expect(await state.save(), isFalse);
      expect(state.writable, isFalse);
      runtime.writable = true;
      runtime.available = false;
      expect(await state.save(), isFalse);
      expect(state.fresh, isFalse);
      expect(state.error, contains('此配置已不可用'));
      expect(runtime.writes, isEmpty);
      expect(state.draft!['endpoint'], 'mine');
    },
  );

  test(
    'external invalid input survives valid edits back to baseline and refresh',
    () async {
      await state.start();
      state.holdDraft(true);
      state.edit(['endpoint'], 'temporary');
      state.edit(['endpoint'], 'old');
      expect(state.hasDraft, isTrue);
      runtime.remote['revision'] = 2;
      runtime.remote['value']['limit'] = 20;
      await state.refresh();
      expect(state.accepted!['revision'], 1);
      expect(state.draft!['limit'], 10);
      expect(state.latest!['value']['limit'], 20);
      state.replaceDraft({
        'endpoint': 'old',
        'limit': 15,
      }, holdExternalDraft: false);
      expect(state.rebase(useLocal: {'["limit"]': true}), isTrue);
      expect(state.draft!['limit'], 15);
    },
  );

  test(
    'credential writes stay protected before and after a schema change',
    () async {
      await state.start();
      expect(
        () => state.edit(['apiKey'], 'secret'),
        throwsA(isA<ConfigurationEditException>()),
      );
      state.edit(['endpoint'], 'mine');
      runtime.remote['revision'] = 2;
      runtime.remote['secrets'] = [
        {
          'path': ['endpoint'],
          'set': true,
        },
      ];
      await state.refresh();
      expect(() => state.rebase(), throwsA(isA<ConfigurationEditException>()));
      expect(runtime.writes, isEmpty);
    },
  );

  test('malformed success receipt is unknown and cannot be reissued', () async {
    await state.start();
    state.edit(['endpoint'], 'mine');
    runtime.onWrite = (_) async => {'ok': true};
    expect(await state.save(), isFalse);
    expect(state.uncertain, isTrue);
    expect(await state.save(), isFalse);
    expect(runtime.writes, hasLength(1));
  });

  test(
    'dispose suppresses a late read and removes runtime observation',
    () async {
      final local = ConfigurationEditingController(
        runtime,
        namespace: 'test-settings',
      );
      final delayed = Completer<dynamic>();
      runtime.onRead = () => delayed.future;
      var notifications = 0;
      local.addListener(() {
        notifications++;
      });
      final loading = local.start();
      local.dispose();
      final before = notifications;
      runtime.hint();
      delayed.complete(runtime.describe());
      await loading;
      expect(notifications, before);
      expect(local.accepted, isNull);
    },
  );
}
