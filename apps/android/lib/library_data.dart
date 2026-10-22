import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime.dart';

const libraryRequestTimeout = Duration(seconds: 20);

String librarySessionTitle(Json session) {
  final value = session['projections']?['values']?['title'];
  return value is String && value.trim().isNotEmpty ? value : '未命名会话';
}

String libraryFailureCode(Object failure) =>
    failure is PlatformException ? failure.code : 'unconfirmed';

Json libraryFailureDetails(Object failure) {
  if (failure is! PlatformException || failure.details is! Map) return {};
  final details = Map<String, dynamic>.from(failure.details as Map);
  return details['details'] is Map
      ? Map<String, dynamic>.from(details['details'] as Map)
      : details;
}

List<Json> _rows(dynamic value) {
  if (value is! List || value.any((row) => row is! Json)) {
    throw const FormatException('Invalid library rows');
  }
  return value.cast<Json>();
}

List<String> _ids(dynamic value) {
  if (value is! List || value.any((id) => id is! String || id.trim().isEmpty)) {
    throw const FormatException('Invalid library identities');
  }
  return value.cast<String>();
}

String _identity(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Missing library identity');
  }
  return value;
}

/// Receipt state survives page navigation within its RuntimeController.
class LibraryAction {
  LibraryAction(this.method, this.params);
  final String method;
  final Json params;
  String state = 'pending';
  String? message, code;
  Json details = {}, result = {};
  bool get unresolved => state == 'pending' || state == 'unconfirmed';
  bool get blocksRetry => unresolved || state == 'partial';
}

class LibraryWorkspaceDraft {
  String name = '';
  String? directory;
  Json? registered;
  bool adoptDefault = false;
}

/// Owns read observations and pending receipts; original services own mutations.
class LibraryController extends ChangeNotifier {
  LibraryController(this.runtime);
  final RuntimeController runtime;
  List<Json> workspaces = [], sessions = [];
  List<String> archivedSessionIds = [], pinnedSessionIds = [];
  String? defaultDirectory, readError;
  bool loading = false, fresh = false, writing = false;
  final actions = <String, LibraryAction>{};
  final drafts = <String, String>{};
  final draftBases = <String, String>{};
  final workspaceDraft = LibraryWorkspaceDraft();
  final _observations = <String, StreamSubscription<Json>>{};
  final _healthy = <String, bool>{'workspace': false, 'session': false};
  final _closedStreams = <String>{};
  Timer? _refreshTimer;
  bool _started = false, _disposed = false;
  int _read = 0, _connection = 0, _watch = 0;
  String? _phase;
  Object? _taskEpoch, _sessionRows;

  bool get synchronized =>
      fresh && runtime.ready && _healthy.values.every((value) => value);
  bool get canWrite => synchronized && !writing;
  String get synchronizationLabel => synchronized
      ? '已同步'
      : loading
      ? '正在读取 · 同步尚未确认'
      : '未同步 · 保留上次读取的目录';

  Json? workspace(String id) {
    for (final row in workspaces) {
      if (row['workspaceId'] == id) return row;
    }
    return null;
  }

  Json? session(String id) {
    for (final row in sessions) {
      if (row['sessionId'] == id) return row;
    }
    return null;
  }

  Json? workspaceFor(String sessionId) {
    for (final row in workspaces) {
      if ((row['sessionIds'] as List).contains(sessionId)) return row;
    }
    return null;
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _phase = runtime.phase;
    _taskEpoch = runtime.taskState['epoch'];
    _sessionRows = runtime.sessions;
    runtime.addListener(_runtimeChanged);
    _observe();
    unawaited(refresh());
  }

  void _runtimeChanged() {
    final connectionChanged =
        _phase != runtime.phase || _taskEpoch != runtime.taskState['epoch'];
    final sessionsChanged = !identical(_sessionRows, runtime.sessions);
    _sessionRows = runtime.sessions;
    if (connectionChanged) {
      _phase = runtime.phase;
      _taskEpoch = runtime.taskState['epoch'];
      _connection++;
      _read++;
      fresh = false;
      loading = false;
      for (final name in _healthy.keys) {
        _healthy[name] = false;
      }
      if (runtime.ready) _observe();
      _publish();
    }
    if (runtime.ready && (connectionChanged || sessionsChanged)) {
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    if (_disposed || !runtime.ready) return;
    fresh = false;
    _publish();
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 100), () {
      if (!writing) unawaited(refresh());
    });
  }

  void _observe() {
    final generation = ++_watch;
    for (final observation in _observations.values) {
      unawaited(observation.cancel());
    }
    _observations.clear();
    _closedStreams.clear();
    for (final name in _healthy.keys) {
      _healthy[name] = false;
      _observations[name] = runtime
          .watchApi(name, name == 'workspace' ? 'follow' : 'control')
          .listen(
            (frame) {
              if (_disposed || generation != _watch) return;
              if (frame['type'] == 'opening' ||
                  frame['type'] == 'disconnected') {
                _healthy[name] = false;
                _read++;
                loading = false;
                _publish();
              } else if (frame['type'] == 'item') {
                final value = frame['value'];
                if (value is! Json || value['type'] is! String) {
                  _streamLost(name, generation);
                  return;
                }
                if (value['type'] == 'baseline') _healthy[name] = true;
                // Only titles affect this management list; token and tool
                // projections must not cause repeated catalog reads.
                if (name == 'workspace' ||
                    value['type'] == 'baseline' ||
                    value['type'] == 'projection' && value['key'] == 'title') {
                  _read++;
                  _scheduleRefresh();
                }
                _publish();
              } else if (frame['type'] == 'end') {
                _streamLost(name, generation);
              }
            },
            onError: (Object failure) => _streamLost(name, generation),
            onDone: () => _streamLost(name, generation),
          );
    }
  }

  void _streamLost(String name, int generation) {
    if (_disposed || generation != _watch) return;
    _healthy[name] = false;
    _closedStreams.add(name);
    _read++;
    loading = false;
    _publish();
  }

  Future<void> refresh({bool reconnect = false}) async {
    if (_disposed || writing) return;
    if (reconnect && _closedStreams.isNotEmpty) _observe();
    final read = ++_read;
    if (!runtime.ready) {
      fresh = false;
      loading = false;
      _publish();
      return;
    }
    loading = true;
    fresh = false;
    _publish();
    try {
      final result =
          await runtime.call('library.catalog').timeout(libraryRequestTimeout)
              as Json;
      final nextWorkspaces = _rows(result['workspaces']);
      final nextSessions = _rows(result['sessions']);
      final archived = _ids(result['archivedSessionIds']);
      final pinned = _ids(result['pinnedSessionIds']);
      final directory = _identity(result['defaultDirectory']);
      for (final row in nextWorkspaces) {
        _identity(row['workspaceId']);
        _identity(row['path']);
        if (row['title'] is! String) {
          throw const FormatException('Invalid workspace title');
        }
        _ids(row['sessionIds']);
      }
      for (final row in nextSessions) {
        _identity(row['sessionId']);
      }
      if (_disposed || read != _read) return;
      workspaces = nextWorkspaces;
      sessions = nextSessions
          .where((row) => row['origin'] != 'subagent')
          .toList();
      archivedSessionIds = archived;
      pinnedSessionIds = pinned;
      defaultDirectory = directory;
      fresh = true;
      readError = null;
      _reconcile();
    } catch (failure) {
      if (_disposed || read != _read) return;
      fresh = false;
      readError = '目录读取未确认，请刷新核对。错误：${libraryFailureCode(failure)}';
    } finally {
      if (!_disposed && read == _read) {
        loading = false;
        _publish();
      }
    }
  }

  void _reconcile() {
    for (final action in actions.values) {
      if (action.state != 'unconfirmed') continue;
      final params = action.params;
      final id = params['sessionId'];
      final matches = switch (action.method) {
        'sessionRename' =>
          session(id)?['projections']?['values']?['title'] == params['title'],
        'workspaceRename' =>
          workspace(params['workspaceId'])?['title'] == params['title'],
        'sessionPin' =>
          session(id) != null &&
              pinnedSessionIds.contains(id) == params['pinned'],
        'sessionArchive' =>
          session(id) != null &&
              archivedSessionIds.contains(id) == params['archived'],
        _ => false,
      };
      if (matches) {
        action.state = 'observed';
        action.message = '当前读取的状态已与修改一致；不推断此前请求的执行过程。';
      }
    }
  }

  bool allowed(String key) => canWrite && actions[key]?.blocksRetry != true;

  /// Unknown writes never replay on reconnect, refresh, or page reopening.
  Future<Json?> mutate(String key, String method, Json params) async {
    if (!allowed(key)) return null;
    final action = LibraryAction(method, Map.of(params));
    actions[key] = action;
    final connection = _connection;
    _read++;
    loading = false;
    writing = true;
    _publish();
    Json? result;
    try {
      final receipt = await runtime
          .call('library.$method', params)
          .timeout(libraryRequestTimeout);
      if (_disposed) return null;
      if (connection != _connection) {
        throw const FormatException('Receipt from previous connection');
      }
      result = _receipt(method, receipt);
      action
        ..state = 'confirmed'
        ..result = result
        ..message = '原服务已确认操作。';
      if (method == 'directoryCreate') {
        workspaceDraft.directory = result['path'] as String;
      }
      if (method == 'workspaceCreate') {
        workspaceDraft.registered = result['workspace'] as Json;
      }
    } catch (failure) {
      if (_disposed) return null;
      action.code = libraryFailureCode(failure);
      action.details = libraryFailureDetails(failure);
      if (action.code == 'workspace/session-active' &&
          method == 'sessionArchive') {
        action.state = 'needs-stop';
        action.message = '会话仍有活动，尚未归档。请核对活动后再决定是否停止并归档。';
      } else if (action.code == 'session/workspace-attach-failed' &&
          action.details['sessionId'] is String) {
        action
          ..state = 'partial'
          ..result = {'sessionId': action.details['sessionId']}
          ..message = '会话已创建，但工作区关联未完成。请打开已有会话核对，不会重新创建。';
      } else if (action.code == 'session/fork-title-failed') {
        final childId = action.details['sessionId'];
        action
          ..state = 'partial'
          ..result = childId is String ? {'sessionId': childId} : {}
          ..message = childId is String
              ? '分支会话 $childId 已创建，但标题更新未完成。请从工作区与会话打开，不会重新创建。'
              : '分支会话可能已创建，但无法读取新会话编号。请从工作区与会话核对，不会重新创建。';
      } else if (const {
        'gateway/bad-request',
        'gateway/arguments-invalid',
        'workspace/not-found',
        'workspace/name-conflict',
        'workspace/move-invalid',
        'session/not-found',
        'session/conflict',
        'session/title-invalid',
        'session/fork-unavailable',
        'session/migration-required',
        'session/agent-busy',
        'agent-preset/conflict',
        'directory-picker/exists',
        'directory-picker/create-failed',
        'directory-picker/unavailable',
        'directory-picker/unreadable',
      }.contains(action.code)) {
        action.state = 'rejected';
        action.message = '操作未完成，已保留填写内容。错误：${action.code}';
      } else {
        action.state = 'unconfirmed';
        action.message = '操作结果未确认，已保留填写内容。请刷新或查看目录核对；不会自动重发。错误：${action.code}';
      }
    } finally {
      if (!_disposed) {
        writing = false;
        _publish();
        await refresh();
      }
    }
    return result;
  }

  Json _receipt(String method, dynamic receipt) {
    if (receipt is! Json) throw const FormatException('Missing receipt');
    switch (method) {
      case 'sessionCreate':
      case 'sessionFork':
        _identity(receipt['sessionId']);
      case 'directoryCreate':
        _identity(receipt['path']);
      case 'workspaceCreate':
      case 'workspaceRename':
        if (receipt['workspace'] is! Json) {
          throw const FormatException('Missing workspace receipt');
        }
        if (method == 'workspaceCreate' && receipt['created'] is! bool) {
          throw const FormatException('Missing workspace creation receipt');
        }
        _identity(receipt['workspace']['workspaceId']);
        _identity(receipt['workspace']['path']);
      case 'sessionRename':
        if (receipt['title'] is! String || receipt['seq'] is! int) {
          throw const FormatException('Missing title receipt');
        }
      case 'sessionArchive':
        _ids(receipt['archivedSessionIds']);
      case 'sessionPin':
        _ids(receipt['pinnedSessionIds']);
      case 'workspaceReorder':
        _ids(receipt['workspaceIds']);
      case 'sessionReorder':
        if (receipt['workspace'] is! Json) {
          throw const FormatException('Missing workspace order receipt');
        }
        _ids(receipt['workspace']['sessionIds']);
      default:
        throw const FormatException('Unknown library mutation');
    }
    return receipt;
  }

  @override
  void dispose() {
    _disposed = true;
    _read++;
    _watch++;
    _refreshTimer?.cancel();
    runtime.removeListener(_runtimeChanged);
    for (final observation in _observations.values) {
      unawaited(observation.cancel());
    }
    super.dispose();
  }
}
