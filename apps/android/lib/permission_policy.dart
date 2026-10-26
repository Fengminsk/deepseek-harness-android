import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'approvals.dart';
import 'isolated_approval_page.dart';
import 'runtime.dart';
import 'ui.dart';

/// The server's observed execution policy. A directory is never presented as
/// a Shell confinement boundary merely because file tools use one.
class ExecutionPermissionPolicy {
  const ExecutionPermissionPolicy({
    required this.fileSandbox,
    required this.presetsAvailable,
    required this.shellAvailable,
  });

  final String? fileSandbox;
  final bool presetsAvailable;
  final bool shellAvailable;

  factory ExecutionPermissionPolicy.parse(Object? response) {
    if (response is! Json) throw const FormatException('权限状态不是对象');
    final shell = response['shell'];
    final files = response['fileTools'];
    final presets = response['presets'];
    final programmaticTools = response['programmaticTools'];
    final unavailableShell =
        shell is Json &&
        shell['tool'] == 'android_shell' &&
        shell['available'] == false &&
        shell['reason'] == 'isolated-executor-unavailable' &&
        shell['executionIdentity'] == null &&
        shell['approval'] == 'unavailable' &&
        shell['workspaceConfinement'] == false;
    final legacyShell =
        shell is Json &&
        shell['tool'] == 'android_shell' &&
        shell['available'] == null &&
        shell['executionIdentity'] == 'app-uid' &&
        shell['approval'] == 'every-invocation' &&
        shell['workspaceConfinement'] == false;
    if (shell is! Json ||
        (!unavailableShell && !legacyShell) ||
        files is! Json ||
        (files['sandboxMode'] != null && files['sandboxMode'] is! String) ||
        presets is! Json ||
        presets['available'] is! bool ||
        programmaticTools is! Json ||
        programmaticTools['available'] != false ||
        programmaticTools['filesystem'] != 'read-only' ||
        programmaticTools['writableRoots'] is! List ||
        (programmaticTools['writableRoots'] as List).isNotEmpty ||
        programmaticTools['network'] != 'off' ||
        programmaticTools['reason'] != 'isolated-executor-unwired') {
      throw const FormatException('权限状态与当前 App 契约不符');
    }
    return ExecutionPermissionPolicy(
      fileSandbox: files['sandboxMode'] as String?,
      presetsAvailable: presets['available'] as bool,
      shellAvailable: legacyShell,
    );
  }

  String get fileSummary => switch (fileSandbox) {
    'workspace-write' => '写入默认限于工作区及许可的临时目录；内置模型文件读取另限于工作区绝对路径',
    'read-only' => '只读；修改请求按运行时策略处理',
    'danger-full-access' => '文件工具未受工作区范围限制',
    null => '文件工具策略未确认',
    _ => '自定义文件工具策略：$fileSandbox',
  };

  String get shellSummary => shellAvailable
      ? '内部迁移模式：以 App 身份运行，每条命令执行前需单次授权；无路径或网络隔离'
      : '默认关闭：隔离 Shell 尚未就绪，模型不能运行任意命令';
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
    title: const Text('沙箱与执行权限'),
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
                icon: Icons.shield_outlined,
                title: '隔离脚本授权',
                subtitle: '查看指定运行的文件、可写路径和联网范围',
                onTap: () => Navigator.push(
                  context,
                  PocketRoute<void>(
                    builder: (_) =>
                        IsolatedApprovalInboxPage(runtime: widget.runtime),
                  ),
                ),
              ),
              PocketRow(
                icon: Icons.verified_user_outlined,
                title: loading ? '正在读取执行权限' : '执行权限待确认',
                subtitle: error,
              ),
            ],
          ),
        if (policy != null) ...[
          PocketSection(
            title: '脚本执行沙箱',
            divided: true,
            children: const [
              PocketRow(
                icon: Icons.lock_outline_rounded,
                title: '尚未启用',
                subtitle: '通用 PTC 与工作流执行器尚未接入模型工具。',
              ),
              PocketRow(
                icon: Icons.folder_off_outlined,
                title: '文件：只读',
                subtitle: '默认不授予脚本可写路径；未来可选择指定工作区。',
              ),
              PocketRow(
                icon: Icons.wifi_off_rounded,
                title: '网络：关闭',
                subtitle: '默认不授予脚本联网权限；模型账号连接独立运行。',
              ),
            ],
          ),
          PocketSection(
            title: '当前运行边界',
            divided: true,
            children: [
              PocketRow(
                icon: Icons.terminal_rounded,
                title: 'Shell 命令',
                subtitle: policy!.shellSummary,
              ),
              PocketRow(
                icon: Icons.folder_outlined,
                title: 'Agent 文件工具',
                subtitle: policy!.fileSummary,
              ),
              const PocketRow(
                icon: Icons.extension_outlined,
                title: '插件与自定义配置',
                subtitle: '受信任代码以 App 身份运行，不受隔离脚本的路径和网络策略约束。',
              ),
              PocketRow(
                icon: Icons.verified_user_outlined,
                title: '会话权限预设',
                subtitle: policy!.presetsAvailable
                    ? '原版预设服务已接入；隔离 Shell 尚未就绪，暂不可切换'
                    : '暂不可切换：隔离 Shell 尚未就绪',
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              policy!.shellAvailable
                  ? '内部迁移模式中的 Shell 工作目录不限制文件访问，文件工具策略不适用于 Shell。'
                  : '文件工具的工作区策略不会授予 Shell 文件路径或联网能力。',
            ),
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
