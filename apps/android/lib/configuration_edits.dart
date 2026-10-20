import 'dart:convert';

typedef ConfigurationMap = Map<String, dynamic>;

const _missing = _Missing();

class _Missing {
  const _Missing();
}

class ConfigurationEditException implements Exception {
  const ConfigurationEditException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool configurationEqual(dynamic left, dynamic right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) =>
              right.containsKey(key) &&
              configurationEqual(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (index) => index,
        ).every((index) => configurationEqual(left[index], right[index]));
  }
  return left == right;
}

ConfigurationMap configurationObject(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const ConfigurationEditException('配置必须是 JSON 对象。');
  }
  return value;
}

ConfigurationMap cloneConfiguration(ConfigurationMap value) =>
    jsonDecode(jsonEncode(value)) as ConfigurationMap;

bool _prefix(List<String> parent, List<String> child) =>
    parent.length <= child.length &&
    List.generate(
      parent.length,
      (index) => index,
    ).every((index) => parent[index] == child[index]);

String configurationPathLabel(List<String> path) =>
    path.isEmpty ? '整个配置' : path.join(' › ');

dynamic configurationValueAt(dynamic value, List<String> path) {
  for (final key in path) {
    if (value is Map && value.containsKey(key)) {
      value = value[key];
    } else if (value is List) {
      final index = int.tryParse(key);
      if (index == null || index < 0 || index >= value.length) return _missing;
      value = value[index];
    } else {
      return _missing;
    }
  }
  return value;
}

bool configurationHasValue(dynamic value) => !identical(value, _missing);

String configurationValueLabel(dynamic value) => identical(value, _missing)
    ? '未设置（使用默认值）'
    : const JsonEncoder.withIndent('  ').convert(value);

/// Resolves the uid/refs envelope returned by Schemastery's toJSON().
class ConfigurationSchema {
  ConfigurationSchema(dynamic schema)
    : envelope = schema is Map ? Map<String, dynamic>.from(schema) : {};
  final ConfigurationMap envelope;

  ConfigurationMap resolve(dynamic reference) {
    if (reference is Map) return Map<String, dynamic>.from(reference);
    final refs = envelope['refs'];
    final value = refs is Map ? refs['$reference'] : null;
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  ConfigurationMap get root =>
      envelope.containsKey('refs') ? resolve(envelope['uid']) : envelope;

  List<ConfigurationMap> nodesAt(List<String> path) {
    List<ConfigurationMap> descend(
      ConfigurationMap node,
      List<String> remaining,
      int depth,
    ) {
      if (depth > 64) return [];
      if (remaining.isEmpty) {
        return [
          node,
          if (node['type'] == 'transform')
            ...descend(resolve(node['inner']), remaining, depth + 1),
          if (node['type'] == 'union' || node['type'] == 'intersect')
            for (final branch in node['list'] as List? ?? [])
              ...descend(resolve(branch), remaining, depth + 1),
        ];
      }
      switch (node['type']) {
        case 'object':
          final dict = node['dict'];
          if (dict is! Map || !dict.containsKey(remaining.first)) return [];
          return descend(
            resolve(dict[remaining.first]),
            remaining.sublist(1),
            depth + 1,
          );
        case 'array':
        case 'dict':
          return descend(
            resolve(node['inner']),
            remaining.sublist(1),
            depth + 1,
          );
        case 'transform':
          return descend(resolve(node['inner']), remaining, depth + 1);
        case 'union':
        case 'intersect':
          return [
            for (final branch in node['list'] as List? ?? [])
              ...descend(resolve(branch), remaining, depth + 1),
          ];
        default:
          return [];
      }
    }

    return descend(root, path, 0);
  }

  bool containsSecret(ConfigurationMap node, [Set<dynamic>? visited]) {
    if ((node['meta'] as Map?)?['role'] == 'secret') return true;
    final seen = {...?visited};
    final uid = node['uid'];
    if (uid != null && !seen.add(uid)) return false;
    return [
      ...(node['dict'] as Map? ?? {}).values,
      if (node['inner'] != null) node['inner'],
      ...node['list'] as List? ?? [],
    ].any((child) => containsSecret(resolve(child), seen));
  }
}

class ConfigurationProtection {
  ConfigurationProtection(ConfigurationMap descriptor)
    : schema = ConfigurationSchema(descriptor['schema']),
      paths = [
        for (final secret in descriptor['secrets'] as List? ?? [])
          (secret['path'] as List).cast<String>(),
      ];
  final ConfigurationSchema schema;
  final List<List<String>> paths;

  bool isSecret(List<String> path) =>
      paths.any((secret) => _prefix(secret, path)) ||
      List.generate(path.length + 1, (index) => path.sublist(0, index)).any(
        (parent) => schema
            .nodesAt(parent)
            .any((node) => (node['meta'] as Map?)?['role'] == 'secret'),
      );

  bool containsSecret(List<String> path) =>
      isSecret(path) ||
      paths.any((secret) => _prefix(path, secret)) ||
      schema.nodesAt(path).any(schema.containsSecret);

  void reject(List<String> path) => throw ConfigurationEditException(
    '“${configurationPathLabel(path)}”包含受保护的凭据。'
    '请保留此字段及其容器；凭据通过专门入口管理。',
  );
}

/// Produces only user-intended leaf edits from a redacted resolved snapshot.
/// A secret-bearing array cannot be rewritten or reordered from this view.
List<ConfigurationMap> configurationEdits(
  ConfigurationMap descriptor,
  ConfigurationMap draft,
) {
  final protection = ConfigurationProtection(descriptor);
  final operations = <ConfigurationMap>[];
  void walk(dynamic before, dynamic after, List<String> path) {
    if (configurationEqual(before, after)) return;
    if (protection.isSecret(path)) protection.reject(path);
    if (before is List || after is List) {
      if (protection.containsSecret(path)) protection.reject(path);
    } else if (after is Map && (before is Map || identical(before, _missing))) {
      final old = before is Map ? before : const {};
      final keys = {...old.keys, ...after.keys}.cast<String>();
      if (keys.isEmpty && !protection.containsSecret(path)) {
        operations.add({'op': 'set', 'path': path, 'value': {}});
      }
      for (final key in keys) {
        walk(
          old.containsKey(key) ? old[key] : _missing,
          after.containsKey(key) ? after[key] : _missing,
          [...path, key],
        );
      }
      return;
    }
    if (protection.containsSecret(path)) protection.reject(path);
    operations.add(
      identical(after, _missing)
          ? {'op': 'unset', 'path': path}
          : {'op': 'set', 'path': path, 'value': after},
    );
  }

  walk(configurationObject(descriptor['value']), draft, []);
  return operations;
}

class ConfigurationReset {
  const ConfigurationReset(this.operations, this.preserved);
  final List<ConfigurationMap> operations;
  final List<List<String>> preserved;
}

/// Removes ordinary user overrides while keeping secrets and their arrays.
ConfigurationReset configurationReset(ConfigurationMap descriptor) {
  final protection = ConfigurationProtection(descriptor);
  final operations = <ConfigurationMap>[];
  final preserved = <List<String>>[];
  void walk(dynamic value, List<String> path) {
    if (protection.isSecret(path) ||
        value is List && protection.containsSecret(path)) {
      preserved.add(path);
      return;
    }
    if (value is Map && protection.containsSecret(path)) {
      for (final entry in value.entries) {
        walk(entry.value, [...path, entry.key as String]);
      }
      return;
    }
    operations.add({'op': 'unset', 'path': path});
  }

  final user = descriptor['user'];
  if (user is Map) {
    for (final entry in user.entries) {
      walk(entry.value, [entry.key as String]);
    }
  }
  for (final secret in descriptor['secrets'] as List? ?? []) {
    if (secret['set'] == true) {
      final path = (secret['path'] as List).cast<String>();
      if (!preserved.any((parent) => _prefix(parent, path))) {
        preserved.add(path);
      }
    }
  }
  return ConfigurationReset(operations, preserved);
}

void applyConfigurationEdit(
  ConfigurationMap target,
  ConfigurationMap operation,
) {
  final path = (operation['path'] as List).cast<String>();
  if (path.isEmpty) {
    throw const ConfigurationEditException('不支持替换整个配置。');
  }
  var parent = target;
  for (final key in path.take(path.length - 1)) {
    final value = parent[key];
    if (value is! ConfigurationMap) {
      parent[key] = <String, dynamic>{};
    }
    parent = parent[key] as ConfigurationMap;
  }
  if (operation['op'] == 'unset') {
    parent.remove(path.last);
  } else {
    parent[path.last] = jsonDecode(jsonEncode(operation['value']));
  }
}

class ConfigurationConflict {
  const ConfigurationConflict({
    required this.path,
    required this.before,
    required this.local,
    required this.remote,
  });
  final List<String> path;
  final dynamic before, local, remote;
  String get id => jsonEncode(path);
}

class ConfigurationRebase {
  const ConfigurationRebase(this.value, this.conflicts);
  final ConfigurationMap value;
  final List<ConfigurationConflict> conflicts;
}

/// Replays local leaf intent on the latest snapshot. Same-field changes require
/// an explicit choice; unrelated remote edits are retained.
ConfigurationRebase rebaseConfiguration(
  ConfigurationMap previous,
  ConfigurationMap draft,
  ConfigurationMap latest, {
  Map<String, bool> useLocal = const {},
}) {
  final operations = configurationEdits(previous, draft);
  final next = cloneConfiguration(configurationObject(latest['value']));
  final conflicts = <ConfigurationConflict>[];
  final protection = ConfigurationProtection(latest);
  for (final operation in operations) {
    final path = (operation['path'] as List).cast<String>();
    if (protection.containsSecret(path)) protection.reject(path);
    final before = configurationValueAt(previous['value'], path);
    final remote = configurationValueAt(latest['value'], path);
    final local = operation['op'] == 'unset' ? _missing : operation['value'];
    final parentChanged =
        List.generate(path.length, (index) => path.sublist(0, index)).any((
          parent,
        ) {
          final oldParent = configurationValueAt(previous['value'], parent);
          final newParent = configurationValueAt(latest['value'], parent);
          return oldParent is Map && newParent is! Map;
        });
    if (!configurationEqual(before, remote) || parentChanged) {
      if (configurationEqual(local, remote)) continue;
      final conflict = ConfigurationConflict(
        path: path,
        before: before,
        local: local,
        remote: remote,
      );
      if (!useLocal.containsKey(conflict.id)) {
        conflicts.add(conflict);
        continue;
      }
      if (!useLocal[conflict.id]!) continue;
    }
    applyConfigurationEdit(next, operation);
  }
  return ConfigurationRebase(next, conflicts);
}
