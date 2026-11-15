// 远程宿主推送通知的 App 侧行为：严格解析、去重、前台抑制、断连清理与系统通知桥。
//
// 协议字段以 `apps/android/docs/remote-dsh/protocol.md` §8.2/§8.3/§8.5 为准。

import 'package:dsh_android/remote_notifications.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 远程通知设备侧出口的内存替身：记录调用，也能按需失败。
class _RecordingBridge implements RemoteNotificationBridge {
  final List<RemoteNotification> shown = <RemoteNotification>[];
  int showAttempts = 0;
  int cancelAllCalls = 0;
  bool failShow = false;
  bool failCancel = false;

  @override
  Future<void> show(RemoteNotification notification) async {
    showAttempts++;
    if (failShow) {
      throw PlatformException(code: 'test/show', message: '通知通道不可用');
    }
    shown.add(notification);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    if (failCancel) {
      throw PlatformException(code: 'test/cancel', message: '通知通道不可用');
    }
  }
}

Map<String, dynamic> _taskCompletedParams({
  String taskId = 'task-1',
  String sessionId = 's-1',
  String title = '修复登录',
  String status = 'completed',
  int? turn = 7,
  String? summary = '已改 3 个文件',
  bool? truncated,
}) => <String, dynamic>{
  'taskId': taskId,
  'sessionId': sessionId,
  'workspaceId': 'ws-1',
  'title': title,
  'status': status,
  'turn': ?turn,
  'completedAt': 1763000000000,
  'summary': ?summary,
  'truncated': ?truncated,
};

Map<String, dynamic> _approvalPendingParams({
  String interactionId = 'interaction-1',
  String sessionId = 's-1',
  String kind = 'approval',
  String title = 'pwsh',
  String? summary = '请求执行 npm test',
  String? toolName = 'pwsh',
  bool? truncated,
}) => <String, dynamic>{
  'interactionId': interactionId,
  'sessionId': sessionId,
  'kind': kind,
  'title': title,
  'summary': ?summary,
  'toolName': ?toolName,
  'createdAt': 1763000000000,
  'truncated': ?truncated,
};

Map<String, dynamic> _sessionChangedParams({
  String sessionId = 's-1',
  int revision = 2,
  String? title = '新标题',
  bool? archived,
}) => <String, dynamic>{
  'sessionId': sessionId,
  'workspaceId': 'ws-1',
  'revision': revision,
  'title': ?title,
  'archived': ?archived,
  'updatedAt': 1763000000000,
};

/// 超过帧上限但字段本身合法的帧：未知字段按协议 §8.1 忽略，帧上限由本层兜底。
Map<String, dynamic> _padded(
  Map<String, dynamic> params,
  int bytes,
) => <String, dynamic>{
  ...params,
  'padding': 'x' * bytes,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote.taskCompleted 解析（协议 §8.2）', () {
    test('合法帧解析出通知字段与去重键', () {
      final notification = parseRemoteTaskCompleted(_taskCompletedParams());

      expect(notification, isNotNull);
      expect(notification!.kind, RemoteNotificationKind.taskCompleted);
      expect(notification.sessionId, 's-1');
      expect(notification.title, '修复登录');
      expect(notification.body, '已改 3 个文件');
      expect(notification.tag, 'task-1');
      expect(notification.taskId, 'task-1');
      expect(notification.workspaceId, 'ws-1');
      expect(notification.status, 'completed');
      expect(notification.turn, 7);
      expect(notification.timestamp, 1763000000000);
      expect(notification.truncated, isFalse);
      expect(notification.dedupeKey, 'taskCompleted:s-1:7');
    });

    test('turn 缺失时用 taskId 兜底去重键', () {
      final notification = parseRemoteTaskCompleted(
        _taskCompletedParams(turn: null),
      );

      expect(notification, isNotNull);
      expect(notification!.dedupeKey, 'taskCompleted:s-1:task-1');
    });

    test('必填字段缺失整帧丢弃', () {
      for (final key in <String>[
        'taskId',
        'sessionId',
        'title',
        'status',
        'completedAt',
      ]) {
        final params = _taskCompletedParams()..remove(key);
        expect(
          parseRemoteTaskCompleted(params),
          isNull,
          reason: '缺少必填字段 $key 时应丢弃',
        );
      }
    });

    test('类型或枚举不对整帧丢弃', () {
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams()..['taskId'] = 42),
        isNull,
      );
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams()..['title'] = '   '),
        isNull,
        reason: '空白标题不可展示',
      );
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams()..['status'] = 'running'),
        isNull,
        reason: 'status 只接受协议枚举 completed/failed/cancelled',
      );
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams()..['turn'] = '7'),
        isNull,
      );
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams()..['turn'] = -1),
        isNull,
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams()..['completedAt'] = 'yesterday',
        ),
        isNull,
      );
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams()..['truncated'] = 'yes'),
        isNull,
      );
    });

    test('字段与帧超限整帧丢弃', () {
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(title: 'x' * 201),
        ),
        isNull,
        reason: 'title 上限 200 字符',
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(title: 'x' * 200),
        ),
        isNotNull,
        reason: '刚好 200 字符应接受',
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(summary: 'x' * 513),
        ),
        isNull,
        reason: 'summary 上限 512 字符',
      );
      expect(
        parseRemoteTaskCompleted(
          _padded(_taskCompletedParams(), remoteTaskCompletedFrameBytes),
        ),
        isNull,
        reason: '帧超过 8 KiB 应丢弃',
      );
    });

    test('summary 缺失时按 status 给兜底正文', () {
      expect(
        parseRemoteTaskCompleted(_taskCompletedParams(summary: null))!.body,
        contains('已完成'),
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(status: 'failed', summary: null),
        )!.body,
        contains('失败'),
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(status: 'cancelled', summary: null),
        )!.body,
        contains('取消'),
      );
    });

    test('truncated 透传为正文末尾省略号，已带省略号不重复补', () {
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(summary: '已改 3 个文件', truncated: true),
        )!.body,
        '已改 3 个文件…',
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(summary: '已改 3 个文件…', truncated: true),
        )!.body,
        '已改 3 个文件…',
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(summary: '已改 3 个文件', truncated: false),
        )!.body,
        '已改 3 个文件',
      );
      expect(
        parseRemoteTaskCompleted(
          _taskCompletedParams(summary: null, truncated: true),
        )!.body,
        '本轮任务已完成，轻点查看回复。',
        reason: '正文是兜底句时不再补省略号（truncated 可能是 id 被截断）',
      );
    });
  });

  group('remote.approvalPending 解析（协议 §8.3）', () {
    test('合法帧解析出审批字段与去重键', () {
      final notification = parseRemoteApprovalPending(_approvalPendingParams());

      expect(notification, isNotNull);
      expect(notification!.kind, RemoteNotificationKind.approvalPending);
      expect(notification.sessionId, 's-1');
      expect(notification.title, 'pwsh');
      expect(notification.body, '请求执行 npm test');
      expect(notification.tag, 'interaction-1');
      expect(notification.interactionId, 'interaction-1');
      expect(notification.interactionKind, 'approval');
      expect(notification.toolName, 'pwsh');
      expect(notification.timestamp, 1763000000000);
      expect(notification.dedupeKey, 'approvalPending:interaction-1');
    });

    test('summary 缺失时按 kind 给兜底正文', () {
      expect(
        parseRemoteApprovalPending(
          _approvalPendingParams(summary: null),
        )!.body,
        contains('审批'),
      );
      expect(
        parseRemoteApprovalPending(
          _approvalPendingParams(kind: 'question', summary: null),
        )!.body,
        contains('回答'),
      );
      expect(
        parseRemoteApprovalPending(
          _approvalPendingParams(kind: 'plan', summary: null),
        )!.body,
        contains('方案'),
      );
    });

    test('必填/枚举/上限不合格整帧丢弃', () {
      for (final key in <String>[
        'interactionId',
        'sessionId',
        'kind',
        'title',
        'createdAt',
      ]) {
        final params = _approvalPendingParams()..remove(key);
        expect(
          parseRemoteApprovalPending(params),
          isNull,
          reason: '缺少必填字段 $key 时应丢弃',
        );
      }
      expect(
        parseRemoteApprovalPending(
          _approvalPendingParams()..['kind'] = 'permission',
        ),
        isNull,
      );
      expect(
        parseRemoteApprovalPending(
          _approvalPendingParams(summary: 'x' * 1025),
        ),
        isNull,
      );
      expect(
        parseRemoteApprovalPending(
          _approvalPendingParams(toolName: 'x' * 129),
        ),
        isNull,
      );
      expect(
        parseRemoteApprovalPending(
          _padded(_approvalPendingParams(), remoteApprovalPendingFrameBytes),
        ),
        isNull,
      );
    });
  });

  group('remote.sessionChanged 解析（协议 §8.5）', () {
    test('合法帧解析出会话变更字段', () {
      final change = parseRemoteSessionChanged(_sessionChangedParams());

      expect(change, isNotNull);
      expect(change!.sessionId, 's-1');
      expect(change.revision, 2);
      expect(change.title, '新标题');
      expect(change.workspaceId, 'ws-1');
      expect(change.updatedAt, 1763000000000);
      expect(change.archived, isNull);
    });

    test('必填/类型/上限不合格整帧丢弃', () {
      for (final key in <String>['sessionId', 'revision', 'updatedAt']) {
        final params = _sessionChangedParams()..remove(key);
        expect(
          parseRemoteSessionChanged(params),
          isNull,
          reason: '缺少必填字段 $key 时应丢弃',
        );
      }
      expect(
        parseRemoteSessionChanged(_sessionChangedParams()..['revision'] = -1),
        isNull,
      );
      expect(
        parseRemoteSessionChanged(_sessionChangedParams()..['revision'] = '2'),
        isNull,
      );
      expect(
        parseRemoteSessionChanged(_sessionChangedParams()..['archived'] = 1),
        isNull,
      );
      expect(
        parseRemoteSessionChanged(
          _padded(_sessionChangedParams(), remoteSessionChangedFrameBytes),
        ),
        isNull,
      );
    });
  });

  group('分发器去重与前台抑制', () {
    test('同一 sessionId+turn 只弹一次，不同轮次各弹一次', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      expect(
        dispatcher.handle(remoteTaskCompletedMethod, _taskCompletedParams()),
        isTrue,
      );
      expect(
        dispatcher.handle(remoteTaskCompletedMethod, _taskCompletedParams()),
        isFalse,
        reason: '重复帧不再接受',
      );
      dispatcher.handle(
        remoteTaskCompletedMethod,
        _taskCompletedParams(turn: 8),
      );
      await pumpEventQueue();

      expect(bridge.shown, hasLength(2));
      expect(bridge.shown.map((item) => item.turn), <int>[7, 8]);
    });

    test('turn 缺失时按 taskId 去重，不同任务各弹一次', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      dispatcher.handle(
        remoteTaskCompletedMethod,
        _taskCompletedParams(turn: null),
      );
      dispatcher.handle(
        remoteTaskCompletedMethod,
        _taskCompletedParams(turn: null),
      );
      dispatcher.handle(
        remoteTaskCompletedMethod,
        _taskCompletedParams(taskId: 'task-2', turn: null),
      );
      await pumpEventQueue();

      expect(bridge.shown, hasLength(2));
    });

    test('同一 interactionId 只弹一次', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      dispatcher.handle(
        remoteApprovalPendingMethod,
        _approvalPendingParams(interactionId: 'interaction-2'),
      );
      await pumpEventQueue();

      expect(bridge.shown, hasLength(2));
    });

    test('App 在前台时不弹系统通知，但仍广播且不重复补弹', () async {
      final bridge = _RecordingBridge();
      var foreground = true;
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => foreground,
      );
      addTearDown(dispatcher.dispose);
      final streamed = <RemoteNotification>[];
      final subscription = dispatcher.notifications.listen(streamed.add);
      addTearDown(subscription.cancel);

      expect(
        dispatcher.handle(remoteTaskCompletedMethod, _taskCompletedParams()),
        isTrue,
      );
      await pumpEventQueue();
      expect(bridge.shown, isEmpty, reason: '前台由页面线呈现，不弹系统通知');
      expect(streamed, hasLength(1), reason: '通知流仍然广播，供页面提示用');

      // 退到后台后同一事实不补弹（去重表在前台时就已经记下）。
      foreground = false;
      dispatcher.handle(remoteTaskCompletedMethod, _taskCompletedParams());
      await pumpEventQueue();
      expect(bridge.shown, isEmpty);

      dispatcher.handle(
        remoteTaskCompletedMethod,
        _taskCompletedParams(turn: 9),
      );
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
    });

    test('通知流按到达顺序广播解析结果', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);
      final streamed = <RemoteNotification>[];
      final subscription = dispatcher.notifications.listen(streamed.add);
      addTearDown(subscription.cancel);

      dispatcher.handle(remoteTaskCompletedMethod, _taskCompletedParams());
      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      await pumpEventQueue();

      expect(streamed, hasLength(2));
      expect(streamed.first.kind, RemoteNotificationKind.taskCompleted);
      expect(streamed.last.kind, RemoteNotificationKind.approvalPending);
    });

    test('不合格帧不广播、不弹通知、不占去重键', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      expect(
        dispatcher.handle(remoteTaskCompletedMethod, <String, dynamic>{
          'sessionId': 's-1',
        }),
        isFalse,
      );
      expect(
        dispatcher.handle('remote.unknown', _taskCompletedParams()),
        isFalse,
      );
      await pumpEventQueue();
      expect(bridge.shown, isEmpty);

      // 上一帧被丢弃，合法帧仍然能弹（没有被半残帧占掉去重键）。
      expect(
        dispatcher.handle(remoteTaskCompletedMethod, _taskCompletedParams()),
        isTrue,
      );
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
    });
  });

  group('清理与失败降级', () {
    test('clear 取消远程通知并清空去重表', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));

      dispatcher.clear();
      await pumpEventQueue();
      expect(bridge.cancelAllCalls, 1);

      // 同一 interactionId 在换代之后是新连接上的新提醒。
      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      await pumpEventQueue();
      expect(bridge.shown, hasLength(2));
    });

    test('bridge 抛错只记录，不影响去重与后续通知', () async {
      final bridge = _RecordingBridge();
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      bridge.failShow = true;
      expect(
        dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams()),
        isTrue,
      );
      await pumpEventQueue();
      expect(bridge.showAttempts, 1);
      expect(bridge.shown, isEmpty);

      // 失败不重试：同一 interactionId 的重复帧仍然被去重表挡住。
      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      await pumpEventQueue();
      expect(bridge.showAttempts, 1);

      bridge.failShow = false;
      dispatcher.handle(
        remoteApprovalPendingMethod,
        _approvalPendingParams(interactionId: 'interaction-2'),
      );
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
    });

    test('cancelAll 失败不影响清理与连接', () async {
      final bridge = _RecordingBridge()..failCancel = true;
      final dispatcher = RemoteNotificationDispatcher(
        bridge: bridge,
        isAppForeground: () => false,
      );
      addTearDown(dispatcher.dispose);

      dispatcher.handle(remoteApprovalPendingMethod, _approvalPendingParams());
      await pumpEventQueue();
      dispatcher.clear();
      await pumpEventQueue();

      expect(bridge.cancelAllCalls, 1);
      dispatcher.handle(
        remoteApprovalPendingMethod,
        _approvalPendingParams(interactionId: 'interaction-3'),
      );
      await pumpEventQueue();
      expect(bridge.shown, hasLength(2), reason: '清理失败也不能卡住后续通知');
    });
  });

  group('dsh/runtime 系统通知桥', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RuntimeController.channel, (call) async {
            calls.add(call);
            return true;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RuntimeController.channel, null);
    });

    test('show/cancelAll 走约定方法名与参数', () async {
      final bridge = MethodChannelRemoteNotificationBridge();
      final notification = parseRemoteApprovalPending(_approvalPendingParams())!;

      await bridge.show(notification);
      await bridge.cancelAll();

      expect(calls, hasLength(2));
      expect(
        calls.first.method,
        MethodChannelRemoteNotificationBridge.showMethod,
      );
      expect(
        calls.first.method,
        'notifications.remote.show',
        reason: '方法名是 Kotlin MainActivity 的接线点，不能漂移',
      );
      final arguments = calls.first.arguments as Map<Object?, Object?>;
      expect(arguments['kind'], 'approvalPending');
      expect(arguments['title'], 'pwsh');
      expect(arguments['body'], '请求执行 npm test');
      expect(arguments['tag'], 'interaction-1');
      expect(arguments['sessionId'], 's-1');
      expect(arguments['interactionKind'], 'approval');
      expect(
        calls.last.method,
        MethodChannelRemoteNotificationBridge.cancelAllMethod,
      );
      expect(calls.last.method, 'notifications.remote.cancelAll');
    });

    test('设备侧抛错时 show/cancelAll 静默降级', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            RuntimeController.channel,
            (call) async => throw PlatformException(
              code: 'notification-failed',
              message: '通道不可用',
            ),
          );
      final bridge = MethodChannelRemoteNotificationBridge();
      final notification = parseRemoteTaskCompleted(_taskCompletedParams())!;

      await expectLater(bridge.show(notification), completes);
      await expectLater(bridge.cancelAll(), completes);
    });
  });
}
