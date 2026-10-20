import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'models.dart';

const commandDefinitions = {
  'goal': '@deepseek-ai/dsh-command-goal',
  'plan': '@deepseek-ai/dsh-plan-mode',
  'feedback': '@deepseek-ai/dsh-command-feedback',
  'compact': '@deepseek-ai/dsh-command-compact',
  'permission': '@deepseek-ai/dsh-permission-presets',
  'export': '@deepseek-ai/dsh-session-log-export',
};

String? builtinCommand(Json descriptor) {
  for (final entry in commandDefinitions.entries) {
    if (descriptor['definitionId'] == entry.value) return entry.key;
  }
  return null;
}

String commandLabel(Json descriptor) =>
    switch (builtinCommand(descriptor) ?? descriptor['clientAction']) {
      'file' => '文件',
      'goal' => '目标',
      'plan' => '计划',
      'feedback' => '反馈',
      'compact' => '压缩',
      'permission' => '权限',
      'model' => '模型',
      'export' => '下载日志',
      _ => '${descriptor['name']}',
    };

/// Uses the original ui-commands token rules, including definition-scoped aliases.
({Json descriptor, String line, bool bare})? typedComposerCommand(
  String text,
  List<Json> catalog,
) {
  final line = text.trim();
  if (!line.startsWith('/')) return null;
  final separator = line.indexOf(RegExp(r'\s'));
  final token = separator < 0
      ? line.substring(1)
      : line.substring(1, separator);
  final bare = separator < 0;
  if (token.isEmpty) return null;
  final rows = composerCommandRows(catalog);
  var descriptor = rows.where((row) => row['name'] == token).firstOrNull;
  const aliases = {
    '目标': 'goal',
    '计划': 'plan',
    '反馈': 'feedback',
    '压缩': 'compact',
    '权限': 'permission',
    '导出': 'export',
  };
  final alias = aliases[token];
  if (descriptor == null && alias != null) {
    descriptor = rows
        .where((row) => row['definitionId'] == commandDefinitions[alias])
        .firstOrNull;
  }
  if (descriptor == null || (!bare && descriptor['input'] == null)) return null;
  return (
    descriptor: descriptor,
    line: '/${descriptor['name']}${bare ? '' : line.substring(separator)}',
    bare: bare,
  );
}

Future<List<Json>> loadComposerCatalog(
  RuntimeController runtime,
  String id,
) async {
  await runtime.ensureSession(id);
  final result = await runtime.call('api.call', {
    'namespace': 'commands',
    'method': 'list',
    'args': {'agentId': id},
  }) as List;
  return result.cast<Json>();
}

String commandDescription(Json descriptor) =>
    switch (builtinCommand(descriptor) ?? descriptor['clientAction']) {
      'file' => '添加文件到当前消息',
      'goal' => '设置或查看长期任务目标',
      'plan' => '进入或退出计划模式',
      'feedback' => '发送关于当前会话的反馈',
      'compact' => '压缩以上对话内容',
      'permission' => '切换权限预设（沙箱模式与审批策略）',
      'model' => '选择本会话使用的模型',
      'export' => '将当前会话内容导出为 ZIP',
      _ => '${descriptor['description'] ?? ''}',
    };

IconData commandIcon(Json descriptor) =>
    switch (builtinCommand(descriptor) ?? descriptor['clientAction']) {
      'file' => Icons.attach_file_rounded,
      'goal' => Icons.track_changes_rounded,
      'plan' => Icons.edit_note_rounded,
      'feedback' => Icons.send_outlined,
      'compact' => Icons.compress_rounded,
      'permission' => Icons.verified_user_outlined,
      'model' => Icons.hub_outlined,
      'export' => Icons.file_download_outlined,
      _ => Icons.terminal_rounded,
    };

/// Matches ui-commands/presentation.ts; plugin rows retain their own identity.
List<Json> composerCommandRows(List<Json> catalog) {
  final rows = [
    ...catalog,
    {'name': 'file', 'clientAction': 'file'},
    {'name': 'model', 'clientAction': 'model'},
  ];
  const add = ['file', 'goal', 'plan', 'feedback'];
  const commands = ['compact', 'permission', 'model', 'export'];
  final byName = {for (final row in rows) row['name'] as String: row};
  if (byName.length != rows.length) {
    throw const FormatException('文件或模型菜单与插件指令名称冲突');
  }
  return [
    for (final name in add)
      if (byName[name] != null) {...byName[name]!, 'section': '添加'},
    for (final name in commands)
      if (byName[name] != null) {...byName[name]!, 'section': '指令'},
    for (final row in rows)
      if (!add.contains(row['name']) && !commands.contains(row['name']))
        {...row, 'section': '指令'},
  ];
}

class ComposerCommands extends StatefulWidget {
  const ComposerCommands({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.onPick,
    this.maxHeight = 420,
  });
  final RuntimeController runtime;
  final String sessionId;
  final ValueChanged<Json> onPick;
  final double maxHeight;
  @override
  State<ComposerCommands> createState() => _ComposerCommandsState();
}

class _ComposerCommandsState extends State<ComposerCommands> {
  List<Json>? rows;
  String? error;
  int generation = 0;
  Future<void> configureModels() async {
    await Navigator.push(
      context,
      PocketRoute<void>(builder: (_) => ModelsPage(runtime: widget.runtime)),
    );
    if (mounted) await load();
  }

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(ComposerCommands oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) unawaited(load());
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      rows = null;
      error = null;
    });
    try {
      final result = await loadComposerCatalog(
        widget.runtime,
        widget.sessionId,
      );
      final arranged = composerCommandRows(result);
      if (mounted && current == generation) setState(() => rows = arranged);
    } catch (failure) {
      if (mounted && current == generation) {
        setState(() => error = '无法读取当前会话菜单：$failure');
      }
    }
  }

  @override
  Widget build(BuildContext context) => GlassSurface(
    radius: 26,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        shrinkWrap: true,
        children: [
          if (rows == null) ...[
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                error == null
                    ? '正在读取会话菜单…'
                    : error!.contains('Select an available model')
                    ? '请先配置可用模型与凭据，再使用会话指令。'
                    : error!,
              ),
            ),
            if (error != null) ...[
              PocketTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('文件  file'),
                subtitle: const Text('添加文件到当前消息'),
                onTap: () =>
                    widget.onPick({'name': 'file', 'clientAction': 'file'}),
              ),
              PocketTile(
                leading: const Icon(Icons.hub_outlined),
                title: const Text('配置模型与凭据'),
                onTap: configureModels,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: PocketButton.tonal(
                  onPressed: load,
                  child: const Text('重新读取'),
                ),
              ),
            ],
          ],
          for (var index = 0; index < (rows?.length ?? 0); index++) ...[
            if (index == 0 ||
                rows![index - 1]['section'] != rows![index]['section'])
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 5),
                child: Text(
                  rows![index]['section'] as String,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            PocketTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              leading: Icon(commandIcon(rows![index]), size: 21),
              title: Text(
                '${commandLabel(rows![index])}  ${rows![index]['name']}',
              ),
              subtitle: Text(
                commandDescription(rows![index]),
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () => widget.onPick(rows![index]),
            ),
          ],
        ],
      ),
    ),
  );
}

class ComposerCommandChip extends StatelessWidget {
  const ComposerCommandChip({
    super.key,
    required this.command,
    required this.onRemove,
  });
  final Json command;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: GlassSurface(
      radius: 20,
      child: PocketTile(
        leading: Icon(commandIcon(command)),
        title: Text('${commandLabel(command)} · /${command['name']}'),
        trailing: GlassButton(
          icon: Icons.close_rounded,
          label: '移除指令',
          onPressed: onRemove,
        ),
      ),
    ),
  );
}

class SessionPermissionPage extends StatefulWidget {
  const SessionPermissionPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.command,
  });
  final RuntimeController runtime;
  final String sessionId;
  final Json command;
  @override
  State<SessionPermissionPage> createState() => _SessionPermissionPageState();
}

class _SessionPermissionPageState extends State<SessionPermissionPage> {
  List<Json>? options;
  bool busy = false, acknowledged = false;
  String? pending, result, error;
  String? currentValue;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      await widget.runtime.ensureSession(widget.sessionId);
      final catalog = await widget.runtime.call('api.call', {
        'namespace': 'permissionPresets',
        'method': 'catalog',
        'args': {},
      }) as Json;
      final projection = await widget.runtime.call('api.call', {
        'namespace': 'session',
        'method': 'projections',
        'args': {
          'request': {'sessionId': widget.sessionId},
        },
      }) as Json?;
      if (projection?['kind'] != 'sequenced') {
        throw const FormatException('会话权限状态尚未就绪');
      }
      if (mounted) {
        setState(() {
          options = (catalog['options'] as List).cast<Json>();
          currentValue =
              projection!['values']['permissions']?['currentValue'] as String?;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = '无法读取权限选项：$failure');
    }
  }

  void pick(String value) {
    if (value == 'danger-full-access' || value == 'auto') {
      setState(() {
        pending = value;
        acknowledged = false;
      });
    } else {
      unawaited(apply(value));
    }
  }

  Future<void> apply(String value) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      pending = null;
    });
    try {
      final response = await widget.runtime.call('session.command', {
        'sessionId': widget.sessionId,
        'line': '/${widget.command['name']} $value',
        'attachmentIds': [],
      }) as Json?;
      if (!mounted) return;
      setState(
        () => result = response == null
            ? '指令已不可用，请重新打开会话菜单。'
            : '${response['result']['text'] ?? response['result']['kind']}',
      );
      if (response?['result']['kind'] == 'success') await load();
    } catch (failure) {
      if (mounted) setState(() => error = '执行结果未确认，请先核对会话记录：$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('会话权限'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新权限选项',
      onPressed: busy ? null : load,
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('权限预设由 DSH 提供。Android 系统授予应用的权限边界仍然生效。'),
        ),
        if (options == null)
          const PocketSection(
            children: [
              PocketRow(icon: Icons.verified_user_outlined, title: '正在读取权限选项'),
            ],
          ),
        if (options != null)
          PocketSection(
            title: currentValue == 'custom' ? '当前使用自定义权限' : '权限预设',
            children: [
              for (final option in options!)
                PocketRow(
                  icon: Icons.verified_user_outlined,
                  title: switch (option['value']) {
                    'read-only' => '仅可查看',
                    'workspace-write' => '工作区内修改',
                    'danger-full-access' => '完全权限',
                    'auto' => '自动审查（实验）',
                    _ => '${option['name']}',
                  },
                  subtitle: option['description'] as String?,
                  trailing: option['value'] == currentValue
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: busy ? null : () => pick(option['value'] as String),
                ),
            ],
          ),
        if (pending != null)
          PocketSection(
            title: pending == 'auto' ? '确认启用自动审查（实验）？' : '确认启用完全权限？',
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  pending == 'auto'
                      ? '自动审查不使用沙箱。每次原生工具调用和 PTC 内层调用前，都会由与当前 agent 相同的模型进行审查；审查拒绝的调用由你批准或拒绝。此功能仍属实验性，可能误放行或误拒绝，并会消耗额外 token。'
                      : '启用完全权限后，智能体将减少确认步骤，并且可以直接执行更多操作，包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。',
                ),
              ),
              PocketSwitchRow(
                title: const Text('我已了解风险，并愿意继续'),
                value: acknowledged,
                onChanged: (value) => setState(() => acknowledged = value),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  children: [
                    PocketButton.tonal(
                      onPressed: () => setState(() => pending = null),
                      child: const Text('取消'),
                    ),
                    PocketButton(
                      onPressed: acknowledged ? () => apply(pending!) : null,
                      child: const Text('启用'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        for (final text in [error, result])
          if (text != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(text),
            ),
      ],
    ),
  );
}
