import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecoveryRuntime extends RuntimeController {
  final calls = <String>[];
  final failures = <String>{};
  Completer<Json>? webPending;
  final webEntered = Completer<void>();

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add(method);
    if (failures.contains(method)) throw StateError('$method unavailable');
    if (method == 'web.status' && webPending != null) {
      if (!webEntered.isCompleted) webEntered.complete();
      return webPending!.future;
    }
    return switch (method) {
      'runtime.info' => <String, dynamic>{'platform': 'android'},
      'runtime.live' => <String, dynamic>{
        'revision': 1,
        'statuses': <String, String>{},
        'streaming': <String, String>{},
      },
      'interactions.list' => <String, dynamic>{
        'revision': 1,
        'requests': <Json>[],
      },
      'web.status' => <String, dynamic>{
        'phase': 'listening',
        'url': 'http://127.0.0.1:3080/',
      },
      'sessions.list' => <Json>[
        {'id': 'existing-chat'},
      ],
      'settings.describe' => <Json>[
        {
          'ns': 'agent-default-model',
          'value': {'provider': 'fixture', 'model': 'restored-model'},
        },
      ],
      'tasks.list' => <String, dynamic>{
        'epoch': 'service-a',
        'revision': 1,
        'summary': <String, dynamic>{},
        'active': <Json>[],
        'sessions': <Json>[],
        'nextOffset': null,
      },
      _ => throw StateError('Unexpected recovery RPC $method'),
    };
  }
}

void main() {
  for (final failedRead in [
    'runtime.live',
    'interactions.list',
    'web.status',
    'sessions.list',
    'settings.describe',
  ]) {
    test(
      '$failedRead failure does not suppress independent recovery reads',
      () async {
        final runtime = _RecoveryRuntime()..phase = 'ready';
        addTearDown(runtime.dispose);
        runtime.failures.add(failedRead);

        await expectLater(runtime.refresh(), throwsA(isA<StateError>()));

        expect(runtime.info['platform'], 'android');
        expect(
          runtime.calls,
          containsAllInOrder([
            'runtime.live',
            'interactions.list',
            'web.status',
            'sessions.list',
            'settings.describe',
            'tasks.list',
          ]),
        );
        expect(
          runtime.model,
          failedRead == 'settings.describe'
              ? 'deepseek-flash'
              : 'restored-model',
        );
        expect(runtime.sessions.isNotEmpty, failedRead != 'sessions.list');
        expect(runtime.taskState['epoch'], 'service-a');
        if (failedRead == 'web.status') {
          expect(runtime.web['url'], isNull);
        } else {
          expect(runtime.web['phase'], 'listening');
        }

        runtime.failures.clear();
        await runtime.refresh();
        expect(runtime.web['phase'], 'listening');
        expect(runtime.sessions.single['id'], 'existing-chat');
        expect(runtime.model, 'restored-model');
      },
    );
  }

  test('old recovery stops before reading a replacement connection', () async {
    final runtime = _RecoveryRuntime()..phase = 'ready';
    addTearDown(runtime.dispose);
    runtime.webPending = Completer<Json>();
    final oldRead = runtime.refresh();
    await runtime.webEntered.future;

    runtime.fail(StateError('service replaced'));
    runtime.webPending!.complete({'phase': 'listening', 'url': 'old-link'});
    await oldRead;

    expect(runtime.calls, isNot(contains('settings.describe')));
    expect(runtime.calls, isNot(contains('tasks.list')));
    expect(runtime.web['url'], isNull);
  });
}
