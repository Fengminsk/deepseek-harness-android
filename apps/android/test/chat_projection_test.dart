import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

Json event(int seq, String type, Json data, {dynamic surface}) => {
  'seq': seq,
  'time': seq * 1000,
  'type': type,
  'data': data,
  'surfaceOp': ?surface,
};

Json input(
  int seq,
  String text, {
  Json source = const {'kind': 'user'},
  dynamic surface = 'append',
}) => event(seq, 'user/message', {
  'id': 'input-$seq',
  'role': 'user',
  'source': source,
  'content': [
    {'type': 'text', 'text': text},
  ],
}, surface: surface);

Json assistant(
  int seq,
  String text, {
  int turn = 1,
  int step = 1,
  dynamic surface = 'append',
}) => event(seq, 'assistant/message', {
  'turn': turn,
  'step': step,
  'message': {
    'id': 'assistant-$seq',
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
}, surface: surface);

Json system(int seq, String text, {dynamic surface = 'append'}) =>
    event(seq, 'system/message', {
      'turn': 1,
      'step': 1,
      'message': {
        'role': 'system',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    }, surface: surface);

Json header(int seq, {String reason = 'initial', int step = 1}) =>
    event(seq, 'request/header', {
      'turn': 1,
      'step': step,
      'reason': reason,
      'header': {
        'config': {'provider': 'fixture', 'model': 'fixture'},
        'tools': [],
      },
    });

void main() {
  test('human source owns the user bubble; runtime and unknown producers remain context', () {
    final projection = ChatProjection()
      ..reconcile([
        input(0, 'my question'),
        input(
          1,
          'internal runtime context',
          source: {'kind': 'runtime-context', 'form': 'snapshot'},
        ),
        input(
          2,
          'plugin message',
          source: {'kind': 'future-plugin', 'form': 'future-form'},
        ),
        event(3, 'developer/message', {
          'turn': 1,
          'step': 1,
          'message': {
            'source': {'kind': 'tools'},
            'content': [
              {'type': 'tool-addition', 'toolName': 'android_files'},
            ],
          },
        }, surface: 'append'),
      ]);
    expect(projection.entries.map((row) => row.kind), [
      ChatEntryKind.user,
      ChatEntryKind.context,
      ChatEntryKind.context,
      ChatEntryKind.context,
    ]);
    expect(
      projection.entries[1].content.single['text'],
      'internal runtime context',
    );
    expect(projection.entries[2].title, contains('future-plugin'));
    expect(projection.entries[3].content.single['toolName'], 'android_files');
  });

  test(
    'replacement copies do not duplicate or erase append-origin conversation',
    () {
      final projection = ChatProjection()
        ..reconcile([
          input(0, 'original'),
          assistant(1, 'reply'),
          input(
            2,
            'model-only replacement',
            surface: {'op': 'replace', 'startSeq': 0, 'endSeq': 1},
          ),
          assistant(
            3,
            'copied reply',
            surface: {'op': 'replace', 'startSeq': 2, 'endSeq': 2},
          ),
        ]);
      expect(projection.entries.map((row) => row.content.single['text']), [
        'original',
        'reply',
      ]);
    },
  );

  test('system prompt is separately inspectable and same-step header does not repeat it', () {
    final projection = ChatProjection()
      ..reconcile([
        event(0, 'turn/start', {'turn': 1}),
        event(1, 'step/start', {'turn': 1, 'step': 1}),
        system(2, 'private system prompt'),
        input(3, 'hello'),
        header(4),
        assistant(5, 'hi'),
      ]);
    expect(
      projection.entries.where((row) => row.kind == ChatEntryKind.systemPrompt),
      hasLength(1),
    );
    expect(projection.entries.first.seq, 0);
    expect(projection.entries.first.text, 'private system prompt');
  });

  test(
    'later appended prompt updates retain their own historical position',
    () {
      final projection = ChatProjection()
        ..reconcile([
          system(0, 'first'),
          header(1),
          system(2, 'updated'),
          header(3, reason: 'change'),
        ]);
      final prompts = projection.entries
          .where((row) => row.kind == ChatEntryKind.systemPrompt)
          .toList();
      expect(prompts.map((row) => row.text), ['first', 'updated']);
      expect(prompts.last.title, '系统提示更新');
      expect(prompts.last.seq, 2);
    },
  );

  test('positional replacement removes effective prompt without stale prompt resurrection', () {
    final projection = ChatProjection()
      ..reconcile([
        system(0, 'original'),
        header(1),
        input(
          2,
          'replacement',
          source: {'kind': 'plugin'},
          surface: {'op': 'replace', 'startSeq': 0, 'endSeq': 0},
        ),
        header(3, reason: 'resume', step: 2),
      ]);
    // The historical card stays, but the resumed request has no surviving system prompt.
    expect(
      projection.entries.where((row) => row.kind == ChatEntryKind.systemPrompt),
      hasLength(1),
    );
  });

  test('replacement prompt follows positional order rather than latest event sequence', () {
    final projection = ChatProjection()
      ..reconcile([
        system(0, 'old first'),
        system(1, 'effective later'),
        header(2),
        system(
          3,
          'replacement earlier',
          surface: {'op': 'replace', 'startSeq': 0, 'endSeq': 0},
        ),
        header(4, reason: 'resume', step: 2),
      ]);
    expect(projection.entries.last.text, 'effective later');
  });

  test('same-step resumed prompt stays at the resumed header instead of jumping before old input', () {
    final projection = ChatProjection()
      ..reconcile([
        event(0, 'turn/start', {'turn': 1}),
        event(1, 'step/start', {'turn': 1, 'step': 1}),
        system(2, 'original prompt'),
        header(3),
        assistant(4, 'old reply'),
        system(
          5,
          'replacement prompt',
          surface: {'op': 'replace', 'startSeq': 2, 'endSeq': 2},
        ),
        header(6, reason: 'resume'),
      ]);
    expect(projection.entries.last.key, 'system:6');
    expect(projection.entries.last.seq, 6);
    expect(projection.entries.last.text, 'replacement prompt');
  });

  test('retry chain correlates producer id and attempt and cancels only its owning scheduled boundary', () {
    Json scheduled(int seq, String id, int step, int attempt) =>
        event(seq, 'llm/retry', {
          'retryId': id,
          'turn': 1,
          'step': step,
          'retry': attempt,
          'mode': 'normal',
          'maxRetries': 3,
          'delayMs': 1500,
          'provider': 'fixture',
          'policyKey': 'fixture',
          'failure': {'code': 'AUTH', 'message': 'sensitive fragment'},
        });
    final events = [
      scheduled(0, 'chain-a', 1, 1),
      scheduled(1, 'chain-b', 2, 1),
    ];
    final projection = ChatProjection()..reconcile(events);
    expect(projection.entries.first.title, '等待模型请求重试');
    expect(projection.entries.first.text, contains('计划等待 2 秒'));
    events.add(
      event(2, 'llm/retry-started', {
        'retryId': 'chain-a',
        'turn': 1,
        'step': 1,
        'retry': 1,
      }),
    );
    projection.reconcile(events);
    expect(projection.entries.first.title, '模型请求已重试');
    events.add(scheduled(3, 'chain-a', 1, 2));
    events.add(event(4, 'step/end', {'turn': 1, 'step': 1}));
    projection.reconcile(events);
    expect(projection.entries, hasLength(2));
    expect(projection.entries.first.seq, 0);
    expect(projection.entries.first.title, '模型重试已取消');
    expect(projection.entries.first.details, contains('第 1/3 次重试 · 已开始'));
    expect(projection.entries.first.details, contains('第 2/3 次重试 · 已取消'));
    expect(
      projection.entries.first.details,
      isNot(contains('sensitive fragment')),
    );
    expect(projection.entries[1].title, '等待模型请求重试');
    events.add(
      event(5, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
    );
    projection.reconcile(events);
    expect(projection.entries[1].title, '模型重试已取消');
  });

  test(
    'partial window with missing replacement endpoint does not invent a prompt',
    () {
      final projection = ChatProjection()
        ..reconcile([
          system(
            10,
            'partial replacement',
            surface: {'op': 'replace', 'startSeq': 0, 'endSeq': 1},
          ),
          header(11, reason: 'resume'),
        ]);
      expect(projection.entries, isEmpty);
    },
  );

  test('unknown append surface and unknown content are retained; bookkeeping is not a bubble', () {
    final projection = ChatProjection()
      ..reconcile([
        event(0, 'future/visible', {'payload': 'important'}, surface: 'append'),
        event(1, 'future/bookkeeping', {'payload': 'not a message'}),
        event(2, 'assistant/message', {
          'turn': 1,
          'step': 1,
          'message': {
            'content': [
              {'type': 'future-block', 'payload': 'preserved'},
            ],
          },
        }, surface: 'append'),
      ]);
    expect(projection.entries, hasLength(2));
    expect(projection.entries.first.kind, ChatEntryKind.unknown);
    expect(projection.entries.last.content.single['payload'], 'preserved');
  });

  test('command completion updates its original row, including result-only history', () {
    final events = [
      event(0, 'command/run', {
        'commandId': 'a',
        'name': 'model',
        'args': ' fixture',
      }),
      event(1, 'command/run', {'commandId': 'b', 'name': 'permission'}),
      event(2, 'command/done', {
        'commandId': 'b',
        'kind': 'error',
        'text': 'failed',
      }),
      event(3, 'command/done', {
        'commandId': 'a',
        'kind': 'success',
        'text': 'changed',
      }),
      event(4, 'command/done', {
        'commandId': 'c',
        'kind': 'success',
        'text': 'partial window',
      }),
    ];
    final projection = ChatProjection()..reconcile(events);
    expect(projection.entries, hasLength(3));
    expect(projection.entries[0].title, '/model fixture');
    expect(projection.entries[0].text, 'changed');
    expect(projection.entries[1].error, isTrue);
    expect(projection.entries[2].text, 'partial window');
  });

  test('failures, interrupted turns and max-tokens remain visible without exposing AUTH details', () {
    final projection = ChatProjection()
      ..reconcile([
        event(0, 'turn/end', {
          'turn': 1,
          'reason': {
            'kind': 'error',
            'error': {
              'code': 'AUTH',
              'message': 'credential fragment must not display',
            },
          },
        }),
        event(1, 'turn/end', {
          'turn': 2,
          'reason': {'kind': 'interrupted'},
        }),
        event(2, 'turn/end', {
          'turn': 3,
          'reason': {'kind': 'max-tokens'},
        }),
        event(3, 'turn/end', {
          'turn': 4,
          'reason': {'kind': 'completed'},
        }),
      ]);
    expect(projection.entries, hasLength(3));
    expect(
      projection.entries.first.text,
      isNot(contains('credential fragment')),
    );
    expect(projection.entries[1].error, isTrue);
    expect(projection.entries[2].text, contains('输出长度'));
  });

  test('title and assistant settlement follow current session window, not previous conversation', () {
    final projection = ChatProjection()
      ..reconcile([
        event(0, 'session/title', {'title': 'Readable title'}),
        assistant(1, 'same reply', turn: 2, step: 3),
      ]);
    expect(projection.title, 'Readable title');
    expect(projection.hasFinalAssistant(turn: 2, step: 3), isTrue);
    expect(projection.hasFinalAssistant(turn: 2, step: 4), isFalse);
    projection.reconcile([input(0, 'new conversation')]);
    expect(projection.title, isNull);
    expect(projection.hasFinalAssistant(turn: 2, step: 3), isFalse);
  });

  test('failed attempt prefix stays inspectable without settling the later retry in the same step', () {
    final events = <Json>[
      {
        ...event(0, 'assistant/attempt', {
          'turn': 1,
          'step': 1,
          'stream': [
            {
              'type': 'text-chunks',
              'index': 0,
              'time0': 0,
              'dt': [0],
              'texts': ['safe prefix'],
            },
          ],
        }),
        // Produced by the original canonical assembler in the runtime carrier.
        'assistantContent': [
          {'type': 'text', 'text': 'safe prefix'},
        ],
      },
    ];
    final projection = ChatProjection()..reconcile(events);
    expect(projection.hasFinalAssistant(turn: 1, step: 1), isFalse);
    expect(projection.entries.single.title, '未完成的模型回复');
    expect(projection.entries.single.content.single['text'], 'safe prefix');
    events.add(assistant(1, 'complete retry'));
    projection.reconcile(events);
    expect(projection.hasFinalAssistant(turn: 1, step: 1), isTrue);
    expect(projection.entries, hasLength(2));
    expect(projection.entries.last.content.single['text'], 'complete retry');
  });

  test('attempt without a prepared prefix remains inspectable and interrupted messages preserve their status', () {
    final finalMessage = assistant(1, 'saved partial');
    (finalMessage['data'] as Json)['interrupted'] = true;
    final projection = ChatProjection()
      ..reconcile([
        event(0, 'assistant/attempt', {
          'turn': 1,
          'step': 1,
          'stream': <Json>[],
        }),
        finalMessage,
      ]);
    expect(projection.entries.first.kind, ChatEntryKind.unknown);
    expect(projection.entries.first.title, '未完成的模型请求');
    expect(projection.entries.last.interrupted, isTrue);
  });

  test('10k history is interpreted once; unchanged streaming frames do not walk or rebuild rows', () {
    final events = List.generate(
      10000,
      (index) => input(index, 'message $index'),
    );
    final projection = ChatProjection()..reconcile(events);
    final first = projection.entries.first;
    final last = projection.entries.last;
    for (var frame = 0; frame < 300; frame++) {
      projection.reconcile(events);
    }
    expect(projection.processedEventCount, 10000);
    events.add(assistant(10000, 'new reply'));
    projection.reconcile(events);
    expect(projection.processedEventCount, 10001);
    expect(identical(projection.entries.first, first), isTrue);
    expect(identical(projection.entries[9999], last), isTrue);
    expect(projection.indexOfKey(last.key), 9999);
  });
}
