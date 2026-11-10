import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'configuration_editor.dart';
import 'runtime.dart';
import 'ui.dart';

/// One managed MCP server decoded from the manager's watch stream.
class McpServerRow {
  const McpServerRow({
    required this.name,
    required this.configured,
    required this.state,
    this.toolCount,
    this.attempt,
    this.maxAttempts,
    this.lastError,
  });

  final String name;

  /// False for a retained cleanup record after the entry was removed.
  final bool configured;
  final String state;
  final int? toolCount;
  final int? attempt;
  final int? maxAttempts;
  final String? lastError;

  /// A server the user can restart or probe.
  bool get addressable => configured;
}

/// Decode one `mcpManager/watch` frame value into server rows.
List<McpServerRow> mcpServersFrom(dynamic value) {
  if (value is! List) throw const FormatException('MCP 服务器列表格式无效');
  return [
    for (final raw in value)
      if (raw is Map)
        McpServerRow(
          name: _text(raw['name']) ?? '未命名服务器',
          configured: raw['configured'] == true,
          state: _state(raw['status']),
          toolCount: _count(raw['status']?['toolCount']),
          attempt: _count(raw['status']?['attempt']),
          maxAttempts: _count(raw['status']?['maxAttempts']),
          lastError: _text(raw['status']?['lastError']),
        )
      else
        throw const FormatException('MCP 服务器条目无效'),
  ];
}

String _state(dynamic status) {
  if (status is! Map) throw const FormatException('MCP 服务器状态无效');
  final state = status['state'];
  if (state is String && state.isNotEmpty) return state;
  throw const FormatException('MCP 服务器状态无效');
}

String? _text(dynamic value) => value is String && value.isNotEmpty ? value : null;

int? _count(dynamic value) => value is int && value >= 0 ? value : null;

/// Model-facing status label for one server row.
String mcpStatusLabel(McpServerRow row) {
  switch (row.state) {
    case 'connected':
      final tools = row.toolCount;
      return tools == null ? '已连接' : '已连接 · $tools 个工具';
    case 'connecting':
      return row.attempt == null ? '正在连接' : '正在连接（第 ${row.attempt} 次）';
    case 'reconnecting':
      return row.attempt == null || row.maxAttempts == null
          ? '正在重连'
          : '正在重连（${row.attempt}/${row.maxAttempts}）';
    case 'waiting-credentials':
      return '等待凭据';
    case 'disabled':
      return '已停用';
    case 'closed':
      return '已关闭';
    case 'failed':
      final reason = row.lastError;
      return reason == null ? '失败' : '失败：$reason';
    default:
      return row.state;
  }
}

/// One model-facing status summary for the settings subtitle.
String mcpSummary(List<McpServerRow> rows) {
  if (rows.isEmpty) return '未配置 MCP 服务器';
  final connected = rows.where((row) => row.state == 'connected').length;
  return '${rows.length} 个服务器 · $connected 个已连接';
}

/// Live MCP server status with restart and probe actions.
///
/// The list comes from the manager's own watch stream, so status changes push
/// without polling. Editing the `servers` map stays with the ordinary settings
/// form for the owning entry; this page only links to it.
class McpServersPage extends StatefulWidget {
  const McpServersPage({required this.runtime, super.key});

  final RuntimeController runtime;

  @override
  State<McpServersPage> createState() => _McpServersPageState();
}

class _McpServersPageState extends State<McpServersPage> {
  List<McpServerRow>? rows;
  String? error;
  String? probing;
  String? restarting;
  int generation = 0;
  late int connectionGeneration;
  late String phase;
  StreamSubscription<Json>? watch;

  @override
  void initState() {
    super.initState();
    connectionGeneration = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    widget.runtime.addListener(runtimeChanged);
    _subscribe();
  }

  @override
  void dispose() {
    widget.runtime.removeListener(runtimeChanged);
    unawaited(watch?.cancel());
    super.dispose();
  }

  void runtimeChanged() {
    if (phase == widget.runtime.phase &&
        connectionGeneration == widget.runtime.connectionGeneration) {
      return;
    }
    phase = widget.runtime.phase;
    connectionGeneration = widget.runtime.connectionGeneration;
    generation++;
    setState(() {
      rows = null;
      error = null;
    });
    unawaited(watch?.cancel());
    if (widget.runtime.ready) _subscribe();
  }

  void _subscribe() {
    if (!widget.runtime.ready) return;
    final attempt = generation;
    watch = widget.runtime
        .watchApi('mcpManager', 'watch')
        .listen(
          (frame) {
            if (!mounted || attempt != generation) return;
            switch (frame['type']) {
              case 'item':
                try {
                  final decoded = mcpServersFrom(frame['value']);
                  setState(() {
                    rows = decoded;
                    error = null;
                  });
                } on FormatException catch (failure) {
                  setState(() => error = '${failure.message}，请重新打开页面');
                }
              case 'error':
                final message = frame['error']?['message'];
                setState(
                  () => error = 'MCP 状态未能读取。${message is String ? message : '服务未确认'}',
                );
              default:
                break;
            }
          },
          onError: (Object failure) {
            if (!mounted || attempt != generation) return;
            setState(() => error = 'MCP 状态未能读取。${mcpFailureCode(failure)}');
          },
          onDone: () {
            if (!mounted || attempt != generation) return;
            if (widget.runtime.ready) _subscribe();
          },
        );
  }

  Json? get _configForm {
    for (final form in widget.runtime.forms) {
      if (form['ns'] == 'mcp-manager') return form;
    }
    return null;
  }

  Future<void> _restart(McpServerRow row) async {
    if (restarting != null) return;
    setState(() => restarting = row.name);
    try {
      await widget.runtime.call('api.call', {
        'namespace': 'mcpManager',
        'method': 'restart',
        'args': {'name': row.name},
      });
      if (mounted) setState(() => error = null);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '重启未能确认。${mcpFailureCode(failure)}');
      }
    } finally {
      if (mounted) setState(() => restarting = null);
    }
  }

  Future<void> _probe(McpServerRow row) async {
    if (probing != null) return;
    setState(() => probing = row.name);
    try {
      final result = await widget.runtime.call('api.call', {
        'namespace': 'mcpManager',
        'method': 'probe',
        'args': {'name': row.name},
      });
      if (!mounted) return;
      // The probe settled; stop the row spinner before the modal keeps the page
      // from reaching a steady frame.
      setState(() => probing = null);
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('探测 ${row.name}'),
          content: Text(
            result is Map && result['ok'] == true
                ? '连接成功，工具列表已读取；探测不保留连接。'
                : '探测失败（${result is Map && result['stage'] is String ? result['stage'] : '未确认'}）：'
                      '${result is Map && result['message'] is String ? result['message'] : '服务未返回原因'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (failure) {
      if (mounted) {
        setState(() => error = '探测未能确认。${mcpFailureCode(failure)}');
      }
    } finally {
      if (mounted && probing != null) setState(() => probing = null);
    }
  }

  Color _stateColor(ThemeData theme, McpServerRow row) => switch (row.state) {
    'connected' => theme.colorScheme.tertiary,
    'connecting' || 'reconnecting' => theme.colorScheme.primary,
    'waiting-credentials' => theme.colorScheme.error,
    'failed' => theme.colorScheme.error,
    _ => theme.colorScheme.outline,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = this.rows;
    return PocketScaffold(
      title: const Text('MCP 服务器'),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          PocketSection(
            title: '连接状态',
            children: [
              if (!widget.runtime.ready)
                const PocketRow(
                  icon: Icons.sync_rounded,
                  title: '本地服务就绪后读取 MCP 状态',
                ),
              if (error != null)
                PocketRow(icon: Icons.error_outline_rounded, title: error!),
              if (rows == null && widget.runtime.ready && error == null)
                const PocketRow(
                  icon: Icons.sync_rounded,
                  title: '正在读取 MCP 服务器',
                ),
              if (rows != null && rows.isEmpty)
                const PocketRow(
                  icon: Icons.extension_outlined,
                  title: '未配置 MCP 服务器',
                  subtitle: '在下面的配置里添加 servers 后，这里会显示连接状态。',
                ),
              for (final row in rows ?? const <McpServerRow>[])
                _McpServerTile(
                  key: ValueKey('mcp-server-${row.name}'),
                  row: row,
                  color: _stateColor(theme, row),
                  busy: restarting == row.name || probing == row.name,
                  onRestart: _restart,
                  onProbe: _probe,
                ),
            ],
          ),
          PocketSection(
            title: '配置',
            children: [
              if (_configForm != null)
                PocketRow(
                  icon: Icons.settings_outlined,
                  title: '编辑服务器配置',
                  subtitle: '添加、修改或移除 servers；保存后状态会自动更新',
                  onTap: () => Navigator.push(
                    context,
                    PocketRoute<void>(
                      builder: (_) => ConfigPage(
                        runtime: widget.runtime,
                        descriptor: _configForm!,
                      ),
                    ),
                  ),
                )
              else
                const PocketRow(
                  icon: Icons.info_outline_rounded,
                  title: '当前 profile 没有可编辑的 mcp-manager 配置',
                  subtitle: '服务器只来自已安装插件时，需要由插件提供方管理。',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _McpServerTile extends StatelessWidget {
  const _McpServerTile({
    required this.row,
    required this.color,
    required this.busy,
    required this.onRestart,
    required this.onProbe,
    super.key,
  });

  final McpServerRow row;
  final Color color;
  final bool busy;
  final Future<void> Function(McpServerRow row) onRestart;
  final Future<void> Function(McpServerRow row) onProbe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.name, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  mcpStatusLabel(row),
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
                if (!row.configured)
                  Text(
                    '配置已移除，连接仍在收尾',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (row.addressable) ...[
            IconButton(
              tooltip: '探测连接',
              icon: const Icon(Icons.network_ping_rounded),
              onPressed: () => unawaited(onProbe(row)),
            ),
            IconButton(
              tooltip: '重启服务器',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: () => unawaited(onRestart(row)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Platform failure code when the bridge reports one, else a neutral label.
String mcpFailureCode(Object failure) =>
    failure is PlatformException ? failure.code : 'unconfirmed';
