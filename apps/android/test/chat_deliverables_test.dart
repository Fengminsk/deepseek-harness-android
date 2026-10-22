import 'package:dsh_android/chat_deliverables.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

Json artifactEvent(int seq, String type, Json data, {String? surface}) => {
  'seq': seq,
  'type': type,
  'data': data,
  'surfaceOp': ?surface,
};

Json todoEvent(int seq, List<dynamic> todos) =>
    artifactEvent(seq, 'todo/write', {'todos': todos});

Json presentEvent(int seq, int turn, List<dynamic> files) => artifactEvent(
  seq,
  'deliverables/presented',
  {'turn': turn, 'callId': 'call-$seq', 'files': files},
);

Json endEvent(int seq, int turn, {String reason = 'completed'}) =>
    artifactEvent(seq, 'turn/end', {
      'turn': turn,
      'reason': {'kind': reason},
    });

Json replyEvent(int seq, int turn, String text, {String surface = 'append'}) =>
    artifactEvent(seq, 'assistant/message', {
      'turn': turn,
      'step': 1,
      'message': {
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    }, surface: surface);

const parallelTodos = [
  {'content': '整理已授权文件', 'status': 'completed'},
  {'content': '分析表格', 'status': 'in_progress'},
  {'content': '生成报告', 'status': 'in_progress'},
  {'content': '核对交付内容', 'status': 'pending'},
];

void main() {
  test('cold replay keeps parallel statuses and whole-list replacement', () {
    final projection = ChatArtifactsProjection()
      ..reconcile([
        artifactEvent(1, 'turn/start', {'turn': 1}),
        todoEvent(2, parallelTodos),
        todoEvent(3, [
          {'content': '生成报告', 'status': 'completed'},
        ]),
        endEvent(4, 1),
      ]);
    final writes = projection.entries.whereType<ChatTodoSnapshot>().toList();
    expect(writes, hasLength(2));
    expect(writes.first.count(ChatTodoStatus.inProgress), 2);
    expect(writes.first.summary, contains('2 项进行中'));
    expect(projection.currentTodos!.items!.single.content, '生成报告');
    expect(
      projection.currentTodos!.items!.single.status,
      ChatTodoStatus.completed,
    );
  });

  test(
    'new turn clears current dock, not history; empty write clears explicitly',
    () {
      final events = [todoEvent(1, parallelTodos), endEvent(2, 1)];
      final projection = ChatArtifactsProjection()..reconcile(events);
      expect(projection.currentTodos, isNotNull);
      events.add(artifactEvent(3, 'turn/start', {'turn': 2}));
      projection.reconcile(events);
      expect(projection.currentTodos, isNull);
      expect(projection.entries.whereType<ChatTodoSnapshot>(), hasLength(1));
      events.add(todoEvent(4, []));
      projection.reconcile(events);
      expect(projection.currentTodos!.items, isEmpty);
      expect(projection.currentTodos!.summary, '待办已清空');
    },
  );

  test('durable write is independent of missing or failed tool receipts', () {
    final projection = ChatArtifactsProjection()
      ..reconcile([
        artifactEvent(1, 'tool/call', {
          'turn': 1,
          'name': 'todo_write',
          'arguments': '{"todos":[]}',
        }),
        todoEvent(2, parallelTodos),
        artifactEvent(3, 'tool/result', {
          'message': {'isError': true},
        }),
      ]);
    expect(projection.currentTodos!.items, hasLength(4));
    final noWrite = ChatArtifactsProjection()
      ..reconcile([
        artifactEvent(1, 'tool/call', {
          'name': 'todo_write',
          'arguments': '{"todos":[]}',
        }),
        artifactEvent(2, 'tool/result', {
          'message': {'isError': false},
        }),
      ]);
    expect(noWrite.currentTodos, isNull);
  });

  test('unknown or malformed todo state is not presented as an empty or complete plan', () {
    for (final invalid in [
      [
        {'content': 'future', 'status': 'future'},
      ],
      [
        {'content': '', 'status': 'completed'},
      ],
      [
        {'content': 'same', 'status': 'pending'},
        {'content': 'same', 'status': 'completed'},
      ],
      [null],
    ]) {
      final projection = ChatArtifactsProjection()
        ..reconcile([todoEvent(1, invalid)]);
      expect(projection.currentTodos!.items, isNull);
      expect(projection.currentTodos!.summary, contains('无法显示'));
    }
  });

  test('presented cards wait for turn end and select declarations before closing reply', () {
    final events = [
      artifactEvent(1, 'turn/start', {'turn': 1}),
      presentEvent(2, 1, [
        {'path': '/workspace/report.pdf', 'description': '报告'},
      ]),
      replyEvent(3, 1, '报告已生成'),
      presentEvent(4, 1, [
        {'path': '/workspace/too-late.pdf'},
      ]),
    ];
    final projection = ChatArtifactsProjection()..reconcile(events);
    expect(projection.entries.whereType<ChatPresentedTurn>(), isEmpty);
    events.add(endEvent(5, 1));
    projection.reconcile(events);
    final turn = projection.entries.whereType<ChatPresentedTurn>().single;
    expect(turn.seq, 5);
    expect(turn.files.single.path, '/workspace/report.pdf');
    expect(turn.files.single.seq, 2);
    expect(turn.files.single.index, 0);
  });

  test('no closing prose uses turn end, even an interrupted turn', () {
    final projection = ChatArtifactsProjection()
      ..reconcile([
        presentEvent(2, 1, [
          {'path': './actual.md'},
        ]),
        endEvent(3, 1, reason: 'interrupted'),
      ]);
    expect(
      projection.entries
          .whereType<ChatPresentedTurn>()
          .single
          .files
          .single
          .path,
      './actual.md',
    );
  });

  test('latest declaration wins per exact path, keeping first order and original indices', () {
    final projection = ChatArtifactsProjection()
      ..reconcile([
        presentEvent(1, 1, [
          null,
          {'path': 'folder/a%20#?.pdf', 'description': '旧版'},
          {'path': 'b.xlsx'},
        ]),
        presentEvent(2, 1, [
          {'path': 'b.xlsx', 'description': '表格'},
          {'path': 'folder/a%20#?.pdf', 'description': '最终报告'},
          {'path': './b.xlsx'},
        ]),
        endEvent(3, 1),
      ]);
    final files = projection.entries
        .whereType<ChatPresentedTurn>()
        .single
        .files;
    expect(files.map((file) => file.path), [
      'folder/a%20#?.pdf',
      'b.xlsx',
      './b.xlsx',
    ]);
    expect(files.first.description, '最终报告');
    expect((files.first.seq, files.first.index), (2, 1));
    expect(files.first.name, 'a%20#?.pdf');
  });

  test('present never derives paths from args, prose or unsuccessful result metadata', () {
    final projection = ChatArtifactsProjection()
      ..reconcile([
        artifactEvent(1, 'tool/call', {
          'name': 'present',
          'arguments': '{"files":[{"path":"fake.pdf"}]}',
        }),
        artifactEvent(2, 'tool/result', {
          'message': {'isError': true},
          'meta': {
            'files': [
              {'path': 'fake.pdf'},
            ],
          },
        }),
        replyEvent(3, 1, '[文件](fake.pdf)'),
        endEvent(4, 1),
      ]);
    expect(projection.entries, isEmpty);
  });

  test(
    'invalid delivery records do not shift valid original file coordinates',
    () {
      final projection = ChatArtifactsProjection()
        ..reconcile([
          artifactEvent(1, 'deliverables/presented', {
            'turn': 1,
            'files': [
              {'path': 'no-call.pdf'},
            ],
          }),
          presentEvent(2, 1, [
            {'path': ''},
            {'path': 'invalid.pdf', 'description': 12},
            {'path': 'valid.pdf'},
          ]),
          endEvent(3, 1),
        ]);
      final file = projection.entries
          .whereType<ChatPresentedTurn>()
          .single
          .files
          .single;
      expect((file.seq, file.index, file.path), (2, 2, 'valid.pdf'));
    },
  );

  test('turns do not share files and non-append replacement cannot move closing boundary', () {
    final projection = ChatArtifactsProjection()
      ..reconcile([
        presentEvent(1, 1, [
          {'path': 'one.pdf'},
        ]),
        replyEvent(2, 1, 'done'),
        presentEvent(3, 1, [
          {'path': 'later.pdf'},
        ]),
        replyEvent(4, 1, 'replacement', surface: 'replace'),
        endEvent(5, 1),
        presentEvent(6, 2, [
          {'path': 'two.pdf'},
        ]),
        endEvent(7, 2),
      ]);
    final turns = projection.entries.whereType<ChatPresentedTurn>().toList();
    expect(turns, hasLength(2));
    expect(turns[0].files.single.path, 'one.pdf');
    expect(turns[1].files.single.path, 'two.pdf');
  });

  test('persisted interrupted assistant blocks bound deliveries like original turn tail', () {
    final attempt = artifactEvent(2, 'assistant/attempt', {
      'turn': 1,
      'step': 1,
    });
    attempt['assistantContent'] = [
      {'type': 'text', 'text': 'partial response'},
    ];
    final projection = ChatArtifactsProjection()
      ..reconcile([
        presentEvent(1, 1, [
          {'path': 'before.pdf'},
        ]),
        attempt,
        presentEvent(3, 1, [
          {'path': 'after.pdf'},
        ]),
        endEvent(4, 1, reason: 'interrupted'),
      ]);
    expect(
      projection.entries
          .whereType<ChatPresentedTurn>()
          .single
          .files
          .single
          .path,
      'before.pdf',
    );
  });

  test('incremental stream, cold reconstruction and prepended history produce the same data', () {
    final events = [
      todoEvent(1, parallelTodos),
      presentEvent(2, 1, [
        {'path': 'a.pdf'},
      ]),
      replyEvent(3, 1, 'ready'),
      endEvent(4, 1),
      artifactEvent(5, 'turn/start', {'turn': 2}),
      todoEvent(6, [
        {'content': '后续', 'status': 'pending'},
      ]),
    ];
    final incremental = ChatArtifactsProjection();
    final window = <Json>[];
    for (final event in events) {
      window.add(event);
      incremental.reconcile(window);
    }
    final cold = ChatArtifactsProjection()..reconcile(events);
    final prepended = ChatArtifactsProjection()
      ..reconcile(events.sublist(3))
      ..reconcile(events);
    for (final projection in [cold, prepended]) {
      expect(
        projection.entries.map((entry) => entry.key),
        incremental.entries.map((entry) => entry.key),
      );
      expect(projection.currentTodos!.items!.single.content, '后续');
      expect(
        projection.entries
            .whereType<ChatPresentedTurn>()
            .single
            .files
            .single
            .path,
        'a.pdf',
      );
    }
    final revision = incremental.revision;
    final count = incremental.processedEventCount;
    for (var frame = 0; frame < 500; frame++) {
      incremental.reconcile(window);
    }
    expect(incremental.revision, revision);
    expect(incremental.processedEventCount, count);
    incremental.reconcile([]);
    expect(incremental.currentTodos, isNull);
    expect(incremental.entries, isEmpty);
  });
}
