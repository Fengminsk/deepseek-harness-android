import 'dart:collection';
import 'dart:convert';

import 'runtime.dart';

enum TrajectoryKind {
  user,
  context,
  request,
  assistant,
  attempt,
  tool,
  compaction,
  lifecycle,
  other,
}

/// Values from recorded model calls. Missing fields stay missing, rather than
/// becoming estimates from message length or elapsed wall time.
class TrajectoryUsage {
  const TrajectoryUsage({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.reasoning = 0,
    this.total,
  });

  final int input, output, cacheRead, cacheWrite, reasoning;
  final int? total;

  int get countedTotal => total ?? input + output + cacheRead + cacheWrite;

  TrajectoryUsage add(TrajectoryUsage other) => TrajectoryUsage(
    input: input + other.input,
    output: output + other.output,
    cacheRead: cacheRead + other.cacheRead,
    cacheWrite: cacheWrite + other.cacheWrite,
    reasoning: reasoning + other.reasoning,
    total: countedTotal + other.countedTotal,
  );

  static TrajectoryUsage? from(dynamic source) {
    if (source is! Map ||
        source['inputTokens'] is! int ||
        source['outputTokens'] is! int) {
      return null;
    }
    int nonnegative(String key) {
      final value = source[key];
      return value is int && value >= 0 ? value : 0;
    }

    final input = source['inputTokens'] as int;
    final output = source['outputTokens'] as int;
    if (input < 0 || output < 0) return null;
    final total = source['totalTokens'];
    return TrajectoryUsage(
      input: input,
      output: output,
      cacheRead: nonnegative('cacheReadTokens'),
      cacheWrite: nonnegative('cacheWriteTokens'),
      reasoning: nonnegative('reasoningTokens'),
      total: total is int && total >= 0 ? total : null,
    );
  }
}

/// One durable ledger position. A tool's result updates its call position;
/// its original event maps are retained for the inspector.
class TrajectoryRecord {
  const TrajectoryRecord({
    required this.key,
    required this.seq,
    required this.time,
    required this.kind,
    required this.title,
    required this.events,
    this.turn,
    this.step,
    this.endTime,
    this.usage,
    this.cumulativeUsage,
    this.requestSeq,
    this.error = false,
    this.interrupted = false,
    this.summary,
  });

  final String key, title;
  final int seq, time;
  final TrajectoryKind kind;
  final List<Json> events;
  final int? turn, step, endTime, requestSeq;
  final TrajectoryUsage? usage, cumulativeUsage;
  final bool error, interrupted;
  final String? summary;

  int? get durationMs =>
      endTime == null || endTime! < time ? null : endTime! - time;
}

/// Read-only projection of the original ordered Session events. It never calls
/// the Agent or fetches history; the route owns its existing Session read.
class SessionTrajectoryProjection {
  List<Json>? _source;
  int _length = -1;
  List<TrajectoryRecord> _records = const [];
  TrajectoryUsage cumulative = const TrajectoryUsage();
  int? firstTime, lastTime;

  List<TrajectoryRecord> get records => _records;

  void reconcile(List<Json> events) {
    if (identical(_source, events) && _length == events.length) return;
    _source = events;
    _length = events.length;
    final rows = <TrajectoryRecord>[];
    final toolPositions = <String, int>{};
    final requestByStep = <(int, int), int>{};
    final stepStarts = <(int, int), int>{};
    var usageTotal = const TrajectoryUsage();
    int? turn, step, earliest, latest;

    for (final event in events) {
      final seq = event['seq'];
      final time = event['time'];
      final type = event['type'];
      final data = event['data'];
      if (seq is! int || time is! int || type is! String || data is! Map) {
        continue;
      }
      earliest = earliest == null || time < earliest ? time : earliest;
      latest = latest == null || time > latest ? time : latest;
      final dataTurn = data['turn'];
      final dataStep = data['step'];
      final recordTurn = dataTurn is int ? dataTurn : turn;
      final recordStep = dataStep is int ? dataStep : step;
      final location = (recordTurn, recordStep);
      switch (type) {
        case 'turn/start':
          turn = dataTurn is int ? dataTurn : turn;
          step = null;
          rows.add(
            _row(event, TrajectoryKind.lifecycle, '第 $turn 轮开始', turn: turn),
          );
        case 'step/start':
          turn = dataTurn is int ? dataTurn : turn;
          step = dataStep is int ? dataStep : step;
          if (turn != null && step != null) stepStarts[(turn, step)] = time;
          rows.add(
            _row(
              event,
              TrajectoryKind.lifecycle,
              '步骤 $step 开始',
              turn: turn,
              step: step,
            ),
          );
        case 'request/header':
          if (recordTurn != null && recordStep != null) {
            requestByStep[(recordTurn, recordStep)] = seq;
          }
          final config = data['header'] is Map
              ? (data['header'] as Map)['config']
              : null;
          final model = config is Map ? config['model'] : null;
          rows.add(
            _row(
              event,
              TrajectoryKind.request,
              '模型请求',
              turn: recordTurn,
              step: recordStep,
              summary: model is String ? model : null,
            ),
          );
        case 'user/message':
          if (event['surfaceOp'] != null && event['surfaceOp'] != 'append') {
            break;
          }
          final source = data['source'];
          final human = source is Map && source['kind'] == 'user';
          rows.add(
            _row(
              event,
              human ? TrajectoryKind.user : TrajectoryKind.context,
              human ? '你的消息' : '上下文',
              turn: recordTurn,
              step: recordStep,
              summary: source is Map && source['kind'] is String
                  ? source['kind'] as String
                  : null,
            ),
          );
        case 'assistant/message':
        case 'assistant/attempt':
          if (type == 'assistant/message' &&
              event['surfaceOp'] != null &&
              event['surfaceOp'] != 'append') {
            break;
          }
          final usage = type == 'assistant/message'
              ? TrajectoryUsage.from(data['usage']) ??
                    _streamUsage(data['stream'])
              : _streamUsage(data['stream']);
          if (usage != null) usageTotal = usageTotal.add(usage);
          final interrupted =
              data['interrupted'] == true || type == 'assistant/attempt';
          rows.add(
            _row(
              event,
              type == 'assistant/message'
                  ? TrajectoryKind.assistant
                  : TrajectoryKind.attempt,
              type == 'assistant/message' ? 'Agent 回复' : '未完成的模型尝试',
              turn: recordTurn,
              step: recordStep,
              requestSeq: requestByStep[location],
              usage: usage,
              cumulativeUsage: usage == null ? null : usageTotal,
              interrupted: interrupted,
              startTime: recordTurn != null && recordStep != null
                  ? stepStarts[(recordTurn, recordStep)]
                  : null,
            ),
          );
        case 'tool/call':
          final id = data['callId'];
          final name = data['name'];
          if (id is! String) break;
          final position = rows.length;
          toolPositions[jsonEncode([recordTurn, recordStep, id])] = position;
          rows.add(
            _row(
              event,
              TrajectoryKind.tool,
              name is String ? name : '工具调用',
              turn: recordTurn,
              step: recordStep,
              summary: '执行中',
            ),
          );
        case 'tool/result':
          if (event['surfaceOp'] != 'append') break;
          final message = data['message'];
          final source = message is Map ? message['source'] : null;
          final id = source is Map ? source['callId'] : null;
          final position = id is String
              ? toolPositions[jsonEncode([recordTurn, recordStep, id])]
              : null;
          final failed = message is Map && message['isError'] == true;
          if (position != null) {
            final previous = rows[position];
            rows[position] = TrajectoryRecord(
              key: previous.key,
              seq: previous.seq,
              time: previous.time,
              kind: previous.kind,
              title: previous.title,
              events: List.unmodifiable([...previous.events, event]),
              turn: previous.turn,
              step: previous.step,
              endTime: time,
              error: failed,
              summary: failed ? '失败' : '已完成',
            );
          } else {
            rows.add(
              _row(
                event,
                TrajectoryKind.tool,
                '工具结果',
                turn: recordTurn,
                step: recordStep,
                error: failed,
                summary: '缺少已加载的调用记录',
              ),
            );
          }
        case 'step/end':
          rows.add(
            _row(
              event,
              TrajectoryKind.lifecycle,
              '步骤结束',
              turn: recordTurn,
              step: recordStep,
            ),
          );
          if (turn == recordTurn && step == recordStep) step = null;
        case 'turn/end':
          final reason = data['reason'];
          final status = reason is Map ? reason['kind'] : null;
          rows.add(
            _row(
              event,
              TrajectoryKind.lifecycle,
              '本轮结束',
              turn: recordTurn,
              summary: status is String ? status : null,
              error: status == 'error' || status == 'interrupted',
            ),
          );
          if (turn == recordTurn) {
            turn = null;
            step = null;
          }
        case 'system/message':
        case 'developer/message':
          rows.add(
            _row(
              event,
              TrajectoryKind.context,
              type == 'system/message' ? '系统上下文' : '工具与开发上下文',
              turn: recordTurn,
              step: recordStep,
            ),
          );
        default:
          final kind = type.contains('compaction')
              ? TrajectoryKind.compaction
              : type.startsWith('assistant/live-') ||
                    type.startsWith('tool/ptc-')
              ? TrajectoryKind.lifecycle
              : TrajectoryKind.other;
          rows.add(
            _row(
              event,
              kind,
              _eventLabel(type),
              turn: recordTurn,
              step: recordStep,
            ),
          );
      }
    }
    _records = UnmodifiableListView(rows);
    cumulative = usageTotal;
    firstTime = earliest;
    lastTime = latest;
  }

  TrajectoryRecord _row(
    Json event,
    TrajectoryKind kind,
    String title, {
    int? turn,
    int? step,
    int? requestSeq,
    int? startTime,
    TrajectoryUsage? usage,
    TrajectoryUsage? cumulativeUsage,
    String? summary,
    bool error = false,
    bool interrupted = false,
  }) => TrajectoryRecord(
    key: 'event:${event['seq']}',
    seq: event['seq'] as int,
    time: startTime ?? event['time'] as int,
    endTime: startTime == null ? null : event['time'] as int,
    kind: kind,
    title: title,
    events: List.unmodifiable([event]),
    turn: turn,
    step: step,
    requestSeq: requestSeq,
    usage: usage,
    cumulativeUsage: cumulativeUsage,
    summary: summary,
    error: error,
    interrupted: interrupted,
  );

  TrajectoryUsage? _streamUsage(dynamic stream) {
    if (stream is! List) return null;
    TrajectoryUsage? combined;
    for (final entry in stream) {
      if (entry is! Map || entry['type'] != 'chunk') continue;
      final chunk = entry['chunk'];
      if (chunk is! Map || chunk['type'] != 'usage') continue;
      final usage = TrajectoryUsage.from(chunk['usage']);
      if (usage != null) {
        combined = combined == null ? usage : combined.add(usage);
      }
    }
    return combined;
  }

  String _eventLabel(String type) => switch (type) {
    'llm/retry' || 'llm/retry-started' => '模型重试',
    'assistant/live-chunk' => '模型输出片段',
    'tool/ptc-dispatch-start' => '子工具开始',
    'tool/ptc-dispatch' => '子工具结果',
    _ => type,
  };
}
