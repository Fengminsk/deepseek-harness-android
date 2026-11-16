import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_android/remote_transport.dart';
import 'package:dsh_android/runtime_transport.dart';
// 显式断言「超时定时器已取消、没有 pending timer」需要 fake_async；它由
// flutter_test 传递引入（pubspec.lock 已锁定），本轮不改 pubspec，所以直接导入。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
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

  group('拨号超时（HANDOFF §4 第 17 项）', () {
    test('默认 12 秒，错误码复用 remote/* 客户端命名空间', () {
      expect(
        RemoteRuntimeTransport.defaultConnectTimeout,
        const Duration(seconds: 12),
      );
      expect(
        RemoteRuntimeTransport.connectTimeoutCode,
        'remote/connect-timeout',
      );
    });

    test('拨号 12 秒未完成即终止：超时失败、主动中止连接、不自动重连、无 Timer 泄漏', () {
      fakeAsync((async) {
        var attempts = 0;
        var aborts = 0;
        final pending = Completer<WebSocket>();
        final transport = _transportWithDialer((HttpClient client) {
          attempts++;
          return RemoteDialAttempt(
            socket: pending.future,
            abort: () => aborts++,
          );
        });
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
        Object? failure;
        unawaited(
          transport.handshake.then<void>(
            (_) {},
            onError: (Object error) => failure = error,
          ),
        );
        async.flushMicrotasks();

        async.elapse(
          RemoteRuntimeTransport.defaultConnectTimeout -
              const Duration(milliseconds: 1),
        );
        expect(attempts, 1);
        expect(aborts, 0, reason: '没到时限不能提前放弃');
        expect(failure, isNull);
        expect(transport.phase, 'connecting');

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        expect(
          failure,
          isA<RuntimeTransportFailure>().having(
            (value) => value.code,
            'code',
            RemoteRuntimeTransport.connectTimeoutCode,
          ),
        );
        expect(aborts, 1, reason: '超时必须主动中止仍在建立的连接');
        expect(transport.phase, 'lost');
        expect(phases, contains('lost'));
        expect(phases, isNot(contains('ready')));
        expect(codes, contains(RemoteRuntimeTransport.connectTimeoutCode));

        // 终止性失败：不按退避重连，不会出现第二个 12 秒窗口。
        async.elapse(const Duration(minutes: 2));
        expect(attempts, 1);
        expect(phases, isNot(contains('reconnecting')));

        // `abort` 与底层拨号完成存在竞态：晚到的 socket 也必须关掉。
        final late = _FakeWebSocket();
        pending.complete(late);
        async.flushMicrotasks();
        expect(late.closeCalls, 1, reason: '超时后晚到的 socket 必须被关闭');
        expect(late.lastCloseReason, RemoteRuntimeTransport.connectTimeoutCode);

        unawaited(transport.close());
        async.flushMicrotasks();
        expect(transport.isClosed, isTrue);
        expect(async.pendingTimers, isEmpty, reason: '超时定时器必须在失败/关闭路径上取消');
        unawaited(subscription.cancel());
      });
    });

    test('拨号期间 close（切换设备 / dispose）取消定时器并中止在途连接', () {
      fakeAsync((async) {
        var aborts = 0;
        final pending = Completer<WebSocket>();
        final transport = _transportWithDialer(
          (_) =>
              RemoteDialAttempt(socket: pending.future, abort: () => aborts++),
        );
        async.flushMicrotasks();
        expect(transport.phase, 'connecting');

        var closed = false;
        unawaited(transport.close().then((_) => closed = true));
        async.flushMicrotasks();

        expect(closed, isTrue);
        expect(transport.isClosed, isTrue);
        expect(aborts, 1, reason: '关闭传输必须中止在途拨号，不能留下悬挂连接');

        // 定时器已随 close 取消：再等三个窗口也不会触发任何回调。
        async.elapse(RemoteRuntimeTransport.defaultConnectTimeout * 3);
        expect(aborts, 1);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('拨号失败时取消超时定时器，按退避转入重连', () {
      fakeAsync((async) {
        var attempts = 0;
        final transport = _transportWithDialer((_) {
          attempts++;
          return RemoteDialAttempt(
            socket: Future<WebSocket>.error(
              const SocketException('connection refused'),
            ),
            abort: () {},
          );
        });
        final phases = <String>[];
        final subscription = transport.events.listen((event) {
          if (event['method'] != 'remote.status') return;
          final params = event['params'];
          if (params is Map<String, dynamic> && params['phase'] is String) {
            phases.add(params['phase'] as String);
          }
        });
        async.flushMicrotasks();

        expect(attempts, 1);
        expect(phases, contains('reconnecting'));
        // 拨号已经失败：12 秒定时器取消，只剩 1 秒档的退避重连定时器。
        expect(
          async.pendingTimers.map((timer) => timer.duration),
          isNot(contains(RemoteRuntimeTransport.defaultConnectTimeout)),
        );

        unawaited(transport.close());
        async.flushMicrotasks();
        expect(transport.isClosed, isTrue);
        expect(async.pendingTimers, isEmpty, reason: '退避定时器也要随 close 取消');
        unawaited(subscription.cancel());
      });
    });

    test('底层拨号先抛 TimeoutException 也按拨号超时终止，不退回可重试', () {
      fakeAsync((async) {
        final transport = _transportWithDialer(
          (_) => RemoteDialAttempt(
            socket: Future<WebSocket>.error(
              TimeoutException(
                'Connection timed out',
                RemoteRuntimeTransport.defaultConnectTimeout,
              ),
            ),
            abort: () {},
          ),
        );
        final phases = <String>[];
        final subscription = transport.events.listen((event) {
          if (event['method'] != 'remote.status') return;
          final params = event['params'];
          if (params is Map<String, dynamic> && params['phase'] is String) {
            phases.add(params['phase'] as String);
          }
        });
        Object? failure;
        unawaited(
          transport.handshake.then<void>(
            (_) {},
            onError: (Object error) => failure = error,
          ),
        );
        async.flushMicrotasks();

        expect(
          failure,
          isA<RuntimeTransportFailure>().having(
            (value) => value.code,
            'code',
            RemoteRuntimeTransport.connectTimeoutCode,
          ),
        );
        expect(phases, contains('lost'));
        expect(phases, isNot(contains('reconnecting')));

        unawaited(transport.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        unawaited(subscription.cancel());
      });
    });

    test('拨号成功即取消超时定时器；握手完成后不遗留定时器', () {
      fakeAsync((async) {
        final socket = _FakeWebSocket();
        final transport = _transportWithDialer(
          (_) => RemoteDialAttempt(
            socket: Future<WebSocket>.value(socket),
            abort: () => throw StateError('拨号成功后不应再中止连接'),
          ),
          handshakeTimeout: const Duration(hours: 1),
        );
        final phases = <String>[];
        final subscription = transport.events.listen((event) {
          if (event['method'] != 'remote.status') return;
          final params = event['params'];
          if (params is Map<String, dynamic> && params['phase'] is String) {
            phases.add(params['phase'] as String);
          }
        });
        async.flushMicrotasks();

        expect(transport.phase, 'handshaking');
        expect(socket.sent, hasLength(1));
        final hello = jsonDecode(socket.sent.single) as Map<String, dynamic>;
        expect(hello['method'], 'protocol.hello');
        final id = hello['id'];
        expect(id, isA<String>());
        // 连接建立时拨号定时器已经取消：这里只剩 1 小时的握手窗口。
        expect(
          async.pendingTimers.map((timer) => timer.duration),
          isNot(contains(RemoteRuntimeTransport.defaultConnectTimeout)),
        );

        socket.emit(
          '${jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{
              'protocolVersion': 1,
              'host': <String, dynamic>{'name': '本地测试宿主', 'platform': 'win32', 'home': r'C:\test\dsh'},
              'methods': <String>[],
              'unsupported': <String>[],
              'capabilities': <String>[],
            },
          })}\n',
        );
        async.flushMicrotasks();

        expect(transport.phase, 'ready');
        expect(phases, contains('ready'));
        expect(async.pendingTimers, isEmpty, reason: '握手定时器在成功后取消');

        unawaited(transport.close());
        async.flushMicrotasks();
        expect(transport.isClosed, isTrue);
        expect(async.pendingTimers, isEmpty);
        unawaited(subscription.cancel());
      });
    });
  });
}

/// 注入拨号实现的传输；端点用 TEST-NET-1，永远不会真的发起网络请求。
RemoteRuntimeTransport _transportWithDialer(
  RemoteDialer dialer, {
  Duration handshakeTimeout = const Duration(seconds: 10),
}) => RemoteRuntimeTransport(
  endpoint: 'wss://192.0.2.1:4777/app',
  token: _deviceToken,
  pinnedCaPem: pairingCaPem,
  dialer: dialer,
  handshakeTimeout: handshakeTimeout,
);

/// 测试用的假 WebSocket：只实现传输层真正会碰到的成员，其余成员被用到时由
/// [noSuchMethod] 抛错，避免假实现悄悄偏离真实接口。
class _FakeWebSocket implements WebSocket {
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  final List<String> sent = <String>[];
  int closeCalls = 0;
  int? lastCloseCode;
  String? lastCloseReason;
  Duration? _pingInterval;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inbound.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(dynamic data) {
    if (data is String) sent.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCalls++;
    lastCloseCode = code;
    lastCloseReason = reason;
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  Duration? get pingInterval => _pingInterval;

  @override
  set pingInterval(Duration? value) => _pingInterval = value;

  @override
  int? get closeCode => lastCloseCode;

  @override
  String? get closeReason => lastCloseReason;

  /// 模拟宿主推来一帧文本。
  void emit(String frame) => _inbound.add(frame);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试假 socket 未实现 ${invocation.memberName}');
}
