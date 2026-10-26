import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  final requests = <String>[];
  final historyIds = <String>[];
  final historyParams = <Json>[];
  Future<Json> Function()? history;
  Future<Json> Function(Json params)? historyPage;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    requests.add(method);
    switch (method) {
      case 'runtime.info':
        return <String, dynamic>{};
      case 'runtime.live':
        return {
          'revision': 0,
          'statuses': <String, dynamic>{},
          'streaming': <String, dynamic>{},
          'liveMessages': <String, dynamic>{},
          'errors': <String, dynamic>{},
        };
      case 'session.readWindow':
        historyIds.add(params['sessionId'] as String);
        historyParams.add(params);
        final response = historyPage != null
            ? await historyPage!(params)
            : await history!();
        if (response.containsKey('firstSeq')) return response;
        final records = (response['events'] as List).cast<Json>();
        return {
          ...response,
          'firstSeq': records.isEmpty ? null : records.first['seq'],
          'throughSeq': records.isEmpty ? -1 : records.last['seq'],
          'hasMore': false,
        };
      case 'session.read.release':
        return {'released': true};
      default:
        throw StateError('Unexpected $method');
    }
  }

  @override
  Future<void> refreshInteractions() async {}
  @override
  Future<void> refreshWeb() async {}
  @override
  Future<void> refreshSessions() async {}
  @override
  Future<void> refreshForms() async {}
  @override
  Future<void> refreshTasks() async {}
}

Json _event(int seq, String type, Json data) => {
  'seq': seq,
  'type': type,
  'time': seq,
  'surfaceOp': 'append',
  'data': data,
};

List<Json> _openTurn() => [
  _event(0, 'turn/start', {'turn': 1}),
  _event(1, 'step/start', {'turn': 1, 'step': 1}),
  _event(2, 'tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'fetch-one',
    'name': 'web_fetch',
    'arguments': '{"url":"https://example.invalid"}',
  }),
];

List<Json> _recovered() => [
  ..._openTurn(),
  _event(3, 'tool/result', {
    'turn': 1,
    'step': 1,
    'message': {
      'role': 'tool',
      'source': {'kind': 'tool', 'callId': 'fetch-one'},
      'toolCallId': 'fetch-one',
      'isError': true,
      'content': [
        {'type': 'text', 'text': 'Tool outcome is unknown after interruption'},
      ],
    },
    'error': {'code': 'TOOL_OUTCOME_UNKNOWN'},
  }),
  _event(4, 'turn/end', {
    'turn': 1,
    'reason': {'kind': 'interrupted'},
  }),
];

Future<MockStreamHandlerEventSink> _attachEvents(_Runtime runtime) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final listening = Completer<MockStreamHandlerEventSink>();
  messenger.setMockStreamHandler(
    RuntimeController.events,
    MockStreamHandler.inline(onListen: (_, sink) => listening.complete(sink)),
  );
  addTearDown(
    () => messenger.setMockStreamHandler(RuntimeController.events, null),
  );
  await runtime.start();
  return listening.future;
}

void _deliverEvent(MockStreamHandlerEventSink sink, String id, Json event) {
  sink.success(
    jsonEncode({
      'method': 'session.event',
      'params': {'sessionId': id, 'event': event},
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, null);
  });

  test(
    'replacement runtime refreshes chat interruption without sending work',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      runtime.history = () async => {'events': _openTurn()};
      await runtime.openSession('s');
      await runtime.restart();
      runtime.phase = 'ready';
      runtime.history = () async => {'events': _recovered()};
      await runtime.refresh();
      final events = runtime.timelines['s']!;
      final chat = ChatProjection()..reconcile(events);
      final tools = ToolActivityProjection()..reconcile(events);
      expect(
        chat.entries.any((row) => row.text?.contains('本轮任务未完成') == true),
        isTrue,
      );
      expect(
        tools.byAnchorSeq.values.single.phase,
        ToolActivityPhase.interrupted,
      );
      expect(
        tools.byAnchorSeq.values.single.error?['code'],
        'TOOL_OUTCOME_UNKNOWN',
      );
      expect(runtime.statuses, isEmpty);
      expect(
        runtime.requests.where(
          (call) => call == 'session.send' || call == 'session.ensure',
        ),
        isEmpty,
      );
      final reads = runtime.requests
          .where((call) => call == 'session.readWindow')
          .length;
      await runtime.refresh();
      expect(
        runtime.requests.where((call) => call == 'session.readWindow').length,
        reads,
      );
    },
  );

  for (final failed in [false, true]) {
    test(
      'old process history ${failed ? 'failure' : 'reply'} cannot replace recovered chat',
      () async {
        final runtime = _Runtime();
        addTearDown(runtime.dispose);
        final stale = Completer<Json>();
        runtime.timelines['s'] = _openTurn();
        runtime.history = () => stale.future;
        final old = runtime.openSession('s');
        await runtime.restart();
        runtime.phase = 'ready';
        runtime.history = () async => {'events': _recovered()};
        await runtime.refresh();
        if (failed) {
          stale.completeError(StateError('dead process'));
        } else {
          stale.complete({'events': _openTurn()});
        }
        await old;
        expect(runtime.timelines['s']!.last['type'], 'turn/end');
        expect(runtime.error, isNull);
      },
    );
  }

  test(
    'new chats recover without reading child events or unsubmitted drafts',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final id = runtime.newSession();
      runtime.newSession(); // No durable Session exists for this draft.
      runtime.timelines[id] = _openTurn();
      runtime.timelines['child'] = _openTurn();
      await runtime.restart();
      runtime.history = () async => {'events': _recovered()};
      await runtime.refresh();
      expect(runtime.historyIds, [id]);
      expect(runtime.timelines[id]!.last['type'], 'turn/end');
      expect(runtime.timelines['child']!.last['type'], 'tool/call');
    },
  );

  test(
    'current generation read failure is visible and can be retried',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final id = runtime.newSession();
      runtime.timelines[id] = _openTurn();
      await runtime.restart();
      runtime.history = () async => throw StateError('history unavailable');
      await expectLater(runtime.refresh(), throwsStateError);
      expect(runtime.timelines[id]!.last['type'], 'tool/call');
      runtime.history = () async => {'events': _recovered()};
      await runtime.refresh();
      expect(runtime.timelines[id]!.last['type'], 'turn/end');
    },
  );

  test(
    'opening reads one bounded tail and loads older rows at a fixed cut',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      runtime.historyPage = (params) async {
        if (!params.containsKey('beforeSeq')) {
          return {
            'events': [for (var i = 200; i <= 400; i++) _event(i, 'x', {})],
            'firstSeq': 200,
            'throughSeq': 400,
            'hasMore': true,
          };
        }
        return {
          'events': [for (var i = 0; i < 200; i++) _event(i, 'x', {})],
          'firstSeq': 0,
          'throughSeq': 400,
          'hasMore': false,
        };
      };
      await runtime.openSession('s');
      expect(runtime.timelines['s'], hasLength(201));
      final before = runtime.timelines['s'];
      expect(await runtime.loadOlderSession('s'), 200);
      expect(runtime.historyParams, [
        {'sessionId': 's'},
        {'sessionId': 's', 'throughSeq': 400, 'beforeSeq': 200},
      ]);
      expect(identical(runtime.timelines['s'], before), isTrue);
      expect(runtime.timelines['s'], hasLength(401));
      expect(runtime.historyWindows['s']!.hasMore, isFalse);
    },
  );

  test(
    'tail window includes live events without bringing old display rows back',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final sink = await _attachEvents(runtime);
      final tail = Completer<Json>();
      runtime.historyPage = (params) => tail.future;
      _deliverEvent(sink, 's', _event(199, 'x', {}));
      _deliverEvent(sink, 's', _event(201, 'x', {}));
      await Future<void>.delayed(Duration.zero);
      final read = runtime.openSession('s');
      await Future<void>.delayed(Duration.zero);
      expect(runtime.historyParams.last, {'sessionId': 's'});
      _deliverEvent(sink, 's', _event(202, 'x', {}));
      await Future<void>.delayed(Duration.zero);
      tail.complete({
        'events': [for (var i = 198; i <= 200; i++) _event(i, 'x', {})],
        'firstSeq': 198,
        'throughSeq': 200,
        'hasMore': true,
      });
      await read;
      expect(runtime.timelines['s']!.map((event) => event['seq']), [
        198,
        199,
        200,
        201,
        202,
      ]);
    },
  );

  test(
    'cold read drops old process rows but retains a fresh live event',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final sink = await _attachEvents(runtime);

      runtime.history = () async => {
        'events': [
          _event(0, 'turn/start', {'turn': 1}),
        ],
      };
      await runtime.openSession('s');
      // The old carrier displayed this row, but its durable history never
      // confirmed it before the process was replaced.
      runtime.timelines['s']!.add(_event(90, 'tool/call', {'callId': 'ghost'}));
      await runtime.restart();
      runtime.phase = 'ready';

      final cold = Completer<Json>();
      runtime.history = () => cold.future;
      final reading = runtime.openSession('s');
      _deliverEvent(
        sink,
        's',
        _event(2, 'assistant/message', {'text': 'new process'}),
      );
      await Future<void>.delayed(Duration.zero);
      cold.complete({
        'events': [
          _event(0, 'turn/start', {'turn': 1}),
          _event(1, 'turn/end', {'turn': 1}),
        ],
      });
      await reading;
      expect(runtime.timelines['s']!.map((event) => event['seq']), [0, 1, 2]);
      expect(runtime.timelines['s']!.last['data']['text'], 'new process');
    },
  );

  test('an unconfirmed disconnect keeps same-process display rows', () async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    runtime.history = () async => {
      'events': [
        _event(0, 'turn/start', {'turn': 1}),
      ],
    };
    await runtime.openSession('s');
    runtime.timelines['s']!.add(
      _event(1, 'assistant/message', {'text': 'live'}),
    );
    runtime.fail(StateError('temporary Binder disconnect'));
    runtime.phase = 'ready';
    await runtime.openSession('s');
    expect(runtime.timelines['s']!.map((event) => event['seq']), [0, 1]);
  });

  test('failed older page preserves the already visible window', () async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    runtime.historyPage = (params) async {
      if (!params.containsKey('beforeSeq')) {
        return {
          'events': [_event(200, 'x', {})],
          'firstSeq': 200,
          'throughSeq': 200,
          'hasMore': true,
        };
      }
      throw StateError('page unavailable');
    };
    await runtime.openSession('s');
    await expectLater(runtime.loadOlderSession('s'), throwsStateError);
    expect(runtime.timelines['s']!.map((event) => event['seq']), [200]);
    expect(runtime.historyWindows['s']!.hasMore, isTrue);
  });

  test(
    'older page from a replaced connection cannot prepend stale records',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final older = Completer<Json>();
      runtime.historyPage = (params) async {
        if (params.containsKey('beforeSeq')) return older.future;
        return {
          'events': [
            _event(200, 'turn/start', {'turn': 3}),
          ],
          'firstSeq': 200,
          'throughSeq': 200,
          'hasMore': true,
        };
      };
      await runtime.openSession('s');
      final pending = runtime.loadOlderSession('s');
      await Future<void>.delayed(Duration.zero);
      await runtime.restart();
      runtime.phase = 'ready';
      await runtime.openSession('s');
      older.complete({
        'events': [
          _event(0, 'turn/start', {'turn': 1}),
        ],
        'firstSeq': 0,
        'throughSeq': 200,
        'hasMore': false,
      });
      expect(await pending, 0);
      expect(runtime.timelines['s']!.map((event) => event['seq']), [200]);
    },
  );
}
