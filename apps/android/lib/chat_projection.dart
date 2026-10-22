import 'dart:collection';

import 'runtime.dart';
import 'tool_activity_data.dart';

enum ChatEntryKind {
  user,
  assistant,
  context,
  systemPrompt,
  tool,
  command,
  notice,
  unknown,
}

/// An immutable row over the already-loaded Session window.
class ChatEntry {
  const ChatEntry({
    required this.key,
    required this.seq,
    required this.kind,
    required this.event,
    this.content = const [],
    this.source,
    this.title,
    this.text,
    this.error = false,
    this.outcome,
    this.tool,
    this.turn,
    this.step,
    this.details,
    this.detailsTitle,
    this.interrupted = false,
  });

  final String key;
  final int seq;
  final ChatEntryKind kind;
  final Json event;
  final List<dynamic> content;
  final Json? source, outcome;
  final String? title, text;
  final bool error;
  final bool interrupted;
  final ToolActivity? tool;
  final int? turn, step;
  final String? details, detailsTitle;
}

/// Chat interpretation of the loaded log, matching the original Web's append
/// surface, producer classification, command correlation and prompt inspection.
///
/// Repeated stream frames with no new durable events take O(1). Appends only
/// interpret new events; old row objects retain identity. A replaced/prepended
/// history window replays explicitly. This class never reads a Session itself.
class ChatProjection {
  final _seen = <Json>[];
  final _rows = <ChatEntry>[];
  final _positions = <String, int>{};
  final _commands = <String, Json>{};
  final _outcomes = <String, Json>{};
  final _stepStarts = <(int, int), int>{};
  final _turnStarts = <int, int>{};
  final _settledSteps = <(int, int)>{};
  final _frozenSteps = <(int, int)>{};
  final _assistantPrefixes = <int, Map<int, _AssistantPrefix>>{};
  final _retries = <String, _RetryChain>{};
  List<Json>? _source;
  ToolActivityProjection _tools = ToolActivityProjection();
  _SystemPromptState _system = _SystemPromptState();
  String? _previousRequestSystem;
  (dynamic, dynamic)? _previousRequestLocation;
  String? _title;
  int _processed = 0;
  late final List<ChatEntry> entries = UnmodifiableListView(_rows);

  String? get title => _title;
  int? indexOfKey(String key) => _positions[key];

  /// Used by the regression gate to bound work on unchanged streaming frames.
  int get processedEventCount => _processed;

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
      _rows.clear();
      _positions.clear();
      _commands.clear();
      _outcomes.clear();
      _stepStarts.clear();
      _turnStarts.clear();
      _settledSteps.clear();
      _frozenSteps.clear();
      _assistantPrefixes.clear();
      _retries.clear();
      _tools = ToolActivityProjection();
      _system = _SystemPromptState();
      _previousRequestSystem = null;
      _previousRequestLocation = null;
      _title = null;
      prefix = 0;
    }
    if (prefix == events.length) return;
    _tools.reconcile(events);
    for (var index = prefix; index < events.length; index++) {
      final event = events[index];
      _consume(event);
      _seen.add(event);
      _processed++;
    }
    for (final activity in _tools.byAnchorSeq.values) {
      final key = 'tool:${activity.identity}';
      final previous = _positions[key];
      if (previous != null && identical(_rows[previous].tool, activity)) {
        continue;
      }
      _put(
        ChatEntry(
          key: key,
          seq: activity.anchorSeq,
          kind: ChatEntryKind.tool,
          event: activity.events.first,
          tool: activity,
        ),
      );
    }
  }

  /// Live text is correlated by the original turn/step, never by text equality:
  /// identical replies in two successive steps are both legitimate.
  bool hasFinalAssistant({required int turn, required int step}) =>
      _settledSteps.contains((turn, step));

  /// A closed interrupted prefix also replaces the live row, without claiming
  /// that a durable assistant/message exists. An open failed attempt does not.
  bool hasSettledAssistant({required int turn, required int step}) =>
      hasFinalAssistant(turn: turn, step: step) ||
      _frozenSteps.contains((turn, step));

  void _put(ChatEntry row) {
    final previous = _positions[row.key];
    if (previous != null) {
      if (_rows[previous].seq == row.seq) {
        _rows[previous] = row;
        return;
      }
      _rows.removeAt(previous);
    }
    var index = _rows.length;
    while (index > 0 && _rows[index - 1].seq > row.seq) {
      index--;
    }
    _rows.insert(index, row);
    for (var at = previous == null ? index : 0; at < _rows.length; at++) {
      _positions[_rows[at].key] = at;
    }
  }

  void _remove(String key) {
    final position = _positions.remove(key);
    if (position == null) return;
    _rows.removeAt(position);
    for (var at = position; at < _rows.length; at++) {
      _positions[_rows[at].key] = at;
    }
  }

  void _consume(Json event) {
    final type = event['type'];
    final data = event['data'] as Json;
    final seq = event['seq'] as int;
    final op = event['surfaceOp'];
    if (type == 'system/message' || (op != null && op != 'append')) {
      _system.apply(event);
    }
    switch (type) {
      case 'session/title':
        if (data['title'] is String) _title = data['title'] as String;
        return;
      case 'turn/start':
        _turnStarts[data['turn'] as int] = seq;
        return;
      case 'step/start':
        _stepStarts[(data['turn'] as int, data['step'] as int)] = seq;
        _resetAssistantPrefix(data);
        return;
      case 'step/end':
        _closeAssistantPrefixes(event, step: data['step'] as int);
        _closeRetries(data['turn'], data['step']);
        return;
      case 'request/header':
        _requestPrompt(event);
        return;
      case 'system/message':
        final prompt = _system.introduced;
        if (op == 'append' && prompt != null && prompt.text.isNotEmpty) {
          _put(
            _promptRow(
              event,
              prompt.text,
              update: prompt.update,
              anchor: prompt.update ? seq : _anchor(data, seq),
            ),
          );
        }
        return;
      case 'user/message':
        if (op != 'append') {
          final source = _record(data['source']);
          if (source?['kind'] == 'compact-checkpoint') {
            _put(
              ChatEntry(
                key: 'checkpoint:$seq',
                seq: seq,
                kind: ChatEntryKind.context,
                event: event,
                title: '上下文已压缩',
                content: _content(data),
                source: source,
              ),
            );
          }
          return;
        }
        final source = _record(data['source']);
        final human = source?['kind'] == 'user';
        _put(
          ChatEntry(
            key: 'message:$seq',
            seq: seq,
            kind: human ? ChatEntryKind.user : ChatEntryKind.context,
            event: event,
            content: _content(data),
            source: source,
            title: human ? null : contextTitle(source),
          ),
        );
        return;
      case 'developer/message':
        final message = _record(data['message']);
        _put(
          ChatEntry(
            key: 'developer:$seq',
            seq: seq,
            kind: ChatEntryKind.context,
            event: event,
            content: _content(message),
            source: _record(message?['source']),
            title: contextTitle(_record(message?['source'])),
          ),
        );
        return;
      case 'assistant/message':
        if (op != 'append') return;
        final turn = data['turn'] as int?;
        final step = data['step'] as int?;
        if (turn != null && step != null) {
          _resetAssistantPrefix(data);
          _settledSteps.add((turn, step));
        }
        final blocks = _content(_record(data['message']));
        // Tool-call blocks belong to the existing correlated Tool cards.
        final visible = blocks
            .where((block) => block is! Json || block['type'] != 'tool-call')
            .toList();
        if (visible.isNotEmpty) {
          _put(
            ChatEntry(
              key: 'assistant:$seq',
              seq: seq,
              kind: ChatEntryKind.assistant,
              event: event,
              content: List.unmodifiable(visible),
              turn: turn,
              step: step,
              interrupted: data['interrupted'] == true,
            ),
          );
        }
        return;
      case 'assistant/attempt':
        // The native carrier derives this with the original canonical
        // assembleAssistantStream().interruptedBlocks(), without changing the
        // durable record. An unsuccessful attempt must not settle the step:
        // the same step can still have a later successful retry.
        final content = event['assistantContent'];
        final hasPrefix = content is List && content.isNotEmpty;
        final decodeError = event['assistantContentError'] as String?;
        if (content is List) _assistantPrefix(data)?.replace(content);
        _put(
          ChatEntry(
            key: 'attempt:$seq',
            seq: seq,
            kind: hasPrefix ? ChatEntryKind.context : ChatEntryKind.unknown,
            event: event,
            title: decodeError != null
                ? '模型回复记录无法解析'
                : hasPrefix
                ? '未完成的模型回复'
                : '未完成的模型请求',
            text: decodeError,
            error: decodeError != null,
            content: hasPrefix ? content : const [],
            turn: data['turn'] as int?,
            step: data['step'] as int?,
          ),
        );
        return;
      case 'assistant/live-chunk':
        final chunk = _record(data['chunk']);
        if (chunk != null) _assistantPrefix(data)?.apply(chunk);
        return;
      case 'command/run':
      case 'command/done':
        final id = data['commandId'] as String;
        if (type == 'command/run') {
          _commands[id] = event;
        } else {
          _outcomes[id] = data;
        }
        final run = _commands[id];
        final runData = _record(run?['data']);
        final outcome = _outcomes[id];
        _put(
          ChatEntry(
            key: 'command:$id',
            seq: (run?['seq'] as int?) ?? seq,
            kind: ChatEntryKind.command,
            event: run ?? event,
            title: runData == null
                ? '会话指令'
                : '/${runData['name']}${(runData['args'] as String? ?? '').trimRight()}',
            text: outcome == null
                ? '指令执行中…'
                : outcome['text'] as String? ??
                      (outcome['kind'] == 'error' ? '指令执行失败' : '指令已完成'),
            error: outcome?['kind'] == 'error',
            outcome: outcome,
          ),
        );
        return;
      case 'turn/end':
        _closeAssistantPrefixes(event);
        _closeRetries(data['turn']);
        final reason = _record(data['reason']);
        final kind = reason?['kind'];
        if (kind == 'completed') return;
        final failure = _record(reason?['error']);
        final signedOut =
            kind == 'aborted' &&
            reason?['reason']?['kind'] == 'hook' &&
            reason?['reason']?['reason'] == 'deepseek-account/signed-out';
        final text = switch (kind) {
          'error' => chatFailureText(failure),
          'interrupted' => '服务在任务完成前退出，本轮任务未完成。',
          'aborted' => signedOut ? '已退出 DeepSeek 账号，任务已停止。' : '任务已停止。',
          'max-tokens' => '本轮达到输出长度上限，可继续对话。',
          'blocked' => '任务已暂停。',
          'forked' => '此处由原对话分支。',
          _ => '任务结束：${kind ?? '未记录原因'}',
        };
        _put(
          ChatEntry(
            key: 'turn-end:$seq',
            seq: seq,
            kind: ChatEntryKind.notice,
            event: event,
            title: kind == 'error' || kind == 'interrupted'
                ? '本轮任务未完成'
                : '任务状态',
            text: text,
            error: kind == 'error' || kind == 'interrupted' || signedOut,
          ),
        );
        return;
      case 'llm/retry':
        _resetAssistantPrefix(data);
        _retry(event);
        return;
      case 'llm/retry-started':
        _retry(event);
        return;
      case 'tool/call':
      case 'tool/result':
      case 'tool/ptc-dispatch':
      case 'tool/ptc-dispatch-start':
      case 'tool-workflow/run-start':
      case 'tool-workflow/agent-start':
      case 'tool-workflow/agent-end':
      case 'tool-workflow/run-end':
        return;
      default:
        // Merge-extensible surface events must stay inspectable. Lifecycle and
        // bookkeeping events without a surface marker are not chat messages.
        if (op == 'append') {
          _put(
            ChatEntry(
              key: 'unknown:$seq',
              seq: seq,
              kind: ChatEntryKind.unknown,
              event: event,
              title: '未识别的会话内容 · $type',
            ),
          );
        }
    }
  }

  _AssistantPrefix? _assistantPrefix(Json data) {
    final turn = data['turn'], step = data['step'];
    if (turn is! int || step is! int ||
        _settledSteps.contains((turn, step))) {
      return null;
    }
    return _assistantPrefixes
        .putIfAbsent(turn, () => <int, _AssistantPrefix>{})
        .putIfAbsent(step, _AssistantPrefix.new);
  }

  void _resetAssistantPrefix(Json data) {
    final turn = data['turn'], step = data['step'];
    if (turn is! int || step is! int) return;
    final steps = _assistantPrefixes[turn];
    steps?.remove(step);
    if (steps?.isEmpty == true) _assistantPrefixes.remove(turn);
    if (_frozenSteps.remove((turn, step))) {
      _remove('assistant-frozen:$turn:$step');
    }
  }

  void _closeAssistantPrefixes(Json event, {int? step}) {
    final turn = event['data']['turn'] as int;
    final prefixes = _assistantPrefixes[turn];
    if (prefixes == null) return;
    final closingSteps = step == null
        ? (prefixes.keys.toList()..sort())
        : [step];
    for (final closingStep in closingSteps) {
      final prefix = prefixes.remove(closingStep);
      if (prefix == null || _settledSteps.contains((turn, closingStep))) {
        continue;
      }
      final content = prefix.visibleContent;
      if (content.isEmpty) continue;
      _frozenSteps.add((turn, closingStep));
      // ChatEntry keeps integer sequences. Insert at the closing event before
      // its notice; stable tie ordering preserves the original interrupted
      // assistant's position without inventing a durable message or id.
      _put(
        ChatEntry(
          key: 'assistant-frozen:$turn:$closingStep',
          seq: event['seq'] as int,
          kind: ChatEntryKind.assistant,
          event: event,
          content: content,
          turn: turn,
          step: closingStep,
          interrupted: true,
        ),
      );
    }
    if (prefixes.isEmpty) _assistantPrefixes.remove(turn);
  }

  int _anchor(Json data, int fallback) {
    final turn = data['turn'], step = data['step'];
    return (step == 1 ? _turnStarts[turn] : null) ??
        _stepStarts[(turn, step)] ??
        fallback;
  }

  ChatEntry _promptRow(
    Json event,
    String text, {
    bool update = false,
    int? anchor,
  }) => ChatEntry(
    key: 'system:${event['seq']}',
    seq: anchor ?? event['seq'] as int,
    kind: ChatEntryKind.systemPrompt,
    event: event,
    title: update ? '系统提示更新' : '系统提示',
    text: text,
  );

  void _requestPrompt(Json event) {
    final data = event['data'] as Json;
    final system = _system.effective;
    final text = system?.text ?? '';
    final previous = _previousRequestSystem;
    final shownByAppend =
        _system.lastEvent?['type'] == 'system/message' &&
        _system.lastEvent?['surfaceOp'] == 'append' &&
        system != null &&
        (system.update || previous == null) &&
        system.turn == data['turn'] &&
        system.step == data['step'];
    final show =
        !shownByAppend &&
        (previous == null ||
            data['reason'] != 'change' ||
            data['startsSeries'] == true ||
            (text != previous && system?.update != true));
    if (show && text.isNotEmpty) {
      final location = (data['turn'], data['step']);
      final anchor =
          (previous == null && data['reason'] != 'initial') ||
              _previousRequestLocation == location
          ? event['seq'] as int
          : _anchor(data, event['seq'] as int);
      _put(_promptRow(event, text, anchor: anchor));
    }
    _previousRequestSystem = text;
    _previousRequestLocation = (data['turn'], data['step']);
  }

  void _retry(Json event) {
    final data = event['data'] as Json;
    final id = data['retryId'];
    if (id is! String || id.isEmpty) return;
    if (event['type'] == 'llm/retry') {
      final chain = _retries.putIfAbsent(id, () => _RetryChain(event));
      chain.attempts.add(_RetryAttempt(data));
      _putRetry(id, chain);
    } else {
      final chain = _retries[id];
      if (chain == null) return; // A start transition alone lacks its failure.
      for (final attempt in chain.attempts) {
        if (attempt.data['retry'] == data['retry']) attempt.state = 'started';
      }
      _putRetry(id, chain);
    }
  }

  void _closeRetries(dynamic turn, [dynamic step]) {
    for (final MapEntry(key: id, value: chain) in _retries.entries) {
      final data = chain.event['data'] as Json;
      if (data['turn'] != turn || (step != null && data['step'] != step)) {
        continue;
      }
      final current = chain.attempts.last;
      if (current.state != 'scheduled') continue;
      current.state = 'cancelled';
      _putRetry(id, chain);
    }
  }

  void _putRetry(String id, _RetryChain chain) {
    final current = chain.attempts.last;
    _put(
      ChatEntry(
        key: 'retry:$id',
        seq: chain.event['seq'] as int,
        kind: ChatEntryKind.notice,
        event: chain.event,
        title: switch (current.state) {
          'started' => '模型请求已重试',
          'cancelled' => '模型重试已取消',
          _ => '等待模型请求重试',
        },
        text: current.describe(),
        detailsTitle: '重试记录',
        details: chain.attempts.length > 1
            ? chain.attempts.map((attempt) => attempt.describe()).join('\n\n')
            : null,
      ),
    );
  }
}

/// Prefixes are presentation state only; snapshots replace streamed blocks so
/// a canonical assistant/attempt cannot duplicate already-seen token deltas.
class _AssistantPrefix {
  final _blocks = <int, dynamic>{};

  void replace(List<dynamic> content) {
    _blocks
      ..clear()
      ..addEntries(content.indexed.map((entry) => MapEntry(entry.$1, entry.$2)));
  }

  void apply(Json chunk) {
    final index = chunk['index'];
    if (index is! int) return;
    switch (chunk['type']) {
      case 'block-start':
      case 'tool-call-delta':
        _blocks.remove(index);
      case 'text-delta':
      case 'reasoning-delta':
        final text = chunk['text'];
        if (text is! String) return;
        final type = chunk['type'] == 'text-delta' ? 'text' : 'reasoning';
        final previous = _record(_blocks[index]);
        var retained = '';
        if (previous != null && previous['type'] == type) {
          retained = previous['text'] as String? ?? '';
        }
        _blocks[index] = {
          'type': type,
          'text': '$retained$text',
        };
      case 'block-end':
        final block = chunk['block'];
        if (block is Json) _blocks[index] = block;
    }
  }

  List<dynamic> get visibleContent {
    final indexes = _blocks.keys.toList()..sort();
    return List.unmodifiable(
      indexes.map((index) => _blocks[index]).where((block) {
        if (block is! Json) return true;
        if (block['type'] == 'tool-call') return false;
        if (block['type'] == 'text' || block['type'] == 'reasoning') {
          return (block['text'] as String? ?? '').trim().isNotEmpty;
        }
        return true;
      }),
    );
  }
}

class _RetryChain {
  _RetryChain(this.event);
  final Json event;
  final attempts = <_RetryAttempt>[];
}

class _RetryAttempt {
  _RetryAttempt(this.data);
  final Json data;
  String state = 'scheduled';

  String describe() {
    final maximum = data['mode'] == 'always' ? '∞' : data['maxRetries'];
    final status = switch (state) {
      'started' => '已开始',
      'cancelled' => '已取消',
      _ => '等待中',
    };
    final delay = data['delayMs'] as num?;
    final seconds = delay == null ? null : (delay / 1000).ceil();
    return '第 ${data['retry']}/$maximum 次重试 · $status'
        '${state == 'scheduled' && seconds != null ? ' · 计划等待 $seconds 秒' : ''}'
        '\n${chatFailureText(_record(data['failure']))}';
  }
}

String contextTitle(Json? source) {
  final kind = source?['kind'];
  final label = switch (kind) {
    'skill-invocation' => source?['name'] ?? kind,
    'agent-instructions' =>
      (source?['changes'] as List?)
          ?.whereType<Json>()
          .map((row) => row['path'])
          .whereType<String>()
          .join(', '),
    'session-reference' =>
      (source?['references'] as List?)
          ?.whereType<Json>()
          .map((row) => row['label'])
          .whereType<String>()
          .join(', '),
    _ => kind,
  };
  final role = kind == 'session-reference' ? '引用会话' : '上下文';
  return label == null || label == '' ? role : '$role · $label';
}

/// AUTH details can contain credential fragments; match the Web's displayFailure.
String chatFailureText(Json? failure) => switch (failure?['code']) {
  'AUTH' => '模型认证失败，请检查模型与凭据。',
  'ACCOUNT_SIGNED_OUT' => '已退出 DeepSeek 账号。',
  'ACCOUNT_SIGN_IN_REQUIRED' => '请先登录 DeepSeek 账号。',
  'QUOTA' || 'ACCOUNT_QUOTA' => '账号额度不足，请检查账号状态。',
  'INTERRUPTED' => '服务在任务完成前退出。',
  _ => failure?['message'] as String? ?? '请求未完成。',
};

List<dynamic> _content(Json? message) =>
    message?['content'] is List ? message!['content'] as List : const [];
Json? _record(dynamic value) => value is Json ? value : null;
String _text(List<dynamic> content) => content
    .whereType<Json>()
    .where((block) => block['type'] == 'text')
    .map((block) => block['text'] as String? ?? '')
    .join();

class _SystemPrompt {
  const _SystemPrompt(this.text, this.turn, this.step, this.update);
  final String text;
  final dynamic turn, step;
  final bool update;
}

/// Positional replacement handling follows ui-conversation/contract/system-prompt.ts.
class _SystemPromptState {
  int? firstSeq;
  bool uncertain = false;
  final nodes = <int, _SystemPrompt>{};
  final replacements = <int, int>{};
  _SystemPrompt? effective, introduced;
  Json? lastEvent;

  void apply(Json event) {
    final seq = event['seq'] as int;
    firstSeq ??= seq;
    lastEvent = event;
    introduced = null;
    final op = event['surfaceOp'];
    final oldKeys = nodes.keys.toList()..sort();
    final previous = oldKeys
        .map((key) => nodes[key]!)
        .where((node) => node.text.isNotEmpty)
        .lastOrNull;
    var position = seq;
    if (op is Json) {
      final start = op['startSeq'] as int, end = op['endSeq'] as int;
      uncertain |=
          (start < firstSeq! && !replacements.containsKey(start)) ||
          (end < firstSeq! && !replacements.containsKey(end));
      position = replacements[start] ?? start;
      final last = replacements[end] ?? end;
      nodes.removeWhere((key, _) => key >= position && key <= last);
      replacements.removeWhere(
        (_, value) => value >= position && value <= last,
      );
      replacements[seq] = position;
    }
    if (uncertain) {
      nodes.clear();
      replacements.clear();
      effective = null;
      return;
    }
    if (event['type'] == 'system/message') {
      final data = event['data'] as Json;
      introduced = _SystemPrompt(
        _text(_content(_record(data['message']))),
        data['turn'],
        data['step'],
        op == 'append' && previous != null,
      );
      nodes[position] = introduced!;
    }
    final ordered = nodes.keys.toList()..sort();
    final surviving = ordered
        .map((key) => nodes[key]!)
        .where((node) => node.text.isNotEmpty)
        .lastOrNull;
    if (identical(surviving, previous)) return;
    effective = identical(surviving, introduced)
        ? introduced
        : _SystemPrompt(
            surviving?.text ?? '',
            surviving?.turn ?? 0,
            surviving?.step ?? 0,
            false,
          );
  }
}
