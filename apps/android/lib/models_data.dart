import 'configuration_edits.dart';
import 'runtime.dart';

Future<dynamic> modelsApi(
  RuntimeController runtime,
  String namespace,
  String method, [
  Json args = const {},
]) => runtime.call('api.call', {
  'namespace': namespace,
  'method': method,
  'args': args,
});

/// The same convention as ui-settings-models/store.ts. Existing references win.
String modelCredentialReference(String provider) =>
    '${provider.toUpperCase().replaceAll(RegExp('[^A-Z0-9]+'), '_')}_API_KEY';

Json modelObjectAt(dynamic root, List<String> path) {
  final value = configurationValueAt(root, path);
  return value is Map ? Map<String, dynamic>.from(value) : {};
}

List<String> modelStringChoices(Json descriptor, List<String> path) =>
    ConfigurationSchema(descriptor['schema'])
        .nodesAt(path)
        .where((node) => node['type'] == 'const' && node['value'] is String)
        .map((node) => node['value'] as String)
        .toSet()
        .toList();

List<String> modelReasoningLevels(Json descriptor, List<String> path) {
  final schema = ConfigurationSchema(descriptor['schema']);
  for (final node in schema.nodesAt([
    ...path,
    'models',
    '0',
    'reasoningEfforts',
  ])) {
    if (node['type'] != 'dict') continue;
    final key = schema.resolve(node['sKey']);
    return (key['list'] as List? ?? [])
        .map(schema.resolve)
        .map((entry) => entry['value'])
        .whereType<String>()
        .toList();
  }
  return [];
}

class ModelProvider {
  ModelProvider(this.entry, this.descriptor);
  final Json entry;
  final Json? descriptor;
  String get id => entry['provider'] as String;
  String get name => entry['displayName'] as String;
  List<String> get path => (entry['settingsPath'] as List).cast<String>();
  bool get active => entry['active'] == true;
  bool get account => id == 'deepseek-account';
  Json get profile => modelObjectAt(descriptor?['value'], path);
  String get credentialRef =>
      profile['apiKeyEnv'] is String &&
          (profile['apiKeyEnv'] as String).isNotEmpty
      ? profile['apiKeyEnv'] as String
      : modelCredentialReference(id);
  bool get removable =>
      descriptor != null &&
      path.isNotEmpty &&
      configurationHasValue(configurationValueAt(descriptor!['user'], path)) &&
      !configurationHasValue(configurationValueAt(descriptor!['base'], path));
}

class ModelsSnapshot {
  ModelsSnapshot(this.providers, this.descriptors, this.catalog);
  final List<ModelProvider> providers;
  final List<Json> descriptors;
  final Json catalog;
  Json? descriptor(String ns) {
    for (final row in descriptors) {
      if (row['ns'] == ns) return row;
    }
    return null;
  }

  static Future<ModelsSnapshot> read(RuntimeController runtime) async {
    final parts = await Future.wait([
      modelsApi(runtime, 'llm', 'listProviders'),
      modelsApi(runtime, 'llm', 'listConfigurableProviders'),
      runtime.call('settings.describe'),
      modelsApi(runtime, 'session', 'modelCatalog'),
    ]);
    final registered = (parts[0] as List).cast<Json>();
    final directory = (parts[1] as List).cast<Json>();
    final descriptors = (parts[2] as List).cast<Json>();
    final active = {for (final row in registered) row['id']};
    final rows = [
      for (final row in directory)
        {...row, 'active': active.contains(row['provider'])},
      for (final row in registered)
        if (!directory.any((entry) => entry['provider'] == row['id']))
          {
            'provider': row['id'],
            'displayName': row['name'],
            'settingsNs': '',
            'settingsPath': <String>[],
            'active': true,
          },
    ];
    Json? owning(Json row) {
      for (final descriptor in descriptors) {
        if (descriptor['ns'] == row['settingsNs']) return descriptor;
      }
      return null;
    }

    return ModelsSnapshot(
      rows.map((row) => ModelProvider(row, owning(row))).toList(),
      descriptors,
      parts[3] as Json,
    );
  }
}

/// Stores only edits shown by the form, fenced by the snapshot it was opened on.
Future<Json> writeModelSettings(
  RuntimeController runtime,
  Json accepted,
  Json draft,
) async {
  final operations = configurationEdits(accepted, draft);
  if (operations.isEmpty) return accepted;
  final result = (await runtime.call('settings.mutate', {
    'ns': accepted['ns'],
    'revision': accepted['revision'],
    'ops': operations,
  }) as List).cast<Json>();
  return cloneConfiguration(
    result.firstWhere((row) => row['ns'] == accepted['ns']),
  );
}

/// Capacity notation matches the Web model editor (decimal K/M, integral tokens).
int? modelCapacity(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final match = RegExp(r'^(\d+(?:\.\d+)?)([kKmM])?$').firstMatch(value);
  if (match == null) throw const FormatException('容量须为正整数，支持 256K、1M。');
  final suffix = match[2]?.toLowerCase();
  final scaled =
      double.parse(match[1]!) *
      (suffix == 'm'
          ? 1000000
          : suffix == 'k'
          ? 1000
          : 1);
  if (!scaled.isFinite ||
      scaled <= 0 ||
      (scaled - scaled.round()).abs() > 0.000001) {
    throw const FormatException('容量须为正整数，支持 256K、1M。');
  }
  return scaled.round();
}

void validateModelRows(List<Json> rows) {
  final ids = <String>{};
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final id = row['id'] is String ? (row['id'] as String).trim() : '';
    if (id.isEmpty) throw FormatException('第 ${index + 1} 个模型需要 ID。');
    if (!ids.add(id)) throw FormatException('模型 ID 重复：$id');
    for (final key in ['contextWindow', 'maxTokens']) {
      final value = row[key];
      if (value != null && (value is! int || value <= 0)) {
        throw FormatException('$id 的 $key 须为正整数。');
      }
    }
  }
}

void validateCustomProvider(
  String route,
  String endpoint,
  String protocol,
  List<String> protocols,
  List<Json> models,
  Set<String> taken,
) {
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(route)) {
    throw const FormatException('服务商 ID 以小写字母开头，可包含数字和单连字符。');
  }
  if (taken.contains(route)) throw const FormatException('此服务商 ID 已存在。');
  final uri = Uri.tryParse(endpoint);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    throw const FormatException('请输入完整的 HTTP 或 HTTPS 接口地址。');
  }
  if (!protocols.contains(protocol)) throw const FormatException('请选择接口协议。');
  if (models.isEmpty) throw const FormatException('至少添加一个模型。');
  validateModelRows(models);
}
