import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/chat_goal.dart';
import 'package:dsh_android/chat_goal_plan_state.dart';
import 'package:dsh_android/chat_plan.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json goalValue({
  String id = 'g1',
  int revision = 1,
  String objective = '原目标',
  String phase = 'active',
}) => {
  'goal': {
    'id': id,
    'revision': revision,
    'objective': objective,
    'phase': phase,
    'maxGoalRounds': 256,
  },
  'roundsStarted': 3,
  'createdAt': 1,
  'updatedAt': 2,
};
Json baseline(
  Json? goal, {
  int seq = 8,
  bool active = false,
  bool pending = false,
}) => {
  'kind': 'sequenced',
  'asOfSeq': seq,
  'values': {
    'goal': goal,
    'plan': {'active': active, 'pending': pending},
  },
};

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  final control = StreamController<Json>.broadcast(sync: true);
  final remote = StreamController<Json>.broadcast(sync: true);
  final calls = <(String, Json)>[];
  final ensured = <String>[];
  int generation = 0;
  Json? projection = baseline(goalValue());
  Json? live = {...goalValue()['goal'], 'activation': 'disarmed'};
  Future<dynamic> Function()? read;
  Future<dynamic> Function(String, Json)? mutate;
  Future<Json> Function()? ensure;
  Future<dynamic> Function()? activationRead;
  @override
  int get connectionGeneration => generation;
  @override
  Stream<Json> get remoteEvents => remote.stream;
  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) => control.stream;
  @override
  Future<Json> ensureSession(String id) async {
    ensured.add(id);
    if (ensure != null) return ensure!();
    return {'sessionId': id};
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, params));
    if (method == 'session.command') {
      return mutate == null
          ? {
              'result': {'kind': 'success'},
            }
          : mutate!(method, params);
    }
    if (params['namespace'] == 'session') {
      return read == null ? projection : read!();
    }
    if (params['method'] == 'get') {
      return activationRead == null ? live : activationRead!();
    }
    return mutate == null
        ? {
            'ref': {'id': 'g1', 'revision': 2},
          }
        : mutate!(params['method'] as String, params['args'] as Json);
  }

  void replaceConnection() {
    generation++;
    statuses.clear();
    notifyListeners();
  }

  void attach() {
    statuses['session'] = 'idle';
    notifyListeners();
  }

  void projected(Json value, {String key = 'goal', int seq = 9}) =>
      control.add({
        'type': 'item',
        'value': {
          'type': 'projection',
          'sessionId': 'session',
          'key': key,
          'value': value,
          'seq': seq,
        },
      });
  Future<void> closeTest() async {
    dispose();
    await control.close();
    await remote.close();
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

Json event(int seq, String type, Json data) => {
  'seq': seq,
  'type': type,
  'data': data,
};
Json submitted(int seq, String id, String text, {String type = 'tool/call'}) =>
    event(seq, type, {
      'name': 'exit_plan_mode',
      type == 'tool/call' ? 'callId' : 'subCallId': id,
      'arguments': type == 'tool/call'
          ? jsonEncode({'plan': text})
          : {'plan': text},
    });

void main() {
  test('draft Session remains read-only until explicit goal creation or bare plan selection', () async {
    final runtime = _Runtime()..projection = null;
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    expect(runtime.ensured, isEmpty);
    expect(state.goalAvailable, isFalse);
    expect(state.plan, isNull);
    expect(await state.create('pause'), isTrue);
    final request = runtime.calls
        .singleWhere((call) => call.$2['method'] == 'create')
        .$2['args'];
    expect(request['request'], {'objective': 'pause'});
    expect(await state.setPlan(true), isTrue);
    expect(
      runtime.calls
          .lastWhere((call) => call.$1 == 'session.command')
          .$2['line'],
      '/plan',
    );
    // /plan on would send the text "on" to the Agent rather than only select mode.
    expect(runtime.ensured, ['session', 'session']);
    state.dispose();
    await runtime.closeTest();
  });

  test('new goal forwards an explicit round cap through the original create request', () async {
    final runtime = _Runtime()..projection = null;
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    expect(await state.create('分阶段完成', maxGoalRounds: 12), isTrue);
    final request = runtime.calls
        .singleWhere((call) => call.$2['method'] == 'create')
        .$2['args'];
    expect(request['request'], {'objective': '分阶段完成', 'maxGoalRounds': 12});
    expect(runtime.ensured, ['session']);
    state.dispose();
    await runtime.closeTest();
  });

  test('clear confirmation uses captured identity even when a newer goal replaces it', () async {
    final runtime = _Runtime();
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    final captured = state.goal!;
    runtime.projected(goalValue(id: 'replacement'), seq: 15);
    runtime.mutate = (method, args) async {
      expect(method, 'clear');
      expect(args['ref'], captured.ref);
      throw PlatformException(code: 'GOAL_STALE_REVISION');
    };
    expect(await state.clear(captured), isFalse);
    expect(state.goal!.id, 'replacement');
    state.dispose();
    await runtime.closeTest();
  });

  test('disposal while mutation is in flight does not replay or publish a late success', () async {
    final runtime = _Runtime();
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    final wait = Completer<dynamic>();
    runtime.mutate = (_, _) => wait.future;
    final operation = state.pause();
    await flush();
    state.dispose();
    wait.complete({'id': 'g1', 'revision': 2});
    expect(await operation, isFalse);
    expect(
      runtime.calls.where((call) => call.$2['method'] == 'pause').length,
      1,
    );
    await runtime.closeTest();
  });

  test('cold goal and plan reads never activate or resume an Agent', () async {
    final runtime = _Runtime();
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    expect(state.goal!.objective, '原目标');
    expect(state.fresh, isTrue);
    expect(state.activation, isNull);
    expect(state.canResume, isTrue);
    expect(runtime.ensured, isEmpty);
    expect(
      runtime.calls.where((call) => call.$2['namespace'] == 'goals'),
      isEmpty,
    );
    state.dispose();
    await runtime.closeTest();
  });

  test(
    'a restored durable active goal stays disarmed until explicit resume',
    () async {
      final runtime = _Runtime()..statuses['session'] = 'idle';
      runtime.live = {...goalValue()['goal'], 'activation': 'disarmed'};
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      await state.start();
      expect(state.goal!.phase, 'active');
      expect(state.activation, 'disarmed');
      expect(state.canPause, isFalse);
      expect(state.canResume, isTrue);
      expect(runtime.ensured, isEmpty);
      runtime.mutate = (method, args) async {
        expect(method, 'resume');
        expect(args['ref'], {'id': 'g1', 'revision': 1});
        return {...goalValue()['goal'], 'revision': 2, 'activation': 'armed'};
      };
      expect(await state.resume(), isTrue);
      expect(runtime.ensured, ['session']);
      expect(
        runtime.calls.where((call) => call.$2['method'] == 'resume').length,
        1,
      );
      state.dispose();
      await runtime.closeTest();
    },
  );

  test(
    'live activation event supersedes a delayed get and matches exact revision',
    () async {
      final runtime = _Runtime()..statuses['session'] = 'idle';
      final read = Completer<dynamic>();
      runtime.activationRead = () => read.future;
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      final starting = state.start();
      await flush();
      runtime.remote.add({
        'event': 'goal/activation-changed',
        'args': [
          {
            'sessionId': 'session',
            'goal': {'id': 'g1', 'revision': 1, 'activation': 'armed'},
          },
        ],
      });
      read.complete({'id': 'g1', 'revision': 1, 'activation': 'disarmed'});
      await starting;
      expect(state.activation, 'armed');
      expect(state.canPause, isTrue);
      runtime.projected(goalValue(revision: 2));
      expect(state.activation, isNull);
      await flush();
      expect(state.activation, isNull);
      state.dispose();
      await runtime.closeTest();
    },
  );

  test(
    'a cleared or mismatched live activation event withdraws stale armed state',
    () async {
      final runtime = _Runtime()..statuses['session'] = 'idle';
      runtime.live = {...goalValue()['goal'], 'activation': 'armed'};
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      await state.start();
      expect(state.canPause, isTrue);
      runtime.remote.add({
        'event': 'goal/activation-changed',
        'args': [
          {'sessionId': 'session'},
        ],
      });
      expect(state.activation, isNull);
      expect(state.canPause, isFalse);
      runtime.remote.add({
        'event': 'goal/activation-changed',
        'args': [
          {
            'sessionId': 'session',
            'goal': {'id': 'g1', 'revision': 1, 'activation': 'armed'},
          },
        ],
      });
      expect(state.canPause, isTrue);
      runtime.remote.add({
        'event': 'goal/activation-changed',
        'args': [
          {
            'sessionId': 'session',
            'goal': {'id': 'g1', 'revision': 2, 'activation': 'armed'},
          },
        ],
      });
      expect(state.activation, isNull);
      expect(state.canPause, isFalse);
      state.dispose();
      await runtime.closeTest();
    },
  );

  test(
    'a newer sequenced projection cannot be overwritten by a late read',
    () async {
      final runtime = _Runtime();
      final pending = Completer<dynamic>();
      runtime.read = () => pending.future;
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      final starting = state.start();
      runtime.projected(goalValue(revision: 2, objective: '新目标'), seq: 12);
      pending.complete(baseline(goalValue(), seq: 8));
      await starting;
      expect(state.goal!.revision, 2);
      expect(state.goal!.objective, '新目标');
      state.dispose();
      await runtime.closeTest();
    },
  );

  test('connection replacement and disposal withdraw authority and ignore late reads', () async {
    final runtime = _Runtime()..statuses['session'] = 'idle';
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    final late = Completer<dynamic>();
    runtime.read = () => late.future;
    final pending = state.refresh();
    runtime.replaceConnection();
    expect(state.activation, isNull);
    expect(state.canMutate, isFalse);
    state.dispose();
    late.complete(baseline(goalValue(revision: 4)));
    await pending;
    expect(state.goal!.revision, 1);
    expect(state.alive, isFalse);
    expect(await state.resume(), isFalse);
    await runtime.closeTest();
  });

  test(
    'an edit sends the captured CAS ref and a conflict never resubmits',
    () async {
      final runtime = _Runtime();
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      await state.start();
      final captured = state.goal!;
      runtime.projection = baseline(
        goalValue(revision: 2, objective: 'Web 已修改'),
        seq: 12,
      );
      runtime.projected(goalValue(revision: 2, objective: 'Web 已修改'), seq: 12);
      runtime.mutate = (method, args) async {
        expect(method, 'edit');
        expect(args['ref'], {'id': 'g1', 'revision': 1});
        expect(args['request']['objective'], '我的草稿');
        throw PlatformException(
          code: 'GOAL_STALE_REVISION',
          message: 'changed',
        );
      };
      expect(
        await state.edit(captured, objective: '我的草稿', maxGoalRounds: 300),
        isFalse,
      );
      expect(state.goal!.objective, 'Web 已修改');
      expect(state.actionError, contains('编辑内容会保留'));
      expect(
        runtime.calls.where((call) => call.$2['method'] == 'edit').length,
        1,
      );
      state.dispose();
      await runtime.closeTest();
    },
  );

  test('rapid mutations have one admission and reconnect before ensure prevents write', () async {
    final runtime = _Runtime();
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    final wait = Completer<Json>();
    runtime.ensure = () => wait.future;
    final first = state.resume();
    expect(await state.resume(), isFalse);
    runtime.replaceConnection();
    wait.complete({'sessionId': 'session'});
    expect(await first, isFalse);
    expect(
      runtime.calls.where((call) => call.$2['method'] == 'resume'),
      isEmpty,
    );
    expect(runtime.ensured, ['session']);
    state.dispose();
    await runtime.closeTest();
  });

  test('plan mode reflects host pending target and explicit off uses original command', () async {
    final runtime = _Runtime()
      ..projection = baseline(null, active: false, pending: true);
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    expect(state.plan!.target, isTrue);
    expect(await state.setPlan(false), isTrue);
    expect(runtime.calls.lastWhere((call) => call.$1 == 'session.command').$2, {
      'sessionId': 'session',
      'line': '/plan off',
      'attachmentIds': [],
    });
    // A receipt is not a fabricated plan/mode event.
    expect(state.plan!.pending, isTrue);
    expect(state.plan!.active, isFalse);
    state.dispose();
    await runtime.closeTest();
  });

  test(
    'submitted plans require original complete arguments and H1 heading',
    () {
      expect(
        ChatSubmittedPlan.fromEvent(submitted(2, 'p', '# Plan\n\n- step'))!
            .title,
        'Plan',
      );
      expect(
        ChatSubmittedPlan.fromEvent(submitted(2, 'p', '## Too small')),
        isNull,
      );
      expect(
        ChatSubmittedPlan.fromEvent(submitted(2, 'p', 'plain text')),
        isNull,
      );
      expect(
        ChatSubmittedPlan.fromEvent(
          event(2, 'tool/call', {
            'callId': 'p',
            'name': 'exit_plan_mode',
            'arguments': '{bad',
          }),
        ),
        isNull,
      );
    },
  );

  test('PTC settlement retains first plan and rejected reviews remain at finished turn tail', () {
    final projection = ChatPlanProjection();
    final log = [
      event(1, 'turn/start', {'turn': 1}),
      submitted(
        2,
        'p',
        '# Initial\nfull text',
        type: 'tool/ptc-dispatch-start',
      ),
      submitted(3, 'p', '# Later', type: 'tool/ptc-dispatch'),
      event(4, 'tool/result', {
        'callId': 'p',
        'result': {'decision': 'keep-planning'},
      }),
    ];
    projection.reconcile(log);
    expect(projection.entries, isEmpty);
    log.add(event(5, 'turn/end', {'turn': 1, 'reason': 'interrupted'}));
    projection.reconcile(log);
    expect(projection.entries.single.title, 'Initial');
    expect(projection.entries.single.seq, 5);
    expect(projection.entries.single.anchorSeq, 2);
    final processed = projection.processedEventCount;
    projection.reconcile(log);
    expect(projection.processedEventCount, processed);
    projection.reconcile([
      event(1, 'turn/start', {'turn': 2}),
    ]);
    expect(projection.entries, isEmpty);
  });

  testWidgets(
    'goal editor preserves draft during concurrent update and exposes comparison',
    (tester) async {
      final runtime = _Runtime();
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      await state.start();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: ChatGoalEditorPage(controller: state, base: state.goal),
        ),
      );
      await tester.tap(find.text('任务目标'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '我的本地草稿');
      // TextDocumentPage returns text into the editor; this does not mutate goal.
      await tester.tap(find.byTooltip('完成编辑'));
      await tester.pumpAndSettle();
      runtime.projected(goalValue(revision: 2, objective: '另一个窗口的目标'), seq: 12);
      await tester.pumpAndSettle();
      expect(find.text('我的本地草稿'), findsOneWidget);
      expect(find.text('另一个窗口的目标'), findsOneWidget);
      expect(find.text('保留草稿，采用最新版本继续编辑'), findsOneWidget);
      expect(runtime.ensured, isEmpty);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await runtime.closeTest();
    },
  );

  testWidgets('new goal editor exposes optional round cap on its detail page', (
    tester,
  ) async {
    final runtime = _Runtime()..projection = null;
    final state = ChatGoalPlanController(
      runtime: runtime,
      sessionId: 'session',
    );
    await state.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: ChatGoalEditorPage(controller: state),
      ),
    );
    expect(find.text('使用服务默认值'), findsOneWidget);
    await tester.tap(find.text('最多执行轮次'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12');
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    await tester.tap(find.text('任务目标'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '完成迁移');
    await tester.tap(find.byTooltip('完成编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存目标'));
    await tester.pumpAndSettle();
    final request = runtime.calls
        .singleWhere((call) => call.$2['method'] == 'create')
        .$2['args'];
    expect(request['request'], {'objective': '完成迁移', 'maxGoalRounds': 12});
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await runtime.closeTest();
  });

  testWidgets(
    'plan document is read-only Markdown and large text does not overflow controls',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = _Runtime()
        ..projection = baseline(
          goalValue(objective: '非常长的任务目标用于检查窄屏状态与大字体布局'),
          pending: true,
        );
      final state = ChatGoalPlanController(
        runtime: runtime,
        sessionId: 'session',
      );
      await state.start();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                ChatGoalDock(controller: state),
                ChatPlanDock(controller: state),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: const ChatPlanDocumentPage(
            title: '记录计划',
            markdown: '# 记录计划\n\n完整内容\n\n- 第一步\n- 第二步',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('完整内容', findRichText: true), findsOneWidget);
      expect(runtime.ensured, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await runtime.closeTest();
    },
  );
}
