/// 传输缝：本地 socketpair 与远程 wss 的唯一替换点。
///
/// 为什么要这个文件：`RuntimeController` 的全部页面只依赖两个原语——一次带参数
/// 的请求，以及一条入站通知流。本地模式下这两个原语的物理通道是同进程的
/// socketpair（MethodChannel + EventChannel），远程模式下是一条 `wss://` 连接
/// （见 docs/remote-dsh/protocol.md）。把它们抽成 [RuntimeTransport]，控制器就
/// 只持有一个字段，本地传输与远程传输可以互换，页面与业务代码一行都不用改。
///
/// 实现者只收发帧、不解释业务方法：方法表由宿主侧门面决定，传输层不认识
/// `session.*` / `api.*` 的语义。
///
/// 本文件只依赖 dart:async 与 dart:convert：不 import flutter，也不 import
/// dart:io。远程实现要跑在没有 Flutter 绑定的环境里，也必须能共用同一个接口与
/// 同一个失败类型。
library;

import 'dart:async';
import 'dart:convert';

/// 本地与远程共用的唯一传输缝。
///
/// 方法名、参数、错误码与远端帧格式以 docs/remote-dsh/protocol.md 为准；本接口
/// 只承载“发一次请求 / 收一条通知 / 关闭”，不承载流控、重连与握手——那些是实现
/// 者的内部状态，对调用方不可见。
abstract interface class RuntimeTransport {
  /// 发送一次请求并等待响应。
  ///
  /// [params] 一律作为请求的 `params` 字段上线，不拼进方法名，也不塞进 `id`。
  /// 失败时抛 [RuntimeTransportFailure]：`code` 取 `result._pocket_error.code`
  /// （应用层，协议 §9.2）或 `error.data.code`（协议层，协议 §9.1），`message`
  /// 是已经组装好、可直接 `Text()` 的中文，`details` 是原始错误对象。
  /// 传输已关闭时抛 `code: 'gateway/cancelled'`。
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]);

  /// 发送一条单向通知，不等待结果。传输已关闭时静默丢弃。
  ///
  /// 本地实现不支持这个方向，见 [LocalRuntimeTransport.notify]。
  void notify(String method, [Map<String, dynamic> params = const {}]);

  /// 入站通知帧，形态固定为 `{'method': String, 'params': Map}`，包含
  /// `api.stream` 与全部 `remote.*`；不包含响应帧。
  Stream<Map<String, dynamic>> get events;

  /// 关闭传输：未结算请求以 `gateway/cancelled` 失败，[events] 随后关闭。
  ///
  /// 幂等，重复调用不抛。
  Future<void> close();

  /// 安装反向请求处理器（宿主 → App 的 `native.*` 请求）。
  ///
  /// handler 的返回值即 JSON-RPC `result`。handler 抛 [UnsupportedError] 或
  /// `code: 'unsupported-method'` 的失败时，传输层回 `-32601`；其它异常回
  /// `-32603`，消息截断到 1024 字节。未安装 handler 时，所有反向请求回 `-32601`。
  /// 本地实现永不触发，见 [LocalRuntimeTransport.setRequestHandler]。
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  );
}

/// 传输层唯一的失败类型。
///
/// 字段与 `flutter/services` 的 `PlatformException` 一一对应，语义也相同：
///
/// - `code`：`result._pocket_error.code`（应用层 `gateway/*`，协议 §9.2）或
///   `error.data.code`（协议层，协议 §9.1）；传输自身关闭时是 `gateway/cancelled`。
/// - `message`：可以直接展示的中文（协议 §9.4），调用方只做长度截断，不再拼前缀。
/// - `details`：原始错误对象；本地产生的失败（例如关闭）没有原始对象，为 null。
///
/// 不直接复用 `PlatformException`，是因为本文件不能 import flutter/services：远程
/// 实现要在纯 Dart 环境里产生同一类失败，页面才能用同一段 catch 处理两种传输。
class RuntimeTransportFailure implements Exception {
  const RuntimeTransportFailure({
    required this.code,
    required this.message,
    this.details,
  });

  /// 错误码，例如 `gateway/bad-request`、`auth-revoked`、`gateway/cancelled`。
  final String code;

  /// 可直接展示的中文句子，不做二次加工。
  final String message;

  /// 原始错误对象（`_pocket_error` 或 JSON-RPC `error`）；本地产生的失败为 null。
  final Object? details;

  @override
  String toString() => 'RuntimeTransportFailure($code): $message';
}

/// 注入给 [LocalRuntimeTransport] 的请求执行器签名。
///
/// [payload] 是 `params` 的 JSON 文本（**不含** `method` 与 `id`，那两个由装配方
/// 负责封装）；返回原生侧的 JSON 文本，原生侧没有结果时返回 null。
/// `RuntimeController` 用它拼出既有的 `{'method': …, 'params': …}` 封装并打
/// MethodChannel，因此本文件不需要知道平台通道的存在。
typedef LocalRuntimeInvoke = Future<String?> Function(
  String method,
  String payload,
);

/// 本地模式实现：请求交给注入的 [LocalRuntimeInvoke]，入站通知来自注入的事件流。
///
/// 它只做三件事：把 `params` 编码成 JSON 文本、解出 `_pocket_error`、把入站事件
/// 转发给 [events]。真正的 MethodChannel / EventChannel 动作全部在
/// `RuntimeController` 里，所以本类可以脱离 Flutter 绑定被单测直接构造。
class LocalRuntimeTransport implements RuntimeTransport {
  /// 创建本地传输。
  ///
  /// [invoke] 执行一次真实调用；[events] 是宿主推来的通知流（由控制器从既有
  /// EventChannel 泵入，形态与 [RuntimeTransport.events] 相同）。
  LocalRuntimeTransport({
    required LocalRuntimeInvoke localInvoke,
    required Stream<Map<String, dynamic>> events,
  }) : _invoke = localInvoke,
       _inbound = events {
    _subscription = _inbound.listen(_forwardEvent, onError: _forwardError);
  }

  final LocalRuntimeInvoke _invoke;
  final Stream<Map<String, dynamic>> _inbound;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<dynamic> Function(String method, Map<String, dynamic> params)?
  _requestHandler;
  Future<void>? _closing;
  bool _closed = false;

  /// 传输关闭后再次请求时的固定失败（协议 §9.2 的 `gateway/cancelled` 文案）。
  static const RuntimeTransportFailure _closedFailure = RuntimeTransportFailure(
    code: 'gateway/cancelled',
    message: '操作已取消（连接或页面已关闭）。',
  );

  /// 入站通知流，形态与 [RuntimeTransport.events] 相同。
  ///
  /// 单订阅：只允许一个消费者（控制器的事件泵）。还没有订阅者时事件会缓冲在
  /// 内部控制器里，不会丢；取消订阅后不能再订阅。
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 把 `params` 编码成 JSON 文本交给注入的 [LocalRuntimeInvoke]，再解码结果。
  ///
  /// 结果若是带 `_pocket_error` 的对象，按既有约定转成
  /// [RuntimeTransportFailure] 抛出（本地模式下 `gateway/*` 一直走这条路径）。
  /// 注入的 invoke 自己抛出的异常（例如 MethodChannel 未注册时的
  /// `PlatformException`）原样透传：本层没有 flutter/services，无法识别它的类型，
  /// 也不应该把结构化失败重新包装一遍。
  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_closed) throw _closedFailure;
    final raw = await _invoke(method, jsonEncode(params));
    final decoded = raw == null ? null : jsonDecode(raw);
    if (decoded is Map<String, dynamic> &&
        decoded['_pocket_error'] is Map<String, dynamic>) {
      final failure = decoded['_pocket_error'] as Map<String, dynamic>;
      throw RuntimeTransportFailure(
        code: failure['code'] as String,
        message: failure['message'] as String,
        details: failure,
      );
    }
    return decoded;
  }

  /// 本地模式不产生 App → 宿主通知，直接抛 [UnsupportedError]。
  ///
  /// 原因：本地模式下宿主与 App 在同一个进程里，宿主不需要“通过传输”被告知；
  /// 现有本地通知全部是宿主 → App 方向（EventChannel），协议 v1 也没有定义
  /// App → 宿主的单向通知用例（协议 §4.1 只列请求方法）。抛出而不是静默丢弃，
  /// 是为了让“某段代码假设自己可以 notify”在首次联调时立刻暴露，而不是变成一个
  /// 永远不生效的调用。
  @override
  void notify(String method, [Map<String, dynamic> params = const {}]) {
    throw UnsupportedError('本地传输不支持 notify($method)：宿主在同进程内直接调用，不需要 App 主动通知。');
  }

  /// 存下反向请求处理器，但本地模式永不触发。
  ///
  /// 本地模式下 `native.*` 由宿主在**同一进程**里直接实现（协议 §5.2 的拦截表），
  /// 不存在“宿主 → App 的请求帧”，因此没有反向往返可交付。存下来只是为了让装配
  /// 代码对两种传输使用同一段逻辑，不必按模式分支。
  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {
    _requestHandler = handler;
  }

  /// 已安装的反向请求处理器；本地模式下只会被保存，永远不会被调用。
  ///
  /// 暴露读取点，一是让装配代码与测试能确认安装结果，二是避免这个“只写不读”的
  /// 字段被静态检查判成无用字段。
  Future<dynamic> Function(String method, Map<String, dynamic> params)?
  get requestHandler => _requestHandler;

  /// 关闭传输。幂等：重复调用（含并发调用）不抛，并返回同一次关闭的结果。
  ///
  /// 顺序固定：先取消入站订阅（关闭后不再有事件写进已关闭的控制器），再关闭
  /// [events]。已经在途的原生调用不受影响——MethodChannel 没有取消句柄，它返回后
  /// 仍会照常解析并交给调用方；[close] 之后新发起的请求以 `gateway/cancelled` 失败。
  ///
  /// 与接口契约的差异：本地模式不维护在途请求表，因此不会把已发出的请求主动以
  /// `gateway/cancelled` 失败。本地 `close` 只发生在 App 退出路径，此时控制器已经
  /// 不再接管结果；远程实现必须补上这一步（协议 §5.4）。
  @override
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    return _closing = _close();
  }

  Future<void> _close() async {
    // 同步置位：`_close()` 的第一个 await 之前，request 就能看到已关闭状态，
    // 不会出现“关到一半还接受新请求”的窗口。
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    // 不等待 close 的完成态：单订阅控制器当前没有监听者时 done 不会交付，
    // await 会把 App 的退出路径挂住。关闭动作本身已经生效，事件流不会再有新帧。
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _forwardEvent(Map<String, dynamic> event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _forwardError(Object error, [StackTrace? stackTrace]) {
    if (!_events.isClosed) _events.addError(error, stackTrace);
  }
}
