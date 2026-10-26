import 'dart:convert';

import 'runtime.dart';

/// Remembers default only against a confirmed effective Session selection.
/// The Session API remains authoritative for the actual model and effort.
class SessionReasoningPreferences {
  const SessionReasoningPreferences();

  Future<Json?> load(String sessionId) async {
    final raw = await RuntimeController.channel.invokeMethod<String>(
      'session.reasoning.load',
      {'sessionId': sessionId},
    );
    if (raw == null) return null;
    final value = jsonDecode(raw);
    if (value is! Json ||
        value['provider'] is! String ||
        value['model'] is! String ||
        (value['reasoningEffort'] != null &&
            value['reasoningEffort'] is! String)) {
      throw const FormatException('默认档位记录无效');
    }
    return value;
  }

  Future<void> save(String sessionId, Json? effectiveSelection) =>
      RuntimeController.channel.invokeMethod<void>('session.reasoning.save', {
        'sessionId': sessionId,
        'selection': effectiveSelection == null
            ? null
            : jsonEncode(effectiveSelection),
      });
}
