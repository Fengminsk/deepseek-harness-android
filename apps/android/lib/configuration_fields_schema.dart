import 'configuration_edits.dart';

/// Presentation of the Schemastery wire schema. This never materializes defaults
/// or replaces the runtime's validation; opaque validators remain server owned.
class ConfigurationFieldSchema {
  const ConfigurationFieldSchema(this.schema, this.node);
  final ConfigurationSchema schema;
  final ConfigurationMap node;

  String get type => '${node['type'] ?? 'unknown'}';
  Map get meta => node['meta'] as Map? ?? const {};
  bool get structured => const ['object', 'array', 'dict'].contains(type);
  bool get secret => schema.containsSecret(node);
  bool get enumType =>
      type == 'const' ||
      type == 'union' &&
          alternatives.isNotEmpty &&
          alternatives.every(
            (child) => child.type == 'const' && child.node.containsKey('value'),
          );
  bool get native =>
      structured ||
      enumType ||
      const ['string', 'number', 'boolean'].contains(type);
  List<ConfigurationFieldSchema> get alternatives => [
    for (final ref in node['list'] as List? ?? [])
      ConfigurationFieldSchema(schema, schema.resolve(ref)),
  ];
  List<dynamic> get options => type == 'const'
      ? [node['value']]
      : [for (final child in alternatives) child.node['value']];
  ConfigurationFieldSchema get inner =>
      ConfigurationFieldSchema(schema, schema.resolve(node['inner']));
  ConfigurationFieldSchema get keySchema =>
      ConfigurationFieldSchema(schema, schema.resolve(node['sKey']));
  Map<String, ConfigurationFieldSchema> get fields => {
    for (final entry in (node['dict'] as Map? ?? {}).entries)
      '${entry.key}': ConfigurationFieldSchema(
        schema,
        schema.resolve(entry.value),
      ),
  };
  String? get description {
    final value = meta['description'];
    if (value is String) return value;
    if (value is Map) {
      return (value['zh-CN'] ?? value['zh'] ?? value['en-US'] ?? value[''])
          as String?;
    }
    return null;
  }

  /// Only constraints whose semantics are available in the JSON schema run here.
  /// No JS transforms, defaults or unions are guessed on the client.
  String? validate(dynamic value, {int depth = 0}) {
    if (depth > 24) return '结构层级过深，请使用高级编辑。';
    if (!configurationHasValue(value) || value == null) {
      return meta['required'] == true ? '此项不能为空。' : null;
    }
    if (secret) return null;
    if (enumType) {
      return options.any((option) => configurationEqual(value, option))
          ? null
          : '请选择提供的选项。';
    }
    String? range(num size, String noun, {bool skipMin = false}) {
      if (!skipMin && meta['min'] is num && size < meta['min']) {
        return '$noun不能小于 ${meta['min']}。';
      }
      if (meta['max'] is num && size > meta['max']) {
        return '$noun不能大于 ${meta['max']}。';
      }
      return null;
    }

    if (type == 'string') {
      if (value is! String) return '请输入文本。';
      final bounds = range(value.length, '长度');
      if (bounds != null) return bounds;
      final pattern = meta['pattern'];
      if (pattern is Map && pattern['source'] is String) {
        final flags = '${pattern['flags'] ?? ''}';
        // Dart supports the common ECMAScript flags. Leave unsupported regex
        // extensions to the original validator, rather than rejecting valid JS.
        if (!flags.split('').any((flag) => !'imsu'.contains(flag))) {
          try {
            final regexp = RegExp(
              pattern['source'],
              caseSensitive: !flags.contains('i'),
              multiLine: flags.contains('m'),
              dotAll: flags.contains('s'),
              unicode: flags.contains('u'),
            );
            if (!regexp.hasMatch(value)) return '内容不符合此项要求的格式。';
          } on FormatException {
            /* Runtime validates unsupported expressions. */
          }
        }
      }
    } else if (type == 'number') {
      if (value is! num || !value.isFinite) return '请输入有效数字。';
      final bounds = range(value, '数值');
      if (bounds != null) return bounds;
      final step = meta['step'];
      if (step == 1 &&
          (value - (meta['min'] is num ? meta['min'] : 0)) % 1 != 0) {
        return '请输入符合步长的整数。';
      }
    } else if (type == 'boolean') {
      if (value is! bool) return '请选择开启或关闭。';
    } else if (type == 'array') {
      if (value is! List) return '此项需要一个列表。';
      final bounds = range(
        value.length,
        '项目数量',
        skipMin: inner.meta['default'] != null,
      );
      if (bounds != null) return bounds;
      for (var i = 0; i < value.length; i++) {
        final error = inner.validate(value[i], depth: depth + 1);
        if (error != null) return '第 ${i + 1} 项：$error';
      }
    } else if (type == 'object' || type == 'dict') {
      if (value is! Map) return '此项需要一个对象。';
      final children = type == 'object'
          ? fields
          : {for (final key in value.keys) '$key': inner};
      for (final entry in children.entries) {
        if (type == 'dict') {
          final keyError = keySchema.validate(entry.key, depth: depth + 1);
          if (keyError != null) return '${entry.key}：$keyError';
        }
        final error = entry.value.validate(
          configurationValueAt(value, [entry.key]),
          depth: depth + 1,
        );
        if (error != null) return '${entry.key}：$error';
      }
    }
    return null;
  }
}

String configurationStructureSummary(dynamic value) {
  if (!configurationHasValue(value)) return '未设置';
  if (value == null) return '空值';
  if (value is bool) return value ? '已开启' : '已关闭';
  if (value is List) return '${value.length} 项';
  if (value is Map) {
    for (final key in ['name', 'displayName', 'id', 'model', 'provider']) {
      if (value[key] is String && (value[key] as String).isNotEmpty) {
        return '${value[key]}';
      }
    }
    return '${value.length} 个字段';
  }
  return value.toString().isEmpty ? '空文本' : value.toString();
}
