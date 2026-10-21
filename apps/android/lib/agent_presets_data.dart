import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';

const agentPresetSettingsNamespace = 'agent-preset-registry';
const agentPresetRequestTimeout = Duration(seconds: 20);

class AgentPresetOption {
  const AgentPresetOption({
    required this.id,
    this.name,
    this.description,
    this.broken,
    this.isDefault = false,
  });

  final String id;
  final String? name, description, broken;
  final bool isDefault;
  String get label => name?.trim().isNotEmpty == true ? name! : id;
  bool get available => broken == null;

  factory AgentPresetOption.fromJson(dynamic value) {
    final row = _object(value, '预设目录');
    if (row['isDefault'] is! bool) throw const FormatException('预设默认状态缺失');
    return AgentPresetOption(
      id: _id(row['id']),
      name: _optionalText(row['name']),
      description: _optionalText(row['description']),
      broken: _optionalText(row['broken']),
      isDefault: row['isDefault'] as bool,
    );
  }
}

class AgentPresetDocument {
  const AgentPresetDocument({
    required this.agentPreset,
    required this.content,
    this.name,
    this.description,
  });

  final String agentPreset, content;
  final String? name, description;
}

Json _object(dynamic value, String label) {
  if (value is! Json) throw FormatException('$label 数据不完整');
  return value;
}

String _id(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('预设标识缺失');
  }
  return value;
}

String? _optionalText(dynamic value) {
  if (value != null && value is! String) {
    throw const FormatException('预设说明格式不正确');
  }
  return value as String?;
}

String? _effectiveDefault(Json descriptor) {
  final value = _object(descriptor['value'], '默认预设设置');
  final selected = value['selectedDefault'] ?? value['default'];
  return selected == null ? null : _id(selected);
}

class _PresetSnapshot {
  const _PresetSnapshot({
    required this.options,
    required this.defaultId,
    required this.appliedId,
    required this.writable,
    required this.revision,
    required this.sessionExists,
    required this.sessionStarted,
  });
  final List<AgentPresetOption> options;
  final String? defaultId, appliedId;
  final bool writable, sessionExists;
  final bool? sessionStarted;
  final int? revision;
}

/// Read observations and local choices over the original preset and settings APIs.
/// Opening this controller never creates or resumes a conversation.
class AgentPresetsController extends ChangeNotifier {
  AgentPresetsController(this.runtime, {this.sessionId})
    : _phase = runtime.phase,
      _connection = runtime.connectionGeneration,
      _forms = runtime.forms,
      _sessions = runtime.sessions,
      _sessionStatus = runtime.statuses[sessionId] {
    runtime.addListener(_runtimeChanged);
  }

  final RuntimeController runtime;
  final String? sessionId;
  List<AgentPresetOption> options = const [];
  String? appliedId, draftId, defaultId, notice;
  // A successful observation must not erase a refused or unconfirmed mutation.
  String? _observationError, _mutationError;
  String? get error {
    final messages = [_observationError, _mutationError].whereType<String>();
    return messages.isEmpty ? null : messages.join('\n');
  }

  bool loading = false, busy = false, fresh = false;
  bool conflict = false, uncertain = false, sessionExists = false;
  bool? sessionStarted;
  bool get isSession => sessionId != null;
  bool get hasDraft => draftId != null && draftId != appliedId;
  bool get canChoose =>
      fresh &&
      runtime.ready &&
      !busy &&
      !uncertain &&
      (!isSession || sessionStarted == false);
  bool get canApply =>
      canChoose &&
      hasDraft &&
      !conflict &&
      !uncertain &&
      (isSession || _writable && _revision != null) &&
      options.any((option) => option.id == draftId && option.available);

  bool _disposed = false, _observing = false, _writing = false;
  bool _refreshAgain = false, _refreshScheduled = false, _writable = false;
  String _phase;
  String? _sessionStatus;
  int _connection, _read = 0, _watch = 0;
  int? _revision, _draftRevision;
  Object? _forms, _sessions;
  Future<void>? _refresh;
  StreamSubscription<Json>? _observation;

  Future<dynamic> _api(
    String namespace,
    String method, [
    Json args = const {},
  ]) => runtime
      .call('api.call', {
        'namespace': namespace,
        'method': method,
        'args': args,
      })
      .timeout(agentPresetRequestTimeout);

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _runtimeChanged() {
    final changed =
        _phase != runtime.phase || _connection != runtime.connectionGeneration;
    final settingsChanged = !identical(_forms, runtime.forms);
    final sessionChanged =
        !identical(_sessions, runtime.sessions) ||
        _sessionStatus != runtime.statuses[sessionId];
    _forms = runtime.forms;
    _sessions = runtime.sessions;
    _sessionStatus = runtime.statuses[sessionId];
    if (changed) {
      _phase = runtime.phase;
      _connection = runtime.connectionGeneration;
      _read++;
      _refresh = null;
      loading = false;
      fresh = false;
      if (_writing) uncertain = true;
      _observationError = '连接已变化，正在重新核对；尚未应用的选择已保留。';
      _publish();
    }
    if (_observing &&
        runtime.ready &&
        (changed || settingsChanged || isSession && sessionChanged)) {
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    if (_disposed || !_observing) return;
    fresh = false;
    _read++;
    _refreshAgain = true;
    _publish();
    if (_refreshScheduled || _refresh != null || _writing) return;
    _refreshScheduled = true;
    scheduleMicrotask(() {
      _refreshScheduled = false;
      if (!_disposed && runtime.ready && !_writing) unawaited(load());
    });
  }

  void _invalidateObservation(String message) {
    // Detach the obsolete read so an explicit retry does not join its future.
    // Its eventual completion is fenced by both the read token and identity.
    _read++;
    _refresh = null;
    loading = fresh = false;
    _observationError = message;
    _publish();
  }

  void _observe() {
    _observing = true;
    if (!isSession || _observation != null) return;
    final watch = ++_watch;
    _observation = runtime
        .watchApi('session', 'control')
        .listen(
          (frame) {
            if (_disposed || watch != _watch) return;
            final type = frame['type'];
            if (type == 'opening' ||
                type == 'disconnected' ||
                type == 'error') {
              _invalidateObservation('会话同步尚未确认，请刷新核对。');
            } else if (type == 'item') {
              final value = frame['value'];
              if (value is Json &&
                  (value['type'] == 'baseline' ||
                      value['type'] == 'projection' &&
                          value['sessionId'] == sessionId &&
                          value['key'] == 'agentPreset')) {
                _scheduleRefresh();
              }
            } else if (type == 'end') {
              _invalidateObservation('会话同步已结束，请刷新核对。');
            }
          },
          onError: (Object failure) {
            if (_disposed || watch != _watch) return;
            _invalidateObservation('会话同步暂不可用，请刷新核对。');
          },
          onDone: () {
            if (_disposed || watch != _watch) return;
            _observation = null;
            _invalidateObservation('会话同步已结束，请刷新核对。');
          },
        );
  }

  Future<_PresetSnapshot> _fetch() async {
    List<AgentPresetOption> roster;
    try {
      final result = _object(await _api('agentPresets', 'list'), '预设目录');
      if (result['presets'] is! List) throw const FormatException('预设目录缺失');
      roster = (result['presets'] as List)
          .map(AgentPresetOption.fromJson)
          .toList(growable: false);
      if (roster.map((option) => option.id).toSet().length != roster.length) {
        throw const FormatException('预设目录包含重复标识');
      }
    } on PlatformException catch (failure) {
      if (failure.code != 'gateway/invocation-unavailable') rethrow;
      roster = const [];
    }
    final settings = _object(await _api('settings', 'describe'), '预设设置');
    if (settings['namespaces'] is! List || settings['writable'] is! bool) {
      throw const FormatException('预设设置状态缺失');
    }
    Json? descriptor;
    for (final raw in settings['namespaces'] as List) {
      final row = _object(raw, '配置项');
      if (row['ns'] == agentPresetSettingsNamespace) descriptor = row;
    }
    final revision = descriptor?['revision'];
    if (descriptor != null && (revision is! int || revision < 0)) {
      throw const FormatException('预设配置版本缺失');
    }
    String? defaultPreset = descriptor == null
        ? null
        : _effectiveDefault(descriptor);
    final defaults = roster.where((row) => row.isDefault).toList();
    if (defaults.length > 1) throw const FormatException('默认预设状态不一致');
    defaultPreset ??= defaults.isEmpty ? null : defaults.single.id;
    String? applied = defaultPreset;
    var exists = false;
    bool? started;
    if (isSession) {
      // The exported list owns blank status; turnBoundary is an internal state
      // projection and is not fabricated in the Android client.
      final listed = _object(
        await _api('session', 'list', {'_request': {}}),
        '会话目录',
      );
      if (listed['items'] is! List) throw const FormatException('会话目录缺失');
      Json? session;
      for (final item in listed['items'] as List) {
        final row = _object(item, '会话');
        if (row['sessionId'] == sessionId) session = row;
      }
      final projected = await _api('session', 'projections', {
        'request': {'sessionId': sessionId},
      });
      if (session == null && projected == null) {
        started = false;
      } else {
        if (session == null || projected == null || session['blank'] is! bool) {
          throw const FormatException('会话状态正在变化，请重新核对');
        }
        final projection = _object(projected, '会话预设');
        if (projection['kind'] != 'sequenced' ||
            projection['asOfSeq'] is! int) {
          throw const FormatException('会话需要完成迁移或重新同步后才能选择预设');
        }
        final values = _object(projection['values'], '会话预设');
        if (!values.containsKey('agentPreset')) {
          throw const FormatException('未取得会话的实际预设');
        }
        applied = values['agentPreset'] == null
            ? null
            : _id(values['agentPreset']);
        exists = true;
        started = session['blank'] != true;
      }
    }
    return _PresetSnapshot(
      options: List.unmodifiable(roster),
      defaultId: defaultPreset,
      appliedId: applied,
      writable: settings['writable'] == true,
      revision: revision as int?,
      sessionExists: exists,
      sessionStarted: started,
    );
  }

  void _accept(_PresetSnapshot next) {
    final keepDraft = hasDraft || uncertain;
    final oldApplied = appliedId;
    options = next.options;
    defaultId = next.defaultId;
    appliedId = next.appliedId;
    _writable = next.writable;
    _revision = next.revision;
    sessionExists = next.sessionExists;
    sessionStarted = sessionStarted == true ? true : next.sessionStarted;
    if (!keepDraft) {
      draftId = appliedId;
      _draftRevision = _revision;
      conflict = false;
    } else if (draftId == appliedId) {
      conflict = false;
      uncertain = false;
      _mutationError = null;
      _draftRevision = _revision;
      notice = '已核对当前预设。';
    } else if (oldApplied != appliedId ||
        !isSession && _draftRevision != _revision) {
      conflict = true;
    }
    fresh = true;
  }

  Future<void> refresh() => load();

  Future<void> load() {
    if (_disposed) return Future.value();
    _observe();
    if (_writing) {
      _refreshAgain = true;
      return Future.value();
    }
    if (_refresh != null) return _refresh!;
    if (!runtime.ready) {
      fresh = false;
      loading = false;
      _observationError = '本地服务尚未就绪，恢复后会重新读取。';
      _publish();
      return Future.value();
    }
    _refreshAgain = false;
    final read = ++_read;
    final connection = runtime.connectionGeneration;
    loading = true;
    fresh = false;
    _observationError = null;
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
            final next = await _fetch();
            if (!current()) return;
            _accept(next);
          } catch (failure) {
            if (!current()) return;
            fresh = false;
            _observationError = '无法读取预设，请刷新重试：$failure';
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
            if (_refreshAgain && runtime.ready && !_writing) _scheduleRefresh();
          }
        });
    return _refresh = operation;
  }

  void select(String id) {
    if (!canChoose || uncertain) return;
    if (!options.any((row) => row.id == id && row.available)) return;
    draftId = id;
    _draftRevision = _revision;
    conflict = false;
    _observationError = _mutationError = notice = null;
    _publish();
  }

  void discardDraft() {
    if (busy) return;
    draftId = appliedId;
    _draftRevision = _revision;
    conflict = uncertain = false;
    _observationError = _mutationError = notice = null;
    _publish();
  }

  void rebaseDraft() {
    if (!fresh || busy || uncertain) return;
    _draftRevision = _revision;
    conflict = false;
    _observationError = _mutationError = notice = null;
    _publish();
  }

  Future<void> apply() async {
    if (_disposed || busy || uncertain || conflict || !hasDraft) return;
    final wanted = draftId!;
    busy = true;
    notice = _observationError = _mutationError = null;
    _publish();
    var submitted = false;
    var connection = runtime.connectionGeneration;
    try {
      await load();
      if (_disposed ||
          !fresh ||
          !runtime.ready ||
          draftId != wanted ||
          conflict ||
          uncertain ||
          sessionStarted == true ||
          !options.any((row) => row.id == wanted && row.available)) {
        return;
      }
      if (!isSession && (!_writable || _revision == null)) {
        _mutationError = '当前运行配置不允许修改默认预设。';
        return;
      }
      connection = runtime.connectionGeneration;
      _writing = submitted = true;
      final result = isSession
          ? await runtime
                .call('session.selectPreset', {
                  'sessionId': sessionId,
                  'agentPreset': wanted,
                })
                .timeout(agentPresetRequestTimeout)
          : await _api('settings', 'update', {
              'ns': agentPresetSettingsNamespace,
              'patch': {'selectedDefault': wanted},
              'expectedRevision': _draftRevision,
            });
      if (_disposed) return;
      if (!runtime.ready || connection != runtime.connectionGeneration) {
        uncertain = true;
        fresh = false;
        _mutationError = '连接变化，应用结果尚未确认；请刷新核对，不会自动重发。';
        return;
      }
      final applied = isSession
          ? _id(result)
          : _effectiveDefault(_object(result, '默认预设保存结果'));
      if (applied != wanted) throw const FormatException('保存返回的预设与所选项不一致');
      appliedId = draftId = applied;
      if (isSession) sessionExists = true;
      conflict = uncertain = false;
      notice = isSession ? '已应用此会话的 Agent 预设。' : '已保存默认 Agent 预设。';
      _refreshAgain = true;
    } catch (failure) {
      if (_disposed) return;
      final code = failure is PlatformException ? failure.code : null;
      final rejected =
          code == 'settings/conflict' ||
          code == 'settings/rejected' ||
          code == 'agent-preset/locked' ||
          code == 'agent-preset/not-found' ||
          code == 'agent-preset/invalid';
      if (code == 'settings/conflict') conflict = true;
      if (code == 'agent-preset/locked') sessionStarted = true;
      uncertain = submitted && !rejected;
      fresh = false;
      _mutationError = uncertain
          ? '应用结果尚未确认，选择已保留；请刷新核对，不会自动重发。'
          : '未能应用预设，选择已保留：$failure';
      _refreshAgain = true;
    } finally {
      _writing = false;
      if (!_disposed) {
        busy = false;
        _publish();
        if (_refreshAgain && runtime.ready) unawaited(load());
      }
    }
  }

  Future<AgentPresetDocument> readDocument(String id) async {
    if (_disposed || !runtime.ready) throw StateError('本地服务尚未就绪');
    final connection = runtime.connectionGeneration;
    final raw = _object(
      await _api('agentPresets', 'read', {'agentPreset': id}),
      '预设声明',
    );
    if (_disposed ||
        !runtime.ready ||
        connection != runtime.connectionGeneration) {
      throw StateError('连接已变化，请重新读取预设声明');
    }
    if (_id(raw['agentPreset']) != id || raw['content'] is! String) {
      throw const FormatException('预设声明与请求不一致');
    }
    return AgentPresetDocument(
      agentPreset: id,
      content: raw['content'] as String,
      name: _optionalText(raw['name']),
      description: _optionalText(raw['description']),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _read++;
    _watch++;
    runtime.removeListener(_runtimeChanged);
    unawaited(_observation?.cancel());
    super.dispose();
  }
}
