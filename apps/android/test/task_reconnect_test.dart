import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  final reads = <Completer<Json>>[];
  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    if (method != 'tasks.list' && method != 'runtime.live') {
      throw StateError('Unexpected $method');
    }
    final result = Completer<Json>();
    reads.add(result);
    return result.future;
  }
}

Json tasks(String epoch) => {
  'epoch': epoch,
  'revision': 1,
  'summary': {},
  'active': [],
  'sessions': [
    {'sessionId': epoch},
  ],
  'nextOffset': null,
};

void main() {
  testWidgets(
    'restarting admits a new task baseline while a stale read is in flight',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (_) async => null,
      );
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(RuntimeController.channel, null),
      );
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final old = runtime.refreshTasks();
      await runtime.restart();
      final fresh = runtime.refreshTasks();
      expect(runtime.reads, hasLength(2));
      runtime.reads[1].complete(tasks('new-process'));
      await fresh;
      runtime.reads[0].complete(tasks('old-process'));
      await old;
      expect(runtime.taskState['epoch'], 'new-process');
      expect(runtime.taskSessions.single['sessionId'], 'new-process');
    },
  );

  testWidgets(
    'typed live baseline merges only newer complete block projections and clears on process restart',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final listening = Completer<MockStreamHandlerEventSink>();
      messenger.setMockStreamHandler(
        RuntimeController.events,
        MockStreamHandler.inline(
          onListen: (_, sink) => listening.complete(sink),
        ),
      );
      messenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (_) async => null,
      );
      final runtime = _Runtime();
      addTearDown(() {
        messenger.setMockMethodCallHandler(RuntimeController.channel, null);
        messenger.setMockStreamHandler(RuntimeController.events, null);
      });
      await runtime.start();
      final sink = await listening.future;
      final baseline = runtime.refreshLive();
      Json message(String text) => {
        'attemptId': 'one',
        'turn': 1,
        'step': 2,
        'content': [
          {'type': 'reasoning', 'text': text},
        ],
        'interrupted': false,
      };
      void emit(int revision, String text) => sink.success(
        jsonEncode({
          'method': 'session.live',
          'params': {
            'sessionId': 's',
            'revision': revision,
            'value': message(text),
          },
        }),
      );
      void status(String phase, {String? generation}) => sink.success(
        jsonEncode({
          'method': 'runtime.status',
          'params': {
            'phase': phase,
            'generation': ?generation,
          },
        }),
      );
      emit(9, 'old');
      emit(11, 'latest');
      await tester.pump();
      runtime.reads.single.complete({
        'revision': 10,
        'statuses': <String, dynamic>{},
        'streaming': <String, dynamic>{},
        'liveMessages': {'s': message('baseline')},
      });
      await tester.pump();
      await baseline;
      expect(runtime.liveMessages['s']!['content'], [
        {'type': 'reasoning', 'text': 'latest'},
      ]);
      status('failed');
      await tester.pump();
      expect(runtime.liveMessages['s']!['unconfirmed'], isTrue);
      await runtime.restart();
      expect(runtime.liveMessages['s']!['unconfirmed'], isTrue);
      expect(runtime.liveMessages['s']!['interrupted'], isFalse);
      status('starting');
      await tester.pump();
      expect(runtime.liveMessages, isEmpty);
      status('ready', generation: 'first-process');
      await tester.pump();
      runtime.liveMessages['s'] = message('current process');
      runtime.statuses['s'] = 'running';
      runtime.streaming['s'] = 'current delta';
      status('ready', generation: 'first-process');
      await tester.pump();
      expect(runtime.liveMessages['s']!['content'], [
        {'type': 'reasoning', 'text': 'current process'},
      ]);
      status('ready', generation: 'replacement-process');
      await tester.pump();
      expect(runtime.liveMessages, isEmpty);
      expect(runtime.statuses, isEmpty);
      expect(runtime.streaming, isEmpty);
      runtime.dispose();
      await tester.pump();
    },
  );
}
