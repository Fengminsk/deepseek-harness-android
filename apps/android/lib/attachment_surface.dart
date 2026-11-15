// 附件草稿与宿主之间的替换点：调用面。
//
// 本地模式下调用面就是 `RuntimeController`（它已经实现本接口：`ready`、`phase`、
// `connectionGeneration`、`call` 与监听器成员齐备）；远程模式下由
// `remote_attachments.dart` 的 `RemoteAttachmentSurface` 提供走 `wss` 的实现。
// `AttachmentDrafts` 与 `PocketAttachmentRail` 只依赖这个接口，因此渲染、上传、
// 重试与移除逻辑本地/远程共用，页面不关心请求是走 MethodChannel 还是远程门面。

import 'package:flutter/foundation.dart';

/// 附件草稿调用宿主附件方法的唯一入口。
///
/// `attachments.prepare` / `attachments.preview` / `attachments.release` 的请求与
/// 响应形状在本地与远程完全一致（见 `docs/remote-dsh/p5-remaining-design.md`
/// §3.1、§3.4.2）。[call] 失败时抛异常，`message` 可以直接展示；本地实现抛
/// `PlatformException`，远程实现抛 `RemoteAttachmentFailure`，`AttachmentDrafts`
/// 只把失败文本交给 rail，因此不需要按模式分叉。
abstract interface class AttachmentCallSurface {
  /// 连接是否已就绪；未就绪时草稿不发起请求，只在 rail 上展示「待重试」。
  bool get ready;

  /// 当前连接阶段（本地是运行时 phase，远程是连接控制器的阶段名）。
  String get phase;

  /// 连接代际：每建立一次新连接递增，草稿据此把已上传的收据置为「需重试」。
  int get connectionGeneration;

  /// 调用一个宿主附件方法。
  ///
  /// @param method 门面方法名，例如 `attachments.prepare`。
  /// @param params 请求参数；调用方已经带上 `sessionId` 与草稿 `id`。
  /// @returns 宿主返回的 JSON 结果。
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]);

  /// 订阅连接状态变化。
  void addListener(VoidCallback listener);

  /// 取消订阅连接状态变化。
  void removeListener(VoidCallback listener);

  /// 释放调用面自身。
  ///
  /// 只摘掉它对连接的观察，不关闭连接、也不释放连接持有者（远程页与本地页面都
  /// 由外层管理连接生命周期）。
  void dispose();
}

/// 可选能力：`attachments.prepare` 需要携带草稿元数据。
///
/// 远程宿主没有设备侧缓存，只能靠 App 声明的 `name` / `mediaType` / `bytes`
/// 给上传收据命名并与实际拉取的字节数对账；本地运行时直接读设备缓存，因此
/// `RuntimeController` 不实现本接口，本地 `attachments.prepare` 的参数保持原样
/// （既有本地测试断言了精确参数）。
abstract interface class AttachmentMetadataSurface {}
