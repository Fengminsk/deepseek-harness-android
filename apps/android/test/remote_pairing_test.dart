import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/remote_pairing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_tls_fixture.dart';

/// `/pair` 成功的响应体字段（协议 §3.2 的配对接口约定）。
const String _pairedDeviceId = '0123456789abcdef0123456789abcdef';
const String _pairedDeviceToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

/// 配对链接里的令牌（43 字符 base64url）。
const String _pairingToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  // 本组测试要跑真实 TLS：不能初始化 TestWidgetsFlutterBinding，否则 flutter_test
  // 会安装一个把所有 HTTP 请求打成 400 的 HttpOverrides。
  group('配对 TLS 只信任配对码里那张 CA', () {
    late HttpServer server;
    late List<Map<String, dynamic>> pairRequests;

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'pair() 接受由固定 CA 签发的叶子证书（对端出示的不是 CA 本身）',
      () async {
        final started = await _startPairingServer(
          certPem: pairingServerCertPem,
          keyPem: pairingServerKeyPem,
          caBody: pairingCaPem,
        );
        server = started.server;
        pairRequests = started.pairRequests;
        final descriptor = _descriptorFor(server.port, pairingCaPem);

        final pairing = RemotePairing(timeout: const Duration(seconds: 15));
        final caPem = await pairing.fetchCa(descriptor);
        expect(caCertificateFingerprint(caPem), descriptor.instanceId);

        final credential = await pairing.pair(
          descriptor,
          caPem,
          deviceLabel: 'Pixel 8',
          appVersion: '0.1.0+121',
        );

        expect(credential.deviceId, _pairedDeviceId);
        expect(credential.deviceToken, _pairedDeviceToken);
        expect(pairRequests, hasLength(1));
        expect(pairRequests.single['token'], _pairingToken);
        expect(pairRequests.single['deviceLabel'], 'Pixel 8');
        expect(pairRequests.single['appVersion'], '0.1.0+121');
      },
    );

    test(
      'pair() 拒绝由另一张 CA 签发的叶子证书（固定 CA 之后不再接受任意证书）',
      () async {
        final started = await _startPairingServer(
          certPem: foreignServerCertPem,
          keyPem: foreignServerKeyPem,
          caBody: pairingCaPem,
        );
        server = started.server;
        pairRequests = started.pairRequests;
        final descriptor = _descriptorFor(server.port, pairingCaPem);

        final pairing = RemotePairing(timeout: const Duration(seconds: 15));
        // 首信任只按响应体指纹判定，因此这一步仍然成功。
        final caPem = await pairing.fetchCa(descriptor);
        expect(caCertificateFingerprint(caPem), descriptor.instanceId);

        await expectLater(
          pairing.pair(
            descriptor,
            caPem,
            deviceLabel: 'Pixel 8',
            appVersion: '0.1.0+121',
          ),
          throwsA(
            isA<RemotePairingFailure>().having(
              (failure) => failure.code,
              'code',
              'pairing/tls',
            ),
          ),
        );
        expect(pairRequests, isEmpty);
      },
    );

    test('fetchCa 拒绝响应体指纹与配对码不一致的 CA', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        // 对端在 /ca.cer 里给了另一张 CA：证书链能过，但指纹对不上。
        caBody: foreignCaPem,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);

      final pairing = RemotePairing(timeout: const Duration(seconds: 15));
      await expectLater(
        pairing.fetchCa(descriptor),
        throwsA(
          isA<RemotePairingFailure>().having(
            (failure) => failure.code,
            'code',
            'pairing/ca-fingerprint',
          ),
        ),
      );
    });

    test('pair() 在 CA 与配对码不一致时不发出任何请求', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        caBody: pairingCaPem,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);
      final pairing = RemotePairing(timeout: const Duration(seconds: 15));

      await expectLater(
        pairing.pair(
          descriptor,
          foreignCaPem,
          deviceLabel: 'Pixel 8',
          appVersion: '0.1.0+121',
        ),
        throwsA(
          isA<RemotePairingFailure>().having(
            (failure) => failure.code,
            'code',
            'pairing/ca-fingerprint',
          ),
        ),
      );
      expect(pairRequests, isEmpty);
    });

    test('pair() 对无法解析的 CA 给出可展示的错误，而不是抛 FormatException', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        caBody: pairingCaPem,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);
      final pairing = RemotePairing(timeout: const Duration(seconds: 15));

      await expectLater(
        pairing.pair(
          descriptor,
          '-----BEGIN CERTIFICATE-----\nnot-base64\n-----END CERTIFICATE-----\n',
          deviceLabel: 'Pixel 8',
          appVersion: '0.1.0+121',
        ),
        throwsA(
          isA<RemotePairingFailure>().having(
            (failure) => failure.code,
            'code',
            'pairing/ca-format',
          ),
        ),
      );
    });
  });

  group('HTTPS 反代：系统根证书验证反代公网证书', () {
    late HttpServer server;
    late List<Map<String, dynamic>> pairRequests;

    tearDown(() async {
      await server.close(force: true);
    });

    /// 模拟「公网 CA 已经在系统根证书里」：真实环境由系统信任库提供，测试把
    /// fixture CA 加进一个带系统根证书的上下文，其余验证行为与生产一致。
    SecurityContext trustFixtureCa() =>
        SecurityContext(withTrustedRoots: true)
          ..setTrustedCertificatesBytes(utf8.encode(pairingCaPem));

    test('systemTrust 的 fetchCa 按系统根证书验证：自签反代证书直接失败', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        caBody: pairingCaPem,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);
      final pairing = RemotePairing(timeout: const Duration(seconds: 15));

      await expectLater(
        pairing.fetchCa(descriptor, systemTrust: true),
        throwsA(
          isA<RemotePairingFailure>()
              .having((failure) => failure.code, 'code', 'pairing/proxy-tls')
              .having(
                (failure) => failure.message,
                'message',
                contains('系统信任'),
              ),
        ),
      );
      expect(pairRequests, isEmpty);
    });

    test('systemTrust 在系统信任反代证书时配对成功，且仍核对 /ca.cer 指纹', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        caBody: pairingCaPem,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);
      final pairing = RemotePairing(
        timeout: const Duration(seconds: 15),
        systemTrustContextFactory: trustFixtureCa,
      );

      final caPem = await pairing.fetchCa(descriptor, systemTrust: true);
      expect(caCertificateFingerprint(caPem), descriptor.instanceId);

      final credential = await pairing.pair(
        descriptor,
        caPem,
        deviceLabel: 'Pixel 8',
        appVersion: '0.1.0+121',
        systemTrust: true,
      );

      expect(credential.deviceId, _pairedDeviceId);
      expect(credential.deviceToken, _pairedDeviceToken);
      expect(pairRequests, hasLength(1));
      expect(pairRequests.single['token'], _pairingToken);
    });

    test('systemTrust 仍拒绝与配对码不一致的 CA（反代转到了别的后端）', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        caBody: foreignCaPem,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);
      final pairing = RemotePairing(
        timeout: const Duration(seconds: 15),
        systemTrustContextFactory: trustFixtureCa,
      );

      await expectLater(
        pairing.fetchCa(descriptor, systemTrust: true),
        throwsA(
          isA<RemotePairingFailure>()
              .having((failure) => failure.code, 'code', 'pairing/ca-fingerprint')
              .having((failure) => failure.message, 'message', contains('反代')),
        ),
      );
      expect(pairRequests, isEmpty);
    });

    test('systemTrust 下 /pair 非 2xx 时提示反代没有转发', () async {
      final started = await _startPairingServer(
        certPem: pairingServerCertPem,
        keyPem: pairingServerKeyPem,
        caBody: pairingCaPem,
        pairStatus: HttpStatus.badGateway,
      );
      server = started.server;
      pairRequests = started.pairRequests;
      final descriptor = _descriptorFor(server.port, pairingCaPem);
      final pairing = RemotePairing(
        timeout: const Duration(seconds: 15),
        systemTrustContextFactory: trustFixtureCa,
      );
      final caPem = await pairing.fetchCa(descriptor, systemTrust: true);

      await expectLater(
        pairing.pair(
          descriptor,
          caPem,
          deviceLabel: 'Pixel 8',
          appVersion: '0.1.0+121',
          systemTrust: true,
        ),
        throwsA(
          isA<RemotePairingFailure>()
              .having((failure) => failure.code, 'code', 'pairing/status')
              .having((failure) => failure.message, 'message', contains('反代')),
        ),
      );
      expect(pairRequests, hasLength(1));
    });
  });

  group('反代链接识别（只提示切换入口，不改信任模式）', () {
    final instanceId = caCertificateFingerprint(pairingCaPem);
    final fragment = '#instance=$instanceId&token=$_pairingToken';

    test('wss 显式 443 与 https:// 前缀都判为反代形态', () {
      expect(
        looksLikeHttpsProxyPairingLink('wss://dsh.example.com:443$fragment'),
        isTrue,
      );
      expect(
        looksLikeHttpsProxyPairingLink('https://dsh.example.com$fragment'),
        isTrue,
      );
      // 从浏览器复制的裸 https 地址：先提示切换入口，提交时再报缺片段。
      expect(
        looksLikeHttpsProxyPairingLink('https://dsh.example.com'),
        isTrue,
      );
    });

    test('缺片段或片段不合法的 443 链接交给普通入口的解析错误', () {
      expect(
        looksLikeHttpsProxyPairingLink('wss://dsh.example.com:443'),
        isFalse,
      );
      expect(
        looksLikeHttpsProxyPairingLink(
          'wss://dsh.example.com:443#instance=bad&token=bad',
        ),
        isFalse,
      );
    });

    test('局域网地址、默认 4777 与 8443 直通都判为直连', () {
      expect(
        looksLikeHttpsProxyPairingLink('wss://192.168.1.10:4777$fragment'),
        isFalse,
      );
      expect(
        looksLikeHttpsProxyPairingLink('wss://192.168.1.10$fragment'),
        isFalse,
      );
      expect(
        looksLikeHttpsProxyPairingLink('wss://dsh.example.com:8443$fragment'),
        isFalse,
      );
    });

    test('无法解析成地址的输入返回 false，交给既有解析错误处理', () {
      expect(looksLikeHttpsProxyPairingLink(''), isFalse);
      expect(looksLikeHttpsProxyPairingLink('not a link'), isFalse);
    });

    test('反代链接仍按既有规则解析，并保留显式 443 端口', () {
      final proxy = PairingDescriptor.parse(
        'wss://dsh.example.com:443$fragment',
      );
      expect(proxy.host, 'dsh.example.com');
      expect(proxy.port, 443);
      expect(proxy.instanceId, instanceId);
      expect(proxy.token, _pairingToken);
    });
  });
}

PairingDescriptor _descriptorFor(int port, String caPem) {
  final instanceId = caCertificateFingerprint(caPem);
  return PairingDescriptor.parse(
    'wss://127.0.0.1:$port#instance=$instanceId&token=$_pairingToken',
  );
}

/// 启动一个只服务 `/ca.cer` 与 `/pair` 的真实 HTTPS 服务器。
///
/// 证书材料来自 [support/remote_tls_fixture.dart]：`certPem`/`keyPem` 决定对端出示
/// 哪条证书链，`caBody` 是 `/ca.cer` 的响应体。两者刻意分开，才能分别验证「TLS
/// 必须由固定 CA 签发」与「响应体指纹必须等于配对码」。
Future<
  ({HttpServer server, List<Map<String, dynamic>> pairRequests})
>
_startPairingServer({
  required String certPem,
  required String keyPem,
  required String caBody,
  int pairStatus = HttpStatus.ok,
}) async {
  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  final pairRequests = <Map<String, dynamic>>[];
  server.listen(
    (HttpRequest request) async {
      final response = request.response;
      if (request.method == 'GET' && request.uri.path == '/ca.cer') {
        final body = utf8.encode(caBody);
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'x-pem-file')
          ..contentLength = body.length
          ..add(body);
        await response.close();
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/pair') {
        final raw = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(raw);
        pairRequests.add(
          decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
        );
        if (pairStatus != HttpStatus.ok) {
          final body = utf8.encode('bad gateway');
          response
            ..statusCode = pairStatus
            ..contentLength = body.length
            ..add(body);
          await response.close();
          return;
        }
        final body = utf8.encode(
          jsonEncode(<String, dynamic>{
            'deviceId': _pairedDeviceId,
            'deviceToken': _pairedDeviceToken,
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(days: 30))
                .millisecondsSinceEpoch,
          }),
        );
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..contentLength = body.length
          ..add(body);
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    },
    // 负向用例里客户端会拒绝服务器证书，服务器侧同时报一次握手失败：
    // 那是预期结果，不能让未处理的错误把测试打成失败。
    onError: (Object _) {},
  );
  return (server: server, pairRequests: pairRequests);
}
