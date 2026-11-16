// 远程会话洞察：`session.projections` 的 values 解析、派生读数与数据源的刷新时机。
//
// 上半部分只做纯解析（输入是探针从真实远程宿主上读到的 values 形状），下半部分用
// 假传输驱动 `RemoteConversationLiveSource`，断言「首屏 / 轮次边界 / 待办写入 /
// 重连 / 手动重试」各读一次、无关事件不读、读取失败保留上一次读数，不连宿主。

import 'dart:async';

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_session_insights.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_projection_test.dart' as fixture;
import 'support/remote_conversation_fakes.dart';

/// 真实远程宿主返回的 `values` 形状（2026-11-16 探针读取的 23 个键里的四项）。
Map<String, dynamic> insightValues({
  int turns = 20,
  int steps = 23,
  int? uncachedInputTokens = 19162,
  int? cacheReadTokens = 385792,
  int? cacheWriteTokens = 0,
  int? outputTokens = 1304,
  int? pressureTokens = 18999,
  int? projectedTokens = 19058,
  int? contextWindow = 1048576,
  List<Map<String, dynamic>>? todos,
}) => <String, dynamic>{
  'todos':
      todos ??
      <Map<String, dynamic>>[
        <String, dynamic>{'content': '检查构建', 'status': 'in_progress'},
        <String, dynamic>{'content': '跑测试', 'status': 'pending'},
        <String, dynamic>{'content': '收尾', 'status': 'completed'},
      ],
  'sessionStats': <String, dynamic>{
    'turns': turns,
    'steps': steps,
    'llmMs': 57216,
    'toolMs': 6723,
    'ttftMs': 47690,
    'ttftSteps': 23,
    'decodeMs': 9526,
    'decodeTokens': 1304,
  },
  'tokenUsage': <String, dynamic>{
    'uncachedInputTokens': ?uncachedInputTokens,
    'cacheReadTokens': ?cacheReadTokens,
    'cacheWriteTokens': ?cacheWriteTokens,
    'outputTokens': ?outputTokens,
  },
  'contextPressure': <String, dynamic>{
    'pressureTokens': ?pressureTokens,
    'projectedTokens': ?projectedTokens,
    'contextWindow': ?contextWindow,
  },
};

Map<String, dynamic> _projectionsPayload({
  int asOfSeq = 10,
  Map<String, dynamic>? values,
}) => <String, dynamic>{
  'kind': 'sequenced',
  'asOfSeq': asOfSeq,
  'values': values ?? insightValues(),
};

Map<String, dynamic> _windowPayload(List<Map<String, dynamic>> events) => {
  'events': events,
  'throughSeq': events.last['seq'] as int,
  'firstSeq': events.first['seq'] as int,
  'hasMore': false,
};

Map<String, dynamic> _catalogPayload() => <String, dynamic>{
  'groups': <Map<String, dynamic>>[],
};

/// 绑定一个真实数据源并收集它推给页面的更新。
({
  RemoteConversationLiveSource source,
  FakeRemoteTransport transport,
  FakeRemoteConnection connection,
  StreamController<Map<String, dynamic>> events,
  List<RemoteConversationUpdate> updates,
})
_attachLiveSource({Set<String>? supported}) {
  final transport = FakeRemoteTransport();
  transport.answers['session.readWindow'] = (_) => _windowPayload([
    fixture.header(0),
    fixture.input(1, '你好'),
  ]);
  transport.answers['api.subscribe'] = (params) => <String, dynamic>{
    'streamId': params['streamId'],
    'generation': 'generation-${params['streamId']}',
  };
  transport.answers['api.call'] = (params) => switch (params['method']) {
    'projections' => _projectionsPayload(),
    'modelCatalog' => _catalogPayload(),
    _ => <String, dynamic>{},
  };
  final connection = FakeRemoteConnection(
    transport: transport,
    windowAck: true,
    supported:
        supported ??
        <String>{
          remoteConversationReadMethod,
          remoteConversationSendMethod,
          remoteConversationInteractionsListMethod,
          remoteConversationApiCallMethod,
        },
  );
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final source = RemoteConversationLiveSource(
    connection: connection,
    sessionId: 's-1',
    events: events.stream,
  );
  final updates = <RemoteConversationUpdate>[];
  final subscription = source.updates.listen(updates.add);
  addTearDown(() async {
    await subscription.cancel();
    source.dispose();
    await events.close();
  });
  return (
    source: source,
    transport: transport,
    connection: connection,
    events: events,
    updates: updates,
  );
}

/// 数据源发出的 `session.projections` 读取次数。
int _projectionReads(FakeRemoteTransport transport) => transport
    .paramsOf('api.call')
    .where((params) => params['method'] == 'projections')
    .length;

/// 数据源推送的洞察更新。
List<RemoteConversationInsights> _insightUpdates(
  List<RemoteConversationUpdate> updates,
) => updates.whereType<RemoteConversationInsights>().toList();

/// 通过 `session.event` 通知注入一条会话事件（follow 不可用时的同一条路径）。
void _emitEvent(
  StreamController<Map<String, dynamic>> events,
  Map<String, dynamic> event,
) {
  events.add(<String, dynamic>{
    'method': 'session.event',
    'params': {'sessionId': 's-1', 'event': event},
  });
}

void main() {
  group('解析真实宿主的 values', () {
    test('四项读数都按宿主投影形状解析', () {
      final insights = RemoteSessionInsights.fromProjectionValues(
        insightValues(),
      );

      expect(insights.hasAny, isTrue);
      expect(insights.todos, hasLength(3));
      expect(insights.todos![0].content, '检查构建');
      expect(insights.todos![0].status, RemoteTodoStatus.inProgress);
      expect(insights.todos![1].status, RemoteTodoStatus.pending);
      expect(insights.todos![2].status, RemoteTodoStatus.completed);

      expect(insights.stats!.turns, 20);
      expect(insights.stats!.steps, 23);
      expect(insights.stats!.llmMs, 57216);
      expect(insights.stats!.toolMs, 6723);
      expect(insights.stats!.averageTtftMs, closeTo(2073.478, .001));
      expect(insights.stats!.decodeTokensPerSecond, closeTo(136.9, .1));

      expect(insights.usage!.uncachedInputTokens, 19162);
      expect(insights.usage!.cacheReadTokens, 385792);
      expect(insights.usage!.cacheWriteTokens, 0);
      expect(insights.usage!.outputTokens, 1304);
      expect(insights.usage!.billedInputTokens, 404954);
      expect(insights.usage!.totalTokens, 406258);

      expect(insights.pressure!.pressureTokens, 18999);
      expect(insights.pressure!.projectedTokens, 19058);
      expect(insights.pressure!.contextWindow, 1048576);
      expect(insights.pressure!.usedTokens, 19058);
    });

    test('values 为 null 或不是对象时是空快照，不抛异常', () {
      for (final values in <Object?>[null, 'bad', <Object?>[], 42]) {
        final insights = RemoteSessionInsights.fromProjectionValues(values);
        expect(insights.hasAny, isFalse, reason: '$values');
        expect(insights.isEmpty, isTrue);
        expect(insights.todos, isNull);
        expect(insights.stats, isNull);
        expect(insights.usage, isNull);
        expect(insights.pressure, isNull);
        expect(insights.cacheHitPercent, isNull);
        expect(insights.contextPercent, isNull);
      }
    });

    test('缺失的键不影响其它读数，也不抛异常', () {
      final insights = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{'title': '无关键', 'sessionStats': insightValues()['sessionStats']},
      );
      expect(insights.todos, isNull);
      expect(insights.usage, isNull);
      expect(insights.pressure, isNull);
      expect(insights.stats!.turns, 20);
      expect(insights.hasAny, isTrue);
    });
  });

  group('待办解析', () {
    test('null 表示没有记录，空列表表示已清空', () {
      final absent = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{'todos': null},
      );
      expect(absent.todos, isNull);

      final cleared = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{'todos': <Object?>[]},
      );
      expect(cleared.todos, isEmpty);
      expect(cleared.todos, isNotNull);
    });

    test('坏条目逐条跳过，坏类型整体为 null', () {
      final partial = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{
          'todos': <Object?>[
            <String, dynamic>{'content': '有效', 'status': 'completed'},
            'bad',
            <String, dynamic>{'content': '', 'status': 'pending'},
            <String, dynamic>{'content': '状态不认识', 'status': 'blocked'},
            <String, dynamic>{'content': 3, 'status': 'pending'},
            <String, dynamic>{'content': '有效二', 'status': 'pending'},
          ],
        },
      );
      expect(
        partial.todos!.map((item) => item.content),
        <String>['有效', '有效二'],
      );

      for (final bad in <Object?>['bad', 7, <String, dynamic>{}]) {
        final insights = RemoteSessionInsights.fromProjectionValues(
          <String, dynamic>{'todos': bad},
        );
        expect(insights.todos, isNull, reason: '$bad');
      }
    });
  });

  group('统计与用量解析', () {
    test('统计缺核心计数或类型错误时整项为 null', () {
      final missingTurns = Map<String, dynamic>.of(
        insightValues()['sessionStats'] as Map<String, dynamic>,
      )..remove('turns');
      expect(
        RemoteSessionInsights.fromProjectionValues(
          <String, dynamic>{'sessionStats': missingTurns},
        ).stats,
        isNull,
      );
      expect(
        RemoteSessionInsights.fromProjectionValues(
          <String, dynamic>{'sessionStats': <String, dynamic>{'turns': -1, 'steps': 2}},
        ).stats,
        isNull,
      );
    });

    test('时间字段坏掉时按 0 处理，不影响轮次与 step 计数', () {
      final insights = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{
          'sessionStats': <String, dynamic>{
            'turns': 3,
            'steps': 4,
            'llmMs': 'bad',
            'decodeMs': -5,
          },
        },
      );
      expect(insights.stats!.turns, 3);
      expect(insights.stats!.steps, 4);
      expect(insights.stats!.llmMs, 0);
      expect(insights.stats!.decodeMs, 0);
      expect(insights.stats!.averageTtftMs, isNull);
      expect(insights.stats!.decodeTokensPerSecond, isNull);
    });

    test('用量缺一个桶或类型错误时整项为 null（不报错误的命中率）', () {
      final usage = insightValues()['tokenUsage'] as Map<String, dynamic>;
      for (final missing in <String>[
        'uncachedInputTokens',
        'cacheReadTokens',
        'cacheWriteTokens',
        'outputTokens',
      ]) {
        final broken = Map<String, dynamic>.of(usage)..remove(missing);
        expect(
          RemoteSessionInsights.fromProjectionValues(
            <String, dynamic>{'tokenUsage': broken},
          ).usage,
          isNull,
          reason: missing,
        );
      }
      expect(
        RemoteSessionInsights.fromProjectionValues(
          <String, dynamic>{'tokenUsage': <String, dynamic>{'cacheReadTokens': 1.5}},
        ).usage,
        isNull,
      );
    });

    test('上下文三项各自可选：只有容量时读数存在但没有百分比', () {
      final capacityOnly = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{
          'contextPressure': <String, dynamic>{'contextWindow': 1000000},
        },
      );
      expect(capacityOnly.pressure, isNotNull);
      expect(capacityOnly.pressure!.contextWindow, 1000000);
      expect(capacityOnly.pressure!.usedTokens, isNull);
      expect(capacityOnly.contextPercent, isNull);

      final numbersOnly = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{
          'contextPressure': <String, dynamic>{'pressureTokens': 500},
        },
      );
      expect(numbersOnly.pressure!.contextWindow, isNull);
      expect(numbersOnly.contextPercent, isNull);

      final allBad = RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{
          'contextPressure': <String, dynamic>{
            'pressureTokens': -1,
            'projectedTokens': 'x',
            'contextWindow': 0,
          },
        },
      );
      expect(allBad.pressure, isNull);
    });
  });

  group('派生读数', () {
    RemoteSessionInsights usageInsights({
      required int uncached,
      required int cacheRead,
      required int cacheWrite,
      int output = 0,
    }) => RemoteSessionInsights.fromProjectionValues(
      <String, dynamic>{
        'tokenUsage': <String, dynamic>{
          'uncachedInputTokens': uncached,
          'cacheReadTokens': cacheRead,
          'cacheWriteTokens': cacheWrite,
          'outputTokens': output,
        },
      },
    );

    test('缓存命中率：整数百分比，部分命中不会被四舍五入成 100%', () {
      expect(
        usageInsights(uncached: 0, cacheRead: 0, cacheWrite: 0).cacheHitPercent,
        isNull,
        reason: '没有输入 token 时没有命中率',
      );
      expect(
        usageInsights(uncached: 1000, cacheRead: 0, cacheWrite: 0)
            .cacheHitPercent,
        '0',
      );
      expect(
        usageInsights(uncached: 500, cacheRead: 500, cacheWrite: 0)
            .cacheHitPercent,
        '50',
      );
      expect(
        usageInsights(uncached: 0, cacheRead: 1000, cacheWrite: 0)
            .cacheHitPercent,
        '100',
      );
      expect(
        usageInsights(uncached: 5, cacheRead: 995, cacheWrite: 0)
            .cacheHitPercent,
        '99.5',
      );
      expect(
        usageInsights(uncached: 1, cacheRead: 1999, cacheWrite: 0)
            .cacheHitPercent,
        '99.95',
      );
      expect(
        usageInsights(uncached: 2, cacheRead: 1, cacheWrite: 0)
            .cacheHitPercent,
        '33',
      );
      expect(
        usageInsights(
          uncached: 5,
          cacheRead: 995,
          cacheWrite: 0,
        ).cacheHitRatio,
        closeTo(.995, .000001),
      );
    });

    test('上下文占用：projectedTokens 优先、缺容量为 null、上限 100', () {
      int? percentFor({
        int? pressure,
        int? projected,
        int? window,
      }) => RemoteSessionInsights.fromProjectionValues(
        <String, dynamic>{
          'contextPressure': <String, dynamic>{
            'pressureTokens': ?pressure,
            'projectedTokens': ?projected,
            'contextWindow': ?window,
          },
        },
      ).contextPercent;

      expect(percentFor(pressure: 500, window: 1000), 50);
      expect(percentFor(projected: 600, pressure: 500, window: 1000), 60);
      expect(percentFor(pressure: 500), isNull);
      expect(percentFor(window: 1000), isNull);
      expect(percentFor(projected: 4000, window: 1000), 100);
      expect(percentFor(projected: 1, window: 3), 33);
      expect(percentFor(projected: 2, window: 3), 67);
    });

    test('相等性覆盖嵌套读数，用于数据源跳过没变的推送', () {
      final first = RemoteSessionInsights.fromProjectionValues(insightValues());
      final same = RemoteSessionInsights.fromProjectionValues(insightValues());
      final changed = RemoteSessionInsights.fromProjectionValues(
        insightValues(turns: 21),
      );
      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(changed));

      expect(
        RemoteSessionInsights.fromProjectionValues(
          <String, dynamic>{'todos': <Object?>[]},
        ),
        isNot(
          RemoteSessionInsights.fromProjectionValues(
            <String, dynamic>{'todos': null},
          ),
        ),
      );
    });
  });

  group('数据源的刷新时机', () {
    test('首屏读一次并推送解析后的读数，不推失败', () async {
      final live = _attachLiveSource();
      await live.source.start();
      await pumpEventQueue();

      final reads = live.transport.paramsOf('api.call').where(
        (params) => params['method'] == 'projections',
      );
      expect(reads, hasLength(1));
      expect(reads.single['namespace'], 'session');
      expect(reads.single['args'], {
        'request': {'sessionId': 's-1'},
      });

      final updates = _insightUpdates(live.updates);
      expect(updates, hasLength(1));
      expect(updates.single.insights!.stats!.turns, 20);
      expect(updates.single.insights!.usage!.cacheReadTokens, 385792);
      expect(updates.single.insights!.contextPercent, 2);
      expect(live.updates.whereType<RemoteConversationFailure>(), isEmpty);

      live.source.dispose();
      await pumpEventQueue();
    });

    test('一轮结束、下一轮开始与待办写入各读一次，无关事件不读', () async {
      final live = _attachLiveSource();
      await live.source.start();
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 1);

      // 与洞察无关的事件（助手消息、步骤结束）不触发读取。
      _emitEvent(live.events, fixture.assistant(2, '回复'));
      _emitEvent(
        live.events,
        fixture.event(3, 'step/end', <String, dynamic>{'turn': 1, 'step': 1}),
      );
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 1);

      _emitEvent(
        live.events,
        fixture.event(4, 'turn/end', <String, dynamic>{
          'turn': 1,
          'reason': <String, dynamic>{'kind': 'completed'},
        }),
      );
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 2, reason: 'turn/end 后重读');

      _emitEvent(
        live.events,
        fixture.event(5, 'todo/write', <String, dynamic>{
          'todos': <Map<String, dynamic>>[
            <String, dynamic>{'content': '继续', 'status': 'in_progress'},
          ],
        }),
      );
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 3, reason: 'todo/write 后重读');

      _emitEvent(
        live.events,
        fixture.event(6, 'turn/start', <String, dynamic>{'turn': 2}),
      );
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 4, reason: '新轮次开始后重读');

      live.source.dispose();
      await pumpEventQueue();
    });

    test('同一时刻只跑一次读取：在途期间的触发合并成一次补读', () async {
      final live = _attachLiveSource();
      var reads = 0;
      Completer<Object?>? hold;
      live.transport.answers['api.call'] = (params) {
        if (params['method'] != 'projections') {
          return <String, dynamic>{};
        }
        reads++;
        final gate = hold;
        if (gate != null) return gate.future;
        return _projectionsPayload(
          asOfSeq: reads,
          values: insightValues(turns: reads),
        );
      };

      await live.source.start();
      await pumpEventQueue();
      expect(reads, 1);

      // 第一次触发开始读取并在途；后续相关事件只记一个补读标记。
      hold = Completer<Object?>();
      _emitEvent(
        live.events,
        fixture.event(2, 'turn/end', <String, dynamic>{'turn': 1}),
      );
      _emitEvent(
        live.events,
        fixture.event(3, 'todo/write', <String, dynamic>{
          'todos': <Map<String, dynamic>>[],
        }),
      );
      _emitEvent(
        live.events,
        fixture.event(4, 'turn/start', <String, dynamic>{'turn': 2}),
      );
      await pumpEventQueue();
      expect(reads, 2, reason: '在途读取不会重复发请求');

      hold.complete(_projectionsPayload());
      hold = null;
      await pumpEventQueue();
      await pumpEventQueue();
      expect(reads, 3, reason: '合并的触发在读完后补读一次');
      final updates = _insightUpdates(live.updates);
      expect(updates.last.insights!.stats!.turns, 3);

      live.source.dispose();
      await pumpEventQueue();
    });

    test('重连与手动重试都重读一次', () async {
      final live = _attachLiveSource();
      await live.source.start();
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 1);

      live.connection.setPhase(RemoteConnectionPhase.reconnecting);
      await pumpEventQueue();
      live.connection.setPhase(RemoteConnectionPhase.ready);
      await pumpEventQueue();
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 2, reason: '重连后重读洞察');

      await live.source.reload();
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 3, reason: '页面重试后重读洞察');

      live.source.dispose();
      await pumpEventQueue();
    });

    test('读取失败保留上一次读数，不升级成页面错误；恢复后继续更新', () async {
      final live = _attachLiveSource();
      var reads = 0;
      live.transport.answers['api.call'] = (params) {
        if (params['method'] != 'projections') {
          return <String, dynamic>{};
        }
        reads++;
        if (reads == 2) {
          throw const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '与电脑的连接已断开，正在重连…',
          );
        }
        return _projectionsPayload(
          asOfSeq: reads,
          values: insightValues(turns: reads),
        );
      };

      await live.source.start();
      await pumpEventQueue();
      expect(_insightUpdates(live.updates).single.insights!.stats!.turns, 1);

      _emitEvent(
        live.events,
        fixture.event(2, 'turn/end', <String, dynamic>{'turn': 1}),
      );
      await pumpEventQueue();
      expect(_insightUpdates(live.updates), hasLength(1), reason: '失败不推送空读数');
      expect(
        live.updates.whereType<RemoteConversationFailure>(),
        isEmpty,
        reason: '洞察读取失败不打断会话',
      );

      _emitEvent(
        live.events,
        fixture.event(3, 'turn/start', <String, dynamic>{'turn': 2}),
      );
      await pumpEventQueue();
      expect(_insightUpdates(live.updates).last.insights!.stats!.turns, 3);
      expect(reads, 3);

      live.source.dispose();
      await pumpEventQueue();
    });

    test('读数没变时不重复推送', () async {
      final live = _attachLiveSource();
      await live.source.start();
      await pumpEventQueue();
      expect(_insightUpdates(live.updates), hasLength(1));

      _emitEvent(
        live.events,
        fixture.event(2, 'turn/end', <String, dynamic>{'turn': 1}),
      );
      await pumpEventQueue();
      expect(_projectionReads(live.transport), 2, reason: '确实重读了');
      expect(_insightUpdates(live.updates), hasLength(1), reason: '内容没变不推');

      live.source.dispose();
      await pumpEventQueue();
    });

    test('宿主没有 api.call 时不读也不推洞察', () async {
      final live = _attachLiveSource(
        supported: <String>{remoteConversationReadMethod},
      );
      await live.source.start();
      await pumpEventQueue();

      expect(_projectionReads(live.transport), 0);
      expect(_insightUpdates(live.updates), isEmpty);
      expect(live.updates.whereType<RemoteConversationFailure>(), isEmpty);

      live.source.dispose();
      await pumpEventQueue();
    });
  });
}
