/// 远程 DSH 的 Dart 传输实现：用 `wss://` 连接 PC 上的 DSH 宿主。
///
/// 这条传输复用本地模式完全相同的门面方法表与帧格式：换行分隔的 JSON-RPC 2.0
/// （契约见 `docs/remote-dsh/protocol.md`）。传输层只做四件事：
///
/// 1. 拨号与 TLS 固定：只信任配对时固定的 CA，不信任系统根证书；
/// 2. 握手：连接建立后的第一帧是 `protocol.hello`，结果暴露为 [handshake]；
/// 3. 帧编解码：请求 / 响应 / 通知三分流，反向请求交给 [setRequestHandler]；
/// 4. 重连：指数退避加抖动，每次重连重新握手，断线期间 [events] 不关闭。
///
/// ## TLS 固定为什么不比对证书指纹
///
/// `dart:convert` 没有 SHA-256，手工比对指纹要么再引入一个加密依赖，要么自己写
/// DER 解析与十六进制比对——两条路都比「把固定 CA 装进独立信任库」更容易写错。
/// 这里使用 `SecurityContext(withTrustedRoots: false)` 加
/// `setTrustedCertificatesBytes`：系统根证书被完全排除，只有调用方传入的那张 CA
/// 能签出被接受的证书；证书链、有效期与主机名校验仍由 BoringSSL 执行，也没有
/// 打开 `badCertificateCallback` 这类「先接受再判断」的口子。
///
/// 代价是固定粒度是「这张 CA 签发的证书」，Dart 层无法再比对 CA 的 SHA-256 是否
/// 等于 `instanceId`。那一步由配对流程（P3）在写入 CA 之前完成；本传输只信任
/// 调用方交给它的 PEM。若 PEM 不是配对得到的 CA，握手会失败，并给出 `remote/tls`
/// 失败码。
///
/// ## 心跳与「40 秒无帧」
///
/// `dart:io` 不把 WebSocket 的 ping/pong 控制帧暴露给应用层，因此不能靠「最后一条
/// 数据帧的时间」判断存活——安静的 `ready` 连接本来就可能 40 秒没有业务帧。这里
/// 依赖 `pingInterval = 20s`：客户端每 20 秒发一次 ping，并在下一个 20 秒内等待
/// pong；两个 ping 周期（40 秒）都没有回应时，底层以 1001 关闭连接，重连循环据此
/// 重连。服务端发来的 ping 由 `dart:io` 自动回 pong，所以两个方向都被覆盖。
///
/// ## 明确不做
///
/// 二进制帧、`permessage-deflate`（协议 §11 关闭）、连接级续传（协议 §7.1）、
/// 多宿主并发。`notify` 只在握手完成后发送；握手前或断线期间调用会被静默丢弃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'runtime_transport.dart';

/// 一次成功握手得到宿主身份、可用方法表与能力声明（协议 §3.2）。
///
/// 字段名与线上字段一一对应：`host` 对象在线上是嵌套的，这里摊平成 [name]、
/// [platform]、[home]，避免调用方反复做 `Map` 取值。
class RemoteHostInfo {
  /// 创建一份宿主信息；列表字段会复制为不可变列表。
  RemoteHostInfo({
    required this.protocolVersion,
    required this.name,
    required this.platform,
    required this.home,
    required List<String> methods,
    required List<String> unsupported,
    required List<String> capabilities,
  }) : methods = List<String>.unmodifiable(methods),
       unsupported = List<String>.unmodifiable(unsupported),
       capabilities = List<String>.unmodifiable(capabilities);

  /// 宿主实现的协议版本；v1 恒为 `1`。
  final int protocolVersion;

  /// 宿主显示名（协议 `host.name`），可直接展示。
  final String name;

  /// 宿主平台：`win32` / `darwin` / `linux`（协议 `host.platform`）。
  final String platform;

  /// 宿主 DSH 主目录绝对路径（协议 `host.home`），只用于展示与排障。
  final String home;

  /// 宿主可应答的方法清单，条目可以是精确名或 `.*` 结尾的前缀（协议 §10.1）。
  final List<String> methods;

  /// 宿主明确不支持的方法清单；优先级高于 [methods]（协议 §10.1）。
  final List<String> unsupported;

  /// 宿主能力声明；v1 只定义 `window-ack`（协议 §10.3）。
  final List<String> capabilities;

  /// 按协议 §10.1 判断宿主是否支持某个方法。
  ///
  /// 先匹配 [unsupported]（覆盖即不支持），再匹配 [methods]；前缀只认 `.*`
  /// 结尾，其它形态按字面量处理，不做额外解释。
  bool supports(String method) {
    for (final pattern in unsupported) {
      if (_matches(pattern, method)) return false;
    }
    for (final pattern in methods) {
      if (_matches(pattern, method)) return true;
    }
    return false;
  }

  /// 是否声明了某个能力（例如 `window-ack`）。
  bool declares(String capability) => capabilities.contains(capability);

  /// 还原成线上 `protocol.hello` 的 `result` 形态，供 `remote.status` 帧携带。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocolVersion': protocolVersion,
    'host': <String, dynamic>{'name': name, 'platform': platform, 'home': home},
    'methods': methods,
    'unsupported': unsupported,
    'capabilities': capabilities,
  };

  static bool _matches(String pattern, String method) {
    if (pattern.endsWith('.*')) {
      return method.startsWith(pattern.substring(0, pattern.length - 1));
    }
    return pattern == method;
  }

  @override
  String toString() =>
      'RemoteHostInfo($name, $platform, v$protocolVersion, '
      '${methods.length} methods)';
}

/// 远程传输对连接控制器暴露的完整表面。
///
/// 在 [RuntimeTransport] 的收发原语之上补两件事：握手结果（方法表与能力）与连接
/// 阶段。分开成接口是为了让 `RemoteConnectionController` 的阶段机可以脱离真实
/// socket 被单元测试驱动，同时页面仍然只依赖 [RuntimeTransport] 那几个原语。
abstract interface class RemoteTransportLink implements RuntimeTransport {
  /// 首次成功握手的结果；终止性失败或 [RuntimeTransport.close] 时以错误完成。
  Future<RemoteHostInfo> get handshake;

  /// 最近一次成功握手得到的宿主信息；尚未握手成功时为 null。
  RemoteHostInfo? get host;

  /// 传输层阶段：`connecting` / `handshaking` / `ready` / `reconnecting` / `lost`。
  String get phase;

  /// 是否已调用过 [RuntimeTransport.close]。
  bool get isClosed;
}

/// 一次进行中的 WebSocket 拨号。
///
/// 单独成类是为了给拨号超时一个最小可注入点：测试可以返回一个永不完成的
/// [socket]，并断言超时或 [RemoteRuntimeTransport.close] 时 [abort] 被调用。
/// 真实实现里 [abort] 强关底层 `HttpClient`，把正在建立的 TCP/TLS socket 与
/// 响应流一起拆掉，不留下悬挂连接。
class RemoteDialAttempt {
  /// 创建一次拨号尝试。
  RemoteDialAttempt({required this.socket, required this.abort});

  /// 拨号结果：成功时给出已建立的 WebSocket，失败时以异常完成。
  final Future<WebSocket> socket;

  /// 主动中止仍在建立的连接；幂等，可以重复调用。
  final void Function() abort;
}

/// 拨号入口；只给测试替换成永不完成/可控的连接，缺省实现走 `WebSocket.connect`。
typedef RemoteDialer = RemoteDialAttempt Function(HttpClient client);

/// 远程模式的 [RuntimeTransport] 实现。
///
/// 生命周期：构造即开始拨号（不提供单独的 `start`）。首次握手成功后
/// [handshake] 完成；之后每次断线都会按退避重连并重新握手。[close] 之后不再
/// 重连，所有在途请求以 `gateway/cancelled` 失败。
///
/// 连接阶段的进展通过 [events] 里的 `remote.status` 人工帧暴露；它不替代宿主推送
/// 的 `runtime.status`——业务是否就绪仍以 `runtime.status.params.phase == 'ready'`
/// 为准（协议 §3.4）。
class RemoteRuntimeTransport implements RemoteTransportLink {
  /// 创建远程传输。
  ///
  /// [endpoint] 必须是 `wss://<host>:<port>/app`；路径为空时补成 `/app`，其它路径、
  /// 查询串与片段会被拒绝（协议 §1.1）。
  /// [token] 是配对得到的设备令牌，会作为 `Authorization: Bearer <token>` 上线。
  /// [pinnedCaPem] 是配对时固定的 CA 证书 PEM 文本；PEM 为空或无法解析时构造函数
  /// 立即抛出 `remote/tls` 失败，而不是等到第一次拨号。
  ///
  /// [deviceLabel] / [appVersion] / [capabilities] 原样进入 `protocol.hello.params`
  /// （协议 §3.1）。[requestTimeout] 是普通请求的兜底超时，避免宿主无响应时页面
  /// 永久悬挂；[handshakeTimeout] 对应协议 §3.3 的 10 秒握手窗口。
  ///
  /// [connectTimeout] 是拨号（TCP + TLS + HTTP 升级）的总时限，默认
  /// [defaultConnectTimeout]（12 秒）：不可达网络下 OS 的 TCP 超时可达约 2 分钟，
  /// 期间页面只能停在「正在连接」。超时按终止性失败处理（不自动重连），页面进入
  /// 可见失败态，用户检查地址与网络后可重试。
  ///
  /// [dialer] 只给测试注入拨号实现；App 侧不要传入，缺省用 `WebSocket.connect`。
  ///
  /// [pingInterval] 是 WebSocket 自动 ping 的周期；默认 20 秒，即两个周期（40 秒）
  /// 无回应时底层关闭连接并触发重连。
  RemoteRuntimeTransport({
    required String endpoint,
    required String token,
    required String pinnedCaPem,
    this.deviceLabel = '未命名的 Android 设备',
    this.appVersion = '0.1.0',
    List<String> capabilities = const <String>['window-ack'],
    Duration connectTimeout = defaultConnectTimeout,
    Duration handshakeTimeout = const Duration(seconds: 10),
    Duration requestTimeout = const Duration(seconds: 90),
    Duration pingInterval = const Duration(seconds: 20),
    this.dialer,
  }) : _endpoint = _normalizeEndpoint(endpoint),
       _token = _validateToken(token),
       _capabilities = List<String>.unmodifiable(capabilities),
       _connectTimeout = connectTimeout,
       _handshakeTimeout = handshakeTimeout,
       _requestTimeout = requestTimeout,
       _pingInterval = pingInterval,
       _securityContext = _pinnedSecurityContext(pinnedCaPem) {
    if (connectTimeout <= Duration.zero) {
      throw ArgumentError.value(connectTimeout, 'connectTimeout', '必须大于 0');
    }
    if (handshakeTimeout <= Duration.zero) {
      throw ArgumentError.value(handshakeTimeout, 'handshakeTimeout', '必须大于 0');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout', '必须大于 0');
    }
    if (pingInterval <= Duration.zero) {
      throw ArgumentError.value(pingInterval, 'pingInterval', '必须大于 0');
    }
    // `handshake` 可能一直没人 await（例如首连就失败后页面已销毁）。先挂一个
    // 吞掉的监听，避免 future 以错误完成时被当成未处理的异步异常。
    unawaited(_handshake.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(_run());
  }

  /// 协议版本；当前协议 v1 恒为 1（协议 §3.1）。
  static const int protocolVersion = 1;

  /// 拨号（TCP + TLS + WebSocket 升级）的默认超时。
  ///
  /// 12 秒覆盖正常局域网/公网入口的拨号延迟，又比不可达网络下 OS 的 TCP 超时
  /// （可能约 2 分钟）短一个数量级（HANDOFF §4 第 17 项）。这是传输的固定策略，
  /// 不开放用户设置。
  static const Duration defaultConnectTimeout = Duration(seconds: 12);

  /// 拨号超时的失败码。
  ///
  /// 复用 `remote/*` 这个客户端侧命名空间（同 `remote/tls`、
  /// `remote/handshake-timeout`、`remote/connect-failed`），而不是新增
  /// `gateway/connect-timeout`：协议 §9.2 的 `gateway/*` 是宿主应用层
  /// `_pocket_error` 的词汇，拨号超时发生在手机侧、宿主根本没有参与应答，用
  /// `gateway/*` 会把客户端失败误归因成宿主错误；`gateway/timeout`（协议 §4.1）
  /// 描述的是宿主请求 90 秒无响应，语义也不符。
  static const String connectTimeoutCode = 'remote/connect-timeout';

  /// 协议要求的固定 Origin，逐字节比较（协议 §2.1）。
  static const String origin = 'https://pocket-harness.local';

  /// 上行单帧上限：1 MiB（协议 §1.3）。
  static const int maxOutboundFrameBytes = 1024 * 1024;

  /// 下行单帧上限：16 MiB（协议 §1.3）。超限视为协议错误并重连。
  static const int maxInboundFrameBytes = 16 * 1024 * 1024;

  /// 重连等待表（协议 §1.4）：1 s 起指数增长、30 s 封顶；实际等待值再叠加 ±20%
  /// 抖动。只有连接存活超过 [RemoteReconnectPolicy.healthyThreshold] 之后才把失败
  /// 计数清零——「连上即断」必须继续升级退避，否则会退化成秒级重连风暴。
  static const List<Duration> reconnectBackoff = RemoteReconnectPolicy.backoff;

  static const RuntimeTransportFailure _cancelledFailure =
      RuntimeTransportFailure(
        code: 'gateway/cancelled',
        message: '操作已取消（连接或页面已关闭）。',
      );

  final Uri _endpoint;
  final String _token;

  /// 展示给宿主的设备名，进入 `protocol.hello.params.deviceLabel`。
  final String deviceLabel;

  /// App 构建号，进入 `protocol.hello.params.appVersion`，仅用于宿主展示与排障。
  final String appVersion;

  /// 拨号实现；null 表示走缺省的 `WebSocket.connect`。
  ///
  /// 只用于测试注入永不完成/可控的连接来驱动超时路径，App 侧不要传入。
  final RemoteDialer? dialer;

  final List<String> _capabilities;
  final Duration _connectTimeout;
  final Duration _handshakeTimeout;
  final Duration _requestTimeout;
  final Duration _pingInterval;
  final SecurityContext _securityContext;

  /// 重连退避策略；与 [reconnectBackoff] 同一份常量。
  final RemoteReconnectPolicy _reconnectPolicy = RemoteReconnectPolicy();

  /// 单订阅：与 [LocalRuntimeTransport] 一致，未订阅前事件会缓冲，不会丢。
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>();

  /// 首次成功握手的结果；终止性失败或 [close] 时以错误完成。
  final Completer<RemoteHostInfo> _handshake = Completer<RemoteHostInfo>();

  /// 在途请求：id → 等待响应的 completer。
  final Map<String, Completer<dynamic>> _pending =
      <String, Completer<dynamic>>{};

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  HttpClient? _dialingClient;
  RemoteDialAttempt? _dialAttempt;
  Timer? _dialTimer;
  Future<void>? _socketClose;
  Future<void>? _closing;
  Completer<void>? _retryWake;
  RemoteHostInfo? _host;
  RuntimeTransportFailure? _terminalError;
  RuntimeTransportFailure? _lastFailure;
  RuntimeTransportFailure? _protocolError;
  Future<dynamic> Function(String method, Map<String, dynamic> params)?
  _requestHandler;
  String _lineBuffer = '';
  String _phase = 'connecting';
  int? _closeCode;
  String _closeReason = '';
  int _attempt = 0;
  int _generation = 0;

  /// 本次连接握手成功的时刻；用来判断「这次连接是否算存活」，
  /// 只有超过 [RemoteReconnectPolicy.healthyThreshold] 才重置退避。
  DateTime? _readyAt;
  bool _closed = false;
  bool _terminal = false;
  bool _ready = false;
  bool _everReady = false;
  bool _readyThisAttempt = false;

  /// 首次成功握手的结果；宿主信息在每次重连后可能变化，最新值见 [host]。
  ///
  /// 版本不匹配、认证失败、设备被撤销、[close] 等终止性情形会让它失败；可重试的
  /// 网络故障不会让它完成，连接会继续按退避重连。
  @override
  Future<RemoteHostInfo> get handshake => _handshake.future;

  /// 最近一次成功握手得到的宿主信息；尚未握手成功时为 null。
  ///
  /// 每次重连都会重新握手并覆盖这个值（协议 §7.2 第 3 步要求重新计算入口可见性）。
  @override
  RemoteHostInfo? get host => _host;

  /// 传输层阶段：`connecting` / `handshaking` / `ready` / `reconnecting` / `lost`。
  ///
  /// 与 `remote.status` 人工帧的 `phase` 字段一致。业务就绪仍看 `runtime.status`。
  @override
  String get phase => _phase;

  /// 是否已调用过 [close]。
  @override
  bool get isClosed => _closed;

  /// 入站通知流，形态与接口约定一致：`{'method': String, 'params': Map}`。
  ///
  /// 包含宿主帧里的全部通知（`api.stream`、`session.event`、`remote.*`）以及本类
  /// 产生的 `remote.status`。重连期间不关闭；终止性失败后由调用方 [close]，
  /// [close] 之后不再产生新事件。单订阅，取消订阅后不能再订阅。
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 发送一次请求并等待响应。
  ///
  /// 只有握手完成（[phase] 为 `ready`）后才允许发送业务请求；否则立即以
  /// `gateway/unavailable` 失败。响应里的 `_pocket_error` 与 JSON-RPC `error`
  /// 都会统一转成 [RuntimeTransportFailure]（协议 §4.1）。
  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    if (_closed || _closing != null) {
      return Future<dynamic>.error(_cancelledFailure);
    }
    if (_terminal) {
      return Future<dynamic>.error(_terminalError ?? _cancelledFailure);
    }
    if (!_ready) {
      return Future<dynamic>.error(
        RuntimeTransportFailure(
          code: 'gateway/unavailable',
          message: _host == null ? '尚未连接到电脑，请稍后重试。' : '与电脑的连接已断开，正在重连…',
          details: <String, dynamic>{'phase': _phase},
        ),
      );
    }
    final id = _nextRequestId();
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _sendRequestFrame(id, method, params);
    } on Object catch (error, stackTrace) {
      _pending.remove(id);
      return Future<dynamic>.error(error, stackTrace);
    }
    return completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw RuntimeTransportFailure(
          code: 'gateway/timeout',
          message: '电脑上的 DSH 响应超时，请重试。',
          details: <String, dynamic>{'id': id, 'method': method},
        );
      },
    );
  }

  /// 发送一条单向通知；未握手成功或已关闭时静默丢弃。
  ///
  /// 通知没有应答，写失败无法回传给调用方；真正的断线由连接关闭统一发现。
  @override
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    if (_closed || !_ready) return;
    try {
      _sendFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      });
    } on Object catch (error) {
      // 通知没有应答可回；写失败只会表现为连接随后断开，由 onDone 统一处理。
      _lastFailure = _asFailure(error);
    }
  }

  /// 安装宿主的反向请求处理器（`native.*`），见接口约定。
  ///
  /// 未安装时所有反向请求回 `-32601`；处理器抛 [UnsupportedError] 或
  /// `code: 'unsupported-method'` 时同样回 `-32601`。
  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {
    _requestHandler = handler;
  }

  /// 关闭传输：停止重连，所有在途请求以 `gateway/cancelled` 失败，[events] 随后关闭。
  ///
  /// 幂等：重复调用（含并发调用）返回同一次关闭的结果，不抛异常。
  ///
  /// [events] 的关闭不等待监听者消费完缓冲事件：单订阅控制器如果从未被监听，
  /// `StreamController.close()` 的 done future 会一直挂着，不能让 `close()` 跟着挂。
  @override
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    return _closing = _close();
  }

  Future<void> _close() async {
    // 同步置位：第一个 await 之前 request 就能看到已关闭，不再接受新请求。
    _closed = true;
    _ready = false;
    _phase = 'lost';
    _failPending(_cancelledFailure);
    if (!_handshake.isCompleted) _handshake.completeError(_cancelledFailure);
    _cancelRetry();
    // 拨号中的超时定时器与在途连接也要收掉：切换设备 / dispose 时页面已经离开，
    // 不能留下 12 秒后才触发的回调和悬挂的 socket。
    _cancelDialTimeout();
    _dialAttempt?.abort();
    _dialingClient?.close(force: true);
    await _closeSocket(WebSocketStatus.normalClosure, 'client-closed');
    _socket = null;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    if (!_events.isClosed) unawaited(_events.close());
  }

  // ---------------------------------------------------------------------------
  // 连接与重连
  // ---------------------------------------------------------------------------

  Future<void> _run() async {
    var attempt = 0;
    var rateLimited = false;
    while (!_closed && !_terminal) {
      if (attempt == 0 && !_everReady) _setPhase('connecting');
      try {
        await _serve();
      } on _TerminalFailure catch (failure) {
        _terminate(failure);
        break;
      } on _RetryableFailure catch (failure) {
        rateLimited = failure.rateLimited;
        _lastFailure = failure.error;
      } on Object catch (error) {
        rateLimited = false;
        _lastFailure = _asFailure(error);
        // _serve 的契约只抛上面两类；走到这里说明有未预料的问题，按可重试处理，
        // 不让重连循环因为一个异常就永久停摆。
      }
      if (_closed || _terminal) break;
      // 只有这次连接真的握手成功、并且存活超过阈值，才把失败计数清零。否则
      // 「连上即断」（宿主重启、中间设备掐连接）会让退避永远停在 1 s（协议 §1.4
      // 的 1 s → 30 s 就对不上实际行为了）。
      final readyAt = _readyAt;
      _readyAt = null;
      final lifetime = _readyThisAttempt && readyAt != null
          ? DateTime.now().difference(readyAt)
          : null;
      if (_reconnectPolicy.resetsAfter(lifetime)) {
        attempt = 0;
        rateLimited = false;
      }
      final delay = _reconnectPolicy.delayFor(
        attempt,
        rateLimited: rateLimited,
      );
      attempt++;
      _setPhase('reconnecting', error: _lastFailure);
      await _sleep(delay);
    }
    _ready = false;
  }

  /// 建立一条连接并把它服务到关闭为止。
  ///
  /// 正常返回只发生在 [close] 期间；对端关闭、握手失败等都以
  /// [_TerminalFailure] 或 [_RetryableFailure] 抛出，交给 [_run] 分类。
  Future<void> _serve() async {
    final generation = ++_generation;
    _attempt++;
    _protocolError = null;
    _socketClose = null;
    _readyThisAttempt = false;
    _readyAt = null;

    WebSocket socket;
    try {
      socket = await _dial();
    } on _TerminalFailure {
      rethrow;
    } on _RetryableFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _RetryableFailure(_asFailure(error)),
        stackTrace,
      );
    }

    if (_closed) {
      await _closeLateSocket(socket);
      return;
    }

    _socket = socket;
    _closeCode = null;
    _closeReason = '';
    _lineBuffer = '';
    final ended = Completer<void>();
    _socketSubscription = socket.listen(
      (dynamic data) => _handleInbound(data, generation),
      onError: (Object error, StackTrace stackTrace) {
        if (!ended.isCompleted) ended.complete();
      },
      onDone: () {
        _closeCode = socket.closeCode;
        _closeReason = socket.closeReason ?? '';
        _ready = false;
        // 连接一断，所有在途请求立刻失败；迟到的响应帧随后按未知 id 丢弃。
        _failPending(_cancelledFailure);
        if (!ended.isCompleted) ended.complete();
      },
      cancelOnError: true,
    );

    try {
      _setPhase('handshaking');
      final info = await _handshakeOnConnection(generation);
      if (_closed || generation != _generation) return;
      _host = info;
      _ready = true;
      _everReady = true;
      _readyThisAttempt = true;
      _readyAt = DateTime.now();
      if (!_handshake.isCompleted) _handshake.complete(info);
      _setPhase('ready');
      await ended.future;
    } on _TerminalFailure catch (failure) {
      await _closeSocket(failure.closeCode, failure.error.code);
      rethrow;
    } on Object catch (error, stackTrace) {
      // 握手中的可重试失败：先关掉半开连接，再把「具体失败」与「关闭码」合并。
      await _closeSocket(WebSocketStatus.normalClosure, 'handshake-failed');
      if (_closed) return;
      if (_terminal && _terminalError != null) {
        throw _TerminalFailure(_terminalError!, WebSocketStatus.normalClosure);
      }
      final failure = _asFailure(error);
      final terminal = _terminalFromFailure(failure);
      if (terminal != null) throw terminal;
      final closeFailure = _closeFailureFor(_closeCode, _closeReason);
      if (failure.code == 'gateway/cancelled') throw closeFailure;
      Error.throwWithStackTrace(
        _RetryableFailure(
          failure,
          rateLimited:
              closeFailure is _RetryableFailure && closeFailure.rateLimited,
        ),
        stackTrace,
      );
    } finally {
      _ready = false;
      _socket = null;
      _lineBuffer = '';
      final subscription = _socketSubscription;
      _socketSubscription = null;
      await subscription?.cancel();
      _failPending(_cancelledFailure);
    }

    if (_closed) return;
    throw _closeFailureFor(_closeCode, _closeReason);
  }

  /// 建立一条 WebSocket 连接；拨号超时与失败都在这里收敛成结构化失败。
  ///
  /// 超时使用显式 [Timer] 而不是 `Future.timeout`：外部 [close]（切换设备、dispose）
  /// 必须能立刻取消它，否则页面已经离开、回调还在等 12 秒，测试里也会留下 pending
  /// timer。超时按终止性失败处理——拨号已经等满一个完整窗口，自动重连只会把同一个
  /// 12 秒再演一遍，交给用户检查地址与网络。
  Future<WebSocket> _dial() async {
    final client = HttpClient(context: _securityContext)
      ..connectionTimeout = _connectTimeout;
    _dialingClient = client;
    Timer? timer;
    final timedOut = Completer<Never>();
    try {
      final dial = dialer?.call(client) ?? _webSocketDial(client);
      _dialAttempt = dial;
      timer = Timer(_connectTimeout, () {
        // 主动拆掉还在建立的 TCP/TLS 连接：只丢下 future 会泄漏悬挂的 socket。
        dial.abort();
        // `abort` 与底层拨号完成存在竞态：晚到的连接也必须关掉。
        unawaited(
          dial.socket.then<void>(
            (socket) => unawaited(
              socket.close(WebSocketStatus.goingAway, connectTimeoutCode),
            ),
            onError: (Object _) {},
          ),
        );
        if (!timedOut.isCompleted) {
          timedOut.completeError(_connectTimeoutFailure());
        }
      });
      _dialTimer = timer;
      final socket = await Future.any<WebSocket>(<Future<WebSocket>>[
        dial.socket,
        timedOut.future,
      ]);
      // 协议 §1.5：客户端每 20 秒 ping 一次；两个周期没有 pong 时底层关闭。
      socket.pingInterval = _pingInterval;
      return socket;
    } on _TerminalFailure {
      rethrow;
    } on RuntimeTransportFailure catch (failure) {
      // 只有拨号超时会以结构化失败走到这里（其它异常由下面的分支映射）。
      throw _TerminalFailure(failure, WebSocketStatus.goingAway);
    } on TimeoutException {
      // `HttpClient.connectionTimeout` 与拨号定时器是同一个窗口的两层保险：哪一层
      // 先到都收敛成同一个终止性失败，否则同一个 12 秒会因底层实现不同退化成
      // 可重试的 `remote/connect-failed`。
      throw _TerminalFailure(
        _connectTimeoutFailure(),
        WebSocketStatus.goingAway,
      );
    } on HandshakeException catch (error) {
      // 证书不受信任是终止态（协议 §1.4：证书/令牌/协议不匹配不属于可重试的网络
      // 故障）。自动重连只会每 ≤30 s 再失败一次，必须交给用户重新配对。
      throw _TerminalFailure(_tlsFailure(error), _closeCodeProtocolMismatch);
    } on TlsException catch (error) {
      throw _TerminalFailure(_tlsFailure(error), _closeCodeProtocolMismatch);
    } on WebSocketException catch (error) {
      throw _httpFailure(error);
    } on IOException catch (error) {
      throw RuntimeTransportFailure(
        code: 'remote/connect-failed',
        message: '无法连接到电脑：$error',
        details: error.toString(),
      );
    } on Object catch (error) {
      throw RuntimeTransportFailure(
        code: 'remote/connect-failed',
        message: '无法连接到电脑：$error',
        details: error.toString(),
      );
    } finally {
      timer?.cancel();
      if (identical(_dialTimer, timer)) _dialTimer = null;
      _dialAttempt = null;
      if (identical(_dialingClient, client)) _dialingClient = null;
      // 升级成功后 socket 已经从 HttpClient 上 detach，关闭客户端不会影响它。
      client.close(force: true);
    }
  }

  /// 缺省拨号实现：用固定 TLS 上下文的 [HttpClient] 建立 `wss://` 连接。
  ///
  /// [RemoteDialAttempt.abort] 强关客户端；`HttpClient.close(force: true)` 会中止
  /// 正在建立的连接，这是「超时后不留下悬挂 socket」的最终兜底。
  RemoteDialAttempt _webSocketDial(HttpClient client) {
    final socket = WebSocket.connect(
      _endpoint.toString(),
      headers: <String, dynamic>{
        'Authorization': 'Bearer $_token',
        'Origin': origin,
      },
      // 协议 §1.1 明确不启用 permessage-deflate。
      compression: CompressionOptions.compressionOff,
      customClient: client,
    );
    return RemoteDialAttempt(
      socket: socket,
      abort: () => client.close(force: true),
    );
  }

  RuntimeTransportFailure _connectTimeoutFailure() {
    return RuntimeTransportFailure(
      code: connectTimeoutCode,
      message: '连接电脑超时，请检查地址与网络后重试。',
      details: <String, dynamic>{
        'endpoint': _endpoint.toString(),
        'timeoutMs': _connectTimeout.inMilliseconds,
      },
    );
  }

  /// 取消拨号超时定时器：成功、失败与外部取消路径都要走到。
  void _cancelDialTimeout() {
    _dialTimer?.cancel();
    _dialTimer = null;
  }

  RuntimeTransportFailure _tlsFailure(TlsException error) {
    return RuntimeTransportFailure(
      code: 'remote/tls',
      message:
          '无法验证电脑的 TLS 证书：${error.message}。'
          '请重新配对这台电脑，或在电脑上更新证书。',
      details: error.toString(),
    );
  }

  Exception _httpFailure(WebSocketException error) {
    final status = error.httpStatusCode;
    switch (status) {
      case HttpStatus.unauthorized:
        return _TerminalFailure(
          const RuntimeTransportFailure(
            code: 'auth-failed',
            message: '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。',
          ),
          _closeCodeAuthFailed,
        );
      case HttpStatus.forbidden:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'remote/origin-rejected',
            message:
                '连接被拒绝：电脑不接受的客户端来源（Origin）。'
                '请确认 App 与电脑上的 DSH 版本一致。',
            details: error.message,
          ),
          _closeCodeAuthFailed,
        );
      case HttpStatus.notFound:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'remote/not-found',
            message:
                '连接地址不正确：电脑上没有 /app 端点。'
                '请检查电脑上的远程 DSH 是否已开启。',
            details: error.message,
          ),
          WebSocketStatus.normalClosure,
        );
      case HttpStatus.tooManyRequests:
        return _RetryableFailure(
          RuntimeTransportFailure(
            code: 'rate-limited',
            message: '连接尝试过于频繁，电脑已限流；稍后会按退避重试。',
            details: error.message,
          ),
          rateLimited: true,
        );
      default:
        return _RetryableFailure(
          RuntimeTransportFailure(
            code: 'remote/connect-failed',
            message:
                '无法连接到电脑：${error.message}'
                '${status == null ? '' : '（HTTP $status）'}。',
            details: error.toString(),
          ),
        );
    }
  }

  // ---------------------------------------------------------------------------
  // 握手
  // ---------------------------------------------------------------------------

  Future<RemoteHostInfo> _handshakeOnConnection(int generation) async {
    final id = _nextRequestId();
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _sendRequestFrame(id, 'protocol.hello', <String, dynamic>{
        'protocolVersion': protocolVersion,
        'appVersion': appVersion,
        'deviceLabel': deviceLabel,
        'capabilities': _capabilities,
      });
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    final result = await completer.future.timeout(
      _handshakeTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw RuntimeTransportFailure(
          code: 'remote/handshake-timeout',
          message: '连接电脑超时：握手未在 ${_handshakeTimeout.inSeconds} 秒内完成。',
          details: <String, dynamic>{
            'timeoutMs': _handshakeTimeout.inMilliseconds,
          },
        );
      },
    );
    if (generation != _generation) throw _cancelledFailure;
    return _hostInfoFrom(result);
  }

  RemoteHostInfo _hostInfoFrom(Object? result) {
    if (result is! Map<String, dynamic>) {
      throw _TerminalFailure(
        const RuntimeTransportFailure(
          code: 'protocol-mismatch',
          message: '握手响应格式不正确：电脑没有返回预期的对象。请把两端升级到同一版本。',
        ),
        _closeCodeProtocolMismatch,
      );
    }
    final version = result['protocolVersion'];
    if (version is! int || version != protocolVersion) {
      throw _TerminalFailure(
        RuntimeTransportFailure(
          code: 'protocol-mismatch',
          message:
              '协议版本不匹配：电脑为 v${version ?? '未知'}，'
              '手机为 v$protocolVersion。请把两端升级到同一版本。',
          details: result,
        ),
        _closeCodeProtocolMismatch,
      );
    }
    final host = result['host'];
    if (host is! Map<String, dynamic>) {
      throw _TerminalFailure(
        RuntimeTransportFailure(
          code: 'protocol-mismatch',
          message: '握手响应缺少电脑信息（host），无法继续连接。',
          details: result,
        ),
        _closeCodeProtocolMismatch,
      );
    }
    final name = host['name'];
    final platform = host['platform'];
    final home = host['home'];
    if (name is! String || platform is! String || home is! String) {
      throw _TerminalFailure(
        RuntimeTransportFailure(
          code: 'protocol-mismatch',
          message: '握手响应里的电脑信息不完整（缺少名称、平台或主目录）。',
          details: result,
        ),
        _closeCodeProtocolMismatch,
      );
    }
    return RemoteHostInfo(
      protocolVersion: version,
      name: name,
      platform: platform,
      home: home,
      methods: _stringList(result['methods'], 'methods', result),
      unsupported: _stringList(result['unsupported'], 'unsupported', result),
      capabilities: _stringList(result['capabilities'], 'capabilities', result),
    );
  }

  List<String> _stringList(Object? raw, String field, Object details) {
    if (raw == null) return const <String>[];
    if (raw is! List) {
      throw _TerminalFailure(
        RuntimeTransportFailure(
          code: 'protocol-mismatch',
          message: '握手响应里的 $field 不是字符串数组。',
          details: details,
        ),
        _closeCodeProtocolMismatch,
      );
    }
    final values = <String>[];
    for (final item in raw) {
      if (item is! String) {
        throw _TerminalFailure(
          RuntimeTransportFailure(
            code: 'protocol-mismatch',
            message: '握手响应里的 $field 含有非字符串条目。',
            details: details,
          ),
          _closeCodeProtocolMismatch,
        );
      }
      values.add(item);
    }
    return values;
  }

  // ---------------------------------------------------------------------------
  // 帧编解码
  // ---------------------------------------------------------------------------

  void _handleInbound(dynamic data, int generation) {
    if (generation != _generation || _closed) return;
    if (data is String) {
      _lineBuffer += data;
    } else {
      // 协议 §11 不引入二进制帧；收到即视为协议错误。
      _protocolFailure('收到二进制帧；协议 v1 只允许文本帧。');
      return;
    }
    if (_lineBuffer.length > maxInboundFrameBytes) {
      // 按 UTF-16 长度做宽松上限（非 ASCII 时实际字节更多）；这里只为拦住
      // 无换行的异常大帧，避免内存无限增长。
      _protocolFailure('下行帧超过 16 MiB 上限，已断开连接。');
      return;
    }
    while (generation == _generation && _protocolError == null && !_closed) {
      final index = _lineBuffer.indexOf('\n');
      if (index < 0) return;
      final line = _lineBuffer.substring(0, index);
      _lineBuffer = _lineBuffer.substring(index + 1);
      // 协议禁止 \r\n；这里容忍并剥掉尾随 \r，避免一个多余字节就断开整条连接。
      final trimmed = line.endsWith('\r')
          ? line.substring(0, line.length - 1)
          : line;
      if (trimmed.isEmpty) continue;
      _handleLine(trimmed);
    }
  }

  void _handleLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _protocolFailure('收到无法解析的 JSON 帧。');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _protocolFailure('收到非对象的 JSON-RPC 帧。');
      return;
    }
    if (decoded['jsonrpc'] != '2.0') {
      _protocolFailure('收到 jsonrpc 不是 "2.0" 的帧。');
      return;
    }

    final method = decoded['method'];
    final hasId = decoded.containsKey('id');
    final id = decoded['id'];
    if (method is String && method.isNotEmpty) {
      if (hasId && id != null) {
        // 带 id 的 method 帧是宿主的反向请求（协议 §5）。
        unawaited(_serveReverseRequest(id, method, _paramsOf(decoded)));
      } else {
        _emit(method, _paramsOf(decoded));
      }
      return;
    }
    if (!hasId) {
      _protocolFailure('收到既没有 id 也没有 method 的帧。');
      return;
    }
    if (id == null) {
      // 认证 / 版本类连接级错误：不结算任何在途请求，直接进入终止态（协议 §2.2）。
      _handleConnectionError(decoded['error']);
      return;
    }
    _settleResponse(id, decoded);
  }

  Map<String, dynamic> _paramsOf(Map<String, dynamic> frame) {
    final params = frame['params'];
    return params is Map<String, dynamic> ? params : const <String, dynamic>{};
  }

  void _settleResponse(Object id, Map<String, dynamic> frame) {
    // 我们只发字符串 id；数字 id 不属于本实现，按未知响应丢弃。
    if (id is! String) return;
    final completer = _pending.remove(id);
    if (completer == null) return; // 超时后迟到的响应：丢弃，不关连接（协议 §1.2）。
    if (frame.containsKey('error')) {
      completer.completeError(_failureFromResponse(frame['error']));
      return;
    }
    final result = frame['result'];
    if (result is Map<String, dynamic> &&
        result['_pocket_error'] is Map<String, dynamic>) {
      final failure = result['_pocket_error'] as Map<String, dynamic>;
      final code = failure['code'];
      final message = failure['message'];
      completer.completeError(
        RuntimeTransportFailure(
          code: code is String ? code : 'gateway/internal',
          message: message is String ? message : '电脑上的 DSH 处理失败，请稍后重试。',
          details: failure,
        ),
      );
      return;
    }
    if (!frame.containsKey('result')) {
      completer.completeError(
        const RuntimeTransportFailure(
          code: 'gateway/bad-request',
          message: '电脑返回的响应帧既没有 result 也没有 error。',
        ),
      );
      return;
    }
    completer.complete(result);
  }

  RuntimeTransportFailure _failureFromResponse(Object? raw) {
    final error = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    final data = error['data'] is Map<String, dynamic>
        ? error['data'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final dataCode = data['code'];
    final code = dataCode is String
        ? dataCode
        : _codeForRpcError(error['code']);
    final rawMessage = error['message'];
    return RuntimeTransportFailure(
      code: code,
      message: rawMessage is String ? rawMessage : _defaultMessage(code),
      details: error,
    );
  }

  String _codeForRpcError(Object? code) {
    switch (code) {
      case -32700:
      case -32600:
      case -32602:
        return 'gateway/bad-request';
      case -32601:
        return 'unsupported-method';
      case -32603:
        return 'gateway/internal';
      case -32000:
        return 'protocol-mismatch';
      case -32001:
        return 'auth-failed';
      case -32002:
        return 'auth-revoked';
      case -32003:
        return 'rate-limited';
      default:
        return 'gateway/internal';
    }
  }

  String _defaultMessage(String code) {
    switch (code) {
      case 'gateway/bad-request':
        return '请求参数不正确。';
      case 'gateway/internal':
        return '电脑上的 DSH 处理失败，请稍后重试。';
      case 'gateway/cancelled':
        return '操作已取消（连接或页面已关闭）。';
      case 'gateway/timeout':
        return '电脑上的 DSH 响应超时，请重试。';
      case 'gateway/unavailable':
        return '电脑上的 DSH 暂时不可用，请稍后重试。';
      case 'unsupported-method':
        return '当前连接的电脑不支持该操作。';
      case 'auth-failed':
        return '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。';
      case 'auth-revoked':
        return '这台手机已被电脑撤销授权。请在电脑上重新配对。';
      case 'protocol-mismatch':
        return '协议版本不匹配。请把两端升级到同一版本。';
      case 'rate-limited':
        return '操作太频繁，请稍后重试。';
      default:
        return '电脑上的 DSH 暂时不可用，请稍后重试。';
    }
  }

  void _handleConnectionError(Object? raw) {
    if (_closed || _terminal) return;
    final failure = _failureFromResponse(raw);
    final closeCode = switch (failure.code) {
      'auth-failed' => _closeCodeAuthFailed,
      'auth-revoked' => _closeCodeAuthRevoked,
      _ => _closeCodeProtocolMismatch,
    };
    _terminate(_TerminalFailure(failure, closeCode));
  }

  // ---------------------------------------------------------------------------
  // 反向请求
  // ---------------------------------------------------------------------------

  Future<void> _serveReverseRequest(
    Object id,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_closed) {
      _sendError(id, -32603, '设备正在断开连接。', const <String, dynamic>{
        'code': 'gateway/cancelled',
      });
      return;
    }
    final handler = _requestHandler;
    if (handler == null) {
      _sendUnsupported(id, method);
      return;
    }
    try {
      final result = await handler(method, params);
      if (_closed) return;
      _sendResult(id, result);
    } on UnsupportedError {
      _sendUnsupported(id, method);
    } on RuntimeTransportFailure catch (failure) {
      if (failure.code == 'unsupported-method') {
        _sendUnsupported(id, method);
      } else {
        _sendError(
          id,
          -32603,
          _truncateUtf8(failure.message, 1024),
          <String, dynamic>{'code': failure.code},
        );
      }
    } on Object catch (error) {
      _sendError(
        id,
        -32603,
        _truncateUtf8('$error', 1024),
        const <String, dynamic>{'code': 'gateway/internal'},
      );
    }
  }

  void _sendUnsupported(Object id, String method) {
    _sendError(id, -32601, '当前设备不支持 $method。', <String, dynamic>{
      'code': 'unsupported-method',
      'method': method,
    });
  }

  /// 发送反向请求的成功结果；结果无法 JSON 编码时回 `-32603`（接口约定）。
  void _sendResult(Object id, Object? result) {
    try {
      _sendFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      });
    } on RuntimeTransportFailure catch (failure) {
      // 连接已断开或帧超限时没有可回的对象，只能记录原因等连接关闭处理。
      _lastFailure = failure;
    } on Object catch (error) {
      _sendError(
        id,
        -32603,
        _truncateUtf8('$error', 1024),
        const <String, dynamic>{'code': 'gateway/internal'},
      );
    }
  }

  void _sendError(
    Object id,
    int rpcCode,
    String message,
    Map<String, dynamic> data,
  ) {
    _sendQuietly(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, dynamic>{
        'code': rpcCode,
        'message': message,
        'data': data,
      },
    });
  }

  /// 反向请求的应答没有调用方可以抛错，写失败只能记录后交给连接关闭处理。
  void _sendQuietly(Map<String, dynamic> frame) {
    try {
      _sendFrame(frame);
    } on Object catch (error) {
      _lastFailure = _asFailure(error);
    }
  }

  // ---------------------------------------------------------------------------
  // 发送与请求表
  // ---------------------------------------------------------------------------

  void _sendRequestFrame(
    String id,
    String method,
    Map<String, dynamic> params,
  ) {
    _sendFrame(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
  }

  void _sendFrame(Map<String, dynamic> frame) {
    if (_closed) throw _cancelledFailure;
    final socket = _socket;
    if (socket == null) throw _cancelledFailure;
    final line = '${jsonEncode(frame)}\n';
    final length = utf8.encode(line).length;
    if (length > maxOutboundFrameBytes) {
      throw RuntimeTransportFailure(
        code: 'gateway/bad-request',
        message: '请求过大，无法发送（超过 1 MiB 上限）。',
        details: <String, dynamic>{
          'bytes': length,
          'limit': maxOutboundFrameBytes,
        },
      );
    }
    // 必须用 String 发送文本帧；传 List<int> 会变成二进制帧，被宿主按协议错误断开。
    socket.add(line);
  }

  /// 生成请求 id。
  ///
  /// 协议 §1.2 规定 App → 宿主的请求 id 是 `"a-" + uuidv4`，宿主 → App 是
  /// `"h-" + uuidv4`：方向前缀让两条方向的 id 空间隔离，uuid 保证同一进程内
  /// （含重连后）不会复用。宿主只把 id 原样回填、不校验形态，所以这里始终发
  /// 协议形态，而不是自增序号。
  String _nextRequestId() => 'a-${_uuidV4()}';

  /// 生成 RFC 4122 v4 UUID 文本（小写、带连字符）。
  ///
  /// 请求 id 的随机源用 `Random.secure()`：同一进程内（含重连）不会复用，
  /// 且不引入新的依赖包。
  static String _uuidV4() {
    final bytes = List<int>.generate(
      16,
      (_) => _requestIdRandom.nextInt(256),
    );
    // 版本位固定 4，变体位固定 10xx（RFC 4122 §4.4）。
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 请求 id 的随机源；只用于 [RemoteRuntimeTransport._nextRequestId]。
  static final Random _requestIdRandom = Random.secure();

  void _failPending(RuntimeTransportFailure failure) {
    if (_pending.isEmpty) return;
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(failure);
    }
  }

  // ---------------------------------------------------------------------------
  // 关闭码、退避与状态帧
  // ---------------------------------------------------------------------------

  static const int _closeCodeAuthFailed = 4000;
  static const int _closeCodeAuthRevoked = 4001;
  static const int _closeCodeProtocolMismatch = 4002;

  Exception _closeFailureFor(int? code, String reason) {
    final detail = reason.isEmpty ? null : reason;
    final protocolFailure = _protocolError;
    if (protocolFailure != null &&
        (code == null || code == WebSocketStatus.protocolError)) {
      // 本地主动关闭时 socket.closeCode 可能还没回填；保留具体协议错误原因。
      return _RetryableFailure(protocolFailure);
    }
    switch (code) {
      case WebSocketStatus.normalClosure:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'remote/closed',
            message: '与电脑的连接已正常关闭，不会自动重连。',
            details: detail,
          ),
          WebSocketStatus.normalClosure,
        );
      case WebSocketStatus.messageTooBig:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'remote/frame-too-large',
            message: '请求过大，电脑已关闭连接。请缩小请求范围后重新连接。',
            details: detail,
          ),
          WebSocketStatus.messageTooBig,
        );
      case _closeCodeAuthFailed:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'auth-failed',
            message: '连接被拒绝：设备令牌无效。请在电脑上重新配对这台手机。',
            details: detail,
          ),
          _closeCodeAuthFailed,
        );
      case _closeCodeAuthRevoked:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'auth-revoked',
            message: '这台手机已被电脑撤销授权。请在电脑上重新配对。',
            details: detail,
          ),
          _closeCodeAuthRevoked,
        );
      case _closeCodeProtocolMismatch:
        return _TerminalFailure(
          RuntimeTransportFailure(
            code: 'protocol-mismatch',
            message:
                '连接被拒绝：协议版本不匹配或握手未完成。'
                '请确认手机与电脑的 DSH 版本一致。',
            details: detail,
          ),
          _closeCodeProtocolMismatch,
        );
      case 4003:
        return _RetryableFailure(
          RuntimeTransportFailure(
            code: 'rate-limited',
            message: '操作太频繁，电脑已限速；将等待一段时间后重试。',
            details: detail,
          ),
          rateLimited: true,
        );
      case WebSocketStatus.protocolError:
        return _RetryableFailure(
          _protocolError ??
              RuntimeTransportFailure(
                code: 'gateway/bad-request',
                message: '与电脑的连接因帧格式错误被关闭，正在重连…',
                details: detail,
              ),
        );
      default:
        {
          // 1001 宿主退出、1006 异常断开、以及协议表外的关闭码都按可重连处理
          // （协议 §1.4）。
          final details = <String, dynamic>{'closeCode': code};
          if (detail != null) details['reason'] = detail;
          return _RetryableFailure(
            RuntimeTransportFailure(
              code: 'gateway/cancelled',
              message: '与电脑的连接已断开，正在重连…',
              details: details,
            ),
          );
        }
    }
  }

  _TerminalFailure? _terminalFromFailure(RuntimeTransportFailure failure) {
    switch (failure.code) {
      case 'auth-failed':
        return _TerminalFailure(failure, _closeCodeAuthFailed);
      case 'auth-revoked':
        return _TerminalFailure(failure, _closeCodeAuthRevoked);
      case 'protocol-mismatch':
        return _TerminalFailure(failure, _closeCodeProtocolMismatch);
      case 'remote/tls':
        // 固定的 CA 验证不了对端证书：只有重新配对或电脑换回原证书才能恢复。
        return _TerminalFailure(failure, _closeCodeProtocolMismatch);
      case 'remote/handshake-timeout':
        // 协议 §3.3 里握手超时由宿主按 `protocol-mismatch` 关闭；对端连握手都不回，
        // 重连只会重复同一个十秒，交给用户处理。
        return _TerminalFailure(failure, _closeCodeProtocolMismatch);
      default:
        return null;
    }
  }

  Future<void> _sleep(Duration duration) {
    final wake = Completer<void>();
    _retryWake = wake;
    final timer = Timer(duration, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(() {
      timer.cancel();
      if (identical(_retryWake, wake)) _retryWake = null;
    });
  }

  void _cancelRetry() {
    final wake = _retryWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _closeSocket(int code, String reason) {
    final existing = _socketClose;
    if (existing != null) return existing;
    final socket = _socket;
    if (socket == null) return Future<void>.value();
    _ready = false;
    return _socketClose = _closeSocketImpl(socket, code, reason);
  }

  Future<void> _closeSocketImpl(
    WebSocket socket,
    int code,
    String reason,
  ) async {
    try {
      await socket
          .close(code, _truncateUtf8(reason, 123))
          .timeout(const Duration(seconds: 2));
    } on Object catch (_) {
      // 2 秒内没等到对端回关闭帧就放弃等待；底层连接由 WebSocket 自身超时收敛。
      _ready = false;
    }
  }

  Future<void> _closeLateSocket(WebSocket socket) async {
    try {
      await socket
          .close(WebSocketStatus.goingAway, 'client-closed')
          .timeout(const Duration(seconds: 1));
    } on Object catch (_) {
      _ready = false;
    }
  }

  void _protocolFailure(String message) {
    if (_closed || _protocolError != null) return;
    _protocolError = RuntimeTransportFailure(
      code: 'gateway/bad-request',
      message: message,
      details: const <String, dynamic>{'code': 'gateway/bad-request'},
    );
    unawaited(_closeSocket(WebSocketStatus.protocolError, 'protocol-error'));
  }

  void _terminate(_TerminalFailure failure) {
    if (_closed || _terminal) return;
    _terminal = true;
    _terminalError = failure.error;
    _ready = false;
    _phase = 'lost';
    _failPending(failure.error);
    if (!_handshake.isCompleted) _handshake.completeError(failure.error);
    _cancelRetry();
    _setPhase('lost', error: failure.error);
    if (!_closed) {
      unawaited(_closeSocket(failure.closeCode, failure.error.code));
    }
  }

  void _setPhase(String phase, {RuntimeTransportFailure? error}) {
    _phase = phase;
    final params = <String, dynamic>{'phase': phase, 'attempt': _attempt};
    final host = _host;
    if (host != null) params['host'] = host.toJson();
    if (error != null) {
      final errorParams = <String, dynamic>{
        'code': error.code,
        'message': error.message,
      };
      final details = error.details;
      if (details != null) errorParams['details'] = details;
      params['error'] = errorParams;
    }
    _emit('remote.status', params);
  }

  void _emit(String method, Map<String, dynamic> params) {
    if (_events.isClosed) return;
    _events.add(<String, dynamic>{'method': method, 'params': params});
  }

  RuntimeTransportFailure _asFailure(Object error) {
    if (error is RuntimeTransportFailure) return error;
    if (error is TimeoutException) {
      return RuntimeTransportFailure(
        code: connectTimeoutCode,
        message: '连接电脑超时，请检查地址与网络后重试。',
        details: error.toString(),
      );
    }
    if (error is TlsException) return _tlsFailure(error);
    return RuntimeTransportFailure(
      code: 'remote/connect-failed',
      message: '连接电脑失败：$error',
      details: error.toString(),
    );
  }

  static Uri _normalizeEndpoint(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isScheme('wss')) {
      throw ArgumentError.value(raw, 'endpoint', '远程端点必须是 wss:// 地址');
    }
    if (uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(raw, 'endpoint', '远程端点不能携带用户信息');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw ArgumentError.value(raw, 'endpoint', '远程端点不能带查询串或片段（协议 §1.1）');
    }
    final path = uri.path;
    if (path.isEmpty || path == '/') {
      return uri.replace(path: '/app');
    }
    if (path != '/app') {
      throw ArgumentError.value(raw, 'endpoint', '远程端点路径必须是 /app（协议 §1.1）');
    }
    return uri;
  }

  static String _validateToken(String token) {
    if (token.isEmpty) {
      throw ArgumentError.value(token, 'token', '设备令牌不能为空');
    }
    for (final codeUnit in token.codeUnits) {
      if (codeUnit <= 0x20 || codeUnit == 0x7F) {
        throw ArgumentError.value(token, 'token', '设备令牌不能包含空白或控制字符');
      }
    }
    return token;
  }

  /// 建立只信任给定 CA 的 TLS 上下文。
  ///
  /// `withTrustedRoots: false` 排除系统根证书；没有设置
  /// `badCertificateCallback`，因此证书链验证失败时连接直接失败，不存在
  /// 「先接受、后判断」的中间态。
  static SecurityContext _pinnedSecurityContext(String pinnedCaPem) {
    if (pinnedCaPem.trim().isEmpty) {
      throw const RuntimeTransportFailure(
        code: 'remote/tls',
        message: '没有提供固定的 CA 证书，无法建立安全的远程连接。',
      );
    }
    final context = SecurityContext(withTrustedRoots: false);
    try {
      context.setTrustedCertificatesBytes(utf8.encode(pinnedCaPem));
    } on TlsException catch (error) {
      throw RuntimeTransportFailure(
        code: 'remote/tls',
        message: '固定 CA 证书加载失败：${error.message}。请重新配对这台电脑。',
        details: error.toString(),
      );
    } on ArgumentError catch (error) {
      throw RuntimeTransportFailure(
        code: 'remote/tls',
        message: '固定 CA 证书格式不正确：${error.message}。请确认传入的是 PEM 文本。',
        details: error.toString(),
      );
    } on Object catch (error) {
      throw RuntimeTransportFailure(
        code: 'remote/tls',
        message: '固定 CA 证书加载失败：$error',
        details: error.toString(),
      );
    }
    return context;
  }

  /// 按 UTF-8 字节截断，避免把多字节字符切成两半。
  static String _truncateUtf8(String value, int maxBytes) {
    final bytes = utf8.encode(value);
    if (bytes.length <= maxBytes) return value;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
  }
}

class _TerminalFailure implements Exception {
  const _TerminalFailure(this.error, this.closeCode);

  final RuntimeTransportFailure error;
  final int closeCode;
}

class _RetryableFailure implements Exception {
  const _RetryableFailure(this.error, {this.rateLimited = false});

  final RuntimeTransportFailure error;
  final bool rateLimited;
}

/// 重连退避策略（协议 §1.4）：指数退避 1 s → 30 s，抖动 ±20%。
///
/// 单独成类是为了让「等待多久」和「什么时候把失败计数清零」可以被单元测试直接
/// 证伪：这两条规则写错时，真机上表现为每 ≤10 s 重连一次，很难靠端到端观察发现。
class RemoteReconnectPolicy {
  /// 创建策略。[random] 只用于测试时给出确定的抖动序列。
  RemoteReconnectPolicy({Random? random}) : _random = random ?? Random();

  /// 退避基数表：第 n 次连续失败等待 `backoff[min(n, last)]`，再叠加 ±20% 抖动。
  ///
  /// 最后一档就是协议上限 30 s；不再增长，也不封顶到更小的值。
  static const List<Duration> backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// 抖动幅度：实际等待落在基数的 80%–120%。
  static const double jitterRatio = 0.2;

  /// 连接要存活这么久，下一次断开才把连续失败计数清零。
  ///
  /// 比首个退避档（1 s）长得多：宿主「接受连接后立刻关闭」时计数必须继续增长，
  /// 否则每次都会从 1 s 重新开始，等于没有退避。
  static const Duration healthyThreshold = Duration(seconds: 10);

  final Random _random;

  /// 第 [failures] 次连续失败（从 0 开始）需要等待多久。
  ///
  /// [rateLimited] 为 true 时（协议 §1.4 的 4003）不少于 30 s。
  Duration delayFor(int failures, {bool rateLimited = false}) {
    final index = failures < 0
        ? 0
        : (failures < backoff.length ? failures : backoff.length - 1);
    final base = backoff[index];
    final micros = (base.inMicroseconds * (1 + jitterRatio * (2 * _random.nextDouble() - 1))).round();
    final jittered = Duration(microseconds: micros);
    if (rateLimited && jittered < backoff.last) return backoff.last;
    return jittered;
  }

  /// 这次连接的存活时长是否足以把失败计数清零。
  ///
  /// [lifetime] 为 null 表示这次连接从未握手成功（纯失败），必须继续累计失败。
  bool resetsAfter(Duration? lifetime) =>
      lifetime != null && lifetime >= healthyThreshold;
}
