import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';
import 'terminal_runtime.dart';
import 'terminal_screen.dart';
import 'ui.dart';

/// 把宿主终端失败信封（`_pocket_error`）翻译成页面文案。
///
/// 错误码与处理方式见 `docs/remote-dsh/terminal-design.md` §2.3。本地 Android 宿主
/// 目前只给出通用失败（`gateway/internal`），本地页面因此仍走各自的兜底文案；远程
/// 宿主会给出带归因的码，命中时用这里的说明替换「送达状态未知」这类保守提示。
///
/// @param failure 页面捕获到的异常。
/// @returns 可展示的中文说明；不是已归因的终端失败时为 null。
String? terminalFailureMessage(Object failure) {
  if (failure is! PlatformException) return null;
  Map? envelope;
  final details = failure.details;
  if (details is Map) {
    final nested = details['details'];
    envelope = nested is Map ? nested : details;
  }
  switch (failure.code) {
    case 'terminal/unavailable':
      return '终端已不存在，请返回终端列表刷新。';
    case 'terminal/control-unavailable':
      return switch (envelope?['reason']) {
        'read-only' => '终端当前只读（输入由另一条连接持有），输入未发送。',
        'not-running' => '终端进程已结束，输入未发送。',
        _ => '终端当前不能接收输入，输入未发送。',
      };
    case 'terminal/limit-reached':
      final limit = envelope?['limit'];
      return limit is int ? '这台电脑最多同时保留 $limit 个终端。' : '已达到每会话终端数量上限。';
    default:
      return null;
  }
}

/// The on-screen and hardware arrows must use the same mode selected by the PTY.
String terminalArrowInput(
  String direction, {
  required bool applicationCursorKeys,
}) {
  final code = switch (direction) {
    '↑' => 'A',
    '↓' => 'B',
    '→' => 'C',
    '←' => 'D',
    _ => throw ArgumentError.value(direction, 'direction'),
  };
  return '\u001b${applicationCursorKeys ? 'O' : '['}$code';
}

/// Draft text is a paste operation; Return is sent after the paste delimiter.
String terminalDraftInput(
  String draft, {
  required bool enter,
  required bool bracketedPaste,
}) {
  final text = draft.isEmpty || !bracketedPaste
      ? draft
      : '\u001b[200~$draft\u001b[201~';
  return enter ? '$text\r' : text;
}

/// SGR mouse reports use one-based grid coordinates and require DECSET 1006.
/// Older X10/UTF-8/urxvt encodings are deliberately not guessed.
String? terminalSgrMouseInput({
  required String tracking,
  required bool sgrMouse,
  required String action,
  required int button,
  required int col,
  required int row,
  required int cols,
  required int rows,
}) {
  if (!sgrMouse || tracking == 'off' ||
      !const ['click', 'drag', 'any'].contains(tracking) ||
      col < 1 || col > cols || row < 1 || row > rows) {
    return null;
  }
  final code = switch (action) {
    'down' || 'up' when button >= 0 && button <= 2 => button,
    'move' when tracking == 'any' && button == 3 => 35,
    'move' when tracking != 'click' && button >= 0 && button <= 2 => button + 32,
    'wheelUp' => 64,
    'wheelDown' => 65,
    _ => null,
  };
  if (code == null) return null;
  return '\u001b[<$code;$col;$row${action == 'up' ? 'm' : 'M'}';
}

/// Session-scoped PTYs owned by the Android Host. Leaving this page detaches
/// the viewport; it does not close a running shell.
///
/// 宿主依赖只有两个接口：[runtime] 是终端调用面（本地是 [RuntimeController]，
/// 远程是 `RemoteTerminalRuntime`），[shellSource] 提供 Shell 发现与偏好。
class SessionTerminalsPage extends StatefulWidget {
  const SessionTerminalsPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.shellSource,
  });

  final TerminalCallSurface runtime;
  final String sessionId;
  final TerminalShellSource shellSource;

  @override
  State<SessionTerminalsPage> createState() => _SessionTerminalsPageState();
}

class _SessionTerminalsPageState extends State<SessionTerminalsPage> {
  List<Json> terminals = const [];
  bool loading = false;
  String? error;
  int generation = 0;
  late int connection;
  late String phase;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(_runtimeChanged);
    unawaited(refresh());
  }

  @override
  void didUpdateWidget(SessionTerminalsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    oldWidget.runtime.removeListener(_runtimeChanged);
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(_runtimeChanged);
    terminals = const [];
    unawaited(refresh());
  }

  void _runtimeChanged() {
    if (!mounted) return;
    final changed =
        connection != widget.runtime.connectionGeneration ||
        phase != widget.runtime.phase;
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    if (changed) {
      terminals = const [];
      unawaited(refresh());
    } else {
      setState(() {});
    }
  }

  Future<void> refresh() async {
    final epoch = ++generation;
    if (!widget.runtime.ready) {
      if (mounted) {
        setState(() {
          terminals = const [];
          loading = false;
          error = '服务未连接，终端状态待确认。';
        });
      }
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await widget.runtime
          .call('terminal.list', {'sessionId': widget.sessionId})
          .timeout(const Duration(seconds: 8));
      if (!mounted || epoch != generation) return;
      if (value is! List) throw const FormatException('Invalid terminal list');
      setState(() {
        terminals = value.cast<Json>();
        loading = false;
      });
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(() {
          loading = false;
          error = '无法读取终端状态，请重试。';
        });
      }
    }
  }

  Future<void> create({TerminalShellOption? shell}) async {
    if (loading || !widget.runtime.ready) return;
    final runtime = widget.runtime;
    final sessionId = widget.sessionId;
    final connectionAtStart = runtime.connectionGeneration;
    final id = 'mobile-${DateTime.now().microsecondsSinceEpoch}';
    final cols = ((MediaQuery.sizeOf(context).width - 44) / 8.4).floor().clamp(
      20,
      160,
    );
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final preferred = shell ?? await widget.shellSource.preferred();
      final available = await widget.shellSource.discover();
      if (!mounted ||
          !identical(widget.runtime, runtime) ||
          widget.sessionId != sessionId ||
          runtime.connectionGeneration != connectionAtStart) {
        return;
      }
      if (preferred == null || !available.contains(preferred)) {
        throw const _ShellUnavailable();
      }
      await runtime
          .call('terminal.create', {
            'sessionId': sessionId,
            'id': id,
            'cols': cols,
            'rows': 24,
            'shellId': preferred.id,
          })
          .timeout(const Duration(seconds: 12));
      if (!mounted ||
          !identical(widget.runtime, runtime) ||
          widget.sessionId != sessionId ||
          runtime.connectionGeneration != connectionAtStart) {
        return;
      }
      await Navigator.of(context).push<void>(
        PocketRoute<void>(
          builder: (_) => SessionTerminalView(
            runtime: runtime,
            sessionId: sessionId,
            id: id,
          ),
        ),
      );
      if (mounted) unawaited(refresh());
    } catch (failure) {
      if (mounted) {
        setState(() {
          loading = false;
          error = failure is _ShellUnavailable
              ? '已选 Shell 暂不可用，请从右上角重新选择。'
              : terminalFailureMessage(failure) ??
                    '无法启动终端。请检查 Shell、会话工作目录与运行环境。';
        });
      }
    }
  }

  Future<void> selectShell() async {
    if (loading || !widget.runtime.ready) return;
    final runtime = widget.runtime;
    final sessionId = widget.sessionId;
    final connectionAtOpen = runtime.connectionGeneration;
    TerminalShellOption preferred;
    try {
      final found = await widget.shellSource.preferred();
      if (found == null) {
        if (mounted) setState(() => error = '没有可用的 Shell。');
        return;
      }
      preferred = found;
    } catch (_) {
      if (mounted) setState(() => error = '无法读取 Shell 选择，请重试。');
      return;
    }
    if (!mounted ||
        !identical(widget.runtime, runtime) ||
        widget.sessionId != sessionId ||
        connectionAtOpen != runtime.connectionGeneration) {
      return;
    }
    final selected = await Navigator.of(context).push<TerminalShellOption>(
      PocketRoute<TerminalShellOption>(
        builder: (_) => _TerminalShellPickerPage(
          shellSource: widget.shellSource,
          preferred: preferred,
        ),
      ),
    );
    if (!mounted ||
        selected == null ||
        !identical(widget.runtime, runtime) ||
        widget.sessionId != sessionId ||
        connectionAtOpen != runtime.connectionGeneration) {
      return;
    }
    try {
      final available = await widget.shellSource.discover();
      if (!available.contains(selected)) throw const _ShellUnavailable();
      if (!mounted ||
          !identical(widget.runtime, runtime) ||
          widget.sessionId != sessionId ||
          connectionAtOpen != runtime.connectionGeneration) {
        return;
      }
      await widget.shellSource.remember(selected);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is _ShellUnavailable
              ? '所选 Shell 已不可用，请重新选择。'
              : '无法保存 Shell 选择，请重试。',
        );
      }
      return;
    }
    if (mounted && connectionAtOpen == runtime.connectionGeneration) {
      await create(shell: selected);
    }
  }

  Future<void> rename(Json terminal) async {
    final id = terminal['id'];
    if (id is! String || loading || !widget.runtime.ready) return;
    final connectionAtOpen = widget.runtime.connectionGeneration;
    final name = await Navigator.of(context).push<String>(
      PocketRoute<String>(
        builder: (_) => _TerminalNamePage(
          initialName: terminal['name'] is String
              ? terminal['name'] as String
              : '终端',
        ),
      ),
    );
    if (!mounted ||
        name == null ||
        connectionAtOpen != widget.runtime.connectionGeneration ||
        !widget.runtime.ready ||
        !terminals.any((entry) => entry['id'] == id)) {
      return;
    }
    try {
      await widget.runtime
          .call('terminal.rename', {
            'sessionId': widget.sessionId,
            'id': id,
            'name': name,
          })
          .timeout(const Duration(seconds: 7));
      if (mounted && connectionAtOpen == widget.runtime.connectionGeneration) {
        unawaited(refresh());
      }
    } catch (failure) {
      if (mounted && connectionAtOpen == widget.runtime.connectionGeneration) {
        setState(
          () => error =
              terminalFailureMessage(failure) ?? '无法更改终端名称，请重试。',
        );
      }
    }
  }

  @override
  void dispose() {
    generation++;
    widget.runtime.removeListener(_runtimeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('终端'),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassButton(
          icon: Icons.add_rounded,
          label: '新建终端',
          onPressed: loading || !widget.runtime.ready
              ? null
              : () => unawaited(create()),
        ),
        const SizedBox(width: 8),
        GlassButton(
          icon: Icons.expand_more_rounded,
          label: '选择 Shell',
          onPressed: loading || !widget.runtime.ready ? null : selectShell,
        ),
      ],
    ),
    body: PocketList(
      children: [
        if (error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
        if (loading && terminals.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('正在读取终端…')),
        if (!loading && terminals.isEmpty && error == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('还没有终端。点右上角新建。'),
          ),
        if (terminals.isNotEmpty)
          PocketSection(
            children: [
              for (final terminal in terminals)
                PocketRow(
                  key: ValueKey('terminal-${terminal['id']}'),
                  icon: Icons.terminal_rounded,
                  title: terminal['name'] is String
                      ? terminal['name'] as String
                      : '终端',
                  subtitle: terminal['state'] == 'running'
                      ? '${terminal['cwd'] is String ? (terminal['cwd'] as String).split('/').last : '会话'} · 运行中'
                      : '已结束 · ${terminal['exitCode'] ?? '状态未知'}',
                  trailing: GlassButton(
                    icon: Icons.drive_file_rename_outline_rounded,
                    label: '重命名终端',
                    onPressed: loading || !widget.runtime.ready
                        ? null
                        : () => rename(terminal),
                  ),
                  onTap: () async {
                    final id = terminal['id'];
                    if (id is! String) return;
                    await Navigator.of(context).push<void>(
                      PocketRoute<void>(
                        builder: (_) => SessionTerminalView(
                          runtime: widget.runtime,
                          sessionId: widget.sessionId,
                          id: id,
                        ),
                      ),
                    );
                    if (mounted) unawaited(refresh());
                  },
                ),
            ],
          ),
      ],
    ),
  );
}

class _ShellUnavailable implements Exception {
  const _ShellUnavailable();
}

/// Discovery happens on entry and does not start a terminal process.
class _TerminalShellPickerPage extends StatefulWidget {
  const _TerminalShellPickerPage({
    required this.shellSource,
    required this.preferred,
  });
  final TerminalShellSource shellSource;
  final TerminalShellOption preferred;

  @override
  State<_TerminalShellPickerPage> createState() =>
      _TerminalShellPickerPageState();
}

class _TerminalShellPickerPageState extends State<_TerminalShellPickerPage> {
  List<TerminalShellOption> shells = const [];
  bool loading = false;
  String? error;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  Future<void> reload() async {
    if (loading) return;
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final found = await widget.shellSource.discover();
      if (!mounted || request != generation) return;
      setState(() {
        shells = found;
        loading = false;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          shells = const [];
          loading = false;
          error = '无法读取已安装的 Shell。';
        });
      }
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('选择 Shell'),
    body: PocketList(
      children: [
        if (loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('正在查找可用的 Shell…'),
          ),
        if (error != null || !loading && shells.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(error ?? '没有可用的 Shell。'),
                const SizedBox(height: 12),
                PocketButton.tonal(
                  onPressed: loading ? null : reload,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        if (shells.isNotEmpty)
          PocketSection(
            children: [
              for (final shell in shells)
                PocketRow(
                  icon: Icons.terminal_rounded,
                  title: shell.label,
                  trailing: shell == widget.preferred
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.of(context).pop(shell),
                ),
            ],
          ),
      ],
    ),
  );
}

class _TerminalNamePage extends StatefulWidget {
  const _TerminalNamePage({required this.initialName});
  final String initialName;

  @override
  State<_TerminalNamePage> createState() => _TerminalNamePageState();
}

class _TerminalNamePageState extends State<_TerminalNamePage> {
  late final controller = TextEditingController(text: widget.initialName);
  String? nameError;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void save() {
    final name = controller.text.trim();
    if (name.isEmpty ||
        name.characters.length > 64 ||
        RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(name)) {
      setState(() => nameError = '请输入不超过 64 个字符的名称。');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('终端名称'),
    trailing: GlassButton(
      icon: Icons.check_rounded,
      label: '保存名称',
      onPressed: save,
    ),
    body: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 64,
              onChanged: (_) {
                if (nameError != null) setState(() => nameError = null);
              },
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => save(),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              decoration: InputDecoration(
                hintText: '终端名称',
                errorText: nameError,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class SessionTerminalView extends StatefulWidget {
  const SessionTerminalView({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.id,
  });

  final TerminalCallSurface runtime;
  final String sessionId, id;

  @override
  State<SessionTerminalView> createState() => _SessionTerminalViewState();
}

class _SessionTerminalViewState extends State<SessionTerminalView>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  late final FocusNode inputFocus = FocusNode(onKeyEvent: _handleInputKey);
  final outputScroll = ScrollController();
  final Queue<String> pendingKeys = Queue<String>();
  final Map<int, int> activeMouseButtons = {};
  final Map<int, (int, int)> lastMouseCells = {};
  String? acknowledgedDraft;
  Timer? polling, resizeTimer, cursorTimer;
  bool reading = false, sending = false, closing = false, resizing = false;
  bool visible = true;
  /// 光标闪烁相位。用 [ValueNotifier] 而不是 state 字段：只有光标所在行依赖它，
  /// 每次闪烁都 setState 会让整页（含所有终端行）重建，是终端输出的主要构建成本之一。
  final ValueNotifier<bool> cursorPhase = ValueNotifier<bool>(true);
  bool interactiveInput = true, inputDeliveryUncertain = false;
  bool enterAfterInput = false;
  String display = '', state = 'starting';
  String terminalName = '终端';
  TerminalScreenData? screenView;
  String? error, operationError;
  int revision = -1, epoch = 0, sendSequence = 0;
  late int connection;
  ({int cols, int rows})? pendingSize, attemptedSize;

  String get copyableDisplay => screenView == null
      ? display
      : screenView!.lines
            .map((line) => line.runs.map((run) => run.text).join())
            .join('\n');

  bool _mouseDevice(PointerEvent event) =>
      event.kind == PointerDeviceKind.mouse ||
      event.kind == PointerDeviceKind.stylus;

  int? _mouseButton(int buttons) {
    if (buttons & 1 != 0) return 0;
    if (buttons & 4 != 0) return 1;
    if (buttons & 2 != 0) return 2;
    return null;
  }

  void _reportMouse(PointerEvent event, int line, double cellWidth,
      double lineHeight, String action, int button) {
    final view = screenView;
    if (view == null || state != 'running' || !_mouseDevice(event) ||
        (interactiveInput && input.text.isNotEmpty)) {
      return;
    }
    final firstVisibleLine = view.lines.length - view.rows;
    if (line < firstVisibleLine) return;
    final col = (event.localPosition.dx / cellWidth).floor() + 1;
    final row = line - firstVisibleLine +
        (event.localPosition.dy / lineHeight).floor() + 1;
    final boundedCol = col.clamp(1, view.cols);
    final boundedRow = row.clamp(1, view.rows);
    final cell = (boundedCol, boundedRow);
    if (action == 'move' && lastMouseCells[event.pointer] == cell) return;
    final report = terminalSgrMouseInput(
      tracking: view.mouseTracking,
      sgrMouse: view.sgrMouse,
      action: action,
      button: button,
      col: boundedCol,
      row: boundedRow,
      cols: view.cols,
      rows: view.rows,
    );
    if (report == null) return;
    lastMouseCells[event.pointer] = cell;
    unawaited(send(report));
  }

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    WidgetsBinding.instance.addObserver(this);
    input.addListener(_draftChanged);
    widget.runtime.addListener(_runtimeChanged);
    polling = Timer.periodic(
      const Duration(milliseconds: 450),
      (_) => unawaited(read()),
    );
    cursorTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted ||
          !visible ||
          state != 'running' ||
          screenView?.cursorVisible != true ||
          screenView?.cursorBlink != true) {
        return;
      }
      // 只通知依赖光标相位的行，不触发整页重建。
      cursorPhase.value = !cursorPhase.value;
    });
    unawaited(read());
  }

  void _draftChanged() {
    final sent = acknowledgedDraft;
    if (sent != null && !input.value.composing.isValid) {
      acknowledgedDraft = null;
      _removeAcknowledgedDraft(sent);
    }
    if (mounted) setState(() {});
    _pumpInteractiveInput();
  }

  void _pumpInteractiveInput() {
    if (!mounted ||
        !interactiveInput ||
        inputDeliveryUncertain ||
        sending ||
        input.value.composing.isValid ||
        state != 'running' ||
        !widget.runtime.ready) {
      return;
    }
    if (input.text.isNotEmpty) {
      unawaited(send(input.text, clear: true));
    } else if (enterAfterInput) {
      enterAfterInput = false;
      unawaited(send('\r'));
    }
  }

  void _submitInput() {
    if (!interactiveInput) {
      unawaited(sendDraft(enter: true));
      return;
    }
    if (input.value.composing.isValid) {
      setState(() => operationError = '请先确认正在输入的文字，再发送回车。');
      return;
    }
    if (inputDeliveryUncertain) {
      unawaited(sendDraft(enter: true));
      return;
    }
    enterAfterInput = true;
    _pumpInteractiveInput();
  }

  void _sendControlKey(String bytes) {
    if (interactiveInput && input.text.isNotEmpty) {
      setState(() => operationError = '请等当前输入送达后再发送控制键。');
      return;
    }
    unawaited(send(bytes));
  }

  void _removeAcknowledgedDraft(String sent) {
    if (!input.text.startsWith(sent)) {
      if (interactiveInput) inputDeliveryUncertain = true;
      setState(() => operationError = '已发送的输入被修改，请检查草稿，避免重复发送。');
      return;
    }
    final selection = input.selection;
    input.value = TextEditingValue(
      text: input.text.substring(sent.length),
      selection: TextSelection.collapsed(
        offset: selection.isValid
            ? (selection.extentOffset - sent.length).clamp(
                0,
                input.text.length - sent.length,
              )
            : input.text.length - sent.length,
      ),
    );
  }

  KeyEventResult _handleInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!mounted ||
        !visible ||
        state != 'running' ||
        !widget.runtime.ready ||
        input.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    String? bytes;
    if (keyboard.isControlPressed) {
      bytes = switch (key) {
        LogicalKeyboardKey.keyC => '\u0003',
        LogicalKeyboardKey.keyD => '\u0004',
        LogicalKeyboardKey.keyZ => '\u001a',
        _ => null,
      };
    } else {
      bytes = switch (key) {
        LogicalKeyboardKey.escape => '\u001b',
        LogicalKeyboardKey.tab => keyboard.isShiftPressed ? '\u001b[Z' : '\t',
        LogicalKeyboardKey.arrowUp when input.text.isEmpty =>
          terminalArrowInput(
            '↑',
            applicationCursorKeys: screenView?.applicationCursorKeys == true,
          ),
        LogicalKeyboardKey.arrowDown when input.text.isEmpty =>
          terminalArrowInput(
            '↓',
            applicationCursorKeys: screenView?.applicationCursorKeys == true,
          ),
        LogicalKeyboardKey.arrowLeft when input.text.isEmpty =>
          terminalArrowInput(
            '←',
            applicationCursorKeys: screenView?.applicationCursorKeys == true,
          ),
        LogicalKeyboardKey.arrowRight when input.text.isEmpty =>
          terminalArrowInput(
            '→',
            applicationCursorKeys: screenView?.applicationCursorKeys == true,
          ),
        LogicalKeyboardKey.backspace when input.text.isEmpty => '\u007f',
        _ => null,
      };
    }
    if (bytes == null) return KeyEventResult.ignored;
    _sendControlKey(bytes);
    return KeyEventResult.handled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState next) {
    visible = next == AppLifecycleState.resumed;
    if (visible) {
      cursorPhase.value = true;
      unawaited(read());
    }
  }

  void _runtimeChanged() {
    if (!mounted) return;
    if (connection != widget.runtime.connectionGeneration) {
      connection = widget.runtime.connectionGeneration;
      epoch++;
      sendSequence++;
      revision = -1;
      resizeTimer?.cancel();
      pendingKeys.clear();
      acknowledgedDraft = null;
      if (interactiveInput && input.text.isNotEmpty) {
        inputDeliveryUncertain = true;
      }
      enterAfterInput = false;
      pendingSize = null;
      attemptedSize = null;
      setState(() {
        state = 'unconfirmed';
        sending = false;
        screenView = null;
        cursorPhase.value = true;
        display = '';
        operationError = null;
        error = widget.runtime.ready ? '正在确认终端状态…' : '服务未连接，终端状态待确认。';
      });
      if (widget.runtime.ready) {
        unawaited(read());
      }
      return;
    }
    if (!widget.runtime.ready && state != 'unconfirmed') {
      epoch++;
      sendSequence++;
      resizeTimer?.cancel();
      pendingKeys.clear();
      acknowledgedDraft = null;
      if (interactiveInput && input.text.isNotEmpty) {
        inputDeliveryUncertain = true;
      }
      enterAfterInput = false;
      pendingSize = null;
      attemptedSize = null;
      setState(() {
        state = 'unconfirmed';
        sending = false;
        error = '服务未连接，终端状态待确认。';
      });
    } else if (widget.runtime.ready && state == 'unconfirmed') {
      attemptedSize = null;
      unawaited(read());
    }
  }

  Future<void> read() async {
    if (reading || !visible || !widget.runtime.ready || !mounted) return;
    reading = true;
    final request = epoch;
    try {
      final result = await widget.runtime
          .call('terminal.read', {
            'sessionId': widget.sessionId,
            'id': widget.id,
          })
          .timeout(const Duration(seconds: 7));
      if (!mounted || request != epoch || result is! Json) return;
      final nextRevision = result['revision'];
      final nextState = result['state'] is String
          ? result['state'] as String
          : 'unknown';
      if (nextRevision is int &&
          (nextRevision != revision ||
              nextState != state ||
              error != result['error'])) {
        final followOutput =
            !outputScroll.hasClients || outputScroll.position.extentAfter < 48;
        final nextView = result['view'] == null
            ? null
            : TerminalScreenData.parse(result['view']);
        final resetCursorPhase =
            screenView == null ||
            nextView == null ||
            screenView!.cursorVisible != nextView.cursorVisible ||
            screenView!.cursorStyle != nextView.cursorStyle ||
            screenView!.cursorBlink != nextView.cursorBlink;
        setState(() {
          revision = nextRevision;
          screenView = nextView;
          if (resetCursorPhase) cursorPhase.value = true;
          display = result['display'] is String
              ? result['display'] as String
              : '';
          state = nextState;
          terminalName = result['name'] is String
              ? result['name'] as String
              : '终端';
          error = result['error'] as String?;
        });
        _pumpInteractiveInput();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && followOutput && outputScroll.hasClients) {
            outputScroll.jumpTo(outputScroll.position.maxScrollExtent);
          }
        });
      }
    } catch (failure) {
      if (mounted && request == epoch) {
        setState(() {
          state = 'unconfirmed';
          error = terminalFailureMessage(failure) ?? '终端暂不可读取，请检查服务连接。';
        });
      }
    } finally {
      reading = false;
    }
  }

  Future<void> send(String data, {bool clear = false}) async {
    if (!mounted || state != 'running' || !widget.runtime.ready) return;
    if (utf8.encode(data).length > 65536) {
      setState(() => operationError = '单次终端输入不能超过 64 KiB，请分段发送。');
      return;
    }
    if (sending) {
      if (clear) return;
      if (pendingKeys.length >= 64) {
        setState(() => operationError = '按键队列已满，请等待终端响应。');
        return;
      }
      pendingKeys.addLast(data);
      return;
    }
    final draft = input.text;
    final request = epoch;
    final sequence = ++sendSequence;
    final requestConnection = widget.runtime.connectionGeneration;
    setState(() {
      sending = true;
      operationError = null;
    });
    var accepted = false;
    try {
      await widget.runtime
          .call('terminal.write', {
            'sessionId': widget.sessionId,
            'id': widget.id,
            'data': data,
          })
          .timeout(const Duration(seconds: 7));
      if (!mounted ||
          sequence != sendSequence ||
          request != epoch ||
          requestConnection != widget.runtime.connectionGeneration) {
        return;
      }
      accepted = true;
      if (clear) {
        if (input.value.composing.isValid) {
          acknowledgedDraft = draft;
        } else {
          _removeAcknowledgedDraft(draft);
        }
      }
      await read();
    } catch (failure) {
      if (mounted &&
          sequence == sendSequence &&
          request == epoch &&
          requestConnection == widget.runtime.connectionGeneration) {
        setState(
          () => operationError =
              terminalFailureMessage(failure) ??
              '输入送达状态未知，后续按键未发送。先检查终端输出，再决定是否重试。',
        );
        if (clear && interactiveInput) {
          inputDeliveryUncertain = true;
          enterAfterInput = false;
        }
      }
    } finally {
      if (sequence == sendSequence) {
        if (!accepted ||
            request != epoch ||
            requestConnection != widget.runtime.connectionGeneration ||
            state != 'running' ||
            !widget.runtime.ready) {
          final dropped = pendingKeys.isNotEmpty;
          pendingKeys.clear();
          if (accepted && dropped && mounted) {
            operationError = '终端状态待确认，排队按键未发送；请检查输出后重新输入。';
          }
        }
        if (mounted) {
          setState(() => sending = false);
          if (accepted &&
              pendingKeys.isNotEmpty &&
              state == 'running' &&
              widget.runtime.ready) {
            unawaited(send(pendingKeys.removeFirst()));
          } else if (accepted) {
            _pumpInteractiveInput();
          }
        }
      }
    }
  }

  Future<void> sendDraft({required bool enter}) async {
    if (input.value.composing.isValid) {
      setState(() => operationError = '请先确认正在输入的文字，再发送到终端。');
      return;
    }
    final draft = input.text;
    if (draft.isEmpty && !enter) return;
    inputDeliveryUncertain = false;
    enterAfterInput = false;
    await send(
      terminalDraftInput(
        draft,
        enter: enter,
        bracketedPaste: screenView?.bracketedPaste == true,
      ),
      clear: true,
    );
  }

  void scheduleResize(({int cols, int rows}) size) {
    if (!mounted ||
        state != 'running' ||
        !widget.runtime.ready ||
        screenView == null) {
      return;
    }
    if (screenView!.cols == size.cols && screenView!.rows == size.rows) return;
    if (attemptedSize == size || pendingSize == size) return;
    pendingSize = size;
    resizeTimer?.cancel();
    resizeTimer = Timer(const Duration(milliseconds: 180), () {
      unawaited(applyResize());
    });
  }

  Future<void> applyResize() async {
    if (resizing || !mounted || state != 'running' || !widget.runtime.ready) {
      return;
    }
    final size = pendingSize;
    pendingSize = null;
    if (size == null) return;
    if (screenView?.cols == size.cols && screenView?.rows == size.rows) return;
    resizing = true;
    attemptedSize = size;
    final request = epoch;
    final connection = widget.runtime.connectionGeneration;
    try {
      await widget.runtime
          .call('terminal.resize', {
            'sessionId': widget.sessionId,
            'id': widget.id,
            'cols': size.cols,
            'rows': size.rows,
          })
          .timeout(const Duration(seconds: 7));
      if (mounted &&
          request == epoch &&
          connection == widget.runtime.connectionGeneration) {
        await read();
      }
    } catch (failure) {
      if (mounted &&
          request == epoch &&
          connection == widget.runtime.connectionGeneration) {
        setState(
          () => operationError =
              terminalFailureMessage(failure) ??
              '终端尺寸未能同步，重新进入页面后可重试。',
        );
      }
    } finally {
      resizing = false;
      if (pendingSize != null && mounted) {
        resizeTimer?.cancel();
        resizeTimer = Timer(const Duration(milliseconds: 180), () {
          unawaited(applyResize());
        });
      }
    }
  }

  Future<void> close() async {
    if (closing) return;
    setState(() => closing = true);
    try {
      await widget.runtime
          .call('terminal.close', {
            'sessionId': widget.sessionId,
            'id': widget.id,
          })
          .timeout(const Duration(seconds: 7));
      if (mounted) Navigator.of(context).pop();
    } catch (failure) {
      if (mounted) {
        setState(() {
          closing = false;
          error = terminalFailureMessage(failure) ?? '终端未确认关闭，请重试。';
        });
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    sendSequence++;
    polling?.cancel();
    resizeTimer?.cancel();
    cursorTimer?.cancel();
    cursorPhase.dispose();
    pendingKeys.clear();
    activeMouseButtons.clear();
    lastMouseCells.clear();
    acknowledgedDraft = null;
    WidgetsBinding.instance.removeObserver(this);
    widget.runtime.removeListener(_runtimeChanged);
    input.dispose();
    inputFocus.dispose();
    outputScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(terminalName),
    trailing: GlassButton(
      icon: Icons.close_rounded,
      label: '关闭终端进程',
      onPressed: closing ? null : close,
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: const TextSpan(
            text: 'W',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.35,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final cellWidth = painter.width;
        final lineHeight = painter.height;
        painter.dispose();
        final size = fitTerminalViewport(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          cellWidth: cellWidth,
          lineHeight: lineHeight,
          reservedHeight: MediaQuery.paddingOf(context).top + 230,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) scheduleResize(size);
        });
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(
              constraints.maxWidth,
              (screenView?.cols ?? 0) * cellWidth + 40,
            ),
            height: constraints.maxHeight,
            child: ColoredBox(
              color:
                  screenView?.background ??
                  Theme.of(context).colorScheme.surface,
              child: ListView.builder(
                controller: outputScroll,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 150),
                itemCount: 4 + (screenView?.lines.length ?? 0),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Text(
                      state == 'running' ? '运行中 · 离开页面后继续运行' : '进程状态：$state',
                      style: Theme.of(context).textTheme.labelMedium,
                    );
                  }
                  if (index == 1) {
                    final message = operationError ?? error;
                    return message == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(message),
                          );
                  }
                  if (index == 2) return const SizedBox(height: 12);
                  if (screenView == null) {
                    return index == 3
                        ? SelectableText(
                            display.isEmpty ? ' ' : display,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              height: 1.35,
                            ),
                          )
                        : const SizedBox.shrink();
                  }
                  if (index == 3) {
                    return screenView!.stylesTruncated
                        ? Text(
                            '终端样式过多，后续颜色已简化。',
                            style: Theme.of(context).textTheme.labelSmall,
                          )
                        : const SizedBox.shrink();
                  }
                  final line = index - 4;
                  final view = screenView!;
                  final lineData = view.lines[line];
                  // 只有含光标单元格的行依赖闪烁相位；其它行固定 running=false，
                  // 使 530ms 一次的相位切换只重建光标行，而不是整页所有终端行。
                  final hasCursor = lineData.runs.any((run) => run.cursor);
                  final cursorRunning = state == 'running' && view.cursorVisible;
                  TerminalScreenLine buildLine(bool phase) => TerminalScreenLine(
                    key: ValueKey('terminal-line-$line'),
                    line: lineData,
                    running:
                        hasCursor &&
                        cursorRunning &&
                        (!view.cursorBlink || phase),
                    palette: view.palette,
                    foreground: view.foreground,
                    background: view.background,
                    cursorColor: view.cursorColor,
                    cursorStyle: view.cursorStyle,
                  );
                  final content = hasCursor && view.cursorBlink
                      ? ValueListenableBuilder<bool>(
                          valueListenable: cursorPhase,
                          builder: (context, phase, _) => buildLine(phase),
                        )
                      : buildLine(true);
                  if (!view.sgrMouse || view.mouseTracking == 'off' ||
                      line < view.lines.length - view.rows) {
                    return content;
                  }
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      if (!_mouseDevice(event) ||
                          (interactiveInput && input.text.isNotEmpty)) {
                        return;
                      }
                      final button = _mouseButton(event.buttons);
                      if (button == null) return;
                      activeMouseButtons[event.pointer] = button;
                      _reportMouse(event, line, cellWidth, lineHeight, 'down', button);
                    },
                    onPointerMove: (event) {
                      if (!_mouseDevice(event)) return;
                      final button = activeMouseButtons[event.pointer];
                      if (button != null) {
                        _reportMouse(event, line, cellWidth, lineHeight, 'move', button);
                      } else if (view.mouseTracking == 'any') {
                        _reportMouse(event, line, cellWidth, lineHeight, 'move', 3);
                      }
                    },
                    onPointerUp: (event) {
                      final button = activeMouseButtons.remove(event.pointer);
                      lastMouseCells.remove(event.pointer);
                      if (button != null) {
                        _reportMouse(event, line, cellWidth, lineHeight, 'up', button);
                      }
                    },
                    onPointerCancel: (event) {
                      activeMouseButtons.remove(event.pointer);
                      lastMouseCells.remove(event.pointer);
                    },
                    onPointerSignal: (event) {
                      if (event is! PointerScrollEvent || !_mouseDevice(event)) return;
                      if (event.scrollDelta.dy == 0) return;
                      _reportMouse(event, line, cellWidth, lineHeight,
                          event.scrollDelta.dy < 0 ? 'wheelUp' : 'wheelDown', 0);
                    },
                    child: SizedBox(
                      width: view.cols * cellWidth,
                      height: lineHeight,
                      child: content,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    ),
    bottom: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PocketButton.tonal(
                    onPressed: sending || input.text.isNotEmpty
                        ? null
                        : () => setState(() {
                            interactiveInput = !interactiveInput;
                            enterAfterInput = false;
                            inputDeliveryUncertain = false;
                          }),
                    child: Text(interactiveInput ? '实时输入' : '草稿输入'),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    icon: Icons.copy_rounded,
                    label: '复制终端内容',
                    onPressed: copyableDisplay.isEmpty
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: copyableDisplay),
                          ),
                  ),
                  const SizedBox(width: 8),
                  for (final key in const [
                    ('Esc', '\u001b'),
                    ('Tab', '\t'),
                    ('Shift-Tab', '\u001b[Z'),
                    ('↑', '\u001b[A'),
                    ('↓', '\u001b[B'),
                    ('←', '\u001b[D'),
                    ('→', '\u001b[C'),
                    ('退格', '\u007f'),
                    ('Enter', '\r'),
                    ('Ctrl-C', '\u0003'),
                    ('Ctrl-D', '\u0004'),
                    ('Ctrl-Z', '\u001a'),
                  ]) ...[
                    PocketButton.tonal(
                      onPressed: state == 'running' && widget.runtime.ready
                          ? () => _sendControlKey(
                              const {'↑', '↓', '←', '→'}.contains(key.$1)
                                  ? terminalArrowInput(
                                      key.$1,
                                      applicationCursorKeys:
                                          screenView?.applicationCursorKeys ==
                                          true,
                                    )
                                  : key.$2,
                            )
                          : null,
                      child: Text(key.$1),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    focusNode: inputFocus,
                    enabled: state == 'running',
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: interactiveInput ? '输入即发送' : '输入命令',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submitInput(),
                  ),
                ),
                const SizedBox(width: 8),
                if (!interactiveInput) ...[
                  GlassButton(
                    icon: Icons.keyboard_rounded,
                    label: '仅发送输入，不按回车',
                    onPressed:
                        state == 'running' && !sending && input.text.isNotEmpty
                        ? () => sendDraft(enter: false)
                        : null,
                  ),
                  const SizedBox(width: 8),
                ],
                GlassButton(
                  icon: Icons.arrow_upward_rounded,
                  label: interactiveInput ? '发送回车' : '发送命令',
                  onPressed:
                      state == 'running' && (interactiveInput || !sending)
                      ? _submitInput
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
