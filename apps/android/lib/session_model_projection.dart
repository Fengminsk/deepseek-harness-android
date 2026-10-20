import 'runtime.dart';

/// Replays ordered Session events using the original modelSelection.next rules.
///
/// Mirrors packages/api/session-controller/src/model-selection-projection.ts:
/// an unrelated request records last use without consuming a pending selection.
/// Returns null before any selection or request, leaving default choice to callers.
Json? nextSessionModel(Iterable<Json> events) {
  Json? pending, lastUsed;
  for (final event in events) {
    if (event['type'] == 'model/selection') {
      pending = Json.of(event['data'] as Json);
    } else if (event['type'] == 'request/header') {
      final config = event['data']['header']['config'] as Json;
      lastUsed = {
        'provider': config['provider'],
        'model': config['model'],
        if (config.containsKey('reasoningEffort'))
          'reasoningEffort': '${config['reasoningEffort']}',
      };
      if (pending != null &&
          pending['provider'] == lastUsed['provider'] &&
          pending['model'] == lastUsed['model'] &&
          pending['reasoningEffort'] == lastUsed['reasoningEffort']) {
        pending = null;
      }
    }
  }
  return pending ?? lastUsed;
}
