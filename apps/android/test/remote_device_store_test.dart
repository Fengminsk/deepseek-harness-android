import 'dart:convert';

import 'package:dsh_android/remote_device_store.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_tls_fixture.dart';

/// 设备令牌的线上形态：43 字符 base64url（协议 §2.1）。
const String _deviceToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

final String _pairingInstanceId = caCertificateFingerprint(pairingCaPem);
final String _foreignInstanceId = caCertificateFingerprint(foreignCaPem);

/// 内存版本的令牌保管口：测试不碰 Keystore。
class _MemoryVault implements RemoteDeviceTokenVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String tokenRef) async {
    values.remove(tokenRef);
  }

  @override
  Future<bool> isConfigured(String tokenRef) async => values.containsKey(tokenRef);

  @override
  Future<String> read(String tokenRef) async {
    final value = values[tokenRef];
    if (value == null) {
      throw const RemoteDeviceStoreException(
        'remote/credential-read',
        '本机密钥库里没有这台电脑的设备令牌，请重新配对。',
      );
    }
    return value;
  }

  @override
  Future<void> write(String tokenRef, String token) async {
    values[tokenRef] = token;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/remote_devices');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? preferences;

  setUp(() {
    preferences = null;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case remoteDevicesReadMethod:
          return preferences;
        case remoteDevicesSaveMethod:
          preferences = call.arguments as String;
          return null;
        default:
          throw MissingPluginException('未模拟的偏好方法 ${call.method}');
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  RemoteDeviceStore newStore() => RemoteDeviceStore(
    channel: channel,
    tokens: _MemoryVault(),
  );

  RemoteDevice device({
    String instanceId = '',
    String caPem = '',
  }) => RemoteDevice(
    id: '0123456789abcdef0123456789abcdef',
    label: 'Pixel 8',
    host: '192.168.1.20',
    port: 4777,
    instanceId: instanceId.isEmpty ? _pairingInstanceId : instanceId,
    caPem: caPem.isEmpty ? pairingCaPem : caPem,
    createdAt: DateTime.utc(2026, 11, 15, 6, 0, 0),
  );

  test('读回记录时接受 DER 指纹与 instanceId 一致的 CA', () async {
    final store = newStore();
    await store.save(device(), deviceToken: _deviceToken);

    final devices = await store.load();
    expect(devices, hasLength(1));
    expect(devices.single.instanceId, _pairingInstanceId);
    expect(devices.single.caPem, pairingCaPem);
    expect(await store.readToken(devices.single), _deviceToken);
  });

  test('读回记录时拒绝 CA 指纹与 instanceId 不一致的记录（不静默信任）', () async {
    // 偏好里的 CA 是 A，记录的指纹却是 B 的：两半信任锚来自两次不同配对。
    final tampered = device(instanceId: _foreignInstanceId).toJson();
    preferences = jsonEncode(<String, dynamic>{
      'version': remoteDeviceStoreVersion,
      'devices': <Map<String, dynamic>>[tampered],
    });

    final store = newStore();
    await expectLater(
      store.load(),
      throwsA(
        isA<RemoteDeviceStoreException>().having(
          (failure) => failure.code,
          'code',
          'remote/instance-mismatch',
        ),
      ),
    );
  });

  test('读回记录时拒绝被替换成另一张 CA 的证书', () async {
    // 指纹仍是原来的 instanceId，但 caPem 被换成 B：只有重新计算 SHA-256 才能发现。
    final tampered = device().toJson()..['caPem'] = foreignCaPem;
    preferences = jsonEncode(<String, dynamic>{
      'version': remoteDeviceStoreVersion,
      'devices': <Map<String, dynamic>>[tampered],
    });

    await expectLater(
      newStore().load(),
      throwsA(
        isA<RemoteDeviceStoreException>().having(
          (failure) => failure.code,
          'code',
          'remote/instance-mismatch',
        ),
      ),
    );
  });

  test('读回记录时把无法解析的 CA 报成明确的存储失败', () async {
    final tampered = device().toJson()
      ..['caPem'] = '-----BEGIN CERTIFICATE-----\nnot-base64\n'
          '-----END CERTIFICATE-----\n';
    preferences = jsonEncode(<String, dynamic>{
      'version': remoteDeviceStoreVersion,
      'devices': <Map<String, dynamic>>[tampered],
    });

    await expectLater(
      newStore().load(),
      throwsA(
        isA<RemoteDeviceStoreException>().having(
          (failure) => failure.code,
          'code',
          'remote/preferences-corrupt',
        ),
      ),
    );
  });
}
