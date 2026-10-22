import 'dart:async';

import 'package:flutter/foundation.dart';

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
  ModelsSnapshot(
    this.providers,
    this.descriptors,
    this.catalog, {
    this.catalogFresh = true,
  });
  final List<ModelProvider> providers;
  final List<Json> descriptors;
  final Json catalog;

  /// A failed catalog read cannot authorize choosing a model, even when the
  /// separately read provider settings are current.
  final bool catalogFresh;
  Json? descriptor(String ns) {
    for (final row in descriptors) {
      if (row['ns'] == ns) return row;
    }
    return null;
  }

  static Future<ModelsSnapshot> read(RuntimeController runtime) async {
    // The remote catalog may need an account listing. Its failure must not
    // suppress independent local provider and settings management.
    final catalogRead = modelsApi(runtime, 'session', 'modelCatalog')
        .then<({Json? value, bool fresh})>(
          (value) => (value: value as Json, fresh: true),
          onError: (Object failure) => (value: null, fresh: false),
        );
    final parts = await Future.wait([
      modelsApi(runtime, 'llm', 'listProviders'),
      modelsApi(runtime, 'llm', 'listConfigurableProviders'),
      runtime.call('settings.describe'),
    ]);
    final catalogResult = await catalogRead;
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
      catalogResult.value ??
          {
            'default': modelObjectAt(
              descriptors
                  .where((row) => row['ns'] == 'agent-default-model')
                  .firstOrNull?['value'],
              const [],
            ),
            'groups': <Json>[],
            'failures': <Json>[],
            'routableProviders': <String>[],
          },
      catalogFresh: catalogResult.fresh,
    );
  }
}

/// Runtime-owned read cache. A retained directory is display data; edits must
/// refresh it before opening an editor after a connection change or failure.
class ModelsDirectoryController extends ChangeNotifier {
  ModelsDirectoryController(this.runtime)
    : _phase = runtime.phase,
      _connection = runtime.connectionGeneration {
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  ModelsSnapshot? snapshot;
  String? error;
  bool loading = false, fresh = false, _disposed = false;
  bool get retryPending => _retry != null;
  int _revision = 0, _connection;
  String _phase;
  Future<void>? _refresh;
  Timer? _retry;
  int _retryAttempt = 0;
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
  ];

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  void _scheduleRetry() {
    if (_disposed ||
        !runtime.ready ||
        !hasListeners ||
        _retry != null ||
        _retryAttempt >= _retryDelays.length) {
      return;
    }
    final delay = _retryDelays[_retryAttempt++];
    _retry = Timer(delay, () {
      _retry = null;
      if (!_disposed && runtime.ready && hasListeners) {
        unawaited(refresh());
      }
    });
  }

  void _runtimeChanged() {
    if (_phase == runtime.phase &&
        _connection == runtime.connectionGeneration) {
      return;
    }
    _phase = runtime.phase;
    _connection = runtime.connectionGeneration;
    _revision++;
    _refresh = null;
    _cancelRetry();
    _retryAttempt = 0;
    fresh = false;
    loading = false;
    if (runtime.ready) {
      unawaited(refresh());
    } else {
      error = '本地服务尚未就绪，恢复后会自动刷新。';
      notifyListeners();
    }
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_refresh != null) return _refresh!;
    _cancelRetry();
    if (!runtime.ready) {
      fresh = false;
      error = '本地服务尚未就绪，恢复后会自动刷新。';
      notifyListeners();
      return Future.value();
    }
    final revision = ++_revision;
    final connection = runtime.connectionGeneration;
    loading = true;
    error = null;
    notifyListeners();
    late final Future<void> operation;
    operation =
        () async {
          bool current() =>
              !_disposed &&
              revision == _revision &&
              connection == runtime.connectionGeneration &&
              runtime.ready;
          try {
            final next = await ModelsSnapshot.read(runtime);
            if (!current()) return;
            snapshot = next;
            fresh = true;
            if (next.catalogFresh) {
              _retryAttempt = 0;
            } else {
              _scheduleRetry();
            }
          } catch (failure) {
            if (!current()) return;
            fresh = false;
            _scheduleRetry();
            error = retryPending
                ? '本地服务尚未返回完整配置，稍后会自动重试。'
                : '本地服务尚未返回完整配置，请点击刷新重试。';
          } finally {
            if (current()) {
              loading = false;
              notifyListeners();
            }
          }
        }().whenComplete(() {
          if (identical(_refresh, operation)) _refresh = null;
        });
    return _refresh = operation;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _cancelRetry();
    runtime.removeListener(_runtimeChanged);
    super.dispose();
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
