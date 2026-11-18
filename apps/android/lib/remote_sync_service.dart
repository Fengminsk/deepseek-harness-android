/// 主进程前台同步服务与「应用级远程连接」的 Dart 侧所有者。
///
/// 目标：App 退到桌面/后台时，远程连接与 `session.follow` / `remote.*` 通知继续运行，
/// 任务完成与审批提问能像聊天软件一样弹出系统通知。三条事实决定了这里的结构：
///
/// - 连接只存在于 Flutter UI isolate 的 `RemoteConnectionController` 里，因此**连接
///   必须跨页面存活**：`RemoteDshPage` 只是视图，从会话页返回远程首页、从远程页返回
///   本地首页都不该断掉唯一连接。本文件用应用级 [RemoteBackgroundSync] 持有共享连接，
///   页面通过 [RemoteBackgroundConnectionHost] 借用，不再各自创建/销毁。
/// - Android 前台服务只能在界面可见时启动（Android 12+），但进程被系统杀死（ANR、
///   低内存、OEM 后台清理）后 Dart isolate 也会消失；因此服务以「常驻通知 + 心跳」
///   表达真实的同步状态：心跳新鲜才算同步中，心跳超时只显示可点按恢复的通知。
/// - 唤醒锁、电池优化豁免、厂商自启动设置都**不能绕过** ANR 与 OEM 后台策略，只减少
///   被系统当成空闲进程回收的机会。界面与诊断里如实说明这一点。
///
/// 与平台的全部交互走 `dsh/runtime` 通道（见 [MethodChannelRemoteSyncPlatform]）：
/// `remote.sync.start|stop|heartbeat|status`、`remote.sync.preferences.read|write`、
/// `remote.sync.guide.consume`、`remote.sync.batteryOptimization.request`、
/// `remote.sync.oem.backgroundSettings`。测试注入 [RemoteSyncPlatform] 与假连接控制器。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_connection.dart';
import 'remote_device_store.dart' as paired;
import 'remote_notifications.dart';
import 'runtime.dart';

/// 页面/平台可注入的后台同步生命周期（原有接口，测试用假实现）。
abstract class RemoteSyncLifecycle {
  /// Ask the platform to keep the process alive in the background.
  Future<void> start();

  /// Stop the background service and remove its ongoing notification.
  Future<void> stop();
}

/// `dsh/runtime` 实现：`remote.sync.start` / `remote.sync.stop`。
///
/// 这是给页面历史路径保留的薄封装（页面在测试里注入假实现）；应用级连接由
/// [RemoteBackgroundSync] 通过 [RemoteSyncPlatform] 直接带原因调用。
class MethodChannelRemoteSyncLifecycle implements RemoteSyncLifecycle {
  MethodChannelRemoteSyncLifecycle({MethodChannel? channel, RemoteSyncPlatform? platform})
    : _platform = platform ?? MethodChannelRemoteSyncPlatform(channel: channel);

  final RemoteSyncPlatform _platform;

  /// 本进程内是否成功启动过；平台服务另有自己的状态（`remote.sync.status`）。
  bool get started => _platform.started;

  @override
  Future<void> start() async {
    if (_platform.started) return;
    try {
      await _platform.start('page');
    } on Object {
      // 旧 App 外壳或通道不可用：前台同步保持关闭，会话本身照常工作。
    }
  }

  @override
  Future<void> stop() async {
    if (!_platform.started) return;
    try {
      await _platform.stop('page');
    } on Object {
      // 停止是尽力而为：服务也会在连接终止/用户关闭后台同步时停止。
    }
  }
}

/// `remote.sync.status` 的一份快照（字段与 Kotlin `RemoteSyncService.statusJson` 同名）。
@immutable
class RemoteSyncServiceStatus {
  /// 创建快照；字段全部来自平台，缺字段时使用安全默认值。
  const RemoteSyncServiceStatus({
    required this.running,
    required this.degraded,
    required this.recoveryPending,
    required this.wakeLockHeld,
    required this.wakeLockExpiries,
    required this.batteryOptimizationsIgnored,
    required this.backgroundRestricted,
    required this.powerSaveMode,
    required this.uiAlive,
    required this.previousRunAbnormal,
    required this.previousRunStartedAt,
    required this.startedAt,
    required this.lastHeartbeatAt,
    required this.lastTaskRemovedAt,
    required this.lastStartReason,
    required this.lastStopReason,
    required this.storedLastAction,
    required this.storedLastActionAt,
    required this.storedStopReason,
  });

  /// 解析 Kotlin 侧 `statusJson` 的 JSON 对象。
  factory RemoteSyncServiceStatus.fromJson(Map<String, dynamic> json) {
    DateTime? time(Object? value) => value is num && value > 0
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
    String? text(Object? value) => value is String && value.isNotEmpty ? value : null;
    int count(Object? value) => value is num && value.isFinite ? value.toInt() : 0;
    return RemoteSyncServiceStatus(
      running: json['running'] == true,
      degraded: json['degraded'] == true,
      recoveryPending: json['recoveryPending'] == true,
      wakeLockHeld: json['wakeLockHeld'] == true,
      wakeLockExpiries: count(json['wakeLockExpiries']),
      batteryOptimizationsIgnored: json['batteryOptimizationsIgnored'] == true,
      backgroundRestricted: json['backgroundRestricted'] == true,
      powerSaveMode: json['powerSaveMode'] == true,
      uiAlive: json['uiAlive'] == true,
      previousRunAbnormal: json['previousRunAbnormal'] == true,
      previousRunStartedAt: time(json['previousRunStartedAtMillis']),
      startedAt: time(json['startedAtMillis']),
      lastHeartbeatAt: time(json['lastHeartbeatAtMillis']),
      lastTaskRemovedAt: time(json['lastTaskRemovedAtMillis']),
      lastStartReason: text(json['lastStartReason']),
      lastStopReason: text(json['lastStopReason']),
      storedLastAction: text(json['storedLastAction']),
      storedLastActionAt: time(json['storedLastActionAtMillis']),
      storedStopReason: text(json['storedStopReason']),
    );
  }

  /// 服务正在前台运行且心跳新鲜（真的在同步）。
  final bool running;

  /// 服务仍在，但没有可用连接（进程重启 / 心跳超时 / 划掉任务后引擎不在）。
  final bool degraded;

  /// 是否处于「可点按恢复」状态（与 [degraded] 同义，命名贴合界面文案）。
  final bool recoveryPending;

  /// 当前前台期间是否持有 CPU 唤醒锁。
  final bool wakeLockHeld;

  /// 唤醒锁超时后被重新获取的次数。
  final int wakeLockExpiries;

  /// Android 标准电池优化是否已豁免本应用（只影响提示，不阻塞同步）。
  final bool batteryOptimizationsIgnored;

  /// Android 是否报告后台执行受限。
  final bool backgroundRestricted;

  /// 系统省电模式是否开启。
  final bool powerSaveMode;

  /// 最后一次读取状态时界面/FlutterEngine 是否存活。
  final bool uiAlive;

  /// 本进程启动时是否检测到上次运行被系统杀死（ANR/低内存/厂商清理）。
  final bool previousRunAbnormal;

  /// 上次异常结束的那轮服务开始时间；没有记录时为 null。
  final DateTime? previousRunStartedAt;

  /// 本轮服务开始时间。
  final DateTime? startedAt;

  /// 最近一次心跳时间。
  final DateTime? lastHeartbeatAt;

  /// 最近一次划掉最近任务的时间。
  final DateTime? lastTaskRemovedAt;

  /// 服务启动原因（App 启动自动连接 / 连接就绪 / 恢复通知点击等）。
  final String? lastStartReason;

  /// 服务停止/降级原因（连接失败、用户关闭后台同步、心跳超时等）。
  final String? lastStopReason;

  /// 持久化的最后一次状态动作（进程被系统杀死后仍可读）。
  final String? storedLastAction;

  /// 持久化状态动作的时间。
  final DateTime? storedLastActionAt;

  /// 持久化的最后停止原因。
  final String? storedStopReason;
}

/// 原生保存的后台同步偏好。
@immutable
class RemoteSyncPreferencesState {
  /// 创建偏好快照。
  const RemoteSyncPreferencesState({
    required this.backgroundSync,
    required this.batteryGuideShown,
  });

  /// 解析 `remote.sync.preferences.read` 的 JSON。
  factory RemoteSyncPreferencesState.fromJson(Map<String, dynamic> json) =>
      RemoteSyncPreferencesState(
        backgroundSync: json['backgroundSync'] != false,
        batteryGuideShown: json['batteryGuideShown'] == true,
      );

  /// 是否在 App 启动后自动保持远程连接与后台服务（默认开启）。
  final bool backgroundSync;

  /// 一次性电池优化引导是否已经展示过。
  final bool batteryGuideShown;
}

/// 设置页与诊断用的合并快照：原生服务状态 + Dart 侧连接/服务决策。
@immutable
class RemoteSyncDiagnostics {
  /// 创建诊断快照。
  const RemoteSyncDiagnostics({
    required this.service,
    required this.backgroundSyncEnabled,
    required this.pageOpen,
    required this.serviceRequested,
    required this.serviceStarts,
    required this.serviceStops,
    required this.heartbeatActive,
    required this.phase,
    required this.deviceLabel,
    required this.pairedDeviceCount,
    required this.lastError,
    required this.lastErrorCode,
    required this.lastDisconnectReason,
    required this.lastServiceError,
    required this.lastRestoreError,
  });

  /// 尚未读取到任何状态时的空快照；页面首帧用它占位。
  static const RemoteSyncDiagnostics empty = RemoteSyncDiagnostics(
    service: null,
    backgroundSyncEnabled: true,
    pageOpen: false,
    serviceRequested: false,
    serviceStarts: 0,
    serviceStops: 0,
    heartbeatActive: false,
    phase: null,
    deviceLabel: null,
    pairedDeviceCount: 0,
    lastError: null,
    lastErrorCode: null,
    lastDisconnectReason: null,
    lastServiceError: null,
    lastRestoreError: null,
  );

  /// 原生前台服务状态；读取失败或旧 App 外壳时为 null。
  final RemoteSyncServiceStatus? service;

  /// 用户是否开启「后台保持与电脑的连接」。
  final bool backgroundSyncEnabled;

  /// 当前是否有远程页面在使用共享连接。
  final bool pageOpen;

  /// Dart 侧是否认为服务已经启动（与原生 [service] 可能短暂不一致）。
  final bool serviceRequested;

  /// 本进程内启动过服务的次数。
  final int serviceStarts;

  /// 本进程内停止过服务的次数。
  final int serviceStops;

  /// 心跳定时器是否在运行。
  final bool heartbeatActive;

  /// 远程连接阶段；从未建立共享连接时为 null。
  final RemoteConnectionPhase? phase;

  /// 当前/最近连接的电脑名。
  final String? deviceLabel;

  /// 本机已配对电脑数量。
  final int pairedDeviceCount;

  /// 最近一次连接失败的可读原因。
  final String? lastError;

  /// 最近一次连接失败的协议错误码。
  final String? lastErrorCode;

  /// 最近一次断开/失败的原因说明（Dart 侧记录）。
  final String? lastDisconnectReason;

  /// Dart 侧最近一次平台操作错误。
  final String? lastServiceError;

  /// 最近一次恢复连接失败的原因。
  final String? lastRestoreError;
}

/// 协调器需要的平台能力；生产实现走 `dsh/runtime`，测试注入假实现。
abstract class RemoteSyncPlatform {
  /// 本进程内是否成功启动过前台服务。
  bool get started;

  /// 启动前台服务；[reason] 写进服务诊断。
  Future<bool> start(String reason);

  /// 停止前台服务；[reason] 写进服务诊断。
  Future<bool> stop(String reason);

  /// 心跳报到；返回服务实例是否存活（false 表示需要重新 start）。
  Future<bool> heartbeat();

  /// 读取服务状态快照。
  Future<RemoteSyncServiceStatus?> status();

  /// 读取后台同步偏好。
  Future<RemoteSyncPreferencesState?> readPreferences();

  /// 保存「启动后自动保持连接」偏好。
  Future<void> writeBackgroundSync(bool enabled);

  /// 消费一次性电池优化引导；第一次返回 true。
  Future<bool> consumeBatteryGuide();

  /// 打开系统电池优化请求页；返回模式（`request` / `list` / `already-ignored`）。
  Future<String?> requestBatteryOptimization();

  /// 打开厂商自启动/耗电管理页；返回命中的候选名或 `app-details`。
  Future<String?> openOemBackgroundSettings();
}

/// `dsh/runtime` 生产实现。
class MethodChannelRemoteSyncPlatform implements RemoteSyncPlatform {
  /// 创建平台实现；[channel] 默认 `dsh/runtime`（测试可换命名通道）。
  MethodChannelRemoteSyncPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/runtime');

  final MethodChannel _channel;
  bool _started = false;

  @override
  bool get started => _started;

  @override
  Future<bool> start(String reason) async {
    try {
      final value = await _channel.invokeMethod<bool>('remote.sync.start', {
        'reason': reason,
      });
      _started = value ?? true;
      return _started;
    } on MissingPluginException {
      _started = false;
      return false;
    }
  }

  @override
  Future<bool> stop(String reason) async {
    try {
      await _channel.invokeMethod<bool>('remote.sync.stop', {'reason': reason});
      _started = false;
      return true;
    } on MissingPluginException {
      _started = false;
      return false;
    }
  }

  @override
  Future<bool> heartbeat() async {
    try {
      return await _channel.invokeMethod<bool>('remote.sync.heartbeat') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<RemoteSyncServiceStatus?> status() async {
    try {
      final raw = await _channel.invokeMethod<String>('remote.sync.status');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RemoteSyncServiceStatus.fromJson(_stringMap(decoded));
    } on MissingPluginException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<RemoteSyncPreferencesState?> readPreferences() async {
    try {
      final raw = await _channel.invokeMethod<String>(
        'remote.sync.preferences.read',
      );
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RemoteSyncPreferencesState.fromJson(_stringMap(decoded));
    } on MissingPluginException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeBackgroundSync(bool enabled) async {
    final saved = await _channel.invokeMethod<bool>(
      'remote.sync.preferences.write',
      {'backgroundSync': enabled},
    );
    if (saved == false) {
      throw StateError('后台同步设置没有保存成功');
    }
  }

  @override
  Future<bool> consumeBatteryGuide() async {
    try {
      return await _channel.invokeMethod<bool>('remote.sync.guide.consume') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<String?> requestBatteryOptimization() async {
    try {
      return await _channel.invokeMethod<String>(
        'remote.sync.batteryOptimization.request',
      );
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<String?> openOemBackgroundSettings() async {
    try {
      return await _channel.invokeMethod<String>(
        'remote.sync.oem.backgroundSettings',
      );
    } on MissingPluginException {
      return null;
    }
  }

  static Map<String, dynamic> _stringMap(Map<dynamic, dynamic> value) =>
      value.map((key, value) => MapEntry('$key', value));
}

/// 页面需要的应用级连接宿主：共享连接 + 页面计数（不包含平台细节，便于测试替换）。
abstract class RemoteBackgroundConnectionHost {
  /// 取得应用级共享连接；页面不拥有、不释放它。
  RemoteConnectionController connection(RuntimeController runtime);

  /// 远程页面挂载：页面打开期间即使关闭「后台保持连接」也保持前台服务。
  void attachPage();

  /// 远程页面销毁：只在关闭「后台保持连接」时才停止服务/断开共享连接。
  void detachPage();
}

/// 应用级远程后台同步：持有跨页面共享的远程连接与主进程前台服务。
///
/// 生命周期（全部以「连接是否真的可用」为准，不冒充同步）：
///
/// - App 启动（[attach]，由 `main.dart` 在运行时启动后调用）或首次打开远程页
///   （[connection]）时，若「后台保持连接」开启且有已配对电脑，自动连接上次成功连接
///   的电脑（只有一台时连那一台），并在界面可见时启动前台服务；
/// - 连接 ready：启动前台服务、每 [heartbeatInterval] 心跳一次、请求一次通知权限、
///   首连时给一条一次性电池优化引导；
/// - 连接 failed/idle：停止前台服务并记录最后断开原因（不假装继续同步）；
/// - 页面销毁不再断开共享连接（「后台保持连接」开启时），只有用户移除电脑/关闭开关
///   才停止；
/// - 进程被系统杀死后，原生服务以 START_STICKY 重启并显示「点按恢复」；用户打开 App
///   后 [onAppResumed] 重新建连并让服务回到同步状态。
class RemoteBackgroundSync extends ChangeNotifier
    implements RemoteBackgroundConnectionHost {
  /// 创建协调器；生产使用 [instance]，测试可直接 `new` 并注入假平台。
  RemoteBackgroundSync({
    RemoteSyncPlatform? platform,
    RemoteNotificationPermission? notificationPermission,
    RemoteConnectionController Function(RuntimeController runtime)? createConnection,
    this.heartbeatInterval = const Duration(seconds: 25),
  }) : _platform = platform ?? MethodChannelRemoteSyncPlatform(),
       _notificationPermission =
           notificationPermission ?? MethodChannelRemoteNotificationPermission(),
       _createConnection = createConnection ?? _defaultConnection;

  /// App 全局共享实例（由 `main.dart` 启动 App 时 [attach]）。
  static final RemoteBackgroundSync instance = RemoteBackgroundSync();

  static RemoteConnectionController _defaultConnection(RuntimeController runtime) =>
      RemoteConnectionController(store: paired.RemoteDeviceStore(runtime: runtime));

  final RemoteSyncPlatform _platform;
  final RemoteNotificationPermission _notificationPermission;
  final RemoteConnectionController Function(RuntimeController) _createConnection;

  /// 心跳间隔；服务侧 90 秒没有心跳就降级为「点按恢复」通知。
  final Duration heartbeatInterval;

  RuntimeController? _runtime;
  RemoteConnectionController? _connection;
  bool _attached = false;
  bool _preferencesLoaded = false;
  bool _backgroundSyncEnabled = true;
  int _pageCount = 0;
  bool _userDisconnected = false;
  bool _serviceStarted = false;
  bool _restoring = false;
  bool _restoreScheduled = false;
  bool _guideChecked = false;
  bool _disposed = false;
  DateTime? _lastServiceRestartAt;
  String? _batteryGuideMessage;
  String? _lastDisconnectReason;
  String? _lastServiceError;
  String? _lastRestoreError;
  int _serviceStarts = 0;
  int _serviceStops = 0;
  Timer? _heartbeat;

  /// 共享连接控制器；页面通过 [connection] 取得，App 启动后由 [attach] 自动创建。
  RemoteConnectionController? get sharedConnection => _connection;

  /// 用户是否开启「后台保持与电脑的连接」（App 启动自动连接 + 页面关闭后继续同步）。
  bool get backgroundSyncEnabled => _backgroundSyncEnabled;

  /// Dart 侧是否认为前台服务已启动。
  bool get serviceStarted => _serviceStarted;

  /// 最近一次连接失败/断开的原因（界面与诊断展示）。
  String? get lastDisconnectReason => _lastDisconnectReason;

  @override
  RemoteConnectionController connection(RuntimeController runtime) {
    _runtime = runtime;
    var controller = _connection;
    if (controller == null) {
      controller = _createSharedConnection(runtime);
      unawaited(_restore(reason: 'page-open'));
    }
    return controller;
  }

  /// App 启动时挂上运行时：运行时就绪后按偏好恢复最近连接并启动服务。
  Future<void> attach(RuntimeController runtime) async {
    if (_attached) return;
    _attached = true;
    _runtime = runtime;
    runtime.addListener(_onRuntimeChanged);
    await _restore(reason: 'app-start');
  }

  /// App 回到前台：补心跳（服务可能停在「点按恢复」）并尝试恢复连接。
  Future<void> onAppResumed() async {
    if (_attached && _serviceStarted) {
      unawaited(_sendHeartbeat());
    }
    await _restore(reason: 'app-resumed');
    final controller = _connection;
    // 连接已经可用但服务启动曾经失败（例如 Android 12+ 前台启动限制）：
    // 回到前台时补一次启动，避免「界面在用时没有前台服务」的窗口。
    if (_attached &&
        _shouldRunService &&
        !_serviceStarted &&
        controller != null &&
        controller.phase != RemoteConnectionPhase.idle &&
        controller.phase != RemoteConnectionPhase.failed) {
      await _startService('app-resumed');
    }
  }

  /// 远程页面打开：关闭「后台保持连接」时也保持前台服务。
  @override
  void attachPage() {
    _pageCount++;
    final controller = _connection;
    if (controller != null &&
        _shouldRunService &&
        controller.phase != RemoteConnectionPhase.idle &&
        controller.phase != RemoteConnectionPhase.failed) {
      unawaited(_startService('page-open'));
    }
    _notify();
  }

  /// 远程页面销毁；共享连接与前台服务默认继续运行。
  @override
  void detachPage() {
    if (_pageCount > 0) _pageCount--;
    if (!_shouldRunService) {
      final controller = _connection;
      unawaited(_stopService('page-closed'));
      if (controller != null && controller.phase != RemoteConnectionPhase.idle) {
        // 用户明确关闭了「后台保持连接」：页面关闭后不再保留后台连接。
        unawaited(controller.disconnect());
      }
    }
    _notify();
  }

  /// 用户切换「后台保持与电脑的连接」。
  Future<void> setBackgroundSyncEnabled(bool enabled) async {
    _backgroundSyncEnabled = enabled;
    _preferencesLoaded = true;
    try {
      await _platform.writeBackgroundSync(enabled);
      _lastServiceError = null;
    } on Object catch (error) {
      _lastServiceError = '后台同步设置没有保存成功：$error';
    }
    if (enabled) {
      _userDisconnected = false;
      await _restore(reason: 'setting-enabled');
      final controller = _connection;
      if (controller != null &&
          controller.phase != RemoteConnectionPhase.idle &&
          controller.phase != RemoteConnectionPhase.failed) {
        await _startService('setting-enabled');
      }
    } else if (_pageCount == 0) {
      final controller = _connection;
      await _stopService('setting-disabled');
      if (controller != null && controller.phase != RemoteConnectionPhase.idle) {
        _userDisconnected = true;
        _lastDisconnectReason = '后台保持连接已关闭';
        await controller.disconnect();
      }
    }
    _notify();
  }

  /// 一次性电池优化引导：返回要展示的文案，只返回一次。
  ///
  /// 只做提示，不声称能解决 ANR/OEM 后台清理；用户拒绝后 `remote.sync.guide.consume`
  /// 已经消费，不会反复打扰。
  Future<String?> takeBatteryGuideNotice() async {
    final pending = _batteryGuideMessage;
    if (pending != null) {
      _batteryGuideMessage = null;
      return pending;
    }
    if (_guideChecked) return null;
    _guideChecked = true;
    try {
      final status = await _platform.status();
      if (status == null || status.batteryOptimizationsIgnored) return null;
      final first = await _platform.consumeBatteryGuide();
      if (!first) return null;
      const message =
          '后台同步提示：允许「电池优化豁免」可减少 Android 在后台冻结同步的机会，'
          '但不能绕过主线程无响应或厂商后台清理。可在 设置 → 后台保活 中调整。';
      return message;
    } on Object catch (error) {
      _log('battery guide unavailable: $error');
      return null;
    }
  }

  /// 请求系统电池优化豁免；返回平台模式说明，失败时抛出可展示的错误。
  Future<String> requestBatteryOptimization() async {
    final mode = await _platform.requestBatteryOptimization();
    _notify();
    return switch (mode) {
      'already-ignored' => '已经获得电池优化豁免',
      'request' => '已打开系统电池优化请求页，请选择「允许」',
      'list' => '已打开电池优化列表，请在列表里找到 Pocket Harness 并选择不限制',
      _ => '没有找到电池优化设置页，请在系统设置中手动查找',
    };
  }

  /// 打开厂商自启动/耗电管理页；返回可展示的说明。
  Future<String> openOemBackgroundSettings() async {
    final result = await _platform.openOemBackgroundSettings();
    _notify();
    if (result == null) {
      return '没有找到厂商后台设置页，请按设置页提示的路径手动查找';
    }
    if (result == 'app-details') {
      return '已打开应用详情页；请在「耗电管理 / 自启动」里手动允许后台活动';
    }
    return '已打开「$result」；名称与路径随手机和系统版本变化';
  }

  /// 读取诊断快照：原生服务状态 + 连接阶段 + 最后断开原因。
  Future<RemoteSyncDiagnostics> diagnostics() async {
    RemoteSyncServiceStatus? service;
    try {
      service = await _platform.status();
    } on Object catch (error) {
      _lastServiceError = '读取服务状态失败：$error';
    }
    final controller = _connection;
    return RemoteSyncDiagnostics(
      service: service,
      backgroundSyncEnabled: _backgroundSyncEnabled,
      pageOpen: _pageCount > 0,
      serviceRequested: _serviceStarted,
      serviceStarts: _serviceStarts,
      serviceStops: _serviceStops,
      heartbeatActive: _heartbeat != null,
      phase: controller?.phase,
      deviceLabel: controller?.activeDevice?.displayName,
      pairedDeviceCount: controller?.devices.length ?? 0,
      lastError: controller?.lastError,
      lastErrorCode: controller?.lastErrorCode,
      lastDisconnectReason: _lastDisconnectReason,
      lastServiceError: _lastServiceError,
      lastRestoreError: _lastRestoreError,
    );
  }

  /// 记录一次用户可见的断开原因（页面移除电脑等场景）。
  void recordDisconnectReason(String reason) {
    _lastDisconnectReason = reason;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    _runtime?.removeListener(_onRuntimeChanged);
    _connection?.removeListener(_onConnectionChanged);
    _connection?.dispose();
    super.dispose();
  }

  bool get _shouldRunService => _backgroundSyncEnabled || _pageCount > 0;

  RemoteConnectionController _createSharedConnection(RuntimeController runtime) {
    final controller = _createConnection(runtime);
    _connection = controller;
    controller.addListener(_onConnectionChanged);
    _log('shared connection created');
    return controller;
  }

  void _onRuntimeChanged() {
    final runtime = _runtime;
    if (runtime == null || !runtime.ready) return;
    unawaited(_restore(reason: 'runtime-ready'));
  }

  /// 按偏好恢复最近连接：App 启动、运行时就绪、回到前台与设置开启共用。
  Future<void> _restore({required String reason}) async {
    final runtime = _runtime;
    if (runtime == null || !runtime.ready) return;
    if (!_attached && _connection == null) return;
    if (_restoring) {
      _restoreScheduled = true;
      return;
    }
    _restoring = true;
    try {
      do {
        _restoreScheduled = false;
        await _loadPreferences();
        final controller = _connection ?? _createSharedConnection(runtime);
        if (!_shouldRunService) continue;
        if (controller.phase != RemoteConnectionPhase.idle) continue;
        if (_userDisconnected) continue;
        if (controller.devices.isEmpty) {
          try {
            await controller.loadDevices();
            _lastRestoreError = null;
          } on Object catch (error) {
            _lastRestoreError = '读取本机已配对电脑失败：$error';
            continue;
          }
        }
        final target =
            controller.lastConnectedDevice ??
            (controller.devices.length == 1 ? controller.devices.single : null);
        if (target == null) continue;
        await _startService(reason);
        _log('restore($reason): connecting ${target.displayName}');
        unawaited(controller.connect(target));
      } while (_restoreScheduled);
    } finally {
      _restoring = false;
    }
  }

  Future<void> _loadPreferences() async {
    if (_preferencesLoaded) return;
    _preferencesLoaded = true;
    try {
      final preferences = await _platform.readPreferences();
      if (preferences != null) _backgroundSyncEnabled = preferences.backgroundSync;
    } on Object catch (error) {
      // 偏好读取失败时保持默认开启：用户明确关闭过的设置会在下次读取时修正。
      _log('preferences unavailable: $error');
    }
  }

  /// 连接阶段变化：启动/停止前台服务，并记录最后断开原因。
  void _onConnectionChanged() {
    final controller = _connection;
    if (controller == null) return;
    switch (controller.phase) {
      case RemoteConnectionPhase.ready:
        _userDisconnected = false;
        _lastDisconnectReason = null;
        unawaited(_onConnectionReady());
      case RemoteConnectionPhase.failed:
        _lastDisconnectReason =
            '连接失败：${controller.lastError ?? controller.lastErrorCode ?? '未知原因'}';
        unawaited(_stopService('connection-failed'));
      case RemoteConnectionPhase.idle:
        unawaited(_stopService('connection-idle'));
      case RemoteConnectionPhase.connecting:
      case RemoteConnectionPhase.handshaking:
      case RemoteConnectionPhase.reconnecting:
      case RemoteConnectionPhase.lost:
        if (_shouldRunService) unawaited(_startService('connection-${controller.phase.name}'));
    }
    _notify();
  }

  Future<void> _onConnectionReady() async {
    _lastRestoreError = null;
    if (_shouldRunService) await _startService('connection-ready');
    await _notificationPermission.ensureRequested();
    _notify();
  }

  Future<void> _startService(String reason) async {
    if (_disposed || !_shouldRunService || _serviceStarted) return;
    _serviceStarted = true;
    _serviceStarts++;
    _startHeartbeat();
    try {
      final started = await _platform.start(reason);
      if (!started) {
        _serviceStarted = false;
        _stopHeartbeat();
        _lastServiceError = '系统没有接受后台同步服务启动';
      } else {
        _lastServiceError = null;
        _log('service started: $reason');
      }
    } on Object catch (error) {
      _serviceStarted = false;
      _stopHeartbeat();
      _lastServiceError = '后台同步服务启动失败：$error';
      _log('service start failed: $error');
    }
    _notify();
  }

  Future<void> _stopService(String reason) async {
    final wasStarted = _serviceStarted;
    _serviceStarted = false;
    _stopHeartbeat();
    if (!wasStarted) return;
    _serviceStops++;
    try {
      await _platform.stop(reason);
      _log('service stopped: $reason');
    } on Object catch (error) {
      _lastServiceError = '后台同步服务停止失败：$error';
    }
    _notify();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) => unawaited(_sendHeartbeat()));
    unawaited(_sendHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  Future<void> _sendHeartbeat() async {
    if (_disposed) return;
    try {
      final alive = await _platform.heartbeat();
      if (alive) return;
      // 服务实例不在（进程被系统重启后还没来得及重建）：重新启动，但按心跳间隔
      // 限流，避免原生侧持续不可用时每次心跳都重启服务。
      if (!_serviceStarted || !_shouldRunService) return;
      final now = DateTime.now();
      final last = _lastServiceRestartAt;
      if (last != null && now.difference(last) < heartbeatInterval) return;
      _lastServiceRestartAt = now;
      _serviceStarted = false;
      unawaited(_startService('heartbeat-restart'));
    } on Object catch (error) {
      _log('heartbeat failed: $error');
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[remote-sync] $message');
  }
}
