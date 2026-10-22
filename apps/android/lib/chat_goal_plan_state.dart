import 'dart:async';

import 'package:flutter/foundation.dart';

import 'runtime.dart';

/// Durable goal fields come from the original sequenced Session projection.
/// Activation is deliberately absent: it belongs to one live process only.
class ChatGoalState {
  const ChatGoalState({
    required this.id,
    required this.revision,
    required this.objective,
    required this.phase,
    required this.roundsStarted,
    required this.maxGoalRounds,
    this.blockedReason,
  });
  final String id, objective, phase;
  final int revision, roundsStarted, maxGoalRounds;
  final String? blockedReason;
  Json get ref => {'id': id, 'revision': revision};

  static ChatGoalState parse(dynamic value) {
    if (value is! Map || value['goal'] is! Map) {
      throw const FormatException('目标记录不完整');
    }
    final goal = value['goal'] as Map;
    if (goal['id'] is! String ||
        (goal['id'] as String).isEmpty ||
        goal['revision'] is! int ||
        goal['revision'] < 1 ||
        goal['objective'] is! String ||
        !const [
          'active',
          'paused',
          'blocked',
          'complete',
        ].contains(goal['phase']) ||
        goal['maxGoalRounds'] is! int ||
        goal['maxGoalRounds'] < 1 ||
        value['roundsStarted'] is! int ||
        value['roundsStarted'] < 0) {
      throw const FormatException('目标记录格式不受支持');
    }
    return ChatGoalState(
      id: goal['id'] as String,
      revision: goal['revision'] as int,
      objective: goal['objective'] as String,
      phase: goal['phase'] as String,
      roundsStarted: value['roundsStarted'] as int,
      maxGoalRounds: goal['maxGoalRounds'] as int,
      blockedReason: goal['blockedReason'] is Map
          ? goal['blockedReason']['message'] as String?
          : null,
    );
  }
}

class ChatPlanState {
  const ChatPlanState({required this.active, required this.pending});
  final bool active, pending;
  bool get target => pending ? !active : active;
  static ChatPlanState parse(dynamic value) {
    if (value is! Map ||
        value['active'] is! bool ||
        value['pending'] is! bool) {
      throw const FormatException('计划模式状态不完整');
    }
    return ChatPlanState(
      active: value['active'] as bool,
      pending: value['pending'] as bool,
    );
  }
}

/// Session-scoped reads never activate an Agent. Only an explicit mutation can
/// attach it. The host's projection, CAS and activation remain authoritative.
/// Disposing/rebinding fences late reads and writes; an uncertain write is never
/// replayed automatically. Remote calls already sent are owned by the runtime.
class ChatGoalPlanController extends ChangeNotifier {
  ChatGoalPlanController({required this.runtime, required this.sessionId}) {
    _generation = runtime.connectionGeneration;
    _ready = runtime.ready;
    _status = runtime.statuses[sessionId];
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  final String sessionId;
  ChatGoalState? goal;
  ChatPlanState? plan;
  bool goalAvailable = false, fresh = false, loading = false, busy = false;
  String? activation, error, actionError, actionKind;
  bool _disposed = false, _started = false, _ready = false;
  String? _status;
  int _generation = 0, _epoch = 0, _read = 0, _activationRead = 0;
  int _goalSeq = -1, _planSeq = -1;
  StreamSubscription<Json>? _control, _events;
  bool get alive => !_disposed;
  bool get canMutate => !_disposed && runtime.ready && fresh && !busy;
  bool get attached => runtime.ready && runtime.statuses.containsKey(sessionId);
  bool get canPause =>
      canMutate && goal?.phase == 'active' && activation == 'armed';
  bool get canResume =>
      canMutate &&
      goal != null &&
      (goal!.phase == 'paused' ||
          goal!.phase == 'blocked' ||
          (goal!.phase == 'active' && (!attached || activation == 'disarmed')));

  Future<dynamic> _api(String namespace, String method, Json args) =>
      runtime.call('api.call', {
        'namespace': namespace,
        'method': method,
        'args': args,
      });

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _control = runtime
        .watchApi('session', 'control')
        .listen(
          _onControl,
          onError: (Object failure) => _readFailure(failure),
          onDone: () {
            if (!_disposed) _readFailure(StateError('会话同步已结束，请重新打开会话'));
          },
        );
    _events = runtime.remoteEvents.listen(_onRemoteEvent);
    await refresh();
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch && runtime.ready;

  void _runtimeChanged() {
    if (_disposed) return;
    final connectionChanged =
        _generation != runtime.connectionGeneration || _ready != runtime.ready;
    final status = runtime.statuses[sessionId];
    final statusChanged = _status != status;
    _status = status;
    if (connectionChanged) {
      _generation = runtime.connectionGeneration;
      _ready = runtime.ready;
      _epoch++;
      _read++;
      _activationRead++;
      fresh = false;
      activation = null;
      _goalSeq = _planSeq = -1;
      loading = false;
      error = '连接已变化，正在重新确认会话状态。';
      _publish();
      if (_ready) unawaited(refresh());
    } else if (statusChanged) {
      activation = null;
      _activationRead++;
      _publish();
      if (attached) unawaited(_loadActivation());
    }
  }

  Future<void> refresh() async {
    if (_disposed || !runtime.ready) return;
    final epoch = _epoch, read = ++_read;
    loading = true;
    _publish();
    try {
      final value = await _api('session', 'projections', {
        'request': {'sessionId': sessionId},
      });
      if (!_current(epoch) || read != _read) return;
      if (value == null) {
        // A not-yet-created draft Session has no capability evidence.
        goal = null;
        plan = null;
        goalAvailable = false;
        fresh = true;
      } else {
        _baseline(value);
      }
      error = null;
      await _loadActivation();
    } catch (failure) {
      if (_current(epoch) && read == _read) _readFailure(failure);
    } finally {
      if (!_disposed && epoch == _epoch && read == _read) {
        loading = false;
        _publish();
      }
    }
  }

  void _readFailure(Object failure) {
    if (_disposed) return;
    fresh = false;
    activation = null;
    _activationRead++;
    error = '无法确认目标与计划状态：$failure';
    _publish();
  }

  void _baseline(dynamic value) {
    if (value is! Map ||
        value['kind'] != 'sequenced' ||
        value['values'] is! Map ||
        value['asOfSeq'] is! int) {
      throw const FormatException('会话尚未提供可用的状态快照');
    }
    final values = value['values'] as Map;
    final seq = value['asOfSeq'] as int;
    _acceptGoal(values['goal'], seq, available: values.containsKey('goal'));
    _acceptPlan(values['plan'], seq);
    fresh = true;
  }

  void _acceptGoal(dynamic value, int seq, {bool available = true}) {
    if (seq < _goalSeq) return;
    final next = value == null ? null : ChatGoalState.parse(value);
    if (goal?.id != next?.id || goal?.revision != next?.revision) {
      activation = null;
      _activationRead++;
    }
    goal = next;
    goalAvailable = available;
    _goalSeq = seq;
  }

  void _acceptPlan(dynamic value, int seq) {
    if (seq < _planSeq) return;
    plan = value == null ? null : ChatPlanState.parse(value);
    _planSeq = seq;
  }

  void _onControl(Json frame) {
    if (_disposed) return;
    try {
      if (frame['type'] == 'opening' || frame['type'] == 'disconnected') {
        _epoch++;
        _goalSeq = _planSeq = -1;
        fresh = false;
        activation = null;
        loading = false;
        _publish();
        return;
      }
      if (frame['type'] != 'item') return;
      final item = frame['value'];
      if (item is! Map) throw const FormatException('会话同步帧不完整');
      if (item['type'] == 'baseline') {
        final baseline = item['value']?['projections']?[sessionId];
        if (baseline != null) _baseline(baseline);
        // Cold sessions need a read-only query; control only contains live ones.
        if (!fresh) unawaited(refresh());
      } else if (item['type'] == 'projection' &&
          item['sessionId'] == sessionId) {
        final seq = item['seq'];
        if (seq is! int) throw const FormatException('会话同步序号不完整');
        if (item['key'] == 'goal') _acceptGoal(item['value'], seq);
        if (item['key'] == 'plan') _acceptPlan(item['value'], seq);
      } else {
        return;
      }
      error = null;
      _publish();
      unawaited(_loadActivation());
    } catch (failure) {
      _readFailure(failure);
    }
  }

  void _onRemoteEvent(Json frame) {
    if (_disposed || !attached || frame['event'] != 'goal/activation-changed') {
      return;
    }
    final args = frame['args'];
    final data = args is List && args.isNotEmpty ? args.first : null;
    if (data is! Map || data['sessionId'] != sessionId) return;
    _activationRead++;
    _acceptActivation(data['goal']);
    _publish();
  }

  void _acceptActivation(dynamic value) {
    // A clear or a different revision withdraws the previous live authority.
    // The durable projection may arrive after this process-local event.
    activation = null;
    if (value is Map &&
        value['id'] == goal?.id &&
        value['revision'] == goal?.revision &&
        const ['armed', 'disarmed'].contains(value['activation'])) {
      activation = value['activation'] as String;
    }
  }

  Future<void> _loadActivation() async {
    if (!fresh || !attached || goal?.phase != 'active' || _disposed) return;
    final epoch = _epoch, read = ++_activationRead;
    try {
      final value = await _api('goals', 'get', {'agentId': sessionId});
      if (!_current(epoch) || read != _activationRead || !attached) return;
      _acceptActivation(value);
      _publish();
    } catch (failure) {
      // Cold/non-live rejection cannot authorize continuation or erase history.
      if (_current(epoch) && read == _activationRead) {
        activation = null;
        _publish();
      }
    }
  }

  /// The caller retains its edit's original ref. A stale revision must never be
  /// replaced automatically by the current revision at save time.
  Future<bool> edit(
    ChatGoalState base, {
    required String objective,
    required int maxGoalRounds,
  }) => _mutate('edit', {
    'ref': base.ref,
    'request': {'objective': objective.trim(), 'maxGoalRounds': maxGoalRounds},
  });
  Future<bool> create(String objective, {int? maxGoalRounds}) =>
      _mutate('create', {
        'request': {
          'objective': objective.trim(),
          'maxGoalRounds': ?maxGoalRounds,
        },
      });
  Future<bool> pause() =>
      goal == null ? Future.value(false) : _mutate('pause', {'ref': goal!.ref});
  Future<bool> resume() => goal == null
      ? Future.value(false)
      : _mutate('resume', {'ref': goal!.ref});
  Future<bool> clear([ChatGoalState? expected]) => (expected ?? goal) == null
      ? Future.value(false)
      : _mutate('clear', {'ref': (expected ?? goal)!.ref});

  // Nonempty input except off becomes a model-visible planning request.
  Future<bool> setPlan(bool enabled) =>
      _mutate('plan', {'line': enabled ? '/plan' : '/plan off'});

  Future<bool> _mutate(String verb, Json args) async {
    if (!canMutate) return false;
    final epoch = _epoch;
    busy = true;
    actionError = null;
    actionKind = verb;
    _publish();
    var sent = false;
    try {
      // This is an explicit user action, unlike start/refresh/history reads.
      await runtime.ensureSession(sessionId);
      if (!_current(epoch)) throw StateError('会话连接已变化，请重新确认后操作');
      sent = true;
      if (verb == 'plan') {
        final result = await runtime.call('session.command', {
          'sessionId': sessionId,
          'line': args['line'],
          'attachmentIds': [],
        });
        if (result is! Map || result['result']?['kind'] != 'success') {
          final outcome = result is Map ? result['result'] : null;
          final message = outcome is Map ? outcome['text'] : null;
          throw StateError(message is String ? message : '计划指令不可用');
        }
      } else {
        await _api('goals', verb, {'agentId': sessionId, ...args});
      }
      if (!_current(epoch)) throw StateError('连接已变化，操作结果待确认');
      await refresh();
      return _current(epoch);
    } catch (failure) {
      if (!_disposed) {
        actionError =
            '${sent ? '操作未确认，请核对最新状态；编辑内容会保留' : '无法操作，编辑内容会保留'}：$failure';
        if (_current(epoch)) await refresh();
      }
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        _publish();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    runtime.removeListener(_runtimeChanged);
    unawaited(_control?.cancel());
    unawaited(_events?.cancel());
    super.dispose();
  }
}
