import 'dart:async';

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_device_store.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:dsh_android/remote_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_tls_fixture.dart';

/// 设备令牌的线上形态：43 字符 base64url（协议 §2.1）。
const String _deviceToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

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
}) => RemoteConnectionController(
  store: RemoteDeviceStore(
    channel: const MethodChannel('test/remote_connection_unused'),
    tokens: _MemoryVault(_deviceToken),
  ),
  hostStatusTimeout: hostStatusTimeout,
  createTransport:
      ({
        required String endpoint,
        required String token,
        required String pinnedCaPem,
        required String deviceLabel,
        required String appVersion,
        required List<String> capabilities,
      }) => link,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('终止态错误码覆盖证书、握手超时与认证失败', () {
    expect(
      RemoteConnectionController.terminalCodes,
      containsAll(<String>[
        'auth-failed',
        'auth-revoked',
        'protocol-mismatch',
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
    final controller = _controllerFor(link);
    addTearDown(controller.dispose);
    await controller.connect(_device());
    link.handshakeSucceeded(_hostInfo());

    link.emit('remote.deviceRevoked', <String, dynamic>{
      'deviceId': '0123456789abcdef0123456789abcdef',
      'reason': 'user-revoked',
      'revokedAt': 1763000000000,
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.phase, RemoteConnectionPhase.failed);
    expect(controller.lastErrorCode, 'auth-revoked');
    expect(controller.lastError, contains('重新配对'));
  });
}
