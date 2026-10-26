import 'runtime.dart';

/// Replays ordered Session events using the original modelSelection.next rules.
///
/// Mirrors packages/api/session-controller/src/model-selection-projection.ts:
/// an unrelated request records last use without consuming a pending selection.
/// Returns null before any selection or request, leaving default choice to callers.
Json? nextSessionModel(Iterable<Json> events) {
  final state = _ModelSelectionState();
  for (final event in events) {
    state.accept(event);
  }
  return state.next;
}

/// The runtime appends immutable events to a loaded window. Streaming updates
/// do not change that window. Replay only appended events; a replacement (older
/// history, reconnect, or another session) starts a fresh projection.
class SessionModelProjection {
  List<Json>? _source;
  int _count = 0;
  Json? _last;
  _ModelSelectionState _state = _ModelSelectionState();
  int processedEventCount = 0;
  Json? get next => _state.next;

  void reconcile(List<Json> events) {
    if (!identical(_source, events) ||
        events.length < _count ||
        (_count > 0 && !identical(events[_count - 1], _last))) {
      _state = _ModelSelectionState();
      _count = 0;
    }
    _source = events;
    for (var at = _count; at < events.length; at++) {
      _state.accept(events[at]);
      processedEventCount++;
    }
    _count = events.length;
    _last = events.isEmpty ? null : events.last;
  }
}

class _ModelSelectionState {
  Json? pending, lastUsed;
  Json? get next => pending ?? lastUsed;

  void accept(Json event) {
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
      final queued = pending;
      final consumed = lastUsed!;
      if (queued != null &&
          queued['provider'] == consumed['provider'] &&
          queued['model'] == consumed['model'] &&
          queued['reasoningEffort'] == consumed['reasoningEffort']) {
        pending = null;
      }
    }
  }
}
