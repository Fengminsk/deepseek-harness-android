import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_trajectory.dart';
import 'package:dsh_android/session_trajectory_data.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json _event(int seq, int time, String type, Json data, {String? surface}) => {
  'seq': seq,
  'time': time,
  'type': type,
  'data': data,
  'surfaceOp': ?surface,
};

List<Json> _history() => [
  _event(0, 1000, 'turn/start', {'turn': 1}),
  _event(1, 1010, 'step/start', {'turn': 1, 'step': 1}),
  _event(2, 1020, 'user/message', {
    'source': {'kind': 'user'},
    'content': [
      {'type': 'text', 'text': 'Summarize this'},
    ],
  }, surface: 'append'),
  _event(3, 1030, 'request/header', {
    'header': {
      'config': {'model': 'deepseek-flash'},
    },
    'reason': 'initial',
  }),
  _event(4, 1100, 'assistant/message', {
    'turn': 1,
    'step': 1,
    'message': {
      'content': [
        {'type': 'text', 'text': 'I will read it.'},
      ],
    },
    'usage': {
      'inputTokens': 10,
      'outputTokens': 5,
      'cacheReadTokens': 4,
      'totalTokens': 19,
    },
  }, surface: 'append'),
  _event(5, 1110, 'tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'call-a',
    'name': 'android_files',
    'arguments': '{"path":"a.txt"}',
  }),
  _event(6, 1170, 'tool/result', {
    'turn': 1,
    'step': 1,
    'message': {
      'role': 'tool',
      'source': {'kind': 'tool', 'callId': 'call-a'},
      'content': [
        {'type': 'text', 'text': 'file content'},
      ],
    },
  }, surface: 'append'),
  _event(7, 1180, 'step/end', {'turn': 1, 'step': 1}),
  _event(8, 1190, 'turn/end', {
    'turn': 1,
    'reason': {'kind': 'completed'},
  }),
];

class _TrajectoryRuntime extends RuntimeController {
  _TrajectoryRuntime(this.records) {
    phase = 'ready';
    timelines['saved'] = [];
  }
  final List<Json> records;
  int reads = 0;
  Completer<void>? readGate;
  bool reject = false;
  bool superseded = false;
  Completer<dynamic>? imageGate;
  bool separateImageGates = false;
  final imageGates = <Completer<dynamic>>[];
  final imageCalls = <({String method, Json params})>[];
  int generation = 0;

  @override
  int get connectionGeneration => generation;

  void reconnect() {
    generation++;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    imageCalls.add((method: method, params: Json.from(params)));
    if (method == 'api.call' && separateImageGates) {
      final gate = Completer<dynamic>();
      imageGates.add(gate);
      return gate.future;
    }
    return imageGate?.future ?? Future<dynamic>.value(null);
  }

  @override
  Future<void> openSession(String id) async {
    reads++;
    await readGate?.future;
    if (reject) throw StateError('History unavailable');
    if (superseded) return;
    timelines[id] = List.of(records);
    notifyListeners();
  }
}

void main() {
  test(
    'durable request, answer, paired tool, exact usage and timing stay linked',
    () {
      final projection = SessionTrajectoryProjection()..reconcile(_history());
      final rows = projection.records;
      final request = rows.singleWhere(
        (row) => row.kind == TrajectoryKind.request,
      );
      final answer = rows.singleWhere(
        (row) => row.kind == TrajectoryKind.assistant,
      );
      final tool = rows.singleWhere((row) => row.kind == TrajectoryKind.tool);
      expect(answer.requestSeq, request.seq);
      expect(answer.durationMs, 90);
      expect(answer.usage?.countedTotal, 19);
      expect(answer.cumulativeUsage?.countedTotal, 19);
      expect(projection.cumulative.cacheRead, 4);
      expect(tool.events.map((event) => event['type']), [
        'tool/call',
        'tool/result',
      ]);
      expect(tool.durationMs, 60);
      expect(tool.error, false);
      expect(projection.firstTime, 1000);
      expect(projection.lastTime, 1190);
    },
  );

  test(
    'failed attempts count recorded usage once; missing usage stays unknown',
    () {
      final history = [
        _event(1, 1000, 'step/start', {'turn': 1, 'step': 1}),
        _event(2, 1020, 'request/header', {
          'header': {
            'config': {'model': 'x'},
          },
        }),
        _event(3, 1060, 'assistant/attempt', {
          'turn': 1,
          'step': 1,
          'stream': [
            {
              'type': 'chunk',
              'time': 1050,
              'chunk': {
                'type': 'usage',
                'usage': {'inputTokens': 6, 'outputTokens': 2},
              },
            },
          ],
        }),
        _event(4, 1100, 'assistant/message', {
          'turn': 1,
          'step': 1,
          'message': {'content': []},
          'usage': {'inputTokens': 8, 'outputTokens': 3},
          'stream': [
            {
              'type': 'chunk',
              'time': 1090,
              'chunk': {
                'type': 'usage',
                'usage': {'inputTokens': 8, 'outputTokens': 3},
              },
            },
          ],
        }, surface: 'append'),
        _event(5, 1110, 'assistant/message', {
          'turn': 1,
          'step': 1,
          'message': {'content': []},
        }, surface: 'replace'),
      ];
      final projection = SessionTrajectoryProjection()..reconcile(history);
      expect(
        projection.records
            .where((r) => r.kind == TrajectoryKind.assistant)
            .length,
        1,
      );
      expect(
        projection.records
            .where((r) => r.kind == TrajectoryKind.attempt)
            .single
            .usage
            ?.countedTotal,
        8,
      );
      expect(projection.cumulative.countedTotal, 19);
      expect(projection.records.last.seq, 4);
    },
  );

  test('unpaired tool result remains visible without invented duration', () {
    final projection = SessionTrajectoryProjection()
      ..reconcile([
        _event(5, 2000, 'tool/result', {
          'turn': 3,
          'step': 2,
          'message': {
            'source': {'callId': 'missing'},
            'isError': true,
            'content': [],
          },
        }, surface: 'append'),
      ]);
    final row = projection.records.single;
    expect(row.summary, '缺少已加载的调用记录');
    expect(row.durationMs, isNull);
    expect(row.error, true);
  });

  testWidgets('trajectory waits for a complete read and never runs an Agent', (
    tester,
  ) async {
    final runtime = _TrajectoryRuntime(_history())
      ..readGate = Completer<void>();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
      ),
    );
    expect(runtime.reads, 1);
    expect(find.text('时间线'), findsNothing);
    runtime.readGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('时间线'), findsOneWidget);
    expect(find.text('模型请求'), findsOneWidget);
    expect(runtime.reads, 1);
  });

  testWidgets('failed history read offers explicit retry without stale rows', (
    tester,
  ) async {
    final runtime = _TrajectoryRuntime(_history())..reject = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法读取完整会话记录'), findsOneWidget);
    expect(find.text('时间线'), findsNothing);
    runtime.reject = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('时间线'), findsOneWidget);
    expect(runtime.reads, 2);
  });

  testWidgets(
    'superseded history read cannot present a partial live timeline as complete',
    (tester) async {
      final runtime = _TrajectoryRuntime(_history())..superseded = true;
      runtime.timelines['saved'] = [_history().first];
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法读取完整会话记录'), findsOneWidget);
      expect(find.text('时间线'), findsNothing);
      runtime.superseded = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('时间线'), findsOneWidget);
    },
  );

  testWidgets(
    'trajectory preserves attachment order and reads repeated images once',
    (tester) async {
      final events = _history();
      events[2] = _event(2, 1020, 'user/message', {
        'source': {'kind': 'user'},
        'content': [
          {'type': 'text', 'text': 'before'},
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'image-a',
              'mediaType': 'image/png',
              'bytes': 68,
              'width': 1,
              'height': 1,
            },
          },
          {'type': 'text', 'text': 'after'},
          {
            'type': 'file',
            'attachment': {
              'attachmentId': 'file-b',
              'name': 'draft.txt',
              'bytes': 0,
            },
          },
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'image-a',
              'mediaType': 'image/png',
              'bytes': 68,
              'width': 1,
              'height': 1,
            },
          },
        ],
      }, surface: 'append');
      final runtime = _TrajectoryRuntime(events)
        ..imageGate = Completer<dynamic>();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('你的消息'));
      await tester.pumpAndSettle();
      expect(find.text('图片 1'), findsOneWidget);
      expect(find.text('draft.txt'), findsOneWidget);
      expect(find.text('图片 2'), findsOneWidget);
      expect(find.text('TXT · 0 B'), findsOneWidget);
      final attachmentCalls = runtime.imageCalls
          .where((call) => call.method == 'api.call')
          .toList();
      expect(attachmentCalls, hasLength(1));
      expect(attachmentCalls.single.params, {
        'namespace': 'session',
        'method': 'attachment',
        'args': {
          'request': {'sessionId': 'saved', 'attachmentId': 'image-a'},
        },
      });
      await tester.tap(find.text('图片 1'));
      await tester.pumpAndSettle();
      expect(find.text('正在加载图片…'), findsOneWidget);
      expect(
        runtime.imageCalls.where((call) => call.method == 'api.call'),
        hasLength(1),
      );
    },
  );

  testWidgets('failed thumbnail waits for an explicit full-screen retry', (
    tester,
  ) async {
    final events = _history();
    events[2] = _event(2, 1020, 'user/message', {
      'source': {'kind': 'user'},
      'content': [
        {
          'type': 'image',
          'attachment': {
            'attachmentId': 'image-a',
            'mediaType': 'image/png',
            'bytes': 68,
            'width': 1,
            'height': 1,
          },
        },
      ],
    }, surface: 'append');
    final runtime = _TrajectoryRuntime(events)
      ..imageGate = Completer<dynamic>();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('你的消息'));
    await tester.pumpAndSettle();
    runtime.imageGate!.completeError(const FormatException('unavailable'));
    await tester.pumpAndSettle();
    expect(
      runtime.imageCalls.where((call) => call.method == 'api.call'),
      hasLength(1),
    );
    runtime.imageGate = Completer<dynamic>();
    await tester.tap(find.text('图片 1'));
    await tester.pumpAndSettle();
    expect(
      runtime.imageCalls.where((call) => call.method == 'api.call'),
      hasLength(2),
    );
  });

  testWidgets('tool result images use their durable result attachment', (
    tester,
  ) async {
    final events = _history();
    events[6] = _event(6, 1170, 'tool/result', {
      'turn': 1,
      'step': 1,
      'message': {
        'source': {'kind': 'tool', 'callId': 'call-a'},
        'content': [
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'tool-image',
              'name': 'result.png',
              'mediaType': 'image/png',
              'bytes': 68,
              'width': 1,
              'height': 1,
            },
          },
        ],
      },
    }, surface: 'append');
    final runtime = _TrajectoryRuntime(events)
      ..imageGate = Completer<dynamic>();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('android_files'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('android_files'));
    await tester.pumpAndSettle();
    expect(find.text('result.png'), findsOneWidget);
    final request = runtime.imageCalls.singleWhere(
      (call) => call.method == 'api.call',
    );
    expect(request.params['args'], {
      'request': {'sessionId': 'saved', 'attachmentId': 'tool-image'},
    });
  });

  testWidgets(
    'long gallery starts only two reads and skips scrolled-away queue',
    (tester) async {
      final events = _history();
      events[2] = _event(2, 1020, 'user/message', {
        'source': {'kind': 'user'},
        'content': [
          for (var index = 0; index < 40; index++)
            {
              'type': 'image',
              'attachment': {
                'attachmentId': 'image-${index.toString().padLeft(2, '0')}',
                'name': 'image-$index',
                'mediaType': 'image/png',
                'bytes': 68,
                'width': 1,
                'height': 1,
              },
            },
        ],
      }, surface: 'append');
      final runtime = _TrajectoryRuntime(events)..separateImageGates = true;
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('你的消息'));
      await tester.pumpAndSettle();
      expect(
        runtime.imageCalls.where((call) => call.method == 'api.call'),
        hasLength(2),
      );
      expect(find.text('image-35'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('image-35'),
        280,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('image-35'), findsOneWidget);
      expect(
        runtime.imageCalls.where((call) => call.method == 'api.call'),
        hasLength(2),
      );
      runtime.imageGates.first.completeError(const FormatException('offline'));
      await tester.pumpAndSettle();
      final reads = runtime.imageCalls
          .where((call) => call.method == 'api.call')
          .toList();
      expect(reads, hasLength(3));
      final third = (reads.last.params['args'] as Json)['request'] as Json;
      expect(
        int.parse((third['attachmentId'] as String).substring(6)),
        greaterThanOrEqualTo(20),
      );
    },
  );

  testWidgets(
    'reconnect invalidates in-flight thumbnails and old full-image cache',
    (tester) async {
      final events = _history();
      events[2] = _event(2, 1020, 'user/message', {
        'source': {'kind': 'user'},
        'content': [
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'image-a',
              'mediaType': 'image/png',
              'bytes': 68,
              'width': 1,
              'height': 1,
            },
          },
        ],
      }, surface: 'append');
      final runtime = _TrajectoryRuntime(events)..separateImageGates = true;
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('你的消息'));
      await tester.pumpAndSettle();
      expect(runtime.imageGates, hasLength(1));

      runtime.reconnect();
      await tester.pumpAndSettle();
      expect(runtime.imageGates, hasLength(2));
      runtime.imageGates.first.complete({
        'attachment': {
          'attachmentId': 'image-a',
          'mediaType': 'image/png',
          'bytes': 68,
          'width': 1,
          'height': 1,
        },
        'data': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      });
      await tester.pumpAndSettle();
      expect(runtime.imageGates, hasLength(2));

      runtime.imageGates[1].completeError(const FormatException('offline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('图片 1'));
      await tester.pumpAndSettle();
      expect(runtime.imageGates, hasLength(3));
    },
  );

  testWidgets(
    'assistant metrics use recorded token time across retry attempts',
    (tester) async {
      final runtime = _TrajectoryRuntime([
        _event(1, 1000, 'step/start', {'turn': 1, 'step': 1}),
        _event(2, 1030, 'assistant/attempt', {
          'turn': 1,
          'step': 1,
          'stream': [
            {
              'type': 'chunk',
              'time': 1020,
              'chunk': {'type': 'text-delta', 'text': 'first'},
            },
          ],
        }),
        _event(3, 1060, 'assistant/message', {
          'turn': 1,
          'step': 1,
          'message': {
            'content': [
              {'type': 'text', 'text': 'reply'},
            ],
          },
          'usage': {'inputTokens': 10, 'outputTokens': 4},
          'stream': [
            {
              'type': 'text-chunks',
              'time0': 1035,
              'dt': [5],
              'texts': ['', 'later'],
            },
          ],
        }, surface: 'append'),
      ]);
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTrajectoryPage(runtime: runtime, sessionId: 'saved'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent 回复'));
      await tester.pumpAndSettle();
      expect(find.text('首 token 延迟'), findsOneWidget);
      expect(find.text('20 ms'), findsOneWidget);
      expect(find.text('40 ms'), findsOneWidget);
      expect(find.text('100.0 tokens/s'), findsOneWidget);
    },
  );
}
