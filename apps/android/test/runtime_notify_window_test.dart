import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _QuietRuntime extends RuntimeController {
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async => {};
}

/// Live text frames must not rebuild the chat page once per token: the runtime
/// folds them into one notification per window, and any other frame flushes at
/// once so status and errors stay immediate.
void main() {
  testWidgets('live text notifies once per window and other frames flush', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final listening = Completer<MockStreamHandlerEventSink>();
    messenger.setMockStreamHandler(
      RuntimeController.events,
      MockStreamHandler.inline(
        onListen: (_, events) => listening.complete(events),
        onCancel: (_) {},
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

    final runtime = _QuietRuntime();
    addTearDown(runtime.dispose);
    await runtime.start();
    final events = await listening.future;
    await tester.pump();

    var notifications = 0;
    runtime.addListener(() => notifications++);

    void emit(String method, Json params) =>
        events.success(jsonEncode({'method': method, 'params': params}));

    for (var index = 0; index < 3; index++) {
      emit('session.live', {
        'sessionId': 'live-task',
        'value': {'content': 'token $index'},
      });
    }
    await tester.pump();
    expect(runtime.liveMessages['live-task'], isNotNull);
    expect(notifications, 0, reason: 'live frames wait for the window');

    await tester.pump(RuntimeController.liveNotifyWindow);
    expect(notifications, 1, reason: 'three frames, one rebuild');

    // A status frame during a pending window flushes at once.
    emit('session.live', {
      'sessionId': 'live-task',
      'value': {'content': 'token 4'},
    });
    await tester.pump();
    emit('session.status', {
      'sessionId': 'live-task',
      'status': 'running',
    });
    await tester.pump();
    expect(notifications, 2);
    await tester.pump(RuntimeController.liveNotifyWindow);
    expect(notifications, 2, reason: 'the flushed window leaves no timer');
  });
}
