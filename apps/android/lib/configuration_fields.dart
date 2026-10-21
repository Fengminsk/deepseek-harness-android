import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_fields_schema.dart';
import 'models.dart' show ModelDraftGuard;
import 'ui.dart';
import 'text_document_page.dart';

class ConfigurationFieldResult {
  const ConfigurationFieldResult(this.value);
  final dynamic value;
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
    this.adding = false,
    this.editingState,
    this.canEdit,
  });
  final ConfigurationFieldSchema field;
  final String title;
  final dynamic value;
  final Map<String, String> labels;
  final bool adding;
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
  bool dirty = false, raw = false;
  String? error;
  bool get enabled => widget.canEdit?.call() ?? true;
  bool get exists => configurationHasValue(value);
  ConfigurationFieldSchema get field => widget.field;

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
    raw = !field.native;
    text = TextEditingController(
      text: raw
          ? (exists ? const JsonEncoder.withIndent('  ').convert(value) : '')
          : (exists && value != null ? '$value' : ''),
    );
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

  String label(String key) => widget.labels[key] ?? key;
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
  }) async {
    if (!enabled) return null;
    return Navigator.of(context).push<ConfigurationFieldResult>(
      PocketRoute(
        builder: (_) => ConfigurationStructurePage(
          field: schema,
          title: title,
          value: initial,
          labels: widget.labels,
          adding: adding,
          editingState: widget.editingState,
          canEdit: widget.canEdit,
        ),
      ),
    );
  }

  Future<void> editMap(String key, ConfigurationFieldSchema schema) async {
    final result = await child(
      schema,
      label(key),
      configurationValueAt(value, [key]),
    );
    if (!mounted || !enabled || result == null) return;
    changed(<String, dynamic>{
      if (value is Map) ...Map<String, dynamic>.from(value),
      key: result.value,
    });
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
    dynamic next = value;
    if (raw) {
      try {
        next = jsonDecode(text.text);
      } catch (_) {
        setState(() => error = 'JSON 无法解析，输入已保留。');
        return;
      }
    }
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
    return PocketRow(
      key: ValueKey('structure-entry:$key'),
      icon: schema.structured ? Icons.folder_open_rounded : Icons.tune_rounded,
      title: label(key),
      subtitle: schema.secret
          ? '包含凭据，请在凭据入口管理'
          : configurationStructureSummary(current),
      onTap: enabled && !schema.secret ? () => editMap(key, schema) : null,
      trailing: configurationHasValue(current) && !schema.secret
          ? remove(label(key), () {
              final next = Map<String, dynamic>.from(value as Map)..remove(key);
              changed(next);
            })
          : null,
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
    if (raw) {
      return TextDocumentField(
        fieldKey: const Key('structure-json'),
        controller: text,
        readOnly: !enabled,
        monospace: true,
        errorText: error,
        onChanged: (_) => setState(() {
          dirty = true;
          error = null;
        }),
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
              onTap: enabled
                  ? () {
                      setState(() {
                        raw = true;
                        text.text = const JsonEncoder.withIndent('  ')
                            .convert(value);
                      });
                    }
                  : null,
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
    if (field.enumType) {
      return PocketSection(
        title: '选项',
        divided: true,
        children: [
          for (final option in field.options)
            PocketTile(
              title: Text(configurationStructureSummary(option)),
              selected: exists && configurationEqual(value, option),
              trailing: exists && configurationEqual(value, option)
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: enabled ? () => changed(option) : null,
            ),
        ],
      );
    }
    if (field.type == 'boolean') {
      return PocketSection(
        children: [
          PocketSwitchRow(
            title: Text(widget.title),
            value: value == true,
            onChanged: enabled ? changed : null,
          ),
        ],
      );
    }
    if (field.type == 'string') {
      return TextDocumentField(
        fieldKey: const Key('structure-value'),
        controller: text,
        readOnly: !enabled,
        errorText: error,
        onChanged: (input) => setState(() {
          dirty = true;
          value = input;
          error = field.validate(input);
        }),
      );
    }
    return PocketSection(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: TextField(
            key: const Key('structure-value'),
            controller: text,
            enabled: enabled,
            keyboardType: field.type == 'number'
                ? const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  )
                : TextInputType.text,
            minLines: 1,
            maxLines: field.type == 'string' ? 6 : 1,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: widget.title,
              errorText: error,
            ),
            onChanged: (input) => setState(() {
              dirty = true;
              if (field.type == 'number') {
                final parsed = num.tryParse(input);
                error = parsed == null || !parsed.isFinite
                    ? '请输入有效数字。'
                    : field.validate(parsed);
                // Keep the raw invalid buffer separate from the last valid value.
                value = parsed;
              } else {
                value = input;
                error = field.validate(input);
              }
            }),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => dirty,
    child: PocketScaffold(
      title: Text(widget.title),
      bottom: PocketButton(
        onPressed: enabled && !field.secret && error == null ? finish : null,
        child: Text(widget.adding ? '添加到草稿' : '完成编辑'),
      ),
      body: PocketList(
        children: [
          if (field.description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Text(field.description!),
            ),
          if (!enabled)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('当前配置暂不可编辑；输入已保留。'),
            ),
          if (error != null && !raw && (field.structured || field.enumType))
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          form(),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Text('完成后返回配置草稿，保存并应用后生效。'),
          ),
        ],
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
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: TextField(
                    key: const Key('structure-key'),
                    controller: controller,
                    enabled: enabled,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: '名称',
                      errorText: error,
                    ),
                    onChanged: (_) => setState(() => error = null),
                  ),
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
