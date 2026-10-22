import 'package:dsh_android/chat_feedback_projection.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

Json event(
  int seq,
  String type, {
  int turn = 1,
  int? step,
  Json? data,
  String? surfaceOp,
}) => {
  'seq': seq,
  'time': seq * 1000,
  'type': type,
  'surfaceOp': ?surfaceOp,
  'data': {'turn': turn, 'step': ?step, ...?data},
};
Json answer(
  int seq,
  int step,
  String id,
  List<Json> content, {
  int turn = 1,
  String op = 'append',
}) => event(
  seq,
  'assistant/message',
  turn: turn,
  step: step,
  surfaceOp: op,
  data: {
    'message': {'id': id, 'role': 'assistant', 'content': content},
  },
);
List<Json> text(String value) => [
  {'type': 'text', 'text': value},
];

void main() {
  test(
    'only the last text-bearing finalized step of a closed Turn owns feedback',
    () {
      final projection = ChatFeedbackProjection();
      final events = <Json>[
        event(0, 'turn/start'),
        event(1, 'step/start', step: 1),
        answer(2, 1, 'first', text('先检查文件')),
        event(3, 'step/end', step: 1),
        event(4, 'step/start', step: 2),
        answer(5, 2, 'tool-only', [
          {'type': 'tool-call', 'name': 'read', 'id': 't', 'arguments': '{}'},
        ]),
        event(6, 'step/end', step: 2),
        event(7, 'step/start', step: 3),
        answer(8, 3, 'final', text('结果')),
        event(9, 'step/end', step: 3),
      ];
      projection.reconcile(events);
      expect(projection.entries, isEmpty);
      expect(projection.allClosing, isEmpty);
      events.add(
        event(
          10,
          'turn/end',
          data: {
            'reason': {'kind': 'completed'},
          },
        ),
      );
      projection.reconcile(events);
      final target = projection.entries.single;
      expect(
        (target.messageId, target.messageSeq, target.turnEndSeq, target.rowKey),
        ('final', 8, 10, 'assistant:8'),
      );
      final closing = projection.allClosing.single;
      expect(
        (closing.text, closing.messageId, closing.seq),
        ('结果', 'final', 8),
      );
      final count = projection.processedEventCount;
      projection.reconcile(events);
      expect(projection.processedEventCount, count);
    },
  );

  test('reasoning, blank text, image-only and replacement surfaces do not become ratings', () {
    final projection = ChatFeedbackProjection();
    projection.reconcile([
      answer(1, 1, 'text', text('回答')),
      answer(2, 2, 'reasoning', [
        {'type': 'reasoning', 'text': '思考'},
      ]),
      answer(3, 3, 'blank', text(' \n')),
      answer(4, 4, 'image', [
        {'type': 'image', 'url': 'fixture'},
      ]),
      answer(5, 5, 'replacement', text('模型上下文替换'), op: 'replace'),
      event(
        6,
        'turn/end',
        data: {
          'reason': {'kind': 'error'},
        },
      ),
    ]);
    expect(projection.entries.single.messageId, 'text');
  });

  test(
    'later frozen text has no durable target and shadows the prior answer',
    () {
      final projection = ChatFeedbackProjection();
      projection.reconcile([
        answer(1, 1, 'earlier', text('先检查')),
        {
          ...event(2, 'assistant/attempt', step: 2),
          'assistantContent': text('未完成的回答'),
        },
        event(3, 'step/end', step: 2),
        event(
          4,
          'turn/end',
          data: {
            'reason': {'kind': 'interrupted'},
          },
        ),
      ]);
      expect(projection.entries, isEmpty);
      final partial = projection.allClosing.single;
      expect((partial.turn, partial.step, partial.text), (1, 2, '未完成的回答'));
      expect(partial.seq, closeTo(2.1, .000001));
      expect(partial.messageId, isNull);
      expect(partial.messageSeq, isNull);
      expect(partial.turnEndSeq, 4);
      projection.reconcile([
        answer(1, 1, 'earlier', text('先检查')),
        {
          ...event(2, 'assistant/attempt', step: 2),
          'assistantContent': [
            {'type': 'reasoning', 'text': '只思考'},
          ],
        },
        event(
          3,
          'turn/end',
          data: {
            'reason': {'kind': 'interrupted'},
          },
        ),
      ]);
      expect(projection.entries.single.messageId, 'earlier');
    },
  );

  test('same-step retries clear superseded answers; final recovered answer owns the target', () {
    final projection = ChatFeedbackProjection();
    final before = <Json>[
      answer(1, 1, 'earlier', text('先检查')),
      answer(2, 2, 'abandoned', text('错误尝试')),
      event(3, 'llm/retry', step: 2),
      {
        ...event(4, 'assistant/attempt', step: 2),
        'assistantContent': text('后续中断'),
      },
      event(5, 'step/end', step: 2),
    ];
    projection.reconcile([...before, event(6, 'turn/end')]);
    expect(projection.entries, isEmpty);
    expect(projection.allClosing.single.text, '后续中断');
    projection.reconcile([
      ...before,
      event(6, 'llm/retry', step: 2),
      answer(7, 2, 'recovered', text('完成')),
      event(8, 'turn/end'),
    ]);
    expect(projection.entries.single.messageId, 'recovered');
    expect(projection.allClosing.single.text, '完成');
    expect(projection.allClosing.single.seq, 7);
  });

  test('a tail window works without starts and prepend or owner replacement rebuilds targets', () {
    final projection = ChatFeedbackProjection();
    final second = <Json>[
      answer(20, 1, 'second', text('第二轮'), turn: 2),
      event(21, 'turn/end', turn: 2),
    ];
    projection.reconcile(second);
    expect(projection.entries.single.messageId, 'second');
    expect(projection.allClosing.single.turn, 2);
    projection.reconcile([
      answer(2, 1, 'first', text('第一轮')),
      event(3, 'turn/end'),
      ...second,
    ]);
    expect(projection.entries.map((target) => target.messageId), [
      'first',
      'second',
    ]);
    expect(projection.allClosing.map((closing) => closing.text), [
      '第一轮',
      '第二轮',
    ]);
    projection.reconcile([]);
    expect(projection.entries, isEmpty);
    expect(projection.allClosing, isEmpty);
  });

  test('live frozen text joins blocks in index order and uses turn end without step end', () {
    final projection = ChatFeedbackProjection();
    final events = <Json>[
      event(
        1,
        'assistant/live-chunk',
        step: 1,
        data: {
          'chunk': {'type': 'text-delta', 'index': 2, 'text': '尾部'},
        },
      ),
      event(
        2,
        'assistant/live-chunk',
        step: 1,
        data: {
          'chunk': {'type': 'text-delta', 'index': 0, 'text': '开头\n'},
        },
      ),
      event(
        3,
        'assistant/live-chunk',
        step: 1,
        data: {
          'chunk': {'type': 'text-delta', 'index': 1, 'text': '替换内容'},
        },
      ),
      event(
        4,
        'assistant/live-chunk',
        step: 1,
        data: {
          'chunk': {'type': 'reasoning-delta', 'index': 1, 'text': '思考不可复制'},
        },
      ),
      event(5, 'turn/end'),
    ];
    projection.reconcile(events);
    expect(projection.entries, isEmpty);
    final closing = projection.allClosing.single;
    expect(closing.text, '开头\n尾部');
    expect(closing.seq, closeTo(4.1, .000001));
    expect(closing.rowKey, 'assistant-frozen:1:1:4.1');
    final replay = ChatFeedbackProjection()..reconcile(List.of(events));
    expect(replay.allClosing.single.text, closing.text);
    expect(replay.allClosing.single.seq, closing.seq);
  });

  test('retry clears partial blocks and final text keeps exact original concatenation', () {
    final projection = ChatFeedbackProjection();
    final events = <Json>[
      event(
        1,
        'assistant/live-chunk',
        step: 1,
        data: {
          'chunk': {'type': 'text-delta', 'index': 0, 'text': '不应残留'},
        },
      ),
      event(2, 'llm/retry', step: 1),
      answer(3, 1, 'real', [
        {'type': 'text', 'text': '甲'},
        {'type': 'reasoning', 'text': '思考'},
        {'type': 'text', 'text': '乙\n丙'},
      ]),
      event(4, 'turn/end'),
    ];
    for (var end = 0; end <= events.length; end++) {
      projection.reconcile(events.sublist(0, end));
    }
    expect(projection.allClosing.single.text, '甲乙\n丙');
    expect(projection.allClosing.single.messageId, 'real');
    expect(projection.entries.single.messageId, 'real');
    final replay = ChatFeedbackProjection()..reconcile(events);
    expect(replay.allClosing.single.text, projection.allClosing.single.text);
  });

  test('text without a durable ID keeps actions but never creates feedback identity', () {
    final projection = ChatFeedbackProjection()
      ..reconcile([
        answer(1, 1, 'earlier', text('旧回答')),
        answer(2, 2, '', text('当前正文')),
        event(3, 'turn/end'),
      ]);
    expect(projection.allClosing.single.text, '当前正文');
    expect(projection.allClosing.single.messageId, isNull);
    expect(projection.allClosing.single.messageSeq, 2);
    expect(projection.entries, isEmpty);
  });
}
