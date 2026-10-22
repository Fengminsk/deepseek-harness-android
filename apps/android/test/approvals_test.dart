import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/approvals.dart';
import 'package:dsh_android/approvals_notifications.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';

Json clone(Json value) => jsonDecode(jsonEncode(value)) as Json;

class InteractionRuntime extends RuntimeController {
  InteractionRuntime(List<Json> requests) {
    remote = requests.map(clone).toList();
    interactions = requests.map(clone).toList();
    phase = 'ready';
  }
  late List<Json> remote;
  final replies = <Json>[];
  final waits = <Json>[];
  final dismissals = <Json>[];
  bool failReply = false;
  bool rejectReply = false;
  bool failRefresh = false;
  String? snapshotError;
  bool applyBeforeLostAck = false;
  Completer<Json>? replyBarrier;
  Completer<void>? nextRefreshBarrier;
  Completer<Json>? notificationDraftBarrier;
  String? notificationDraft;

  @override
  Future<void> refreshInteractions() async {
    final barrier = nextRefreshBarrier;
    nextRefreshBarrier = null;
    if (barrier != null) await barrier.future;
    if (failRefresh) {
      interactionsError = 'transport unavailable';
      notifyListeners();
      throw PlatformException(code: 'transport', message: 'unavailable');
    }
    interactions = remote.map(clone).toList();
    interactionsError = snapshotError;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    switch (method) {
      case 'interactions.reply':
        replies.add(clone(params));
        if (rejectReply) {
          return {
            'accepted': false,
            'requestStillPending': true,
            'message': '内容需要修改，输入已保留。',
          };
        }
        if (applyBeforeLostAck) {
          remote.clear();
          throw PlatformException(code: 'transport', message: 'lost ack');
        }
        if (failReply) {
          throw PlatformException(code: 'transport', message: 'not delivered');
        }
        if (replyBarrier != null) return replyBarrier!.future;
        remote.removeWhere(
          (request) =>
              request['id'] == params['id'] &&
              request['version'] == params['version'],
        );
        return {'accepted': true, 'requestStillPending': false};
      case 'interactions.wait':
        waits.add(clone(params));
        return {};
      case 'interactions.dismiss':
        dismissals.add(clone(params));
        final pending = remote.any(
          (request) =>
              request['id'] == params['id'] &&
              request['version'] == params['version'] &&
              request['callId'] != null,
        );
        if (!pending) remote.clear();
        return {'accepted': true, 'requestStillPending': pending};
      case 'notifications.draft':
        return notificationDraftBarrier?.future ?? {'text': notificationDraft};
      default:
        throw StateError('Unexpected method $method');
    }
  }
}

Json approval({int version = 1}) => {
  'id': 'approval-1',
  'version': version,
  'sessionId': 'session-a',
  'kind': 'approval',
  'toolName': 'bash',
  'callId': 'tool-call-a',
  'reason': 'Read the chosen folder',
  'displayReason': {'en': 'Read the chosen folder', 'zh': '读取指定的目录'},
  'toolCall': {
    'name': 'bash',
    'arguments': {
      'command': 'ls /data/user/0/com.minnnng.dsh_android/files',
      'workdir': '/data/user/0/com.minnnng.dsh_android/files',
    },
  },
};

Json question(List<Json> items, {bool timed = false}) => {
  'id': 'question-1',
  'version': 3,
  'sessionId': 'session-a',
  'kind': 'question',
  'questions': items,
  'callId': 'question-call-a',
  'state': 'open',
  if (timed) ...{
    'waitState': 'counting',
    'countdown': {'remainingMs': 30000, 'running': true},
  },
};

Future<void> openRequest(
  WidgetTester tester,
  InteractionRuntime runtime, {
  int? version,
}) async {
  tester.view.physicalSize = const Size(700, 1300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  final request = runtime.remote.single;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      theme: pocketTheme(Brightness.light),
      home: ApprovalsPage(
        runtime: runtime,
        requestId: request['id'] as String,
        requestVersion: version ?? request['version'] as int,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: .4);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

PocketButton button(WidgetTester tester, String label) =>
    tester.widget<PocketButton>(
      find.ancestor(of: find.text(label), matching: find.byType(PocketButton)),
    );

Finder custom(String id) => find.byKey(ValueKey('question-custom:$id'));

void main() {
  testWidgets(
    'approval shows the actual call and sends allowed-once once while a reply is in flight',
    (tester) async {
      final runtime = InteractionRuntime([approval()]);
      final barrier = Completer<Json>();
      runtime.replyBarrier = barrier;
      addTearDown(() {
        if (!barrier.isCompleted) {
          barrier.complete({'accepted': false, 'requestStillPending': false});
        }
      });
      await openRequest(tester, runtime);
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('工具调用：tool-call-a'), findsOneWidget);
      await tapVisible(tester, find.text('完整工具调用参数'));
      expect(
        find.textContaining('ls /data/user/0/com.minnnng.dsh_android/files'),
        findsOneWidget,
      );
      await tester.tap(find.text('允许一次'));
      await tester.pump();
      expect(button(tester, '拒绝').onPressed, isNull);
      expect(button(tester, '正在提交').onPressed, isNull);
      expect(runtime.replies, [
        {'id': 'approval-1', 'version': 1, 'response': 'allowed-once'},
      ]);
      runtime.remote.clear();
      barrier.complete({'accepted': true, 'requestStillPending': false});
      await tester.pumpAndSettle();
      expect(find.text('答复已提交。'), findsOneWidget);
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reject emits only the real DSH rejected outcome', (
    tester,
  ) async {
    final runtime = InteractionRuntime([approval()]);
    await openRequest(tester, runtime);
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(runtime.replies.single['response'], 'rejected');
    expect(runtime.replies.single['version'], 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'single, multiple and custom answers preserve question ids and original labels',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {
            'id': 'single',
            'question': 'Choose scope',
            'options': [
              {'label': 'Local'},
              {'label': 'LAN'},
            ],
          },
          {
            'id': 'multi',
            'question': 'Choose outputs',
            'multiSelect': true,
            'options': [
              {'label': 'Log'},
              {'label': 'Report'},
            ],
          },
          {'id': 'free', 'question': 'Any other details?'},
        ]),
      ]);
      await openRequest(tester, runtime);
      await tapVisible(tester, find.text('LAN'));
      await tapVisible(tester, find.text('Log'));
      await tapVisible(tester, find.text('Report'));
      await Scrollable.ensureVisible(
        tester.element(custom('multi')),
        alignment: .4,
      );
      await tester.enterText(custom('multi'), ' Include raw data ');
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(custom('free')),
        alignment: .4,
      );
      await tester.enterText(custom('free'), 'Before noon');
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(runtime.replies.single['response'], {
        'answers': [
          {
            'id': 'single',
            'selected': ['LAN'],
          },
          {
            'id': 'multi',
            'selected': ['Log', 'Report'],
            'custom': 'Include raw data',
          },
          {'id': 'free', 'selected': <String>[], 'custom': 'Before noon'},
        ],
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recommended choice is visibly selected without editing the timed wait',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {
            'id': 'scope',
            'question': 'Choose scope',
            'options': [
              {'label': 'Local (Recommended)'},
              {'label': 'Remote'},
            ],
          },
        ], timed: true),
      ]);
      await openRequest(tester, runtime);
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('Local (Recommended)'), findsNothing);
      expect(
        runtime.waits.where((item) => item['action'] == 'engage'),
        isEmpty,
      );
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(runtime.replies.single['response'], {
        'answers': [
          {
            'id': 'scope',
            'selected': ['Local (Recommended)'],
          },
        ],
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a rejected answer retains text and selection for correction and explicit resubmission',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {
            'id': 'details',
            'question': 'Details',
            'multiSelect': true,
            'options': [
              {'label': 'Keep logs'},
            ],
          },
        ]),
      ])..rejectReply = true;
      await openRequest(tester, runtime);
      await tapVisible(tester, find.text('Keep logs'));
      await tester.enterText(custom('details'), 'Do not erase this');
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(find.text('内容需要修改，输入已保留。'), findsOneWidget);
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'Do not erase this',
      );
      expect(button(tester, '提交回答').onPressed, isNotNull);
      runtime.rejectReply = false;
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(runtime.replies, hasLength(2));
      expect(
        runtime.replies.last['response'],
        runtime.replies.first['response'],
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a lost acknowledgement followed by settled state never resends and retains the draft read-only',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ]),
      ])..applyBeforeLostAck = true;
      await openRequest(tester, runtime);
      await tester.enterText(custom('details'), 'Sent once');
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(runtime.replies, hasLength(1));
      expect(find.textContaining('当前输入未再次发送'), findsOneWidget);
      expect(button(tester, '提交回答').onPressed, isNull);
      expect(tester.widget<TextField>(custom('details')).enabled, false);
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'Sent once',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving after a failure retains the draft for the same pending request without answering',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ]),
      ])..failReply = true;
      await openRequest(tester, runtime);
      await tester.enterText(custom('details'), 'Keep across navigation');
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: ApprovalsPage(
            runtime: runtime,
            requestId: 'question-1',
            requestVersion: 3,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'Keep across navigation',
      );
      expect(button(tester, '提交回答').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an unknown reply result remains blocked after a settled-state refresh',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ]),
      ]);
      await openRequest(tester, runtime);
      await tester.enterText(custom('details'), 'Keep me');
      runtime.failReply = true;
      runtime.failRefresh = true;
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(find.textContaining('答复结果暂不确定'), findsOneWidget);
      expect(button(tester, '提交回答').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      runtime.remote.clear();
      runtime.failRefresh = false;
      await tester.tap(find.byTooltip('核对请求状态'));
      await tester.pumpAndSettle();
      expect(button(tester, '提交回答').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'Keep me',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a still-pending snapshot cannot unlock an unconfirmed approval across navigation',
    (tester) async {
      final runtime = InteractionRuntime([approval()])..failReply = true;
      await openRequest(tester, runtime);
      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不能证明先前的答复未送达'), findsOneWidget);
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(button(tester, '拒绝').onPressed, isNull);
      expect(runtime.replies, hasLength(1));

      await tester.tap(find.byTooltip('核对请求状态'));
      await tester.pumpAndSettle();
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(runtime.replies, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: ApprovalsPage(
            runtime: runtime,
            requestId: 'approval-1',
            requestVersion: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('已有一次提交，结果尚未确认'), findsOneWidget);
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(button(tester, '拒绝').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a confirmed reply after page disposal remains submitted when the page reopens',
    (tester) async {
      final runtime = InteractionRuntime([approval()]);
      final barrier = Completer<Json>();
      runtime.replyBarrier = barrier;
      addTearDown(() {
        if (!barrier.isCompleted) {
          barrier.complete({'accepted': false, 'requestStillPending': false});
        }
      });
      await openRequest(tester, runtime);
      await tester.tap(find.text('允许一次'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      barrier.complete({'accepted': true, 'requestStillPending': false});
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: ApprovalsPage(
            runtime: runtime,
            requestId: 'approval-1',
            requestVersion: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('操作已发送，等待 DSH 完成处理'), findsOneWidget);
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a disappearing and reappearing cached request cannot clear an unknown write',
    (tester) async {
      final runtime = InteractionRuntime([approval()])..failReply = true;
      await openRequest(tester, runtime);
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      runtime.remote.clear();
      await tester.tap(find.byTooltip('核对请求状态'));
      await tester.pumpAndSettle();
      runtime.remote.add(approval());
      await tester.tap(find.byTooltip('核对请求状态'));
      await tester.pumpAndSettle();
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(button(tester, '拒绝').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a refresh begun before an unconfirmed reply cannot unlock another answer',
    (tester) async {
      final runtime = InteractionRuntime([approval()]);
      await openRequest(tester, runtime);
      final staleRead = Completer<void>();
      addTearDown(() {
        if (!staleRead.isCompleted) staleRead.complete();
      });
      runtime.nextRefreshBarrier = staleRead;
      await tester.tap(find.byTooltip('核对请求状态'));
      await tester.pump();
      runtime.failReply = true;
      runtime.failRefresh = true;
      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();
      expect(find.textContaining('答复结果暂不确定'), findsOneWidget);
      expect(runtime.replies, hasLength(1));
      runtime.failRefresh = false;
      staleRead.complete();
      await tester.pumpAndSettle();
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(button(tester, '拒绝').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'notification or Web settlement disables the App draft without submitting it',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ]),
      ]);
      await openRequest(tester, runtime);
      await tester.enterText(custom('details'), 'Local draft');
      runtime.remote.clear();
      await runtime.refreshInteractions();
      await tester.pumpAndSettle();
      expect(button(tester, '提交回答').onPressed, isNull);
      expect(tester.widget<TextField>(custom('details')).enabled, false);
      expect(runtime.replies, isEmpty);
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'Local draft',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an uncertain bridge snapshot keeps a cached pending approval disabled after refresh',
    (tester) async {
      final runtime = InteractionRuntime([approval()]);
      await openRequest(tester, runtime);
      runtime.failReply = true;
      runtime.snapshotError = '答复结果未确认';
      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();
      expect(find.textContaining('答复结果尚未确认'), findsOneWidget);
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(button(tester, '拒绝').onPressed, isNull);
      await tester.tap(find.byTooltip('核对请求状态'));
      await tester.pumpAndSettle();
      expect(button(tester, '允许一次').onPressed, isNull);
      expect(runtime.replies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an old notification version cannot approve a newer request', (
    tester,
  ) async {
    final runtime = InteractionRuntime([approval(version: 2)]);
    await openRequest(tester, runtime, version: 1);
    expect(find.text('允许一次'), findsNothing);
    expect(find.textContaining('此通知已失效'), findsOneWidget);
    expect(runtime.replies, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'plan review opens its document and requests changes without submitting a choice',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {
            'id': 'plan',
            'question': 'Review this plan',
            'detail': 'Step 1: inspect files\nStep 2: wait for a decision',
            'intent': {'kind': 'plan-review', 'approve': 'Proceed'},
            'options': [
              {'label': 'Revise', 'description': 'Request changes'},
              {'label': 'Proceed', 'description': 'Use this plan'},
            ],
          },
        ]),
      ]);
      await openRequest(tester, runtime);
      expect(find.textContaining('Step 1: inspect files'), findsOneWidget);
      expect(runtime.replies, isEmpty);
      await tapVisible(tester, find.text('单独查看完整计划'));
      expect(
        find.textContaining('Step 2: wait for a decision'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请求修改'));
      await tester.pumpAndSettle();
      expect(runtime.dismissals, [
        {'id': 'question-1', 'version': 3},
      ]);
      expect(runtime.replies, isEmpty);
      await tester.tap(find.text('批准计划'));
      await tester.pumpAndSettle();
      expect(runtime.replies.single['response'], {
        'answers': [
          {
            'id': 'plan',
            'selected': ['Proceed'],
          },
        ],
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'DSH wait controls forward actions while the App adds no countdown or rejection',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ], timed: true),
      ]);
      await openRequest(tester, runtime);
      expect(find.text('DSH 等待时间：约 30 秒'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('DSH 等待时间：约 30 秒'), findsOneWidget);
      await tapVisible(tester, find.text('需要更多时间'));
      await tester.enterText(custom('details'), 'Editing');
      await tester.pumpAndSettle();
      expect(
        runtime.waits.map((entry) => entry['action']),
        contains('takeTime'),
      );
      expect(runtime.waits.map((entry) => entry['action']), contains('engage'));
      expect(
        runtime.waits.map((entry) => entry['action']),
        contains('holdFocus'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        runtime.waits.map((entry) => entry['action']),
        contains('releaseFocus'),
      );
      expect(runtime.replies, isEmpty);
    },
  );

  testWidgets(
    'notification draft restoration never overwrites an App edit made while it loads',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ]),
      ]);
      final barrier = Completer<Json>();
      runtime.notificationDraftBarrier = barrier;
      addTearDown(() {
        if (!barrier.isCompleted) barrier.complete({'text': null});
      });
      await openRequest(tester, runtime);
      await tester.enterText(custom('details'), 'App has priority');
      barrier.complete({'text': 'Older notification text'});
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'App has priority',
      );
      expect(runtime.replies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'notification input that failed to submit is restored for explicit review',
    (tester) async {
      final runtime = InteractionRuntime([
        question([
          {'id': 'details', 'question': 'Details'},
        ]),
      ])..notificationDraft = 'Draft from notification';
      await openRequest(tester, runtime);
      expect(
        tester.widget<TextField>(custom('details')).controller!.text,
        'Draft from notification',
      );
      expect(runtime.replies, isEmpty);
      expect(find.textContaining('请检查后提交'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'system notification controls request permission only on a user action',
    (tester) async {
      final calls = <String>[];
      var enabled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RuntimeController.channel, (call) async {
            calls.add(call.method);
            if (call.method == 'notifications.status') {
              return jsonEncode({
                'enabled': enabled,
                'reason': enabled ? 'enabled' : 'permission',
                'channelId': 'agent-requests',
              });
            }
            if (call.method == 'notifications.request') {
              enabled = true;
              return null;
            }
            if (call.method == 'notifications.settings') return null;
            throw MissingPluginException();
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(RuntimeController.channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: const NotificationSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, ['notifications.status']);
      await tapVisible(tester, find.text('允许系统通知'));
      expect(find.text('授权通知已开启'), findsOneWidget);
      expect(
        calls.where((method) => method == 'notifications.request'),
        hasLength(1),
      );
      await tapVisible(tester, find.text('打开系统通知设置'));
      expect(calls, contains('notifications.settings'));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
