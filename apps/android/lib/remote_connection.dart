/// 远程 DSH 的连接控制：已配对电脑、单条连接的生命周期与握手方法表。
///
/// 这个类只做四件事，不碰 Widget、不解释业务方法：
///
/// 1. 持有 [RemoteDeviceStore]，把「已配对电脑」暴露给页面；
/// 2. 用 [RemoteRuntimeTransport] 建立 `wss://` 连接，把传输推来的
///    `remote.status` 与宿主的 `runtime.status` 映射成 [RemoteConnectionPhase]
///    （协议 §3.4、§7.2）；
/// 3. 把宿主的入站通知原样广播给页面（[events]），并按方法名计数，供页面决定
///    刷新时机；
/// 4. 关掉旧连接再开新连接，保证一次只有一条连接（协议 §11「多 PC 并发」不做）。
///
/// ## 什么时候算 ready
///
/// 握手（`protocol.hello`）成功只说明这条连接可以发请求，不代表 DSH 已经可用：
/// 协议 §3.4 要求宿主随后推 `runtime.status`，`phase == "ready"` 才是业务就绪。
/// 因此 [RemoteConnectionPhase.ready] 的判据是「握手完成 **且** 宿主 phase 为
/// ready」；宿主迟迟不发状态时，[defaultHostStatusTimeout] 之后进入 [failed] 并
/// 给出可展示的原因，而不是让页面永远转圈。
///
/// 宿主也用它自己的 `runtime.ready` 通知表达同一件事（同一个门面在初始化完成时
/// 发出）；这里把它与 `runtime.status.phase == "ready"` 视为同一信号。
///
/// ## 阶段与终止态
///
/// 传输层只会推出 `connecting` / `handshaking` / `ready` / `reconnecting` /
/// `lost` 五个阶段；本类额外区分 `idle`（没有连接）与 `failed`（终止态）。判定终止态
/// 的依据是错误码是否属于协议 §1.4 的「不自动重连」一类（认证失败、设备撤销、
/// 版本不匹配、正常关闭、帧超限、端点不存在、证书不受信任、握手超时）：这些情况下
/// 传输已经停止重连，界面必须给出「重新配对 / 重新连接」，而不是继续转圈。
///
/// 终止性失败后本类会主动 close 掉传输：它的 socket 已经关闭，但事件流要等
/// `close()` 才收敛，留着就是一条泄漏的订阅。
///
/// ## 切换电脑与失败语义
///
/// v1 同一时刻只保持一条连接（协议 §11），因此 [switchTo] 的动作是「先把旧连接
/// 彻底关掉，再连新的」。切换失败（新电脑不可达、令牌读不出来）不会退回旧连接：
/// 旧传输已经关闭，本类停在 [RemoteConnectionPhase.failed]，[activeDevice] 指向
/// 新电脑，页面据此显示这台电脑的错误与「重试」。
///
/// ## 记住上次成功连接的电脑
///
/// 每次进入 [RemoteConnectionPhase.ready] 都把设备与宿主自报的电脑名回写
/// [store]（[RemoteDeviceStore.markConnected]），供下次冷启动自动连接。回写失败
/// 只记录原因，不影响本次连接。
///
/// ## 设备令牌的读取限制
///
/// [RemoteDeviceStore.readToken] 的冷启动读取受凭据门面限制，失败原因由存储层
/// 解释，本类只把它的中文消息原样交给页面，绝不把「读不到令牌」伪装成「未配对」。
///
/// ## 生命周期
///
/// [dispose] 会关闭传输与 [events] 广播；页面持有本类时必须由创建方调用
/// [dispose]，否则连接不会随页面销毁而断开。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'remote_device_store.dart';
import 'remote_native_bridge.dart';
import 'remote_transport.dart';
import 'runtime_transport.dart';

/// 远程连接所处的阶段。
///
/// `connecting` / `handshaking` / `ready` / `reconnecting` / `lost` 与传输层
/// `remote.status.params.phase` 一一对应；`idle` 表示还没有发起连接，`failed`
/// 表示终止态（不会再自动重连）。
enum RemoteConnectionPhase {
  /// 没有连接：初始状态，或调用 [RemoteConnectionController.disconnect] 之后。
  idle,

  /// 正在拨号建立 `wss://` 连接。
  connecting,

  /// 已连上，正在发 `protocol.hello` 并等宿主的方法表。
  handshaking,

  /// 握手完成，可以发业务请求。
  ready,

  /// 连接断开，传输正在按退避重连（协议 §7.2）。
  reconnecting,

  /// 连接丢失且传输没有继续重连。
  lost,

  /// 终止态：认证失败、设备撤销、版本不匹配等，只有用户动作才能恢复。
  failed,
}

/// 创建远程传输的工厂。
///
/// 参数就是 [RemoteRuntimeTransport] 的构造签名里决定「连哪台电脑」的那部分；
/// 返回值是 [RemoteTransportLink]，测试可以注入一个不拨号的实现，因此本类不直接
/// 依赖 `dart:io`。
typedef RemoteTransportFactory = RemoteTransportLink Function({
  required String endpoint,
  required String token,
  required String pinnedCaPem,
  required String deviceLabel,
  required String appVersion,
  required List<String> capabilities,
});

/// 远程 DSH 的连接控制器。
///
/// 页面通过 [addListener] 订阅状态变化，读 [devices] 渲染设备胶囊条、读 [phase]
/// 决定空态、读 [transport] 发门面请求。所有连接动作都是异步的，失败不会抛给
/// 调用方，而是写进 [lastError] 并把 [phase] 推到 `failed`。
class RemoteConnectionController extends ChangeNotifier {
  /// 创建控制器。
  ///
  /// [store] 提供已配对电脑与设备令牌；[appVersion] 进入
  /// `protocol.hello.params.appVersion`，只用于宿主展示与排障（协议 §3.1）；
  /// [capabilities] 是客户端能力声明，v1 只有 `window-ack`（协议 §10.3）。
  /// [createTransport] 只给测试替换传输实现；[hostStatusTimeout] 是握手完成后等待
  /// 宿主 `runtime.status` 的时限（协议 §3.4）。
  RemoteConnectionController({
    required this.store,
    this.appVersion = defaultRemoteAppVersion,
    List<String> capabilities = const <String>['window-ack'],
    this.hostStatusTimeout = defaultHostStatusTimeout,
    RemoteTransportFactory? createTransport,
  }) : _capabilities = List<String>.unmodifiable(capabilities),
       _createTransport = createTransport ?? _createDefaultTransport {
    if (hostStatusTimeout <= Duration.zero) {
      throw ArgumentError.value(
        hostStatusTimeout,
        'hostStatusTimeout',
        '必须大于 0',
      );
    }
  }

  /// 默认上报的 App 版本号。
  ///
  /// 握手里的 `appVersion` 只用于宿主展示与排障（协议 §3.1），因此这里给一个固定
  /// 值而不是再去读一次 `app.metadata`：读通道失败会把一次正常连接挡在门外。
  static const String defaultRemoteAppVersion = '0.1.0';

  /// 握手完成后等待宿主进入 ready 的默认时限。
  ///
  /// 宿主在握手后要初始化库、交互与网络恢复，正常远快于这个时限；超过它仍没有
  /// `runtime.status`，说明宿主侧初始化卡住或没接门面，必须展示原因而不是继续等。
  static const Duration defaultHostStatusTimeout = Duration(seconds: 15);

  /// 终止态错误码，与协议 §1.4「不自动重连」的一类一致。
  ///
  /// 传输层已经把这些码包装成自己的终止态（socket 关闭、不再重连），本类据此把
  /// `lost` 提升成 `failed`，让界面给出「重新连接 / 重新配对」而不是无限转圈。
  /// `remote/tls`、`remote/handshake-timeout` 是客户端侧判定的终止态：证书不受
  /// 信任、宿主不回握手都属于「重试同一个动作不会变好」。
  static const Set<String> terminalCodes = <String>{
    'auth-failed',
    'auth-revoked',
    'protocol-mismatch',
    'remote/closed',
    'remote/frame-too-large',
    'remote/handshake-timeout',
    'remote/not-found',
    'remote/origin-rejected',
    'remote/tls',
  };

  /// 已配对电脑与本机设备令牌的来源。
  final RemoteDeviceStore store;

  /// 进入 `protocol.hello.params.appVersion` 的 App 版本号（仅供宿主排障）。
  final String appVersion;

  /// 握手完成后等待宿主 `runtime.status` 的时限。
  final Duration hostStatusTimeout;

  final List<String> _capabilities;
  final RemoteTransportFactory _createTransport;

  List<RemoteDevice> _devices = const <RemoteDevice>[];
  RemoteDevice? _activeDevice;
  RemoteConnectionPhase _phase = RemoteConnectionPhase.idle;
  String? _lastError;
  String? _lastErrorCode;
  String? _deviceListError;
  String? _lastConnectedDeviceId;
  String? _recordedConnectedDeviceId;
  RemoteHostInfo? _host;
  RemoteTransportLink? _transport;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 入站帧的广播出口（传输层的 [RuntimeTransport.events] 是单订阅，已被本类占用）。
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// 非状态通知按方法名的累计次数（本次连接内）。
  final Map<String, int> _notificationCounts = <String, int>{};
  String? _lastNotificationMethod;
  bool _listenerNotifyScheduled = false;

  /// 握手是否已完成（等价于传输层的 `ready` 阶段）。
  bool _handshakeComplete = false;

  /// 宿主是否已经报过 ready（`runtime.status.phase == "ready"` 或 `runtime.ready`）。
  bool _hostReady = false;

  /// 宿主最近一次上报的阶段，用于超时提示。
  String? _hostPhase;

  /// 等待宿主 ready 的超时计时器。
  Timer? _hostStatusTimer;

  /// 连接代际：每次 connect / disconnect 递增，用来作废迟到的手握结果与事件。
  int _generation = 0;
  bool _disposed = false;

  /// 已配对电脑；读取失败时保留上一次成功读到的列表。
  List<RemoteDevice> get devices => _devices;

  /// 上次成功连接的电脑；从未成功连接过时为 null。
  ///
  /// 记录由 [RemoteDeviceStore] 持久化，冷启动读完设备表后即可用；每次进入
  /// [RemoteConnectionPhase.ready] 由本类回写。首页用它决定自动连接哪一台。
  RemoteDevice? get lastConnectedDevice {
    final id = _lastConnectedDeviceId;
    if (id == null) return null;
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// 当前连接（或最近一次连接）的电脑；[disconnect] 之后为 null。
  RemoteDevice? get activeDevice => _activeDevice;

  /// 连接阶段。
  RemoteConnectionPhase get phase => _phase;

  /// 最近一次失败的可展示中文说明；没有失败时为 null。
  ///
  /// 内容直接来自传输层的 `message`（协议 §9.4 已经组装好），本类不拼接前缀。
  String? get lastError => _lastError;

  /// [lastError] 对应的错误码（`auth-failed` 等）；没有时为 null。
  String? get lastErrorCode => _lastErrorCode;

  /// 最近一次读取设备列表失败的可展示中文说明；读取成功时为 null。
  String? get deviceListError => _deviceListError;

  /// 传输层暴露给页面的请求入口；未连接或终止态之后为 null。
  RuntimeTransport? get transport => _transport;

  /// 门面推来的全部入站帧，形态与 [RuntimeTransport.events] 一致：
  /// `{'method': String, 'params': Map}`，包含 `remote.status`、`api.stream`、
  /// `session.event` 与全部 `remote.*`。
  ///
  /// 广播流：传输层的 `events` 是单订阅且已被本类占用，页面要直接消费入站帧时
  /// 订阅这里。帧原样转发，不展开 `api.stream`、不改写 `params`，订阅方自己按
  /// `method` 分流。没有订阅者时不做缓存（不重放），也不影响本类自己的状态处理；
  /// [dispose] 之后流结束。
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 最近一条非状态通知的方法名；还没有收到过时为 null。
  String? get lastNotificationMethod => _lastNotificationMethod;

  /// 某个方法名的非状态通知累计次数（本次连接内；`remote.status` 不计入）。
  int notificationCount(String method) => _notificationCounts[method] ?? 0;

  /// 全部非状态通知的方法名与累计次数（不可变快照）。
  Map<String, int> get notificationCounts =>
      Map<String, int>.unmodifiable(_notificationCounts);

  /// 宿主最近一次上报的阶段（`runtime.status.params.phase`）；未知时为 null。
  String? get hostPhase => _hostPhase;

  /// 最近一次成功握手得到的宿主身份、方法表与能力（协议 §3.2）。
  ///
  /// 每次重连都会重新握手并覆盖这个值（协议 §7.2 第 3 步）；未握手成功时为 null。
  RemoteHostInfo? get host => _host;

  /// 是否已经可以发业务请求。
  ///
  /// 只有「握手完成 + 宿主 phase 为 ready」才为 true（协议 §3.4）：握手成功还不够，
  /// 宿主的门面可能仍在初始化。
  bool get isReady => _phase == RemoteConnectionPhase.ready;

  /// 宿主是否支持某个门面方法（协议 §10.1、§10.2）。
  ///
  /// 先看 `unsupported`（覆盖即不支持），再看 `methods` 里的精确名或 `.*` 前缀；
  /// 判定完全复用 [RemoteHostInfo.supports]。尚未握手成功时一律返回 false：方法表
  /// 只来自握手，不能缓存跨连接（协议 §10.1）。
  bool supports(String method) => _host?.supports(method) ?? false;

  /// 重新读取已配对电脑与「上次成功连接的设备」。
  ///
  /// 读取失败不降级成空列表：失败会写进 [deviceListError] 并抛出，由调用方决定是
  /// 展示错误，还是把「本机还没有设备表」当成空列表。
  Future<List<RemoteDevice>> loadDevices() async {
    try {
      final table = await store.loadTable();
      if (_disposed) return _devices;
      // 只有设备表真的变了才通知：页面把本方法当作「刷新」调用，无条件通知会让
      // 监听者再触发一次刷新，形成自我维持的读取循环。
      final changed =
          _deviceListError != null || !_sameDeviceTable(table.devices);
      _devices = List<RemoteDevice>.unmodifiable(table.devices);
      _lastConnectedDeviceId = table.lastConnectedDeviceId;
      _deviceListError = null;
      if (changed) _notify();
      return _devices;
    } on Object catch (error) {
      if (!_disposed) {
        final message = _messageOf(error);
        if (_deviceListError != message) {
          _deviceListError = message;
          _notify();
        }
      }
      rethrow;
    }
  }

  /// 连接到 [device]。
  ///
  /// 已连接到同一台电脑且连接还在进行中时是空操作；其余情况先干净断开旧连接再连
  /// 新的（协议 §11：一次只连一台）。失败不抛异常：原因写进 [lastError]，阶段推到
  /// [RemoteConnectionPhase.failed]；此时 [activeDevice] 是要连的那台电脑，
  /// [transport] 为 null。
  ///
  /// 顺序是刻意的：先作废代际并切到 `connecting`，再关闭旧传输。关闭要等 socket
  /// 收敛，期间页面不能继续显示 `ready`；代际提前递增还能让旧握手/旧事件在关闭
  /// 过程中就被丢弃。
  Future<void> connect(RemoteDevice device) async {
    if (_disposed) return;
    if (_activeDevice?.id == device.id && _inFlight) return;
    final generation = ++_generation;
    _activeDevice = device;
    _lastError = null;
    _lastErrorCode = null;
    _setPhase(RemoteConnectionPhase.connecting);
    await _closeTransport();
    if (_disposed || generation != _generation) return;

    final String token;
    try {
      token = await store.readToken(device);
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      _fail(_messageOf(error), _codeOf(error));
      return;
    }
    if (_disposed || generation != _generation) return;

    final RemoteTransportLink transport;
    try {
      transport = _createTransport(
        endpoint: device.appEndpoint.toString(),
        token: token,
        pinnedCaPem: device.caPem,
        deviceLabel: device.label,
        appVersion: appVersion,
        capabilities: _capabilities,
      );
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      // CA 无法解析、端点非法等构造期失败：不会自己恢复，直接进终止态。
      _fail(_messageOf(error), _codeOf(error));
      return;
    }
    if (_disposed || generation != _generation) {
      unawaited(transport.close());
      return;
    }

    _transport = transport;
    // 反向请求（宿主 → App）挂在整条连接上：只应答 `native.attachments.read`，
    // 其余方法由处理器抛 UnsupportedError，传输层回 -32601（协议 §5.3）。
    // 重连时换一条传输，处理器随之重新安装；旧传输由本类关闭。
    RemoteNativeBridge.instance.install(transport);
    _subscription = transport.events.listen(
      (event) => _onTransportEvent(generation, event),
      onError: (Object error) {
        if (_disposed || generation != _generation) return;
        _fail(_messageOf(error), _codeOf(error));
      },
    );
    // 握手成功只代表「可以发请求」，业务是否就绪仍以 runtime.status 为准（协议
    // §3.4）；这里先把方法表拿下来，供页面判断入口可见性。
    unawaited(
      transport.handshake.then<void>(
        (info) {
          if (_disposed || generation != _generation) return;
          if (identical(_host, info)) return;
          _host = info;
          _notify();
        },
        onError: (Object error) {
          if (_disposed || generation != _generation) return;
          _fail(_messageOf(error), _codeOf(error));
        },
      ),
    );
    // 阶段以传输推来的 remote.status 为准；这里补一次当前值，避免订阅建立之前
    // 已经发出的首帧仍然停留在上一阶段。
    _applyTransportStatus(transport.phase);
  }

  /// 切换到另一台电脑：先干净断开当前连接，再连新的。
  ///
  /// 与 [connect] 的实际动作相同（[connect] 已经包含「断开旧连接」），保留独立名字
  /// 是为了让页面代码读起来是「换一台」而不是「连一台」。切换没有回退路径：新电脑
  /// 连不上时停在 [RemoteConnectionPhase.failed]，[activeDevice] 是新电脑，
  /// [lastError] 是它的失败原因，页面据此给出「重试 / 切换设备」。
  Future<void> switchTo(RemoteDevice device) => connect(device);

  /// 断开当前连接并回到 `idle`。
  ///
  /// 幂等：没有连接时只清空状态。断开之后 [transport] 为 null，页面不必再判断
  /// 传输是否已关闭。
  Future<void> disconnect() async {
    if (_disposed) return;
    _generation++;
    await _closeTransport();
    if (_disposed) return;
    final changed =
        _activeDevice != null ||
        _phase != RemoteConnectionPhase.idle ||
        _lastError != null;
    _activeDevice = null;
    _lastError = null;
    _lastErrorCode = null;
    _phase = RemoteConnectionPhase.idle;
    if (changed) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _hostStatusTimer?.cancel();
    _hostStatusTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final transport = _transport;
    _transport = null;
    _host = null;
    final cancelled = subscription?.cancel();
    if (cancelled != null) unawaited(cancelled);
    final closing = transport?.close();
    if (closing != null) unawaited(closing);
    if (!_events.isClosed) unawaited(_events.close());
    super.dispose();
  }

  bool get _inFlight =>
      _phase == RemoteConnectionPhase.connecting ||
      _phase == RemoteConnectionPhase.handshaking ||
      _phase == RemoteConnectionPhase.ready ||
      _phase == RemoteConnectionPhase.reconnecting;

  /// 两次读取得到的设备表在界面上是否等价。
  ///
  /// 只比较展示用得到的字段：存储层每次 `load()` 都会返回新对象实例，用 `identical`
  /// 比较会把「没变化」误判成变化。
  bool _sameDeviceTable(List<RemoteDevice> next) {
    if (next.length != _devices.length) return false;
    for (var index = 0; index < next.length; index++) {
      final left = next[index];
      final right = _devices[index];
      if (left.id != right.id || left.label != right.label) return false;
      if (left.lastSeenAt != right.lastSeenAt) return false;
      // 电脑名决定胶囊条与副标题上的文字，变化必须让页面重建。
      if (left.hostName != right.hostName) return false;
    }
    return true;
  }

  /// 关闭传输：先摘掉事件订阅，再关闭连接，最后清空宿主信息。
  ///
  /// 顺序固定：先取消订阅，[RemoteRuntimeTransport.close] 期间推来的 `lost` 帧才
  /// 不会被当成本次会话的状态变化。
  Future<void> _closeTransport() async {
    // 同步重置：第一个 await 之前后续事件与超时计时器就必须看不到旧一代的状态。
    _hostStatusTimer?.cancel();
    _hostStatusTimer = null;
    _handshakeComplete = false;
    _hostReady = false;
    _hostPhase = null;
    _notificationCounts.clear();
    _lastNotificationMethod = null;
    _recordedConnectedDeviceId = null;
    final subscription = _subscription;
    _subscription = null;
    final transport = _transport;
    _transport = null;
    _host = null;
    final cancelled = subscription?.cancel();
    if (cancelled != null) await cancelled;
    if (transport != null) {
      try {
        await transport.close();
      } on Object catch (error) {
        // 关闭只做清理：socket 已经随关闭码收敛，没有可恢复的动作，
        // 因此只记录原因，不覆盖调用方正在展示的失败。
        debugPrint('关闭远程传输时出错：$error');
      }
    }
  }

  /// 入站帧的唯一入口：先转发给页面，再处理本类自己的状态。
  ///
  /// 转发必须发生在所有 early return 之前：页面靠 [events] 消费 `api.stream` 与
  /// `session.event`，这些帧对 controller 没有状态含义，但对页面有。
  void _onTransportEvent(int generation, Map<String, dynamic> event) {
    if (_disposed || generation != _generation) return;
    if (!_events.isClosed) _events.add(event);
    final method = event['method'];
    if (method is! String || method.isEmpty) return;
    final params = event['params'];
    final payload = params is Map<String, dynamic>
        ? params
        : const <String, dynamic>{};
    switch (method) {
      case 'remote.status':
        _applyTransportStatus(
          payload['phase'],
          code: _errorCodeOf(payload['error']),
          message: _errorMessageOf(payload['error']),
        );
      case 'runtime.status':
        _applyHostStatus(payload);
      case 'runtime.ready':
        // 同一门面在初始化完成时发的通知；与 runtime.status.phase == "ready"
        // 是同一个事实，两端口径都要认。
        _markHostReady();
      case 'remote.deviceRevoked':
        // 协议 §8.4：收到即把该 PC 置为「已撤销、需重新配对」，忽略随后的关闭原因。
        _recordNotification(method);
        _fail('这台手机已被电脑撤销授权。请在电脑上重新配对。', 'auth-revoked');
      default:
        _recordNotification(method);
    }
  }

  void _recordNotification(String method) {
    _lastNotificationMethod = method;
    _notificationCounts[method] = (_notificationCounts[method] ?? 0) + 1;
    // 合并通知：宿主可能在一次 socket 读取里连续推多条帧（`session.event` 按 token
    // 到达），逐条 notifyListeners 会让页面每帧重建。计数已在上面的 map 里，监听者
    // 收到一次通知后即可读到全部最新值。
    if (_listenerNotifyScheduled || _disposed) return;
    _listenerNotifyScheduled = true;
    scheduleMicrotask(() {
      _listenerNotifyScheduled = false;
      if (!_disposed) _notify();
    });
  }

  static String? _errorCodeOf(Object? raw) {
    if (raw is! Map) return null;
    final code = raw['code'];
    return code is String && code.isNotEmpty ? code : null;
  }

  static String? _errorMessageOf(Object? raw) {
    if (raw is! Map) return null;
    final message = raw['message'];
    return message is String && message.trim().isNotEmpty ? message : null;
  }

  /// 把传输层阶段映射成本类阶段。
  ///
  /// 注意 `ready` 只代表握手完成（协议 §3.4 明确「握手成功不等于可用的 App」）：
  /// 还要等宿主报 ready，本类才进入 [RemoteConnectionPhase.ready]。
  void _applyTransportStatus(String? phase, {String? code, String? message}) {
    switch (phase) {
      case 'connecting':
        _resetHostReadiness();
        _setPhase(RemoteConnectionPhase.connecting);
      case 'handshaking':
        _resetHostReadiness();
        _setPhase(RemoteConnectionPhase.handshaking);
      case 'ready':
        final host = _transport?.host;
        if (host != null) _host = host;
        _lastError = null;
        _lastErrorCode = null;
        _handshakeComplete = true;
        if (_hostReady) {
          _cancelHostStatusTimer();
          _setPhase(RemoteConnectionPhase.ready);
        } else {
          // 握手完成、等宿主 phase：保持 handshaking，并给这个等待设上限。
          _setPhase(RemoteConnectionPhase.handshaking);
          _armHostStatusTimer();
        }
      case 'reconnecting':
        _resetHostReadiness();
        // 重连期间保留原因：断网与限流都是可展示的中文句子。
        _lastError = message;
        _lastErrorCode = code;
        _setPhase(RemoteConnectionPhase.reconnecting);
      case 'lost':
        _resetHostReadiness();
        if (code != null && terminalCodes.contains(code)) {
          _fail(message ?? _defaultFailureMessage(code), code);
          return;
        }
        _lastError = message;
        _lastErrorCode = code;
        _setPhase(RemoteConnectionPhase.lost);
      default:
        // 协议层忽略不认识的阶段（协议 §0 第 4 条）；不改状态。
        break;
    }
  }

  /// 处理宿主的阶段协议（协议 §3.4）：`phase == "ready"` 才算业务就绪。
  void _applyHostStatus(Map<String, dynamic> params) {
    final phase = params['phase'];
    if (phase is! String || phase.isEmpty) return;
    _hostPhase = phase;
    switch (phase) {
      case 'ready':
        _markHostReady();
      case 'failed':
        final detail = params['error'];
        final message = detail is String && detail.trim().isNotEmpty
            ? '电脑上的 DSH 启动失败：$detail'
            : '电脑上的 DSH 启动失败，无法继续使用这台电脑。请查看电脑上的日志后重新连接。';
        _fail(message, 'remote/host-failed');
      default:
        // `starting` 等未就绪阶段：继续等，超时由 [_hostStatusTimer] 兜底。
        break;
    }
  }

  void _markHostReady() {
    if (_disposed) return;
    if (_hostReady) {
      // 宿主可能既推 runtime.ready 又推 runtime.status(ready)：只处理第一次。
      return;
    }
    _hostReady = true;
    _cancelHostStatusTimer();
    if (_handshakeComplete) _setPhase(RemoteConnectionPhase.ready);
  }

  /// 重置「宿主已就绪」这条状态：连接换代之后旧连接的就绪不再成立。
  void _resetHostReadiness() {
    _cancelHostStatusTimer();
    _handshakeComplete = false;
    _hostReady = false;
    _hostPhase = null;
  }

  void _armHostStatusTimer() {
    _cancelHostStatusTimer();
    _hostStatusTimer = Timer(hostStatusTimeout, () {
      _hostStatusTimer = null;
      if (_disposed || _phase == RemoteConnectionPhase.ready) return;
      final observed = _hostPhase == null
          ? '一直没有收到电脑的就绪通知'
          : '电脑当前的阶段是「$_hostPhase」';
      _fail(
        '已连上电脑，但 DSH 在 ${hostStatusTimeout.inSeconds} 秒内没有进入就绪状态'
            '（$observed）。请确认电脑上的 DSH 已启动完成，然后重新连接。',
        'remote/status-timeout',
      );
    });
  }

  void _cancelHostStatusTimer() {
    _hostStatusTimer?.cancel();
    _hostStatusTimer = null;
  }

  /// 进入终止态并关掉传输。
  void _fail(String message, String? code) {
    if (_disposed) return;
    _lastError = message;
    _lastErrorCode = code;
    _setPhase(RemoteConnectionPhase.failed);
    unawaited(_closeTransport());
  }

  void _setPhase(RemoteConnectionPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    _notify();
    // 进入 ready 是唯一一次「这台电脑确实连上了」的信号：记下它，供下次冷启动
    // 自动连接。回写是异步的，失败不会改变本次连接的阶段。
    if (phase == RemoteConnectionPhase.ready) _rememberConnectedDevice();
  }

  /// 把当前连接成功的电脑回写进设备表（上次连接 + 电脑名 + 最近在线时间）。
  ///
  /// 同一条连接内只回写一次：重连（`lost → reconnecting → ready`）不重复写偏好；
  /// 换代（[connect] / [disconnect]）会清掉记录标记，切到另一台电脑后重新回写。
  void _rememberConnectedDevice() {
    final device = _activeDevice;
    if (device == null) return;
    if (_recordedConnectedDeviceId == device.id) return;
    _recordedConnectedDeviceId = device.id;
    final hostName = _host?.name;
    unawaited(_recordConnectedDevice(device.id, hostName));
  }

  Future<void> _recordConnectedDevice(String deviceId, String? hostName) async {
    try {
      final table = await store.markConnected(deviceId, hostName: hostName);
      if (_disposed) return;
      _lastConnectedDeviceId = table.lastConnectedDeviceId;
      if (!_sameDeviceTable(table.devices)) {
        _devices = List<RemoteDevice>.unmodifiable(table.devices);
        _notify();
      }
    } on Object catch (error) {
      // 记录「上次连接」只是下次冷启动的便利提示：写偏好失败不影响本次连接。
      debugPrint('记录上次连接的电脑失败：$error');
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  static String _defaultFailureMessage(String code) {
    switch (code) {
      case 'auth-failed':
        return '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。';
      case 'auth-revoked':
        return '这台手机已被电脑撤销授权。请在电脑上重新配对。';
      case 'protocol-mismatch':
        return '协议版本不匹配。请把两端升级到同一版本。';
      case 'remote/frame-too-large':
        return '请求过大，电脑已关闭连接。请缩小请求范围后重新连接。';
      case 'remote/handshake-timeout':
        return '已连上电脑，但电脑没有在 10 秒内完成握手。请确认电脑上的 DSH 版本与手机一致，然后重试。';
      case 'remote/host-failed':
        return '电脑上的 DSH 启动失败，无法继续使用这台电脑。请查看电脑上的日志后重新连接。';
      case 'remote/not-found':
        return '连接地址不正确：电脑上没有 /app 端点。请检查电脑上的远程 DSH 是否已开启。';
      case 'remote/origin-rejected':
        return '连接被拒绝：电脑不接受的客户端来源。请确认 App 与电脑上的 DSH 版本一致。';
      case 'remote/closed':
        return '与电脑的连接已正常关闭，不会自动重连。';
      case 'remote/status-timeout':
        return '已连上电脑，但 DSH 没有进入就绪状态。请确认电脑上的 DSH 已启动完成，然后重新连接。';
      case 'remote/tls':
        return '无法验证电脑的 TLS 证书：固定的 CA 与电脑出示的证书不匹配。请重新配对这台电脑。';
      default:
        return '没能连接到这台电脑，请检查网络后重试。';
    }
  }

  static String _messageOf(Object error) {
    if (error is RuntimeTransportFailure) return error.message;
    if (error is RemoteDeviceStoreException) return error.message;
    if (error is FormatException) return error.message;
    if (error is ArgumentError) return '${error.message}';
    return '$error';
  }

  static String? _codeOf(Object error) {
    if (error is RuntimeTransportFailure) return error.code;
    if (error is RemoteDeviceStoreException) return error.code;
    return null;
  }
}

/// 默认传输工厂：直接构造 [RemoteRuntimeTransport]。
RemoteRuntimeTransport _createDefaultTransport({
  required String endpoint,
  required String token,
  required String pinnedCaPem,
  required String deviceLabel,
  required String appVersion,
  required List<String> capabilities,
}) => RemoteRuntimeTransport(
  endpoint: endpoint,
  token: token,
  pinnedCaPem: pinnedCaPem,
  deviceLabel: deviceLabel,
  appVersion: appVersion,
  capabilities: capabilities,
);
