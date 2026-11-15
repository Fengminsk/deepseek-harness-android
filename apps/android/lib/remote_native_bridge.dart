// 远程连接上的反向请求应答：宿主 → App 的 `native.*`（协议 §5）。
//
// 附件上行（`docs/remote-dsh/p5-remaining-design.md` §3.4）的字节方向是反的：
// 宿主在 `attachments.prepare` 里用反向请求 `native.attachments.read` 向手机要
// 分页字节，手机只服务**当前草稿集合**里的 id（§3.4.6）。本文件负责：
//
// 1. 在每条远程传输建立后安装反向请求处理器（`RemoteConnectionController.connect`）；
//    连接换代时重新安装，旧传输上的请求按「已换连接」回 `-32601`；
// 2. 只应答 `native.attachments.read`，其余方法一律抛 [UnsupportedError]，由
//    `RemoteTransport` 翻译成 `-32601` + `data.code: unsupported-method`
//    （协议 §5.3 强制，不得静默丢弃）；
// 3. 把分页读转给设备侧 MethodChannel（`attachment.read` / `attachment.discard`，
//    见 `AttachmentTransfers.kt`），并按 §3.4.2 校验请求与响应形状。
//
// 分页大小固定 256 KiB：base64 后约 350 KiB，远低于 1 MiB 上行帧上限（协议 §1.3）。
// 页大小是协议常量（§3.4.2），不做成可配置项。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';
import 'runtime_transport.dart';

/// 宿主向 App 分页读取附件草稿的方法名（协议 §5.2 反向请求表）。
const String remoteAttachmentReadMethod = 'native.attachments.read';

/// 一页的字节上限（§3.4.2 的 `length` 上限，协议常量）。
const int remoteAttachmentReadPageBytes = 256 * 1024;

/// 设备侧通道方法：读取附件草稿的私有副本一页。
const String _deviceReadMethod = 'attachment.read';

/// 设备侧通道方法：删除附件草稿的私有副本（`.bin` 与 `.json`）。
const String _deviceDiscardMethod = 'attachment.discard';

/// `attachment.pick` 产生的小写 UUID v4（与 `attachments.mjs` 的校验同一条规则）。
final RegExp _attachmentIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// 设备侧 MethodChannel 的调用签名；测试可以换成纯内存实现。
typedef DeviceAttachmentCall = Future<String?> Function(
  String method,
  Map<String, dynamic> params,
);

/// 一条远程连接上的反向请求应答器。
///
/// 生产装配用 [instance]（进程内只有一条远程连接，协议 §11）；单测可以直接构造
/// 一个新实例并注入 [DeviceAttachmentCall]。
class RemoteNativeBridge {
  /// 创建应答器。
  ///
  /// @param invokeDevice 设备侧通道调用；缺省走 [RuntimeController.channel]。
  RemoteNativeBridge({DeviceAttachmentCall? invokeDevice})
    : _invokeDevice = invokeDevice ?? _invokeDeviceChannel;

  /// 生产装配使用的应答器（`RemoteConnectionController.connect` 安装它）。
  static final RemoteNativeBridge instance = RemoteNativeBridge();

  final DeviceAttachmentCall _invokeDevice;

  /// 允许宿主拉取字节的草稿 id。
  ///
  /// 只由 [RemoteAttachmentSurface] 在 `attachments.prepare` / `attachments.release`
  /// 时登记与注销：宿主永远拿不到「用户这次没选中的文件」的字节（§3.4.6）。
  final Set<String> _allowed = <String>{};

  /// 最近安装处理器的传输；连接换代后旧传输上的请求不再被服务。
  RuntimeTransport? _transport;

  /// 登记一条草稿，允许宿主在本次上传中分页读取它。
  void allow(String id) => _allowed.add(id);

  /// 注销一条草稿：release/dispose 之后宿主不能再读它。
  void deny(String id) => _allowed.remove(id);

  /// [id] 当前是否允许被读取。
  bool allows(String id) => _allowed.contains(id);

  /// 在 [transport] 上安装反向请求处理器（替换旧处理器）。
  ///
  /// 每次连接建立后调用一次；旧连接由连接控制器关闭，它的处理器随传输一起回收。
  void install(RuntimeTransport transport) {
    _transport = transport;
    transport.setRequestHandler(_handlerFor(transport));
  }

  Future<dynamic> Function(String method, Map<String, dynamic> params)
  _handlerFor(RuntimeTransport transport) {
    return (method, params) async {
      // 连接已换代：旧传输上迟到的反向请求不再属于当前设备连接，按不支持应答。
      if (!identical(_transport, transport)) throw UnsupportedError(method);
      return handle(method, params);
    };
  }

  /// 处理一条反向请求；返回 JSON-RPC `result`。
  ///
  /// 只接受 [remoteAttachmentReadMethod]，其余方法抛 [UnsupportedError]（传输层
  /// 回 `-32601`）。参数或设备响应不符合 §3.4.2 时抛
  /// `attachment-file/invalid-request` / `gateway/internal` 的
  /// [RuntimeTransportFailure]。
  Future<dynamic> handle(String method, Map<String, dynamic> params) async {
    if (method != remoteAttachmentReadMethod) throw UnsupportedError(method);
    return _read(params);
  }

  /// 删除设备上的附件副本（宿主 `attachments.release` 受理后由 App 发起）。
  ///
  /// 幂等：文件已不存在也算成功。失败只记录，不影响已完成的 release。
  Future<void> discard(String id) async {
    try {
      await _invokeDevice(_deviceDiscardMethod, <String, dynamic>{'id': id});
    } on PlatformException catch (failure) {
      debugPrint('清理手机上的附件副本失败：${failure.code} ${failure.message}');
    } on MissingPluginException catch (failure) {
      debugPrint('清理手机上的附件副本失败：$failure');
    }
  }

  Future<Map<String, dynamic>> _read(Map<String, dynamic> params) async {
    final id = params['id'];
    final offset = params['offset'];
    final length = params['length'];
    if (id is! String || offset is! int || length is! int) {
      throw _failure(
        'attachment-file/invalid-request',
        '附件读取请求缺少 id、offset 或 length。',
      );
    }
    // 集合外（含格式非法的 id）一律按「文件已不在手机上」应答，不暴露本机文件
    // 是否存在（§3.4.6）。
    if (!_attachmentIdPattern.hasMatch(id) || !_allowed.contains(id)) {
      throw _failure('attachment-file/not-found', '文件已不在手机上，请重新选择。');
    }
    if (offset < 0 || length < 1 || length > remoteAttachmentReadPageBytes) {
      throw _failure('attachment-file/invalid-request', '附件读取范围不正确。');
    }

    final String? raw;
    try {
      raw = await _invokeDevice(_deviceReadMethod, <String, dynamic>{
        'id': id,
        'offset': offset,
        'length': length,
      });
    } on PlatformException catch (failure) {
      throw _deviceFailure(failure);
    } on MissingPluginException catch (failure) {
      throw _failure('gateway/internal', '读取手机上的附件失败：$failure');
    }
    if (raw == null) {
      throw _failure('gateway/internal', '手机没有返回附件内容。');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw _failure('gateway/internal', '手机返回的附件分页不是合法 JSON。');
    }
    if (decoded is! Map<String, dynamic>) {
      throw _failure('gateway/internal', '手机返回的附件分页格式不正确。');
    }
    final data = decoded['data'];
    final nextOffset = decoded['nextOffset'];
    final size = decoded['size'];
    final eof = decoded['eof'];
    if (data is! String ||
        nextOffset is! int ||
        size is! int ||
        eof is! bool ||
        size < 0 ||
        nextOffset < offset ||
        nextOffset > size ||
        (eof && nextOffset != size) ||
        (!eof && nextOffset <= offset)) {
      throw _failure('gateway/internal', '手机返回的附件分页字段不完整。');
    }
    // 宿主按累计字节与 prepare 声明的 bytes 对账；这里只做同一条上限的硬校验，
    // base64 解码后的字节数不可能超过请求的 length。
    if (data.length > ((length + 2) ~/ 3) * 4) {
      throw _failure('gateway/internal', '手机返回的附件分页超过请求长度。');
    }
    return <String, dynamic>{
      'data': data,
      'nextOffset': nextOffset,
      'size': size,
      'eof': eof,
    };
  }

  static RuntimeTransportFailure _failure(String code, String message) =>
      RuntimeTransportFailure(code: code, message: message);

  static RuntimeTransportFailure _deviceFailure(PlatformException failure) {
    final message = failure.message?.trim();
    final fallback = message == null || message.isEmpty
        ? '读取手机上的附件失败，请重试。'
        : message;
    if (failure.code.startsWith('attachment-file/')) {
      return RuntimeTransportFailure(code: failure.code, message: fallback);
    }
    return RuntimeTransportFailure(code: 'gateway/internal', message: fallback);
  }

  static Future<String?> _invokeDeviceChannel(
    String method,
    Map<String, dynamic> params,
  ) => RuntimeController.channel.invokeMethod<String>(method, params);
}
