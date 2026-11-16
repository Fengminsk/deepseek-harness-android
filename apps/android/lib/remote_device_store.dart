/// 远程设备的本机存储：非机密字段进偏好，设备令牌进 Android Keystore。
///
/// 分工来自 `docs/remote-dsh-plan.md` §5.4 的存储决定：
///
/// - 设备 id、显示名、地址、端口、`instanceId`、固定的 CA 证书、时间戳，以及
///   握手后学到的电脑显示名存偏好（沿用 `network_proxy.dart` 用的 `dsh/runtime`
///   原生偏好通道，不引入新包）；
/// - 设备令牌只以 `credentials.set` 写进 Android Keystore，偏好里只有指向它的
///   引用 [RemoteDevice.tokenRef]，因此本文件任何返回值都不含明文令牌。
///
/// 偏好里另有一项 `lastConnectedDeviceId`，记录上次成功连接的设备，决定冷启动时
/// 首页自动连接哪一台（见 [RemoteDeviceStore.markConnected]）。它只是连接提示，
/// 不是信任锚：指向不存在的设备时按「没有记录」处理，并在下一次写入时收敛。
///
/// ## 信任锚在读取路径上复核
///
/// 偏好里的 `caPem` 与 `instanceId` 是同一枚信任锚的两半。只校验 PEM 头远远不够：
/// 偏好被改写、或记录与证书来自两次不同配对时，「清单里的指纹」和「真正拿去固定
/// TLS 的证书」就会不一致，App 会拿一张未经确认的证书去连电脑。[load] 因此重新
/// 计算 `SHA-256(CA DER)` 并与 `instanceId` 比对，不等就抛
/// [RemoteDeviceStoreException]（`remote/instance-mismatch`），绝不静默信任。
///
/// ## 两处契约限制（原生/门面侧补齐前不会自行消失）
///
/// 1. `dsh/runtime` 通道没有通用 key-value 方法，只有 `network.proxy.*`、
///    `appearance.*` 这类专用方法。本文件按同一模式使用 [remoteDevicesReadMethod]
///    与 [remoteDevicesSaveMethod]：Kotlin 侧要补同名的两个 `when` 分支（读一个
///    JSON 字符串、写回同一个字符串）。缺方法时抛
///    `remote/preferences-unavailable`，不静默当成空列表。
/// 2. 设备令牌的明文读取经 `credentials.read`（[RuntimeCredentialVault.read]）。
///    原生/门面侧没有提供该方法时读到的是明确异常（`remote/credential-failed`），
///    由页面提示重新配对，而不是假装「未配对」。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'remote_pairing.dart';
import 'runtime.dart';

/// 读取设备列表偏好的通道方法名（`dsh/runtime`）。
const String remoteDevicesReadMethod = 'remote.devices.read';

/// 写入设备列表偏好的通道方法名（`dsh/runtime`）。
const String remoteDevicesSaveMethod = 'remote.devices.save';

/// 偏好读写的超时；与 `network_proxy.dart` 的偏好超时一致。
const Duration remoteDevicePreferenceTimeout = Duration(seconds: 5);

/// 设备列表的大小上限。
///
/// 一条记录只有几百字节（CA PEM 是最大项），64 KiB 足够几十台设备；设上限是为了
/// 不让一次异常写入把偏好撑坏。
const int remoteDevicePreferencesMaxBytes = 64 * 1024;

/// 偏好里设备列表的格式版本。
const int remoteDeviceStoreVersion = 1;

/// 偏好里「上次成功连接的设备」字段名。
///
/// 它与 `version` / `devices` 平级，值是设备 id。旧版本 App 读这张表时忽略这个
/// 字段（因此不构成数据损坏），写回时会丢掉它——那只会让下次冷启动少一条
/// 「自动连上次那台」的提示，不会影响设备与令牌本身。
const String remoteLastConnectedDeviceKey = 'lastConnectedDeviceId';

/// 设备 id 的线上形态：32 位小写十六进制（`apps/remote-host/src/devices.ts`）。
final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{32}$');

/// 设备令牌的线上形态：43 字符 base64url（协议 §2.1）。
final RegExp _deviceTokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// `instanceId` 的线上形态：64 位小写十六进制（`apps/remote-host/src/identity.ts`）。
final RegExp _instancePattern = RegExp(r'^[0-9a-f]{64}$');

/// 设备显示名里不允许出现的控制字符。
final RegExp _controlCharacterPattern = RegExp(r'[\u0000-\u001f\u007f]');

/// 主机名里不允许出现的空白字符。
final RegExp _whitespacePattern = RegExp(r'\s');

/// `tokenRef` 的形状：`remote-device/<32 位十六进制设备 id>`。
final RegExp _tokenReferencePattern = RegExp(r'^remote-device/([0-9a-f]{32})$');

/// 设备存储的一次失败。
///
/// [code] 供页面分支，[message] 是可直接展示的中文句子。本文件不把任何失败降级成
/// 「空列表」或「未配对」。
class RemoteDeviceStoreException implements Exception {
  /// 记录失败类别、可展示文案与原始异常。
  const RemoteDeviceStoreException(this.code, this.message, [this.details]);

  /// 失败类别，例如 `remote/preferences-unavailable`。
  final String code;

  /// 可直接展示的中文说明。
  final String message;

  /// 原始异常，只用于排障。
  final Object? details;

  @override
  String toString() => 'RemoteDeviceStoreException($code): $message';
}

/// 一台已配对的电脑。
///
/// 令牌本身不在这里，只有指向本机密钥库的引用 [tokenRef]。所有字段都是非机密的：
/// 地址、端口、CA 证书、时间戳，以及握手后学到的电脑显示名（[hostName]）。
///
/// [label] 是**配对时上报的手机显示名**（与 `protocol.hello` 的 `deviceLabel`
/// 同值），不是电脑名：同一台手机配对的电脑会得到相同的 label。电脑名只有握手
/// （`host.name`）里才有，因此 [hostName] 从第一次连接成功起才存在。展示电脑时
/// 用 [displayName]。
///
/// ## 两种 TLS 信任模式（[systemTrust]）
///
/// - `false`（默认，pinned）：直连电脑自己的 TLS 端点。连接只信任 [caPem] 这张
///   自签 CA（`SecurityContext(withTrustedRoots: false)`），配对时也用同一个
///   信任库验证 `/pair`。局域网、组网与 TCP 直通反代都属于这一类。
/// - `true`（HTTPS 反代）：TLS 在反代处终止，App 看到的是反代出示的**公网证书**。
///   连接与配对改用系统根证书校验（含主机名），因此必须是有公网 CA 签发证书的
///   域名；[caPem] 与 [instanceId] 仍然保存并在读回时复核，作为「反代后面是同一
///   台电脑」的身份绑定（`/ca.cer` 的响应体指纹必须等于 [instanceId]）。
///
/// 模式是配对时用户显式选择的，不会根据地址猜测：同一台电脑换一条网络路径就要
/// 重新配对，两种模式不能共用一条记录。
class RemoteDevice {
  /// 创建一台已配对电脑的记录。
  ///
  /// 字段非法时抛 [FormatException]（中文消息），例如从偏好里读回被改坏的数据。
  /// [systemTrust] 省略为 `false`，与旧版本 App 写下的记录一致。
  RemoteDevice({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.instanceId,
    required this.caPem,
    required this.createdAt,
    this.lastSeenAt,
    String? hostName,
    this.systemTrust = false,
  }) : hostName = _normalizedHostName(hostName),
       tokenRef = 'remote-device/$id' {
    if (!_deviceIdPattern.hasMatch(id)) {
      throw const FormatException('设备标识必须是 32 位小写十六进制。');
    }
    if (!_validLabel(label)) {
      throw const FormatException('设备名必须是 1–120 个非控制字符。');
    }
    final name = this.hostName;
    if (name != null && !_validLabel(name)) {
      throw const FormatException('电脑名必须是 1–120 个非控制字符。');
    }
    if (host.isEmpty ||
        host.contains('/') ||
        _whitespacePattern.hasMatch(host)) {
      throw const FormatException('设备地址不合法，应为不带协议的电脑主机名或 IP。');
    }
    if (port < 1 || port > 65535) {
      throw const FormatException('设备端口必须在 1–65535 之间。');
    }
    if (!_instancePattern.hasMatch(instanceId)) {
      throw const FormatException('instanceId 必须是 64 位小写十六进制（CA 指纹）。');
    }
    if (!caPem.contains('-----BEGIN CERTIFICATE-----')) {
      throw const FormatException('固定 CA 必须是 PEM 文本。');
    }
  }

  /// 从偏好里的 JSON 记录还原；缺少字段或字段非法时抛 [FormatException]。
  factory RemoteDevice.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('设备记录不是 JSON 对象。');
    }
    final id = value['id'];
    final label = value['label'];
    final host = value['host'];
    final port = value['port'];
    final instanceId = value['instanceId'];
    final caPem = value['caPem'];
    final createdAt = value['createdAt'];
    final lastSeenAt = value['lastSeenAt'];
    final hostName = value['hostName'];
    final systemTrust = value['systemTrust'];
    if (id is! String) throw const FormatException('设备记录缺少 id。');
    if (label is! String) throw const FormatException('设备记录缺少显示名。');
    if (host is! String) throw const FormatException('设备记录缺少地址。');
    if (port is! int) throw const FormatException('设备记录的端口不是整数。');
    if (instanceId is! String) {
      throw const FormatException('设备记录缺少 instanceId。');
    }
    if (caPem is! String) throw const FormatException('设备记录缺少 CA 证书。');
    if (createdAt is! int) throw const FormatException('设备记录缺少配对时间。');
    if (lastSeenAt != null && lastSeenAt is! int) {
      throw const FormatException('设备记录的最后在线时间不是整数。');
    }
    if (hostName != null && hostName is! String) {
      throw const FormatException('设备记录的电脑名不是字符串。');
    }
    if (systemTrust != null && systemTrust is! bool) {
      throw const FormatException('设备记录的信任模式不是布尔值。');
    }
    return RemoteDevice(
      id: id,
      label: label,
      host: host,
      port: port,
      instanceId: instanceId,
      caPem: caPem,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
      lastSeenAt: lastSeenAt is int
          ? DateTime.fromMillisecondsSinceEpoch(lastSeenAt, isUtc: true)
          : null,
      hostName: hostName is String ? hostName : null,
      // 旧版本 App 写的记录没有这个字段：一律按 pinned 读回（迁移默认值）。
      systemTrust: systemTrust is bool ? systemTrust : false,
    );
  }

  /// 设备 id，PC 的设备表签发（32 位小写十六进制）。
  final String id;

  /// 设备显示名（1–120 个非控制字符），配对时由手机上报。
  final String label;

  /// 电脑地址（主机名或 IP，不带协议与端口）。
  final String host;

  /// 电脑的 wss/配对端口。
  final int port;

  /// 这台电脑 CA 证书的 SHA-256 指纹；与配对链接里的 `instance` 相同。
  final String instanceId;

  /// 配对时固定的 CA 证书 PEM 文本，交给 `RemoteRuntimeTransport` 做 TLS 固定。
  ///
  /// [systemTrust] 为 true 时它不参与本次 TLS 验证（对端出示的是反代的公网证书），
  /// 但仍用于身份绑定：读回记录时复核 `SHA-256(DER) == instanceId`，配对时也用
  /// `/ca.cer` 的响应体验证同一个指纹。
  final String caPem;

  /// TLS 信任模式：`false` 固定 [caPem]，`true` 使用系统根证书（HTTPS 反代）。
  ///
  /// 旧记录没有这个字段，读回时按 `false` 处理；模式只能由配对入口显式选择。
  final bool systemTrust;

  /// 配对成功时间。
  final DateTime createdAt;

  /// 最近一次成功配对或连接的时间；从未连接时为 null。
  ///
  /// 配对成功会写入一次，之后每次握手进入就绪也会更新（[RemoteDeviceStore.markConnected]）。
  final DateTime? lastSeenAt;

  /// 那台电脑自报的显示名（`protocol.hello` 的 `host.name`）。
  ///
  /// 配对链接里没有电脑名，因此它从第一次连接成功起才有值；从未连接过的电脑为
  /// null。展示时用 [displayName]，不要直接读这个字段。
  final String? hostName;

  /// 本机密钥库里设备令牌的引用（`remote-device/<id>`）。
  ///
  /// 它是**引用**而不是令牌本身：明文只进 Keystore，绝不写进偏好。
  final String tokenRef;

  /// 展示给用户的电脑名。
  ///
  /// 电脑自报名优先；从未成功连接过的电脑还不知道它叫什么，退回地址（IP 或主机
  /// 名）。[label] 是配对时上报的手机名，不能当电脑名用。
  String get displayName {
    final name = hostName?.trim() ?? '';
    return name.isEmpty ? host : name;
  }

  /// `RemoteRuntimeTransport` 使用的端点：`wss://<host>:<port>/app`。
  Uri get appEndpoint =>
      Uri(scheme: 'wss', host: host, port: port, path: '/app');

  /// 更新显示名、最后在线时间、电脑名或信任模式后的新记录；[id] 与 CA 不变。
  ///
  /// [hostName] 传 null 表示保持原值（无法用本方法清空电脑名）；
  /// [systemTrust] 传 null 表示保持原值。
  RemoteDevice copyWith({
    String? label,
    DateTime? lastSeenAt,
    String? hostName,
    bool? systemTrust,
  }) => RemoteDevice(
    id: id,
    label: label ?? this.label,
    host: host,
    port: port,
    instanceId: instanceId,
    caPem: caPem,
    createdAt: createdAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    hostName: hostName ?? this.hostName,
    systemTrust: systemTrust ?? this.systemTrust,
  );

  /// 偏好里的持久形态。
  ///
  /// 不含 [tokenRef]：它由 [id] 推导，存两份会让两处可能不一致。只有
  /// [systemTrust] 为 true 时才写这个字段，旧版本 App 因此仍读到 pinned 语义。
  Json toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'host': host,
    'port': port,
    'instanceId': instanceId,
    'caPem': caPem,
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (lastSeenAt != null) 'lastSeenAt': lastSeenAt!.millisecondsSinceEpoch,
    if (hostName != null) 'hostName': hostName,
    if (systemTrust) 'systemTrust': true,
  };
}

/// 规范化可选电脑名：去掉首尾空白；空串与 null 都表示「还不知道」。
String? _normalizedHostName(String? hostName) {
  final trimmed = hostName?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// 设备显示名是否满足 PC 侧同一份约束（`devices.ts`）：1–120 个非控制字符。
bool _validLabel(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty || trimmed.runes.length > 120) return false;
  return !_controlCharacterPattern.hasMatch(label);
}

/// 本机设备表的一次完整读数：已配对电脑与「上次成功连接的设备」。
///
/// 两者来自同一份偏好，一次读取同时返回，避免页面先读设备再单独读连接提示时看到
/// 两份不同代的数据。[lastConnectedDeviceId] 只是自动连接的提示，不是信任锚：
/// 它指向不存在的设备时按「没有记录」处理（读取时收敛，写入时清掉）。
class RemoteDeviceTable {
  const RemoteDeviceTable({
    this.devices = const <RemoteDevice>[],
    this.lastConnectedDeviceId,
  });

  /// 已配对电脑，按配对时间升序。
  final List<RemoteDevice> devices;

  /// 上次成功连接的设备 id；从未成功连接过（或记录已失效）时为 null。
  final String? lastConnectedDeviceId;

  /// 上次成功连接的设备；没有记录时为 null。
  RemoteDevice? get lastConnectedDevice {
    final id = lastConnectedDeviceId;
    if (id == null) return null;
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }
}

/// 设备令牌在本机的保管口。
///
/// 默认实现 [RuntimeCredentialVault] 走本机运行时的 `credentials.*` 方法，令牌进
/// Android Keystore。单测可以换成内存实现，不需要 Flutter 绑定。
abstract class RemoteDeviceTokenVault {
  /// 令牌是否已保存（`credentials.describe` 的 `configured`）。
  Future<bool> isConfigured(String tokenRef);

  /// 写入令牌（`credentials.set`）。[tokenRef] 是 [RemoteDevice.tokenRef] 的形态。
  Future<void> write(String tokenRef, String token);

  /// 删除令牌（`credentials.unset`）；删除不存在的引用不视为失败。
  Future<void> delete(String tokenRef);

  /// 读回明文令牌。
  ///
  /// DSH 的 credentials 门面没有读通道，默认实现因此总是抛异常；存在的实现
  /// （例如原生侧新增了读取方法）可以在单测或后续版本里提供。
  Future<String> read(String tokenRef);
}

/// 通过本机运行时 `credentials.describe` / `set` / `unset` 保管令牌。
class RuntimeCredentialVault implements RemoteDeviceTokenVault {
  /// 绑定本机运行时。
  RuntimeCredentialVault(this.runtime);

  /// 本机运行时；`credentials.*` 需要它已经就绪（`runtime.ready`）。
  final RuntimeController runtime;

  /// 单次凭据调用的超时；与 `credentials_data.dart` 取同一量级。
  static const Duration requestTimeout = Duration(seconds: 20);

  @override
  Future<bool> isConfigured(String tokenRef) async {
    final status = await _call('credentials.describe', {
      'ref': credentialReferenceFor(tokenRef),
    });
    if (status is! Map || status['configured'] is! bool) {
      throw RemoteDeviceStoreException(
        'remote/credential-status',
        '本机凭据服务返回的设备令牌状态无法识别，未能确认这台电脑是否已配对。',
        status,
      );
    }
    return status['configured'] as bool;
  }

  @override
  Future<void> write(String tokenRef, String token) async {
    if (!_deviceTokenPattern.hasMatch(token)) {
      throw const FormatException('设备令牌必须是 43 个字符的 base64url 字符串。');
    }
    final receipt = await _call('credentials.set', {
      'ref': credentialReferenceFor(tokenRef),
      'value': token,
    });
    if (receipt is! Map || receipt['configured'] != true) {
      throw RemoteDeviceStoreException(
        'remote/credential-write',
        '本机凭据服务没有确认设备令牌已保存，配对未落地。',
        receipt,
      );
    }
  }

  @override
  Future<void> delete(String tokenRef) async {
    // unset 对不存在的引用同样是成功：删除是幂等动作，不需要先 describe。
    await _call('credentials.unset', {'ref': credentialReferenceFor(tokenRef)});
  }

  @override
  Future<String> read(String tokenRef) async {
    // 明文只能经 `credentials.read` 取回：`describe` 只报告存在性，而远程连接在
    // 冷启动时必须拿到令牌才能重连，否则用户会被要求无谓地重新配对。
    final result = await _call('credentials.read', {
      'ref': credentialReferenceFor(tokenRef),
    });
    final value = result is Map ? result['value'] : null;
    if (value is! String || value.isEmpty) {
      throw const RemoteDeviceStoreException(
        'remote/credential-read',
        '本机密钥库里没有这台电脑的设备令牌，请重新配对。',
      );
    }
    return value;
  }

  Future<dynamic> _call(String method, Json params) async {
    try {
      return await runtime.call(method, params).timeout(requestTimeout);
    } on TimeoutException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/credential-timeout',
        '等待本机凭据服务响应超时（${requestTimeout.inSeconds} 秒）。',
        failure,
      );
    } on PlatformException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/credential-failed',
        '本机凭据服务拒绝了这次操作：${failure.message ?? failure.code}。',
        failure,
      );
    }
  }
}

/// 把 [RemoteDevice.tokenRef] 映射成本机凭据服务接受的引用。
///
/// DSH 的引用语法是 `^[A-Za-z_][A-Za-z0-9_]*$`（`packages/credentials` 的
/// `credentialRef`），`remote-device/<id>` 里的 `/` 与 `-` 会被它直接拒绝。映射
/// 只发生在这里：对外的 `tokenRef` 保持 `remote-device/<id>`，进凭据调用前换成
/// `remote_device_<id>`。
String credentialReferenceFor(String tokenRef) {
  final match = _tokenReferencePattern.firstMatch(tokenRef);
  if (match == null) {
    throw FormatException(
      '设备令牌引用必须是 remote-device/<32 位十六进制设备 id>，收到：$tokenRef。',
    );
  }
  return 'remote_device_${match.group(1)}';
}

/// 已配对电脑的本机存储。
///
/// 偏好里只放非机密字段；设备令牌只写进 Keystore，偏好里只有
/// [RemoteDevice.tokenRef]。读失败、写失败、数据损坏都抛
/// [RemoteDeviceStoreException]，不会把失败降级成空列表。
class RemoteDeviceStore {
  /// 创建存储。
  ///
  /// [channel] 默认是 `dsh/runtime`（与 `network_proxy.dart` 同一个通道）；
  /// [runtime] 用于默认的 [RuntimeCredentialVault]；[tokens] 用于测试注入。
  /// [runtime] 与 [tokens] 至少要给一个，否则构造即抛 [ArgumentError]。
  RemoteDeviceStore({
    MethodChannel? channel,
    RuntimeController? runtime,
    RemoteDeviceTokenVault? tokens,
  }) : _channel = channel ?? RuntimeController.channel,
       _tokens = tokens ?? _defaultVault(runtime);

  final MethodChannel _channel;
  final RemoteDeviceTokenVault _tokens;

  /// 本次进程内刚写入的令牌。
  ///
  /// 配对当次已经有明文，先从缓存返回可以少打一次凭据调用；缓存为空时回落到
  /// [RemoteDeviceTokenVault.read]（默认实现走 `credentials.read`）。
  final Map<String, String> _tokensInMemory = <String, String>{};

  static RemoteDeviceTokenVault _defaultVault(RuntimeController? runtime) {
    if (runtime == null) {
      throw ArgumentError('RemoteDeviceStore 需要 runtime 或 tokens 之一。');
    }
    return RuntimeCredentialVault(runtime);
  }

  /// 读出全部已配对电脑与「上次成功连接的设备」，按配对时间升序。
  ///
  /// 每条记录都会重新核对 `SHA-256(CA DER) == instanceId`：两半信任锚不一致时抛
  /// [RemoteDeviceStoreException]（`remote/instance-mismatch`），不把记录交给调用方。
  /// 偏好为空时返回空表；内容损坏、版本不认识或存在重复 id 时同样抛异常，
  /// 不做任何自动修正或丢弃。
  ///
  /// 唯一例外是 [RemoteDeviceTable.lastConnectedDeviceId]：它只是自动连接的提示，
  /// 指向不存在的设备（或形态不合法）时按「没有记录」返回，不因此拒绝整张设备表。
  Future<RemoteDeviceTable> loadTable() async {
    final raw = await _readPreferences();
    if (raw == null || raw.trim().isEmpty) {
      return const RemoteDeviceTable();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences-corrupt',
        '本机保存的设备列表不是合法 JSON，未做任何改写。',
        failure,
      );
    }
    if (decoded is! Map) {
      throw const RemoteDeviceStoreException(
        'remote/preferences-corrupt',
        '本机保存的设备列表不是 JSON 对象，未做任何改写。',
      );
    }
    final version = decoded['version'];
    if (version != remoteDeviceStoreVersion) {
      throw RemoteDeviceStoreException(
        'remote/preferences-version',
        '本机保存的设备列表版本是 $version，当前 App 只认识 $remoteDeviceStoreVersion。',
      );
    }
    final records = decoded['devices'];
    if (records is! List) {
      throw const RemoteDeviceStoreException(
        'remote/preferences-corrupt',
        '本机保存的设备列表缺少 devices 数组，未做任何改写。',
      );
    }
    final devices = <RemoteDevice>[];
    final seen = <String>{};
    for (var index = 0; index < records.length; index++) {
      final RemoteDevice device;
      try {
        device = RemoteDevice.fromJson(records[index]);
      } on FormatException catch (failure) {
        throw RemoteDeviceStoreException(
          'remote/preferences-corrupt',
          '本机保存的第 ${index + 1} 台设备记录无法识别：${failure.message}',
          failure,
        );
      }
      if (!seen.add(device.id)) {
        throw RemoteDeviceStoreException(
          'remote/preferences-corrupt',
          '本机保存的设备列表里有重复的设备标识 ${device.id}，未做任何改写。',
        );
      }
      _verifyTrustAnchor(device, index);
      devices.add(device);
    }
    devices.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final lastConnected = decoded[remoteLastConnectedDeviceKey];
    if (lastConnected != null && lastConnected is! String) {
      throw const RemoteDeviceStoreException(
        'remote/preferences-corrupt',
        '本机保存的「上次连接的电脑」不是设备标识，未做任何改写。',
      );
    }
    return RemoteDeviceTable(
      devices: devices,
      lastConnectedDeviceId:
          lastConnected is String &&
              _deviceIdPattern.hasMatch(lastConnected) &&
              seen.contains(lastConnected)
          ? lastConnected
          : null,
    );
  }

  /// 读出全部已配对电脑（[loadTable] 的列表部分），按配对时间升序。
  Future<List<RemoteDevice>> load() async => (await loadTable()).devices;

  /// 记录一台电脑刚才连接成功：更新它的电脑名与最近在线时间，并把它记为
  /// 「上次成功连接的设备」。
  ///
  /// 这是下次冷启动自动连接的唯一输入（[RemoteDeviceTable.lastConnectedDevice]）。
  /// [hostName] 来自握手（`protocol.hello` 的 `host.name`）：配对链接里没有电脑名，
  /// 因此多台电脑的名字只能在这一步学到。设备不在表里（例如刚被移除）时什么都不写，
  /// 原样返回当前设备表。
  ///
  /// 写偏好失败会抛 [RemoteDeviceStoreException]；调用方必须把记录失败与连接本身
  /// 分开处理——记录只是便利提示，不能因此判定连接失败。
  Future<RemoteDeviceTable> markConnected(
    String deviceId, {
    String? hostName,
  }) async {
    if (!_deviceIdPattern.hasMatch(deviceId)) {
      throw const FormatException('设备标识必须是 32 位小写十六进制。');
    }
    final table = await loadTable();
    final index = table.devices.indexWhere((device) => device.id == deviceId);
    if (index < 0) return table;
    final devices = <RemoteDevice>[...table.devices];
    devices[index] = table.devices[index].copyWith(
      lastSeenAt: DateTime.now().toUtc(),
      hostName: _normalizedHostName(hostName),
    );
    await _writePreferences(devices, lastConnectedDeviceId: deviceId);
    return RemoteDeviceTable(devices: devices, lastConnectedDeviceId: deviceId);
  }

  /// 复核一条记录的信任锚：`SHA-256(CA DER)` 必须等于记录里的 `instanceId`。
  ///
  /// 不相等说明偏好里的证书与指纹来自两次不同配对（或被改写）。此时既不能信任
  /// 旧指纹，也不能信任新证书，唯一安全的动作是拒绝读数并要求重新配对。
  /// [RemoteDevice.systemTrust] 为 true 时这一步同样是强制的：系统信任只改变
  /// 传输层用哪套根证书验证反代，不放松「反代后面必须是同一台电脑」的绑定。
  static void _verifyTrustAnchor(RemoteDevice device, int index) {
    final String fingerprint;
    try {
      fingerprint = caCertificateFingerprint(device.caPem);
    } on FormatException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences-corrupt',
        '本机保存的第 ${index + 1} 台设备 CA 证书无法解析：${failure.message}',
        failure,
      );
    }
    if (fingerprint == device.instanceId) return;
    throw RemoteDeviceStoreException(
      'remote/instance-mismatch',
      '本机保存的第 ${index + 1} 台设备的 CA 证书指纹与记录的 instanceId 不一致，'
          '已拒绝使用这条记录。请重新配对这台电脑。',
      <String, dynamic>{
        'deviceId': device.id,
        'recordedInstanceId': device.instanceId,
        'caFingerprint': fingerprint,
      },
    );
  }

  /// 保存一台设备。
  ///
  /// [deviceToken] 非空时先写进 Keystore 再写偏好；偏好写失败会尝试删掉刚写入的
  /// 令牌，保证不会留下「列表里没有、密钥库里却有」的孤儿凭证。已有的
  /// 「上次成功连接的设备」记录原样保留（配对一台新电脑不应改变自动连接目标）。
  Future<void> save(RemoteDevice device, {String? deviceToken}) async {
    final wroteToken = deviceToken != null;
    if (wroteToken) {
      await _writeToken(device.tokenRef, deviceToken);
    }
    final table = await loadTable();
    final devices = <RemoteDevice>[...table.devices];
    final index = devices.indexWhere((candidate) => candidate.id == device.id);
    if (index < 0) {
      devices.add(device);
    } else {
      devices[index] = device;
    }
    try {
      await _writePreferences(
        devices,
        lastConnectedDeviceId: table.lastConnectedDeviceId,
      );
    } on Object {
      if (wroteToken) {
        // 偏好没写成功就等于这次配对没有落地；回滚密钥库，避免留下孤儿令牌。
        // 回滚本身失败不再覆盖原始失败：原始失败才是调用方要展示的原因。
        try {
          await _deleteToken(device.tokenRef);
        } on Object {
          // 删除失败只会留下一个无人引用的密文，不影响本次失败的原因。
        }
      }
      rethrow;
    }
  }

  /// 删除一台设备：先删密钥库里的令牌，再把它从偏好里去掉。
  ///
  /// 对不在列表里的 [id] 也删一次令牌（幂等）。先删令牌是刻意的：偏好写失败时
  /// 会留下「有记录但没令牌」的可见状态，而不是「没记录却有令牌」的隐藏凭证。
  /// 被删的正是「上次成功连接的设备」时，那条记录一并清掉，下次冷启动不会再去
  /// 连一台已经从本机移除的电脑。
  Future<void> remove(String id) async {
    if (!_deviceIdPattern.hasMatch(id)) {
      throw const FormatException('设备标识必须是 32 位小写十六进制。');
    }
    final table = await loadTable();
    final devices = <RemoteDevice>[...table.devices];
    String? tokenRef;
    for (final device in devices) {
      if (device.id == id) {
        tokenRef = device.tokenRef;
        break;
      }
    }
    await _deleteToken(tokenRef ?? 'remote-device/$id');
    final remaining = devices.where((device) => device.id != id).toList();
    final lastConnectedDeviceId = table.lastConnectedDeviceId == id
        ? null
        : table.lastConnectedDeviceId;
    if (remaining.length == devices.length &&
        lastConnectedDeviceId == table.lastConnectedDeviceId) {
      return;
    }
    await _writePreferences(
      remaining,
      lastConnectedDeviceId: lastConnectedDeviceId,
    );
  }

  /// 这台设备的令牌是否确实保存在本机。
  ///
  /// 优先看进程内缓存，避免冷启动前多打一次运行时调用。
  Future<bool> hasToken(RemoteDevice device) async {
    if (_tokensInMemory.containsKey(device.tokenRef)) return true;
    return _tokens.isConfigured(device.tokenRef);
  }

  /// 读出设备令牌。
  ///
  /// 先看本次进程内写入的缓存；没有时交给 [RemoteDeviceTokenVault.read]
  /// （默认实现读 `credentials.read`）。读不回来时抛 `remote/credential-read`
  /// 或 `remote/credential-*`，由页面提示重新配对。
  Future<String> readToken(RemoteDevice device) async {
    final cached = _tokensInMemory[device.tokenRef];
    if (cached != null) return cached;
    return _tokens.read(device.tokenRef);
  }

  /// 清空所有已配对电脑、令牌与「上次连接的设备」记录。
  ///
  /// 逐台删除令牌：任一台删除失败都会继续尝试其余设备，最后抛
  /// `remote/credential-delete` 并且**不改写**设备列表。因此失败时会出现
  /// 「记录还在、其中一部分令牌已删」的状态——它比「记录没了、令牌却还在」更安全，
  /// 也更容易被页面发现并提示重新配对。
  Future<void> clear() async {
    final devices = await load();
    Object? firstFailure;
    for (final device in devices) {
      try {
        await _deleteToken(device.tokenRef);
      } on Object catch (failure) {
        firstFailure ??= failure;
      }
    }
    if (firstFailure != null) {
      throw RemoteDeviceStoreException(
        'remote/credential-delete',
        '清除设备令牌失败，设备列表未改动：$firstFailure。',
        firstFailure,
      );
    }
    _tokensInMemory.clear();
    await _writePreferences(const <RemoteDevice>[]);
  }

  Future<void> _writeToken(String tokenRef, String token) async {
    await _tokens.write(tokenRef, token);
    _tokensInMemory[tokenRef] = token;
  }

  Future<void> _deleteToken(String tokenRef) async {
    await _tokens.delete(tokenRef);
    _tokensInMemory.remove(tokenRef);
  }

  /// 读偏好里的设备列表原文。
  Future<String?> _readPreferences() async {
    try {
      return await _channel
          .invokeMethod<String>(remoteDevicesReadMethod)
          .timeout(remoteDevicePreferenceTimeout);
    } on MissingPluginException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences-unavailable',
        '本机没有提供偏好通道方法 $remoteDevicesReadMethod，无法读取已配对的电脑。',
        failure,
      );
    } on PlatformException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences',
        '读取本机设备列表失败：${failure.message ?? failure.code}。',
        failure,
      );
    } on TimeoutException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences-timeout',
        '读取本机设备列表超时（${remoteDevicePreferenceTimeout.inSeconds} 秒）。',
        failure,
      );
    }
  }

  /// 把整张设备表写回偏好。
  ///
  /// [lastConnectedDeviceId] 与设备列表同一次写入：分成两次写会出现「设备已删、
  /// 上次连接仍指向它」或反过来的中间态。
  Future<void> _writePreferences(
    List<RemoteDevice> devices, {
    String? lastConnectedDeviceId,
  }) async {
    final payload = jsonEncode(<String, dynamic>{
      'version': remoteDeviceStoreVersion,
      'devices': <Map<String, dynamic>>[
        for (final device in devices) device.toJson(),
      ],
      remoteLastConnectedDeviceKey: ?lastConnectedDeviceId,
    });
    if (utf8.encode(payload).length > remoteDevicePreferencesMaxBytes) {
      throw RemoteDeviceStoreException(
        'remote/preferences-too-large',
        '设备列表超过 ${remoteDevicePreferencesMaxBytes ~/ 1024} KiB 上限，未写入。'
            '请先撤销不再使用的电脑。',
      );
    }
    try {
      await _channel
          .invokeMethod<String>(remoteDevicesSaveMethod, payload)
          .timeout(remoteDevicePreferenceTimeout);
    } on MissingPluginException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences-unavailable',
        '本机没有提供偏好通道方法 $remoteDevicesSaveMethod，无法保存已配对的电脑。',
        failure,
      );
    } on PlatformException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences',
        '保存本机设备列表失败：${failure.message ?? failure.code}。',
        failure,
      );
    } on TimeoutException catch (failure) {
      throw RemoteDeviceStoreException(
        'remote/preferences-timeout',
        '保存本机设备列表超时（${remoteDevicePreferenceTimeout.inSeconds} 秒）。',
        failure,
      );
    }
  }
}
