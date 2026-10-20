import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
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

class _ConfigPageState extends State<ConfigPage> {
  late Json accepted = cloneConfiguration(widget.descriptor);
  late Json draft = cloneConfiguration(configurationObject(accepted['value']));
  late final editor = TextEditingController(text: _encoder.convert(draft));
  Json? latest;
  ConfigurationReset? resetReview;
  final choices = <String, bool>{};
  final invalidFields = <String, String>{};
  final fieldVersions = <String, int>{};
  bool busy = false, advanced = false;
  int generation = 0;
  String? message;

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(runtimeChanged);
  }

  void runtimeChanged() {
    for (final form in widget.runtime.forms) {
      if (form['ns'] == accepted['ns'] &&
          form['revision'] != accepted['revision'] &&
          form['revision'] != latest?['revision']) {
        if (mounted) {
          setState(() {
            latest = cloneConfiguration(form);
            choices.clear();
          });
        }
      }
    }
  }

  Json readDraft() => advanced
      ? configurationObject(jsonDecode(editor.text))
      : cloneConfiguration(draft);

  void replaceDraft(Json value) {
    draft = cloneConfiguration(value);
    editor.text = _encoder.convert(draft);
    invalidFields.clear();
    fieldVersions.clear();
    generation++;
  }

  void edit(List<String> path, dynamic value, {bool remove = false}) {
    setState(() {
      applyConfigurationEdit(draft, {
        'op': remove ? 'unset' : 'set',
        'path': path,
        if (!remove) 'value': value,
      });
      editor.text = _encoder.convert(draft);
      resetReview = null;
    });
  }

  void toggleEditor() {
    try {
      final value = readDraft();
      setState(() {
        if (advanced) replaceDraft(value);
        advanced = !advanced;
        message = null;
      });
    } catch (error) {
      setState(() => message = 'JSON 无法解析：$error\n输入已保留。');
    }
  }

  Future<void> readLatest() async {
    setState(() => busy = true);
    try {
      final forms = (await widget.runtime.call('settings.describe') as List)
          .cast<Json>();
      final remote = forms.firstWhere((form) => form['ns'] == accepted['ns']);
      if (!mounted) return;
      setState(() {
        latest = cloneConfiguration(remote);
        choices.clear();
        message = remote['revision'] == accepted['revision']
            ? '当前版本未变化，草稿已保留。'
            : '配置已在其他入口更新。请比较并合并，草稿已保留。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => message = '无法读取最新配置：$error\n输入已保留。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save({List<Json>? operations}) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final ops = operations ?? configurationEdits(accepted, readDraft());
      if (ops.isEmpty) {
        setState(() => message = '没有需要保存的修改。');
        return;
      }
      final forms = (await widget.runtime.call('settings.mutate', {
        'ns': accepted['ns'],
        'revision': accepted['revision'],
        'ops': ops,
      }) as List).cast<Json>();
      final saved = forms.firstWhere((form) => form['ns'] == accepted['ns']);
      if (!mounted) return;
      setState(() {
        accepted = cloneConfiguration(saved);
        replaceDraft(configurationObject(saved['value']));
        latest = null;
        choices.clear();
        resetReview = null;
        message = '已保存并应用。';
      });
      try {
        await widget.runtime.refreshForms();
      } catch (error) {
        if (mounted) {
          setState(() => message = '配置已保存；设置列表刷新失败：$error');
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = '未能保存：$error\n输入已保留。');
      }
      // Read after any failed write: error text is not a reliable conflict tag.
      try {
        final forms = (await widget.runtime.call('settings.describe') as List)
            .cast<Json>();
        final remote = forms.firstWhere((form) => form['ns'] == accepted['ns']);
        if (mounted && remote['revision'] != accepted['revision']) {
          setState(() {
            latest = cloneConfiguration(remote);
            choices.clear();
            resetReview = null;
            message =
                '配置已在其他入口更新；此次保存没有覆盖新版本。'
                '\n输入已保留，请比较并合并后重新保存。';
          });
        }
      } catch (refreshError) {
        if (mounted) {
          setState(() {
            message = '$message\n无法核对最新版本：$refreshError';
          });
        }
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void mergeLatest() {
    if (invalidFields.isNotEmpty) {
      setState(() => message = '请先修正表单中的无效输入；草稿尚未合并。');
      return;
    }
    try {
      final result = rebaseConfiguration(
        accepted,
        readDraft(),
        latest!,
        useLocal: choices,
      );
      if (result.conflicts.isNotEmpty) {
        setState(() => message = '请先为每一处冲突选择要保留的内容。');
        return;
      }
      setState(() {
        accepted = cloneConfiguration(latest!);
        replaceDraft(result.value);
        latest = null;
        choices.clear();
        resetReview = null;
        message = '已合并到草稿，尚未保存；其他入口的无关修改已保留。';
      });
    } catch (error) {
      setState(() => message = '$error\n输入已保留。');
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
                onPressed: busy || failure != null || invalidFields.isNotEmpty
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
    widget.runtime.removeListener(runtimeChanged);
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(configurationNamespaceTitle('${accepted['ns']}')),
    bottom: PocketButton(
      onPressed: busy || invalidFields.isNotEmpty ? null : save,
      child: Text(busy ? '正在处理' : '保存并应用'),
    ),
    body: PocketList(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${accepted['ns']} · 版本 ${accepted['revision']}'),
              const SizedBox(height: 8),
              const Text(
                '仅提交修改的字段。凭据及含凭据的数组会保留，'
                '需要通过专门的凭据入口管理。',
              ),
              PocketButton.tonal(
                onPressed: busy || invalidFields.isNotEmpty
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
        if (latest != null) comparison(),
        if (advanced)
          PocketSection(
            title: '高级参数',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  key: const Key('configuration-json'),
                  controller: editor,
                  enabled: !busy,
                  minLines: 12,
                  maxLines: 24,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  onChanged: (_) => setState(() => resetReview = null),
                  decoration: const InputDecoration(
                    labelText: 'JSON 配置',
                    helperText: '移除普通字段表示取消该字段的用户覆盖。',
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
            enabled: !busy,
            fieldVersions: fieldVersions,
            onEdit: (path, value) => edit(path, value),
            onRemove: (path) {
              edit(path, null, remove: true);
              setState(() {
                final id = jsonEncode(path);
                fieldVersions[id] = (fieldVersions[id] ?? 0) + 1;
                invalidFields.remove(id);
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
              });
            },
            onAdvanced: toggleEditor,
          ),
        PocketSection(
          title: '版本与默认值',
          children: [
            PocketRow(
              icon: Icons.sync_rounded,
              title: '读取最新版本并比较',
              subtitle: '保留正在编辑的草稿',
              onTap: busy ? null : readLatest,
            ),
            PocketRow(
              icon: Icons.restore_rounded,
              title: '恢复普通参数默认值',
              subtitle: '先查看将清除的用户覆盖；保留凭据和含凭据数组',
              onTap: busy
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
                          : '以下用户覆盖将移除，并使用配置的默认值：\n'
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
                      onPressed: busy || resetReview!.operations.isEmpty
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
  );
}

String configurationNamespaceTitle(String namespace) {
  if (namespace.contains('llm') || namespace.contains('model')) return '模型参数';
  if (namespace.contains('shell') || namespace.contains('bash')) return 'Shell';
  if (namespace.contains('search') || namespace.contains('web')) return '联网搜索';
  if (namespace.contains('preset') || namespace.contains('persona')) {
    return 'Agent 预设';
  }
  if (namespace.contains('subagent')) return '子 Agent';
  return '工具与运行参数';
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
