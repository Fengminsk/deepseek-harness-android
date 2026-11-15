/// 远程宿主推送的系统通知（协议 §8）：严格解析、去重与系统通知桥。
///
/// 本模块只做三件事，不碰页面、不碰连接生命周期：
///
/// 1. **严格解析** `remote.taskCompleted`（§8.2）、`remote.approvalPending`
///    （§8.3）与 `remote.sessionChanged`（§8.5）：必填字段、类型、枚举、字段长度与
///    帧字节上限任何一项不合格就丢弃整帧并 `debugPrint`，不崩溃，也不把半个帧交给
///    上层；
/// 2. **去重**：同一 `interactionId` 的审批只弹一次系统通知；同一
///    `sessionId + turn` 的任务完成只弹一次（`turn` 缺失时退回协议 `taskId`），避免
///    宿主重发或重连后重复打扰；
/// 3. **系统通知桥**：[RemoteNotificationBridge] 把「弹一条 / 清全部」抽象成异步
///    调用。生产实现走 `dsh/runtime` 的 `notifications.remote.show` /
///    `notifications.remote.cancelAll`，失败只 `debugPrint`，不影响远程连接。
///
/// ## 前台抑制放在消费处
///
/// App 在前台时，页面线（`RemoteConnectionController.events` → 首页/会话页刷新）
/// 已经呈现了同一事实，再弹系统通知就是重复打扰（协议 §8.1 只要求 App 对
/// `remote.*` 触发系统通知，不要求同时同地呈现两次）。因此判断放在
/// [RemoteNotificationDispatcher]：只有 `isAppForeground()` 为 false（默认实现是
/// `WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed`）才调用
/// [RemoteNotificationBridge.show]。连接层只负责转发与计数，页面挂载处不需要再判。
///
/// 前台抑制不改变去重与通知流：帧仍会进 [RemoteNotificationDispatcher.notifications]
/// 广播，只是不调 bridge；App 退到后台后同一事实不会补弹。
///
/// ## 断开时清理
///
/// [RemoteNotificationDispatcher.clear] 清空去重表并调用
/// [RemoteNotificationBridge.cancelAll]（Kotlin 侧只取消本类 tag 前缀的远程通知，
/// 不会误清本地模式的通知）。连接层在断连、切换电脑、收到 `remote.deviceRevoked`
/// 以及冷启动后的第一次建连时调用它；第一次建连顺带清掉上一次进程遗留的远程通知。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'runtime.dart';

/// `remote.taskCompleted` 通知的方法名（协议 §8.2）。
const String remoteTaskCompletedMethod = 'remote.taskCompleted';

/// `remote.approvalPending` 通知的方法名（协议 §8.3）。
const String remoteApprovalPendingMethod = 'remote.approvalPending';

/// `remote.sessionChanged` 通知的方法名（协议 §8.5）。
const String remoteSessionChangedMethod = 'remote.sessionChanged';

/// `remote.taskCompleted` 的帧字节上限（协议 §8.2）；超限帧丢弃。
const int remoteTaskCompletedFrameBytes = 8 * 1024;

/// `remote.approvalPending` 的帧字节上限（协议 §8.3）；超限帧丢弃。
const int remoteApprovalPendingFrameBytes = 16 * 1024;

/// `remote.sessionChanged` 的帧字节上限（协议 §8.5）；超限帧丢弃。
const int remoteSessionChangedFrameBytes = 4 * 1024;

/// 协议里各种 id 的字符上限（§8.2–§8.5）。
const int remoteNotificationIdMaxChars = 128;

/// 标题类字段的字符上限（§8.2–§8.5）。
const int remoteNotificationTitleMaxChars = 200;

const int _taskSummaryMaxChars = 512;
const int _approvalSummaryMaxChars = 1024;
const int _toolNameMaxChars = 128;

const Set<String> _taskStatuses = <String>{'completed', 'failed', 'cancelled'};
const Set<String> _approvalKinds = <String>{'approval', 'question', 'plan'};

/// 远程系统通知的种类；[RemoteNotification.kind] 决定渠道、tag 与去重键。
enum RemoteNotificationKind {
  /// 宿主上的任务结束（协议 §8.2）。
  taskCompleted,

  /// 宿主上有一条待处理的审批/提问/方案确认（协议 §8.3）。
  approvalPending,
}

/// 一条已校验的远程系统通知。
///
/// 字段来源是协议 §8.2 / §8.3，但只保留 App 侧展示、去重与点击路由需要的部分：
/// 字段名与协议一致，`tag` 是协议 id（任务用 `taskId`、审批用 `interactionId`），
/// 交给 Kotlin 侧拼 notification tag 用于覆盖同一对象的旧通知。
class RemoteNotification {
  /// 创建一条已校验的通知（只由本文件的解析函数调用）。
  const RemoteNotification({
    required this.kind,
    required this.sessionId,
    required this.title,
    required this.body,
    required this.tag,
    this.taskId,
    this.interactionId,
    this.workspaceId,
    this.status,
    this.interactionKind,
    this.toolName,
    this.turn,
    this.timestamp,
    this.truncated = false,
  });

  /// 通知种类（决定 Kotlin 渠道与 tag 前缀）。
  final RemoteNotificationKind kind;

  /// 所属会话；点击通知时作为 `pocket.sessionId` 带给 MainActivity。
  final String sessionId;

  /// 系统通知标题（协议 `title`，已 trim）。
  final String title;

  /// 系统通知正文（协议 `summary`；缺失时用种类兜底文案，见 [truncated]）。
  final String body;

  /// 协议 id：任务完成是 `taskId`，审批是 `interactionId`。
  final String tag;

  /// `remote.taskCompleted.taskId`；审批通知为 null。
  final String? taskId;

  /// `remote.approvalPending.interactionId`；任务通知为 null。
  final String? interactionId;

  /// 所属项目（协议可选字段）；未知为 null。
  final String? workspaceId;

  /// 任务结束状态：`completed` / `failed` / `cancelled`；审批通知为 null。
  final String? status;

  /// 审批种类：`approval` / `question` / `plan`；任务通知为 null。
  final String? interactionKind;

  /// 触发审批的工具名（协议可选字段）；未知为 null。
  final String? toolName;

  /// 结束的轮次序号（协议可选字段）；未知为 null。
  final int? turn;

  /// 协议时间戳（`completedAt` / `createdAt`，Unix 毫秒）。
  final int? timestamp;

  /// 是否有字段被宿主截断（协议 `truncated`）。
  ///
  /// 协议说「至少一个字段被截断」，但只有 `summary` 会构成 [body]；因此正文来自
  /// summary 时以省略号结尾，正文是兜底句时保持完整句子。
  final bool truncated;

  /// 去重键。
  ///
  /// 审批用 `interactionId`（同一请求只提醒一次，协议 §8.3）；任务完成用
  /// `sessionId + turn`（协议 §8.2 的轮次），`turn` 缺失时退回 `taskId`，否则同一
  /// 会话的多轮完成会被误判成同一条。
  String get dedupeKey {
    if (kind == RemoteNotificationKind.approvalPending) {
      return 'approvalPending:$tag';
    }
    final finishedTurn = turn;
    if (finishedTurn == null) return 'taskCompleted:$sessionId:$tag';
    return 'taskCompleted:$sessionId:$finishedTurn';
  }
}

/// 一条已校验的 `remote.sessionChanged`（协议 §8.5）。
///
/// 只用于更新连接层的事实（页面线通过 `events` 自行刷新列表），不弹系统通知：
/// 协议 §8.5 没有「用户需要立刻处理」的请求，后台归档提醒留给后续批次。
class RemoteSessionChange {
  /// 创建一条已校验的会话变更。
  const RemoteSessionChange({
    required this.sessionId,
    required this.revision,
    required this.updatedAt,
    this.workspaceId,
    this.title,
    this.archived,
    this.removed,
  });

  /// 会话 id。
  final String sessionId;

  /// 同一 `sessionId` 内单调递增的版本号；回退帧由连接层丢弃（协议 §8.5）。
  final int revision;

  /// 变更时间（Unix 毫秒）。
  final int updatedAt;

  /// 所属项目（可选）。
  final String? workspaceId;

  /// 会话标题（可选）。
  final String? title;

  /// 是否已归档（可选）。
  final bool? archived;

  /// 是否已被删除（可选）。
  final bool? removed;
}

/// 解析一条 `remote.taskCompleted`（协议 §8.2）。
///
/// 必填字段缺失、类型不对、枚举越界、字段/帧超限或 `title` 为空白时返回 null 并
/// `debugPrint`；调用方据此丢弃该帧。
RemoteNotification? parseRemoteTaskCompleted(Map<String, dynamic> params) {
  try {
    _requireFrameBytes(
      remoteTaskCompletedMethod,
      params,
      remoteTaskCompletedFrameBytes,
    );
    final fields = _FrameFields(params);
    final taskId = fields.requiredString(
      'taskId',
      remoteNotificationIdMaxChars,
    );
    final sessionId = fields.requiredString(
      'sessionId',
      remoteNotificationIdMaxChars,
    );
    final workspaceId = fields.optionalString(
      'workspaceId',
      remoteNotificationIdMaxChars,
    );
    final title = fields.requiredString(
      'title',
      remoteNotificationTitleMaxChars,
    ).trim();
    final status = fields.requiredEnum('status', _taskStatuses);
    final turn = fields.optionalNonNegativeInt('turn');
    final completedAt = fields.requiredNonNegativeInt('completedAt');
    final summary = (fields.optionalString(
      'summary',
      _taskSummaryMaxChars,
    ) ?? '').trim();
    final truncated = fields.optionalBool('truncated') ?? false;
    // `truncated` 表示「至少一个协议字段被截断」，其中只有 summary 构成正文；正文缺失时
    // 用的是完整兜底句，补省略号反而像内容没说完，因此只在 summary 存在时透传。
    final body = summary.isEmpty
        ? _taskCompletedFallback(status)
        : _withTruncationEllipsis(summary, truncated);
    return RemoteNotification(
      kind: RemoteNotificationKind.taskCompleted,
      sessionId: sessionId,
      title: title,
      body: body,
      tag: taskId,
      taskId: taskId,
      workspaceId: workspaceId,
      status: status,
      turn: turn,
      timestamp: completedAt,
      truncated: truncated,
    );
  } on _InvalidFrame catch (invalid) {
    debugPrint('丢弃 $remoteTaskCompletedMethod 帧：${invalid.reason}');
    return null;
  }
}

/// 解析一条 `remote.approvalPending`（协议 §8.3）。
///
/// 校验规则与 [parseRemoteTaskCompleted] 相同；不合格帧返回 null 并 `debugPrint`。
RemoteNotification? parseRemoteApprovalPending(Map<String, dynamic> params) {
  try {
    _requireFrameBytes(
      remoteApprovalPendingMethod,
      params,
      remoteApprovalPendingFrameBytes,
    );
    final fields = _FrameFields(params);
    final interactionId = fields.requiredString(
      'interactionId',
      remoteNotificationIdMaxChars,
    );
    final sessionId = fields.requiredString(
      'sessionId',
      remoteNotificationIdMaxChars,
    );
    final kind = fields.requiredEnum('kind', _approvalKinds);
    final title = fields.requiredString(
      'title',
      remoteNotificationTitleMaxChars,
    ).trim();
    final summary = (fields.optionalString(
      'summary',
      _approvalSummaryMaxChars,
    ) ?? '').trim();
    final toolName = fields.optionalString('toolName', _toolNameMaxChars);
    final createdAt = fields.requiredNonNegativeInt('createdAt');
    final truncated = fields.optionalBool('truncated') ?? false;
    // 与 §8.2 相同：只有 summary 构成正文，缺失时用完整兜底句，不补省略号。
    final body = summary.isEmpty
        ? _approvalPendingFallback(kind)
        : _withTruncationEllipsis(summary, truncated);
    return RemoteNotification(
      kind: RemoteNotificationKind.approvalPending,
      sessionId: sessionId,
      title: title,
      body: body,
      tag: interactionId,
      interactionId: interactionId,
      interactionKind: kind,
      toolName: toolName,
      timestamp: createdAt,
      truncated: truncated,
    );
  } on _InvalidFrame catch (invalid) {
    debugPrint('丢弃 $remoteApprovalPendingMethod 帧：${invalid.reason}');
    return null;
  }
}

/// 解析一条 `remote.sessionChanged`（协议 §8.5）。
///
/// 不合格帧返回 null 并 `debugPrint`；`revision` 回退的帧由连接层丢弃（§8.5），
/// 解析层只负责字段校验。
RemoteSessionChange? parseRemoteSessionChanged(Map<String, dynamic> params) {
  try {
    _requireFrameBytes(
      remoteSessionChangedMethod,
      params,
      remoteSessionChangedFrameBytes,
    );
    final fields = _FrameFields(params);
    final sessionId = fields.requiredString(
      'sessionId',
      remoteNotificationIdMaxChars,
    );
    final workspaceId = fields.optionalString(
      'workspaceId',
      remoteNotificationIdMaxChars,
    );
    final revision = fields.requiredNonNegativeInt('revision');
    final title = fields.optionalString(
      'title',
      remoteNotificationTitleMaxChars,
    );
    final archived = fields.optionalBool('archived');
    final removed = fields.optionalBool('removed');
    final updatedAt = fields.requiredNonNegativeInt('updatedAt');
    return RemoteSessionChange(
      sessionId: sessionId,
      revision: revision,
      updatedAt: updatedAt,
      workspaceId: workspaceId,
      title: title,
      archived: archived,
      removed: removed,
    );
  } on _InvalidFrame catch (invalid) {
    debugPrint('丢弃 $remoteSessionChangedMethod 帧：${invalid.reason}');
    return null;
  }
}

/// 系统通知的设备侧桥；测试注入内存实现，生产走 `dsh/runtime` 通道。
abstract class RemoteNotificationBridge {
  /// 弹出一条远程系统通知。
  ///
  /// 实现必须自己吞掉设备侧失败（见 [MethodChannelRemoteNotificationBridge]）：
  /// 系统通知只是提醒，失败不能影响远程连接。
  Future<void> show(RemoteNotification notification);

  /// 取消本类弹出过的全部远程系统通知；不影响本地模式的通知。
  Future<void> cancelAll();
}

/// 生产实现：`dsh/runtime` 通道上的 `notifications.remote.*` 方法。
///
/// 宿主的方法名与 Kotlin 侧 `RemoteNotifications` 的 channel 分支一一对应；任何
/// 失败（通道未实现、权限变化、Activity 已销毁）只 `debugPrint`。
class MethodChannelRemoteNotificationBridge implements RemoteNotificationBridge {
  /// 创建桥。
  ///
  /// [channel] 默认是 `RuntimeController.channel`（`dsh/runtime`），测试可以换成
  /// 自己的通道名。
  MethodChannelRemoteNotificationBridge({MethodChannel? channel})
    : _channel = channel ?? RuntimeController.channel;

  /// 弹一条远程通知的通道方法名。
  static const String showMethod = 'notifications.remote.show';

  /// 取消全部远程通知的通道方法名。
  static const String cancelAllMethod = 'notifications.remote.cancelAll';

  final MethodChannel _channel;

  @override
  Future<void> show(RemoteNotification notification) async {
    try {
      await _channel.invokeMethod<bool>(showMethod, <String, dynamic>{
        'kind': notification.kind.name,
        'title': notification.title,
        'body': notification.body,
        'tag': notification.tag,
        'sessionId': notification.sessionId,
        if (notification.workspaceId != null)
          'workspaceId': notification.workspaceId,
        if (notification.status != null) 'status': notification.status,
        if (notification.interactionKind != null)
          'interactionKind': notification.interactionKind,
        if (notification.turn != null) 'turn': notification.turn,
        if (notification.timestamp != null) 'timestamp': notification.timestamp,
      });
    } on Object catch (error) {
      // 系统通知只是提醒：通道未接通、权限被改、进程重建都不该影响远程连接。
      debugPrint('弹出远程系统通知失败：$error');
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>(cancelAllMethod);
    } on Object catch (error) {
      debugPrint('清理远程系统通知失败：$error');
    }
  }
}

/// 消费 `remote.taskCompleted` / `remote.approvalPending` 并决定是否弹系统通知。
///
/// 连接层把已通过方法名分流的 `params` 交给 [handle]；本类完成严格解析、去重、
/// 广播（[notifications]）与前台抑制。非前台时才调用 bridge，失败只记录。
class RemoteNotificationDispatcher {
  /// 创建分发器。
  ///
  /// [bridge] 是设备侧出口；[isAppForeground] 缺省读
  /// `WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed`，测试注入
  /// 一个可变开关即可覆盖前台/后台两条路径。
  RemoteNotificationDispatcher({
    required this.bridge,
    bool Function()? isAppForeground,
  }) : _isAppForeground = isAppForeground ?? _defaultIsAppForeground;

  /// 去重表上限。
  ///
  /// 一条长连接可能收到很多通知；按插入顺序淘汰最旧的键，内存有界，而同一
  /// interactionId / 轮次的重复通知实际上总是紧挨着到达。
  static const int maxRememberedNotifications = 256;

  /// 设备侧出口（弹一条 / 清全部远程系统通知）。
  final RemoteNotificationBridge bridge;

  final bool Function() _isAppForeground;
  final Set<String> _remembered = <String>{};
  final StreamController<RemoteNotification> _notifications =
      StreamController<RemoteNotification>.broadcast();
  bool _disposed = false;

  /// 通过解析与去重的通知流（含前台被抑制的那些）。
  ///
  /// 页面线仍以 `RemoteConnectionController.events` 的原始帧为准；这个流只用于
  /// 「刚刚完成 / 待处理」类提示，订阅方自己决定是否有必要展示。
  Stream<RemoteNotification> get notifications => _notifications.stream;

  /// App 现在是否在前台。
  bool get isAppForeground => _isAppForeground();

  /// 处理一条 `remote.*` 通知帧；返回该帧是否被接受（解析通过且不是重复）。
  ///
  /// 只有 [remoteTaskCompletedMethod] 与 [remoteApprovalPendingMethod] 会被识别；
  /// 其余方法名忽略并返回 false（`remote.sessionChanged` 由连接层单独处理）。
  bool handle(String method, Map<String, dynamic> params) {
    if (_disposed) return false;
    final notification = switch (method) {
      remoteTaskCompletedMethod => parseRemoteTaskCompleted(params),
      remoteApprovalPendingMethod => parseRemoteApprovalPending(params),
      _ => null,
    };
    if (notification == null) return false;
    if (!_remember(notification.dedupeKey)) return false;
    if (!_notifications.isClosed) _notifications.add(notification);
    // 前台由页面线呈现，只有不在前台才弹系统通知（协议 §8.1 的唯一一条线）。
    if (!_isAppForeground()) unawaited(_show(notification));
    return true;
  }

  /// 清空去重表并取消全部远程系统通知。
  ///
  /// 连接层在断连、切换电脑、收到 `remote.deviceRevoked` 与冷启动后的第一次建连时
  /// 调用；bridge 失败不影响连接（只记录）。
  void clear() {
    if (_disposed) return;
    _remembered.clear();
    unawaited(_cancelAll());
  }

  /// 关闭通知广播；之后 [handle] 与 [clear] 都是空操作。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_notifications.isClosed) unawaited(_notifications.close());
  }

  bool _remember(String key) {
    if (!_remembered.add(key)) return false;
    while (_remembered.length > maxRememberedNotifications) {
      _remembered.remove(_remembered.first);
    }
    return true;
  }

  Future<void> _show(RemoteNotification notification) async {
    try {
      await bridge.show(notification);
    } on Object catch (error) {
      // 设备侧桥已经自己吞错；这里兜底注入实现抛错的测试/未来实现。
      debugPrint('弹出远程系统通知失败：$error');
    }
  }

  Future<void> _cancelAll() async {
    try {
      await bridge.cancelAll();
    } on Object catch (error) {
      debugPrint('清理远程系统通知失败：$error');
    }
  }

  static bool _defaultIsAppForeground() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
}

String _taskCompletedFallback(String status) => switch (status) {
  'failed' => '本轮任务失败，轻点查看详情。',
  'cancelled' => '本轮任务已取消。',
  _ => '本轮任务已完成，轻点查看回复。',
};

String _approvalPendingFallback(String kind) => switch (kind) {
  'question' => '有一个问题等待你回答。',
  'plan' => '有一个方案等待你确认。',
  _ => '有一个审批等待你处理。',
};

/// `truncated` 透传：宿主已截断的正文补一个省略号；已经以省略号结尾的不重复补。
String _withTruncationEllipsis(String body, bool truncated) {
  if (!truncated || body.isEmpty || body.endsWith('…')) return body;
  return '$body…';
}

void _requireFrameBytes(
  String method,
  Map<String, dynamic> params,
  int limitBytes,
) {
  final int size;
  try {
    size = utf8.encode(jsonEncode(params)).length;
  } on Object {
    throw _InvalidFrame('帧无法序列化为 JSON');
  }
  // 协议 §8.1 要求宿主截断到上限内；超限帧说明对端不守协议，整帧丢弃。
  if (size > limitBytes) {
    throw _InvalidFrame('帧 $size 字节超过 $limitBytes 上限');
  }
}

/// 协议帧字段的严格读取器：类型/长度/枚举任一不合格都抛 [_InvalidFrame]。
class _FrameFields {
  _FrameFields(this._params);

  final Map<String, dynamic> _params;

  String requiredString(String key, int maxLength) {
    final value = _params[key];
    if (value is! String) throw _InvalidFrame('$key 缺失或不是字符串');
    if (value.trim().isEmpty) throw _InvalidFrame('$key 为空白');
    if (value.length > maxLength) {
      throw _InvalidFrame('$key 超过 $maxLength 字符');
    }
    return value;
  }

  String? optionalString(String key, int maxLength) {
    final value = _params[key];
    if (value == null) return null;
    if (value is! String) throw _InvalidFrame('$key 不是字符串');
    if (value.length > maxLength) {
      throw _InvalidFrame('$key 超过 $maxLength 字符');
    }
    return value;
  }

  int requiredNonNegativeInt(String key) {
    final value = _params[key];
    if (value is! int) throw _InvalidFrame('$key 缺失或不是整数');
    if (value < 0) throw _InvalidFrame('$key 为负数');
    return value;
  }

  int? optionalNonNegativeInt(String key) {
    final value = _params[key];
    if (value == null) return null;
    if (value is! int) throw _InvalidFrame('$key 不是整数');
    if (value < 0) throw _InvalidFrame('$key 为负数');
    return value;
  }

  bool? optionalBool(String key) {
    final value = _params[key];
    if (value == null) return null;
    if (value is! bool) throw _InvalidFrame('$key 不是布尔值');
    return value;
  }

  String requiredEnum(String key, Set<String> allowed) {
    final value = _params[key];
    if (value is! String) throw _InvalidFrame('$key 缺失或不是字符串');
    if (!allowed.contains(value)) {
      throw _InvalidFrame('$key 的值「$value」不在协议枚举内');
    }
    return value;
  }
}

/// 解析失败：整帧丢弃，原因只进 `debugPrint`。
class _InvalidFrame implements Exception {
  const _InvalidFrame(this.reason);

  final String reason;
}
