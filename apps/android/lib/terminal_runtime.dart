// 终端页与宿主之间的两个替换点：调用面与 Shell 来源。
//
// 本地模式下两者都由 Android 运行时实现（RuntimeController 与
// TerminalShellCatalog）；远程模式下由 `remote_terminal_page.dart` 提供走
// `wss` 的实现。终端页只依赖这两个接口，因此渲染、输入与轮询逻辑本地/远程共用，
// 页面不关心请求是走 MethodChannel 还是远程门面。

import 'package:flutter/foundation.dart';

/// 终端页调用宿主终端方法的唯一入口。
///
/// `terminal.*` 的请求/响应形状在本地与远程完全一致（见
/// `docs/remote-dsh/terminal-design.md` §2.2）。[call] 失败时抛
/// `PlatformException`：`code`、`message`、`details` 与本地门面逐字段一致，
/// 页面里既有的 `failure is PlatformException` 分支不需要按模式分叉。
abstract interface class TerminalCallSurface {
  /// 连接是否已就绪；未就绪时页面不发起请求，只展示「待确认」状态。
  bool get ready;

  /// 当前连接阶段（本地是运行时 phase，远程是连接控制器的阶段名）。
  String get phase;

  /// 连接代际：每建立一次新连接递增，页面据此丢弃旧连接上的迟到结果。
  int get connectionGeneration;

  /// 调用一个宿主终端方法。
  ///
  /// @param method 门面方法名，例如 `terminal.list`。
  /// @param params 请求参数；页面已经带上 `sessionId`。
  /// @returns 宿主返回的 JSON 结果。
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]);

  /// 订阅连接状态变化。
  void addListener(VoidCallback listener);

  /// 取消订阅连接状态变化。
  void removeListener(VoidCallback listener);
}

/// 一个可启动的 Shell 选项。
///
/// `id` 由宿主解释：本地是固定的 Android shell 标识，远程是那台电脑上的 shell
/// 路径；`label` 只用于选择器展示。
@immutable
class TerminalShellOption {
  /// 创建 Shell 选项。
  const TerminalShellOption({required this.id, required this.label});

  /// 宿主识别的 Shell 标识。
  final String id;

  /// 选择器里的显示名。
  final String label;

  @override
  bool operator ==(Object other) =>
      other is TerminalShellOption && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'TerminalShellOption($id, $label)';
}

/// Shell 发现与偏好记忆。
///
/// 「已安装的 Shell」来自宿主；「上次选择」是 App 侧偏好：本地存在
/// MethodChannel 偏好里，远程只存在本次页面内存中（跨电脑持久化延期）。
abstract interface class TerminalShellSource {
  /// 读取当前可用的 Shell 列表；失败时抛异常，页面展示重试入口。
  ///
  /// @returns 宿主声明的 Shell 选项，顺序即展示顺序。
  Future<List<TerminalShellOption>> discover();

  /// 默认选中的 Shell：有偏好时取偏好，否则取列表首项；列表为空时返回 null。
  ///
  /// @returns 默认 Shell 选项；没有可用 Shell 时为 null。
  Future<TerminalShellOption?> preferred();

  /// 记住用户选择的 Shell；失败时抛异常，页面提示保存失败。
  ///
  /// @param shell 用户选中的 Shell 选项。
  Future<void> remember(TerminalShellOption shell);
}
