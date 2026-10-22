import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:dsh_android/tool_activity_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tool_activity_fixture.dart';

void main() {
  test(
    'pairs by turn step and source call id, including repeated fallback ids',
    () {
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1),
          callEvent(2, step: 2),
          callEvent(3, turn: 2),
          resultEvent(4, step: 2, text: 'second step'),
          resultEvent(5, turn: 2, text: 'second turn'),
          resultEvent(6, text: 'first step'),
        ]);
      final cards = projection.byAnchorSeq;
      expect(cards, hasLength(3));
      expect(cards[1]!.resultText, 'first step');
      expect(cards[2]!.resultText, 'second step');
      expect(cards[3]!.resultText, 'second turn');
      expect(cards.values.map((card) => card.identity).toSet(), hasLength(3));
      expect(projection.consumedSeqs, {1, 2, 3, 4, 5, 6});
    },
  );

  test('result-first and result-only preserve recorded facts and late call pairing', () {
    final events = [resultEvent(2)];
    final projection = ToolActivityProjection()..reconcile(events);
    final resultOnly = projection.byAnchorSeq[2]!;
    expect(resultOnly.hasCall, isFalse);
    expect(resultOnly.name, '');
    expect(resultOnly.argumentsRaw, isNull);
    expect(resultOnly.phase, ToolActivityPhase.completed);
    events.add(callEvent(1));
    projection.reconcile(events);
    final paired = projection.byAnchorSeq[1]!;
    expect(paired.identity, resultOnly.identity);
    expect(paired.hasCall, isTrue);
    expect(paired.resultText, 'done');
    expect(paired.phase, ToolActivityPhase.completed);
  });

  test(
    'only append results settle calls; replacement does not create completion',
    () {
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1),
          resultEvent(
            2,
            surfaceOp: {'op': 'replace', 'startSeq': 0, 'endSeq': 1},
          ),
          resultEvent(
            3,
            id: 'replace-only',
            surfaceOp: {'op': 'replace', 'startSeq': 1, 'endSeq': 2},
          ),
          resultEvent(4, id: 'no-surface', surfaceOp: null),
        ]);
      expect(projection.byAnchorSeq, hasLength(1));
      expect(projection.byAnchorSeq[1]!.phase, ToolActivityPhase.pending);
      expect(projection.consumedSeqs, {1, 2, 3, 4});
    },
  );

  test('idle does not complete calls; explicit matching closure interrupts pending only', () {
    final events = <Json>[
      callEvent(1),
      callEvent(2, id: 'success'),
      resultEvent(3, id: 'success'),
      toolEvent(4, 'agent/status', {'status': 'idle'}),
      toolEvent(5, 'step/end', {'turn': 2, 'step': 1}),
    ];
    final projection = ToolActivityProjection()..reconcile(events);
    expect(projection.byAnchorSeq[1]!.phase, ToolActivityPhase.pending);
    events.add(toolEvent(6, 'step/end', {'turn': 1, 'step': 1}));
    projection.reconcile(events);
    expect(projection.byAnchorSeq[1]!.phase, ToolActivityPhase.interrupted);
    expect(projection.byAnchorSeq[1]!.hasResult, isFalse);
    expect(projection.byAnchorSeq[1]!.boundary!['seq'], 6);
    expect(projection.byAnchorSeq[2]!.phase, ToolActivityPhase.completed);
    events.add(resultEvent(7));
    projection.reconcile(events);
    expect(projection.byAnchorSeq[1]!.phase, ToolActivityPhase.completed);
    expect(projection.byAnchorSeq[1]!.boundary, isNull);
  });

  test(
    'structured failure and original interruption preserve error detail',
    () {
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1),
          resultEvent(
            2,
            isError: true,
            error: {'name': 'Denied', 'code': 'denied', 'reason': 'declined'},
          ),
          callEvent(3, id: 'interrupted'),
          resultEvent(
            4,
            id: 'interrupted',
            isError: true,
            error: {'name': 'Interrupted', 'code': 'interrupted'},
          ),
        ]);
      expect(projection.byAnchorSeq[1]!.phase, ToolActivityPhase.failed);
      expect(projection.byAnchorSeq[1]!.error!['reason'], 'declined');
      expect(projection.byAnchorSeq[3]!.phase, ToolActivityPhase.interrupted);
      expect(projection.byAnchorSeq[3]!.hasResult, isTrue);
    },
  );

  test(
    'PTC children pair end before start and preserve later parent edges',
    () {
      final events = <Json>[
        callEvent(1, name: 'ptc'),
        dispatchEvent(2, parent: 'sub-a', child: 'sub-b', end: true),
      ];
      final projection = ToolActivityProjection()..reconcile(events);
      final missingParent = projection.byAnchorSeq[1]!.children.single;
      expect(missingParent.callId, 'sub-a');
      expect(missingParent.phase, ToolActivityPhase.unknown);
      expect(missingParent.children.single.callId, 'sub-b');
      events.addAll([
        dispatchEvent(3),
        dispatchEvent(4, parent: 'sub-a', child: 'sub-b'),
        dispatchEvent(5, end: true),
      ]);
      projection.reconcile(events);
      final child = projection.byAnchorSeq[1]!.children.single;
      expect(child.hasCall, isTrue);
      expect(child.phase, ToolActivityPhase.completed);
      expect(child.children.single.hasCall, isTrue);
      expect(child.children.single.phase, ToolActivityPhase.completed);
      expect(child.children.single.resultText, 'child result');
    },
  );

  test(
    'PTC wrong-parent and cyclic edges are retained raw without regrouping',
    () {
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1, name: 'ptc'),
          dispatchEvent(2),
          dispatchEvent(3, parent: 'sub-a', child: 'sub-b'),
          dispatchEvent(4, parent: 'sub-b', child: 'sub-a', end: true),
          dispatchEvent(5, parent: 'sub-b', child: 'call-0'),
          dispatchEvent(6, parent: 'sub-a', child: 'sub-a'),
        ]);
      final root = projection.byAnchorSeq[1]!;
      expect(root.children.single.children.single.callId, 'sub-b');
      expect(root.children.single.phase, ToolActivityPhase.pending);
      expect(root.warnings, hasLength(3));
      expect(jsonDecode(root.rawJson)['events'], hasLength(6));
    },
  );

  test(
    'PTC depth ceiling bounds traversal while retaining rejected raw event',
    () {
      final events = <Json>[callEvent(1, name: 'ptc')];
      for (var i = 1; i <= 256; i++) {
        events.add(
          dispatchEvent(
            i + 1,
            parent: i == 1 ? 'call-0' : 'sub-${i - 1}',
            child: 'sub-$i',
          ),
        );
      }
      final projection = ToolActivityProjection()..reconcile(events);
      var card = projection.byAnchorSeq[1]!;
      var depth = 1;
      while (card.children.isNotEmpty) {
        card = card.children.single;
        depth++;
      }
      expect(depth, ToolActivityProjection.maxDepth);
      expect(projection.byAnchorSeq[1]!.warnings, hasLength(1));
      expect(
        jsonDecode(projection.byAnchorSeq[1]!.rawJson)['events'],
        hasLength(257),
      );
    },
  );

  test('PTC attaches to current original step and leaves ambiguous late records separate', () {
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(1),
        toolEvent(2, 'step/start', {'turn': 2, 'step': 1}),
        callEvent(3, turn: 2),
        dispatchEvent(4),
        toolEvent(5, 'turn/end', {
          'turn': 2,
          'reason': {'kind': 'complete'},
        }),
        dispatchEvent(6, child: 'unassigned'),
      ]);
    expect(projection.byAnchorSeq[1]!.children, isEmpty);
    expect(projection.byAnchorSeq[3]!.children.single.callId, 'sub-a');
    expect(
      projection.byAnchorSeq[3]!.children.single.phase,
      ToolActivityPhase.interrupted,
    );
    expect(projection.byAnchorSeq[6]!.warnings, isNotEmpty);
    expect(projection.byAnchorSeq[6]!.children.single.callId, 'unassigned');
  });

  test(
    'unrelated stream frames retain snapshots and history replacement rebuilds',
    () {
      final events = <Json>[callEvent(1), resultEvent(2)];
      final projection = ToolActivityProjection()..reconcile(events);
      final original = projection.byAnchorSeq[1]!;
      final raw = original.rawJson;
      events.add(
        toolEvent(3, 'assistant/live-chunk', {
          'chunk': {'type': 'text-delta', 'text': 'next'},
        }),
      );
      projection.reconcile(events);
      expect(identical(projection.byAnchorSeq[1], original), isTrue);
      expect(identical(projection.byAnchorSeq[1]!.rawJson, raw), isTrue);
      events[1] = resultEvent(2, text: 'reloaded');
      projection.reconcile([...events]);
      expect(projection.byAnchorSeq[1]!.resultText, 'reloaded');
      projection.reconcile([]);
      expect(projection.byAnchorSeq, isEmpty);
    },
  );

  test('late scope resolves previously unscoped child closure', () {
    final projection = ToolActivityProjection()
      ..reconcile([
        dispatchEvent(2),
        toolEvent(3, 'step/end', {'turn': 1, 'step': 1}),
        callEvent(1, name: 'ptc'),
      ]);
    final root = projection.byAnchorSeq[1]!;
    expect(root.phase, ToolActivityPhase.interrupted);
    expect(root.children.single.phase, ToolActivityPhase.interrupted);
    expect(root.children.single.boundary!['seq'], 3);
  });

  test(
    'Android document cards preserve SAF root identity and read continuation',
    () {
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1, name: 'android_files', args: {'action': 'roots'}),
          resultEvent(
            2,
            text: jsonEncode([
              {
                'id': 'opaque-saf-grant',
                'name': '文档',
                'directory': true,
                'available': false,
              },
            ]),
          ),
          callEvent(
            3,
            id: 'read',
            name: 'android_files',
            args: {
              'action': 'read',
              'root': 'opaque-saf-grant',
              'path': 'notes/a.txt',
              'offset': 100,
            },
          ),
          resultEvent(
            4,
            id: 'read',
            text: jsonEncode({
              'text': '当前片段',
              'offset': 100,
              'nextOffset': 124,
              'truncated': true,
            }),
          ),
        ]);
      expect(
        ToolActivityPresentation.from(projection.byAnchorSeq[1]!)
            .fields['文件列表'],
        '目录 · 文档（不可用）',
      );
      final read = ToolActivityPresentation.from(projection.byAnchorSeq[3]!)
          .fields;
      expect(read['授权项目'], 'opaque-saf-grant');
      expect(read['相对路径'], 'notes/a.txt');
      expect(read['读取内容'], '当前片段');
      expect(read['起始偏移'], '100');
      expect(read['下次偏移'], '124');
      expect(read['读取范围'], contains('后续内容需继续读取'));
    },
  );

  test('a failed PTC child stays visible in its completed parent summary', () {
    final failedChild = dispatchEvent(3, end: true);
    (failedChild['data'] as Json)['isError'] = true;
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(1, name: 'ptc'),
        dispatchEvent(2),
        failedChild,
        resultEvent(4, text: 'root returned'),
      ]);
    final activity = projection.byAnchorSeq[1]!;
    expect(activity.phase, ToolActivityPhase.completed);
    expect(toolActivityNeedsAttention(activity), isTrue);
    expect(
      ToolActivityPresentation.from(activity).summary(activity),
      '含失败调用 执行工具',
    );
  });

  test('shell shows explicit exit timeout and stderr without inferring absent success', () {
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(1, args: {'command': 'cat missing'}),
        resultEvent(
          2,
          text: jsonEncode({
            'stdout': '',
            'stderr': 'missing',
            'exitCode': 2,
            'timedOut': false,
            'cancelled': false,
          }),
        ),
        callEvent(3, id: 'timeout'),
        resultEvent(
          4,
          id: 'timeout',
          text: jsonEncode({
            'stdout': 'partial',
            'stderr': '',
            'exitCode': null,
            'timedOut': true,
            'signal': 'SIGTERM',
            'truncated': true,
          }),
        ),
      ]);
    final failedProcess = ToolActivityPresentation.from(
      projection.byAnchorSeq[1]!,
    );
    expect(failedProcess.fields, containsPair('退出码', '2'));
    expect(failedProcess.fields, containsPair('stderr', 'missing'));
    expect(projection.byAnchorSeq[1]!.phase, ToolActivityPhase.completed);
    expect(failedProcess.needsAttention(projection.byAnchorSeq[1]!), isTrue);
    expect(
      failedProcess.summary(projection.byAnchorSeq[1]!),
      '运行失败 cat missing',
    );
    final timed = ToolActivityPresentation.from(projection.byAnchorSeq[3]!);
    expect(timed.fields['退出码'], '未知或未取得');
    expect(timed.fields['超时'], '是');
    expect(timed.fields['终止信号'], 'SIGTERM');
    expect(timed.fields['输出范围'], contains('截断'));
  });

  test(
    'an uncertain timeout stays explicit even with a successful shell exit',
    () {
      final projection = ToolActivityProjection()
        ..reconcile([
          callEvent(1),
          resultEvent(
            2,
            text: jsonEncode({
              'stdout': 'BACKGROUND_OK\n',
              'stderr': '',
              'exitCode': 0,
              'timedOut': null,
              'timeoutStatus': 'unconfirmed',
              'timeoutDiagnostic': 'GROUP_LIVENESS_UNCONFIRMED',
            }),
          ),
        ]);
      final fields = ToolActivityPresentation.from(projection.byAnchorSeq[1]!)
          .fields;
      expect(fields['退出码'], '0');
      expect(fields['超时'], startsWith('未确认'));
      expect(
        projection.byAnchorSeq[1]!.resultText,
        contains('GROUP_LIVENESS_UNCONFIRMED'),
      );
    },
  );

  test('file search metadata and unknown payloads remain available', () {
    final projection = ToolActivityProjection()
      ..reconcile([
        callEvent(1, name: 'read', args: {'file_path': '/a.txt'}),
        resultEvent(
          2,
          meta: {
            'path': '/a.txt',
            'lines': [
              {'number': 9, 'text': 'line nine'},
            ],
            'totalLines': 20,
          },
        ),
        callEvent(
          3,
          id: 'grep',
          name: 'grep',
          args: {'pattern': 'needle', 'path': '/workspace'},
        ),
        resultEvent(
          4,
          id: 'grep',
          meta: {
            'shape': 'matches',
            'files': [
              {
                'path': '/a.txt',
                'matches': [
                  {'lineNumber': 2, 'line': 'needle'},
                ],
              },
            ],
            'total': 1,
            'truncated': true,
          },
        ),
        callEvent(
          5,
          id: 'unknown',
          name: 'future_tool',
          args: {
            'opaque': {'one': 'two'},
          },
        ),
        resultEvent(
          6,
          id: 'unknown',
          text: 'unrecognized result',
          meta: {
            'future': [1, 2, 3],
          },
        ),
      ]);
    expect(
      ToolActivityPresentation.from(projection.byAnchorSeq[1]!).fields['读取内容'],
      '9: line nine',
    );
    final search = ToolActivityPresentation.from(projection.byAnchorSeq[3]!)
        .fields;
    expect(search['匹配结果'], '/a.txt\n2: needle');
    expect(search['结果范围'], contains('截断'));
    final unknown = projection.byAnchorSeq[5]!;
    expect(ToolActivityPresentation.from(unknown).kind, 'other');
    expect(unknown.rawJson, contains('unrecognized result'));
    final raw = jsonDecode(unknown.rawJson);
    expect(jsonDecode(raw['events'][0]['data']['arguments']), {
      'opaque': {'one': 'two'},
    });
    expect(unknown.rawJson, contains('"future"'));
  });
}
