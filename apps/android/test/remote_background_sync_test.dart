// 应用级远程后台同步（RemoteBackgroundSync）与 `dsh/runtime` 平台通道的行为测试。
//
// 关注点全部来自用户反馈的后台丢失场景：连接是否跨页面存活、App 启动后是否自动
// 恢复最近连接并启动前台服务、连接失败/用户关闭后台同步时是否停止、一次性电池优化
// 引导是否只出现一次，以及诊断能否区分「上次运行被系统杀死」（ANR/低内存）。

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_device_store.dart' as paired;
import 'package:dsh_android/remote_notifications.dart';
import 'package:dsh_android/remote_sync_service.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只提供 `ready` / `phase` 的最小运行时；协调器不发起任何本地请求。
class _FakeRuntime extends RuntimeController {
  _FakeRuntime({bool ready = true}) {
    phase = ready ? 'ready' : 'starting';
  }
}

/// 内存令牌保管口：本用例根本不触碰 Keystore/凭据服务。
class _MemoryVault implements paired.RemoteDeviceTokenVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String tokenRef) async => values.remove(tokenRef);

  @override
  Future<bool> isConfigured(String tokenRef) async =>
      values.containsKey(tokenRef);

  @override
  Future<String> read(String tokenRef) async => values[tokenRef] ?? 'token';

  @override
  Future<void> write(String tokenRef, String token) async {
    values[tokenRef] = token;
  }
}

const String _deviceId = '0123456789abcdef0123456789abcdef';

paired.RemoteDevice _device(String id, {String host = '192.168.5.140'}) =>
    paired.RemoteDevice(
      id: id,
      label: 'Pixel 8',
      host: host,
      port: 4777,
      instanceId: 'a' * 64,
      caPem:
          '-----BEGIN CERTIFICATE-----\n'
          'AAAA\n'
          '-----END CERTIFICATE-----\n',
      createdAt: DateTime.utc(2026, 11, 15, 6),
    );

/// 可推进阶段、记录 connect/disconnect 的连接控制器替身。
class _FakeConnection extends RemoteConnectionController {
  _FakeConnection({
    List<paired.RemoteDevice> devices = const <paired.RemoteDevice>[],
    paired.RemoteDevice? lastConnected,
  }) : super(
         store: paired.RemoteDeviceStore(
           channel: const MethodChannel('test/remote-background-sync-unused'),
           tokens: _MemoryVault(),
         ),
       ) {
    _devices = List<paired.RemoteDevice>.of(devices);
    _lastConnected = lastConnected;
  }

  late List<paired.RemoteDevice> _devices;
  paired.RemoteDevice? _lastConnected;
  RemoteConnectionPhase _phase = RemoteConnectionPhase.idle;
  paired.RemoteDevice? _active;
  String? _error;
  String? _errorCode;

  int connects = 0;
  int disconnects = 0;

  @override
  RemoteConnectionPhase get phase => _phase;

  @override
  List<paired.RemoteDevice> get devices => _devices;

  @override
  paired.RemoteDevice? get lastConnectedDevice => _lastConnected;

  @override
  paired.RemoteDevice? get activeDevice => _active;

  @override
  String? get lastError => _error;

  @override
  String? get lastErrorCode => _errorCode;

  @override
  Future<void> connect(paired.RemoteDevice device) async {
    connects++;
    _active = device;
    _phase = RemoteConnectionPhase.connecting;
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    _active = null;
    _phase = RemoteConnectionPhase.idle;
    notifyListeners();
  }

  /// 推进到某个阶段并通知观察者（测试替代真实传输）。
  void moveTo(RemoteConnectionPhase phase, {String? error, String? errorCode}) {
    _phase = phase;
    _error = error;
    _errorCode = errorCode;
    if (phase == RemoteConnectionPhase.ready) {
      _lastConnected ??= _active;
    }
    notifyListeners();
  }
}

class _FakeNotificationPermission implements RemoteNotificationPermission {
  int requests = 0;

  @override
  Future<void> ensureRequested() async {
    requests++;
  }
}

/// 记录全部平台操作的假实现。
class _FakePlatform implements RemoteSyncPlatform {
  bool _started = false;
  final List<String> startReasons = <String>[];
  final List<String> stopReasons = <String>[];
  int heartbeatCalls = 0;
  bool heartbeatAlive = true;
  RemoteSyncServiceStatus? statusValue;
  RemoteSyncPreferencesState preferences = const RemoteSyncPreferencesState(
    backgroundSync: true,
    batteryGuideShown: false,
  );
  bool guideAvailable = false;
  bool batteryRequested = false;
  bool oemRequested = false;
  bool writeSucceeds = true;
  int preferenceWrites = 0;
  Object? startError;

  @override
  bool get started => _started;

  @override
  Future<bool> start(String reason) async {
    if (startError != null) throw startError!;
    _started = true;
    startReasons.add(reason);
    return true;
  }

  @override
  Future<bool> stop(String reason) async {
    _started = false;
    stopReasons.add(reason);
    return true;
  }

  @override
  Future<bool> heartbeat() async {
    heartbeatCalls++;
    return heartbeatAlive;
  }

  @override
  Future<RemoteSyncServiceStatus?> status() async => statusValue;

  @override
  Future<RemoteSyncPreferencesState?> readPreferences() async => preferences;

  @override
  Future<void> writeBackgroundSync(bool enabled) async {
    preferenceWrites++;
    if (!writeSucceeds) throw StateError('偏好写入失败');
    preferences = RemoteSyncPreferencesState(
      backgroundSync: enabled,
      batteryGuideShown: preferences.batteryGuideShown,
    );
  }

  @override
  Future<bool> consumeBatteryGuide() async => guideAvailable;

  @override
  Future<String?> requestBatteryOptimization() async {
    batteryRequested = true;
    return 'request';
  }

  @override
  Future<String?> openOemBackgroundSettings() async {
    oemRequested = true;
    return 'OPPO 自启动管理';
  }
}

RemoteSyncServiceStatus _status({
  bool running = true,
  bool degraded = false,
  bool ignored = false,
  bool previousRunAbnormal = false,
}) => RemoteSyncServiceStatus(
  running: running,
  degraded: degraded,
  recoveryPending: degraded,
  wakeLockHeld: running,
  wakeLockExpiries: 2,
  batteryOptimizationsIgnored: ignored,
  backgroundRestricted: false,
  powerSaveMode: false,
  uiAlive: true,
  previousRunAbnormal: previousRunAbnormal,
  previousRunStartedAt: DateTime.utc(2026, 11, 18, 17, 50),
  startedAt: DateTime.utc(2026, 11, 18, 17, 58),
  lastHeartbeatAt: DateTime.now().subtract(const Duration(seconds: 5)),
  lastTaskRemovedAt: null,
  lastStartReason: 'connection-ready',
  lastStopReason: null,
  storedLastAction: 'running',
  storedLastActionAt: DateTime.utc(2026, 11, 18, 17, 58),
  storedStopReason: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelRemoteSyncPlatform', () {
    const channel = MethodChannel('test/remote-sync-platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    String? statusJson;
    String? preferencesJson;

    setUp(() {
      calls.clear();
      statusJson = null;
      preferencesJson = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'remote.sync.start':
            return true;
          case 'remote.sync.stop':
            return true;
          case 'remote.sync.heartbeat':
            return true;
          case 'remote.sync.status':
            return statusJson;
          case 'remote.sync.preferences.read':
            return preferencesJson;
          case 'remote.sync.preferences.write':
            return true;
          case 'remote.sync.guide.consume':
            return true;
          case 'remote.sync.batteryOptimization.request':
            return 'request';
          case 'remote.sync.oem.backgroundSettings':
            return 'OPPO 自启动管理';
          default:
            throw MissingPluginException('unexpected ${call.method}');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    });

    test('start/stop/heartbeat 带原因调用并维护 started 状态', () async {
      final platform = MethodChannelRemoteSyncPlatform(channel: channel);
      expect(platform.started, isFalse);
      expect(await platform.start('app-start'), isTrue);
      expect(platform.started, isTrue);
      expect(calls.last.method, 'remote.sync.start');
      expect(calls.last.arguments, <String, dynamic>{'reason': 'app-start'});

      expect(await platform.heartbeat(), isTrue);
      expect(calls.last.method, 'remote.sync.heartbeat');

      expect(await platform.stop('user'), isTrue);
      expect(platform.started, isFalse);
      expect(calls.last.method, 'remote.sync.stop');
      expect(calls.last.arguments, <String, dynamic>{'reason': 'user'});
    });

    test('status 解析服务、唤醒锁、电池优化与上次异常结束', () async {
      statusJson =
          '{"running":true,"degraded":false,"recoveryPending":false,'
          '"wakeLockHeld":true,"wakeLockExpiries":3,'
          '"batteryOptimizationsIgnored":true,"backgroundRestricted":false,'
          '"powerSaveMode":false,"uiAlive":true,'
          '"previousRunAbnormal":true,"previousRunStartedAtMillis":1700000000000,'
          '"startedAtMillis":1700000100000,"lastHeartbeatAtMillis":1700000200000,'
          '"lastTaskRemovedAtMillis":1700000300000,'
          '"lastStartReason":"app-start","lastStopReason":null,'
          '"storedLastAction":"process-start","storedLastActionAtMillis":1700000400000,'
          '"storedStopReason":"heartbeat-timeout"}';
      final platform = MethodChannelRemoteSyncPlatform(channel: channel);
      final status = await platform.status();
      expect(status, isNotNull);
      expect(status!.running, isTrue);
      expect(status.degraded, isFalse);
      expect(status.wakeLockHeld, isTrue);
      expect(status.wakeLockExpiries, 3);
      expect(status.batteryOptimizationsIgnored, isTrue);
      expect(status.previousRunAbnormal, isTrue);
      expect(status.lastStartReason, 'app-start');
      expect(status.lastStopReason, isNull);
      expect(status.storedStopReason, 'heartbeat-timeout');
      expect(status.startedAt, isNotNull);
    });

    test('偏好读写与一次性引导消费', () async {
      preferencesJson = '{"backgroundSync":false,"batteryGuideShown":true}';
      final platform = MethodChannelRemoteSyncPlatform(channel: channel);
      final preferences = await platform.readPreferences();
      expect(preferences?.backgroundSync, isFalse);
      expect(preferences?.batteryGuideShown, isTrue);

      await platform.writeBackgroundSync(true);
      expect(calls.last.method, 'remote.sync.preferences.write');
      expect(calls.last.arguments, <String, dynamic>{'backgroundSync': true});

      expect(await platform.consumeBatteryGuide(), isTrue);
      expect(calls.last.method, 'remote.sync.guide.consume');
      expect(await platform.requestBatteryOptimization(), 'request');
      expect(
        await platform.openOemBackgroundSettings(),
        'OPPO 自启动管理',
      );
    });

    test('通道缺失时降级为空状态而不是抛错', () async {
      const missing = MethodChannel('test/remote-sync-missing');
      final platform = MethodChannelRemoteSyncPlatform(channel: missing);
      expect(await platform.start('app-start'), isFalse);
      expect(await platform.heartbeat(), isFalse);
      expect(await platform.status(), isNull);
      expect(await platform.readPreferences(), isNull);
      expect(await platform.consumeBatteryGuide(), isFalse);
    });
  });

  group('RemoteBackgroundSync 应用级连接', () {
    late _FakePlatform platform;
    late _FakeNotificationPermission permission;
    late _FakeRuntime runtime;
    late _FakeConnection connection;
    late RemoteBackgroundSync sync;

    setUp(() {
      platform = _FakePlatform();
      permission = _FakeNotificationPermission();
      runtime = _FakeRuntime();
      connection = _FakeConnection(
        devices: <paired.RemoteDevice>[_device(_deviceId)],
        lastConnected: _device(_deviceId),
      );
      sync = RemoteBackgroundSync(
        platform: platform,
        notificationPermission: permission,
        createConnection: (_) => connection,
        heartbeatInterval: const Duration(minutes: 5),
      );
    });

    tearDown(() {
      sync.dispose();
      runtime.dispose();
    });

    test('App 启动即自动连接最近电脑并启动前台服务', () async {
      await sync.attach(runtime);
      await pumpEventQueue();

      expect(connection.connects, 1, reason: '未进入远程页也应恢复最近连接');
      expect(connection.activeDevice?.id, _deviceId);
      expect(platform.startReasons, contains('app-start'));
      expect(sync.serviceStarted, isTrue);
      expect(platform.heartbeatCalls, greaterThan(0), reason: '启动后立即心跳');
    });

    test('连接就绪时请求一次通知权限并保持服务运行', () async {
      await sync.attach(runtime);
      await pumpEventQueue();
      connection.moveTo(RemoteConnectionPhase.ready);
      await pumpEventQueue();

      expect(permission.requests, 1);
      expect(platform.startReasons.first, 'app-start');
      expect(platform.stopReasons, isEmpty);
      expect(sync.lastDisconnectReason, isNull);
    });

    test('连接失败时停止服务并记录最后断开原因', () async {
      await sync.attach(runtime);
      await pumpEventQueue();
      connection.moveTo(
        RemoteConnectionPhase.failed,
        error: '电脑没有响应',
        errorCode: 'remote/connect-timeout',
      );
      await pumpEventQueue();

      expect(platform.stopReasons, contains('connection-failed'));
      expect(sync.serviceStarted, isFalse);
      expect(sync.lastDisconnectReason, contains('电脑没有响应'));

      final diagnostics = await sync.diagnostics();
      expect(diagnostics.phase, RemoteConnectionPhase.failed);
      expect(diagnostics.lastErrorCode, 'remote/connect-timeout');
    });

    test('页面关闭不再断开共享连接（后台保持连接开启）', () async {
      await sync.attach(runtime);
      await pumpEventQueue();
      connection.moveTo(RemoteConnectionPhase.ready);
      await pumpEventQueue();

      sync.attachPage();
      sync.detachPage();
      await pumpEventQueue();

      expect(connection.disconnects, 0, reason: '返回本地首页不应断开唯一连接');
      expect(platform.stopReasons, isEmpty);
      expect(sync.serviceStarted, isTrue);
    });

    test('关闭后台保持连接后，页面关闭才停止并断开', () async {
      await sync.attach(runtime);
      await pumpEventQueue();
      connection.moveTo(RemoteConnectionPhase.ready);
      await pumpEventQueue();

      sync.attachPage();
      await sync.setBackgroundSyncEnabled(false);
      await pumpEventQueue();
      expect(platform.stopReasons, isEmpty, reason: '页面还打开时继续同步');
      expect(connection.disconnects, 0);

      sync.detachPage();
      await pumpEventQueue();
      expect(platform.stopReasons, contains('page-closed'));
      expect(connection.disconnects, 1);
    });

    test('后台保持连接默认关闭时 App 启动不自动连接，页面打开才连接', () async {
      platform.preferences = const RemoteSyncPreferencesState(
        backgroundSync: false,
        batteryGuideShown: false,
      );
      await sync.attach(runtime);
      await pumpEventQueue();
      expect(connection.connects, 0, reason: '用户关闭后不在启动时连电脑');
      expect(platform.startReasons, isEmpty);

      sync.connection(runtime);
      sync.attachPage();
      connection.moveTo(RemoteConnectionPhase.connecting);
      await pumpEventQueue();
      expect(platform.startReasons, contains('connection-connecting'));
    });

    test('进程被系统杀死后的新进程：启动时恢复连接并暴露上次异常结束', () async {
      platform.statusValue = _status(previousRunAbnormal: true);
      final restored = RemoteBackgroundSync(
        platform: platform,
        notificationPermission: permission,
        createConnection: (_) => connection,
        heartbeatInterval: const Duration(minutes: 5),
      );
      addTearDown(restored.dispose);
      await restored.attach(runtime);
      await pumpEventQueue();

      expect(connection.connects, 1);
      expect(platform.startReasons, contains('app-start'));
      final diagnostics = await restored.diagnostics();
      expect(diagnostics.service?.previousRunAbnormal, isTrue);
      expect(diagnostics.serviceRequested, isTrue);
      expect(diagnostics.heartbeatActive, isTrue);
    });

    test('电池优化未豁免时一次性引导只出现一次', () async {
      platform.statusValue = _status(ignored: false);
      platform.guideAvailable = true;
      await sync.attach(runtime);
      await pumpEventQueue();
      connection.moveTo(RemoteConnectionPhase.ready);
      await pumpEventQueue();

      final first = await sync.takeBatteryGuideNotice();
      expect(first, contains('电池优化'));
      expect(await sync.takeBatteryGuideNotice(), isNull);
    });

    test('已豁免电池优化时不打扰', () async {
      platform.statusValue = _status(ignored: true);
      await sync.attach(runtime);
      await pumpEventQueue();
      connection.moveTo(RemoteConnectionPhase.ready);
      await pumpEventQueue();
      expect(await sync.takeBatteryGuideNotice(), isNull);
    });

    test('设置开关保存失败时记录可读错误', () async {
      platform.writeSucceeds = false;
      await sync.attach(runtime);
      await pumpEventQueue();
      await sync.setBackgroundSyncEnabled(false);
      final diagnostics = await sync.diagnostics();
      expect(diagnostics.lastServiceError, contains('没有保存成功'));
      expect(platform.preferenceWrites, 1);
    });

    test('请求电池优化与厂商后台设置转成可读说明', () async {
      await sync.attach(runtime);
      await pumpEventQueue();
      expect(await sync.requestBatteryOptimization(), contains('电池优化请求页'));
      expect(platform.batteryRequested, isTrue);
      expect(await sync.openOemBackgroundSettings(), contains('自启动'));
      expect(platform.oemRequested, isTrue);
    });

    test('心跳发现服务实例不在时重新启动服务', () async {
      await sync.attach(runtime);
      await pumpEventQueue();
      expect(platform.startReasons, <String>['app-start']);
      platform.heartbeatAlive = false;
      // 下一次心跳（周期 5 分钟太慢，直接触发一次 onAppResumed）。
      await sync.onAppResumed();
      await pumpEventQueue();
      expect(platform.startReasons, contains('heartbeat-restart'));
      expect(sync.serviceStarted, isTrue);
    });
  });
}
