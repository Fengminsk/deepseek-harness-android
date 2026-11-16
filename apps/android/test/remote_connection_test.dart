import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_device_store.dart';
import 'package:dsh_android/remote_notifications.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:dsh_android/remote_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_tls_fixture.dart';

/// 设备令牌的线上形态：43 字符 base64url（协议 §2.1）。
const String _deviceToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

/// 远程通知设备侧出口的内存替身：记录弹出与清理，供连接层断言。
class _RecordingNotificationBridge implements RemoteNotificationBridge {
  final List<RemoteNotification> shown = <RemoteNotification>[];
  int cancelAllCalls = 0;

  @override
  Future<void> show(RemoteNotification notification) async {
    shown.add(notification);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }
}

Map<String, dynamic> _taskCompletedNotification({
  String taskId = 'task-1',
  int turn = 7,
  String summary = '已改 3 个文件',
}) => <String, dynamic>{
  'taskId': taskId,
  'sessionId': 's-1',
  'title': '修复登录',
  'status': 'completed',
  'turn': turn,
  'completedAt': 1763000000000,
  'summary': summary,
};

Map<String, dynamic> _approvalPendingNotification({
  String interactionId = 'interaction-1',
}) => <String, dynamic>{
  'interactionId': interactionId,
  'sessionId': 's-1',
  'kind': 'approval',
  'title': 'pwsh',
  'summary': '请求执行 npm test',
  'createdAt': 1763000000000,
};

Map<String, dynamic> _sessionChangedNotification({
  String sessionId = 's-1',
  int revision = 2,
}) => <String, dynamic>{
  'sessionId': sessionId,
  'revision': revision,
  'title': '新标题',
  'updatedAt': 1763000000000,
};

/// 内存版本的令牌保管口：测试不碰 Keystore，也不读偏好。
class _MemoryVault implements RemoteDeviceTokenVault {
  _MemoryVault(this.token);

  final String token;

  @override
  Future<void> delete(String tokenRef) async {}

  @override
  Future<bool> isConfigured(String tokenRef) async => true;

  @override
  Future<String> read(String tokenRef) async => token;

  @override
  Future<void> write(String tokenRef, String token) async {}
}

/// 只认识部分设备令牌的保管口：模拟「这台电脑的令牌读不出来」。
class _PartialVault implements RemoteDeviceTokenVault {
  _PartialVault(this.token, this.knownRefs);

  final String token;
  final Set<String> knownRefs;

  @override
  Future<void> delete(String tokenRef) async {}

  @override
  Future<bool> isConfigured(String tokenRef) async =>
      knownRefs.contains(tokenRef);

  @override
  Future<String> read(String tokenRef) async {
    if (knownRefs.contains(tokenRef)) return token;
    throw const RemoteDeviceStoreException(
      'remote/credential-read',
      '本机密钥库里没有这台电脑的设备令牌，请重新配对。',
    );
  }

  @override
  Future<void> write(String tokenRef, String token) async {}
}

/// 不拨号的传输替身：测试自己决定握手与阶段推进的时机。
class _FakeLink implements RemoteTransportLink {
  final StreamController<Map<String, dynamic>> _inbound =
      StreamController<Map<String, dynamic>>(sync: true);
  final Completer<RemoteHostInfo> _handshake = Completer<RemoteHostInfo>();

  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  RemoteHostInfo? _host;
  String _phase = 'connecting';
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _inbound.stream;

  @override
  Future<RemoteHostInfo> get handshake => _handshake.future;

  @override
  RemoteHostInfo? get host => _host;

  @override
  String get phase => _phase;

  @override
  bool get isClosed => _closed;

  /// 事件流上是否还有订阅者（切换后旧连接必须取消订阅）。
  bool get hasListener => _inbound.hasListener;

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    requests.add((method: method, params: params));
    return null;
  }

  @override
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {}

  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {}

  @override
  Future<void> close() async {
    _closed = true;
    if (!_inbound.isClosed) await _inbound.close();
  }

  /// 握手成功：推 `remote.status.ready` 并兑现 [handshake]，但不代表宿主可用。
  void handshakeSucceeded(RemoteHostInfo info) {
    _host = info;
    _phase = 'ready';
    emit('remote.status', <String, dynamic>{'phase': 'ready'});
    if (!_handshake.isCompleted) _handshake.complete(info);
  }

  void emit(String method, [Map<String, dynamic> params = const {}]) {
    if (_inbound.isClosed) return;
    _inbound.add(<String, dynamic>{'method': method, 'params': params});
  }

  void lost(String code, String message) {
    _phase = 'lost';
    emit('remote.status', <String, dynamic>{
      'phase': 'lost',
      'error': <String, dynamic>{'code': code, 'message': message},
    });
  }
}

RemoteHostInfo _hostInfo() => RemoteHostInfo(
  protocolVersion: 1,
  name: 'Colin 的台式机',
  platform: 'win32',
  home: r'C:\Users\colin\DSH',
  methods: const <String>['session.send', 'runtime.info'],
  unsupported: const <String>['documents.*'],
  capabilities: const <String>['window-ack'],
);

RemoteDevice _device() => RemoteDevice(
  id: '0123456789abcdef0123456789abcdef',
  label: 'Pixel 8',
  host: '192.168.1.20',
  port: 4777,
  instanceId: caCertificateFingerprint(pairingCaPem),
  caPem: pairingCaPem,
  createdAt: DateTime.utc(2026, 11, 15, 6),
);

RemoteConnectionController _controllerFor(
  _FakeLink link, {
  Duration hostStatusTimeout =
      RemoteConnectionController.defaultHostStatusTimeout,
  RemoteNotificationBridge? notificationBridge,
  bool Function()? isAppForeground,
}) => RemoteConnectionController(
  store: RemoteDeviceStore(
    channel: const MethodChannel('test/remote_connection_unused'),
    tokens: _MemoryVault(_deviceToken),
  ),
  hostStatusTimeout: hostStatusTimeout,
  notificationBridge: notificationBridge ?? _RecordingNotificationBridge(),
  isAppForeground: isAppForeground ?? () => false,
  createTransport: ({
    required String endpoint,
    required String token,
    required String pinnedCaPem,
    required bool systemTrust,
    required String deviceLabel,
    required String appVersion,
    required List<String> capabilities,
  }) => link,
);

/// 每次建连返回一条新的 [_FakeLink]，并记录端点顺序与「建新的之前旧的是否已关闭」。
class _LinkFactory {
  final List<_FakeLink> links = <_FakeLink>[];
  final List<String> endpoints = <String>[];

  /// 每次创建连接时收到的 TLS 信任模式（用于断言 systemTrust 透传）。
  final List<bool> systemTrustFlags = <bool>[];

  /// 每次创建新连接时，上一条连接是否已经关闭。
  final List<bool> previousClosedOnCreate = <bool>[];

  _FakeLink call({
    required String endpoint,
    required String token,
    required String pinnedCaPem,
    required bool systemTrust,
    required String deviceLabel,
    required String appVersion,
    required List<String> capabilities,
  }) {
    if (links.isNotEmpty) previousClosedOnCreate.add(links.last.isClosed);
    final link = _FakeLink();
    links.add(link);
    endpoints.add(endpoint);
    systemTrustFlags.add(systemTrust);
    return link;
  }
}

/// 第二台电脑（与 [_device] 不同的 id / 地址）。
RemoteDevice _secondDevice() => RemoteDevice(
  id: 'fedcba9876543210fedcba9876543210',
  label: 'Pixel 8',
  host: '192.168.1.30',
  port: 4777,
  instanceId: caCertificateFingerprint(pairingCaPem),
  caPem: pairingCaPem,
  createdAt: DateTime.utc(2026, 11, 15, 6, 30),
);

/// 一台经 HTTPS 反代配对的电脑：系统信任公网证书，地址是域名 + 443。
RemoteDevice _proxyDevice() => RemoteDevice(
  id: '00112233445566778899aabbccddeeff',
  label: 'Pixel 8',
  host: 'dsh.example.com',
  port: 443,
  instanceId: caCertificateFingerprint(pairingCaPem),
  caPem: pairingCaPem,
  createdAt: DateTime.utc(2026, 11, 15, 7),
  systemTrust: true,
);

/// 双设备偏好通道：读写与正式实现同一个协议（`{version, devices, lastConnectedDeviceId}`）。
class _DevicePreferences {
  _DevicePreferences(List<RemoteDevice> devices, {this.failSave = false}) {
    preferences = jsonEncode(<String, dynamic>{
      'version': remoteDeviceStoreVersion,
      'devices': <Map<String, dynamic>>[
        for (final device in devices) device.toJson(),
      ],
    });
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case remoteDevicesReadMethod:
          return preferences;
        case remoteDevicesSaveMethod:
          if (failSave) {
            throw PlatformException(
              code: 'remote/preferences',
              message: '测试：偏好写入失败',
            );
          }
          preferences = call.arguments as String;
          writes++;
          return null;
        default:
          throw MissingPluginException('未模拟的偏好方法 ${call.method}');
      }
    });
  }

  static const MethodChannel _channel = MethodChannel(
    'test/remote_connection_devices',
  );
  static final TestDefaultBinaryMessenger _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  static TestDefaultBinaryMessenger get messenger => _messenger;

  /// 是否让偏好写入失败（模拟记录上次连接失败的场景）。
  final bool failSave;

  /// 偏好原文。
  String? preferences;

  /// 偏好写入次数（断言「同一条连接只回写一次」）。
  int writes = 0;

  /// 新建一个绑定这条偏好通道的存储。
  RemoteDeviceStore store(RemoteDeviceTokenVault tokens) =>
      RemoteDeviceStore(channel: _channel, tokens: tokens);

  /// 读回当前偏好里的 JSON。
  Map<String, dynamic> decode() =>
      jsonDecode(preferences ?? '{}') as Map<String, dynamic>;

  /// 移除 mock handler。
  void dispose() => messenger.setMockMethodCallHandler(_channel, null);
}

RemoteConnectionController _controllerWith(
  RemoteDeviceStore store,
  RemoteTransportFactory factory, {
  Duration hostStatusTimeout =
      RemoteConnectionController.defaultHostStatusTimeout,
  RemoteNotificationBridge? notificationBridge,
  bool Function()? isAppForeground,
}) => RemoteConnectionController(
  store: store,
  hostStatusTimeout: hostStatusTimeout,
  notificationBridge: notificationBridge ?? _RecordingNotificationBridge(),
  isAppForeground: isAppForeground ?? () => false,
  createTransport: factory,
);

/// 让连接走完握手与宿主就绪：链路进入 ready、宿主 runtime.status 报 ready。
void _completeHandshake(_FakeLink link) {
  link.handshakeSucceeded(_hostInfo());
  link.emit('runtime.status', <String, dynamic>{'phase': 'ready'});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('终止态错误码覆盖证书、握手超时、拨号超时与认证失败', () {
    expect(
      RemoteConnectionController.terminalCodes,
      containsAll(<String>[
        'auth-failed',
        'auth-revoked',
        'protocol-mismatch',
        'remote/connect-timeout',
        'remote/handshake-timeout',
        'remote/tls',
      ]),
    );
  });

  test('握手完成不等于 ready：要等宿主 runtime.status.phase == "ready"', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    expect(controller.phase, RemoteConnectionPhase.connecting);

    link.handshakeSucceeded(_hostInfo());
    expect(controller.host?.name, 'Colin 的台式机');
    expect(controller.phase, RemoteConnectionPhase.handshaking);
    expect(controller.isReady, isFalse);

    link.emit('runtime.status', <String, dynamic>{'phase': 'starting'});
    expect(controller.hostPhase, 'starting');
    expect(controller.isReady, isFalse);

    link.emit('runtime.status', <String, dynamic>{'phase': 'ready'});
    expect(controller.phase, RemoteConnectionPhase.ready);
    expect(controller.isReady, isTrue);
    expect(controller.lastError, isNull);
  });

  test('宿主的 runtime.ready 通知同样算就绪（同一门面的就绪信号）', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());
    expect(controller.isReady, isFalse);

    link.emit('runtime.ready', <String, dynamic>{'node': 'v24'});
    expect(controller.phase, RemoteConnectionPhase.ready);
  });

  test('宿主迟迟不发就绪状态时超时进入 failed，并给出可展示原因', () async {
    final link = _FakeLink();
    final controller = _controllerFor(
      link,
      hostStatusTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());
    expect(controller.phase, RemoteConnectionPhase.handshaking);

    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'remote/status-timeout');
    expect(controller.lastError, isNotNull);
    expect(controller.lastError, contains('就绪'));
    // 终止后不再保留传输：页面只能通过「重新连接」恢复。
    expect(controller.transport, isNull);
    expect(link.isClosed, isTrue);
  });

  test('宿主明确报 failed 时立即终止并转述宿主原因', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());

    link.emit('runtime.status', <String, dynamic>{
      'phase': 'failed',
      'error': '运行时初始化失败：native.storage.root 不可用',
    });

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'remote/host-failed');
    expect(controller.lastError, contains('native.storage.root'));
  });

  test('remote/tls 是终止态：进入 failed，而不是停在 lost', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());

    link.lost('remote/tls', '无法验证电脑的 TLS 证书：证书指纹不匹配。');
    await Future<void>.delayed(Duration.zero);

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'remote/tls');
    expect(controller.lastError, contains('TLS'));
    expect(link.isClosed, isTrue);
  });

  test('remote/handshake-timeout 也是终止态', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());

    link.lost('remote/handshake-timeout', '连接电脑超时：握手未在 10 秒内完成。');
    await Future<void>.delayed(Duration.zero);

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'remote/handshake-timeout');
  });

  test('设备记录的 TLS 信任模式原样传给传输工厂', () async {
    final devices = _DevicePreferences(<RemoteDevice>[
      _device(),
      _proxyDevice(),
    ]);
    addTearDown(devices.dispose);
    final store = devices.store(_MemoryVault(_deviceToken));
    final factory = _LinkFactory();
    final controller = _controllerWith(store, factory.call);
    addTearDown(controller.dispose);

    await controller.connect(_device());
    await controller.connect(_proxyDevice());

    expect(factory.systemTrustFlags, <bool>[false, true]);
    expect(factory.endpoints, <String>[
      'wss://192.168.1.20:4777/app',
      'wss://dsh.example.com:443/app',
    ]);
  });

  test('拨号超时是终止态：failed 文案与错误码正确，重试可用且不回 ready', () async {
    final devices = _DevicePreferences(<RemoteDevice>[_device()]);
    addTearDown(devices.dispose);
    final store = devices.store(_MemoryVault(_deviceToken));
    final factory = _LinkFactory();
    final controller = _controllerWith(store, factory.call);
    addTearDown(controller.dispose);

    await controller.connect(_device());
    expect(controller.phase, RemoteConnectionPhase.connecting);
    expect(controller.isReady, isFalse);

    // 传输层拨号超时后推出 lost；没有走到握手，所以这里不需要 handshakeSucceeded。
    factory.links.single.lost('remote/connect-timeout', '连接电脑超时，请检查地址与网络后重试。');
    await pumpEventQueue();

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'remote/connect-timeout');
    expect(controller.lastError, '连接电脑超时，请检查地址与网络后重试。');
    expect(controller.isReady, isFalse);
    expect(controller.transport, isNull);
    expect(factory.links.single.isClosed, isTrue, reason: '终止态要关掉传输');

    // 状态机不得回 ready：旧代际迟到的握手/ready 不能把它拉回去。
    factory.links.single.handshakeSucceeded(_hostInfo());
    factory.links.single.emit('runtime.status', <String, dynamic>{
      'phase': 'ready',
    });
    await pumpEventQueue();
    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'remote/connect-timeout');

    // 重试可用：再次 connect 会重新拨号，而不是停在 failed。
    await controller.connect(_device());
    expect(factory.links, hasLength(2));
    expect(controller.phase, RemoteConnectionPhase.connecting);
    expect(controller.activeDevice?.id, _device().id);
    expect(controller.lastError, isNull);
    expect(controller.lastErrorCode, isNull);
  });

  test('切换电脑会取消等待宿主就绪的定时器', () async {
    final devices = _DevicePreferences(<RemoteDevice>[
      _device(),
      _secondDevice(),
    ]);
    addTearDown(devices.dispose);
    final store = devices.store(_MemoryVault(_deviceToken));
    final factory = _LinkFactory();
    final controller = _controllerWith(
      store,
      factory.call,
      hostStatusTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(controller.dispose);

    await controller.connect(_device());
    factory.links.single.handshakeSucceeded(_hostInfo());
    expect(controller.phase, RemoteConnectionPhase.handshaking);

    await controller.switchTo(_secondDevice());
    // 超过旧连接的 60 ms 等待窗口：定时器若没取消，会把新连接推进 failed。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(controller.phase, RemoteConnectionPhase.connecting);
    expect(controller.lastErrorCode, isNull);
    expect(factory.links.first.isClosed, isTrue);
  });

  test('断开连接会取消等待宿主就绪的定时器', () async {
    final link = _FakeLink();
    final controller = _controllerFor(
      link,
      hostStatusTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());
    expect(controller.phase, RemoteConnectionPhase.handshaking);

    await controller.disconnect();
    // 超过等待窗口：定时器若没取消，会留下 lastError 或把阶段推翻。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(controller.phase, RemoteConnectionPhase.idle);
    expect(controller.lastError, isNull);
    expect(controller.lastErrorCode, isNull);
    expect(link.isClosed, isTrue);
  });

  test('events 广播全部入站帧，后订阅者能收到后续帧，dispose 后流正常关闭', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());

    final received = <String>[];
    final subscription = controller.events.listen(
      (event) => received.add(event['method'] as String),
    );
    addTearDown(subscription.cancel);

    link.emit('api.stream', <String, dynamic>{
      'streamId': 'stream-1',
      'sequence': 1,
      'type': 'item',
    });
    link.emit('session.event', <String, dynamic>{'sessionId': 's-1'});
    expect(received, <String>['api.stream', 'session.event']);

    // 后订阅者只收到之后到达的帧（不要求重放），但 dispose 后流必须正常结束。
    final late = <String>[];
    final done = Completer<void>();
    final lateSubscription = controller.events.listen(
      (event) => late.add(event['method'] as String),
      onDone: done.complete,
    );
    addTearDown(lateSubscription.cancel);
    link.emit('sessions.changed', <String, dynamic>{});
    expect(late, <String>['sessions.changed']);

    controller.dispose();
    await done.future.timeout(const Duration(seconds: 2));
    await subscription.cancel();
  });

  test('非状态通知按方法名分类并通知监听者（sessions.changed 不再被吞）', () async {
    final link = _FakeLink();
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());

    var notifications = 0;
    controller.addListener(() => notifications++);

    link.emit('sessions.changed', <String, dynamic>{});
    link.emit('sessions.changed', <String, dynamic>{});
    link.emit('session.changed', <String, dynamic>{'sessionId': 's-1'});
    await Future<void>.delayed(Duration.zero);

    expect(controller.notificationCount('sessions.changed'), 2);
    expect(controller.notificationCount('session.changed'), 1);
    expect(controller.lastNotificationMethod, 'session.changed');
    expect(controller.notificationCounts, <String, int>{
      'sessions.changed': 2,
      'session.changed': 1,
    });
    // 状态帧不计入通知计数。
    expect(controller.notificationCount('remote.status'), 0);
    expect(notifications, greaterThanOrEqualTo(1));
  });

  test('remote.deviceRevoked 立即把连接置为已撤销', () async {
    final link = _FakeLink();
    final bridge = _RecordingNotificationBridge();
    final controller = _controllerFor(link, notificationBridge: bridge);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());

    link.emit('remote.deviceRevoked', <String, dynamic>{
      'deviceId': '0123456789abcdef0123456789abcdef',
      'reason': 'user-revoked',
      'revokedAt': 1763000000000,
    });
    await pumpEventQueue();

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'auth-revoked');
    expect(controller.lastError, contains('重新配对'));
    expect(
      bridge.cancelAllCalls,
      greaterThanOrEqualTo(1),
      reason: '撤销后连接终止，远程系统通知要一起清掉',
    );
  });

  group('远程系统通知（协议 §8）', () {
    test('remote.taskCompleted 严格解析后计数、广播并弹系统通知', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerFor(link, notificationBridge: bridge);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());

      final streamed = <RemoteNotification>[];
      final subscription = controller.remoteNotifications.listen(streamed.add);
      addTearDown(subscription.cancel);

      link.emit('remote.taskCompleted', _taskCompletedNotification());
      await pumpEventQueue();

      expect(controller.notificationCount('remote.taskCompleted'), 1);
      expect(controller.lastNotificationMethod, 'remote.taskCompleted');
      expect(streamed, hasLength(1));
      expect(streamed.single.title, '修复登录');
      expect(bridge.shown, hasLength(1));
      expect(bridge.shown.single.body, '已改 3 个文件');

      // 同一 sessionId+turn 的重复帧不再弹第二次。
      link.emit('remote.taskCompleted', _taskCompletedNotification());
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
      expect(controller.notificationCount('remote.taskCompleted'), 1);
    });

    test('remote.approvalPending 按 interactionId 去重后弹系统通知', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerFor(link, notificationBridge: bridge);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());

      link.emit('remote.approvalPending', _approvalPendingNotification());
      link.emit('remote.approvalPending', _approvalPendingNotification());
      link.emit(
        'remote.approvalPending',
        _approvalPendingNotification(interactionId: 'interaction-2'),
      );
      await pumpEventQueue();

      expect(controller.notificationCount('remote.approvalPending'), 2);
      expect(bridge.shown, hasLength(2));
    });

    test('缺少必填字段的 remote.* 帧被丢弃且不计入通知计数', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerFor(link, notificationBridge: bridge);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());

      link.emit('remote.taskCompleted', <String, dynamic>{
        'sessionId': 's-1',
      });
      link.emit('remote.approvalPending', <String, dynamic>{
        'interactionId': 'interaction-1',
      });
      await pumpEventQueue();

      expect(controller.notificationCount('remote.taskCompleted'), 0);
      expect(controller.notificationCount('remote.approvalPending'), 0);
      expect(controller.lastNotificationMethod, isNull);
      expect(bridge.shown, isEmpty);
    });

    test('remote.sessionChanged 只更新计数与 revision 水位，不弹通知', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerFor(link, notificationBridge: bridge);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());

      link.emit('remote.sessionChanged', _sessionChangedNotification());
      await pumpEventQueue();

      expect(controller.notificationCount('remote.sessionChanged'), 1);
      expect(controller.lastSessionChange?.title, '新标题');
      expect(controller.sessionRevision('s-1'), 2);

      // 同一 sessionId 的 revision 回退帧丢弃（协议 §8.5）。
      link.emit(
        'remote.sessionChanged',
        _sessionChangedNotification(revision: 1),
      );
      await pumpEventQueue();
      expect(controller.notificationCount('remote.sessionChanged'), 1);
      expect(controller.lastSessionChange?.revision, 2);

      link.emit(
        'remote.sessionChanged',
        _sessionChangedNotification(revision: 3),
      );
      await pumpEventQueue();
      expect(controller.notificationCount('remote.sessionChanged'), 2);
      expect(controller.sessionRevision('s-1'), 3);
      expect(bridge.shown, isEmpty, reason: '会话变更没有待办动作，不弹系统通知');
    });

    test('App 在前台时计数照旧但不弹系统通知', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerFor(
        link,
        notificationBridge: bridge,
        isAppForeground: () => true,
      );
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());

      final frames = <String>[];
      final subscription = controller.events.listen(
        (event) => frames.add(event['method'] as String),
      );
      addTearDown(subscription.cancel);

      link.emit('remote.taskCompleted', _taskCompletedNotification());
      await pumpEventQueue();

      expect(controller.notificationCount('remote.taskCompleted'), 1);
      expect(frames, contains('remote.taskCompleted'));
      expect(bridge.shown, isEmpty, reason: '前台由页面线呈现同一事实');
    });

    test('App 退到后台后新通知照常弹系统通知', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      var foreground = true;
      final controller = _controllerFor(
        link,
        notificationBridge: bridge,
        isAppForeground: () => foreground,
      );
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());

      link.emit('remote.taskCompleted', _taskCompletedNotification(turn: 7));
      await pumpEventQueue();
      expect(bridge.shown, isEmpty);

      foreground = false;
      link.emit('remote.taskCompleted', _taskCompletedNotification(turn: 8));
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
      expect(bridge.shown.single.turn, 8);
    });

    test('切换电脑时清空去重表并取消远程系统通知', () async {
      final devices = _DevicePreferences(<RemoteDevice>[
        _device(),
        _secondDevice(),
      ]);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerWith(
        store,
        factory.call,
        notificationBridge: bridge,
      );
      addTearDown(controller.dispose);

      await controller.connect(_device());
      _completeHandshake(factory.links.single);
      factory.links.single.emit(
        'remote.approvalPending',
        _approvalPendingNotification(),
      );
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
      final cancelsBeforeSwitch = bridge.cancelAllCalls;

      await controller.switchTo(_secondDevice());
      await pumpEventQueue();
      expect(
        bridge.cancelAllCalls,
        greaterThan(cancelsBeforeSwitch),
        reason: '切换电脑时旧电脑的通知必须清掉',
      );

      _completeHandshake(factory.links.last);
      factory.links.last.emit(
        'remote.approvalPending',
        _approvalPendingNotification(),
      );
      await pumpEventQueue();
      expect(
        bridge.shown,
        hasLength(2),
        reason: '新连接上的同一 interactionId 是另一台电脑的事实，要重新提醒',
      );
    });

    test('断开连接时取消远程系统通知', () async {
      final link = _FakeLink();
      final bridge = _RecordingNotificationBridge();
      final controller = _controllerFor(link, notificationBridge: bridge);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      link.handshakeSucceeded(_hostInfo());
      link.emit('remote.approvalPending', _approvalPendingNotification());
      await pumpEventQueue();
      expect(bridge.shown, hasLength(1));
      final cancelsBeforeDisconnect = bridge.cancelAllCalls;

      await controller.disconnect();
      await pumpEventQueue();

      expect(controller.phase, RemoteConnectionPhase.idle);
      expect(
        bridge.cancelAllCalls,
        greaterThan(cancelsBeforeDisconnect),
        reason: '断开后通知里的会话已经没有可点开的远程上下文',
      );
      expect(controller.notificationCounts, isEmpty);
    });
  });

  group('多台电脑切换', () {
    test('switchTo 先关闭旧连接再建新连接，阶段不卡在 ready', () async {
      final devices = _DevicePreferences(<RemoteDevice>[
        _device(),
        _secondDevice(),
      ]);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);

      await controller.connect(_device());
      _completeHandshake(factory.links.single);
      expect(controller.phase, RemoteConnectionPhase.ready);
      expect(controller.host?.name, 'Colin 的台式机');

      await controller.switchTo(_secondDevice());

      // 旧连接彻底关闭：不再有事件订阅，也不再是当前传输。
      expect(factory.links, hasLength(2));
      expect(factory.links.first.isClosed, isTrue);
      expect(factory.links.first.hasListener, isFalse);
      expect(factory.previousClosedOnCreate, <bool>[true], reason: '先关旧的再建新的');
      expect(controller.activeDevice?.id, _secondDevice().id);
      expect(controller.transport, same(factory.links.last));
      expect(controller.phase, RemoteConnectionPhase.connecting);
      expect(controller.isReady, isFalse);
      expect(controller.host, isNull, reason: '旧连接的宿主身份不能留给新连接');
      expect(factory.endpoints, <String>[
        _device().appEndpoint.toString(),
        _secondDevice().appEndpoint.toString(),
      ]);

      _completeHandshake(factory.links.last);
      expect(controller.phase, RemoteConnectionPhase.ready);
      expect(controller.host?.name, 'Colin 的台式机');
    });

    test('点已连接的电脑不会重复连接', () async {
      final devices = _DevicePreferences(<RemoteDevice>[_device()]);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      _completeHandshake(factory.links.single);

      await controller.switchTo(_device());

      expect(factory.links, hasLength(1), reason: '同一台电脑不新建传输');
      expect(factory.links.single.isClosed, isFalse);
      expect(controller.phase, RemoteConnectionPhase.ready);
      expect(controller.activeDevice?.id, _device().id);
    });

    test('切换失败时旧连接已关闭，停在 failed 并指向新电脑（不回退旧连接）', () async {
      final devices = _DevicePreferences(<RemoteDevice>[
        _device(),
        _secondDevice(),
      ]);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);

      await controller.connect(_device());
      _completeHandshake(factory.links.single);

      await controller.switchTo(_secondDevice());
      // 新电脑不可达：传输报终止性错误（TLS 指纹不匹配）。
      factory.links.last.lost('remote/tls', '无法验证电脑的 TLS 证书：证书指纹不匹配。');
      await pumpEventQueue();

      expect(controller.phase, RemoteConnectionPhase.failed);
      expect(controller.lastErrorCode, 'remote/tls');
      expect(controller.lastError, contains('TLS'));
      expect(
        controller.activeDevice?.id,
        _secondDevice().id,
        reason: '失败页要指向那台连不上的电脑',
      );
      expect(controller.transport, isNull);
      expect(factory.links.first.isClosed, isTrue, reason: '旧连接不会因为新连接失败而复活');
      expect(factory.links.last.isClosed, isTrue);

      // 可恢复：重试新电脑会重新拨号，而不是静默回到旧电脑。
      await controller.connect(_secondDevice());
      expect(factory.links, hasLength(3));
      expect(controller.phase, RemoteConnectionPhase.connecting);
      expect(controller.activeDevice?.id, _secondDevice().id);
    });

    test('切换到令牌读不出来的电脑：旧连接已关闭并停在 failed', () async {
      final devices = _DevicePreferences(<RemoteDevice>[
        _device(),
        _secondDevice(),
      ]);
      addTearDown(devices.dispose);
      final store = devices.store(
        _PartialVault(_deviceToken, <String>{_device().tokenRef}),
      );
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);
      await controller.connect(_device());
      _completeHandshake(factory.links.single);

      await controller.switchTo(_secondDevice());

      expect(controller.phase, RemoteConnectionPhase.failed);
      expect(controller.lastErrorCode, 'remote/credential-read');
      expect(controller.lastError, contains('重新配对'));
      expect(controller.activeDevice?.id, _secondDevice().id);
      expect(factory.links, hasLength(1), reason: '令牌都没有读到，不该拨号');
      expect(factory.links.single.isClosed, isTrue, reason: '旧连接先关闭');
    });

    test('ready 时把电脑记为上次连接，并回写宿主自报的电脑名', () async {
      final devices = _DevicePreferences(<RemoteDevice>[
        _device(),
        _secondDevice(),
      ]);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);

      await controller.connect(_device());
      _completeHandshake(factory.links.single);
      await pumpEventQueue();

      expect(controller.lastConnectedDevice?.id, _device().id);
      final table = await store.loadTable();
      expect(table.lastConnectedDeviceId, _device().id);
      expect(table.lastConnectedDevice?.hostName, 'Colin 的台式机');
      expect(table.lastConnectedDevice?.displayName, 'Colin 的台式机');
      expect(devices.decode()[remoteLastConnectedDeviceKey], _device().id);
    });

    test('重复的 ready 信号不会重复回写上次连接', () async {
      final devices = _DevicePreferences(<RemoteDevice>[_device()]);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);

      await controller.connect(_device());
      _completeHandshake(factory.links.single);
      await pumpEventQueue();
      final writes = devices.writes;

      // 宿主可能既推 runtime.ready 又推 runtime.status(ready)。
      factory.links.single.emit('runtime.ready', <String, dynamic>{});
      factory.links.single.emit('runtime.status', <String, dynamic>{
        'phase': 'ready',
      });
      await pumpEventQueue();

      expect(controller.phase, RemoteConnectionPhase.ready);
      expect(devices.writes, writes, reason: '同一条连接只回写一次偏好');
    });

    test('记录上次连接的偏好写入失败不影响本次连接就绪', () async {
      final devices = _DevicePreferences(<RemoteDevice>[
        _device(),
      ], failSave: true);
      addTearDown(devices.dispose);
      final store = devices.store(_MemoryVault(_deviceToken));
      final factory = _LinkFactory();
      final controller = _controllerWith(store, factory.call);
      addTearDown(controller.dispose);

      await controller.connect(_device());
      _completeHandshake(factory.links.single);
      await pumpEventQueue();

      expect(controller.phase, RemoteConnectionPhase.ready);
      expect(controller.isReady, isTrue);
      expect(controller.lastError, isNull);
    });
  });
}
