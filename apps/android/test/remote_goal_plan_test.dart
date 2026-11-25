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
// 显式断言「未就绪重试定时器已取消、没有 pending timer」需要 fake_async；它由
// flutter_test 传递引入（pubspec.lock 已锁定），本轮不改 pubspec，所以直接导入。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
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

/// 宿主还没给出可用快照时的真实应答：旧格式会话的迁移提示（没有 asOfSeq）。
Map<String, dynamic> _notReadyProjections() => <String, dynamic>{
  'kind': 'migration-required',
  'values': <String, dynamic>{},
};

/// 控制流基线里的会话块：宿主 `SessionProjectionBaseline`，只有 asOfSeq/values。
Map<String, dynamic> _controlBaselineBlock({
  Map<String, dynamic>? plan,
  int asOfSeq = 1,
}) => <String, dynamic>{
  'asOfSeq': asOfSeq,
  'values': <String, dynamic>{'plan': ?plan},
};

/// 控制流的第一帧：`{type:'item', value:{type:'baseline', value:{projections:{…}}}}`。
Map<String, dynamic> _controlBaselineFrame(Map<String, dynamic> block) =>
    <String, dynamic>{
      'type': 'item',
      'value': <String, dynamic>{
        'type': 'baseline',
        'value': <String, dynamic>{
          'projections': <String, dynamic>{'s-1': block},
        },
      },
    };

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

  test('控制流订阅满额时以投影重读确认计划状态', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: true, pending: false)),
    );
    final controller = _controller(source);
    await controller.start();
    expect(controller.fresh, isTrue);
    source.projections = _projections(
      plan: _plan(active: false, pending: true),
      asOfSeq: 2,
    );
    source.emitControlError(
      const RuntimeTransportFailure(
        code: 'gateway/internal',
        message:
            'App stream limit reached; close an unused page before subscribing',
      ),
    );
    await pumpEventQueue();
    expect(source.projectionReads, 2);
    expect(controller.error, isNull);
    expect(controller.fresh, isTrue);
    expect(controller.plan?.pending, isTrue);
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

  test('控制流结束不当作状态不可信，并静默重订阅', () async {
    final source = _source(
      projections: _projections(plan: _plan(active: true, pending: false)),
    );
    final controller = _controller(source);
    await controller.start();
    expect(controller.plan?.target, isTrue);

    // 连接重建会退役旧订阅：流结束是正常生命周期，不是「状态不可信」。
    await source.closeControl();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(controller.error, isNull);
    expect(controller.plan?.target, isTrue, reason: '保留最后一次已知投影');
  });

  test('控制流基线的会话块（没有 kind）建立计划状态且不报错', () async {
    final source = _source();
    final controller = _controller(source);
    await controller.start();
    expect(controller.fresh, isTrue);

    // 宿主控制流基线的每个会话是 `{asOfSeq, values}`；它和
    // `session.projections` 的 `{kind:'sequenced', …}` 是同一份已排序快照，
    // 缺 kind 不能被当成「读失败」而弹常驻错误条（真机 p8 的误报）。
    source.emitControl(
      _controlBaselineFrame(
        _controlBaselineBlock(
          plan: _plan(active: true, pending: false),
          asOfSeq: 7,
        ),
      ),
    );
    await pumpEventQueue();

    expect(controller.error, isNull);
    expect(controller.fresh, isTrue);
    expect(controller.plan?.active, isTrue);
    expect(controller.plan?.target, isTrue);
    expect(source.projectionReads, 1, reason: '基线已建立状态，不再额外读投影');
  });

  test('非 sequenced 快照不产生错误，有限重试后静默降级', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();

      expect(source.projectionReads, 1);
      expect(controller.error, isNull, reason: '快照未就绪不是失败，不显示错误条');
      expect(controller.fresh, isFalse);
      expect(controller.plan, isNull);
      expect(controller.canMutate, isFalse);
      expect(async.pendingTimers, hasLength(1), reason: '一次未就绪只排一个重试');

      // 300/600/1200 ms 各重读一次；每次仍未就绪继续排下一个。
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();
      expect(source.projectionReads, 2);
      async.elapse(const Duration(milliseconds: 600));
      async.flushMicrotasks();
      expect(source.projectionReads, 3);
      async.elapse(const Duration(milliseconds: 1200));
      async.flushMicrotasks();
      expect(source.projectionReads, 4);

      // 预算用尽：静默停在「计划状态不可用」，不报错也不再请求。
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(source.projectionReads, 4);
      expect(controller.error, isNull);
      expect(controller.fresh, isFalse);
      expect(controller.plan, isNull);
      expect(async.pendingTimers, isEmpty);

      controller.dispose();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty, reason: 'dispose 后没有残留定时器');
    });
  });

  test('sequenced 快照缺 values 也按未就绪处理，不报错', () {
    fakeAsync((async) {
      final source = _source(
        projections: <String, dynamic>{'kind': 'sequenced', 'asOfSeq': 1},
      );
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();

      expect(controller.error, isNull);
      expect(controller.fresh, isFalse);
      expect(controller.plan, isNull);
      expect(async.pendingTimers, hasLength(1));
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('未就绪后恢复为 sequenced 快照即恢复计划状态', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(controller.fresh, isFalse);
      expect(controller.error, isNull);

      source.projections = _projections(
        plan: _plan(active: false, pending: true),
        asOfSeq: 4,
      );
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();

      expect(controller.fresh, isTrue);
      expect(controller.error, isNull);
      expect(controller.plan?.pending, isTrue);
      expect(controller.plan?.target, isTrue);
      expect(controller.canMutate, isTrue, reason: '快照恢复后可以写');
      expect(async.pendingTimers, isEmpty);
      controller.dispose();
    });
  });

  test('未就绪重试期间的真实读失败仍然可见，恢复后清除', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));

      source.projectionsFailure = const RuntimeTransportFailure(
        code: 'gateway/unavailable',
        message: '连接中断',
      );
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();

      expect(controller.error, contains('无法确认计划模式状态'));
      expect(controller.error, contains('连接中断'));
      expect(controller.fresh, isFalse);
      expect(controller.canMutate, isFalse);
      expect(async.pendingTimers, isEmpty, reason: '真失败不再排未就绪重试');
      async.elapse(const Duration(seconds: 10));
      expect(source.projectionReads, 2);

      source.projectionsFailure = null;
      source.projections = _projections(
        plan: _plan(active: true, pending: false),
        asOfSeq: 2,
      );
      unawaited(controller.refresh());
      async.flushMicrotasks();
      expect(controller.error, isNull);
      expect(controller.plan?.target, isTrue);
      controller.dispose();
    });
  });

  test('断连取消未就绪重试，重连后重读', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));

      source.setPhase(RemoteConnectionPhase.reconnecting);
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty, reason: '断连必须取消重试定时器');
      async.elapse(const Duration(seconds: 10));
      expect(source.projectionReads, 1, reason: '断开期间不再读');

      source.projections = _projections(
        plan: _plan(active: true, pending: false),
      );
      source.setPhase(RemoteConnectionPhase.ready);
      async.flushMicrotasks();
      expect(source.projectionReads, 2, reason: '重连后重读');
      expect(controller.plan?.target, isTrue);
      controller.dispose();
    });
  });

  test('控制流 opening 帧取消未就绪重试', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));

      source.emitControl(<String, dynamic>{'type': 'opening'});
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 10));
      expect(source.projectionReads, 1);
      controller.dispose();
    });
  });

  test('dispose 取消未就绪重试，fakeAsync 断言没有 Timer 泄漏', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));

      controller.dispose();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 10));
      expect(source.projectionReads, 1);
    });
  });

  test('显式 refresh 取代已排队重试且不重复排计时器', () {
    fakeAsync((async) {
      final source = _source(projections: _notReadyProjections());
      final controller = RemoteGoalPlanController(source: source);
      unawaited(controller.start());
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));

      unawaited(controller.refresh());
      async.flushMicrotasks();
      expect(source.projectionReads, 2);
      expect(async.pendingTimers, hasLength(1), reason: '不重复排计时器');

      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();
      expect(source.projectionReads, 3);
      controller.dispose();
      async.flushMicrotasks();
    });
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
      'sessionId': 's-1',
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
