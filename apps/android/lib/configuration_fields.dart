import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_fields_schema.dart';
import 'configuration_presentation.dart';
import 'configuration_value_row.dart';
import 'models.dart' show ModelDraftGuard;
import 'ui.dart';
import 'text_document_page.dart';

class ConfigurationFieldResult {
  const ConfigurationFieldResult(this.value) : remove = false;
  const ConfigurationFieldResult.remove() : value = null, remove = true;
  final dynamic value;
  final bool remove;
}

/// A detached, guarded field draft. Returning a value stages it in ConfigPage;
/// this page has no persistence API and never merges array elements by index.
class ConfigurationStructurePage extends StatefulWidget {
  const ConfigurationStructurePage({
    super.key,
    required this.field,
    required this.title,
    required this.value,
    this.labels = const {},
    this.namespace = '',
    this.path = const [],
    this.adding = false,
    this.allowReset = false,
    this.resetLabel = '使用默认值',
    this.inheritedValue,
    this.hasInheritedValue = false,
    this.pendingReset = false,
    this.editingState,
    this.canEdit,
  });
  final ConfigurationFieldSchema field;
  final String title;
  final dynamic value;
  final Map<String, String> labels;
  final String namespace;
  final List<String> path;
  final bool adding, allowReset;
  final String resetLabel;
  final dynamic inheritedValue;
  final bool hasInheritedValue;
  final bool pendingReset;
  final Listenable? editingState;
  final bool Function()? canEdit;

  @override
  State<ConfigurationStructurePage> createState() =>
      _ConfigurationStructurePageState();
}

class _ConfigurationStructurePageState
    extends State<ConfigurationStructurePage> {
  late dynamic value;
  late final TextEditingController text;
  bool dirty = false;
  String? error;
  bool get enabled => widget.canEdit?.call() ?? true;
  bool get exists => configurationHasValue(value);
  ConfigurationFieldSchema get field => widget.field;
  ConfigurationPresentation get presentation =>
      ConfigurationPresentation(widget.namespace);

  @override
  void initState() {
    super.initState();
    value = configurationHasValue(widget.value)
        ? jsonDecode(jsonEncode(widget.value))
        : widget.value;
    if (widget.adding && !exists) {
      value = switch (field.type) {
        'object' || 'dict' => <String, dynamic>{},
        'array' => <dynamic>[],
        'string' => '',
        'boolean' => false,
        _ => value,
      };
    }
    text = TextEditingController(text: exists && value != null ? '$value' : '');
    widget.editingState?.addListener(ownerChanged);
  }

  void ownerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.editingState?.removeListener(ownerChanged);
    text.dispose();
    super.dispose();
  }

  String label(String key, ConfigurationFieldSchema schema) =>
      widget.labels[key] ?? presentation.title([...widget.path, key], schema);
  void changed(dynamic next) => setState(() {
    value = next;
    dirty = true;
    error = null;
  });

  Future<ConfigurationFieldResult?> child(
    ConfigurationFieldSchema schema,
    String title,
    dynamic initial, {
    bool adding = false,
    bool allowReset = false,
    String resetLabel = '使用默认值',
    List<String>? path,
  }) async {
    if (!enabled) return null;
    return Navigator.of(context).push<ConfigurationFieldResult>(
      PocketRoute(
        builder: (_) => ConfigurationStructurePage(
          field: schema,
          title: title,
          value: initial,
          labels: widget.labels,
          namespace: widget.namespace,
          path: path ?? widget.path,
          adding: adding,
          allowReset: allowReset,
          resetLabel: resetLabel,
          editingState: widget.editingState,
          canEdit: widget.canEdit,
        ),
      ),
    );
  }

  Future<void> editMap(String key, ConfigurationFieldSchema schema) async {
    final result = await child(
      schema,
      label(key, schema),
      configurationValueAt(value, [key]),
      allowReset: configurationHasValue(configurationValueAt(value, [key])),
      resetLabel: field.type == 'dict' ? '移除此项' : '使用默认值',
      path: [...widget.path, key],
    );
    if (!mounted || !enabled || result == null) return;
    final next = <String, dynamic>{
      if (value is Map) ...Map<String, dynamic>.from(value),
    };
    if (result.remove) {
      next.remove(key);
    } else {
      next[key] = result.value;
    }
    changed(next);
  }

  Future<void> chooseBranch(ConfigurationFieldSchema branch) async {
    if (!enabled) return;
    if (branch.type == 'const') {
      changed(branch.node['value']);
      return;
    }
    final result = await child(
      branch,
      widget.title,
      branch.acceptsKind(value)
          ? value
          : configurationValueAt(const {}, ['new']),
      adding: !branch.acceptsKind(value),
    );
    if (mounted && enabled && result != null) changed(result.value);
  }

  Future<void> advancedValue() async {
    if (!enabled || field.secret) return;
    final result = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '${widget.title} · 高级编辑',
          text: exists ? const JsonEncoder.withIndent('  ').convert(value) : '',
          readOnly: false,
          monospace: true,
          fieldKey: const Key('structure-json'),
          editingState: widget.editingState,
          canEdit: widget.canEdit,
          validate: (input) {
            try {
              return field.validate(jsonDecode(input));
            } on FormatException {
              return 'JSON 无法解析，输入已保留。';
            }
          },
        ),
      ),
    );
    if (mounted && enabled && result != null) changed(jsonDecode(result));
  }

  Future<void> editItem(int index) async {
    final result = await child(
      field.inner,
      '第 ${index + 1} 项',
      (value as List)[index],
    );
    if (!mounted || !enabled || result == null) return;
    final next = List<dynamic>.from(value as List)..[index] = result.value;
    changed(next);
  }

  Future<void> addItem() async {
    final missing = configurationValueAt(const {}, ['new']);
    if (field.type == 'array') {
      final result = await child(field.inner, '添加项目', missing, adding: true);
      if (!mounted || !enabled || result == null) return;
      changed(<dynamic>[if (value is List) ...value as List, result.value]);
    } else {
      final result = await Navigator.of(context).push<ConfigurationFieldResult>(
        PocketRoute(
          builder: (_) => _ConfigurationKeyPage(
            field: field.keySchema,
            existing: value is Map
                ? (value as Map).keys.cast<String>().toSet()
                : {},
            canEdit: widget.canEdit,
            editingState: widget.editingState,
          ),
        ),
      );
      if (!mounted || !enabled || result == null) return;
      final key = result.value as String;
      final item = await child(field.inner, key, missing, adding: true);
      if (!mounted || !enabled || item == null) return;
      changed(<String, dynamic>{
        if (value is Map) ...Map<String, dynamic>.from(value),
        key: item.value,
      });
    }
  }

  void finish() {
    if (!enabled) return;
    if (!dirty && !widget.adding) {
      Navigator.of(context).pop();
      return;
    }
    final next = value;
    final failure = field.validate(next);
    if (failure != null || !configurationHasValue(next)) {
      setState(() => error = failure ?? '请填写此项。');
      return;
    }
    Navigator.of(context).pop(ConfigurationFieldResult(next));
  }

  Widget remove(String name, VoidCallback callback) => GlassButton(
    icon: Icons.remove_circle_outline_rounded,
    label: '移除 $name',
    onPressed: enabled ? callback : null,
  );

  Widget row(String key, ConfigurationFieldSchema schema) {
    final current = configurationValueAt(value, [key]);
    final inherited = !configurationHasValue(current)
        ? schema.explicitBooleanDefault
        : null;
    if (schema.booleanChoice &&
        (current is bool || inherited != null) &&
        !schema.secret) {
      return PocketSwitchRow(
        key: ValueKey('structure-entry:$key'),
        title: Text(label(key, schema)),
        subtitle: inherited == null ? null : const Text('使用默认值'),
        value: current is bool ? current : inherited!,
        onChanged: enabled
            ? (next) => changed(<String, dynamic>{
                if (value is Map) ...Map<String, dynamic>.from(value),
                key: next,
              })
            : null,
      );
    }
    return ConfigurationValueRow(
      key: ValueKey('structure-entry:$key'),
      title: label(key, schema),
      summary: schema.secret
          ? '包含凭据 · 已保护'
          : configurationStructureSummary(current),
      protected: schema.secret,
      onTap: enabled && !schema.secret ? () => editMap(key, schema) : null,
    );
  }

  Widget form() {
    if (field.secret) {
      return const PocketSection(
        children: [
          Padding(
            padding: EdgeInsets.all(20),
            child: Text('此结构包含凭据，请返回凭据入口管理。'),
          ),
        ],
      );
    }
    if (!field.native) {
      return PocketSection(
        children: [
          PocketTile(
            title: const Text('当前值已保留'),
            subtitle: Text(configurationStructureSummary(value)),
          ),
          PocketRow(
            icon: Icons.tune_rounded,
            title: '高级工具',
            subtitle: '此插件的特殊类型由原始校验器处理。',
            onTap: enabled ? advancedValue : null,
          ),
        ],
      );
    }
    if (field.structured) {
      if (exists &&
          value != null &&
          (field.type == 'array' ? value is! List : value is! Map)) {
        return PocketSection(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('现有值与此结构类型不符；内容已保留。'),
            ),
            PocketRow(
              icon: Icons.code_rounded,
              title: '高级编辑此项',
              onTap: enabled ? advancedValue : null,
            ),
          ],
        );
      }
      final count = value is List
          ? (value as List).length
          : value is Map
          ? (value as Map).length
          : 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PocketSection(
            title: field.type == 'object' ? '参数' : '项目 · $count',
            divided: true,
            children: [
              if (field.type == 'object')
                for (final entry in field.fields.entries)
                  row(entry.key, entry.value)
              else if (field.type == 'dict' && value is Map)
                for (final key in (value as Map).keys.cast<String>())
                  row(key, field.inner)
              else if (field.type == 'array' && value is List)
                for (var i = 0; i < (value as List).length; i++)
                  PocketRow(
                    key: ValueKey('structure-item:$i'),
                    icon: Icons.format_list_bulleted_rounded,
                    title: configurationStructureSummary((value as List)[i]),
                    subtitle: '第 ${i + 1} 项',
                    onTap: enabled ? () => editItem(i) : null,
                    trailing: remove(
                      '第 ${i + 1} 项',
                      () => changed(
                        List<dynamic>.from(value as List)..removeAt(i),
                      ),
                    ),
                  ),
              if (field.type != 'object' && count == 0)
                const Padding(padding: EdgeInsets.all(22), child: Text('尚无项目')),
              if (field.type != 'object')
                PocketRow(
                  icon: Icons.add_rounded,
                  title: '添加项目',
                  onTap: enabled ? addItem : null,
                ),
            ],
          ),
          if (field.type == 'object' &&
              value is Map &&
              (value as Map).keys.any((key) => !field.fields.containsKey(key)))
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('其他已有字段会原样保留。'),
            ),
        ],
      );
    }
    if (field.booleanChoice) {
      final inherited = !exists
          ? widget.hasInheritedValue && widget.inheritedValue is bool
                ? widget.inheritedValue as bool
                : field.explicitBooleanDefault
          : null;
      return PocketSection(
        children: [
          if (value is bool || inherited != null)
            PocketSwitchRow(
              title: Text(widget.title),
              subtitle: inherited == null
                  ? null
                  : Text(widget.pendingReset ? '恢复后使用' : '使用默认值'),
              value: value is bool ? value as bool : inherited!,
              onChanged: enabled ? changed : null,
            )
          else
            for (final option in [true, false])
              PocketTile(
                title: Text(option ? '开启' : '关闭'),
                onTap: enabled ? () => changed(option) : null,
              ),
        ],
      );
    }
    if (field.enumType) {
      final inherited = !exists && widget.hasInheritedValue;
      return PocketSection(
        title: '选项',
        divided: true,
        children: [
          for (final option in field.options)
            if (presentation.offerOption(widget.path, option))
              PocketTile(
                title: Text(presentation.option(widget.path, option)),
                subtitle:
                    inherited &&
                        configurationEqual(widget.inheritedValue, option)
                    ? Text(widget.pendingReset ? '恢复后使用此选项' : '当前默认选项')
                    : null,
                selected:
                    (exists && configurationEqual(value, option)) ||
                    (inherited &&
                        configurationEqual(widget.inheritedValue, option)),
                trailing:
                    (exists && configurationEqual(value, option)) ||
                        (inherited &&
                            configurationEqual(widget.inheritedValue, option))
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: enabled ? () => changed(option) : null,
              ),
        ],
      );
    }
    if (field.branchChoice) {
      final matches = field.alternatives
          .where((branch) => branch.acceptsKind(value))
          .toList();
      return PocketSection(
        title: '值类型',
        divided: true,
        children: [
          if (exists && matches.length != 1)
            PocketTile(
              title: const Text('当前值已保留'),
              subtitle: Text(configurationStructureSummary(value)),
            ),
          for (final branch in field.alternatives)
            PocketTile(
              title: Text(branch.kindLabel),
              subtitle: branch.description == null
                  ? null
                  : Text(branch.description!),
              selected:
                  matches.length == 1 &&
                  configurationEqual(matches.single.node, branch.node),
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: enabled ? () => chooseBranch(branch) : null,
            ),
        ],
      );
    }
    if (field.type == 'string' || field.type == 'number') {
      return TextDocumentField(
        fieldKey: const Key('structure-value'),
        controller: text,
        readOnly: !enabled,
        errorText: error,
        keyboardType: field.type == 'number'
            ? const TextInputType.numberWithOptions(signed: true, decimal: true)
            : TextInputType.multiline,
        onChanged: (input) => setState(() {
          dirty = true;
          if (field.type == 'number') {
            final parsed = num.tryParse(input);
            value = parsed;
            error = parsed == null || !parsed.isFinite
                ? '请输入有效数字。'
                : field.validate(parsed);
          } else {
            value = input;
            error = field.validate(input);
          }
        }),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => dirty,
    child: PocketScaffold(
      title: Text(widget.title),
      trailing: GlassButton(
        icon: Icons.check_rounded,
        label: widget.adding ? '添加到草稿' : '完成编辑',
        solid: true,
        onPressed: enabled && !field.secret && error == null ? finish : null,
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: PocketList(
          children: [
            if (!enabled)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('当前配置暂不可编辑；输入已保留。'),
              ),
            if (error != null &&
                (field.structured ||
                    field.enumType ||
                    field.branchChoice ||
                    !field.native))
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            form(),
            if (presentation.description(widget.path, field) != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                child: Text(
                  presentation.description(widget.path, field)!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (widget.allowReset && !field.secret)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: PocketSection(
                  children: [
                    PocketRow(
                      icon: Icons.restore_rounded,
                      title: widget.resetLabel,
                      onTap: enabled
                          ? () => Navigator.of(context)
                                .pop(const ConfigurationFieldResult.remove())
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _ConfigurationKeyPage extends StatefulWidget {
  const _ConfigurationKeyPage({
    required this.field,
    required this.existing,
    this.canEdit,
    this.editingState,
  });
  final ConfigurationFieldSchema field;
  final Set<String> existing;
  final bool Function()? canEdit;
  final Listenable? editingState;
  @override
  State<_ConfigurationKeyPage> createState() => _ConfigurationKeyPageState();
}

class _ConfigurationKeyPageState extends State<_ConfigurationKeyPage> {
  final controller = TextEditingController();
  String? error;
  bool get enabled => widget.canEdit?.call() ?? true;
  @override
  void initState() {
    super.initState();
    widget.editingState?.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.editingState?.removeListener(changed);
    controller.dispose();
    super.dispose();
  }

  void next() {
    if (!enabled) return;
    final key = controller.text;
    final failure = widget.existing.contains(key)
        ? '此名称已存在，请使用其他名称。'
        : widget.field.validate(key);
    if (failure != null) {
      setState(() => error = failure);
      return;
    }
    Navigator.of(context).pop(ConfigurationFieldResult(key));
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => controller.text.isNotEmpty,
    child: PocketScaffold(
      title: const Text('添加项目'),
      bottom: PocketButton(
        onPressed: enabled ? next : null,
        child: const Text('继续'),
      ),
      body: PocketList(
        children: [
          PocketSection(
            title: '项目名称',
            children: [
              if (widget.field.enumType)
                for (final option in widget.field.options.whereType<String>())
                  PocketTile(
                    title: Text(option),
                    selected: controller.text == option,
                    onTap: enabled && !widget.existing.contains(option)
                        ? () {
                            controller.text = option;
                            setState(() => error = null);
                          }
                        : null,
                  )
              else
                TextDocumentField(
                  fieldKey: const Key('structure-key'),
                  controller: controller,
                  readOnly: !enabled,
                  hintText: '名称',
                  errorText: error,
                  onChanged: (_) => setState(() => error = null),
                ),
              if (widget.field.enumType && error != null)
                Padding(padding: const EdgeInsets.all(20), child: Text(error!)),
            ],
          ),
        ],
      ),
    ),
  );
}
