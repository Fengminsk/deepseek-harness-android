/// 远程配对：解析 PC 给出的配对链接、首信任拉取自签 CA、换取设备令牌。
///
/// 信任模型（协议 §2、`docs/remote-dsh-plan.md` §5.4）：
///
/// - 配对链接里的 `instance` 是这台 PC 的 CA 证书 DER 的 SHA-256 指纹，也是唯一的
///   信任锚。链接形如 `wss://<host>:<port>#instance=<64 hex>&token=<43 chars>`。
/// - 取 `/ca.cer` 时还没有任何可信参照，因此必须容忍对端出示的任意证书（TOFU 的
///   第一次握手）；真正的判据是响应体：`SHA-256(CA DER)` 必须等于 `instance`，
///   不等就拒绝，不留中间态。
/// - `/pair` 在固定 CA 之后才发，TLS 信任库只装这一张 CA
///   （`SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes`）。
///   宿主出示的是这张 CA 签发的**叶子**证书，由 BoringSSL 按证书链验证；链接被换成
///   另一张证书时握手直接失败。**不能**用「对端证书 DER 的指纹 == CA 指纹」判定：
///   叶子证书永远不等于 CA 证书本身。
///
/// ## 为什么这里需要 `package:crypto`
///
/// `remote_transport.dart` 靠 `SecurityContext(withTrustedRoots: false)` 固定整张
/// CA，不需要算指纹；TOFU 这一步必须在写入 CA 之前比对 `instance`，而 Dart 标准库
/// （`dart:convert` / `dart:io`）没有 SHA-256。用 dart-lang 官方包而不是自己写
/// DER 解析与十六进制比对。
///
/// 本文件不依赖 Flutter：只用 `dart:io`、`dart:convert` 与 `package:crypto`，
/// 因此可以被单元测试直接调用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 配对链接不带端口时使用的默认端口：PC 宿主默认监听 4777。
const int remotePairingDefaultPort = 4777;

/// 单次 HTTP 请求（`/ca.cer`、`/pair`）的超时。
const Duration remotePairingTimeout = Duration(seconds: 10);

/// `/ca.cer` 与 `/pair` 响应体的大小上限：64 KiB。
///
/// CA 证书（DER + PEM 文本）只有几 KB；限住上限是为了不把对端当成任意大文件的
/// 通道，也避免一次恶意响应把手机内存吃满。
const int remotePairingMaxResponseBytes = 64 * 1024;

/// 设备 id 的线上形态：32 位小写十六进制（`apps/remote-host/src/devices.ts`）。
final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{32}$');

/// 设备令牌的线上形态：43 字符 base64url（协议 §2.1）。
final RegExp _deviceTokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// instanceId 的线上形态：64 位小写十六进制（`apps/remote-host/src/identity.ts`）。
final RegExp _instancePattern = RegExp(r'^[0-9a-f]{64}$');

/// 配对令牌的线上形态：43 字符 base64url（`apps/remote-host/src/pairing.ts`）。
final RegExp _pairingTokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// PEM 头尾；只接受单张 `CERTIFICATE` 块。
final RegExp _pemBodyPattern = RegExp(
  r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
);

/// 配对过程的一次失败。
///
/// [code] 供页面分支（例如 429 显示「稍后重试」而不是「重新配对」），[message]
/// 是已经组装好的中文句子，可以直接 `Text()` 展示。
class RemotePairingFailure implements Exception {
  /// 记录失败类别与可展示文案。
  const RemotePairingFailure(this.code, this.message, [this.details]);

  /// 失败类别，例如 `pairing/timeout`、`pairing/ca-fingerprint`。
  final String code;

  /// 可直接展示的中文说明。
  final String message;

  /// 原始异常或额外字段，只用于排障，不展示给用户。
  final Object? details;

  @override
  String toString() => 'RemotePairingFailure($code): $message';
}

/// 一次配对链接的解析结果。
///
/// 只保留配对与连接真正需要的四项：`host` / `port` / `instanceId` / `token`。
/// 端点一律由这四项拼出，链接里的其它成分（路径前缀、查询串）在 [parse] 里被拒绝。
class PairingDescriptor {
  const PairingDescriptor._({
    required this.host,
    required this.port,
    required this.instanceId,
    required this.token,
  });

  /// 电脑地址（`Uri.host`，IPv6 不带方括号）。
  final String host;

  /// 电脑的配对 HTTPS 端口；链接省略端口时为 [remotePairingDefaultPort]。
  final int port;

  /// 这台电脑 CA 证书的 SHA-256 指纹（64 位小写十六进制）。
  final String instanceId;

  /// 一次性配对令牌（43 字符 base64url），只在这次的 `/pair` 请求里使用。
  final String token;

  /// `GET https://<host>:<port>/ca.cer`。
  Uri get caEndpoint =>
      Uri(scheme: 'https', host: host, port: port, path: '/ca.cer');

  /// `POST https://<host>:<port>/pair`。
  Uri get pairEndpoint =>
      Uri(scheme: 'https', host: host, port: port, path: '/pair');

  /// 配对成功后 `RemoteRuntimeTransport` 使用的 `wss://<host>:<port>/app`。
  Uri get appEndpoint =>
      Uri(scheme: 'wss', host: host, port: port, path: '/app');

  /// 解析配对链接。
  ///
  /// 接受 `wss://` 与 `https://` 两种前缀（后者按协议 §1.1 归一化为 `wss`），片段
  /// 必须恰好是 `instance` 与 `token` 两个字段，顺序不限。端口省略时用
  /// [remotePairingDefaultPort]。
  ///
  /// 非法输入抛 [FormatException]，消息是可直接展示的中文。
  factory PairingDescriptor.parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('配对链接为空。请重新扫描电脑上的配对二维码。');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      throw const FormatException('配对链接不是合法地址。请重新扫描电脑上的配对二维码。');
    }
    return PairingDescriptor.fromUri(uri);
  }

  /// 解析已经切成 [Uri] 的配对链接；规则与 [parse] 相同。
  factory PairingDescriptor.fromUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'wss' && scheme != 'https') {
      if (scheme == 'ws' || scheme == 'http') {
        throw const FormatException('配对链接必须使用 wss:// 或 https://（v1 只允许加密连接）。');
      }
      throw FormatException('配对链接的协议不受支持：$scheme。');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('配对链接不能包含用户名或密码。');
    }
    if (uri.hasQuery) {
      throw const FormatException('配对链接不能带查询串：instance 与 token 放在 # 之后。');
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      // v1 直连：RemoteRuntimeTransport 只接受 `/app` 路径，链接带前缀会让设备
      // 记下一个连不上的端点，所以这里直接拒绝。
      throw const FormatException('配对链接不能带路径前缀：v1 只接受直连的 wss://<host>:<port>。');
    }
    final host = uri.host;
    if (host.isEmpty) {
      throw const FormatException('配对链接缺少电脑地址。');
    }
    final port = uri.hasPort ? uri.port : remotePairingDefaultPort;
    if (port < 1 || port > 65535) {
      throw const FormatException('配对链接的端口必须在 1–65535 之间。');
    }
    if (uri.fragment.isEmpty) {
      throw const FormatException(
        '配对链接缺少 #instance=…&token=… 片段。请重新扫描电脑上的配对二维码。',
      );
    }

    final fields = _fragmentFields(uri.fragment);
    for (final key in fields.keys) {
      if (key != 'instance' && key != 'token') {
        throw FormatException('配对链接里有无法识别的字段「$key」。');
      }
    }
    final instanceId = fields['instance'];
    if (instanceId == null) {
      throw const FormatException('配对链接缺少 instance 字段（CA 证书指纹）。');
    }
    if (!_instancePattern.hasMatch(instanceId)) {
      throw const FormatException('配对链接的 instance 必须是 64 位小写十六进制（CA 指纹）。');
    }
    final token = fields['token'];
    if (token == null) {
      throw const FormatException('配对链接缺少 token 字段（一次性配对令牌）。');
    }
    if (!_pairingTokenPattern.hasMatch(token)) {
      throw const FormatException('配对链接的 token 必须是 43 个字符的 base64url 字符串。');
    }
    return PairingDescriptor._(
      host: host,
      port: port,
      instanceId: instanceId,
      token: token,
    );
  }
}

/// 按 `k=v&k=v` 切分片段，重复字段即拒绝。
Map<String, String> _fragmentFields(String fragment) {
  final fields = <String, String>{};
  for (final part in fragment.split('&')) {
    final separator = part.indexOf('=');
    if (separator <= 0 || separator == part.length - 1) {
      throw const FormatException(
        '配对链接的片段格式不正确，应为 #instance=<64 位十六进制>&token=<43 字符>。',
      );
    }
    final key = part.substring(0, separator);
    final value = part.substring(separator + 1);
    if (fields.containsKey(key)) {
      throw FormatException('配对链接里出现了重复的「$key」字段。');
    }
    fields[key] = value;
  }
  return fields;
}

/// `/pair` 成功返回的设备凭证。
class PairedCredential {
  /// 记录一次成功配对的结果。
  const PairedCredential({
    required this.deviceId,
    required this.deviceToken,
    required this.expiresAt,
  });

  /// 设备 id（32 位小写十六进制），由 PC 的设备表签发。
  final String deviceId;

  /// 设备令牌（43 字符 base64url），只在这次响应里出现一次。
  final String deviceToken;

  /// 令牌到期时间（UTC）。
  final DateTime expiresAt;

  /// 校验并解析 `/pair` 的响应体。
  ///
  /// 字段名就是线上字段名（`apps/remote-host` 的配对接口约定）：`deviceId`、
  /// `deviceToken`、`expiresAt`（Unix 毫秒）。
  factory PairedCredential.parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw RemotePairingFailure(
        'pairing/response',
        '电脑返回的配对结果不是合法 JSON。',
        error,
      );
    }
    if (decoded is! Map) {
      throw const RemotePairingFailure(
        'pairing/response',
        '电脑返回的配对结果不是 JSON 对象。',
      );
    }
    final deviceId = decoded['deviceId'];
    final deviceToken = decoded['deviceToken'];
    final expiresAt = decoded['expiresAt'];
    if (deviceId is! String || !_deviceIdPattern.hasMatch(deviceId)) {
      throw const RemotePairingFailure(
        'pairing/response',
        '电脑返回的设备标识格式不正确（应为 32 位小写十六进制）。',
      );
    }
    if (deviceToken is! String || !_deviceTokenPattern.hasMatch(deviceToken)) {
      throw const RemotePairingFailure(
        'pairing/response',
        '电脑返回的设备令牌格式不正确（应为 43 个字符的 base64url）。',
      );
    }
    if (expiresAt is! int || expiresAt <= 0) {
      throw const RemotePairingFailure(
        'pairing/response',
        '电脑返回的到期时间格式不正确（应为 Unix 毫秒）。',
      );
    }
    return PairedCredential(
      deviceId: deviceId,
      deviceToken: deviceToken,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true),
    );
  }
}

/// 配对用的 HTTPS 客户端：拉 CA 与换取设备令牌。
///
/// 两个方法都自建 [HttpClient] 并在结束时关闭，不复用连接：配对是低频的一次性
/// 动作，复用只会让「这次请求信任哪张 CA」这种状态跨请求泄漏。
class RemotePairing {
  /// 创建配对客户端。
  ///
  /// [clientFactory] 只用于测试替换；默认按传入的 [SecurityContext] 新建
  /// [HttpClient]。上下文由本类构造，工厂只负责绑定，信任库不存在被替换的可能。
  /// [maxResponseBytes] 是 `/ca.cer` 与 `/pair` 响应体的上限。
  RemotePairing({
    Duration timeout = remotePairingTimeout,
    int maxResponseBytes = remotePairingMaxResponseBytes,
    HttpClient Function(SecurityContext context)? clientFactory,
  }) : _timeout = timeout,
       _maxResponseBytes = maxResponseBytes,
       _clientFactory = clientFactory ?? _defaultClientFactory {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', '超时必须大于 0');
    }
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        '响应上限必须大于 0',
      );
    }
  }

  /// 单次请求超时。
  final Duration _timeout;

  /// 响应体上限（字节）。
  final int _maxResponseBytes;

  /// HTTP 客户端工厂。
  final HttpClient Function(SecurityContext context) _clientFactory;

  static HttpClient _defaultClientFactory(SecurityContext context) =>
      HttpClient(context: context);

  /// 拉取 `/ca.cer` 并校验指纹，返回可交给 `SecurityContext` 的 PEM 文本。
  ///
  /// 此时还没有可信参照，TLS 回调必须接受自签证书；真正的判据是响应体的
  /// `SHA-256(DER)` 必须等于 [PairingDescriptor.instanceId]，不等即抛
  /// [RemotePairingFailure]（`pairing/ca-fingerprint`），不返回任何可固定内容。
  ///
  /// 响应非 2xx、超过 [remotePairingMaxResponseBytes]、不是 X.509 结构或超过
  /// [remotePairingTimeout] 都抛 [RemotePairingFailure]。
  Future<String> fetchCa(PairingDescriptor descriptor) async {
    // 首信任（TOFU）：还没有可信参照，只能先握手，再按配对码里的指纹判定响应体。
    // 这里的信任库刻意为空——判据是下面那次 SHA-256 比对，不是证书链。
    final client = _clientFactory(SecurityContext());
    client.badCertificateCallback = (certificate, host, port) => true;
    client.connectionTimeout = _timeout;
    try {
      return await _guard(() async {
        final request = await client.getUrl(descriptor.caEndpoint);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw RemotePairingFailure(
            'pairing/ca-status',
            '电脑没有提供 CA 证书（HTTP ${response.statusCode}）。'
                '请确认配对链接来自这台电脑上正在运行的远程 DSH。',
          );
        }
        final der = _certificateDer(await _readBounded(response));
        final fingerprint = sha256.convert(der).toString();
        if (fingerprint != descriptor.instanceId) {
          throw const RemotePairingFailure(
            'pairing/ca-fingerprint',
            '证书指纹与配对码不一致，已拒绝固定这台电脑的证书。请重新扫描电脑上的配对二维码。',
          );
        }
        return _pemFromDer(der);
      });
    } finally {
      client.close(force: true);
    }
  }

  /// 用一次性配对令牌换取长期设备令牌。
  ///
  /// [caPem] 必须是 [fetchCa] 返回并已通过指纹校验的 CA；本次请求的 TLS 回调要求
  /// 对端出示的每张证书的指纹都等于该 CA 的指纹，否则握手失败。
  ///
  /// `POST /pair` 的请求体是 `{token, deviceLabel, appVersion}`，成功响应是
  /// `{deviceId, deviceToken, expiresAt}`。HTTP 401 / 403 / 429 映射成带中文
  /// 说明的 [RemotePairingFailure]；其它非 2xx 也抛异常，不返回半成品。
  Future<PairedCredential> pair(
    PairingDescriptor descriptor,
    String caPem, {
    required String deviceLabel,
    required String appVersion,
  }) async {
    final String fingerprint;
    try {
      fingerprint = caCertificateFingerprint(caPem);
    } on FormatException catch (error) {
      throw RemotePairingFailure(
        'pairing/ca-format',
        '已固定的 CA 证书无法解析（${error.message}）。请重新扫描电脑上的配对二维码。',
        error,
      );
    }
    if (fingerprint != descriptor.instanceId) {
      throw const RemotePairingFailure(
        'pairing/ca-fingerprint',
        '已固定的 CA 证书与配对码不一致，已中止配对。请重新扫描电脑上的配对二维码。',
      );
    }
    final label = checkedDeviceLabel(deviceLabel);
    final version = appVersion.trim();
    if (version.isEmpty || version.runes.length > 64) {
      throw const FormatException('App 版本号不能为空，且不超过 64 个字符。');
    }
    final body = utf8.encode(
      jsonEncode({
        'token': descriptor.token,
        'deviceLabel': label,
        'appVersion': version,
      }),
    );
    // TOFU 的第二步：只信任配对码里那张 CA。宿主出示的是它签发的叶子证书，
    // 证书链由 BoringSSL 验证；不再用「对端证书指纹」做判断——那个值与 CA 指纹
    // 永远不相等，等于把每一次配对都判成失败。
    final client = _clientFactory(_pinnedContext(caPem))
      ..connectionTimeout = _timeout;
    try {
      return await _guard(() async {
        final request = await client.postUrl(descriptor.pairEndpoint);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.acceptHeader,
          ContentType.json.mimeType,
        );
        request.headers.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        final text = utf8.decode(
          await _readBounded(response),
          allowMalformed: true,
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _pairStatusFailure(response.statusCode, text);
        }
        return PairedCredential.parse(text);
      });
    } finally {
      client.close(force: true);
    }
  }

  /// 把 401 / 403 / 429 与其它非 2xx 映射成可展示的中文说明。
  RemotePairingFailure _pairStatusFailure(int status, String body) {
    final excerpt = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    final details = excerpt.length <= 200 ? excerpt : excerpt.substring(0, 200);
    return switch (status) {
      HttpStatus.unauthorized => RemotePairingFailure(
        'pairing/unauthorized',
        '配对令牌无效或已过期。请在电脑上重新打开配对二维码，再扫描一次。',
        details,
      ),
      HttpStatus.forbidden => RemotePairingFailure(
        'pairing/forbidden',
        // 桌面宿主对 /pair 返回 403 的语义是配对窗口已关闭或过期（`apps/remote-host/src/pairing.ts`）；
        // 来源校验失败只会发生在升级前的 WS 握手上，不会走到这里。
        '电脑上的配对窗口已经关闭或过期。请在电脑上重新打开配对二维码后再试。',
        details,
      ),
      HttpStatus.tooManyRequests => RemotePairingFailure(
        'pairing/rate-limited',
        '配对尝试过于频繁。请在电脑上重新打开配对二维码，稍等一会儿再扫描。',
        details,
      ),
      _ => RemotePairingFailure(
        'pairing/status',
        '电脑拒绝了配对（HTTP $status）。请重新打开电脑上的配对二维码。',
        details,
      ),
    };
  }

  /// 统一施加超时，并把底层网络异常翻译成中文失败。
  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation().timeout(_timeout);
    } on TimeoutException catch (error) {
      throw RemotePairingFailure(
        'pairing/timeout',
        '等待电脑响应超时（${_timeout.inSeconds} 秒）。'
            '请确认手机与电脑在同一局域网，且电脑上的远程 DSH 正在运行。',
        error,
      );
    } on HandshakeException catch (error) {
      throw RemotePairingFailure(
        'pairing/tls',
        '与电脑建立 TLS 连接失败：${error.message}。请确认配对链接里的地址与端口正确。',
        error,
      );
    } on TlsException catch (error) {
      throw RemotePairingFailure(
        'pairing/tls',
        '与电脑的 TLS 握手失败：${error.message}。',
        error,
      );
    } on SocketException catch (error) {
      throw RemotePairingFailure(
        'pairing/network',
        '无法连接电脑：${error.message}。'
            '请确认手机与电脑在同一网络，且端口没有被防火墙挡住。',
        error,
      );
    } on HttpException catch (error) {
      throw RemotePairingFailure(
        'pairing/network',
        '与电脑的连接中断：${error.message}。请重试。',
        error,
      );
    }
  }

  /// 读响应体，超过上限立即中止。
  Future<Uint8List> _readBounded(HttpClientResponse response) async {
    final declared = response.contentLength;
    if (declared > _maxResponseBytes) {
      throw RemotePairingFailure(
        'pairing/response-too-large',
        '电脑的响应超过 ${_maxResponseBytes ~/ 1024} KiB 上限，已中止。请确认连接的是正确的电脑。',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > _maxResponseBytes) {
        throw RemotePairingFailure(
          'pairing/response-too-large',
          '电脑的响应超过 ${_maxResponseBytes ~/ 1024} KiB 上限，已中止。请确认连接的是正确的电脑。',
        );
      }
    }
    return builder.takeBytes();
  }
}

/// 把 `/ca.cer` 的响应体收敛成证书 DER。
///
/// 契约是 DER，但反向代理或静态文件服务器可能给出 PEM 文本；两种都接受，判据始终
/// 是 DER 的 SHA-256。既不是 DER 也不是 PEM 的响应（例如一段 HTML）在这里就被
/// 拒绝，而不是等到指纹比对时报「指纹不一致」。
Uint8List _certificateDer(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const RemotePairingFailure(
      'pairing/ca-format',
      '电脑返回的 CA 证书为空。请重新打开电脑上的配对二维码。',
    );
  }
  final text = _tryDecodeAscii(bytes);
  if (text != null && text.contains('-----BEGIN')) {
    final match = _pemBodyPattern.firstMatch(text);
    if (match == null) {
      throw const RemotePairingFailure(
        'pairing/ca-format',
        '电脑返回的 CA 证书不是完整的 PEM 文本。请重新打开电脑上的配对二维码。',
      );
    }
    try {
      final der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s+'), ''));
      return _checkedDer(der);
    } on FormatException catch (error) {
      throw RemotePairingFailure(
        'pairing/ca-format',
        '电脑返回的 CA 证书 PEM 无法解码。',
        error,
      );
    }
  }
  return _checkedDer(bytes);
}

/// 只接受首字节为 SEQUENCE（0x30）的非空 DER。
Uint8List _checkedDer(Uint8List der) {
  if (der.length < 64 || der.first != 0x30) {
    throw const RemotePairingFailure(
      'pairing/ca-format',
      '电脑返回的不是 X.509 证书。请确认配对链接指向的是运行中的远程 DSH。',
    );
  }
  return der;
}

/// 纯 ASCII 才按文本处理；二进制 DER 里出现非 ASCII 时返回 null。
String? _tryDecodeAscii(Uint8List bytes) {
  try {
    return ascii.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// 计算 PEM 证书的 DER SHA-256 指纹（64 位小写十六进制）。
///
/// 配对把 `instanceId` 定义为「CA 证书 DER 的 SHA-256」，冷启动读回设备记录时要用
/// 同一个函数复核（`remote_device_store.dart`），否则两处各写一份实现很容易漂移。
///
/// 只接受单张 `CERTIFICATE` 块；PEM 结构或 base64 非法时抛 [FormatException]。
String caCertificateFingerprint(String pem) {
  final match = _pemBodyPattern.firstMatch(pem);
  if (match == null) {
    throw const FormatException('CA 证书不是合法的 PEM 文本（缺少 CERTIFICATE 块）。');
  }
  final Uint8List der;
  try {
    der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s+'), ''));
  } on FormatException {
    throw const FormatException('CA 证书的 PEM 正文不是合法的 base64。');
  }
  return sha256.convert(_checkedDer(der)).toString();
}

/// 用一张固定 CA 建立只信任它的 TLS 上下文。
///
/// `withTrustedRoots: false` 排除系统根证书与用户证书；只有 [caPem] 签发的证书链
/// 能通过验证。不设置 `badCertificateCallback`：没有「先接受、后判断」的中间态。
/// PEM 无法解析时抛 [RemotePairingFailure]（`pairing/tls`），不返回半配置的上下文。
SecurityContext _pinnedContext(String caPem) {
  final context = SecurityContext(withTrustedRoots: false);
  try {
    context.setTrustedCertificatesBytes(utf8.encode(caPem));
  } on TlsException catch (error) {
    throw RemotePairingFailure(
      'pairing/tls',
      '固定 CA 证书加载失败：${error.message}。请重新配对这台电脑。',
      error,
    );
  } on ArgumentError catch (error) {
    throw RemotePairingFailure(
      'pairing/tls',
      '固定 CA 证书格式不正确：${error.message}。请确认配对时保存的是 PEM 文本。',
      error,
    );
  }
  return context;
}

/// DER → PEM：64 列 base64，行尾 LF。
String _pemFromDer(Uint8List der) {
  final body = base64.encode(der);
  final buffer = StringBuffer('-----BEGIN CERTIFICATE-----\n');
  for (var offset = 0; offset < body.length; offset += 64) {
    final end = offset + 64 < body.length ? offset + 64 : body.length;
    buffer
      ..write(body.substring(offset, end))
      ..write('\n');
  }
  buffer.write('-----END CERTIFICATE-----\n');
  return buffer.toString();
}

/// 校验并收敛设备显示名：1–120 个非控制字符（`apps/remote-host/src/devices.ts`
/// 的同一约束）。配对与页面共用这一处实现，避免两套长度规则。
String checkedDeviceLabel(String raw) {
  final label = raw.trim();
  final length = label.runes.length;
  if (length < 1 || length > 120) {
    throw const FormatException('设备名必须是 1–120 个字符。');
  }
  for (final rune in label.runes) {
    final control = rune < 0x20 || rune == 0x7f;
    if (control) {
      throw const FormatException('设备名不能包含控制字符。');
    }
  }
  return label;
}
