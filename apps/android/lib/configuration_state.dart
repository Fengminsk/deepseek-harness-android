import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'configuration_edits.dart';
import 'runtime.dart';

const configurationRequestTimeout = Duration(seconds: 20);

/// Revisioned editing over the original Settings API. A descriptor passed by a
/// caller is display context, never evidence that the current host accepts it.
class ConfigurationEditingController extends ChangeNotifier {
  ConfigurationEditingController(
    this.runtime, {
    required this.namespace,
    Json? descriptor,
  }) : _connection = runtime.connectionGeneration,
       _phase = runtime.phase,
       _forms = runtime.forms {
    if (descriptor != null) {
      accepted = _descriptor(descriptor);
      draft = cloneConfiguration(configurationObject(accepted!['value']));
    }
    runtime.addListener(_runtimeChanged);
  }

  final RuntimeController runtime;
  final String namespace;
  Json? accepted, draft, latest;
  bool fresh = false, loading = false, busy = false, writable = false;
  bool uncertain = false;
  bool _externalDraft = false;
  String? notice;
  String? _readError, _writeError;
  String? get error {
    final parts = [_readError, _writeError].whereType<String>();
    return parts.isEmpty ? null : parts.join('\n');
  }

  bool get hasDraft =>
      uncertain ||
      _externalDraft ||
      draft != null && !configurationEqual(draft, accepted?['value']);
  bool get conflict => latest != null || _writeConflict;
  bool get canEdit => accepted != null && !busy && !uncertain;
  bool get canSave =>
      canEdit && fresh && runtime.ready && writable && !conflict && hasDraft;

  bool _disposed = false, _started = false, _writing = false;
  bool _again = false, _scheduled = false, _writeConflict = false;
  int _connection, _read = 0;
  String _phase;
  Object? _forms;
  Future<void>? _refresh;
  List<Json>? _pendingOperations;

  Json _descriptor(dynamic raw) {
    if (raw is! Json ||
        raw['ns'] != namespace ||
        raw['revision'] is! int ||
        (raw['revision'] as int) < 0 ||
        raw['value'] is! Json ||
        raw['schema'] is! Map ||
        raw['secrets'] is! List ||
        raw['user'] != null && raw['user'] is! Json) {
      throw const FormatException('配置版本或字段不完整');
    }
    return cloneConfiguration(raw);
  }

  Future<dynamic> _api(String method, [Json args = const {}]) => runtime
      .call('api.call', {
        'namespace': 'settings',
        'method': method,
        'args': args,
      })
      .timeout(configurationRequestTimeout);

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _runtimeChanged() {
    final connectionChanged =
        _connection != runtime.connectionGeneration || _phase != runtime.phase;
    final formsChanged = !identical(_forms, runtime.forms);
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    _forms = runtime.forms;
    if (connectionChanged) {
      _read++;
      _refresh = null;
      loading = fresh = false;
      if (_writing) uncertain = true;
      _readError = '连接已变化，需重新核对配置；草稿已保留。';
      _publish();
    }
    if (_started && runtime.ready && (connectionChanged || formsChanged)) {
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    if (_disposed) return;
    fresh = false;
    _read++;
    _again = true;
    _publish();
    if (_scheduled || _refresh != null || _writing) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed && runtime.ready && !_writing) unawaited(refresh());
    });
  }

  Future<void> start() => refresh();

  Future<void> refresh() {
    if (_disposed) return Future.value();
    _started = true;
    if (_writing) {
      _again = true;
      return Future.value();
    }
    if (_refresh != null) return _refresh!;
    if (!runtime.ready) {
      loading = fresh = false;
      _readError = '本地服务尚未就绪；草稿已保留。';
      _publish();
      return Future.value();
    }
    final read = ++_read;
    final connection = runtime.connectionGeneration;
    _again = false;
    loading = true;
    fresh = false;
    _readError = null;
    _publish();
    bool current() =>
        !_disposed &&
        read == _read &&
        connection == runtime.connectionGeneration &&
        runtime.ready;
    late final Future<void> operation;
    operation =
        () async {
          try {
            final raw = await _api('describe');
            if (!current()) return;
            if (raw is! Json ||
                raw['writable'] is! bool ||
                raw['namespaces'] is! List) {
              throw const FormatException('配置目录不完整');
            }
            final candidates = (raw['namespaces'] as List)
                .where((row) => row is Json && row['ns'] == namespace)
                .toList();
            if (candidates.length != 1) {
              throw const FormatException('此配置已不可用，请核对插件状态');
            }
            final next = _descriptor(candidates.single);
            writable = raw['writable'] as bool;
            _acceptRead(next);
            fresh = true;
          } catch (failure) {
            if (!current()) return;
            fresh = false;
            _readError = '无法核对配置：$failure\n草稿已保留。';
          } finally {
            if (current()) {
              loading = false;
              _publish();
            }
          }
        }().whenComplete(() {
          if (!identical(_refresh, operation)) return;
          _refresh = null;
          if (!_disposed) {
            loading = false;
            _publish();
            if (_again && runtime.ready && !_writing) _scheduleRefresh();
          }
        });
    return _refresh = operation;
  }

  bool _matchesOperations(Json observed, List<Json> operations) {
    for (final operation in operations) {
      final path = (operation['path'] as List).cast<String>();
      if (operation['op'] == 'unset') {
        // ConfigEditor persists a full next config when other overrides remain.
        // An unset can therefore still appear in `user` with its inherited value;
        // compare the resolved outcome against this observation's actual base.
        if (!configurationEqual(
          configurationValueAt(observed['value'], path),
          configurationValueAt(observed['base'] ?? <String, dynamic>{}, path),
        )) {
          return false;
        }
      } else if (!configurationEqual(
        configurationValueAt(observed['value'], path),
        operation['value'],
      )) {
        return false;
      }
    }
    return true;
  }

  void _adopt(Json value) {
    accepted = cloneConfiguration(value);
    draft = cloneConfiguration(configurationObject(value['value']));
    latest = null;
    _writeConflict = false;
    _externalDraft = false;
  }

  void _acceptRead(Json next) {
    if (uncertain) {
      latest = next;
      if (_pendingOperations != null &&
          _matchesOperations(next, _pendingOperations!)) {
        _adopt(next);
        uncertain = false;
        _pendingOperations = null;
        _writeError = null;
        notice = '已核对当前配置与目标一致。';
      }
      return;
    }
    if (accepted == null || !hasDraft && !_writeConflict) {
      _adopt(next);
    } else if (_writeConflict ||
        next['revision'] != accepted!['revision'] ||
        !configurationEqual(next['value'], accepted!['value']) ||
        !configurationEqual(next['user'], accepted!['user'])) {
      latest = next;
    }
  }

  void replaceDraft(Json value, {bool? holdExternalDraft}) {
    if (!canEdit) return;
    // Keep the existing secret and protected-array policy at the state boundary.
    configurationEdits(accepted!, value);
    draft = cloneConfiguration(value);
    // A valid field edit must not erase another field's invalid text. Only the
    // owner of that external buffer can explicitly release its hold.
    if (holdExternalDraft != null) _externalDraft = holdExternalDraft;
    _writeError = notice = null;
    _publish();
  }

  /// Retain the baseline while a page owns temporarily invalid raw input.
  void holdDraft(bool held) {
    if (!canEdit || _externalDraft == held) return;
    _externalDraft = held;
    _publish();
  }

  void edit(List<String> path, dynamic value, {bool remove = false}) {
    if (!canEdit || draft == null) return;
    final next = cloneConfiguration(draft!);
    applyConfigurationEdit(next, {
      'op': remove ? 'unset' : 'set',
      'path': path,
      if (!remove) 'value': value,
    });
    replaceDraft(next);
  }

  /// Explicitly merge a fresh observation into the draft without writing it.
  bool rebase({Map<String, bool> useLocal = const {}}) {
    if (!fresh ||
        busy ||
        uncertain ||
        latest == null ||
        accepted == null ||
        draft == null) {
      return false;
    }
    final merged = rebaseConfiguration(
      accepted!,
      draft!,
      latest!,
      useLocal: useLocal,
    );
    if (merged.conflicts.isNotEmpty) {
      notice = '请先为每一处冲突选择要保留的内容。';
      _publish();
      return false;
    }
    accepted = cloneConfiguration(latest!);
    draft = merged.value;
    latest = null;
    _writeConflict = false;
    _writeError = null;
    notice = '已合并到草稿，尚未保存。';
    _publish();
    return true;
  }

  /// Adopt an explicitly reviewed live state, including abandoning uncertainty.
  void discardDraft() {
    if (!fresh || busy || accepted == null) return;
    _adopt(latest ?? accepted!);
    uncertain = false;
    _pendingOperations = null;
    _writeError = notice = null;
    _publish();
  }

  Future<bool> save({List<Json>? operations}) async {
    if (_disposed ||
        busy ||
        uncertain ||
        conflict ||
        accepted == null ||
        draft == null) {
      return false;
    }
    final before = cloneConfiguration(accepted!);
    final target = cloneConfiguration(draft!);
    final requestedConnection = runtime.connectionGeneration;
    final requested = operations == null
        ? configurationEdits(before, target)
        : operations.map(cloneConfiguration).toList();
    if (requested.isEmpty) {
      notice = '没有需要保存的修改。';
      _publish();
      return true;
    }
    // Explicit reset operations may target inherited values differently from a
    // draft diff, but still cannot cross the same credential protection fence.
    final protection = ConfigurationProtection(before);
    for (final operation in requested) {
      final path = (operation['path'] as List).cast<String>();
      if (path.isEmpty || protection.containsSecret(path)) {
        protection.reject(path);
      }
    }
    busy = true;
    _writeError = notice = null;
    _publish();
    var submitted = false;
    try {
      await refresh();
      if (_disposed ||
          !fresh ||
          !runtime.ready ||
          !writable ||
          conflict ||
          runtime.connectionGeneration != requestedConnection ||
          accepted!['revision'] != before['revision']) {
        return false;
      }
      final connection = runtime.connectionGeneration;
      _pendingOperations = requested;
      _writing = submitted = true;
      final raw = await _api('mutate', {
        'ns': namespace,
        'ops': requested,
        'expectedRevision': before['revision'],
      });
      if (_disposed) return false;
      if (!runtime.ready || connection != runtime.connectionGeneration) {
        uncertain = true;
        fresh = false;
        _writeError = '连接变化，保存结果尚未确认；请核对，不会自动重发。';
        return false;
      }
      final saved = _descriptor(raw);
      if (!_matchesOperations(saved, requested)) {
        throw const FormatException('保存回执未确认全部目标字段');
      }
      _adopt(saved);
      uncertain = false;
      _pendingOperations = null;
      _writeError = null;
      notice = '已保存并应用。';
      return true;
    } catch (failure) {
      if (_disposed) return false;
      final code = failure is PlatformException ? failure.code : null;
      // SettingsForms may commit before a post-write describe fails, and its
      // Remote wrapper also calls that settings/rejected. Only a version
      // conflict proves admission was refused before the write.
      final rejected = code == 'settings/conflict';
      _writeConflict = code == 'settings/conflict';
      uncertain = submitted && !rejected;
      if (!uncertain) _pendingOperations = null;
      fresh = false;
      _writeError = uncertain
          ? '保存结果尚未确认；草稿已保留，请核对，不会自动重发。'
          : rejected
          ? '配置版本已变化；草稿已保留，请比较后再合并。'
          : '未能保存：$failure\n草稿已保留。';
      return false;
    } finally {
      _writing = false;
      if (!_disposed) {
        busy = false;
        _publish();
        if (submitted || _again) await refresh();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _read++;
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}
