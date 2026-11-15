// 远程会话页的附件调用面：把 `AttachmentDrafts` 的请求转成那台电脑上的门面调用。
//
// 本文件只做三件事：
//
// 1. 把 `attachments.prepare` / `attachments.release` 转发到远程连接上的传输，
//    并把传输失败翻译成可直接展示的中文（设计文档 §3.4.3：`attachment-file/*`
//    与 `gateway/cancelled` 的专用文案）；
// 2. 维护「宿主可以分页读取哪些草稿」的登记：`prepare` 前登记、`release` 受理后
//    注销（§3.4.6）；注销后顺带删掉手机上的私有副本（设备内通道，不上线）；
// 3. 把连接的阶段与代际投影给 `AttachmentDrafts`：断连/换连接时草稿置为可重试
//    的失败态，沿用 `AttachmentDrafts.invalidateReceipts` 的语义。
//
// 附加在手机上、宿主拿不到路径：字节只经 `remote_native_bridge.dart` 安装的
// 反向请求按页送出，App 侧没有任何把路径交给宿主的入口。

import 'package:flutter/foundation.dart';

import 'attachment_surface.dart';
import 'remote_connection.dart';
import 'remote_native_bridge.dart';
import 'runtime_transport.dart';

/// 上传附件准备用的门面方法（参数 `{sessionId, id, name, mediaType, bytes}`）。
const String remoteAttachmentPrepareMethod = 'attachments.prepare';

/// 释放附件草稿用的门面方法（参数 `{sessionId, id}`）。
const String remoteAttachmentReleaseMethod = 'attachments.release';

/// 远程附件调用面需要的那台电脑的只读连接面。
///
/// 生产实现是 `RemoteConversationLiveSource` 的 `RemoteControllerConnection`；
/// 数据源只把这份最小面交给 [RemoteAttachmentSurface]，页面不直接碰连接控制器。
abstract interface class RemoteAttachmentConnection implements Listenable {
  /// 当前连接阶段。
  RemoteConnectionPhase get phase;

  /// 终止态的失败原因；没有失败时为 null。
  String? get lastError;

  /// 传输入口；未连接或终止态之后为 null。
  RuntimeTransport? get transport;
}

/// 远程附件失败：`code` 是宿主错误码，`message` 是可以直接展示的中文。
///
/// [toString] 只返回 message：`AttachmentDrafts` 把失败文本原样交给
/// `PocketAttachmentRail`，因此 rail 上展示的是「文件已不在手机上，请重新选择」
/// 这类说明，而不是异常类型前缀。
class RemoteAttachmentFailure implements Exception {
  /// 创建失败。
  const RemoteAttachmentFailure(this.code, this.message);

  /// 宿主/传输错误码，例如 `attachment-file/unsupported`、`gateway/cancelled`。
  final String code;

  /// 可直接展示的中文说明。
  final String message;

  @override
  String toString() => message;
}

/// 远程会话页的附件调用面，实现 [AttachmentCallSurface]。
///
/// 生命周期由会话页持有：页面销毁时调用 [dispose]。连接本身由远程首页持有，
/// 本类只读它的阶段、传输与代际，不改变连接生命周期。
class RemoteAttachmentSurface extends ChangeNotifier
    implements AttachmentCallSurface, AttachmentMetadataSurface {
  /// 绑定那台电脑的连接面。
  ///
  /// @param connection 远程连接；生命周期由调用方持有。
  /// @param bridge 反向请求应答器；缺省用进程内的 [RemoteNativeBridge.instance]。
  RemoteAttachmentSurface({
    required this.connection,
    RemoteNativeBridge? bridge,
  }) : _bridge = bridge ?? RemoteNativeBridge.instance {
    _transport = connection.transport;
    _ready =
        connection.phase == RemoteConnectionPhase.ready && _transport != null;
    connection.addListener(_connectionChanged);
  }

  /// 那台电脑的连接面。
  final RemoteAttachmentConnection connection;

  final RemoteNativeBridge _bridge;

  RuntimeTransport? _transport;
  bool _ready = false;
  int _generation = 0;
  bool _disposed = false;

  @override
  bool get ready => !_disposed && _ready;

  @override
  String get phase => ready ? 'ready' : connection.phase.name;

  /// 连接代际。
  ///
  /// 每次「重新握手成功」或换了一条传输对象时递增：`AttachmentDrafts` 据此把已
  /// 上传的收据置为「需重试」，与本地运行时重启的语义一致（§3.4.5）。
  @override
  int get connectionGeneration => _generation;

  void _connectionChanged() {
    if (_disposed) return;
    final nextTransport = connection.transport;
    final nextReady =
        connection.phase == RemoteConnectionPhase.ready &&
        nextTransport != null;
    if (nextReady && (!_ready || !identical(nextTransport, _transport))) {
      _generation++;
    }
    _transport = nextTransport;
    _ready = nextReady;
    notifyListeners();
  }

  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final transport = connection.transport;
    if (!ready || transport == null) {
      throw const RemoteAttachmentFailure(
        'gateway/cancelled',
        '与电脑的连接已断开，请重试。',
      );
    }
    final id = params['id'];
    // 宿主在 `attachments.prepare` 内分页拉取字节：先登记，再发请求，反向请求
    // 到达时这个 id 才在草稿集合里（§3.4.6）。
    final preparing = method == remoteAttachmentPrepareMethod && id is String;
    if (preparing) _bridge.allow(id);
    final dynamic result;
    try {
      result = await transport.request(method, params);
    } on RuntimeTransportFailure catch (failure) {
      throw _translate(failure);
    }
    if (result is Map<String, dynamic> &&
        result['_pocket_error'] is Map<String, dynamic>) {
      final envelope = result['_pocket_error'] as Map<String, dynamic>;
      final code = envelope['code'];
      throw RemoteAttachmentFailure(
        code is String ? code : 'gateway/internal',
        _messageFor(
          code is String ? code : 'gateway/internal',
          envelope['message'] is String ? envelope['message'] as String : '',
        ),
      );
    }
    // release 受理后宿主不再持有这条草稿：注销反向读取资格，并删除手机上的
    // 私有副本（设备内通道，不上线）。清理失败不影响 release 的受理结果。
    if (method == remoteAttachmentReleaseMethod && id is String) {
      _bridge.deny(id);
      await _bridge.discard(id);
    }
    return result;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    connection.removeListener(_connectionChanged);
    super.dispose();
  }

  RemoteAttachmentFailure _translate(RuntimeTransportFailure failure) =>
      RemoteAttachmentFailure(
        failure.code,
        _messageFor(failure.code, failure.message),
      );

  /// 把宿主错误码翻译成 §3.4.3 的专用文案；其它错误沿用宿主给的 message。
  static String _messageFor(String code, String message) {
    final fallback = message.trim();
    switch (code) {
      case 'attachment-file/not-found':
        return '文件已不在手机上，请重新选择。';
      case 'attachment-file/unsupported':
        return '这台手机上的 App 版本不支持上传附件。';
      case 'attachment-file/changed':
        return '选择的文件已变化，请重新选择。';
      case 'attachment-file/invalid-request':
        return '附件读取请求不正确，请重新选择文件。';
      case 'gateway/cancelled':
        return '连接已断开，请重试。';
      case 'gateway/timeout':
        return '电脑上的 DSH 响应超时，请重试。';
      case 'gateway/unavailable':
        return '与电脑的连接已断开，正在重连…';
      default:
        return fallback.isEmpty ? '上传附件失败，请重试。' : fallback;
    }
  }
}
