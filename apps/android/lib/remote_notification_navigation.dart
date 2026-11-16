/// 远程系统通知点击后的深链：pending 的解析、读取与消费。
///
/// 系统通知由 [RemoteNotifications]（Kotlin）弹出，点击 Intent 带 `pocket.route=remote`、
/// `pocket.sessionId`、`pocket.remoteKind`、`pocket.remoteTag` 四个 extra。平台层在启动
/// Intent 与 `onNewIntent` 里把它们校验后存成 pending，Dart 通过 `dsh/runtime` 的
/// `notifications.launch.take` **取一次即清空**（见 [MethodChannelRemoteNotificationLaunchSource]）。
///
/// 本模块只负责「把一次点击变成一个可导航的会话」，不碰页面与连接：
///
/// 1. [RemoteNotificationLaunch.parse] 严格解析原生返回的 JSON：`route` 必须是 `remote`，
///    `sessionId` 非空且不超过 [RemoteNotificationLaunch.sessionIdMaxChars]，`kind` 必须是
///    协议 §8.2/§8.3 的两种取值之一，`tag` 可选但给了就必须是正常字符串。任何一项不合格
///    整条丢弃，不猜、不补默认值；
/// 2. [RemoteNotificationNavigation.consume] 在 App 启动与回前台时被调用：读一次 pending，
///    交给根页面导航；根页面还没挂载时保留，下一次调用重试。原生侧 take 后即清空，因此
///    重复调用不会重复导航；
/// 3. 读取通道缺席（桌面/测试壳没有原生实现）或返回损坏 JSON 时静默返回 null：深链是
///    可选增强，不能影响 App 启动。
///
/// ## 设备归属限制
///
/// 通知负载里没有来源设备标识（协议 §8.2/§8.3 不含 `deviceId`），多台已配对电脑时无法
/// 判断通知来自哪一台。本模块与远程首页保持一致：只连「上次成功连接」的那台（没有记录
/// 且恰好只有一台时连它），不为了猜测自动切换电脑。会话不在该电脑的列表里时落到远程
/// 首页并给出可见提示，见 `remote_dsh_page.dart` 的 pending 处理。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_notifications.dart';
import 'runtime.dart';

/// `dsh/runtime` 上取走 pending 远程通知深链的方法名。
const String remoteNotificationLaunchTakeMethod = 'notifications.launch.take';

/// 一次远程通知点击带来的待打开会话。
///
/// 字段来自平台层校验过的点击 Intent；[parse] 是唯一的构造入口，保证页面只拿到合法值。
class RemoteNotificationLaunch {
  /// 创建一条已校验的深链（只由 [parse] 调用）。
  const RemoteNotificationLaunch({
    required this.sessionId,
    required this.kind,
    this.tag,
  });

  /// 点击 Intent 里 `pocket.route` 的唯一合法取值。
  static const String route = 'remote';

  /// 会话标识的长度上限；与 Kotlin 侧 `MAX_SESSION_CHARS` 一致。
  static const int sessionIdMaxChars = 128;

  /// 协议 id（tag）的长度上限；与 Kotlin 侧 `MAX_ID_CHARS` 一致。
  static const int tagMaxChars = 128;

  /// 要打开的远程会话。
  final String sessionId;

  /// 通知种类：任务完成或审批待处理。
  final RemoteNotificationKind kind;

  /// 协议 id（任务 `taskId` / 审批 `interactionId`）；原生没有给出时为 null。
  ///
  /// 当前导航只按 [sessionId] 打开会话，tag 保留给排障与后续细粒度路由。
  final String? tag;

  /// 严格解析原生返回的一次点击记录；任何字段不合格都返回 null。
  ///
  /// 只接受 `{route: 'remote', sessionId: String, kind: 'taskCompleted'|'approvalPending',
  /// tag?: String}`。未知字段忽略（向前兼容），已知字段类型/取值错误则整条丢弃：
  /// 深链是用户可见的跳转，不能把半个解析结果交给页面。
  ///
  /// @param raw 原生通道返回的 JSON 解码结果，或测试直接给的对象。
  /// @returns 合法深链；否则为 null。
  static RemoteNotificationLaunch? parse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['route'] != route) return null;

    final rawSessionId = raw['sessionId'];
    if (rawSessionId is! String) return null;
    final sessionId = rawSessionId.trim();
    if (sessionId.isEmpty || sessionId.length > sessionIdMaxChars) return null;

    final kind = switch (raw['kind']) {
      'taskCompleted' => RemoteNotificationKind.taskCompleted,
      'approvalPending' => RemoteNotificationKind.approvalPending,
      _ => null,
    };
    if (kind == null) return null;

    final rawTag = raw['tag'];
    String? tag;
    if (rawTag != null) {
      if (rawTag is! String) return null;
      final trimmed = rawTag.trim();
      if (trimmed.isEmpty || trimmed.length > tagMaxChars) return null;
      tag = trimmed;
    }
    return RemoteNotificationLaunch(sessionId: sessionId, kind: kind, tag: tag);
  }
}

/// pending 远程通知深链的读取口。
///
/// 生产实现是 [MethodChannelRemoteNotificationLaunchSource]；测试用假实现直接给出
/// 解析后的结果。约定：**每次读取都会清空平台侧 pending**，连续调用只有第一次可能非空。
abstract class RemoteNotificationLaunchSource {
  /// 取走当前 pending 深链；没有 pending 或读取失败时返回 null，不抛异常。
  Future<RemoteNotificationLaunch?> take();
}

/// 走 `dsh/runtime` 的 `notifications.launch.take` 的读取口。
class MethodChannelRemoteNotificationLaunchSource
    implements RemoteNotificationLaunchSource {
  /// 创建读取口；[channel] 只给测试替换成隔离通道。
  const MethodChannelRemoteNotificationLaunchSource({
    this.channel = RuntimeController.channel,
  });

  /// 与本地/远程运行时共用的原生通道；方法实现见 `MainActivity.kt`。
  final MethodChannel channel;

  @override
  Future<RemoteNotificationLaunch?> take() async {
    final Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>(
        remoteNotificationLaunchTakeMethod,
      );
    } on MissingPluginException {
      // 没有原生实现的壳（桌面/单测）：没有深链，不是错误。
      return null;
    } on PlatformException catch (error) {
      debugPrint('读取远程通知深链失败：${error.code} ${error.message}');
      return null;
    }
    if (raw is! String || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      debugPrint('远程通知深链不是合法 JSON：${error.message}');
      return null;
    }
    return RemoteNotificationLaunch.parse(decoded);
  }
}

/// 消费 pending 深链并把导航交给根页面。
///
/// App 在启动（首帧之后）与每次回到前台时调用 [consume]：平台层在 App 存活时通过
/// `onNewIntent`、进程被杀时通过启动 Intent 记录 pending，两者都在这两个时机被取走。
class RemoteNotificationNavigation {
  /// 创建协调器；[open] 返回 false 表示页面还不能导航（例如根对话页尚未挂载），
  /// 深链会保留到下一次 [consume]。
  RemoteNotificationNavigation({required this.source, required this.open});

  /// pending 深链的来源。
  final RemoteNotificationLaunchSource source;

  /// 真正执行导航的回调；返回 true 表示已交付。
  final bool Function(RemoteNotificationLaunch launch) open;

  RemoteNotificationLaunch? _pending;
  bool _reading = false;

  /// 尚未交付给页面的深链；测试用它观察保留/清空时机。
  RemoteNotificationLaunch? get pending => _pending;

  /// 读取一次 pending 深链并尝试打开。
  ///
  /// - 原生 `take` 取后即清空，重复调用不会重复导航；
  /// - [open] 返回 false 时保留 pending，下次调用重试；
  /// - 读取/解析失败不抛给调用方：深链是可选增强，不能影响 App 启动。
  Future<void> consume() async {
    if (_reading) return;
    _reading = true;
    try {
      final taken = await source.take();
      if (taken != null) _pending = taken;
      final launch = _pending;
      if (launch != null && open(launch)) _pending = null;
    } catch (error) {
      // 通道/解析之外的意外失败不能冒泡到 App 生命周期回调。
      debugPrint('远程通知深链消费失败：$error');
    } finally {
      _reading = false;
    }
  }
}
