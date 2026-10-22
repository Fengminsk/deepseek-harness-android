import 'dart:async';

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
      case 'session.read':
        historyIds.add(params['sessionId'] as String);
        historyParams.add(params);
        return historyPage != null ? historyPage!(params) : history!();
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
          .where((call) => call == 'session.read')
          .length;
      await runtime.refresh();
      expect(
        runtime.requests.where((call) => call == 'session.read').length,
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

  test('history pages reuse one snapshot and finish without a release RPC', () async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    runtime.historyPage = (params) async {
      if (params['offset'] == 0) {
        return {
          'events': [for (var i = 0; i < 200; i++) _event(i, 'x', {})],
          'snapshot': 'read-once',
        };
      }
      return {
        'events': [_event(200, 'x', {})],
      };
    };
    await runtime.openSession('s');
    expect(runtime.historyParams, [
      {'sessionId': 's', 'offset': 0},
      {'sessionId': 's', 'offset': 200, 'snapshot': 'read-once'},
    ]);
    expect(runtime.timelines['s'], hasLength(201));
    expect(runtime.requests.contains('session.read.release'), isFalse);
  });

  test(
    'paged history includes live events without duplicating page overlap',
    () async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final lastPage = Completer<Json>();
      runtime.historyPage = (params) {
        if (params['offset'] == 0) {
          return Future.value({
            'events': [for (var i = 0; i < 200; i++) _event(i, 'x', {})],
            'snapshot': 'stable-history',
          });
        }
        return lastPage.future;
      };
      runtime.timelines['s'] = [_event(199, 'x', {}), _event(201, 'x', {})];
      final read = runtime.openSession('s');
      await Future<void>.delayed(Duration.zero);
      expect(runtime.historyParams.last['offset'], 200);
      runtime.timelines['s']!.add(_event(202, 'x', {}));
      lastPage.complete({
        'events': [_event(200, 'x', {})],
      });
      await read;
      expect(runtime.timelines['s']!.map((event) => event['seq']), [
        for (var i = 0; i <= 202; i++) i,
      ]);
    },
  );

  test('failed later history page releases its snapshot', () async {
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    runtime.historyPage = (params) async {
      if (params['offset'] == 0) {
        return {
          'events': [for (var i = 0; i < 200; i++) _event(i, 'x', {})],
          'snapshot': 'read-once',
        };
      }
      throw StateError('page unavailable');
    };
    await expectLater(runtime.openSession('s'), throwsStateError);
    expect(runtime.requests.last, 'session.read.release');
  });
}
