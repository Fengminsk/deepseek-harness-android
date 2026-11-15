// B2：远程会话页的方案模式。
//
// 两部分：
// 1. `RemoteGoalPlanController` 的状态机（投影四态、控制流增量、写失败降级、
//    重连重读），用假数据源驱动；
// 2. 真实数据源（`RemoteConversationLiveSource`）的线上契约：`session.projections`
//    / `session.control` / `session.command '/plan'` / `interactions.dismiss` 的
//    参数与投影，以及计划审核问题对象的 `intent` 透传。
//
// 都不连宿主、不拨号；页面级用例（计划条、审核卡片）在
// `remote_conversation_page_test.dart`。

import 'dart:async';

import 'package:dsh_android/approvals_draft.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_goal_plan.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_conversation_fakes.dart';

Map<String, dynamic> _windowPayload(List<Map<String, dynamic>> events) => {
  'events': events,
  'throughSeq': events.isEmpty ? 0 : events.last['seq'] as int,
  'firstSeq': events.isEmpty ? null : events.first['seq'] as int,
  'hasMore': false,
};

Map<String, dynamic> _projections({
  Map<String, dynamic>? plan,
  int asOfSeq = 1,
}) => <String, dynamic>{
  'kind': 'sequenced',
  'asOfSeq': asOfSeq,
  'values': <String, dynamic>{'plan': ?plan},
};

Map<String, dynamic> _plan({required bool active, required bool pending}) =>
    <String, dynamic>{'active': active, 'pending': pending};

Map<String, dynamic> _item(
  String streamId,
  String generation,
  int sequence,
  Object? value,
) => <String, dynamic>{
  'method': 'api.stream',
  'params': <String, dynamic>{
    'streamId': streamId,
    'generation': generation,
    'sequence': sequence,
    'type': 'item',
    'value': value,
  },
};

/// 构造一个已就绪、可记录投影读与计划写入的假数据源。
FakeRemoteConversationSource _source({
  Map<String, dynamic>? projections,
  RemoteConnectionPhase phase = RemoteConnectionPhase.ready,
}) => FakeRemoteConversationSource(phase: phase)..projections = projections;

RemoteGoalPlanController _controller(FakeRemoteConversationSource source) {
  final controller = RemoteGoalPlanController(source: source);
  addTearDown(controller.dispose);
  return controller;
}

/// 绑定真实数据源，返回它推给页面的更新与外部事件入口。
({
  RemoteConversationLiveSource source,
  List<RemoteConversationUpdate> updates,
  StreamController<Map<String, dynamic>> events,
})
_attachLive(FakeRemoteTransport transport, {Set<String>? supported}) {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final source = RemoteConversationLiveSource(
    connection: FakeRemoteConnection(
      transport: transport,
      supported:
          supported ??
          <String>{
            remoteConversationReadMethod,
            remoteConversationSendMethod,
            remoteConversationCommandMethod,
            remoteConversationInteractionsListMethod,
            remoteConversationApiCallMethod,
          },
    ),
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
  return (source: source, updates: updates, events: events);
}

void main() {
  // ---------------------------------------------------------------- 控制器

  test('未连接时不读投影，计划条保持隐藏', () async {
    final source = _source(phase: RemoteConnectionPhase.connecting);
    final controller = _controller(source);
    await controller.start();

    expect(source.projectionReads, 0, reason: '未连接不发请求');
    expect(controller.plan, isNull);
    expect(controller.error, isNull, reason: '不显示一个无法确认的状态条');

    source.setPhase(RemoteConnectionPhase.ready);
    await pumpEventQueue();

    expect(source.projectionReads, 1);
    expect(controller.fresh, isTrue);
    expect(controller.plan, isNull, reason: '没有 plan 投影时不编一个默认状态');
  });

  test('投影四态组合算出计划条的目标状态', () async {
    for (final (active, pending, target) in <(bool, bool, bool)>[
      (false, false, false),
      (true, false, true),
      (false, true, true),
      (true, true, false),
    ]) {
      final source = _source(
        projections: _projections(
          plan: _plan(active: active, pending: pending),
        ),
      );
      final controller = _controller(source);
      await controller.start();
      expect(controller.plan?.active, active);
      expect(controller.plan?.pending, pending);
      expect(controller.plan?.target, target);
    }
  });

  test('session.projections 失败给出可重试说明，重试后恢复', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: true, pending: false)),
    );
    source.projectionsFailure = const RuntimeTransportFailure(
      code: 'gateway/unavailable',
      message: '连接中断',
    );
    final controller = _controller(source);
    await controller.start();

    expect(controller.fresh, isFalse);
    expect(controller.error, contains('无法确认计划模式状态'));
    expect(controller.canMutate, isFalse);

    source.projectionsFailure = null;
    await controller.refresh();

    expect(controller.error, isNull);
    expect(controller.fresh, isTrue);
    expect(controller.plan?.target, isTrue);
  });

  test('setPlan 写 /plan 与 /plan off 并重读权威状态', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: false, pending: false)),
    );
    final controller = _controller(source);
    await controller.start();
    expect(controller.canMutate, isTrue);

    source.projections = _projections(
      plan: _plan(active: false, pending: true),
      asOfSeq: 2,
    );
    expect(await controller.setPlan(true), isTrue);
    expect(source.planCommands, <bool>[true]);
    expect(source.ensureCalls, greaterThanOrEqualTo(1), reason: '先恢复会话再写');
    expect(controller.plan?.pending, isTrue);
    expect(controller.busy, isFalse);

    source.projections = _projections(
      plan: _plan(active: false, pending: false),
      asOfSeq: 3,
    );
    expect(await controller.setPlan(false), isTrue);
    expect(source.planCommands, <bool>[true, false]);
  });

  test('setPlan 失败保留原文说明且不自动重放', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: true, pending: false)),
    );
    source.planFailure = const RuntimeTransportFailure(
      code: 'gateway/unavailable',
      message: '连接已断开，请重试。',
    );
    final controller = _controller(source);
    await controller.start();

    expect(await controller.setPlan(false), isFalse);
    expect(source.planCommands, <bool>[false], reason: '未确认的写不重放');
    expect(controller.actionKind, 'plan');
    expect(controller.actionError, contains('操作未确认'));
    expect(controller.actionError, contains('连接已断开，请重试。'));
    expect(controller.busy, isFalse);
  });

  test('session.control 的 plan 投影增量更新状态', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: false, pending: false)),
    );
    final controller = _controller(source);
    await controller.start();
    expect(controller.plan?.target, isFalse);

    source.emitControl(<String, dynamic>{
      'type': 'item',
      'value': <String, dynamic>{
        'type': 'projection',
        'sessionId': 's-1',
        'seq': 5,
        'key': 'plan',
        'value': _plan(active: true, pending: false),
      },
    });
    await pumpEventQueue();

    expect(controller.plan?.active, isTrue);
    expect(controller.plan?.target, isTrue);
    expect(controller.error, isNull);
  });

  test('控制流的基线快照同样能建立计划状态', () async {
    final source = _source();
    final controller = _controller(source);
    await controller.start();
    expect(controller.fresh, isTrue, reason: '空投影也算确认过');

    source.emitControl(<String, dynamic>{
      'type': 'item',
      'value': <String, dynamic>{
        'type': 'baseline',
        'value': <String, dynamic>{
          'projections': <String, dynamic>{
            's-1': _projections(
              plan: _plan(active: true, pending: false),
              asOfSeq: 7,
            ),
          },
        },
      },
    });
    await pumpEventQueue();

    expect(controller.plan?.target, isTrue);
  });

  test('重连后收起计划条并重读投影', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: true, pending: false)),
    );
    final controller = _controller(source);
    await controller.start();
    expect(controller.plan?.target, isTrue);
    final reads = source.projectionReads;

    source.setPhase(RemoteConnectionPhase.reconnecting);
    await pumpEventQueue();
    expect(controller.plan, isNull, reason: '未连接时条不显示');
    expect(controller.error, isNull);

    source.setPhase(RemoteConnectionPhase.ready);
    await pumpEventQueue();
    expect(source.projectionReads, greaterThan(reads), reason: '重连后重读');
    expect(controller.plan?.target, isTrue);
  });

  // -------------------------------------------------------- 真实数据源契约

  test('readProjections 走 api.call 的 session.projections', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([]);
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['api.call'] = (params) {
      expect(params['namespace'], remoteConversationPlanNamespace);
      expect(params['method'], remoteConversationProjectionsMethod);
      return _projections(plan: _plan(active: true, pending: false));
    };
    final live = _attachLive(transport);

    await live.source.start();
    await pumpEventQueue();
    final value = await live.source.readProjections();

    expect(value?['kind'], 'sequenced');
    final request = transport.paramsOf('api.call').last;
    expect(request['args'], {
      'request': {'sessionId': 's-1'},
    });
  });

  test('watchSessionControl 用 session/control 订阅并交付增量帧', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([]);
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    final live = _attachLive(transport);
    await live.source.start();
    await pumpEventQueue();

    final frames = <Map<String, dynamic>>[];
    final subscription = live.source.watchSessionControl().listen(frames.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();

    final subscribe = transport
        .paramsOf('api.subscribe')
        .firstWhere(
          (params) => params['method'] == remoteConversationControlMethod,
        );
    expect(subscribe['namespace'], remoteConversationControlNamespace);
    expect(subscribe['args'], isEmpty);

    final streamId = subscribe['streamId'] as String;
    live.events.add(
      _item(streamId, 'generation-$streamId', 1, <String, dynamic>{
        'type': 'projection',
        'sessionId': 's-1',
        'seq': 3,
        'key': 'plan',
        'value': _plan(active: true, pending: true),
      }),
    );
    await pumpEventQueue();

    final items = frames.where((frame) => frame['type'] == 'item').toList();
    expect(items, hasLength(1), reason: '订阅先发 opening，再交付 item 帧');
    expect(items.single['value']['key'], 'plan');
  });

  test('submitPlan 用 session.command 发送 /plan 与 /plan off', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([]);
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['session.ensure'] = (_) => <String, dynamic>{
      'sessionId': 's-1',
      'created': false,
    };
    transport.answers['session.command'] = (_) => <String, dynamic>{
      'commandId': 'command-1',
      'result': <String, dynamic>{'kind': 'success', 'text': '已进入计划模式'},
    };
    final live = _attachLive(transport);
    await live.source.start();
    await pumpEventQueue();

    await live.source.submitPlan(true);
    await live.source.submitPlan(false);

    final commands = transport.paramsOf('session.command');
    expect(commands, hasLength(2));
    expect(commands[0]['line'], '/plan');
    expect(commands[1]['line'], '/plan off');
    expect(commands[0]['sessionId'], 's-1');
    expect(commands[0]['attachmentIds'], isEmpty);
  });

  test('submitPlan 把宿主的失败结果转成可展示的 StateError', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([]);
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['session.command'] = (_) => <String, dynamic>{
      'commandId': 'command-1',
      'result': <String, dynamic>{'kind': 'error', 'text': '当前不能退出计划模式'},
    };
    final live = _attachLive(transport);
    await live.source.start();
    await pumpEventQueue();

    await expectLater(
      live.source.submitPlan(false),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('当前不能退出计划模式'),
        ),
      ),
    );

    transport.answers['session.command'] = (_) => null;
    await expectLater(
      live.source.submitPlan(true),
      throwsA(isA<StateError>()),
      reason: '电脑没有识别出这条指令',
    );
  });

  test('dismissInteraction 走 interactions.dismiss', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([]);
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['interactions.dismiss'] = (_) => <String, dynamic>{
      'accepted': true,
      'requestStillPending': true,
    };
    final live = _attachLive(transport);
    await live.source.start();
    await pumpEventQueue();

    final reply = await live.source.dismissInteraction('i-q', 2);

    expect(reply.accepted, isTrue);
    expect(reply.requestStillPending, isTrue);
    expect(transport.paramsOf('interactions.dismiss').single, {
      'id': 'i-q',
      'version': 2,
    });
  });

  test('计划审核问题保留 intent，可直接喂给 planReviewOf', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([]);
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['interactions.list'] = (_) => <String, dynamic>{
      'revision': 1,
      'requests': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'i-plan',
          'version': 3,
          'sessionId': 's-1',
          'kind': 'question',
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'plan-q',
              'question': '是否按这份计划执行？',
              'detail': '# 迁移到新接口\n\n先改数据源，再改页面。',
              'multiSelect': false,
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'label': '批准'},
                <String, dynamic>{'label': '继续修改'},
              ],
              'intent': <String, dynamic>{
                'kind': 'plan-review',
                'approve': '批准',
              },
            },
          ],
        },
      ],
    };
    final live = _attachLive(transport);
    await live.source.start();
    await pumpEventQueue();

    final interactions = live.updates
        .whereType<RemoteConversationInteractions>()
        .last;
    final question = interactions.requests.single.questions.single;
    expect(question.intent?['kind'], 'plan-review');
    expect(question.detail, contains('迁移到新接口'));
    expect(question.toJson()['detail'], question.detail);
    expect(question.toJson()['intent'], question.intent);

    final review = planReviewOf(<QuestionAnswerDraft>[
      QuestionAnswerDraft(question.toJson()),
    ]);
    expect(review, isNotNull);
    expect(review!.id, 'plan-q');
    expect(review.approve, '批准');
    expect(review.plan, contains('迁移到新接口'));
    final preview = planReviewPreview(review.plan);
    expect(preview.title, '迁移到新接口');
    expect(preview.summary, isNotEmpty);
  });
}
