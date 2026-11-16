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

/// 两台不同电脑的设备 id（32 位小写十六进制）。
const String _firstId = '0123456789abcdef0123456789abcdef';
const String _secondId = 'fedcba9876543210fedcba9876543210';

/// 内存版本的令牌保管口：测试不碰 Keystore。
class _MemoryVault implements RemoteDeviceTokenVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String tokenRef) async {
    values.remove(tokenRef);
  }

  @override
  Future<bool> isConfigured(String tokenRef) async =>
      values.containsKey(tokenRef);

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

  RemoteDeviceStore newStore() =>
      RemoteDeviceStore(channel: channel, tokens: _MemoryVault());

  RemoteDevice device({
    String instanceId = '',
    String caPem = '',
    String id = _firstId,
    String label = 'Pixel 8',
    String host = '192.168.1.20',
    int port = 4777,
    DateTime? createdAt,
    DateTime? lastSeenAt,
    String? hostName,
    bool systemTrust = false,
  }) => RemoteDevice(
    id: id,
    label: label,
    host: host,
    port: port,
    instanceId: instanceId.isEmpty ? _pairingInstanceId : instanceId,
    caPem: caPem.isEmpty ? pairingCaPem : caPem,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 15, 6, 0, 0),
    lastSeenAt: lastSeenAt,
    hostName: hostName,
    systemTrust: systemTrust,
  );

  /// 直接写偏好原文，模拟旧版本 App 或外部改写留下的数据。
  void writePreferences(Map<String, dynamic> payload) {
    preferences = jsonEncode(payload);
  }

  Map<String, dynamic> storedPreferences() =>
      jsonDecode(preferences ?? '{}') as Map<String, dynamic>;

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
      ..['caPem'] =
          '-----BEGIN CERTIFICATE-----\nnot-base64\n'
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

  group('上次成功连接的电脑', () {
    test('markConnected 记录设备、电脑名与最近在线时间', () async {
      final store = newStore();
      final first = device(createdAt: DateTime.utc(2026, 11, 15, 6));
      final second = device(
        id: _secondId,
        host: '192.168.1.30',
        createdAt: DateTime.utc(2026, 11, 15, 7),
      );
      await store.save(first, deviceToken: _deviceToken);
      await store.save(second, deviceToken: _deviceToken);
      expect(
        (await store.loadTable()).lastConnectedDeviceId,
        isNull,
        reason: '刚配对还没有连接过',
      );

      await store.markConnected(_firstId, hostName: '客厅的电脑');
      final table = await store.loadTable();
      expect(table.lastConnectedDeviceId, _firstId);
      expect(table.lastConnectedDevice?.id, _firstId);
      final connected = table.devices.firstWhere(
        (candidate) => candidate.id == _firstId,
      );
      expect(connected.hostName, '客厅的电脑');
      expect(connected.displayName, '客厅的电脑');
      expect(connected.lastSeenAt, isNotNull);
      expect(
        table.devices
            .firstWhere((candidate) => candidate.id == _secondId)
            .hostName,
        isNull,
        reason: '没有连接过的电脑不受影响',
      );

      // 换了另一台：记录指向最近一次成功连接的那台。
      await store.markConnected(_secondId, hostName: '书房的笔记本');
      final switched = await store.loadTable();
      expect(switched.lastConnectedDeviceId, _secondId);
      expect(switched.lastConnectedDevice?.displayName, '书房的笔记本');
    });

    test('保存新配对不覆盖上次连接记录', () async {
      final store = newStore();
      await store.save(device(), deviceToken: _deviceToken);
      await store.markConnected(_firstId, hostName: '客厅的电脑');

      await store.save(
        device(
          id: _secondId,
          host: '192.168.1.30',
          createdAt: DateTime.utc(2026, 11, 15, 7),
        ),
        deviceToken: _deviceToken,
      );

      final table = await store.loadTable();
      expect(table.lastConnectedDeviceId, _firstId);
      expect(table.devices, hasLength(2));
    });

    test('移除上次连接的电脑会一并清掉记录', () async {
      final vault = _MemoryVault();
      final store = RemoteDeviceStore(channel: channel, tokens: vault);
      await store.save(device(), deviceToken: _deviceToken);
      await store.save(
        device(
          id: _secondId,
          host: '192.168.1.30',
          createdAt: DateTime.utc(2026, 11, 15, 7),
        ),
        deviceToken: _deviceToken,
      );
      await store.markConnected(_firstId, hostName: '客厅的电脑');

      await store.remove(_firstId);

      final table = await store.loadTable();
      expect(table.devices.map((candidate) => candidate.id), <String>[
        _secondId,
      ]);
      expect(
        table.lastConnectedDeviceId,
        isNull,
        reason: '不移除这台电脑的话，下次冷启动会自动去连一个已经删掉的设备',
      );
      expect(vault.values.keys, <String>['remote-device/$_secondId']);
    });

    test('移除其它电脑保留上次连接记录', () async {
      final store = newStore();
      await store.save(device(), deviceToken: _deviceToken);
      await store.save(
        device(
          id: _secondId,
          host: '192.168.1.30',
          createdAt: DateTime.utc(2026, 11, 15, 7),
        ),
        deviceToken: _deviceToken,
      );
      await store.markConnected(_firstId, hostName: '客厅的电脑');

      await store.remove(_secondId);

      final table = await store.loadTable();
      expect(table.lastConnectedDeviceId, _firstId);
      expect(table.lastConnectedDevice?.hostName, '客厅的电脑');
    });

    test('loadTable 忽略指向不存在设备的上次连接记录', () async {
      // 它只是自动连接的提示，不是信任锚：点名一台不存在的电脑时按没有记录处理。
      writePreferences(<String, dynamic>{
        'version': remoteDeviceStoreVersion,
        'devices': <Map<String, dynamic>>[device().toJson()],
        remoteLastConnectedDeviceKey: _secondId,
      });

      final table = await newStore().loadTable();
      expect(table.devices, hasLength(1));
      expect(table.lastConnectedDeviceId, isNull);
      expect(table.lastConnectedDevice, isNull);
    });

    test('上次连接记录类型不对时报数据损坏', () async {
      writePreferences(<String, dynamic>{
        'version': remoteDeviceStoreVersion,
        'devices': <Map<String, dynamic>>[device().toJson()],
        remoteLastConnectedDeviceKey: 42,
      });

      await expectLater(
        newStore().loadTable(),
        throwsA(
          isA<RemoteDeviceStoreException>().having(
            (failure) => failure.code,
            'code',
            'remote/preferences-corrupt',
          ),
        ),
      );
    });

    test('clear 清空设备、令牌与上次连接记录', () async {
      final vault = _MemoryVault();
      final store = RemoteDeviceStore(channel: channel, tokens: vault);
      await store.save(device(), deviceToken: _deviceToken);
      await store.markConnected(_firstId, hostName: '客厅的电脑');

      await store.clear();

      final table = await store.loadTable();
      expect(table.devices, isEmpty);
      expect(table.lastConnectedDeviceId, isNull);
      expect(storedPreferences()['devices'], isEmpty);
      expect(vault.values, isEmpty);
    });

    test('旧记录没有电脑名时 displayName 退回地址，读回仍然可用', () async {
      // 旧版本 App 写的记录没有 hostName：不能因此判成数据损坏。
      writePreferences(<String, dynamic>{
        'version': remoteDeviceStoreVersion,
        'devices': <Map<String, dynamic>>[
          device(host: '192.168.5.140', id: _firstId).toJson(),
        ],
      });

      final table = await newStore().loadTable();
      expect(table.devices.single.hostName, isNull);
      expect(table.devices.single.displayName, '192.168.5.140');

      // 新写入会带上电脑名，往返一致。
      final store = newStore();
      await store.markConnected(_firstId, hostName: '客厅的电脑');
      final reloaded = await newStore().loadTable();
      expect(reloaded.devices.single.hostName, '客厅的电脑');
      expect(reloaded.devices.single.displayName, '客厅的电脑');
    });
  });

  group('TLS 信任模式（pinned / systemTrust）', () {
    test('旧记录没有 systemTrust 字段时按 pinned 读回', () async {
      // 旧版本 App 不知道这个字段：缺省必须是固定宿主 CA 的直连模式。
      writePreferences(<String, dynamic>{
        'version': remoteDeviceStoreVersion,
        'devices': <Map<String, dynamic>>[device().toJson()],
      });

      final table = await newStore().loadTable();
      expect(table.devices.single.systemTrust, isFalse);
    });

    test('systemTrust 记录存储往返，并保留 instanceId 身份绑定', () async {
      final store = newStore();
      await store.save(
        device(host: 'dsh.example.com', port: 443, systemTrust: true),
        deviceToken: _deviceToken,
      );

      final stored =
          (storedPreferences()['devices'] as List).single
              as Map<String, dynamic>;
      expect(stored['systemTrust'], isTrue);

      final reloaded = await newStore().load();
      expect(reloaded.single.systemTrust, isTrue);
      expect(reloaded.single.host, 'dsh.example.com');
      expect(reloaded.single.port, 443);
      expect(reloaded.single.instanceId, _pairingInstanceId);
      expect(reloaded.single.caPem, pairingCaPem);
    });

    test('pinned 记录不写 systemTrust 字段，旧版本 App 仍按 pinned 读', () async {
      await newStore().save(device(), deviceToken: _deviceToken);

      final stored =
          (storedPreferences()['devices'] as List).single
              as Map<String, dynamic>;
      expect(stored.containsKey('systemTrust'), isFalse);
      expect((await newStore().load()).single.systemTrust, isFalse);
    });

    test('systemTrust 记录仍复核 CA 指纹（不放松身份绑定）', () async {
      final tampered = device(systemTrust: true).toJson()
        ..['caPem'] = foreignCaPem;
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

    test('systemTrust 字段类型不对时报数据损坏', () async {
      final tampered = device().toJson()..['systemTrust'] = 'yes';
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

    test('copyWith 能切换信任模式，id 与信任锚不变', () async {
      final pinned = device(host: 'dsh.example.com', port: 443);
      final proxy = pinned.copyWith(systemTrust: true);

      expect(proxy.systemTrust, isTrue);
      expect(proxy.id, pinned.id);
      expect(proxy.instanceId, pinned.instanceId);
      expect(proxy.caPem, pinned.caPem);
      expect(proxy.host, pinned.host);
      expect(proxy.copyWith(systemTrust: false).systemTrust, isFalse);
    });
  });
}
