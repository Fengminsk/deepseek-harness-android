// 远程通知点击深链：解析、平台通道「取一次即清空」与协调器交付语义。
//
// Kotlin 侧的 pending 生命周期由 MainActivity/RemoteNotifications.kt 实现并在
// `flutter analyze`/Kotlin 编译中验证；这里用 `dsh/runtime` 的通道替身验证 Dart 侧
// 对 `notifications.launch.take` 契约的遵守，以及本地通知 route 不会被误当成远程深链。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/remote_notification_navigation.dart';
import 'package:dsh_android/remote_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一次合法点击的 JSON 文本；[overrides] 直接覆盖字段来造坏帧。
String _payload([Map<String, Object?> overrides = const {}]) =>
    jsonEncode(<String, Object?>{
      'route': 'remote',
      'sessionId': 'session-1',
      'kind': 'taskCompleted',
      'tag': 'turn:3',
      ...overrides,
    });

/// 只按顺序吐出预设结果的读取口；`null` 表示平台侧已经清空。
class _QueueSource implements RemoteNotificationLaunchSource {
  _QueueSource(this._results);

  final List<RemoteNotificationLaunch?> _results;
  int calls = 0;

  @override
  Future<RemoteNotificationLaunch?> take() async {
    calls++;
    return _results.isEmpty ? null : _results.removeAt(0);
  }
}

/// 抛异常的读取口：通道/解析之外的意外失败不能冒泡到生命周期回调。
class _ThrowingSource implements RemoteNotificationLaunchSource {
  int calls = 0;

  @override
  Future<RemoteNotificationLaunch?> take() async {
    calls++;
    throw StateError('channel exploded');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('解析', () {
    test('合法深链保留全部字段', () {
      final launch = RemoteNotificationLaunch.parse(
        jsonDecode(_payload()) as Map<String, dynamic>,
      );
      expect(launch, isNotNull);
      expect(launch!.sessionId, 'session-1');
      expect(launch.kind, RemoteNotificationKind.taskCompleted);
      expect(launch.tag, 'turn:3');
    });

    test('审批种类与缺失 tag 都合法', () {
      final launch = RemoteNotificationLaunch.parse(
        jsonDecode(
          _payload(<String, Object?>{'kind': 'approvalPending', 'tag': null}),
        ) as Map<String, dynamic>,
      );
      expect(launch, isNotNull);
      expect(launch!.kind, RemoteNotificationKind.approvalPending);
      expect(launch.tag, isNull);
    });

    test('未知字段忽略，sessionId/tag 两端空白被去掉', () {
      final launch = RemoteNotificationLaunch.parse(
        jsonDecode(
          _payload(<String, Object?>{
            'sessionId': '  session-2  ',
            'tag': ' turn:9 ',
            'futureField': <String, Object?>{'x': 1},
          }),
        ) as Map<String, dynamic>,
      );
      expect(launch, isNotNull);
      expect(launch!.sessionId, 'session-2');
      expect(launch.tag, 'turn:9');
    });

    test('缺少 route 或 route 不是 remote 时丢弃（含本地通知的 route）', () {
      for (final raw in <Object?>[
        <String, Object?>{'sessionId': 'session-1', 'kind': 'taskCompleted'},
        <String, Object?>{'route': 'session', 'sessionId': 'session-1'},
        <String, Object?>{'route': 'tasks'},
        <String, Object?>{
          'route': 'approval',
          'requestId': 'r-1',
          'sessionId': 'session-1',
        },
      ]) {
        expect(RemoteNotificationLaunch.parse(raw), isNull, reason: '$raw');
      }
    });

    test('sessionId 缺失、空、非字符串或超长时丢弃', () {
      for (final raw in <Object?>[
        <String, Object?>{'route': 'remote', 'kind': 'taskCompleted'},
        <String, Object?>{
          'route': 'remote',
          'sessionId': '',
          'kind': 'taskCompleted',
        },
        <String, Object?>{
          'route': 'remote',
          'sessionId': '   ',
          'kind': 'taskCompleted',
        },
        <String, Object?>{
          'route': 'remote',
          'sessionId': 42,
          'kind': 'taskCompleted',
        },
        <String, Object?>{
          'route': 'remote',
          'sessionId': 'x' * (RemoteNotificationLaunch.sessionIdMaxChars + 1),
          'kind': 'taskCompleted',
        },
      ]) {
        expect(RemoteNotificationLaunch.parse(raw), isNull, reason: '$raw');
      }
    });

    test('kind 缺失或不在两种协议取值内时丢弃', () {
      for (final raw in <Object?>[
        <String, Object?>{'route': 'remote', 'sessionId': 'session-1'},
        <String, Object?>{
          'route': 'remote',
          'sessionId': 'session-1',
          'kind': 'unknown',
        },
        <String, Object?>{
          'route': 'remote',
          'sessionId': 'session-1',
          'kind': 7,
        },
      ]) {
        expect(RemoteNotificationLaunch.parse(raw), isNull, reason: '$raw');
      }
    });

    test('tag 类型错误、空串或超长时丢弃，而不是静默忽略', () {
      for (final tag in <Object?>[
        42,
        '',
        '   ',
        'x' * (RemoteNotificationLaunch.tagMaxChars + 1),
      ]) {
        final raw = <String, Object?>{
          'route': 'remote',
          'sessionId': 'session-1',
          'kind': 'taskCompleted',
          'tag': tag,
        };
        expect(RemoteNotificationLaunch.parse(raw), isNull, reason: '$tag');
      }
    });

    test('非 Map 输入（null、字符串、数组）返回 null', () {
      expect(RemoteNotificationLaunch.parse(null), isNull);
      expect(RemoteNotificationLaunch.parse('remote'), isNull);
      expect(RemoteNotificationLaunch.parse(<Object?>[]), isNull);
    });
  });

  group('平台通道：取一次即清空', () {
    const channel = MethodChannel('test/remote_notification_launch_take');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('连续消费只导航一次，第二次 take 返回 null', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, remoteNotificationLaunchTakeMethod);
        return calls == 1 ? _payload() : null;
      });
      final opened = <RemoteNotificationLaunch>[];
      final navigation = RemoteNotificationNavigation(
        source: const MethodChannelRemoteNotificationLaunchSource(
          channel: channel,
        ),
        open: (launch) {
          opened.add(launch);
          return true;
        },
      );

      await navigation.consume();
      await navigation.consume();

      expect(calls, 2, reason: '每次回前台都会问平台要一次');
      expect(opened, hasLength(1), reason: '平台 take 后清空，重复消费不重复导航');
      expect(opened.single.sessionId, 'session-1');
      expect(navigation.pending, isNull);
    });

    test('损坏 JSON 与非字符串返回值都丢弃，不打开任何页面', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => 'not-json');
      final opened = <RemoteNotificationLaunch>[];
      final navigation = RemoteNotificationNavigation(
        source: const MethodChannelRemoteNotificationLaunchSource(
          channel: channel,
        ),
        open: (launch) {
          opened.add(launch);
          return true;
        },
      );

      await navigation.consume();
      expect(opened, isEmpty);
      expect(navigation.pending, isNull);

      messenger.setMockMethodCallHandler(channel, (call) async => 42);
      final second = RemoteNotificationNavigation(
        source: const MethodChannelRemoteNotificationLaunchSource(
          channel: channel,
        ),
        open: (launch) {
          opened.add(launch);
          return true;
        },
      );
      await second.consume();
      expect(opened, isEmpty);
    });

    test('通道缺席（MissingPluginException）静默降级', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final opened = <RemoteNotificationLaunch>[];
      final navigation = RemoteNotificationNavigation(
        source: const MethodChannelRemoteNotificationLaunchSource(
          channel: channel,
        ),
        open: (launch) {
          opened.add(launch);
          return true;
        },
      );

      await navigation.consume();
      expect(opened, isEmpty);
    });

    test('平台异常静默降级', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom', message: 'read failed');
      });
      final opened = <RemoteNotificationLaunch>[];
      final navigation = RemoteNotificationNavigation(
        source: const MethodChannelRemoteNotificationLaunchSource(
          channel: channel,
        ),
        open: (launch) {
          opened.add(launch);
          return true;
        },
      );

      await navigation.consume();
      expect(opened, isEmpty);
    });
  });

  group('协调器', () {
    test('根页面未就绪时保留 pending，下一次消费重试', () async {
      const launch = RemoteNotificationLaunch(
        sessionId: 'session-1',
        kind: RemoteNotificationKind.taskCompleted,
      );
      final source = _QueueSource(<RemoteNotificationLaunch?>[launch]);
      var ready = false;
      final opened = <RemoteNotificationLaunch>[];
      final navigation = RemoteNotificationNavigation(
        source: source,
        open: (item) {
          if (!ready) return false;
          opened.add(item);
          return true;
        },
      );

      await navigation.consume();
      expect(navigation.pending, isNotNull, reason: '页面没挂载时不能丢掉点击');
      expect(opened, isEmpty);

      ready = true;
      await navigation.consume();
      expect(source.calls, 2, reason: '第二次仍会问平台一次');
      expect(navigation.pending, isNull);
      expect(opened, hasLength(1));
    });

    test('并发消费只读一次通道', () async {
      const launch = RemoteNotificationLaunch(
        sessionId: 'session-1',
        kind: RemoteNotificationKind.approvalPending,
      );
      final gate = Completer<RemoteNotificationLaunch?>();
      final source = _GateSource(gate);
      var opened = 0;
      final navigation = RemoteNotificationNavigation(
        source: source,
        open: (_) {
          opened++;
          return true;
        },
      );

      final first = navigation.consume();
      final second = navigation.consume();
      gate.complete(launch);
      await Future.wait(<Future<void>>[first, second]);

      expect(source.calls, 1);
      expect(opened, 1);
    });

    test('读取抛异常不冒泡，也不留下 pending 半成品', () async {
      final source = _ThrowingSource();
      final navigation = RemoteNotificationNavigation(
        source: source,
        open: (_) => true,
      );

      await navigation.consume();
      expect(source.calls, 1);
      expect(navigation.pending, isNull);
    });
  });
}

/// 手动放行的读取口：验证并发消费的互斥。
class _GateSource implements RemoteNotificationLaunchSource {
  _GateSource(this._gate);

  final Completer<RemoteNotificationLaunch?> _gate;
  int calls = 0;

  @override
  Future<RemoteNotificationLaunch?> take() {
    calls++;
    return _gate.future;
  }
}
