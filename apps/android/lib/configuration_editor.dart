import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_fields.dart';
import 'configuration_fields_schema.dart';
import 'configuration_presentation.dart';
import 'configuration_state.dart';
import 'configuration_value_row.dart';
import 'models.dart' show ModelDraftGuard;
import 'runtime.dart';
import 'text_document_page.dart';
import 'ui.dart';

const _encoder = JsonEncoder.withIndent('  ');

class ConfigPage extends StatefulWidget {
  const ConfigPage({
    required this.runtime,
    required this.descriptor,
    super.key,
  });
  final RuntimeController runtime;
  final Json descriptor;
  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> with WidgetsBindingObserver {
  late final state = ConfigurationEditingController(
    widget.runtime,
    namespace: widget.descriptor['ns'] as String,
    descriptor: widget.descriptor,
  );
  Json get accepted => state.accepted!;
  Json get draft => state.draft!;
  Json? get latest => state.latest;
  bool get busy => state.busy;
  String? localMessage;
  String? get message {
    final parts = [localMessage, state.error, state.notice].whereType<String>();
    return parts.isEmpty ? null : parts.join('\n');
  }

  Json? observedAccepted;
  ConfigurationReset? resetReview;
  final choices = <String, bool>{};
  bool structureOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    observedAccepted = accepted;
    state.addListener(runtimeChanged);
    unawaited(state.start());
  }

  void runtimeChanged() {
    if (!mounted) return;
    setState(() {
      if (!identical(observedAccepted, accepted)) {
        observedAccepted = accepted;
        choices.clear();
        resetReview = null;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) unawaited(state.refresh());
  }

  Json readDraft() => cloneConfiguration(draft);

  void replaceDraft(Json value) {
    state.replaceDraft(value, holdExternalDraft: false);
  }

  void edit(List<String> path, dynamic value, {bool remove = false}) {
    state.edit(path, value, remove: remove);
    setState(() => resetReview = null);
  }

  Future<void> editStructure(List<String> path, Json node, String title) async {
    if (!state.canEdit ||
        ConfigurationProtection(accepted).containsSecret(path)) {
      return;
    }
    // Freeze the editing baseline while the route owns its detached draft. A
    // remote update must become a reviewable conflict, never silently replace it.
    structureOpen = true;
    state.holdDraft(true);
    try {
      final field = ConfigurationFieldSchema(
        ConfigurationSchema(accepted['schema']),
        node,
      );
      final current = configurationValueAt(draft, path);
      final fallback = configurationHasValue(current)
          ? configurationValueAt(const {}, const ['missing'])
          : configurationInheritedValueAt(accepted, path, field);
      final result = await Navigator.of(context).push<ConfigurationFieldResult>(
        PocketRoute(
          builder: (_) => ConfigurationStructurePage(
            field: field,
            title: title,
            value: current,
            inheritedValue: fallback,
            hasInheritedValue: configurationHasValue(fallback),
            pendingReset:
                !configurationHasValue(current) &&
                configurationHasValue(
                  configurationValueAt(accepted['value'], path),
                ),
            allowReset: configurationHasValue(
              configurationValueAt(draft, path),
            ),
            namespace: accepted['ns'] as String,
            path: path,
            editingState: state,
            canEdit: () => state.canEdit,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null && state.canEdit) {
        edit(path, result.value, remove: result.remove);
      }
    } finally {
      structureOpen = false;
      if (mounted) {
        state.holdDraft(structureOpen);
      }
    }
  }

  Future<void> toggleEditor() async {
    if (!state.canEdit) return;
    structureOpen = true;
    state.holdDraft(true);
    try {
      final result = await Navigator.of(context).push<String>(
        PocketRoute(
          builder: (_) => TextDocumentPage(
            title: 'JSON 配置',
            text: _encoder.convert(readDraft()),
            readOnly: false,
            monospace: true,
            fieldKey: const Key('configuration-json'),
            editingState: state,
            canEdit: () => state.canEdit,
            helperText: '完成后返回配置草稿，仍需在配置页保存。已有凭据保持原保护。',
            validate: (text) {
              try {
                final candidate = configurationObject(jsonDecode(text));
                configurationEdits(accepted, candidate);
                return null;
              } catch (error) {
                return '配置无法应用到草稿：$error\n输入已保留。';
              }
            },
          ),
        ),
      );
      if (!mounted || result == null || !state.canEdit) return;
      replaceDraft(configurationObject(jsonDecode(result)));
      setState(() {
        localMessage = null;
      });
    } catch (error) {
      if (mounted) setState(() => localMessage = '未能更新草稿：$error');
    } finally {
      structureOpen = false;
      if (mounted) state.holdDraft(false);
    }
  }

  Future<void> readLatest() async {
    setState(() => localMessage = null);
    await state.refresh();
  }

  Future<void> save({List<Json>? operations}) async {
    setState(() => localMessage = null);
    try {
      if (operations == null) replaceDraft(readDraft());
      final saved = await state.save(operations: operations);
      if (!mounted) return;
      if (saved || !state.uncertain && !state.hasDraft) {
        setState(() {
          resetReview = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => localMessage = '未能保存：$error\n输入已保留。');
    }
  }

  void mergeLatest() {
    try {
      replaceDraft(readDraft());
      state.rebase(useLocal: Map.of(choices));
      setState(() {
        localMessage = null;
        resetReview = null;
      });
    } catch (error) {
      setState(() => localMessage = '$error\n输入已保留。');
    }
  }

  Widget comparison() {
    ConfigurationRebase? result;
    String? failure;
    try {
      result = rebaseConfiguration(accepted, readDraft(), latest!);
    } catch (error) {
      failure = '$error';
    }
    return PocketSection(
      title: '版本比较',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '编辑基于版本 ${accepted['revision']}，'
                '当前版本 ${latest!['revision']}。',
              ),
              const SizedBox(height: 12),
              if (failure != null) Text(failure),
              if (result != null && result.conflicts.isEmpty)
                const Text('没有同一字段的冲突，可以保留双方修改。'),
              for (final conflict
                  in result?.conflicts ?? <ConfigurationConflict>[]) ...[
                const SizedBox(height: 18),
                Text(
                  configurationPathLabel(conflict.path),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '原值：${configurationValueLabel(conflict.before)}\n'
                  '我的修改：${configurationValueLabel(conflict.local)}\n'
                  '最新值：${configurationValueLabel(conflict.remote)}',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    PocketChoice(
                      label: const Text('保留我的修改'),
                      selected: choices[conflict.id] == true,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => choices[conflict.id] = true),
                    ),
                    PocketChoice(
                      label: const Text('采用最新值'),
                      selected: choices[conflict.id] == false,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => choices[conflict.id] = false),
                    ),
                  ],
                ),
              ],
              TextDocumentRow(
                title: '查看最新配置（凭据已隐藏）',
                text: _encoder.convert(latest!['value']),
                monospace: true,
                selectable: true,
              ),
              PocketButton.tonal(
                onPressed:
                    busy || !state.fresh || state.uncertain || failure != null
                    ? null
                    : mergeLatest,
                child: const Text('合并到草稿'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> openAdvanced() => Navigator.of(context).push<void>(
    PocketRoute(
      builder: (advancedContext) => StatefulBuilder(
        builder: (context, update) => ListenableBuilder(
          listenable: state,
          builder: (context, _) => PocketScaffold(
            title: const Text('高级设置'),
            body: PocketList(children: advancedItems(advancedContext, update)),
          ),
        ),
      ),
    ),
  );

  List<ConfigurationFieldGroup> get fieldGroups {
    final presentation = ConfigurationPresentation(accepted['ns'] as String);
    if (presentation.groups.isEmpty) return const [];
    final paths = _fields(ConfigurationSchema(accepted['schema']))
        .map((field) => field.path.join('.'))
        .toSet();
    final groups = presentation.groups
        .where((group) => group.paths.any(paths.contains))
        .toList();
    final assigned = groups.expand((group) => group.paths).toSet();
    final other = paths.difference(assigned);
    if (other.isNotEmpty) {
      // A newer runtime can introduce fields before the App has presentation
      // metadata for them. Keep their schema-driven controls reachable.
      groups.add(
        ConfigurationFieldGroup(
          id: 'other',
          title: '其他设置',
          summary: '当前运行时提供的其他参数',
          description: '这些参数由当前运行时提供。修改方式及可用范围遵循它们的配置说明。',
          symbol: ConfigurationGroupSymbol.settings,
          paths: other,
        ),
      );
    }
    return groups;
  }

  Widget groupDirectory(List<ConfigurationFieldGroup> groups) => PocketSection(
    divided: true,
    children: [
      for (final group in groups)
        PocketRow(
          key: ValueKey('configuration-group:${group.id}'),
          icon: switch (group.symbol) {
            ConfigurationGroupSymbol.shell => Icons.terminal_rounded,
            ConfigurationGroupSymbol.search => Icons.search_rounded,
            ConfigurationGroupSymbol.folder => Icons.folder_outlined,
            ConfigurationGroupSymbol.attachment => Icons.attach_file_rounded,
            ConfigurationGroupSymbol.stream => Icons.sync_rounded,
            ConfigurationGroupSymbol.shutdown => Icons.power_settings_new,
            ConfigurationGroupSymbol.settings => Icons.tune_rounded,
          },
          title: group.title,
          subtitle: group.summary,
          onTap: () => openGroup(group),
        ),
    ],
  );

  Future<void> openGroup(ConfigurationFieldGroup group) {
    final settingsRoute = ModalRoute.of(context);
    return Navigator.of(context).push<void>(
      PocketRoute(
        builder: (groupContext) => ListenableBuilder(
          listenable: state,
          builder: (context, _) => PocketScaffold(
            title: Text(group.title),
            body: PocketList(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                  child: Text(group.description),
                ),
                if (state.conflict || state.uncertain || message != null)
                  PocketSection(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          state.uncertain
                              ? '保存结果仍需核对。当前草稿已保留，请返回配置页处理。'
                              : state.conflict
                              ? '配置有新版本。当前草稿已保留，请返回配置页比较后再保存。'
                              : message!,
                          key: const Key('configuration-group-message'),
                        ),
                      ),
                      PocketRow(
                        icon: Icons.arrow_back_rounded,
                        title: '返回配置页',
                        onTap: () => Navigator.of(groupContext).popUntil(
                          (route) => route == settingsRoute || route.isFirst,
                        ),
                      ),
                    ],
                  ),
                ConfigurationFields(
                  descriptor: accepted,
                  value: draft,
                  paths: group.paths,
                  enabled: state.canEdit,
                  onOpen: editStructure,
                  onChanged: (path, value) => edit(path, value),
                  onReset: (path) => edit(path, null, remove: true),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '修改后返回${configurationNamespaceTitle(accepted['ns'] as String)}页统一保存。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> advancedItems(
    BuildContext advancedContext,
    StateSetter update,
  ) => [
    if (fieldGroups.any((group) => group.advanced))
      groupDirectory(fieldGroups.where((group) => group.advanced).toList()),
    PocketSection(
      title: '版本与默认值',
      children: [
        PocketRow(
          icon: Icons.code_rounded,
          title: '高级 JSON 编辑',
          onTap: state.canEdit
              ? () async {
                  await toggleEditor();
                  if (advancedContext.mounted) {
                    Navigator.of(advancedContext).pop();
                  }
                }
              : null,
        ),
        TextDocumentRow(
          title: '配置说明',
          text:
              '只保存修改的字段。已有凭据及包含凭据的内容会保留，请在凭据入口单独管理。\n\n${accepted['ns']} · 版本 ${accepted['revision']}',
        ),
        PocketRow(
          icon: Icons.sync_rounded,
          title: '读取最新版本并比较',
          subtitle: '保留正在编辑的草稿',
          onTap: busy ? null : readLatest,
        ),
        PocketRow(
          icon: Icons.restore_rounded,
          title: '恢复普通参数默认值',
          subtitle: '先查看将恢复的参数；保留凭据和含凭据数组',
          onTap:
              !state.canEdit ||
                  !state.fresh ||
                  !state.writable ||
                  state.conflict
              ? null
              : () => update(() => resetReview = configurationReset(accepted)),
        ),
      ],
    ),
    if (resetReview != null)
      PocketSection(
        title: '确认恢复范围',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  resetReview!.operations.isEmpty
                      ? '没有可恢复的普通参数覆盖。'
                      : '以下参数将恢复为继承值或默认值：\n'
                            '${resetReview!.operations.map((op) => configurationPathLabel((op['path'] as List).cast<String>())).join('\n')}',
                ),
                if (resetReview!.preserved.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '继续保留：\n'
                    '${resetReview!.preserved.map(configurationPathLabel).join('\n')}',
                  ),
                ],
                const SizedBox(height: 12),
                const Text('恢复成功后，当前页面的未保存草稿将被默认值替换。'),
                PocketButton(
                  onPressed:
                      busy ||
                          !state.fresh ||
                          !state.writable ||
                          state.conflict ||
                          state.uncertain ||
                          resetReview!.operations.isEmpty
                      ? null
                      : () => save(operations: resetReview!.operations),
                  child: const Text('确认恢复这些普通参数'),
                ),
                PocketButton.tonal(
                  onPressed: busy
                      ? null
                      : () => update(() => resetReview = null),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ],
      ),
  ];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(runtimeChanged);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => state.hasDraft,
    busy: busy,
    child: PocketScaffold(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(configurationNamespaceTitle('${accepted['ns']}')),
          const SizedBox(height: 2),
          Text(
            state.hasDraft ? '未保存' : '',
            style: TextStyle(
              fontSize: 11,
              height: 1,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: GlassButton(
        key: const Key('configuration-save'),
        icon: Icons.check_rounded,
        label: '保存并应用',
        solid: true,
        onPressed: state.canSave ? save : null,
      ),
      body: PocketList(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
              child: SelectableText(
                message!,
                key: const Key('configuration-message'),
              ),
            ),
          if (state.uncertain)
            PocketSection(
              title: '核对保存结果',
              children: [
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('尚未取得有效回执。请继续核对，或确认采用当前配置并放弃此次草稿。'),
                ),
                if (latest != null)
                  TextDocumentRow(
                    title: '查看当前配置（凭据已隐藏）',
                    subtitle:
                        '版本 ${latest!['revision']}${state.fresh ? '' : ' · 等待重新核对'}',
                    text: _encoder.convert(latest!['value']),
                    monospace: true,
                    selectable: true,
                  ),
                PocketRow(
                  icon: Icons.sync_rounded,
                  title: '继续核对',
                  onTap: busy || state.loading ? null : readLatest,
                ),
                PocketRow(
                  icon: Icons.undo_rounded,
                  title: '采用当前配置',
                  onTap: !state.fresh || busy
                      ? null
                      : () {
                          state.discardDraft();
                          setState(() => localMessage = null);
                        },
                ),
              ],
            )
          else if (latest != null)
            comparison(),
          if (fieldGroups.any((group) => !group.advanced))
            groupDirectory(
              fieldGroups.where((group) => !group.advanced).toList(),
            )
          else if (fieldGroups.isEmpty)
            ConfigurationFields(
              key: const ValueKey('configuration-fields'),
              descriptor: accepted,
              value: draft,
              enabled: state.canEdit,
              onOpen: editStructure,
              onChanged: (path, value) => edit(path, value),
              onReset: (path) => edit(path, null, remove: true),
            ),
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.tune_rounded,
                title: '高级设置',
                onTap: openAdvanced,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

String configurationNamespaceTitle(String namespace) {
  // Exact host entry IDs from the bundled profiles. In particular, ui-* forms
  // configure the original Web client, not Pocket Harness's native appearance.
  const names = {
    'session-log-deepseek': '会话日志上传',
    'agent-loop': 'Agent 执行',
    'agent-default-model': '默认会话模型',
    'llm-deepseek': 'DeepSeek API 密钥接入',
    'llm-deepseek-account': 'DeepSeek 账号模型接入',
    'llm-pi-ai': '兼容模型服务',
    'subagent': '子 Agent',
    'subagent-model-selection-settings': '子 Agent 模型选择',
    'web': '联网工具',
    'web-search-deepseek': 'DeepSeek 搜索',
    'web-deepseek-api': 'DeepSeek 联网服务',
    'web-search-exa': 'Exa 搜索',
    'web-fetch-http': '网页读取',
    'android-runtime': 'Android 工具',
    'ui-settings-account': '原版桌面引导记录',
    'ui-theme': 'Web 主题与字体',
    'ui-settings': '开发者工具',
    'ui-conversation': 'Web 繁忙时发送行为',
    'ui-chat': 'Web 聊天展示',
  };
  // Unknown plugins keep their identity instead of receiving an ambiguous or
  // potentially incorrect title inferred from a substring of their entry ID.
  return names[namespace] ?? namespace;
}

class _Field {
  const _Field(this.path, this.node, this.kind, [this.options = const []]);
  final List<String> path;
  final Json node;
  final String kind;
  final List<dynamic> options;
  String? get description {
    final description = (node['meta'] as Map?)?['description'];
    if (description is String) return description;
    if (description is Map) {
      return (description['zh-CN'] ??
              description['zh'] ??
              description['en-US'] ??
              description[''])
          as String?;
    }
    return null;
  }
}

List<_Field> _fields(ConfigurationSchema schema) {
  final fields = <_Field>[];
  void visit(Json node, List<String> path, int depth) {
    if (depth > 12) return;
    final type = node['type'];
    if ((node['meta'] as Map?)?['role'] == 'secret') {
      if (path.isNotEmpty) fields.add(_Field(path, node, 'secret'));
      return;
    }
    if (type == 'object') {
      if (path.isNotEmpty && !schema.containsSecret(node)) {
        fields.add(_Field(path, node, 'structure'));
        return;
      }
      for (final entry in (node['dict'] as Map? ?? {}).entries) {
        visit(schema.resolve(entry.value), [
          ...path,
          '${entry.key}',
        ], depth + 1);
      }
    } else if (type == 'transform') {
      if (path.isNotEmpty) fields.add(_Field(path, node, 'complex'));
    } else if (type == 'intersect' && path.isEmpty) {
      final combined = ConfigurationFieldSchema(schema, node);
      if (combined.objectIntersection) {
        for (final entry in combined.fields.entries) {
          visit(entry.value.node, [entry.key], depth + 1);
        }
      }
    } else if (type == 'union' && path.isNotEmpty) {
      final alternatives = [
        for (final child in node['list'] as List? ?? []) schema.resolve(child),
      ];
      final simple =
          alternatives.isNotEmpty &&
          alternatives.every((item) => item['type'] == 'const');
      fields.add(
        _Field(path, node, simple ? 'choice' : 'complex', [
          if (simple)
            for (final item in alternatives) item['value'],
        ]),
      );
    } else if (path.isNotEmpty) {
      fields.add(
        _Field(
          path,
          node,
          const ['string', 'number', 'boolean'].contains(type)
              ? type as String
              : const ['array', 'dict'].contains(type)
              ? 'structure'
              : 'complex',
        ),
      );
    }
  }

  visit(schema.root, [], 0);
  final unique = <String, _Field>{};
  for (final field in fields) {
    unique[jsonEncode(field.path)] = field;
  }
  return unique.values.toList();
}

class ConfigurationFields extends StatelessWidget {
  const ConfigurationFields({
    super.key,
    required this.descriptor,
    required this.value,
    required this.enabled,
    required this.onOpen,
    required this.onChanged,
    this.onReset,
    this.paths,
  });
  final Json descriptor, value;
  final bool enabled;
  final Set<String>? paths;
  final void Function(List<String>, Json, String) onOpen;
  final void Function(List<String>, dynamic) onChanged;
  final void Function(List<String>)? onReset;

  @override
  Widget build(BuildContext context) {
    final protection = ConfigurationProtection(descriptor);
    final fields = _fields(protection.schema)
        .where(
          (field) => paths == null || paths!.contains(field.path.join('.')),
        )
        .toList();
    final presentation = ConfigurationPresentation(descriptor['ns'] as String);
    if (fields.isEmpty) {
      return PocketSection(
        children: [
          const PocketTile(
            title: Text('当前配置由插件管理'),
            subtitle: Text('此插件尚未提供普通设置；原有值保持不变。'),
          ),
        ],
      );
    }
    return PocketSection(
      key: const Key('configuration-values'),
      divided: true,
      children: [
        for (final field in fields)
          _row(context, field, protection, presentation),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    _Field item,
    ConfigurationProtection protection,
    ConfigurationPresentation presentation,
  ) {
    final schema = ConfigurationFieldSchema(protection.schema, item.node);
    final title = presentation.title(item.path, schema);
    final current = configurationValueAt(value, item.path);
    final isProtected = protection.containsSecret(item.path);
    final key = ValueKey('configuration-field:${jsonEncode(item.path)}');
    final fallback = !configurationHasValue(current)
        ? configurationInheritedValueAt(descriptor, item.path, schema)
        : configurationValueAt(const {}, const ['missing']);
    if (descriptor['ns'] == 'agent-loop' &&
        item.path.length == 1 &&
        item.path.single == 'maxParallelToolCalls' &&
        schema.type == 'number' &&
        !isProtected) {
      final effective = current is num ? current : fallback;
      if (effective is num &&
          effective.isFinite &&
          effective % 1 == 0 &&
          schema.validate(effective) == null) {
        final override = configurationHasValue(
          configurationValueAt(descriptor['user'], item.path),
        );
        final staged = !configurationEqual(
          current,
          configurationValueAt(descriptor['value'], item.path),
        );
        return Column(
          key: key,
          children: [
            ConfigurationValueRow(
              title: title,
              summary: !configurationHasValue(current)
                  ? '${effective.toInt()} · 恢复后使用默认值'
                  : staged
                  ? '${effective.toInt()} · 待保存'
                  : override
                  ? '${effective.toInt()} · 自定义'
                  : '${effective.toInt()} · 默认值',
              onTap: enabled ? () => onOpen(item.path, item.node, title) : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlassButton(
                    key: const Key('agent-loop-parallel-decrease'),
                    icon: Icons.remove_rounded,
                    label: '减少并行调用数',
                    onPressed: enabled && schema.validate(effective - 1) == null
                        ? () => onChanged(item.path, effective - 1)
                        : null,
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '${effective.toInt()}',
                        key: const Key('agent-loop-parallel-value'),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  ),
                  GlassButton(
                    key: const Key('agent-loop-parallel-increase'),
                    icon: Icons.add_rounded,
                    label: '增加并行调用数',
                    onPressed: enabled && schema.validate(effective + 1) == null
                        ? () => onChanged(item.path, effective + 1)
                        : null,
                  ),
                ],
              ),
            ),
            if (presentation.description(item.path, schema) case final hint?)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ),
            if (configurationHasValue(current) &&
                (override || staged) &&
                onReset != null)
              PocketTile(
                key: const Key('agent-loop-parallel-reset'),
                title: const Text('恢复默认值'),
                onTap: enabled ? () => onReset!(item.path) : null,
              ),
          ],
        );
      }
    }
    final inherited = fallback is bool ? fallback : null;
    if (schema.booleanChoice &&
        (current is bool || inherited != null) &&
        !isProtected) {
      final hint = presentation.description(item.path, schema);
      final resetPending =
          inherited != null &&
          configurationHasValue(
            configurationValueAt(descriptor['value'], item.path),
          );
      return PocketSwitchRow(
        key: key,
        title: Text(title),
        subtitle: hint == null && inherited == null
            ? null
            : Text(
                [
                  if (inherited != null) resetPending ? '恢复后使用' : '使用默认值',
                  ?hint,
                ].join(' · '),
              ),
        value: current is bool ? current : inherited!,
        onChanged: enabled ? (next) => onChanged(item.path, next) : null,
      );
    }
    return ConfigurationValueRow(
      key: key,
      title: title,
      summary: _summary(item, protection, presentation),
      protected: isProtected,
      onTap: enabled && !isProtected
          ? () => onOpen(item.path, item.node, title)
          : null,
    );
  }

  String _summary(
    _Field field,
    ConfigurationProtection protection,
    ConfigurationPresentation presentation,
  ) {
    if (field.kind == 'secret') {
      final configured = (descriptor['secrets'] as List? ?? []).any(
        (slot) =>
            configurationEqual(slot['path'], field.path) && slot['set'] == true,
      );
      return configured ? '已配置 · 凭据中管理' : '未配置 · 凭据中管理';
    }
    if (protection.containsSecret(field.path)) return '包含凭据 · 已保护';
    final current = configurationValueAt(value, field.path);
    if (!configurationHasValue(current)) {
      final schema = ConfigurationFieldSchema(protection.schema, field.node);
      final fallback = configurationInheritedValueAt(
        descriptor,
        field.path,
        schema,
      );
      if (configurationHasValue(fallback)) {
        final resetPending = configurationHasValue(
          configurationValueAt(descriptor['value'], field.path),
        );
        final valueLabel =
            fallback is String &&
                (fallback.contains('\n') || fallback.length > 80)
            ? '${fallback.length} 个字符'
            : presentation.option(field.path, fallback);
        return '$valueLabel · '
            '${resetPending ? '恢复后使用' : '使用默认值'}';
      }
      return '使用默认值';
    }
    if (current is String && (current.contains('\n') || current.length > 80)) {
      return '${current.length} 个字符';
    }
    return presentation.option(field.path, current);
  }
}
