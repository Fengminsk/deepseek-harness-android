import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_android/remote_transport.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_tls_fixture.dart';

/// 设备令牌的线上形态：43 字符 base64url（协议 §2.1）。
const String _deviceToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

void main() {
  group('重连退避（协议 §1.4）', () {
    test('退避表从 1 s 指数增长到 30 s 封顶', () {
      expect(RemoteRuntimeTransport.reconnectBackoff, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 16),
        const Duration(seconds: 30),
      ]);
    });

    test('每档叠加 ±20% 抖动，长连失败不越过 36 s', () {
      final policy = RemoteReconnectPolicy(random: Random(7));
      for (
        var failures = 0;
        failures < RemoteReconnectPolicy.backoff.length;
        failures++
      ) {
        final base = RemoteReconnectPolicy.backoff[failures];
        for (var sample = 0; sample < 100; sample++) {
          final delay = policy.delayFor(failures);
          expect(delay, greaterThanOrEqualTo(base * 0.8));
          expect(delay, lessThanOrEqualTo(base * 1.2));
        }
      }
      // 超过表长之后沿用最后一档，而不是继续增长。
      for (var sample = 0; sample < 100; sample++) {
        expect(
          policy.delayFor(64),
          lessThanOrEqualTo(const Duration(milliseconds: 36000)),
        );
        expect(
          policy.delayFor(64),
          greaterThanOrEqualTo(const Duration(milliseconds: 24000)),
        );
      }
    });

    test('限速关闭（4003）后的等待不少于 30 s', () {
      final policy = RemoteReconnectPolicy(random: Random(3));
      expect(
        policy.delayFor(0, rateLimited: true),
        const Duration(seconds: 30),
      );
      for (var sample = 0; sample < 50; sample++) {
        expect(
          policy.delayFor(5, rateLimited: true),
          greaterThanOrEqualTo(const Duration(seconds: 30)),
        );
      }
    });

    test('只有连接存活超过阈值才把失败计数清零', () {
      final policy = RemoteReconnectPolicy(random: Random(0));
      // 从未握手成功：必须继续累计失败。
      expect(policy.resetsAfter(null), isFalse);
      // 「连上即断」：握手后 2 秒就断，不能回到 1 s 重连。
      expect(policy.resetsAfter(const Duration(seconds: 2)), isFalse);
      expect(
        policy.resetsAfter(RemoteReconnectPolicy.healthyThreshold),
        isTrue,
      );
      expect(policy.resetsAfter(const Duration(minutes: 5)), isTrue);
    });
  });

  group('终止性 TLS 失败不重连（协议 §1.4）', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('固定的 CA 验不过对端证书时进入终止态，而不是按退避重连', () async {
      // 对端出示由另一张 CA 签发的证书；传输固定的是 pairingCaPem。
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(foreignServerCertPem))
        ..usePrivateKeyBytes(utf8.encode(foreignServerKeyPem));
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((_) {}, onError: (Object _) {});

      final transport = RemoteRuntimeTransport(
        endpoint: 'wss://127.0.0.1:${server.port}/app',
        token: _deviceToken,
        pinnedCaPem: pairingCaPem,
        connectTimeout: const Duration(seconds: 10),
        handshakeTimeout: const Duration(seconds: 2),
      );
      final phases = <String>[];
      final codes = <String?>[];
      final subscription = transport.events.listen((event) {
        if (event['method'] != 'remote.status') return;
        final params = event['params'];
        if (params is! Map<String, dynamic>) return;
        final phase = params['phase'];
        if (phase is String) phases.add(phase);
        final error = params['error'];
        if (error is Map<String, dynamic> && error['code'] is String) {
          codes.add(error['code'] as String);
        }
      });

      await expectLater(
        transport.handshake,
        throwsA(
          isA<RuntimeTransportFailure>().having(
            (failure) => failure.code,
            'code',
            'remote/tls',
          ),
        ),
      );
      // 终止态之后的观察窗口：旧实现会在这里立刻推出 reconnecting。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(phases, contains('lost'));
      expect(phases, isNot(contains('reconnecting')));
      expect(codes, contains('remote/tls'));
      expect(transport.phase, 'lost');

      await subscription.cancel();
      await transport.close();
    });
  });

  group('App → 宿主请求 id（协议 §1.2）', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('协议 hello 与业务请求的 id 都是 "a-" + uuidv4，宿主按同一 id 响应', () async {
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(pairingServerCertPem))
        ..usePrivateKeyBytes(utf8.encode(pairingServerKeyPem));
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      // 服务端按协议 §1.2 原样回填请求 id；这里只记录收到的请求帧。
      final requestFrames = <Map<String, dynamic>>[];
      server.listen(
        (HttpRequest request) {
          unawaited(
            WebSocketTransformer.upgrade(request).then<void>(
              (socket) {
                socket.listen(
                  (dynamic data) {
                    final text = data is String
                        ? data
                        : utf8.decode(data as List<int>);
                    for (final line in text.split('\n')) {
                      if (line.trim().isEmpty) continue;
                      final frame = jsonDecode(line) as Map<String, dynamic>;
                      final id = frame['id'];
                      final method = frame['method'];
                      if (id is! String || method is! String) continue;
                      requestFrames.add(frame);
                      final result = method == 'protocol.hello'
                          ? <String, dynamic>{
                              'protocolVersion': 1,
                              'host': <String, dynamic>{
                                'name': '本地测试宿主',
                                'platform': 'win32',
                                'home': r'C:\test\dsh',
                              },
                              'methods': <String>['runtime.info'],
                              'unsupported': <String>[],
                              'capabilities': <String>[],
                            }
                          : <String, dynamic>{'ok': true};
                      socket.add(
                        '${jsonEncode(<String, dynamic>{
                          'jsonrpc': '2.0',
                          'id': id,
                          'result': result,
                        })}\n',
                      );
                    }
                  },
                  onError: (Object _) {},
                );
              },
              onError: (Object _) {},
            ),
          );
        },
        onError: (Object _) {},
      );

      final transport = RemoteRuntimeTransport(
        endpoint: 'wss://127.0.0.1:${server.port}/app',
        token: _deviceToken,
        pinnedCaPem: pairingCaPem,
        handshakeTimeout: const Duration(seconds: 10),
      );
      addTearDown(transport.close);
      await transport.handshake.timeout(const Duration(seconds: 15));
      await transport
          .request('runtime.info')
          .timeout(const Duration(seconds: 15));

      // hello 是第一条请求，业务请求是第二条；服务端在回响应前已经记录，所以这里
      // 不需要额外等待。
      expect(
        requestFrames.map((frame) => frame['method']).toList(),
        <String>['protocol.hello', 'runtime.info'],
      );
      const uuidV4 =
          r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
      final helloId = requestFrames[0]['id'] as String;
      final businessId = requestFrames[1]['id'] as String;
      expect(helloId, matches(RegExp('^a-$uuidV4\$')));
      expect(businessId, matches(RegExp('^a-$uuidV4\$')));
      // uuid 不是自增序号：两条请求的 id 不同且没有可预测的先后关系。
      expect(businessId, isNot(helloId));
    });
  });
}
