import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'approvals.dart';
import 'runtime.dart';
import 'ui.dart';

/// The server's observed execution policy. A directory is never presented as
/// a Shell confinement boundary merely because file tools use one.
class ExecutionPermissionPolicy {
  const ExecutionPermissionPolicy({
    required this.fileSandbox,
    required this.presetsAvailable,
  });

  final String? fileSandbox;
  final bool presetsAvailable;

  factory ExecutionPermissionPolicy.parse(Object? response) {
    if (response is! Json) throw const FormatException('权限状态不是对象');
    final shell = response['shell'];
    final files = response['fileTools'];
    final presets = response['presets'];
    if (shell is! Json ||
        shell['tool'] != 'android_shell' ||
        shell['executionIdentity'] != 'app-uid' ||
        shell['approval'] != 'every-invocation' ||
        shell['workspaceConfinement'] != false ||
        files is! Json ||
        (files['sandboxMode'] != null && files['sandboxMode'] is! String) ||
        presets is! Json ||
        presets['available'] is! bool) {
      throw const FormatException('权限状态与当前 App 契约不符');
    }
    return ExecutionPermissionPolicy(
      fileSandbox: files['sandboxMode'] as String?,
      presetsAvailable: presets['available'] as bool,
    );
  }

  String get fileSummary => switch (fileSandbox) {
    'workspace-write' => '默认限于工作区及许可的临时目录；扩大范围需单次批准',
    'read-only' => '只读；修改请求按运行时策略处理',
    'danger-full-access' => '文件工具未受工作区范围限制',
    null => '文件工具策略未确认',
    _ => '自定义文件工具策略：$fileSandbox',
  };
}

class ExecutionPermissionsPage extends StatefulWidget {
  const ExecutionPermissionsPage({required this.runtime, super.key});

  final RuntimeController runtime;

  @override
  State<ExecutionPermissionsPage> createState() =>
      _ExecutionPermissionsPageState();
}

class _ExecutionPermissionsPageState extends State<ExecutionPermissionsPage> {
  ExecutionPermissionPolicy? policy;
  String? error;
  bool loading = false;
  int request = 0;
  late (int, bool) observed = (
    widget.runtime.connectionGeneration,
    widget.runtime.ready,
  );

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(runtimeChanged);
    unawaited(refresh());
  }

  @override
  void dispose() {
    widget.runtime.removeListener(runtimeChanged);
    request++;
    super.dispose();
  }

  void runtimeChanged() {
    final next = (widget.runtime.connectionGeneration, widget.runtime.ready);
    if (next == observed) return;
    observed = next;
    request++;
    setState(() {
      policy = null;
      error = null;
      loading = false;
    });
    if (widget.runtime.ready) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (!widget.runtime.ready) {
      setState(() {
        policy = null;
        error = '本地服务尚未就绪';
      });
      return;
    }
    final current = ++request;
    final generation = widget.runtime.connectionGeneration;
    setState(() {
      loading = true;
      error = null;
    });
    bool owns() =>
        mounted &&
        current == request &&
        generation == widget.runtime.connectionGeneration &&
        widget.runtime.ready;
    try {
      final raw = await widget.runtime.call('runtime.permissions');
      final next = ExecutionPermissionPolicy.parse(raw);
      if (owns()) setState(() => policy = next);
    } catch (failure) {
      if (owns()) {
        setState(() {
          policy = null;
          error = '无法确认执行权限：$failure';
        });
      }
    } finally {
      if (owns()) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('执行权限'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新执行权限',
      onPressed: loading ? null : refresh,
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        if (policy == null)
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.verified_user_outlined,
                title: loading ? '正在读取执行权限' : '执行权限待确认',
                subtitle: error,
              ),
            ],
          ),
        if (policy != null) ...[
          PocketSection(
            title: '当前运行边界',
            divided: true,
            children: [
              const PocketRow(
                icon: Icons.terminal_rounded,
                title: 'Shell 命令',
                subtitle: '以 App 身份运行；每条命令执行前都需单次授权',
              ),
              PocketRow(
                icon: Icons.folder_outlined,
                title: 'Agent 文件工具',
                subtitle: policy!.fileSummary,
              ),
              PocketRow(
                icon: Icons.verified_user_outlined,
                title: '会话权限预设',
                subtitle: policy!.presetsAvailable
                    ? '原版预设服务已接入；Shell 尚无逐命令文件隔离，暂不可切换'
                    : '暂不可切换：Shell 尚无逐命令文件隔离',
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Shell 的工作目录不限制文件访问。文件工具的工作区策略不适用于 Shell。'),
          ),
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.rule_rounded,
                title: '授权与提问',
                subtitle: '查看和处理待确认的执行请求',
                onTap: () => Navigator.push(
                  context,
                  PocketRoute<void>(
                    builder: (_) => ApprovalsPage(runtime: widget.runtime),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
