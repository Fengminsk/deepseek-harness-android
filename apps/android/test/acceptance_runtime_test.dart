import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _AdmissionRuntime extends RuntimeController {
  final entered = Completer<void>();
  final release = Completer<void>();
  final submissions = <Json>[];

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'session.send') {
      submissions.add(Map<String, dynamic>.of(params));
      if (submissions.length == 1) {
        entered.complete();
        await release.future;
      }
      return {'accepted': true};
    }
    if (method == 'sessions.list') return <Json>[];
    throw StateError('Unexpected method $method');
  }
}

class _ReconnectRuntime extends RuntimeController {
  final entered = Completer<void>();
  final baseline = Completer<Json>();

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'runtime.live') {
      throw StateError('Unexpected method $method');
    }
    entered.complete();
    return baseline.future;
  }
}

void main() {
  test('updated defaults accompany the next submission without overriding an existing Session model', () async {
    final runtime = _AdmissionRuntime();
    addTearDown(runtime.dispose);
    runtime.model = 'first-model';
    final first = runtime.send('conversation', 'first message');
    await runtime.entered.future;
    runtime.model = 'newly-selected-model';
    runtime.release.complete();
    await first;
    await runtime.send('conversation', 'second message');
    expect(runtime.submissions.last['model'], 'newly-selected-model');
    expect(runtime.submissions.last['selectModel'], isFalse);
  });

  testWidgets(
    'reconnect restores a running task and only replays notifications newer than its baseline',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final listening = Completer<MockStreamHandlerEventSink>();
      final cancelled = Completer<void>();
      messenger.setMockStreamHandler(
        RuntimeController.events,
        MockStreamHandler.inline(
          onListen: (_, events) => listening.complete(events),
          onCancel: (_) => cancelled.complete(),
        ),
      );
      messenger.setMockMethodCallHandler(RuntimeController.channel, (
        call,
      ) async {
        if (call.method == 'start') return null;
        throw StateError('Unexpected native method ${call.method}');
      });
      addTearDown(() {
        messenger.setMockStreamHandler(RuntimeController.events, null);
        messenger.setMockMethodCallHandler(RuntimeController.channel, null);
      });
      final runtime = _ReconnectRuntime();
      await runtime.start();
      final events = await listening.future;
      var disposed = false;
      addTearDown(() {
        if (!disposed) runtime.dispose();
      });
      void emit(String method, Json params) =>
          events.success(jsonEncode({'method': method, 'params': params}));
      runtime.statuses['stale-task'] = 'running';
      runtime.streaming['stale-task'] = 'stale text';
      final refresh = runtime.refreshLive();
      await runtime.entered.future;
      emit('session.stream', {
        'sessionId': 'live-task',
        'revision': 9,
        'frame': {
          'type': 'chunk',
          'chunk': {'type': 'text-delta', 'text': 'already in snapshot'},
        },
      });
      emit('session.stream', {
        'sessionId': 'live-task',
        'revision': 11,
        'frame': {
          'type': 'chunk',
          'chunk': {'type': 'text-delta', 'text': ' plus new text'},
        },
      });
      await tester.pump();
      runtime.baseline.complete({
        'revision': 10,
        'statuses': {'live-task': 'running'},
        'streaming': {'live-task': 'restored text'},
      });
      await tester.pump();
      await refresh;
      expect(runtime.statuses, {'live-task': 'running'});
      expect(runtime.streaming, {'live-task': 'restored text plus new text'});
      emit('session.status', {
        'sessionId': 'live-task',
        'revision': 12,
        'status': 'idle',
      });
      await tester.pump();
      expect(runtime.statuses['live-task'], 'idle');
      expect(runtime.streaming, isEmpty);
      runtime.dispose();
      disposed = true;
      await tester.pump();
      await cancelled.future;
    },
  );
}
