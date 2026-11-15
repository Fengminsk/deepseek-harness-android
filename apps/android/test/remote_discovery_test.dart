// 局域网发现：应答解析、坏帧过滤与 UDP 收集窗口（不依赖真实网络）。
//
// 解析测试直接喂 JSON 字符串；UDP 测试只绑回环地址，用第二个套接字伪造宿主
// 应答，验证窗口内收集、nonce 校验、按 instanceId 去重、超时、dispose 与失败翻译。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_android/remote_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主 CA 指纹（64 位小写十六进制）。
final String _instanceId = 'a' * 64;

/// 一次性配对令牌（43 字符 base64url）。
const String _pairingToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

/// 一轮探测的 nonce（宿主原样回显）。
const String _nonce = 'probe-nonce-0001';

/// 主机默认监听的端口；origin 与配对链接都用它。
const int _port = 4777;

/// 一条形状合法的配对链接。
String _pairLink({String host = '192.168.5.21', String? instanceId}) =>
    'wss://$host:$_port#instance=${instanceId ?? _instanceId}'
    '&token=$_pairingToken';

/// 一条宿主应答帧（字段与 discovery.md §2.3 一致）。
Map<String, Object?> _reply({
  String nonce = _nonce,
  String instanceId = '',
  String name = 'DESKTOP-TEST',
  String origin = 'wss://192.168.5.21:4777',
  bool open = true,
  Object? pairUrl,
  Object? expiresAt = 1763433600000,
}) => <String, Object?>{
  'v': 1,
  'kind': 'dsh-remote-host',
  'name': name,
  'origin': origin,
  'instanceId': instanceId.isEmpty ? _instanceId : instanceId,
  'pairing': open
      ? <String, Object?>{
          'open': true,
          'pairUrl': pairUrl ?? _pairLink(),
          'expiresAt': expiresAt,
        }
      : <String, Object?>{'open': false},
  'nonce': nonce,
};

/// 解析一帧 JSON 文本。
RemoteDiscoveredHost? _parse(Object frame, {String nonce = _nonce}) =>
    parseRemoteDiscoveryReply(jsonEncode(frame), nonce: nonce);

void main() {
  group('parseRemoteDiscoveryReply', () {
    test('配对窗口打开：解析名称、origin、instanceId 与配对链接', () {
      final host = _parse(_reply());
      expect(host, isNotNull);
      expect(host!.name, 'DESKTOP-TEST');
      expect(host.address, '192.168.5.21:4777');
      expect(host.origin, Uri.parse('wss://192.168.5.21:4777'));
      expect(host.instanceId, _instanceId);
      expect(host.pairLink, _pairLink());
      expect(host.pairingOpen, isTrue);
      expect(
        host.pairingExpiresAt,
        DateTime.fromMillisecondsSinceEpoch(1763433600000, isUtc: true),
      );
    });

    test('配对窗口关闭：没有链接，pairingOpen 为 false', () {
      final host = _parse(_reply(open: false));
      expect(host, isNotNull);
      expect(host!.pairingOpen, isFalse);
      expect(host.pairLink, isNull);
      expect(host.pairingExpiresAt, isNull);
    });

    test('坏帧一律丢弃（非 JSON / 版本 / 标记 / nonce / 字段 / 链接）', () {
      final badFrames = <String, Object?>{
        '非 JSON': null,
        '非对象': <Object?>[1, 2, 3],
        '版本不符': _reply()..['v'] = 2,
        'kind 不符': _reply()..['kind'] = 'other',
        'nonce 不匹配': _reply(nonce: 'another-nonce-01'),
        '缺 name': _reply()..remove('name'),
        'name 为空': _reply(name: '   '),
        'name 超长': _reply(name: 'x' * 121),
        'instanceId 非小写 hex': _reply(instanceId: 'A' * 64),
        'instanceId 长度不对': _reply(instanceId: 'a' * 63),
        'origin 非 wss': _reply(origin: 'https://192.168.5.21:4777'),
        'origin 带路径': _reply(origin: 'wss://192.168.5.21:4777/app'),
        'origin 带查询串': _reply(origin: 'wss://192.168.5.21:4777?x=1'),
        'pairing 非对象': _reply()..['pairing'] = 'open',
        'open 非 bool': _reply()
          ..['pairing'] = <String, Object?>{'open': 'true'},
        'open=true 缺 pairUrl': _reply()
          ..['pairing'] = <String, Object?>{'open': true, 'expiresAt': 1},
        'expiresAt 非整数': _reply(expiresAt: '1'),
        'expiresAt 非正数': _reply(expiresAt: 0),
        'pairUrl 不是配对链接': _reply(pairUrl: 'https://example.com/pair'),
        'pairUrl 缺少 instance': _reply(
          pairUrl: 'wss://192.168.5.21:4777#token=$_pairingToken',
        ),
        'pairUrl 的 instanceId 与顶层不一致': _reply(
          pairUrl: _pairLink(instanceId: 'b' * 64),
        ),
      };
      for (final entry in badFrames.entries) {
        final raw = entry.value == null ? 'not json' : jsonEncode(entry.value);
        expect(
          parseRemoteDiscoveryReply(raw, nonce: _nonce),
          isNull,
          reason: entry.key,
        );
      }
    });

    test('超过单包上限的应答丢弃', () {
      final padded = _reply()
        ..['ignored'] = 'x' * remoteDiscoveryMaxDatagramBytes;
      expect(_parse(padded), isNull);
    });
  });

  group('createRemoteDiscoveryNonce', () {
    test('生成 22 个 base64url 字符（16 字节随机数）', () {
      final nonce = createRemoteDiscoveryNonce(Random(7));
      expect(nonce, hasLength(22));
      expect(RegExp(r'^[A-Za-z0-9_-]{4,128}$').hasMatch(nonce), isTrue);
    });

    test('固定种子可复现，不同种子不同', () {
      expect(
        createRemoteDiscoveryNonce(Random(7)),
        createRemoteDiscoveryNonce(Random(7)),
      );
      expect(
        createRemoteDiscoveryNonce(Random(7)),
        isNot(createRemoteDiscoveryNonce(Random(8))),
      );
    });
  });

  group('UdpRemoteDiscovery', () {
    // 用固定种子让测试能算出实现内部使用的 nonce（两者都用 Random(7) 的同一序列）。
    final String expectedNonce = createRemoteDiscoveryNonce(Random(7));
    final sockets = <RawDatagramSocket>[];
    late RawDatagramSocket responder;
    RawDatagramSocket? active;

    setUp(() async {
      active = null;
      responder = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() {
      for (final socket in sockets) {
        try {
          socket.close();
        } on Object {
          // 实现自己会关套接字，重复关闭忽略。
        }
      }
      sockets.clear();
      try {
        responder.close();
      } on Object {
        // 已关闭。
      }
    });

    UdpRemoteDiscovery newDiscovery() => UdpRemoteDiscovery(
      port: 9,
      probeRetryDelay: const Duration(milliseconds: 60),
      random: Random(7),
      socketFactory: () async {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        active = socket;
        sockets.add(socket);
        return socket;
      },
      targets: () async => <InternetAddress>[InternetAddress.loopbackIPv4],
    );

    /// 等发现套接字绑定后，把一帧应答发到它的端口。
    Future<void> sendReply(Object frame, {int repeats = 3}) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final socket = active;
      if (socket == null) throw StateError('发现套接字还没绑定');
      final bytes = utf8.encode(frame is String ? frame : jsonEncode(frame));
      for (var index = 0; index < repeats; index += 1) {
        responder.send(bytes, InternetAddress.loopbackIPv4, socket.port);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('收集应答并按 instanceId 去重（同一台电脑只保留第一条）', () async {
      final discovery = newDiscovery();
      final future = discovery.discover(
        window: const Duration(milliseconds: 500),
      );
      await sendReply(_reply(nonce: expectedNonce));
      await sendReply(_reply(nonce: expectedNonce, name: 'DUP-NAME'));
      await sendReply(
        _reply(
          nonce: expectedNonce,
          instanceId: 'b' * 64,
          name: 'OTHER-PC',
          // open=true 时 pairUrl 的 instanceId 必须与顶层一致；这里用关闭窗口的
          // 应答验证「去重按 instanceId，而不是按名称或来源」。
          open: false,
        ),
      );

      final hosts = await future;
      expect(hosts, hasLength(2));
      final byInstance = <String, RemoteDiscoveredHost>{
        for (final host in hosts) host.instanceId: host,
      };
      expect(byInstance[_instanceId]!.name, 'DESKTOP-TEST');
      expect(byInstance['b' * 64]!.name, 'OTHER-PC');
    });

    test('nonce 不匹配的应答不接收', () async {
      final discovery = newDiscovery();
      final future = discovery.discover(
        window: const Duration(milliseconds: 250),
      );
      await sendReply(_reply(nonce: 'probe-nonce-wrong'));
      expect(await future, isEmpty);
    });

    test('窗口内没有应答时返回空列表（不无限广播）', () async {
      final discovery = newDiscovery();
      final stopwatch = Stopwatch()..start();
      final hosts = await discovery.discover(
        window: const Duration(milliseconds: 150),
      );
      stopwatch.stop();
      expect(hosts, isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('dispose 会让进行中的搜索尽快结束', () async {
      final discovery = newDiscovery();
      final future = discovery.discover(window: const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      discovery.dispose();
      expect(await future.timeout(const Duration(seconds: 2)), isEmpty);
    });

    test('dispose 后再搜索给出可展示的失败', () async {
      final discovery = newDiscovery();
      discovery.dispose();
      await expectLater(
        discovery.discover(),
        throwsA(
          isA<RemoteDiscoveryFailure>().having(
            (failure) => failure.code,
            'code',
            'discovery/disposed',
          ),
        ),
      );
    });

    test('绑定套接字失败翻译成 discovery/socket', () async {
      final discovery = UdpRemoteDiscovery(
        port: 9,
        socketFactory: () async => throw const SocketException('没有可用网络接口'),
        targets: () async => <InternetAddress>[InternetAddress.loopbackIPv4],
      );
      await expectLater(
        discovery.discover(),
        throwsA(
          isA<RemoteDiscoveryFailure>()
              .having((failure) => failure.code, 'code', 'discovery/socket')
              .having(
                (failure) => failure.message,
                'message',
                contains('无法打开局域网发现端口'),
              ),
        ),
      );
    });

    test('同一时间只接受一次搜索（重复触发是 discovery/busy）', () async {
      final discovery = newDiscovery();
      final first = discovery.discover(
        window: const Duration(milliseconds: 400),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(
        discovery.discover(window: const Duration(milliseconds: 100)),
        throwsA(
          isA<RemoteDiscoveryFailure>().having(
            (failure) => failure.code,
            'code',
            'discovery/busy',
          ),
        ),
      );
      expect(await first, isEmpty);
    });
  });
}
