import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_state.dart';
import 'models.dart' show ModelDraftGuard;
import 'runtime.dart';
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

  late final editor = TextEditingController(text: _encoder.convert(draft));
  Json? observedDraft, observedAccepted;
  ConfigurationReset? resetReview;
  final choices = <String, bool>{};
  final invalidFields = <String, String>{};
  final fieldVersions = <String, int>{};
  bool advanced = false, rawDirty = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    observedDraft = draft;
    observedAccepted = accepted;
    state.addListener(runtimeChanged);
    unawaited(state.start());
  }

  void runtimeChanged() {
    if (!mounted) return;
    setState(() {
      if (!identical(observedDraft, draft)) {
        observedDraft = draft;
        if (!rawDirty) editor.text = _encoder.convert(draft);
      }
      if (!identical(observedAccepted, accepted)) {
        observedAccepted = accepted;
        if (!rawDirty) {
          invalidFields.clear();
          fieldVersions.clear();
          generation++;
        }
        choices.clear();
        resetReview = null;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) unawaited(state.refresh());
  }

  Json readDraft() => advanced
      ? configurationObject(jsonDecode(editor.text))
      : cloneConfiguration(draft);

  void replaceDraft(Json value) {
    state.replaceDraft(value, holdExternalDraft: false);
    rawDirty = false;
    editor.text = _encoder.convert(value);
    invalidFields.clear();
    fieldVersions.clear();
    generation++;
  }

  void edit(List<String> path, dynamic value, {bool remove = false}) {
    state.edit(path, value, remove: remove);
    setState(() => resetReview = null);
  }

  void toggleEditor() {
    try {
      final value = readDraft();
      setState(() {
        if (advanced) replaceDraft(value);
        advanced = !advanced;
        localMessage = null;
      });
    } catch (error) {
      setState(() => localMessage = 'JSON 无法解析：$error\n输入已保留。');
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
          rawDirty = false;
          editor.text = _encoder.convert(draft);
          invalidFields.clear();
          fieldVersions.clear();
          generation++;
          resetReview = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => localMessage = '未能保存：$error\n输入已保留。');
    }
  }

  void mergeLatest() {
    if (invalidFields.isNotEmpty) {
      setState(() => localMessage = '请先修正表单中的无效输入；草稿尚未合并。');
      return;
    }
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
              PocketDisclosure(
                title: '查看最新配置（凭据已隐藏）',
                child: SelectableText(_encoder.convert(latest!['value'])),
              ),
              PocketButton.tonal(
                onPressed:
                    busy ||
                        !state.fresh ||
                        state.uncertain ||
                        failure != null ||
                        invalidFields.isNotEmpty
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(runtimeChanged);
    state.dispose();
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => state.hasDraft || rawDirty || invalidFields.isNotEmpty,
    busy: busy,
    child: PocketScaffold(
      title: Text(configurationNamespaceTitle('${accepted['ns']}')),
      bottom: PocketButton(
        onPressed:
            busy ||
                !state.fresh ||
                !state.writable ||
                state.conflict ||
                state.uncertain ||
                invalidFields.isNotEmpty
            ? null
            : save,
        child: Text(
          busy
              ? '正在处理'
              : state.uncertain
              ? '请先核对保存结果'
              : !state.fresh
              ? '请先刷新配置'
              : state.conflict
              ? '请先比较并合并'
              : !state.writable
              ? '配置不可写'
              : '保存并应用',
        ),
      ),
      body: PocketList(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
            child: Row(
              children: [
                const Expanded(child: Text('调整后保存生效')),
                const SizedBox(width: 12),
                PocketButton.tonal(
                  onPressed: !state.canEdit || invalidFields.isNotEmpty
                      ? null
                      : toggleEditor,
                  child: Text(advanced ? '返回表单' : '高级 JSON 编辑'),
                ),
              ],
            ),
          ),
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
                  PocketDisclosure(
                    title: '查看当前配置（凭据已隐藏）',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '版本 ${latest!['revision']}${state.fresh ? '' : ' · 等待重新核对'}',
                        ),
                        const SizedBox(height: 12),
                        SelectableText(_encoder.convert(latest!['value'])),
                      ],
                    ),
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
                          rawDirty = false;
                          state.discardDraft();
                          editor.text = _encoder.convert(draft);
                          setState(() => localMessage = null);
                        },
                ),
              ],
            )
          else if (latest != null)
            comparison(),
          if (advanced)
            PocketSection(
              title: '高级参数',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    key: const Key('configuration-json'),
                    controller: editor,
                    enabled: state.canEdit,
                    minLines: 12,
                    maxLines: 24,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    onChanged: (_) {
                      rawDirty = editor.text != _encoder.convert(draft);
                      state.holdDraft(rawDirty || invalidFields.isNotEmpty);
                      setState(() => resetReview = null);
                    },
                    decoration: const InputDecoration(
                      labelText: 'JSON 配置',
                      helperText: '移除普通字段表示将该字段恢复为继承值或默认值。',
                      helperMaxLines: 3,
                    ),
                  ),
                ),
              ],
            )
          else
            ConfigurationFields(
              key: ValueKey(generation),
              descriptor: accepted,
              value: draft,
              enabled: state.canEdit,
              fieldVersions: fieldVersions,
              onEdit: (path, value) => edit(path, value),
              onRemove: (path) {
                edit(path, null, remove: true);
                setState(() {
                  final id = jsonEncode(path);
                  fieldVersions[id] = (fieldVersions[id] ?? 0) + 1;
                  invalidFields.remove(id);
                  state.holdDraft(rawDirty || invalidFields.isNotEmpty);
                });
              },
              onError: (path, error) {
                setState(() {
                  final id = jsonEncode(path);
                  if (error == null) {
                    invalidFields.remove(id);
                  } else {
                    invalidFields[id] = error;
                  }
                  state.holdDraft(rawDirty || invalidFields.isNotEmpty);
                });
              },
              onAdvanced: toggleEditor,
            ),
          PocketSection(
            title: '版本与默认值',
            children: [
              PocketDisclosure(
                title: '配置说明',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('只保存修改的字段。已有凭据及包含凭据的内容会保留，请在凭据入口单独管理。'),
                    const SizedBox(height: 12),
                    Text(
                      '${accepted['ns']} · 版本 ${accepted['revision']}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
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
                    : () => setState(
                        () => resetReview = configurationReset(accepted),
                      ),
              ),
            ],
          ),
          if (resetReview != null)
            PocketSection(
              title: '确认恢复范围',
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 12,
                  ),
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
                            : () => setState(() => resetReview = null),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
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
    'session-log-deepseek': 'DeepSeek 会话记录',
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
    'ui-settings-account': 'Web 账号界面',
    'ui-theme': 'Web 主题与字体',
    'ui-settings': 'Web 开发者工具',
    'ui-conversation': 'Web 繁忙时发送行为',
    'ui-chat': 'Web 聊天展示',
  };
  // Unknown plugins keep their identity instead of receiving an ambiguous or
  // potentially incorrect title inferred from a substring of their entry ID.
  return names[namespace] ?? namespace;
}

const _fieldLabels = {
  'baseURL': '服务地址',
  'provider': '模型提供方',
  'model': '模型 ID',
  'models': '模型目录',
  'thinking': '思考模式',
  'reasoningEffort': '思考强度',
  'maxTokens': '最大输出 Token',
  'defaultContextWindow': '默认上下文容量',
  'streamIdleTimeoutMs': '流式响应空闲超时（毫秒）',
  'retryPolicy': '请求重试策略',
  'selectedDefault': '默认 Agent 预设 ID',
  'cwd': '工作目录',
  'timeoutMs': '默认超时（毫秒）',
  'maxTimeoutMs': '最大超时（毫秒）',
  'maxOutputBytes': '输出保留上限（字节）',
  'maxSpillBytes': '输出文件上限（字节）',
  'graceMs': '进程退出宽限（毫秒）',
  'searchProvider': '搜索提供方 ID',
  'fetchProvider': '网页读取提供方 ID',
  'apiKey': 'API Key',
  'apiKeyEnv': '凭据引用名称',
  'maxUses': '单次请求最大搜索次数',
  'apiVersion': 'API 版本',
  'enableRunInBackground': '允许后台执行',
  'promoteOnTimeout': '超时后转为后台任务',
};

class _Field {
  const _Field(this.path, this.node, this.kind, [this.options = const []]);
  final List<String> path;
  final Json node;
  final String kind;
  final List<dynamic> options;
  String get title => _fieldLabels[path.last] ?? path.last;
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
      for (final entry in (node['dict'] as Map? ?? {}).entries) {
        visit(schema.resolve(entry.value), [
          ...path,
          '${entry.key}',
        ], depth + 1);
      }
    } else if (type == 'transform') {
      visit(schema.resolve(node['inner']), path, depth + 1);
    } else if (type == 'intersect' && path.isEmpty) {
      for (final child in node['list'] as List? ?? []) {
        visit(schema.resolve(child), path, depth + 1);
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
    required this.fieldVersions,
    required this.onEdit,
    required this.onRemove,
    required this.onError,
    required this.onAdvanced,
  });
  final Json descriptor, value;
  final bool enabled;
  final Map<String, int> fieldVersions;
  final void Function(List<String>, dynamic) onEdit;
  final void Function(List<String>) onRemove;
  final void Function(List<String>, String?) onError;
  final VoidCallback onAdvanced;

  @override
  Widget build(BuildContext context) {
    final protection = ConfigurationProtection(descriptor);
    final fields = _fields(protection.schema);
    if (fields.isEmpty) {
      return PocketSection(
        children: [
          PocketRow(
            icon: Icons.data_object_rounded,
            title: '此配置需要使用高级编辑',
            subtitle: '当前 schema 未提供可直接编辑的字段。',
            onTap: enabled ? onAdvanced : null,
          ),
        ],
      );
    }
    return Column(
      children: [
        for (final field in fields)
          PocketSection(
            title: field.title,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                child: _ConfigurationField(
                  key: ValueKey(
                    '${jsonEncode(field.path)}:${fieldVersions[jsonEncode(field.path)] ?? 0}',
                  ),
                  field: field,
                  value: configurationValueAt(value, field.path),
                  configured: (descriptor['secrets'] as List? ?? []).any(
                    (slot) =>
                        configurationEqual(slot['path'], field.path) &&
                        slot['set'] == true,
                  ),
                  protected: protection.containsSecret(field.path),
                  enabled: enabled,
                  onChanged: (next) => onEdit(field.path, next),
                  onRemove: () => onRemove(field.path),
                  onError: (error) => onError(field.path, error),
                  onAdvanced: onAdvanced,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ConfigurationField extends StatefulWidget {
  const _ConfigurationField({
    super.key,
    required this.field,
    required this.value,
    required this.configured,
    required this.protected,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
    required this.onError,
    required this.onAdvanced,
  });
  final _Field field;
  final dynamic value;
  final bool configured, protected, enabled;
  final ValueChanged<dynamic> onChanged;
  final VoidCallback onRemove, onAdvanced;
  final ValueChanged<String?> onError;
  @override
  State<_ConfigurationField> createState() => _ConfigurationFieldState();
}

class _ConfigurationFieldState extends State<_ConfigurationField> {
  late final controller = TextEditingController(
    text: configurationHasValue(widget.value) ? '${widget.value}' : '',
  );
  String? error;

  void changed(String value) {
    dynamic parsed = value;
    String? failure;
    if (widget.field.kind == 'number') {
      parsed = num.tryParse(value);
      final meta = widget.field.node['meta'] as Map? ?? {};
      if (parsed == null || !(parsed as num).isFinite) {
        failure = '请输入有效数字。';
      } else if (meta['min'] is num && parsed < meta['min']) {
        failure = '不能小于 ${meta['min']}。';
      } else if (meta['max'] is num && parsed > meta['max']) {
        failure = '不能大于 ${meta['max']}。';
      } else if (meta['step'] == 1 && parsed % 1 != 0) {
        failure = '请输入整数。';
      }
    }
    setState(() => error = failure);
    widget.onError(failure);
    if (failure == null) widget.onChanged(parsed);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final exists = configurationHasValue(widget.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (field.path.length > 1) ...[
          Text(configurationPathLabel(field.path)),
          const SizedBox(height: 8),
        ],
        if (field.description != null) ...[
          Text(field.description!),
          const SizedBox(height: 12),
        ],
        if (field.kind == 'secret' || widget.protected)
          Text(
            field.kind == 'secret'
                ? (widget.configured ? '已配置；值已隐藏，请在凭据入口管理。' : '未配置；请在凭据入口管理。')
                : '此结构包含凭据，保留现有值。通用编辑器不能替换或重排。',
          )
        else if (field.kind == 'boolean')
          PocketSwitchRow(
            contentPadding: EdgeInsets.zero,
            title: Text(
              exists ? (widget.value == true ? '已开启' : '已关闭') : '使用默认值',
            ),
            value: widget.value == true,
            onChanged: widget.enabled ? widget.onChanged : null,
          )
        else if (field.kind == 'choice')
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final option in field.options)
                PocketChoice(
                  label: Text('$option'),
                  selected: exists && configurationEqual(widget.value, option),
                  onSelected: widget.enabled
                      ? (_) => widget.onChanged(option)
                      : null,
                ),
            ],
          )
        else if (field.kind == 'string' || field.kind == 'number')
          TextField(
            key: ValueKey('configuration-field:${jsonEncode(field.path)}'),
            controller: controller,
            enabled: widget.enabled,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: field.kind == 'number'
                ? const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  )
                : TextInputType.text,
            minLines: 1,
            maxLines: field.kind == 'string' ? 4 : 1,
            decoration: InputDecoration(
              labelText: field.title,
              hintText: '未设置，使用默认值',
              errorText: error,
            ),
            onChanged: changed,
          )
        else ...[
          SelectableText(
            exists ? _encoder.convert(widget.value) : '尚未设置',
            style: const TextStyle(fontSize: 12),
          ),
          PocketButton.tonal(
            onPressed: widget.enabled ? widget.onAdvanced : null,
            child: const Text('在高级编辑中修改此结构'),
          ),
        ],
        if (!widget.protected && field.kind != 'secret' && exists)
          Align(
            alignment: Alignment.centerLeft,
            child: PocketButton.tonal(
              onPressed: widget.enabled ? widget.onRemove : null,
              child: const Text('使用默认值'),
            ),
          ),
      ],
    );
  }
}
