import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'configuration_edits.dart';
import 'runtime.dart';

const credentialRequestTimeout = Duration(seconds: 20);

/// The reference grammar and describe batch bound belong to DSH's Remote API.
bool validCredentialReference(String value) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);

class CredentialUse {
  CredentialUse(this.namespace, this.path);
  final String namespace;
  final List<String> path;
  String get label => '$namespace · ${path.join('.')}';
}

/// Only schema-declared references are collected; secret fields are not read.
Map<String, List<CredentialUse>> credentialUses(List<Json> forms) {
  final found = <String, List<CredentialUse>>{};
  for (final form in forms) {
    final namespace = form['ns'];
    if (namespace is! String) {
      throw const FormatException('Missing settings namespace');
    }
    final schema = ConfigurationSchema(form['schema']);
    void visit(dynamic value, List<String> path) {
      if (path.length > 64) {
        throw const FormatException(
          'Settings nesting exceeds schema traversal',
        );
      }
      final nodes = schema.nodesAt(path);
      if (nodes.any((node) => node['meta']?['role'] == 'secret')) return;
      if (nodes.any((node) => node['meta']?['role'] == 'credential-ref')) {
        if (value is String && validCredentialReference(value)) {
          found
              .putIfAbsent(value, () => [])
              .add(CredentialUse(namespace, path));
        }
        return;
      }
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key is String) visit(entry.value, [...path, entry.key]);
        }
      } else if (value is List) {
        for (var index = 0; index < value.length; index++) {
          visit(value[index], [...path, '$index']);
        }
      }
    }

    visit(form['value'], []);
  }
  return found;
}

class CredentialView {
  CredentialView(this.configured, this.writable, this.source);
  final bool configured, writable;
  final String? source;

  factory CredentialView.read(dynamic value) {
    if (value is! Map ||
        value['configured'] is! bool ||
        value['writable'] is! bool ||
        value['source'] != null && value['source'] is! String) {
      throw const FormatException('Invalid credential status');
    }
    // Do not retain unexpected fields from the process boundary.
    return CredentialView(
      value['configured'] as bool,
      value['writable'] as bool,
      value['source'] as String?,
    );
  }
}

class CredentialWrite {
  CredentialWrite(this.removing);
  final bool removing;
  String state = 'pending';
  bool inFlight = true;
  String? notice;
}

class CredentialEntry {
  CredentialEntry(this.reference);
  final String reference;
  List<CredentialUse> uses = [];
  CredentialView? status;
  bool fresh = false, reading = false, manual = false;
  int readGeneration = 0, draftRevision = 0;
  String draft = '';
  String? readError;
  CredentialWrite? write;
}

String _failureLabel(Object failure) {
  final code = failure is PlatformException ? failure.code : null;
  return switch (code) {
    'gateway/bad-request' => '请求被原服务拒绝',
    'credential/rejected' => '凭据存储未确认写入',
    'disconnected' || 'closed' || 'not-ready' => '运行时连接不可用',
    _ => failure is TimeoutException ? '等待回执超时' : '未取得有效回执',
  };
}

/// Runtime-owned state: drafts survive navigation but never enter persistence.
class CredentialsController extends ChangeNotifier {
  CredentialsController(this.runtime);
  final RuntimeController runtime;
  final entries = <String, CredentialEntry>{};
  bool loading = false, catalogFresh = false;
  String? catalogError;
  StreamSubscription<Json>? _events;
  bool _started = false, _disposed = false;
  String? _phase;
  Object? _forms, _epoch;
  int _connection = 0, _catalogRead = 0, _runtimeGeneration = 0;

  CredentialEntry entry(String reference) =>
      entries.putIfAbsent(reference, () => CredentialEntry(reference));

  Future<dynamic> _api(String method, Json args) => runtime.call('api.call', {
    'namespace': 'credentials',
    'method': method,
    'args': args,
  });

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _phase = runtime.phase;
    _epoch = runtime.taskState['epoch'];
    _forms = runtime.forms;
    _runtimeGeneration = runtime.connectionGeneration;
    runtime.addListener(_runtimeChanged);
    _events = runtime.remoteEvents.listen((event) {
      if (event['event'] != 'credentials/reference-updated') return;
      final args = event['args'];
      if (args is List && args.isNotEmpty && args.first is String) {
        final ref = args.first as String;
        if (entries.containsKey(ref)) unawaited(readReference(ref));
      }
    });
    unawaited(refresh());
  }

  void _runtimeChanged() {
    final changed =
        _runtimeGeneration != runtime.connectionGeneration ||
        _phase != runtime.phase ||
        _epoch != runtime.taskState['epoch'];
    final formsChanged = !identical(_forms, runtime.forms);
    _phase = runtime.phase;
    _epoch = runtime.taskState['epoch'];
    _forms = runtime.forms;
    _runtimeGeneration = runtime.connectionGeneration;
    if (changed) {
      _connection++;
      _catalogRead++;
      catalogFresh = false;
      loading = false;
      for (final row in entries.values) {
        row.readGeneration++;
        row.fresh = false;
        row.reading = false;
        if (row.write?.inFlight == true) {
          row.write!
            ..state = 'unconfirmed'
            ..notice = '连接已变化，写入结果未确认。输入已保留，不会自动重发。';
        }
      }
      _publish();
    }
    if (runtime.ready && (changed || formsChanged)) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final read = ++_catalogRead;
    final connection = _connection;
    if (!runtime.ready) {
      catalogFresh = false;
      loading = false;
      _publish();
      return;
    }
    loading = true;
    _publish();
    try {
      final response = await runtime
          .call('settings.describe')
          .timeout(credentialRequestTimeout);
      if (response is! List || response.any((value) => value is! Json)) {
        throw const FormatException('Invalid settings directory');
      }
      final uses = credentialUses(response.cast<Json>());
      if (_disposed || read != _catalogRead || connection != _connection) {
        return;
      }
      for (final row in entries.values) {
        row.uses = [];
      }
      for (final item in uses.entries) {
        entry(item.key).uses = item.value;
      }
      catalogFresh = true;
      catalogError = null;
      final refs = entries.keys.toList();
      // The original Remote accepts at most 64 references per describe request.
      for (var offset = 0; offset < refs.length; offset += 64) {
        if (_disposed || read != _catalogRead || connection != _connection) {
          return;
        }
        await _describe(refs.skip(offset).take(64).toList());
      }
    } catch (failure) {
      if (_disposed || read != _catalogRead || connection != _connection) {
        return;
      }
      catalogFresh = false;
      catalogError = '引用目录未确认，保留上次目录。${_failureLabel(failure)}。';
    } finally {
      if (!_disposed && read == _catalogRead) {
        loading = false;
        _publish();
      }
    }
  }

  Future<void> readReference(String reference) => _describe([reference]);

  Future<void> _describe(List<String> refs) async {
    if (_disposed) return;
    final connection = _connection;
    final generations = <String, int>{};
    for (final ref in refs) {
      final row = entry(ref);
      generations[ref] = ++row.readGeneration;
      row.fresh = false;
      row.reading = runtime.ready;
    }
    _publish();
    if (!runtime.ready) return;
    try {
      final result = await _api('describe', {
        'refs': refs,
      }).timeout(credentialRequestTimeout);
      if (result is! Map) {
        throw const FormatException('Invalid status directory');
      }
      final values = {
        for (final ref in refs) ref: CredentialView.read(result[ref]),
      };
      if (_disposed || connection != _connection) return;
      for (final ref in refs) {
        final row = entry(ref);
        if (row.readGeneration != generations[ref]) continue;
        row
          ..status = values[ref]
          ..fresh = true
          ..readError = null;
      }
    } catch (failure) {
      if (_disposed || connection != _connection) return;
      for (final ref in refs) {
        final row = entry(ref);
        if (row.readGeneration == generations[ref]) {
          row.readError = '当前状态未确认。${_failureLabel(failure)}。';
        }
      }
    } finally {
      if (!_disposed && connection == _connection) {
        for (final ref in refs) {
          final row = entry(ref);
          if (row.readGeneration == generations[ref]) row.reading = false;
        }
        _publish();
      }
    }
  }

  Future<CredentialEntry?> addReference(String reference) async {
    if (!validCredentialReference(reference)) return null;
    final row = entry(reference)..manual = true;
    await readReference(reference);
    return row;
  }

  void edit(String reference, String value) {
    final row = entry(reference);
    if (row.draft == value) return;
    row.draft = value;
    row.draftRevision++;
    _publish();
  }

  bool canWrite(CredentialEntry row) =>
      !_disposed &&
      runtime.ready &&
      row.fresh &&
      row.status?.writable == true &&
      row.write?.inFlight != true;

  Future<void> save(String reference, {bool acknowledgeUnknown = false}) async {
    final row = entry(reference);
    if (!canWrite(row) || row.draft.isEmpty) return;
    if (row.write?.state == 'unconfirmed' && !acknowledgeUnknown) return;
    await _write(row, removing: false);
  }

  Future<void> remove(String reference, {required bool confirmed}) async {
    final row = entry(reference);
    if (!confirmed || !canWrite(row)) return;
    await _write(row, removing: true);
  }

  Future<void> _write(CredentialEntry row, {required bool removing}) async {
    final action = CredentialWrite(removing);
    row.write = action;
    final connection = _connection;
    final draftRevision = row.draftRevision;
    final value = row.draft;
    _publish();
    void settle({Object? failure}) {
      action.inFlight = false;
      if (_disposed || !identical(row.write, action)) return;
      if (connection != _connection) {
        action
          ..state = 'unconfirmed'
          ..notice = '回执来自先前连接，结果未确认。输入已保留，请核对当前状态。';
      } else if (failure != null) {
        final rejected =
            failure is PlatformException &&
            failure.code == 'gateway/bad-request';
        action
          ..state = rejected ? 'rejected' : 'unconfirmed'
          ..notice = '${_failureLabel(failure)}。输入已保留，不会自动重发。配置状态不能证明本次输入已写入。';
      } else {
        action
          ..state = 'confirmed'
          ..notice = removing ? '原服务已确认移除保存的凭据。' : '原服务已确认保存凭据。';
        if (!removing && row.draftRevision == draftRevision) {
          row.draft = '';
          row.draftRevision++;
        }
      }
      _publish();
      unawaited(readReference(row.reference));
    }

    final completion =
        _api(removing ? 'unset' : 'set', {
          'ref': row.reference,
          if (!removing) 'value': value,
        }).then<void>((receipt) {
          if (receipt != null) {
            settle(failure: const FormatException('Unexpected void receipt'));
          } else {
            settle();
          }
        }, onError: (Object failure) => settle(failure: failure));
    try {
      await completion.timeout(credentialRequestTimeout);
    } on TimeoutException {
      if (!_disposed && identical(row.write, action) && action.inFlight) {
        action
          ..state = 'unconfirmed'
          ..notice = '等待回执超时，输入已保留。旧请求仍在等待结果，暂不能再次写入。';
        _publish();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connection++;
    _catalogRead++;
    runtime.removeListener(_runtimeChanged);
    unawaited(_events?.cancel());
    for (final row in entries.values) {
      row.draft = '';
    }
    entries.clear();
    super.dispose();
  }
}
