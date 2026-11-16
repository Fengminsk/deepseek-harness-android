/// App-private snapshot of recent remote project and session labels.
/// Connection credentials and Session contents are never stored here.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'remote_dsh_page.dart';

/// Bounded local snapshot used while a paired computer reconnects.
class RemoteHomeCache {
  const RemoteHomeCache({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/runtime');

  final MethodChannel _channel;
  static const _limit = 512 * 1024;

  /// Reads valid saved rows. A corrupt or unavailable cache is treated as empty.
  Future<Map<String, List<RemoteDshProject>>> read() async {
    try {
      final raw = await _channel
          .invokeMethod<String>('remote.home.read')
          .timeout(const Duration(seconds: 5));
      if (raw == null || raw.length > _limit) return {};
      final data = jsonDecode(raw);
      if (data is! Map || data['version'] != 1 || data['devices'] is! Map) {
        return {};
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
      return result;
    } on Object {
      return {};
    }
  }

  /// Saves a bounded snapshot. Failures leave the live page usable.
  Future<void> write(Map<String, List<RemoteDshProject>> projects) async {
    final payload = jsonEncode({
      'version': 1,
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
