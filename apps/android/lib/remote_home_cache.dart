/// App-private snapshot of recent remote project and session labels.
///
/// Connection credentials and Session contents are never stored here. The
/// snapshot also remembers per-project expansion choices so a user who folded a
/// project does not see it reopen after an App restart; `running` is deliberately
/// not stored (a stale green dot would claim a session is working while offline).
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'remote_dsh_page.dart';

/// One restored home snapshot: cached project labels plus remembered project
/// expansion choices keyed by `deviceId + '\u0000' + projectId`.
class RemoteHomeSnapshot {
  const RemoteHomeSnapshot({
    this.projects = const <String, List<RemoteDshProject>>{},
    this.expanded = const <String, bool>{},
  });

  /// Cached projects per computer.
  final Map<String, List<RemoteDshProject>> projects;

  /// Remembered project expansion choices; a missing key means expanded.
  final Map<String, bool> expanded;

  /// Whether the snapshot carries neither projects nor expansion choices.
  bool get isEmpty => projects.isEmpty && expanded.isEmpty;
}

/// Bounded local snapshot used while a paired computer reconnects.
class RemoteHomeCache {
  const RemoteHomeCache({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/runtime');

  final MethodChannel _channel;
  static const _limit = 512 * 1024;

  /// Maximum remembered expansion choices; far above the projects limit.
  static const _expandedLimit = 2000;

  /// Reads a valid saved snapshot. A corrupt or unavailable cache is treated as empty.
  Future<RemoteHomeSnapshot> read() async {
    try {
      final raw = await _channel
          .invokeMethod<String>('remote.home.read')
          .timeout(const Duration(seconds: 5));
      if (raw == null || raw.length > _limit) return const RemoteHomeSnapshot();
      final data = jsonDecode(raw);
      // Version 1 is the historical projects-only payload; version 2 adds the
      // expansion map. Both are accepted, unknown versions are discarded.
      if (data is! Map ||
          (data['version'] != 1 && data['version'] != 2) ||
          data['devices'] is! Map) {
        return const RemoteHomeSnapshot();
      }
      final result = <String, List<RemoteDshProject>>{};
      for (final entry in (data['devices'] as Map).entries.take(20)) {
        if (entry.key is! String || entry.value is! List) continue;
        final deviceId = entry.key as String;
        final projects = <RemoteDshProject>[];
        for (final item in (entry.value as List).take(100)) {
          if (item is! Map ||
              item['id'] is! String ||
              item['name'] is! String) {
            continue;
          }
          final sessions = <RemoteDshSession>[];
          if (item['sessions'] case final List rows) {
            for (final row in rows.take(500)) {
              if (row is! Map ||
                  row['id'] is! String ||
                  row['title'] is! String) {
                continue;
              }
              sessions.add(
                RemoteDshSession(
                  id: row['id'] as String,
                  title: row['title'] as String,
                  updatedAt: row['updatedAt'] is int
                      ? row['updatedAt'] as int
                      : null,
                ),
              );
            }
          }
          projects.add(
            RemoteDshProject(
              id: item['id'] as String,
              deviceId: deviceId,
              name: item['name'] as String,
              sessions: sessions,
            ),
          );
        }
        result[deviceId] = projects;
      }
      final expanded = <String, bool>{};
      if (data['expanded'] case final Map entries) {
        for (final entry in entries.entries.take(_expandedLimit)) {
          if (entry.key is String && entry.value is bool) {
            expanded[entry.key as String] = entry.value as bool;
          }
        }
      }
      return RemoteHomeSnapshot(projects: result, expanded: expanded);
    } on Object {
      return const RemoteHomeSnapshot();
    }
  }

  /// Saves a bounded snapshot. Failures leave the live page usable.
  Future<void> write(
    Map<String, List<RemoteDshProject>> projects, {
    Map<String, bool> expanded = const <String, bool>{},
  }) async {
    final payload = jsonEncode({
      'version': 2,
      'devices': {
        for (final entry in projects.entries.take(20))
          entry.key: [
            for (final project in entry.value.take(100))
              {
                'id': project.id,
                'name': project.name,
                'sessions': [
                  for (final session in project.sessions.take(500))
                    {
                      'id': session.id,
                      'title': session.title,
                      'updatedAt': session.updatedAt,
                    },
                ],
              },
          ],
      },
      'expanded': {
        for (final entry in expanded.entries.take(_expandedLimit))
          entry.key: entry.value,
      },
    });
    if (utf8.encode(payload).length > _limit) return;
    try {
      await _channel
          .invokeMethod<void>('remote.home.save', payload)
          .timeout(const Duration(seconds: 5));
    } on Object {
      // Saved recents are optional; the next connection still loads live data.
    }
  }
}
