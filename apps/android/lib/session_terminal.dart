import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';
import 'terminal_screen.dart';
import 'ui.dart';

/// Session-scoped PTYs owned by the Android Host. Leaving this page detaches
/// the viewport; it does not close a running shell.
class SessionTerminalsPage extends StatefulWidget {
  const SessionTerminalsPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });

  final RuntimeController runtime;
  final String sessionId;

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

  Future<void> create() async {
    if (loading || !widget.runtime.ready) return;
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
      await widget.runtime
          .call('terminal.create', {
            'sessionId': widget.sessionId,
            'id': id,
            'cols': cols,
            'rows': 24,
          })
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
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
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '无法启动终端。请检查会话工作目录与运行环境。';
        });
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
    trailing: GlassButton(
      icon: Icons.add_rounded,
      label: '新建终端',
      onPressed: loading || !widget.runtime.ready ? null : create,
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
                  title: terminal['cwd'] is String
                      ? (terminal['cwd'] as String).split('/').last
                      : '终端',
                  subtitle: terminal['state'] == 'running'
                      ? '运行中'
                      : '已结束 · ${terminal['exitCode'] ?? '状态未知'}',
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

class SessionTerminalView extends StatefulWidget {
  const SessionTerminalView({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.id,
  });

  final RuntimeController runtime;
  final String sessionId, id;

  @override
  State<SessionTerminalView> createState() => _SessionTerminalViewState();
}

class _SessionTerminalViewState extends State<SessionTerminalView>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  final outputScroll = ScrollController();
  Timer? polling;
  bool reading = false, sending = false, closing = false;
  bool visible = true;
  String display = '', state = 'starting';
  TerminalScreenData? screenView;
  String? error;
  int revision = -1, epoch = 0;

  String get copyableDisplay => screenView == null
      ? display
      : screenView!.lines
            .map((line) => line.runs.map((run) => run.text).join())
            .join('\n');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(_runtimeChanged);
    polling = Timer.periodic(
      const Duration(milliseconds: 450),
      (_) => unawaited(read()),
    );
    unawaited(read());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState next) {
    visible = next == AppLifecycleState.resumed;
    if (visible) unawaited(read());
  }

  void _runtimeChanged() {
    if (!mounted) return;
    if (!widget.runtime.ready && state != 'unconfirmed') {
      epoch++;
      setState(() {
        state = 'unconfirmed';
        error = '服务未连接，终端状态待确认。';
      });
    } else if (widget.runtime.ready && state == 'unconfirmed') {
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
        setState(() {
          revision = nextRevision;
          screenView = nextView;
          display = result['display'] is String
              ? result['display'] as String
              : '';
          state = nextState;
          error = result['error'] as String?;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && followOutput && outputScroll.hasClients) {
            outputScroll.jumpTo(outputScroll.position.maxScrollExtent);
          }
        });
      }
    } catch (_) {
      if (mounted && request == epoch) {
        setState(() {
          state = 'unconfirmed';
          error = '终端暂不可读取，请检查服务连接。';
        });
      }
    } finally {
      reading = false;
    }
  }

  Future<void> send(String data, {bool clear = false}) async {
    if (sending || state != 'running' || !widget.runtime.ready) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.runtime
          .call('terminal.write', {
            'sessionId': widget.sessionId,
            'id': widget.id,
            'data': data,
          })
          .timeout(const Duration(seconds: 7));
      if (clear) input.clear();
      await read();
    } catch (_) {
      if (mounted) setState(() => error = '输入未送达终端。请确认进程仍在运行。');
    } finally {
      if (mounted) setState(() => sending = false);
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
    } catch (_) {
      if (mounted) {
        setState(() {
          closing = false;
          error = '终端未确认关闭，请重试。';
        });
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    polling?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.runtime.removeListener(_runtimeChanged);
    input.dispose();
    outputScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('终端'),
    trailing: GlassButton(
      icon: Icons.close_rounded,
      label: '关闭终端进程',
      onPressed: closing ? null : close,
    ),
    body: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: math.max(
            constraints.maxWidth,
            (screenView?.cols ?? 0) * 8.2 + 40,
          ),
          height: constraints.maxHeight,
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
                return error == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(error!),
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
              return TerminalScreenLine(
                key: ValueKey('terminal-line-${index - 4}'),
                line: screenView!.lines[index - 4],
                running: state == 'running',
              );
            },
          ),
        ),
      ),
    ),
    bottom: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final key in const [
                  ('Ctrl-C', '\u0003'),
                  ('Tab', '\t'),
                  ('Esc', '\u001b'),
                ])
                  PocketButton.tonal(
                    onPressed: state == 'running' && !sending
                        ? () => send(key.$2)
                        : null,
                    child: Text(key.$1),
                  ),
                GlassButton(
                  icon: Icons.copy_rounded,
                  label: '复制终端内容',
                  onPressed: copyableDisplay.isEmpty
                      ? null
                      : () => Clipboard.setData(
                          ClipboardData(text: copyableDisplay),
                        ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    enabled: state == 'running' && !sending,
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(
                      hintText: '输入命令',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) => send('$value\n', clear: true),
                  ),
                ),
                const SizedBox(width: 8),
                GlassButton(
                  icon: Icons.arrow_upward_rounded,
                  label: '发送命令',
                  onPressed: state == 'running' && !sending
                      ? () => send('${input.text}\n', clear: true)
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
