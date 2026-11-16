/// 配对编排：把「解析链接 → 取 CA → 校验指纹 → 换取设备令牌 → 落本机」串成一步。
///
/// 这个类只做顺序与失败转译，不做 UI、不碰 Widget：[RemoteDeviceStore] 与
/// [RemotePairing] 都可以由调用方注入，单测直接构造即可跑完整流程（成功路径与
/// 每一步的失败路径）。唯一的平台通道是省略 `appVersion` 时读一次
/// `app.metadata`，那条路径同样可以用 `appVersionReader` 替换。
///
/// 顺序固定在 [pair] 里，外部无法改变：CA 必须先取回并通过指纹校验，才允许发出
/// `/pair`；令牌必须先落进 Keystore，才返回 [RemoteDevice]。任一步失败都抛异常，
/// 不会返回一台「看着配对成功、其实连不上」的设备。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'remote_device_store.dart';
import 'remote_pairing.dart';
import 'runtime.dart';

/// 配对流程：解析链接、固定 CA、换取并保存设备令牌。
class RemotePairingFlow {
  /// 创建编排器。
  ///
  /// [store] 负责偏好与 Keystore；[pairing] 负责两张 HTTP 端点；[clock] 只用于
  /// 写入时间戳，测试可以替换；[appVersionReader] 在调用方没有给出 `appVersion`
  /// 时读取 App 构建号。
  RemotePairingFlow({
    required this.store,
    RemotePairing? pairing,
    DateTime Function()? clock,
    Future<String> Function()? appVersionReader,
  }) : pairing = pairing ?? RemotePairing(),
       _clock = clock ?? DateTime.now,
       _appVersionReader = appVersionReader ?? _readAppMetadataVersion;

  /// 设备存储。
  final RemoteDeviceStore store;

  /// 配对 HTTP 客户端。
  final RemotePairing pairing;

  final DateTime Function() _clock;
  final Future<String> Function() _appVersionReader;

  /// 完成一次配对并返回已保存的设备。
  ///
  /// [link] 是电脑上二维码里的文本（`wss://host:port#instance=…&token=…`）。
  /// [deviceLabel] 会作为这台手机的显示名上报给电脑，同时写进本机记录。
  /// [appVersion] 省略时读 `app.metadata` 的 `version+build`（与
  /// `protocol.hello.params.appVersion` 同一取值）。
  /// [systemTrust] 是配对入口显式选择的 TLS 信任模式：`false`（默认）直连宿主
  /// TLS，`true` 表示 TLS 在反代处终止、用系统根证书验证公网证书。两种模式都先
  /// 取回 `/ca.cer` 并核对 `instance` 指纹，身份绑定不放松。
  ///
  /// 抛 [FormatException] 表示输入（链接、设备名、版本号）不合法；抛
  /// [RemotePairingFailure] 表示配对过程中的失败，`message` 可直接展示；
  /// [RemoteDeviceStoreException] 来自存储层的失败会被包成
  /// `pairing/store` 的 [RemotePairingFailure]，因为此时电脑侧已经签发了令牌，
  /// 用户必须去电脑上撤销这台设备。
  Future<RemoteDevice> pair(
    String link, {
    required String deviceLabel,
    String? appVersion,
    bool systemTrust = false,
  }) async {
    final descriptor = PairingDescriptor.parse(link);
    // 设备名先校验：不合格就不该为了报错去拉一次 CA。
    final label = checkedDeviceLabel(deviceLabel);
    final version = (appVersion == null || appVersion.trim().isEmpty)
        ? await _appVersion()
        : appVersion.trim();
    final caPem = await pairing.fetchCa(descriptor, systemTrust: systemTrust);
    final credential = await pairing.pair(
      descriptor,
      caPem,
      deviceLabel: label,
      appVersion: version,
      systemTrust: systemTrust,
    );
    final now = _clock();
    if (!credential.expiresAt.isAfter(now)) {
      throw RemotePairingFailure(
        'pairing/expired',
        '电脑签发的设备令牌已经过期（到期时间 ${credential.expiresAt.toLocal()}）。'
            '请检查手机与电脑的系统时间后重新配对。',
      );
    }
    final device = RemoteDevice(
      id: credential.deviceId,
      label: label,
      host: descriptor.host,
      port: descriptor.port,
      instanceId: descriptor.instanceId,
      caPem: caPem,
      createdAt: now,
      lastSeenAt: now,
      systemTrust: systemTrust,
    );
    try {
      await store.save(device, deviceToken: credential.deviceToken);
    } on Object catch (failure) {
      throw RemotePairingFailure(
        'pairing/store',
        '电脑已签发设备令牌，但本机没有保存成功：$failure。'
            '请在电脑上撤销这台设备后重新配对。',
        failure,
      );
    }
    return device;
  }

  /// 取 App 构建号：`app.metadata` 的 `version+build`。
  Future<String> _appVersion() => _appVersionReader();
}

/// 读取 `app.metadata`，拼成 `0.1.0+120` 形态的构建号。
///
/// 这条通道是整个 App 读取自身版本的既有入口；读不到时抛
/// `pairing/app-version` 而不是上报一个编造的版本号——`appVersion` 会进
/// `protocol.hello`，编造值只会让另一端更难排障。
Future<String> _readAppMetadataVersion() async {
  final String? raw;
  try {
    raw = await RuntimeController.channel
        .invokeMethod<String>('app.metadata')
        .timeout(const Duration(seconds: 5));
  } on MissingPluginException catch (failure) {
    throw RemotePairingFailure(
      'pairing/app-version',
      '无法读取 App 版本号（本机没有 app.metadata 通道方法）。',
      failure,
    );
  } on PlatformException catch (failure) {
    throw RemotePairingFailure(
      'pairing/app-version',
      '读取 App 版本号失败：${failure.message ?? failure.code}。',
      failure,
    );
  } on TimeoutException catch (failure) {
    throw RemotePairingFailure('pairing/app-version', '读取 App 版本号超时。', failure);
  }
  if (raw == null) {
    throw const RemotePairingFailure(
      'pairing/app-version',
      '无法读取 App 版本号（回执为空）。',
    );
  }
  final Object? metadata;
  try {
    metadata = jsonDecode(raw);
  } on FormatException catch (failure) {
    throw RemotePairingFailure(
      'pairing/app-version',
      'App 版本号回执不是合法 JSON。',
      failure,
    );
  }
  if (metadata is! Map) {
    throw const RemotePairingFailure(
      'pairing/app-version',
      'App 版本号回执不是 JSON 对象。',
    );
  }
  final version = metadata['version'];
  if (version is! String || version.isEmpty) {
    throw const RemotePairingFailure(
      'pairing/app-version',
      'App 版本号回执缺少 version。',
    );
  }
  final build = metadata['build'];
  return build is int ? '$version+$build' : version;
}
