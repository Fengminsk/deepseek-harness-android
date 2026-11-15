// 远程终端页：在手机上操作那台电脑上的终端。
//
// 页面不重写终端渲染与输入：能力就绪后直接复用本地的 SessionTerminalsPage /
// SessionTerminalView，只把两处宿主依赖换成远程实现——
// [RemoteTerminalRuntime]（走 `wss` 上的 `terminal.*` 请求/响应）与
// [RemoteTerminalShellSource]（`terminal.shells`）。请求/响应形状与本地 Android
// 完全一致（docs/remote-dsh/terminal-design.md §2.2），错误信封按 §2.3 翻译成
// 页面既有的提示分支。
//
// 入口在远程会话页的「…」菜单；打开走 openDestination 并使用
// [RemoteSessionTerminalPage.routeDestination] 作为稳定目的地标识，同一目的地不会
// 在栈上叠第二层。

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'remote_connection.dart';
import 'runtime_transport.dart';
import 'session_terminal.dart';
import 'terminal_runtime.dart';
import 'ui.dart';

/// 远程终端页所需的连接面：阶段、方法表、终止态原因与传输入口。
///
/// 生产实现是 [RemoteControllerTerminalConnection]（包一层
/// [RemoteConnectionController]）；测试可以直接实现本接口，不需要真实 TLS 连接
/// 或设备表。
abstract interface class RemoteTerminalConnection implements Listenable {
  /// 当前连接阶段。
  RemoteConnectionPhase get phase;

  /// 终止态的失败原因；没有失败时为 null。
  String? get lastError;

  /// 宿主是否支持某个门面方法（协议 §10.1、§10.2）。
  bool supports(String method);

  /// 传输入口；未连接或终止态之后为 null。
  RuntimeTransport? get transport;
}

/// 把 [RemoteConnectionController] 的公开面转成 [RemoteTerminalConnection]。
///
/// 连接生命周期仍由远程首页持有，本类只读阶段、方法表与传输。
class RemoteControllerTerminalConnection implements RemoteTerminalConnection {
  /// 绑定连接控制器。
  const RemoteControllerTerminalConnection(this.controller);

  /// 被读取的远程连接控制器。
  final RemoteConnectionController controller;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  RemoteConnectionPhase get phase => controller.phase;

  @override
  String? get lastError => controller.lastError;

  @override
  bool supports(String method) => controller.supports(method);

  @override
  RuntimeTransport? get transport => controller.transport;
}

/// 终端入口与页内的能力三态（协议 §10.2）。
///
/// 「还没连上」和「这台电脑明确不支持」必须分开：前者等连接就绪后可能变可用，
/// 后者只能置灰并说明原因，不能给一个点了没反应的入口。
enum RemoteTerminalCapability {
  /// 连接就绪且方法表里具备全部终端方法。
  available,

  /// 连接就绪但方法表缺少终端方法（或 `unsupported` 覆盖了它们）。
  unsupported,

  /// 尚未就绪：未握手、重连中或已断开，能力暂时无法判定。
  pending;

  /// 判定终端入口可用所要求的方法。
  ///
  /// 取设计 §4.3 的最弱一环：全部存在才算可用；`terminal.rename` /
  /// `terminal.shells` 只影响页内个别操作，不作为入口门槛。
  static const List<String> requiredMethods = <String>[
    'terminal.list',
    'terminal.create',
    'terminal.read',
    'terminal.write',
    'terminal.resize',
    'terminal.close',
  ];

  /// 由连接面判定当前三态。
  ///
  /// @param connection 那台电脑的连接面。
  /// @returns 入口与页内应展示的能力状态。
  static RemoteTerminalCapability of(RemoteTerminalConnection connection) {
    if (connection.phase != RemoteConnectionPhase.ready ||
        connection.transport == null) {
      return pending;
    }
    for (final method in requiredMethods) {
      if (!connection.supports(method)) return unsupported;
    }
    return available;
  }

  /// 由连接控制器判定当前三态（入口页最常用的形态）。
  ///
  /// @param controller 远程连接控制器。
  /// @returns 入口与页内应展示的能力状态。
  static RemoteTerminalCapability ofController(
    RemoteConnectionController controller,
  ) => of(RemoteControllerTerminalConnection(controller));

  /// 置灰时展示的中文原因；可用时为 null。
  String? get reason => switch (this) {
    available => null,
    pending => '正在连接电脑…',
    unsupported => '这台电脑不支持终端',
  };
}

/// 远程终端调用面：把终端页的 `terminal.*` 请求转成那台电脑上的门面调用。
///
/// [call] 在页面给出的参数上补 `sessionId`（设计 §2.2），并把传输层失败统一抛成
/// `PlatformException`：`code` / `message` / `details` 与本地终端门面一致，页面里
/// 既有的失败分支不需要区分本地与远程。
class RemoteTerminalRuntime extends ChangeNotifier
    implements TerminalCallSurface {
  /// 绑定连接与终端归属的会话。
  ///
  /// @param connection 那台电脑的连接面；生命周期由调用方持有。
  /// @param sessionId 终端归属的会话标识，作为每次请求的 `sessionId`。
  RemoteTerminalRuntime({required this.connection, required this.sessionId}) {
    _transport = connection.transport;
    _ready =
        connection.phase == RemoteConnectionPhase.ready && _transport != null;
    connection.addListener(_connectionChanged);
  }

  /// 那台电脑的连接面。
  final RemoteTerminalConnection connection;

  /// 终端归属的会话标识。
  final String sessionId;

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
  /// 每次「重新握手成功」或换了一条传输对象时递增：断线重连后页面据此丢弃旧连接
  /// 上的迟到结果并重新读取终端（设计 §4.4）。未就绪期间保持原值，页面自身的
  /// phase/ready 监听负责把终端置为「待确认」。
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
      throw PlatformException(
        code: 'gateway/cancelled',
        message: '尚未连接到电脑，无法操作终端。',
      );
    }
    final dynamic result;
    try {
      result = await transport.request(method, <String, dynamic>{
        'sessionId': sessionId,
        ...params,
      });
    } on RuntimeTransportFailure catch (failure) {
      throw PlatformException(
        code: failure.code,
        message: failure.message,
        details: failure.details,
      );
    }
    // 传输实现通常已经把 `_pocket_error` 解成失败；这里再兜一层，保证测试替身或
    // 未来传输实现把信封原样返回时，终端页仍走既有的错误分支。
    if (result is Map<String, dynamic> && result['_pocket_error'] is Map) {
      final envelope = result['_pocket_error'] as Map;
      throw PlatformException(
        code: envelope['code'] is String
            ? envelope['code'] as String
            : 'gateway/internal',
        message: envelope['message'] is String
            ? envelope['message'] as String
            : '终端操作失败。',
        details: envelope,
      );
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
}

/// 远程 Shell 来源：`terminal.shells {sessionId}` → `[{id, label}]`（设计 §2.2）。
///
/// `id` 是那台电脑上的 shell 路径（宿主适配器在 `terminal.create` 时把它当
/// `shellPath` 用）。偏好只存在本页内存里：跨电脑持久化延期（设计 §4.2）。
class RemoteTerminalShellSource implements TerminalShellSource {
  /// 绑定终端调用面。
  ///
  /// @param runtime 已带 `sessionId` 的远程终端调用面。
  RemoteTerminalShellSource(this.runtime);

  /// 发包用的远程终端调用面。
  final RemoteTerminalRuntime runtime;

  TerminalShellOption? _remembered;

  @override
  Future<List<TerminalShellOption>> discover() async {
    final reply = await runtime.call('terminal.shells');
    if (reply is! List) {
      throw const FormatException('Invalid terminal shell list');
    }
    final shells = <TerminalShellOption>[];
    for (final row in reply) {
      if (row is! Map) throw const FormatException('Invalid terminal shell');
      final id = row['id'], label = row['label'];
      if (id is! String || id.isEmpty || label is! String || label.isEmpty) {
        throw const FormatException('Invalid terminal shell');
      }
      final shell = TerminalShellOption(id: id, label: label);
      if (shells.contains(shell)) {
        throw const FormatException('Invalid terminal shell');
      }
      shells.add(shell);
    }
    return List<TerminalShellOption>.unmodifiable(shells);
  }

  @override
  Future<TerminalShellOption?> preferred() async {
    final remembered = _remembered;
    if (remembered != null) return remembered;
    final shells = await discover();
    return shells.isEmpty ? null : shells.first;
  }

  @override
  Future<void> remember(TerminalShellOption shell) async {
    _remembered = shell;
  }
}

/// 远程会话的终端页。
///
/// 入口在远程会话页的「…」菜单；打开走 [openDestination]，同一目的地不会叠第二层：
/// ```dart
/// await openDestination<void>(
///   context,
///   destination: RemoteSessionTerminalPage.routeDestination,
///   builder: (_) => RemoteSessionTerminalPage(
///     connection: RemoteControllerTerminalConnection(controller),
///     sessionId: sessionId,
///   ),
/// );
/// ```
/// 连接就绪且那台电脑声明了终端方法后，本页直接挂载本地终端页
/// [SessionTerminalsPage]；未就绪或电脑不支持时给出可读原因，而不是一个点了没
/// 反应的空白页（设计 §4.3）。
class RemoteSessionTerminalPage extends StatefulWidget {
  /// 创建远程终端页。
  const RemoteSessionTerminalPage({
    super.key,
    required this.connection,
    required this.sessionId,
  });

  /// 本页作为全屏目的地的稳定标识（见 [openDestination]）。
  static const String routeDestination = 'remote-session-terminal';

  /// 那台电脑的连接面。
  final RemoteTerminalConnection connection;

  /// 终端归属的会话标识（`terminal.*` 的 `sessionId`）。
  final String sessionId;

  @override
  State<RemoteSessionTerminalPage> createState() =>
      _RemoteSessionTerminalPageState();
}

class _RemoteSessionTerminalPageState extends State<RemoteSessionTerminalPage> {
  late RemoteTerminalRuntime _runtime;
  late RemoteTerminalShellSource _shellSource;

  /// 一旦连接就绪且电脑支持终端，就保持终端页挂载。
  ///
  /// 断线重连由终端页自己的 generation/phase 监听处理（清屏、待确认、重读），
  /// 不退回「正在连接」占位页，否则用户会在重连时丢掉当前视图。
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _createRuntime();
  }

  void _createRuntime() {
    _entered =
        RemoteTerminalCapability.of(widget.connection) ==
        RemoteTerminalCapability.available;
    _runtime = RemoteTerminalRuntime(
      connection: widget.connection,
      sessionId: widget.sessionId,
    );
    _shellSource = RemoteTerminalShellSource(_runtime);
    _runtime.addListener(_runtimeChanged);
  }

  void _runtimeChanged() {
    if (!mounted) return;
    setState(() {
      if (!_entered &&
          RemoteTerminalCapability.of(widget.connection) ==
              RemoteTerminalCapability.available) {
        _entered = true;
      }
    });
  }

  @override
  void didUpdateWidget(RemoteSessionTerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.connection, widget.connection) &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    _runtime.removeListener(_runtimeChanged);
    _runtime.dispose();
    _createRuntime();
  }

  @override
  void dispose() {
    _runtime.removeListener(_runtimeChanged);
    _runtime.dispose();
    super.dispose();
  }

  /// 未就绪时的说明：连接失败要给出原因，正在连接要给一句等待说明。
  String _pendingMessage() {
    final phase = widget.connection.phase;
    final error = widget.connection.lastError;
    if (phase == RemoteConnectionPhase.failed ||
        phase == RemoteConnectionPhase.lost ||
        phase == RemoteConnectionPhase.idle) {
      return error == null || error.isEmpty
          ? '与电脑的连接已断开，请返回远程首页重新连接。'
          : '与电脑的连接已断开：$error';
    }
    return '正在连接电脑，连上后会自动打开终端列表。';
  }

  @override
  Widget build(BuildContext context) {
    if (_entered) {
      return SessionTerminalsPage(
        runtime: _runtime,
        sessionId: widget.sessionId,
        shellSource: _shellSource,
      );
    }
    final capability = RemoteTerminalCapability.of(widget.connection);
    return PocketScaffold(
      title: const Text('终端'),
      body: PocketEmpty(
        child: _RemoteTerminalNotice(
          icon: capability == RemoteTerminalCapability.pending
              ? Icons.hourglass_top_rounded
              : Icons.terminal_rounded,
          title: capability == RemoteTerminalCapability.pending
              ? '正在连接电脑'
              : '这台电脑不支持终端',
          message: capability == RemoteTerminalCapability.pending
              ? _pendingMessage()
              : '电脑上的 DSH 没有启用终端功能（门面未声明 terminal.* 方法）。'
                    '请在那台电脑上确认终端服务已启用，或升级后重新连接。',
        ),
      ),
    );
  }
}

/// 未就绪/不支持时居中的提示：图标、标题与说明。
class _RemoteTerminalNotice extends StatelessWidget {
  const _RemoteTerminalNotice({
    required this.icon,
    required this.title,
    required this.message,
  });

  /// 顶部图标。
  final IconData icon;

  /// 提示标题。
  final String title;

  /// 一段说明，不写营销语。
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: colors.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyle.title3.of(context, emphasized: true),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
