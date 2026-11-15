// 局域网发现：在手机上调 UDP 广播找同一网段的远程 DSH 宿主。
//
// 发现只解决「免手输」：宿主在应答里给出**已有的配对链接**，拿到链接后仍然走
// `remote_pairing.dart` / `remote_pairing_flow.dart` 的既有配对流程（取 CA、校验
// instanceId、一次性令牌换设备令牌）。本模块不建立信任、不连接 wss、不写设备表。
//
// 协议唯一来源是 `apps/android/docs/remote-dsh/discovery.md`（v1）：
// - 探测：`{"v":1,"probe":"DSH-REMOTE-DISCOVER","nonce":"<4–128 base64url>"}`
//   广播到 UDP 4778；
// - 应答：`{v,kind:"dsh-remote-host",name,origin,instanceId,pairing:{open,pairUrl,expiresAt},nonce}`，
//   只接受单播回复、只接受本轮 nonce 的回显；坏帧静默丢弃。
//
// 本文件不依赖 Flutter（只用 dart:io / dart:convert），可以在纯 Dart 测试里注入假
// 套接字或直接调用 [parseRemoteDiscoveryReply]。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'remote_pairing.dart';

/// 发现协议版本；与宿主 `apps/remote-host/src/discovery.ts` 的 `v` 一致。
const int remoteDiscoveryVersion = 1;

/// 探测帧的协议标记。
const String remoteDiscoveryProbe = 'DSH-REMOTE-DISCOVER';

/// 宿主默认监听的 UDP 发现端口。
const int remoteDiscoveryDefaultPort = 4778;

/// 一次搜索默认收集应答的窗口。
const Duration remoteDiscoveryDefaultWindow = Duration(milliseconds: 2500);

/// 窗口内第二次发送探测的延迟：UDP 没有重传，多发一帧降低丢包概率。
const Duration remoteDiscoveryProbeRetryDelay = Duration(milliseconds: 1000);

/// 单帧应答的字节上限（discovery.md §2.1：最坏 866 B，上限 1400 B）。
const int remoteDiscoveryMaxDatagramBytes = 1400;

/// 探测帧里 nonce 的字节数（base64url 后 22 个字符，落在 4–128 的允许区间）。
const int remoteDiscoveryNonceBytes = 16;

/// `instanceId` 的线上形态：CA 证书 DER 的 SHA-256（64 位小写十六进制）。
final RegExp _instanceIdPattern = RegExp(r'^[0-9a-f]{64}$');

/// 一次局域网发现失败。
///
/// [code] 供页面区分失败环节（`discovery/socket`、`discovery/send`），[message] 是
/// 可直接展示的中文；发现失败不是配对失败，页面必须同时保留扫码/粘贴入口。
class RemoteDiscoveryFailure implements Exception {
  /// 记录失败类别与可展示文案。
  const RemoteDiscoveryFailure(this.code, this.message, [this.details]);

  /// 失败类别。
  final String code;

  /// 可直接展示的中文说明。
  final String message;

  /// 原始异常，只用于排障。
  final Object? details;

  @override
  String toString() => 'RemoteDiscoveryFailure($code): $message';
}

/// 一台被发现的远程 DSH 宿主。
///
/// [pairLink] 只在宿主配对窗口打开时非空，内容是完整的一次性配对链接（含 token）；
/// **不要把它写进日志或崩溃上报**。[toString] 已刻意省略链接。
class RemoteDiscoveredHost {
  /// 记录一次宿主应答。
  const RemoteDiscoveredHost({
    required this.name,
    required this.origin,
    required this.instanceId,
    this.pairLink,
    this.pairingExpiresAt,
  });

  /// 宿主显示名（≤ 120 字符，与握手 `host.name` 一致）。
  final String name;

  /// 宿主对外宣告的 `wss://host[:port]`。
  final Uri origin;

  /// 宿主 CA 证书的 SHA-256 指纹（64 位小写十六进制）。
  final String instanceId;

  /// 完整配对链接；`null` 表示配对窗口当前未打开或已过期。
  final String? pairLink;

  /// 配对窗口关闭时间（UTC）；窗口未打开时为 null。
  final DateTime? pairingExpiresAt;

  /// 配对窗口此刻是否打开（宿主回 `pairing.open=true` 且链接通过既有解析校验）。
  bool get pairingOpen => pairLink != null;

  /// 给用户看的电脑地址：`host:port`（origin 省略端口时只显示 host）。
  String get address =>
      origin.hasPort ? '${origin.host}:${origin.port}' : origin.host;

  /// 排障用的概述；不含配对链接与令牌。
  @override
  String toString() =>
      'RemoteDiscoveredHost($name, $address, open=$pairingOpen)';
}

/// 发现接口：页面只依赖它，测试注入假实现即可不碰真实 UDP。
abstract class RemoteDiscovery {
  /// 广播一次探测并在 [window] 内收集应答；同一宿主只保留第一条。
  ///
  /// 失败抛 [RemoteDiscoveryFailure]（无法绑定/发送广播），超时无应答返回空列表。
  Future<List<RemoteDiscoveredHost>> discover({
    Duration window = remoteDiscoveryDefaultWindow,
  });

  /// 释放后台套接字；页面销毁时调用，进行中的 [discover] 会尽快结束。
  void dispose();
}

/// 解析一帧宿主应答；不是本轮应答或字段不合法时返回 null（静默丢弃）。
///
/// [nonce] 是本轮探测发出的随机串，宿主必须原样回显；`pairing.open=true` 时
/// `pairUrl` 必须能被既有 [PairingDescriptor.parse] 接受，且其中的 `instanceId`
/// 必须与顶层字段一致（否则视为伪造/错配，丢弃整帧）。
RemoteDiscoveredHost? parseRemoteDiscoveryReply(
  String raw, {
  required String nonce,
}) {
  if (raw.isEmpty || raw.length > remoteDiscoveryMaxDatagramBytes) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['v'] != remoteDiscoveryVersion) return null;
  if (decoded['kind'] != 'dsh-remote-host') return null;
  if (decoded['nonce'] != nonce) return null;

  final name = decoded['name'];
  if (name is! String) return null;
  final trimmedName = name.trim();
  if (trimmedName.isEmpty || trimmedName.runes.length > 120) return null;

  final origin = _parseOrigin(decoded['origin']);
  if (origin == null) return null;

  final instanceId = decoded['instanceId'];
  if (instanceId is! String || !_instanceIdPattern.hasMatch(instanceId)) {
    return null;
  }

  final pairing = decoded['pairing'];
  if (pairing is! Map) return null;
  final open = pairing['open'];
  if (open is! bool) return null;
  if (!open) {
    return RemoteDiscoveredHost(
      name: trimmedName,
      origin: origin,
      instanceId: instanceId,
    );
  }

  final pairUrl = pairing['pairUrl'];
  if (pairUrl is! String) return null;
  final PairingDescriptor descriptor;
  try {
    descriptor = PairingDescriptor.parse(pairUrl);
  } on FormatException {
    // 链接形状不合法：整帧丢弃（发现只是提示，宁可少一台也不递坏链接）。
    return null;
  }
  if (descriptor.instanceId != instanceId) return null;

  final expiresAt = pairing['expiresAt'];
  if (expiresAt is! int || expiresAt <= 0) return null;
  return RemoteDiscoveredHost(
    name: trimmedName,
    origin: origin,
    instanceId: instanceId,
    pairLink: pairUrl,
    pairingExpiresAt: DateTime.fromMillisecondsSinceEpoch(
      expiresAt,
      isUtc: true,
    ),
  );
}

/// 校验 `origin`：只接受 `wss://host[:port]`，不带路径/查询串/片段/用户信息。
Uri? _parseOrigin(Object? raw) {
  if (raw is! String) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (uri.scheme != 'wss') return null;
  if (uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
  if (uri.path.isNotEmpty && uri.path != '/') return null;
  if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
  return uri;
}

/// 创建一次 UDP 发现用的套接字。
typedef RemoteDiscoverySocketFactory = Future<RawDatagramSocket> Function();

/// 探测广播的目标地址；测试可以只给回环地址，避免依赖真实网络。
typedef RemoteDiscoveryTargets = Future<List<InternetAddress>> Function();

/// `dart:io` 的生产实现：一次 [discover] 打开一个临时 UDP 套接字，窗口结束即关闭。
///
/// 懒加载由页面控制：只有用户点「搜索局域网」才调用 [discover]，页面销毁时
/// [dispose]；这里没有任何常驻定时器或轮询。
class UdpRemoteDiscovery implements RemoteDiscovery {
  /// 创建发现实现。
  ///
  /// [port] 是宿主发现端口；[socketFactory]、[targets] 与 [random] 只用于测试：
  /// 测试可以把套接字绑到回环、只发回环目标，并注入确定性 nonce 随机源。
  UdpRemoteDiscovery({
    this.port = remoteDiscoveryDefaultPort,
    this.probeRetryDelay = remoteDiscoveryProbeRetryDelay,
    RemoteDiscoverySocketFactory? socketFactory,
    RemoteDiscoveryTargets? targets,
    Random? random,
  }) : _socketFactory =
           socketFactory ??
           (() => RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)),
       _targets = targets ?? _defaultTargets,
       _random = random ?? Random.secure();

  /// 宿主 UDP 发现端口。
  final int port;

  /// 窗口内第二次发送探测的延迟；测试可以缩短以加快超时用例。
  final Duration probeRetryDelay;

  final RemoteDiscoverySocketFactory _socketFactory;
  final RemoteDiscoveryTargets _targets;
  final Random _random;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Completer<void>? _done;
  bool _disposed = false;

  @override
  Future<List<RemoteDiscoveredHost>> discover({
    Duration window = remoteDiscoveryDefaultWindow,
  }) async {
    if (_disposed) {
      throw const RemoteDiscoveryFailure(
        'discovery/disposed',
        '页面已关闭，请重新打开后再搜索局域网。',
      );
    }
    if (_socket != null) {
      throw const RemoteDiscoveryFailure('discovery/busy', '正在搜索局域网里的电脑，请稍候。');
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', '搜索窗口必须大于 0');
    }
    final socket = await _openSocket();
    if (_disposed) {
      _closeQuietly(socket);
      throw const RemoteDiscoveryFailure(
        'discovery/disposed',
        '页面已关闭，请重新打开后再搜索局域网。',
      );
    }
    _socket = socket;
    final nonce = createRemoteDiscoveryNonce(_random);
    final hosts = <String, RemoteDiscoveredHost>{};
    final done = Completer<void>();
    _done = done;

    var sendsSucceeded = 0;
    var sendsFailed = 0;
    final payload = utf8.encode(
      jsonEncode(<String, Object?>{
        'v': remoteDiscoveryVersion,
        'probe': remoteDiscoveryProbe,
        'nonce': nonce,
      }),
    );

    void sendProbe(List<InternetAddress> targets) {
      for (final target in targets) {
        try {
          socket.send(payload, target, port);
          sendsSucceeded += 1;
        } on Object {
          sendsFailed += 1;
        }
      }
    }

    try {
      socket.broadcastEnabled = true;
    } on Object {
      // 个别平台禁止广播：仍然尝试发送，失败会在下方按「无法发送」报出。
    }
    _applyProbeTtl(socket);

    final targets = await _safeTargets();
    _subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final data = datagram!.data;
          if (data.length > remoteDiscoveryMaxDatagramBytes) continue;
          final String raw;
          try {
            raw = utf8.decode(data);
          } on FormatException {
            continue;
          }
          final host = parseRemoteDiscoveryReply(raw, nonce: nonce);
          if (host == null) continue;
          hosts.putIfAbsent(host.instanceId, () => host);
        }
      },
      onError: (Object _) {
        // 入站套接字错误按「这次没有收到」处理：发现是尽力而为，页面还有扫码/粘贴。
      },
    );
    sendProbe(targets);
    final retry = Timer(probeRetryDelay, () {
      if (!_disposed) sendProbe(targets);
    });
    final timer = Timer(window, () {
      if (!done.isCompleted) done.complete();
    });

    try {
      await done.future;
    } finally {
      retry.cancel();
      timer.cancel();
      final subscription = _subscription;
      _subscription = null;
      if (subscription != null) {
        try {
          await subscription.cancel();
        } on Object {
          // 套接字可能已被系统关闭；取消失败不影响已收集的结果。
        }
      }
      _closeQuietly(socket);
      _socket = null;
      _done = null;
    }

    if (hosts.isEmpty && sendsSucceeded == 0 && sendsFailed > 0) {
      throw const RemoteDiscoveryFailure(
        'discovery/send',
        '无法发送局域网发现广播。请确认手机已联网并与电脑在同一网段，'
            '或改用扫码/粘贴配对链接。',
      );
    }
    return hosts.values.toList();
  }

  @override
  void dispose() {
    _disposed = true;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// 绑定一个临时 UDP 套接字；失败翻译成可展示的中文。
  Future<RawDatagramSocket> _openSocket() async {
    try {
      return await _socketFactory();
    } on SocketException catch (failure) {
      throw RemoteDiscoveryFailure(
        'discovery/socket',
        '无法打开局域网发现端口：${failure.message}。'
            '请确认手机已联网，或改用扫码/粘贴配对链接。',
        failure,
      );
    } on Object catch (failure) {
      throw RemoteDiscoveryFailure(
        'discovery/socket',
        '无法启动局域网发现：$failure。请改用扫码或粘贴配对链接。',
        failure,
      );
    }
  }

  /// 出站 TTL=1：探测不跨路由。Android/Linux 的 IP_TTL 选项号是 2；失败只忽略。
  void _applyProbeTtl(RawDatagramSocket socket) {
    try {
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelIPv4, 2, 1),
      );
    } on Object {
      // 测试环境（Windows/macOS）或受限内核可能不支持该选项；不影响发现语义。
    }
  }

  Future<List<InternetAddress>> _safeTargets() async {
    try {
      return await _targets();
    } on Object {
      // 枚举网卡失败时退回全局广播。
      return <InternetAddress>[InternetAddress('255.255.255.255')];
    }
  }

  void _closeQuietly(RawDatagramSocket socket) {
    try {
      socket.close();
    } on Object {
      // 已关闭的套接字重复关闭会抛错；释放是尽力动作。
    }
  }

  /// 默认探测目标：全局广播 + 每个本机 IPv4 网卡按 /24 猜测的子网广播。
  ///
  /// Dart 的 `NetworkInterface` 不暴露子网掩码，无法精确计算定向广播；猜错的目标
  /// 收不到应答但不会有副作用，全局广播仍是主路径。
  static Future<List<InternetAddress>> _defaultTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          final raw = address.rawAddress;
          if (raw.length != 4) continue;
          targets.add('${raw[0]}.${raw[1]}.${raw[2]}.255');
        }
      }
    } on Object {
      // 枚举失败只用全局广播。
    }
    return targets.map(InternetAddress.new).toList();
  }
}

/// 生成一轮探测的 nonce：16 字节随机数的 base64url（22 字符，去掉填充）。
///
/// 协议要求 4–128 个 `[A-Za-z0-9_-]`；[Random.nextInt] 逐字节生成，测试可以注入
/// 固定种子让断言可复现。
String createRemoteDiscoveryNonce(Random random) {
  final bytes = List<int>.generate(
    remoteDiscoveryNonceBytes,
    (_) => random.nextInt(256),
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}
