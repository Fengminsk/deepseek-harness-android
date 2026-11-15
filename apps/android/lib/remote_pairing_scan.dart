// 扫码配对：把系统相机拍到的二维码文本交给配对页。
//
// 原生侧（`PairingQrScan.kt`）用系统相机 intent 拍照，在后台线程用 ZXing 解码，
// 这里只做 MethodChannel 调用与错误翻译：配对协议、CA 指纹校验与设备令牌全部
// 仍走 `remote_pairing.dart` / `remote_pairing_flow.dart`。扫码只是把二维码内容
// 变成配对页输入框里的文本，不新增配对入口，也不改变「配对 = 完全信任」的语义。
//
// [PairingScanner] 抽出来是为了页面测试能注入假实现：真实实现只有 `dsh/runtime`
// 一条通道，测试不需要相机、图片或 Flutter 插件。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// 扫码用的 MethodChannel 方法名（`MainActivity` 的 `remote.pairing.scan`）。
const String pairingScanMethod = 'remote.pairing.scan';

/// 调试构建「从图片文件解码」的方法名；release 上原生不注册该方法。
const String pairingScanImageMethod = 'remote.pairing.scanImage';

/// 一次扫码失败。
///
/// [code] 与原生错误码一致（`pairing/camera-unavailable`、`pairing/decode-failed`），
/// [message] 是可直接展示的中文。
class PairingScanFailure implements Exception {
  /// 记录失败类别与可展示文案。
  const PairingScanFailure(this.code, this.message, [this.details]);

  /// 失败类别。
  final String code;

  /// 可直接展示的中文说明。
  final String message;

  /// 原始异常，只用于排障。
  final Object? details;

  @override
  String toString() => 'PairingScanFailure($code): $message';
}

/// 用户在相机里取消了扫码（按返回键或关掉相机）。
///
/// 取消不是失败：配对页收到它时保持输入框与提示不变，也不展示错误。
class PairingScanCancelled implements Exception {
  /// 记录一次用户取消。
  const PairingScanCancelled();

  @override
  String toString() => 'PairingScanCancelled';
}

/// 扫码器：成功返回二维码文本，用户取消抛 [PairingScanCancelled]，其余失败抛
/// [PairingScanFailure]。
abstract class PairingScanner {
  /// 打开相机扫码并返回其中的文本。
  Future<String> scan();
}

/// 走 `dsh/runtime` 的生产实现。
class MethodChannelPairingScanner implements PairingScanner {
  /// 创建扫码器。
  ///
  /// [channel] 只用于测试替换，默认就是 `dsh/runtime`。
  MethodChannelPairingScanner({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/runtime');

  final MethodChannel _channel;

  @override
  Future<String> scan() =>
      _decode(pairingScanMethod, const <String, Object?>{});

  /// 调试构建专用：解码一张本机图片里的二维码（真机验收脚本的通道）。
  ///
  /// release 上 `remote.pairing.scanImage` 未注册，抛
  /// `pairing/camera-unavailable` 语义的 [MissingPluginException] 会被翻译成
  /// [PairingScanFailure]；产品代码不调用这个方法。
  Future<String> scanImage(String path) =>
      _decode(pairingScanImageMethod, <String, Object?>{'path': path});

  Future<String> _decode(String method, Map<String, Object?> arguments) async {
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>(method, arguments);
    } on MissingPluginException catch (failure) {
      throw PairingScanFailure(
        'pairing/camera-unavailable',
        '当前版本不支持扫码，请改为粘贴电脑上的配对链接。',
        failure,
      );
    } on PlatformException catch (failure) {
      if (failure.code == 'pairing/scan-cancelled') {
        throw const PairingScanCancelled();
      }
      throw PairingScanFailure(
        _codeOf(failure.code),
        failure.message ?? _fallbackMessage(failure.code),
        failure,
      );
    }
    return _textOf(raw);
  }

  /// 原生错误码收敛到页面认识的两种失败；未知码按解码失败处理。
  static String _codeOf(String code) {
    if (code == 'pairing/camera-unavailable') {
      return 'pairing/camera-unavailable';
    }
    return 'pairing/decode-failed';
  }

  static String _fallbackMessage(String code) {
    if (code == 'pairing/camera-unavailable') {
      return '这台手机上没有可用的相机应用，请改为粘贴电脑上的配对链接。';
    }
    return '扫码失败，请重试或改为粘贴电脑上的配对链接。';
  }

  /// 解析原生回执：`{text}` 成功，`{cancelled:true}` 取消。
  static String _textOf(String? raw) {
    if (raw == null) {
      throw const PairingScanFailure(
        'pairing/decode-failed',
        '扫码没有返回结果，请重试或改为粘贴电脑上的配对链接。',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (failure) {
      throw PairingScanFailure(
        'pairing/decode-failed',
        '扫码结果无法识别，请重试或改为粘贴电脑上的配对链接。',
        failure,
      );
    }
    if (decoded is! Map) {
      throw const PairingScanFailure(
        'pairing/decode-failed',
        '扫码结果无法识别，请重试或改为粘贴电脑上的配对链接。',
      );
    }
    if (decoded['cancelled'] == true) {
      throw const PairingScanCancelled();
    }
    final text = decoded['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const PairingScanFailure(
        'pairing/decode-failed',
        '扫码结果里没有二维码文本，请重试或改为粘贴电脑上的配对链接。',
      );
    }
    return text;
  }
}
