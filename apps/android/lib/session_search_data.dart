import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'library_data.dart';
import 'runtime.dart';

const sessionSearchQueryLimit = 500;
const sessionSearchResultLimit = 20;
const sessionSearchTimeout = Duration(seconds: 30);

enum SessionSearchPhase { idle, searching, complete, failed }

class SessionSearchItem {
  const SessionSearchItem({required this.sessionId, required this.snippet});
  final String sessionId, snippet;
}

/// A page-local, read-only search. A query or connection change retires every
/// outstanding read; reconnecting never submits the preserved query itself.
class SessionSearchController extends ChangeNotifier {
  SessionSearchController(this.runtime, {String initialQuery = ''})
    : query = initialQuery,
      _generation = runtime.connectionGeneration,
      _runtimePhase = runtime.phase,
      _epoch = runtime.taskState['epoch'] {
    runtime.addListener(_runtimeChanged);
  }

  final RuntimeController runtime;
  String query;
  String? submittedQuery, error, catalogError;
  SessionSearchPhase phase = SessionSearchPhase.idle;
  List<SessionSearchItem> items = const [];
  bool hasMore = false;
  Map<String, Json> _catalog = {};
  Set<String> _archived = {};
  int _read = 0, _generation;
  String _runtimePhase;
  Object? _epoch;
  bool _disposed = false;

  String? get validation {
    final normalized = query.trim();
    if (normalized.isEmpty) return '请输入要查找的对话内容';
    if (normalized.length > sessionSearchQueryLimit) {
      return '搜索内容过长，请缩短至 500 个字符以内';
    }
    if (normalized.contains('\u0000')) return '搜索内容包含无法使用的字符';
    return null;
  }

  bool get canSearch =>
      !_disposed &&
      runtime.ready &&
      phase != SessionSearchPhase.searching &&
      validation == null;

  String title(String id) {
    final session = _catalog[id];
    return session == null ? '会话信息未读取' : librarySessionTitle(session);
  }

  bool canOpen(String id) =>
      runtime.ready &&
      phase == SessionSearchPhase.complete &&
      _catalog.containsKey(id);

  bool hasTitle(String id) {
    final title = _catalog[id]?['projections']?['values']?['title'];
    return title is String && title.trim().isNotEmpty;
  }

  bool archived(String id) => _archived.contains(id);

  void setQuery(String value) {
    if (_disposed || query == value) return;
    query = value;
    _reset();
    error = null;
    _publish();
  }

  void _reset() {
    _read++;
    phase = SessionSearchPhase.idle;
    submittedQuery = null;
    items = const [];
    hasMore = false;
    catalogError = null;
  }

  void _runtimeChanged() {
    if (_disposed) return;
    if (_generation == runtime.connectionGeneration &&
        _runtimePhase == runtime.phase &&
        _epoch == runtime.taskState['epoch']) {
      return;
    }
    final hadSearch = submittedQuery != null;
    _generation = runtime.connectionGeneration;
    _runtimePhase = runtime.phase;
    _epoch = runtime.taskState['epoch'];
    _reset();
    _catalog = {};
    _archived = {};
    error = hadSearch || query.trim().isNotEmpty
        ? runtime.ready
              ? '连接已恢复，请重新搜索'
              : '服务连接已中断，搜索内容已保留'
        : null;
    _publish();
  }

  Future<void> search() async {
    if (_disposed || phase == SessionSearchPhase.searching) return;
    final invalid = validation;
    if (!runtime.ready || invalid != null) {
      error = !runtime.ready ? '服务连接尚未恢复，请稍后重试' : invalid;
      _publish();
      return;
    }
    final read = ++_read;
    final generation = runtime.connectionGeneration;
    final epoch = runtime.taskState['epoch'];
    final normalized = query.trim();
    bool current() =>
        !_disposed &&
        read == _read &&
        runtime.ready &&
        generation == runtime.connectionGeneration &&
        epoch == runtime.taskState['epoch'];
    phase = SessionSearchPhase.searching;
    submittedQuery = normalized;
    items = const [];
    hasMore = false;
    error = null;
    catalogError = null;
    _publish();
    try {
      // Catalog failure must not turn a successful content search into an empty
      // result. Missing titles stay explicitly unnamed, with their session ID.
      final responses = await Future.wait<dynamic>([
        runtime
            .call('api.call', {
              'namespace': 'session',
              'method': 'search',
              'args': {
                'request': {'query': normalized},
              },
            })
            .timeout(sessionSearchTimeout),
        _readCatalog(),
      ], eagerError: true);
      if (!current()) return;
      final result = responses[0];
      if (result is! Map ||
          result['items'] is! List ||
          result['hasMore'] is! bool ||
          (result['items'] as List).length > sessionSearchResultLimit) {
        throw const FormatException('Invalid session search response');
      }
      final next = <SessionSearchItem>[];
      final seen = <String>{};
      for (final item in result['items'] as List) {
        if (item is! Map ||
            item['sessionId'] is! String ||
            (item['sessionId'] as String).trim().isEmpty ||
            item['snippet'] is! String ||
            !seen.add(item['sessionId'] as String)) {
          throw const FormatException('Invalid session search item');
        }
        next.add(
          SessionSearchItem(
            sessionId: item['sessionId'] as String,
            snippet: item['snippet'] as String,
          ),
        );
      }
      final catalog = responses[1] as _SearchCatalog;
      _catalog = catalog.sessions;
      _archived = catalog.archived;
      catalogError = catalog.error;
      items = List.unmodifiable(next);
      hasMore = result['hasMore'] as bool;
      phase = SessionSearchPhase.complete;
    } catch (failure) {
      if (!current()) return;
      phase = SessionSearchPhase.failed;
      error = _searchFailure(failure);
    } finally {
      if (current()) _publish();
    }
  }

  Future<_SearchCatalog> _readCatalog() async {
    try {
      final value = await runtime
          .call('library.catalog')
          .timeout(libraryRequestTimeout);
      if (value is! Map ||
          value['sessions'] is! List ||
          value['archivedSessionIds'] is! List) {
        throw const FormatException('Invalid search catalog');
      }
      final sessions = <String, Json>{};
      for (final row in value['sessions'] as List) {
        if (row is! Json || row['sessionId'] is! String) {
          throw const FormatException('Invalid search catalog item');
        }
        final title = row['projections'];
        if (title != null &&
            (title is! Map ||
                title['values'] != null && title['values'] is! Map)) {
          throw const FormatException('Invalid search title projection');
        }
        sessions[row['sessionId'] as String] = row;
      }
      final archived = (value['archivedSessionIds'] as List).cast<String>();
      return _SearchCatalog(sessions, archived.toSet());
    } catch (failure) {
      return const _SearchCatalog({}, {}, error: '会话标题暂未读取，可重新搜索以更新');
    }
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _read++;
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}

class _SearchCatalog {
  const _SearchCatalog(this.sessions, this.archived, {this.error});
  final Map<String, Json> sessions;
  final Set<String> archived;
  final String? error;
}

String _searchFailure(Object failure) {
  if (failure is TimeoutException) return '搜索用时较长，请稍后重试或缩短搜索内容';
  if (failure is FormatException) return '无法读取搜索结果，请重试';
  if (failure is PlatformException) {
    if (failure.code == 'SESSION_QUERY_SEARCH_DISABLED') {
      return '当前服务未开启正文搜索';
    }
    if (failure.code == 'gateway/bad-request') return '搜索内容无法使用，请修改后重试';
  }
  return '正文搜索暂不可用，请稍后重试';
}
