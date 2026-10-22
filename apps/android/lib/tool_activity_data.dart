import 'dart:convert';

import 'runtime.dart';

enum ToolActivityPhase { pending, completed, failed, interrupted, unknown }

/// One immutable rendering snapshot. Derived payloads are parsed only on demand.
class ToolActivity {
  ToolActivity({
    required this.identity,
    required this.callId,
    required this.anchorSeq,
    required this.name,
    required this.phase,
    required this.events,
    required this.children,
    this.argumentsRaw,
    this.argumentsValue,
    this.content = const [],
    this.error,
    this.meta,
    this.boundary,
    this.parentCallId,
    this.hasCall = false,
    this.hasResult = false,
    this.warnings = const [],
  });

  final String identity, callId, name;
  final int anchorSeq;
  final ToolActivityPhase phase;
  final String? argumentsRaw, parentCallId;
  final dynamic argumentsValue, meta;
  final List<dynamic> content;
  final Json? error, boundary;
  final bool hasCall, hasResult;
  final List<Json> events;
  final List<ToolActivity> children;
  final List<String> warnings;

  late final dynamic decodedArguments = argumentsValue ?? _decode(argumentsRaw);
  late final Json? args = decodedArguments is Json
      ? decodedArguments as Json
      : null;
  late final String resultText = content
      .whereType<Json>()
      .where((block) => block['type'] == 'text' && block['text'] is String)
      .map((block) => block['text'] as String)
      .join('\n');
  late final dynamic resultValue =
      content.length == 1 &&
          content.first is Json &&
          (content.first as Json)['type'] == 'text'
      ? _decode((content.first as Json)['text'] as String?)
      : null;
  late final String rawJson = const JsonEncoder.withIndent('  ').convert({
    'events': events,
    if (boundary != null) 'interruptionBoundary': boundary,
  });

  static dynamic _decode(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}

class _Call {
  _Call(this.id);
  final String id;
  Json? call, result, boundary;
  int? turn, step;
  String? parent;
  final events = <Json>[];
}

class _Root {
  _Root(this.id, this.identity);
  final String id;
  String identity;
  final calls = <String, _Call>{};
  final events = <Json>[];
  final children = <String, List<String>>{};
  final warnings = <String>[];
  ToolActivity? projected;
  bool dirty = true;
}

/// Session-owned, incremental projection of the existing append-only event log.
/// Runtime timelines append in place or replace their list on history refresh;
/// their existing event maps are immutable. A new list is checked for changes,
/// while unchanged streaming frames take an O(1) path without walking history.
class ToolActivityProjection {
  static const maxDepth = 256; // Same nesting ceiling as the Web projection.
  final _roots = <String, _Root>{};
  final _seen = <Json>[];
  final _consumed = <int>{};
  final _stepEnds = <(int, int), Json>{};
  final _turnEnds = <int, Json>{};
  List<Json>? _source;
  int? _turn, _step;
  Map<int, ToolActivity> _byAnchor = {};

  Map<int, ToolActivity> get byAnchorSeq => Map.unmodifiable(_byAnchor);

  /// Includes non-append tool/result events: those are surface replacements,
  /// not a second completion card, matching isAppendSurfaceEvent in the Web UI.
  Set<int> get consumedSeqs => Set.unmodifiable(_consumed);

  void reconcile(List<Json> events) {
    if (identical(_source, events) && _seen.length == events.length) return;
    _source = events;
    var prefix = 0;
    while (prefix < _seen.length &&
        prefix < events.length &&
        identical(_seen[prefix], events[prefix])) {
      prefix++;
    }
    if (prefix == _seen.length && prefix == events.length) return;
    if (prefix != _seen.length) {
      _roots.clear();
      _seen.clear();
      _consumed.clear();
      _stepEnds.clear();
      _turnEnds.clear();
      _turn = null;
      _step = null;
      prefix = 0;
    }
    for (final event in events.skip(prefix)) {
      _consume(event);
      _seen.add(event);
    }
    _byAnchor = {
      for (final root in _roots.values)
        _project(root).anchorSeq: _project(root),
    };
  }

  void _consume(Json event) {
    final type = event['type'];
    final seq = event['seq'] as int;
    final data = event['data'] as Json;
    if (type == 'turn/start') {
      _turn = data['turn'] as int;
      _step = null;
      return;
    }
    if (type == 'step/start') {
      _turn = data['turn'] as int;
      _step = data['step'] as int;
      return;
    }
    if (type == 'step/end' || type == 'turn/end') {
      final turn = data['turn'] as int;
      final step = data['step'] as int?;
      if (type == 'step/end') {
        _stepEnds[(turn, step!)] = event;
      } else {
        _turnEnds[turn] = event;
      }
      for (final root in _roots.values) {
        for (final call in root.calls.values) {
          if (call.turn == turn &&
              (type == 'turn/end' || call.step == step) &&
              call.result == null &&
              call.call != null &&
              (call.call!['seq'] as int) < seq) {
            call.boundary ??= event;
            root.dirty = true;
          }
        }
      }
      if (_turn == turn && (type == 'turn/end' || _step == step)) {
        _step = null;
        if (type == 'turn/end') _turn = null;
      }
      return;
    }
    if (type == 'tool/call' || type == 'tool/result') {
      if (type == 'tool/result' && event['surfaceOp'] != 'append') {
        _consumed.add(seq);
        return;
      }
      final id = type == 'tool/call'
          ? data['callId'] as String
          : data['message']['source']['callId'] as String;
      final root = _root(id, data['turn'] as int, data['step'] as int);
      final call = root.calls.putIfAbsent(id, () => _Call(id));
      root.events.add(event);
      call.events.add(event);
      if (type == 'tool/call') {
        call.call = event;
        call.turn = data['turn'] as int;
        call.step = data['step'] as int;
        _bound(call);
      } else {
        call.result = event;
        call.turn ??= data['turn'] as int;
        call.step ??= data['step'] as int;
      }
      root.dirty = true;
      _consumed.add(seq);
      return;
    }
    if (type != 'tool/ptc-dispatch-start' && type != 'tool/ptc-dispatch') {
      return;
    }
    final rootId = data['rootCallId'];
    if (rootId is! String || rootId.isEmpty) return;
    final candidates = _roots.values
        .where((root) => root.id == rootId)
        .toList();
    final root = _turn != null && _step != null
        ? _root(rootId, _turn, _step)
        : candidates.length == 1
        ? candidates.single
        : candidates.isEmpty
        ? _root(rootId, null, null)
        : _roots.putIfAbsent(
            'unscoped:$seq:$rootId',
            () =>
                _Root(rootId, 'unscoped:$seq:$rootId')
                  ..warnings.add('缺少步骤归属，存在多个同名调用，保留未归属的子调用记录。'),
          );
    root.events.add(event);
    root.dirty = true;
    _consumed.add(seq);
    final parentId = data['parentCallId'] as String;
    final childId = data['subCallId'] as String;
    final previous = root.calls[childId];
    if (childId == rootId ||
        (previous?.parent != null && previous!.parent != parentId) ||
        (previous?.parent == null && !_acceptsEdge(root, parentId, childId))) {
      root.warnings.add('子调用 $childId 的归属未展开：关系重复、循环或超过深度限制。');
      return;
    }
    if (previous?.parent == null) {
      root.children.putIfAbsent(parentId, () => []).add(childId);
    }
    final call = root.calls.putIfAbsent(childId, () => _Call(childId));
    call.parent = parentId;
    call.events.add(event);
    call.turn ??= root.calls[rootId]?.turn ?? _turn;
    call.step ??= root.calls[rootId]?.step ?? _step;
    if (type == 'tool/ptc-dispatch-start') {
      call.call ??= event;
      _bound(call);
    } else {
      call.result = event;
    }
  }

  _Root _root(String id, int? turn, int? step) {
    final identity = jsonEncode([turn, step, id]);
    final existing = _roots[identity];
    if (existing != null) return existing;
    final unscopedKey = jsonEncode([null, null, id]);
    final unscoped = _roots[unscopedKey];
    if (turn != null &&
        step != null &&
        unscoped != null &&
        _roots.values.where((root) => root.id == id).length == 1) {
      _roots.remove(unscopedKey);
      unscoped.identity = identity;
      for (final call in unscoped.calls.values) {
        call.turn ??= turn;
        call.step ??= step;
        if (call.call != null) _bound(call);
      }
      unscoped.dirty = true;
      return _roots[identity] = unscoped;
    }
    return _roots[identity] = _Root(id, identity);
  }

  void _bound(_Call call) {
    final end =
        _stepEnds[(call.turn ?? -1, call.step ?? -1)] ?? _turnEnds[call.turn];
    if (end != null && (end['seq'] as int) > (call.call!['seq'] as int)) {
      call.boundary = end;
    }
  }

  bool _acceptsEdge(_Root root, String parent, String child) {
    if (parent == child) return false;
    final ancestors = <String>{};
    String? cursor = parent;
    while (cursor != null) {
      if (cursor == child || !ancestors.add(cursor)) return false;
      cursor = root.calls[cursor]?.parent;
    }
    final pending = <(String, int)>[(child, 1)];
    final visited = <String>{};
    for (var index = 0; index < pending.length; index++) {
      final (id, depth) = pending[index];
      if (!visited.add(id) || ancestors.length + depth > maxDepth) return false;
      for (final nested in root.children[id] ?? <String>[]) {
        pending.add((nested, depth + 1));
      }
    }
    return true;
  }

  ToolActivity _project(_Root root) {
    if (!root.dirty) return root.projected!;
    ToolActivity project(String id, int depth) {
      final call = root.calls[id];
      final callData = call?.call?['data'] as Json?;
      final resultData = call?.result?['data'] as Json?;
      final ptc = call?.parent != null;
      final result = ptc ? resultData : (resultData?['message'] as Json?);
      final error = resultData?['error'] as Json?;
      final boundary = call?.boundary;
      final hasResult = call?.result != null;
      ToolActivityPhase phase;
      if (hasResult) {
        if (error?['code'] == 'interrupted' ||
            error?['code'] == 'TOOL_OUTCOME_UNKNOWN') {
          phase = ToolActivityPhase.interrupted;
        } else {
          phase = result?['isError'] == true
              ? ToolActivityPhase.failed
              : ToolActivityPhase.completed;
        }
      } else if (boundary != null) {
        phase = ToolActivityPhase.interrupted;
      } else {
        phase = call?.call != null
            ? ToolActivityPhase.pending
            : ToolActivityPhase.unknown;
      }
      final named = ptc ? (callData ?? resultData) : callData;
      final nested = [
        ...root.children[id] ?? <String>[],
        if (id == root.id)
          for (final parent in root.children.keys)
            if (parent != root.id && root.calls[parent]?.parent == null) parent,
      ];
      return ToolActivity(
        identity: jsonEncode([root.identity, id]),
        callId: id,
        anchorSeq:
            (call?.call ?? call?.result ?? root.events.first)['seq'] as int,
        name: named?['name'] as String? ?? '',
        argumentsRaw: ptc ? null : callData?['arguments'] as String?,
        argumentsValue: ptc ? (named?['arguments']) : null,
        phase: phase,
        events: List.unmodifiable(
          id == root.id ? root.events : call?.events ?? [],
        ),
        children: depth < maxDepth
            ? [for (final child in nested) project(child, depth + 1)]
            : const [],
        hasCall: call?.call != null,
        hasResult: hasResult,
        content: result?['content'] as List? ?? const [],
        error: error,
        meta: resultData?['meta'],
        boundary: hasResult ? null : boundary,
        parentCallId: call?.parent,
        warnings: [
          if (id == root.id) ...root.warnings,
          if (depth == maxDepth && nested.isNotEmpty)
            '子调用达到显示深度上限，完整记录保留在根调用的原始详情。',
        ],
      );
    }

    // Missing intermediate parents are presentation placeholders only: keep
    // the real graph untouched so later dispatch events can supply their edge.
    root.projected = project(root.id, 1);
    root.dirty = false;
    return root.projected!;
  }
}
