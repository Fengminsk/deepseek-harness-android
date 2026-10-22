import 'runtime.dart';

class ChatFeedbackTarget {
  const ChatFeedbackTarget({
    required this.turn,
    required this.step,
    required this.messageId,
    required this.messageSeq,
    required this.turnEndSeq,
  });
  final int turn, step, messageSeq, turnEndSeq;
  final String messageId;
  String get rowKey => 'assistant:$messageSeq';
}

/// Original turn-tail closing reply, including a frozen partial without a
/// durable message ID. Copy/share use [text]; feedback requires [messageId].
class ChatReplyClosing {
  const ChatReplyClosing({
    required this.turn,
    required this.step,
    required this.seq,
    required this.text,
    required this.turnEndSeq,
    this.messageId,
    this.messageSeq,
  });
  final int turn, step, turnEndSeq;
  final num seq;
  final String text;
  final String? messageId;
  final int? messageSeq;
  String get rowKey => messageSeq != null
      ? 'assistant:$messageSeq'
      : 'assistant-frozen:$turn:$step:$seq';
}

class _FeedbackStep {
  Json? finalEvent;
  int? endSeq;
  final partialText = <int, String>{};
  String get text => (partialText.keys.toList()..sort())
      .map((index) => partialText[index]!)
      .join();
}

class _FeedbackTurn {
  int? endSeq;
  final steps = <int, _FeedbackStep>{};
}

// Original assistantText joins text blocks directly, without inserted breaks.
String _text(dynamic content) => content is List
    ? content
          .whereType<Map>()
          .where((block) => block['type'] == 'text' && block['text'] is String)
          .map((block) => block['text'] as String)
          .join()
    : '';

/// Mirrors assistant-step and turn-tail: only a closed Turn's last finalized
/// step containing nonblank text owns feedback. Frozen text without a durable
/// message ID shadows an earlier answer but cannot itself receive feedback.
/// Input is the native canonical event window, including original reconstructed
/// assistantContent on failed attempts; this class neither reads nor writes logs.
class ChatFeedbackProjection {
  final _seen = <Json>[];
  final _turns = <int, _FeedbackTurn>{};
  final _targets = <int, ChatFeedbackTarget>{};
  final _closings = <int, ChatReplyClosing>{};
  List<Json>? _source;
  List<ChatFeedbackTarget> _entries = const [];
  List<ChatFeedbackTarget> get entries => _entries;
  List<ChatReplyClosing> _allClosing = const [];
  List<ChatReplyClosing> get allClosing => _allClosing;
  int processedEventCount = 0;

  void reconcile(List<Json> events) {
    if (identical(_source, events) && _seen.length == events.length) return;
    var prefix = 0;
    if (identical(_source, events) &&
        events.length >= _seen.length &&
        (_seen.isEmpty || identical(events[_seen.length - 1], _seen.last))) {
      prefix = _seen.length;
    } else {
      while (prefix < _seen.length &&
          prefix < events.length &&
          identical(_seen[prefix], events[prefix])) {
        prefix++;
      }
    }
    _source = events;
    if (prefix != _seen.length) {
      _seen.clear();
      _turns.clear();
      _targets.clear();
      _closings.clear();
      prefix = 0;
    }
    final dirty = <int>{};
    for (var at = prefix; at < events.length; at++) {
      final event = events[at];
      _seen.add(event);
      processedEventCount++;
      final data = event['data'], seq = event['seq'];
      if (data is! Map || data['turn'] is! int || seq is! int) continue;
      final turn = data['turn'] as int;
      final state = _turns.putIfAbsent(turn, _FeedbackTurn.new);
      if (event['type'] == 'turn/end') {
        state.endSeq = seq;
        dirty.add(turn);
        continue;
      }
      if (data['step'] is! int) continue;
      final step = data['step'] as int;
      final current = state.steps.putIfAbsent(step, _FeedbackStep.new);
      switch (event['type']) {
        case 'step/start':
          state.steps[step] = _FeedbackStep();
        case 'llm/retry':
          current.finalEvent = null;
          current.partialText.clear();
        case 'step/end':
          current.endSeq = seq;
        case 'assistant/message':
          if (event['surfaceOp'] != 'append') continue;
          current.finalEvent = event;
        case 'assistant/attempt':
          // Native history derives this through the original stream assembler.
          // A later retry clears these blocks just as assistant-step does.
          final content = event['assistantContent'];
          if (content is List) {
            current.partialText.clear();
            for (var index = 0; index < content.length; index++) {
              final block = content[index];
              if (block is Map &&
                  block['type'] == 'text' &&
                  block['text'] is String) {
                current.partialText[index] = block['text'];
              }
            }
          }
        case 'assistant/live-chunk':
          final chunk = data['chunk'];
          if (chunk is! Map || chunk['index'] is! int) continue;
          final index = chunk['index'] as int;
          if (chunk['type'] == 'block-start') current.partialText.remove(index);
          if (chunk['type'] == 'reasoning-delta' ||
              chunk['type'] == 'tool-call-delta') {
            current.partialText.remove(index);
          }
          if (chunk['type'] == 'text-delta' && chunk['text'] is String) {
            current.partialText[index] =
                '${current.partialText[index] ?? ''}${chunk['text']}';
          }
          if (chunk['type'] == 'block-end') {
            final block = chunk['block'];
            current.partialText.remove(index);
            if (block is Map &&
                block['type'] == 'text' &&
                block['text'] is String) {
              current.partialText[index] = block['text'];
            }
          }
        default:
          continue;
      }
      dirty.add(turn);
    }
    for (final turn in dirty) {
      _publishTurn(turn, _turns[turn]!);
    }
    _entries = List.unmodifiable(
      _targets.values.toList()
        ..sort((a, b) => a.turnEndSeq.compareTo(b.turnEndSeq)),
    );
    _allClosing = List.unmodifiable(
      _closings.values.toList()
        ..sort((a, b) => a.turnEndSeq.compareTo(b.turnEndSeq)),
    );
  }

  void _publishTurn(int turn, _FeedbackTurn state) {
    _targets.remove(turn);
    _closings.remove(turn);
    final endSeq = state.endSeq;
    if (endSeq == null) return;
    ChatReplyClosing? closing;
    for (final entry in state.steps.entries) {
      final step = entry.value;
      final event = step.finalEvent;
      if (event != null) {
        final message = event['data']['message'];
        if (message is! Map) continue;
        final text = _text(message['content']);
        if (text.trim().isEmpty) continue;
        final seq = event['seq'] as int;
        if (closing != null && seq < closing.seq) continue;
        closing = ChatReplyClosing(
          turn: turn,
          step: entry.key,
          seq: seq,
          text: text,
          messageId:
              message['id'] is String && (message['id'] as String).isNotEmpty
              ? message['id'] as String
              : null,
          messageSeq: seq,
          turnEndSeq: endSeq,
        );
      } else {
        final text = step.text;
        if (text.trim().isEmpty) continue;
        // CHAT_SYNTHETIC_SEQ_OFFSETS.interruptedAssistant in original DSH.
        final seq = (step.endSeq ?? endSeq) - .9;
        if (closing != null && seq < closing.seq) continue;
        closing = ChatReplyClosing(
          turn: turn,
          step: entry.key,
          seq: seq,
          text: text,
          turnEndSeq: endSeq,
        );
      }
    }
    if (closing == null) return;
    _closings[turn] = closing;
    if (closing.messageId != null && closing.messageSeq != null) {
      _targets[turn] = ChatFeedbackTarget(
        turn: turn,
        step: closing.step,
        messageId: closing.messageId!,
        messageSeq: closing.messageSeq!,
        turnEndSeq: endSeq,
      );
    }
  }
}
