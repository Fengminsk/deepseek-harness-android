// 远程会话页的计划模式控制器。
//
// 与本地 `ChatGoalPlanController` 的 plan 分支同构：状态读 `session.projections`
// 的 `values.plan`（`{active, pending}`，`target` 由两者算出），实时增量订阅
// `session.control` 的 `plan` 投影帧，写入口是 `session.command` 的 `/plan` 与
// `/plan off`。差别只有两处：
//
// - 它依赖 [RemoteConversationSource] 而不是本地 `RuntimeController`，所以同一套
//   `ChatPlanDock` / `ChatPlanModePage` 可以在手机与配对电脑上复用；
// - goal（追求目标）不做：D6 已决策，激活态依赖 `goal/activation-changed` 这种
//   runtime 事件，远程协议 §8 的通知清单里没有对应项。
//
// 三态：未连接时 [plan] 保持 null（条不显示，不置灰一个不存在的条）；宿主的
// 投影快照尚未就绪（冷会话/旧格式待迁移）不是失败，保持 [fresh] 为 false 并按
// 有限退避再读，仍不可用就静默降级为「计划状态不可用」；只有真正的读失败
// （`readProjections` 抛错）才让 [error] 给出「状态待确认」并保留 [refresh] 供
// 页面提供重试；`session.command` 写失败时 [actionError] 保留原文说明，调用方
// 的输入草稿不受影响（本类不持有输入）。
//
// 与本地一致的提交语义：一次写操作在发送前 fixed（`sent`）标记，未确认的写不会
// 被自动重放；失败后重读一次权威状态，绝不把旧状态当成成功。

library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_goal_plan_state.dart';
import 'remote_connection.dart';
import 'remote_conversation_source.dart';
import 'runtime.dart';
import 'runtime_transport.dart';

/// 远程会话的计划模式状态。
///
/// 由会话页创建并持有：页面在 `initState` 里调用 [start]，在 `dispose` 里调用
/// [ChatPlanSurface] 之外的 [dispose]。实现只做 plan（见文件头说明）。
class RemoteGoalPlanController extends ChangeNotifier
    implements ChatPlanSurface {
  /// 绑定一个远程会话数据源。
  ///
  /// @param source 会话页持有的数据源；本类只读它的阶段、投影与流，不新建连接。
  RemoteGoalPlanController({required this.source}) {
    _phase = source.phase;
    source.addListener(_sourceChanged);
  }

  /// 会话页正在使用的远程数据源。
  final RemoteConversationSource source;

  @override
  ChatPlanState? plan;

  @override
  bool fresh = false, loading = false, busy = false;

  @override
  String? error, actionError, actionKind;

  bool _started = false, _disposed = false;
  RemoteConnectionPhase _phase = RemoteConnectionPhase.idle;
  int _epoch = 0, _read = 0, _planSeq = -1;
  StreamSubscription<Json>? _control;
  Timer? _resubscribe, _readiness;
  int _controlEnds = 0, _readinessAttempt = 0;

  /// 控制流在连接重建时会被退役（`onDone`），这不代表计划状态不可信；重连
  /// ready 后重新订阅，短时间连续结束（例如宿主立即收口）才停止重试，避免空转。
  static const int _maxControlEnds = 3;

  /// 投影快照未就绪时的有限重试节奏。
  ///
  /// 宿主还没有为这个会话给出 sequenced 快照（冷会话尚未激活、旧格式待迁移）时，
  /// 读会成功但拿不到可用值：这不是失败，按 300/600/1200 ms 退避再读几次；仍
  /// 不可用就静默降级为「计划状态不可用」，页面按无计划状态渲染。重连、控制流
  /// 重新订阅与显式 [refresh] 都会重新给一轮完整预算。
  static const List<Duration> _readinessRetryDelays = <Duration>[
    Duration(milliseconds: 300),
    Duration(milliseconds: 600),
    Duration(milliseconds: 1200),
  ];

  /// 控制器是否仍可用；页面在销毁前不必再检查。
  bool get alive => !_disposed;

  /// 是否可以发起写操作：连接就绪、状态已确认、且没有在途写。
  @override
  bool get canMutate =>
      !_disposed &&
      source.phase == RemoteConnectionPhase.ready &&
      fresh &&
      !busy;

  /// 开始订阅控制流并读一次首屏投影。重复调用返回同一次开始。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _subscribeControl();
    await refresh();
  }

  void _subscribeControl() {
    if (_disposed ||
        _control != null ||
        source.phase != RemoteConnectionPhase.ready) {
      return;
    }
    _control = source.watchSessionControl().listen(
      _onControl,
      onError: _onControlError,
      onDone: _onControlDone,
    );
  }

  void _onControlDone() {
    _control = null;
    if (_disposed || source.phase != RemoteConnectionPhase.ready) return;
    // 控制流结束通常是连接重建时退役旧订阅；保留最后一次投影并重读一次，
    // 不把「流结束」当成状态不可信。仅当短时间内反复结束（宿主不提供该流）
    // 才停止重新订阅，避免空转。
    if (_controlEnds >= _maxControlEnds) return;
    _controlEnds += 1;
    unawaited(refresh());
    _resubscribe?.cancel();
    _resubscribe = Timer(const Duration(milliseconds: 300), () {
      _resubscribe = null;
      _subscribeControl();
    });
  }

  @override
  Future<void> refresh() {
    // 显式重读（页面重试、恢复连接、计划页刷新）取代已排队的未就绪重试，并重新
    // 给出完整的有限重试预算。
    _cancelReadinessRetry();
    return _readProjections();
  }

  Future<void> _readProjections() async {
    if (_disposed || source.phase != RemoteConnectionPhase.ready) {
      _cancelReadinessRetry();
      return;
    }
    final epoch = _epoch, read = ++_read;
    loading = true;
    _publish();
    try {
      final value = await source.readProjections();
      if (!_current(epoch) || read != _read) return;
      if (value == null) {
        // 宿主明确回答「这个会话还没有投影」：与本地一样，不编一个默认状态。
        plan = null;
        fresh = true;
        error = null;
        _cancelReadinessRetry();
      } else if (_acceptBaseline(value)) {
        fresh = true;
        error = null;
        _cancelReadinessRetry();
      } else {
        _snapshotNotReady();
      }
    } on Object catch (failure) {
      if (_current(epoch) && read == _read) _readFailure(failure);
    } finally {
      if (!_disposed && epoch == _epoch && read == _read) {
        loading = false;
        _publish();
      }
    }
  }

  @override
  Future<bool> setPlan(bool enabled) async {
    if (!canMutate) return false;
    final epoch = _epoch;
    busy = true;
    actionError = null;
    actionKind = 'plan';
    _publish();
    var sent = false;
    try {
      // 显式用户操作：冷会话需要先恢复，与本地 `ChatGoalPlanController._mutate`
      // 的顺序一致（先 ensureSession，再发指令）。
      await source.ensureSession();
      if (!_current(epoch)) throw StateError('会话连接已变化，请重新确认后操作');
      sent = true;
      await source.submitPlan(enabled);
      if (!_current(epoch)) throw StateError('连接已变化，操作结果待确认');
      await refresh();
      return _current(epoch);
    } on Object catch (failure) {
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

  /// 当前读与写是否仍属于同一代连接。
  bool _current(int epoch) =>
      !_disposed &&
      epoch == _epoch &&
      source.phase == RemoteConnectionPhase.ready;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  /// 连接阶段变化：离开 ready 时收起计划条（不显示一个无法确认的状态），重新
  /// ready 时重读（协议 §7.2：重连后以宿主投影为准）。
  void _sourceChanged() {
    if (_disposed) return;
    final phase = source.phase;
    if (phase == _phase) return;
    final wasReady = _phase == RemoteConnectionPhase.ready;
    _phase = phase;
    if (phase != RemoteConnectionPhase.ready) {
      _epoch++;
      _read++;
      _planSeq = -1;
      _cancelReadinessRetry();
      plan = null;
      fresh = false;
      loading = false;
      busy = false;
      error = null;
      actionError = null;
      actionKind = null;
      _publish();
      return;
    }
    if (!wasReady) {
      // 重连后重新确认：先清掉上一代的读数，等待新的投影基线。
      _epoch++;
      _planSeq = -1;
      _cancelReadinessRetry();
      fresh = false;
      error = null;
      _controlEnds = 0;
      _publish();
      unawaited(refresh());
      _subscribeControl();
    }
  }

  void _readFailure(Object failure) {
    if (_disposed) return;
    _cancelReadinessRetry();
    fresh = false;
    error = '无法确认计划模式状态：$failure';
    _publish();
  }

  /// 快照尚未就绪：读本身成功，但宿主还没有给出可用基线。
  ///
  /// 这不是失败，不显示常驻错误条；保持 [fresh] 为 false（禁用写、页面按无计划
  /// 状态渲染），按 [_readinessRetryDelays] 退避再读。次数用尽后静默停在这里，
  /// 等重连、控制流重新订阅或显式 [refresh] 再试。
  void _snapshotNotReady() {
    if (_disposed) return;
    fresh = false;
    error = null;
    _scheduleReadinessRetry();
  }

  void _scheduleReadinessRetry() {
    if (_disposed || _readiness != null) return;
    if (_readinessAttempt >= _readinessRetryDelays.length) return;
    final delay = _readinessRetryDelays[_readinessAttempt++];
    _readiness = Timer(delay, () {
      _readiness = null;
      unawaited(_readProjections());
    });
  }

  /// 取消排队的未就绪重试并复位预算；重连/换代/显式重读都会调到它。
  void _cancelReadinessRetry() {
    _readiness?.cancel();
    _readiness = null;
    _readinessAttempt = 0;
  }

  /// 接受一份投影基线；false 表示快照尚未就绪而不是失败。
  ///
  /// `session.projections` 回 `{kind:'sequenced', asOfSeq, values}`；控制流基线的
  /// 每个会话是 `{asOfSeq, values}`（宿主的 `SessionProjectionBaseline`，没有
  /// `kind`）。两者是同一份已排序快照，缺 `kind` 不能当成失败。`plan` 值本身
  /// 不合法仍是协议失败，由调用方走 [_readFailure]。
  bool _acceptBaseline(Object? value) {
    if (value is! Map || value['values'] is! Map || value['asOfSeq'] is! int) {
      return false;
    }
    final kind = value['kind'];
    if (kind != null && kind != 'sequenced') return false;
    final values = value['values'] as Map;
    _acceptPlan(values['plan'], value['asOfSeq'] as int);
    return true;
  }

  void _acceptPlan(Object? value, int seq) {
    if (seq < _planSeq) return;
    plan = value == null ? null : ChatPlanState.parse(value);
    _planSeq = seq;
  }

  void _onControl(Json frame) {
    if (_disposed) return;
    try {
      if (frame['type'] == 'opening' || frame['type'] == 'disconnected') {
        _epoch++;
        _planSeq = -1;
        _cancelReadinessRetry();
        fresh = false;
        loading = false;
        _publish();
        return;
      }
      if (frame['type'] != 'item') return;
      final item = frame['value'];
      if (item is! Map) throw const FormatException('会话同步帧不完整');
      if (item['type'] == 'baseline') {
        final value = item['value'];
        final projections = value is Map ? value['projections'] : null;
        final baseline = projections is Map
            ? projections[source.sessionId]
            : null;
        if (baseline != null) {
          if (_acceptBaseline(baseline)) {
            fresh = true;
          } else {
            _snapshotNotReady();
          }
        }
        // 冷会话不在控制流里；还需要一次只读查询拿投影。
        if (!fresh) unawaited(refresh());
      } else if (item['type'] == 'projection' &&
          item['sessionId'] == source.sessionId) {
        final seq = item['seq'];
        if (seq is! int) throw const FormatException('会话同步序号不完整');
        if (item['key'] == 'plan') _acceptPlan(item['value'], seq);
      } else {
        return;
      }
      error = null;
      _publish();
    } on Object catch (failure) {
      _readFailure(failure);
    }
  }

  /// 控制流失败：断线与「方法不支持」由页面阶段机/手动重试承担，不升级成
  /// 计划状态的错误提示；其它失败（例如协议帧错误）说明状态不再可信。
  void _onControlError(Object failure) {
    if (_disposed) return;
    if (failure is RuntimeTransportFailure &&
        failure.code == 'gateway/internal' &&
        failure.message.contains('App stream limit reached')) {
      // Control observation admission failed, not the authoritative plan read.
      // Keep the last confirmed projection and ask the desktop for a fresh one.
      unawaited(refresh());
      return;
    }
    if (failure is RuntimeTransportFailure &&
        const <String>{
          'unsupported-method',
          'gateway/unavailable',
          'gateway/cancelled',
        }.contains(failure.code)) {
      return;
    }
    _readFailure(failure);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    source.removeListener(_sourceChanged);
    _resubscribe?.cancel();
    _resubscribe = null;
    _readiness?.cancel();
    _readiness = null;
    final control = _control;
    _control = null;
    if (control != null) unawaited(control.cancel());
    super.dispose();
  }
}
