import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'models.dart';
import 'models_data.dart';
import 'runtime.dart';
import 'ui.dart';

class ModelListPage extends StatefulWidget {
  const ModelListPage({
    required this.runtime,
    required this.settingsNs,
    required this.initial,
    required this.reasoningLevels,
    required this.supportsInput,
    this.provider,
    this.endpoint,
    this.protocol,
    super.key,
  });
  final RuntimeController runtime;
  final String settingsNs;
  final String? provider, endpoint, protocol;
  final List<Json> initial;
  final List<String> reasoningLevels;
  final bool supportsInput;
  @override
  State<ModelListPage> createState() => _ModelListPageState();
}

class _ModelListPageState extends State<ModelListPage> {
  late List<Json> rows = widget.initial.map(cloneConfiguration).toList();
  List<Json>? discovered;
  final probeKey = TextEditingController();
  bool busy = false;
  int? removeIndex;
  String? error;
  @override
  void dispose() {
    probeKey.dispose();
    super.dispose();
  }

  Future<void> edit([int? index]) async {
    final result = await Navigator.push<Json>(
      context,
      PocketRoute(
        builder: (_) => ModelEntryPage(
          initial: index == null ? <String, dynamic>{} : rows[index],
          reasoningLevels: widget.reasoningLevels,
          supportsInput: widget.supportsInput,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (index == null) {
          rows.add(result);
        } else {
          rows[index] = result;
        }
        error = null;
        removeIndex = null;
      });
    }
  }

  Future<void> discover() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await modelsApi(widget.runtime, 'llm', 'discoverModels', {
        'settingsNs': widget.settingsNs,
        'request': {
          if (widget.provider != null) 'provider': widget.provider,
          if (widget.endpoint?.isNotEmpty == true) 'baseURL': widget.endpoint,
          if (widget.protocol != null) 'api': widget.protocol,
          if (probeKey.text.trim().isNotEmpty) 'apiKey': probeKey.text.trim(),
        },
      });
      if (mounted) setState(() => discovered = (result as List).cast<Json>());
    } catch (failure) {
      if (mounted) setState(() => error = '无法发现模型：$failure\n现有模型与输入已保留。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void adopt(Json found) {
    final next = <String, dynamic>{
      'id': found['id'],
      if (found['name'] != null) 'name': found['name'],
      if (found['contextWindow'] != null)
        'contextWindow': found['contextWindow'],
      if (found['maxTokens'] != null) 'maxTokens': found['maxTokens'],
      if (widget.supportsInput && found['inputModalities'] != null)
        'input': found['inputModalities'],
    };
    setState(() => rows.add(next));
  }

  void finish() {
    try {
      validateModelRows(rows);
      Navigator.pop(context, rows);
    } catch (failure) {
      setState(() => error = '$failure');
    }
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () =>
        !configurationEqual(rows, widget.initial) || probeKey.text.isNotEmpty,
    busy: busy,
    child: PocketScaffold(
      title: const Text('模型列表'),
      bottom: PocketButton(
        onPressed: busy ? null : finish,
        child: const Text('应用到当前草稿'),
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (error != null) ModelNotice(error!),
          const ModelNotice('这里修改当前表单的草稿，返回服务商页面保存后生效。'),
          PocketSection(
            title: '已选模型',
            children: [
              if (rows.isEmpty) const ModelNotice('尚未添加模型。'),
              for (var index = 0; index < rows.length; index++)
                PocketRow(
                  icon: Icons.auto_awesome_outlined,
                  title: '${rows[index]['name'] ?? rows[index]['id']}',
                  subtitle: '${rows[index]['id']}',
                  onTap: busy ? null : () => edit(index),
                  trailing: GlassButton(
                    icon: Icons.remove_circle_outline,
                    label: '移除 ${rows[index]['id']}',
                    onPressed: busy
                        ? null
                        : () => setState(() => removeIndex = index),
                  ),
                ),
              PocketRow(
                icon: Icons.add_rounded,
                title: '手动添加模型',
                onTap: busy ? null : edit,
              ),
            ],
          ),
          if (removeIndex != null)
            PocketSection(
              title: '移除此模型',
              children: [
                ModelNotice('${rows[removeIndex!]['id']} 将从当前模型草稿移除。'),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      PocketButton.tonal(
                        onPressed: () => setState(() => removeIndex = null),
                        child: const Text('保留模型'),
                      ),
                      PocketButton(
                        onPressed: () => setState(() {
                          rows.removeAt(removeIndex!);
                          removeIndex = null;
                        }),
                        child: const Text('确认移除模型'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          PocketSection(
            title: '从服务商发现',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: probeKey,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '仅本次发现使用的 API Key',
                    hintText: '可留空；此字段不会保存凭据',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: PocketButton.tonal(
                  onPressed: busy ? null : discover,
                  child: Text(busy ? '正在读取' : '发现模型'),
                ),
              ),
              if (discovered != null && discovered!.isEmpty)
                const ModelNotice('服务商没有返回模型。可手动添加。'),
              for (final found in discovered ?? <Json>[])
                PocketRow(
                  icon: Icons.add_circle_outline_rounded,
                  title: '${found['name'] ?? found['id']}',
                  subtitle: '${found['id']}',
                  trailing: rows.any((row) => row['id'] == found['id'])
                      ? const Text('已添加')
                      : null,
                  onTap: busy || rows.any((row) => row['id'] == found['id'])
                      ? null
                      : () => adopt(found),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class ModelEntryPage extends StatefulWidget {
  const ModelEntryPage({
    required this.initial,
    required this.reasoningLevels,
    required this.supportsInput,
    super.key,
  });
  final Json initial;
  final List<String> reasoningLevels;
  final bool supportsInput;
  @override
  State<ModelEntryPage> createState() => _ModelEntryPageState();
}

class _ModelEntryPageState extends State<ModelEntryPage> {
  late final draft = cloneConfiguration(widget.initial);
  late final id = TextEditingController(text: draft['id'] as String? ?? '');
  late final name = TextEditingController(text: draft['name'] as String? ?? '');
  late final contextSize = TextEditingController(
    text: '${draft['contextWindow'] ?? ''}',
  );
  late final outputSize = TextEditingController(
    text: '${draft['maxTokens'] ?? ''}',
  );
  late final Map<String, TextEditingController> efforts = {
    for (final level in widget.reasoningLevels)
      level: TextEditingController(
        text: draft['reasoningEfforts'] is Map
            ? '${draft['reasoningEfforts'][level] ?? ''}'
            : '',
      ),
  };
  late final selectedEfforts = draft['reasoningEfforts'] is Map
      ? (draft['reasoningEfforts'] as Map).keys.cast<String>().toSet()
      : <String>{};
  late String reasoning = !draft.containsKey('reasoningEfforts')
      ? 'inherit'
      : draft['reasoningEfforts'] == false
      ? 'disabled'
      : 'custom';
  String? error;
  @override
  void dispose() {
    for (final controller in [
      id,
      name,
      contextSize,
      outputSize,
      ...efforts.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void finish() {
    try {
      final next = cloneConfiguration(draft)..['id'] = id.text.trim();
      for (final (key, text) in [('name', name.text.trim())]) {
        if (text.isEmpty) {
          next.remove(key);
        } else {
          next[key] = text;
        }
      }
      for (final (key, controller) in [
        ('contextWindow', contextSize),
        ('maxTokens', outputSize),
      ]) {
        final value = modelCapacity(controller.text);
        if (value == null) {
          next.remove(key);
        } else {
          next[key] = value;
        }
      }
      if (widget.reasoningLevels.isNotEmpty) {
        switch (reasoning) {
          case 'inherit':
            next.remove('reasoningEfforts');
          case 'disabled':
            next['reasoningEfforts'] = false;
          case 'custom':
            if (selectedEfforts.isEmpty) {
              throw const FormatException('至少选择一个推理档位。');
            }
            final original = widget.initial['reasoningEfforts'];
            next['reasoningEfforts'] = {
              // A future/unknown level is retained instead of stripped by this UI.
              if (original is Map)
                for (final key in original.keys)
                  if (!efforts.containsKey(key)) key as String: original[key],
              for (final level in selectedEfforts)
                level: efforts[level] == null
                    ? original[level]
                    : efforts[level]!.text.trim().isEmpty
                    ? null
                    : efforts[level]!.text.trim(),
            };
        }
      }
      validateModelRows([next]);
      Navigator.pop(context, next);
    } catch (failure) {
      setState(() => error = '$failure');
    }
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () =>
        !configurationEqual(draft, widget.initial) ||
        id.text != (widget.initial['id'] ?? '') ||
        name.text != (widget.initial['name'] ?? '') ||
        contextSize.text != '${widget.initial['contextWindow'] ?? ''}' ||
        outputSize.text != '${widget.initial['maxTokens'] ?? ''}' ||
        reasoning !=
            (!widget.initial.containsKey('reasoningEfforts')
                ? 'inherit'
                : widget.initial['reasoningEfforts'] == false
                ? 'disabled'
                : 'custom') ||
        !configurationEqual(
          selectedEfforts.toList()..sort(),
          (widget.initial['reasoningEfforts'] is Map
                ? (widget.initial['reasoningEfforts'] as Map).keys
                      .cast<String>()
                      .toList()
                : <String>[])
            ..sort(),
        ) ||
        efforts.entries.any(
          (entry) =>
              entry.value.text !=
              (widget.initial['reasoningEfforts'] is Map
                  ? '${widget.initial['reasoningEfforts'][entry.key] ?? ''}'
                  : ''),
        ),
    child: PocketScaffold(
      title: const Text('编辑模型'),
      bottom: PocketButton(onPressed: finish, child: const Text('应用模型')),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (error != null) ModelNotice(error!),
          PocketSection(
            title: '模型信息',
            children: [
              for (final (controller, label) in [
                (id, '模型 ID'),
                (name, '显示名称'),
                (contextSize, '上下文容量'),
                (outputSize, '最大输出 Token'),
              ])
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(labelText: label),
                  ),
                ),
              const ModelNotice('容量可写 256K 或 1M；留空继承服务商或模型目录的值。'),
            ],
          ),
          if (widget.supportsInput)
            PocketSection(
              title: '输入类型',
              children: [
                for (final modality in ['text', 'image'])
                  PocketSwitchRow(
                    title: Text(modality == 'image' ? '图片' : '文本'),
                    value: (draft['input'] as List? ?? []).contains(modality),
                    onChanged: (selected) => setState(() {
                      final input = List<String>.from(
                        draft['input'] as List? ?? [],
                      );
                      input.remove(modality);
                      if (selected) input.add(modality);
                      draft['input'] = input;
                    }),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: PocketButton.tonal(
                    onPressed: () => setState(() => draft.remove('input')),
                    child: const Text('继承输入类型'),
                  ),
                ),
              ],
            ),
          if (widget.reasoningLevels.isNotEmpty)
            PocketSection(
              title: '推理能力',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in [
                        ('inherit', '继承'),
                        ('disabled', '不支持推理'),
                        ('custom', '指定档位'),
                      ])
                        PocketChoice(
                          label: Text(label),
                          selected: reasoning == value,
                          onSelected: (_) => setState(() => reasoning = value),
                        ),
                    ],
                  ),
                ),
                if (reasoning == 'custom') ...[
                  const ModelNotice('每个值是此服务商接受的协议字段值；空值表示 null，具体兼容性由适配器验证。'),
                  for (final level in widget.reasoningLevels) ...[
                    PocketSwitchRow(
                      title: Text(level),
                      value: selectedEfforts.contains(level),
                      onChanged: (selected) => setState(() {
                        if (selected) {
                          selectedEfforts.add(level);
                        } else {
                          selectedEfforts.remove(level);
                        }
                      }),
                    ),
                    if (selectedEfforts.contains(level))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: TextField(
                          controller: efforts[level],
                          decoration: InputDecoration(labelText: '$level 的协议值'),
                        ),
                      ),
                  ],
                ],
              ],
            ),
        ],
      ),
    ),
  );
}
