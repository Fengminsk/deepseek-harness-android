/// App-private cache of the latest remote conversation window.
///
/// The cache lets the conversation page render the last known messages before the
/// computer answers (and while offline). It stores only the event JSON the
/// timeline already renders; attachment bytes, device tokens and connection
/// credentials never enter this store. One native preference entry exists per
/// device, containing at most [RemoteConversationCache.maxSessionsPerDevice]
/// sessions and staying below [RemoteConversationCache.maxDeviceBytes].
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'remote_conversation_source.dart';

/// One cached conversation window plus the labels needed to render it offline.
class RemoteConversationCacheEntry {
  const RemoteConversationCacheEntry({
    required this.window,
    required this.title,
    required this.updatedAt,
  });

  /// The window to feed the timeline.
  final RemoteConversationWindow window;

  /// Session title at the time the window was cached.
  final String title;

  /// Last write time (Unix ms); drives least-recently-used eviction.
  final int updatedAt;
}

/// Bounded local cache keyed by `deviceId` (one native document) + `sessionId`.
class RemoteConversationCache {
  const RemoteConversationCache({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/runtime');

  final MethodChannel _channel;

  /// Sessions kept per device before least-recently-used eviction.
  static const int maxSessionsPerDevice = 10;

  /// Upper bound for one session entry.
  static const int maxSessionBytes = 256 * 1024;

  /// Upper bound for one device document (native side enforces the same 2 MiB).
  static const int maxDeviceBytes = 2 * 1024 * 1024;

  static const int _version = 1;

  /// 保存 [window] 时保留同一会话已存的 UI 偏好（如统计条展开状态）。
  static const String _statsExpandedKey = 'statsExpanded';

  /// 读取统计条展开偏好；旧缓存/无记录/损坏时返回 null（调用方用默认展开）。
  Future<bool?> readStatsExpanded(String deviceId, String sessionId) async {
    if (deviceId.trim().isEmpty || sessionId.trim().isEmpty) return null;
    final sessions = await _loadSessions(deviceId);
    for (final item in sessions) {
      if (item['sessionId'] != sessionId) continue;
      final value = item[_statsExpandedKey];
      return value is bool ? value : null;
    }
    return null;
  }

  /// 保存统计条展开偏好；即使该会话还没有事件缓存也能保存。
  Future<void> saveStatsExpanded({
    required String deviceId,
    required String sessionId,
    required bool expanded,
  }) async {
    if (deviceId.trim().isEmpty || sessionId.trim().isEmpty) return;
    try {
      final sessions = await _loadSessions(deviceId);
      final index = sessions.indexWhere((item) => item['sessionId'] == sessionId);
      final now = DateTime.now().millisecondsSinceEpoch;
      final base = index >= 0
          ? Map<String, dynamic>.from(sessions[index])
          : <String, dynamic>{
              'sessionId': sessionId,
              'title': '',
              'throughSeq': 0,
              'firstSeq': null,
              'hasMore': false,
              'events': <dynamic>[],
            };
      base[_statsExpandedKey] = expanded;
      base['updatedAt'] = now;
      if (index >= 0) {
        sessions[index] = base;
      } else {
        sessions.insert(0, base);
      }
      await _writeSessions(deviceId, sessions);
    } on Object {
      // UI 偏好保存失败不影响会话内容；下次进入退回默认展开。
    }
  }

  /// 写入一份已裁剪的设备文档；超限时放弃（偏好不是关键路径）。
  Future<void> _writeSessions(
    String deviceId,
    List<Map<String, dynamic>> sessions,
  ) async {
    final bounded = _boundSessions(sessions);
    final payload = jsonEncode(<String, dynamic>{
      'version': _version,
      'sessions': bounded,
    });
    if (utf8.encode(payload).length > maxDeviceBytes) return;
    await _channel
        .invokeMethod<void>('remote.conversation.save', <String, dynamic>{
          'deviceId': deviceId,
          'value': payload,
        })
        .timeout(const Duration(seconds: 5));
  }

  /// Reads the cached window for [sessionId] on [deviceId].
  ///
  /// Missing, corrupt or unavailable caches return null; callers fall back to the
  /// live connection instead of surfacing an error.
  Future<RemoteConversationCacheEntry?> read(
    String deviceId,
    String sessionId,
  ) async {
    if (deviceId.trim().isEmpty || sessionId.trim().isEmpty) return null;
    final sessions = await _loadSessions(deviceId);
    for (final item in sessions) {
      if (item['sessionId'] != sessionId) continue;
      return _entryOf(item);
    }
    return null;
  }

  /// Saves [window] for [sessionId], evicting the least recently used entries.
  ///
  /// This is best effort: failures (missing channel, quota) leave the live page
  /// usable and never throw.
  Future<void> save({
    required String deviceId,
    required String sessionId,
    required RemoteConversationWindow window,
    String title = '',
  }) async {
    if (deviceId.trim().isEmpty || sessionId.trim().isEmpty) return;
    if (window.events.isEmpty) return;
    try {
      final sessions = await _loadSessions(deviceId);
      final entry = _encodeEntry(deviceId, sessionId, window, title);
      if (entry == null) return;
      for (final item in sessions) {
        if (item['sessionId'] != sessionId) continue;
        final stats = item[_statsExpandedKey];
        if (stats is bool) entry[_statsExpandedKey] = stats;
        break;
      }
      sessions.removeWhere((item) => item['sessionId'] == sessionId);
      sessions.insert(0, entry);
      await _writeSessions(deviceId, sessions);
    } on Object {
      // Cached conversation content is optional; the next snapshot still shows.
    }
  }

  /// Reads and validates one device document; corrupt documents degrade to [].
  Future<List<Map<String, dynamic>>> _loadSessions(String deviceId) async {
    try {
      final raw = await _channel
          .invokeMethod<String>('remote.conversation.read', <String, dynamic>{
            'deviceId': deviceId,
          })
          .timeout(const Duration(seconds: 5));
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['version'] != _version ||
          decoded['sessions'] is! List) {
        return <Map<String, dynamic>>[];
      }
      return <Map<String, dynamic>>[
        for (final item in (decoded['sessions'] as List))
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } on Object {
      return <Map<String, dynamic>>[];
    }
  }

  /// Encodes one entry; returns null when the window has no renderable event.
  Map<String, dynamic>? _encodeEntry(
    String deviceId,
    String sessionId,
    RemoteConversationWindow window,
    String title,
  ) {
    final events = <Map<String, dynamic>>[
      for (final event in window.events) Map<String, dynamic>.of(event),
    ];
    if (events.isEmpty) return null;
    var encoded = <String, dynamic>{
      'sessionId': sessionId,
      'title': title,
      'throughSeq': window.throughSeq,
      'firstSeq': window.firstSeq,
      'hasMore': window.hasMore,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'events': events,
    };
    // Keep the newest events when one session entry exceeds the per-session cap.
    while (events.isNotEmpty &&
        utf8.encode(jsonEncode(encoded)).length > maxSessionBytes) {
      events.removeAt(0);
      encoded = <String, dynamic>{
        ...encoded,
        'firstSeq': events.isEmpty ? null : events.first['seq'],
        'events': events,
      };
    }
    return events.isEmpty ? null : encoded;
  }

  /// Least-recently-used + byte-budget trimming for one device document.
  List<Map<String, dynamic>> _boundSessions(
    List<Map<String, dynamic>> sessions,
  ) {
    sessions.sort((left, right) {
      final leftAt = left['updatedAt'];
      final rightAt = right['updatedAt'];
      final leftMs = leftAt is int ? leftAt : 0;
      final rightMs = rightAt is int ? rightAt : 0;
      return rightMs.compareTo(leftMs);
    });
    final bounded = sessions.take(maxSessionsPerDevice).toList();
    while (bounded.length > 1 &&
        utf8.encode(
              jsonEncode(<String, dynamic>{
                'version': _version,
                'sessions': bounded,
              }),
            ).length >
            maxDeviceBytes) {
      bounded.removeLast();
    }
    return bounded;
  }

  /// Parses one stored session item; invalid entries are skipped by the caller.
  RemoteConversationCacheEntry? _entryOf(Map<String, dynamic> item) {
    final throughSeq = item['throughSeq'];
    final events = item['events'];
    if (throughSeq is! int || events is! List) return null;
    final parsed = <Map<String, dynamic>>[
      for (final event in events) Map<String, dynamic>.of(event),
    ];
    if (parsed.isEmpty) return null;
    final first = item['firstSeq'];
    final title = item['title'];
    final updatedAt = item['updatedAt'];
    return RemoteConversationCacheEntry(
      window: RemoteConversationWindow(
        events: parsed,
        throughSeq: throughSeq,
        firstSeq: first is int ? first : null,
        hasMore: item['hasMore'] == true,
      ),
      title: title is String ? title : '',
      updatedAt: updatedAt is int ? updatedAt : 0,
    );
  }
}
