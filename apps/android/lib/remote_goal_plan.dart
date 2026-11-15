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
// 三态：未连接时 [plan] 保持 null（条不显示，不置灰一个不存在的条）；
// `session.projections` 读失败时 [error] 给出「状态待确认」并保留 [refresh] 供
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
    _control = source.watchSessionControl().listen(
      _onControl,
      onError: _onControlError,
      onDone: () {
        if (!_disposed) {
          _readFailure(StateError('会话同步已结束，请重新打开会话'));
        }
      },
    );
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (_disposed || source.phase != RemoteConnectionPhase.ready) return;
    final epoch = _epoch, read = ++_read;
    loading = true;
    _publish();
    try {
      final value = await source.readProjections();
      if (!_current(epoch) || read != _read) return;
      if (value == null) {
        // 会话还没有投影：与本地一样，不编一个默认状态。
        plan = null;
        fresh = true;
      } else {
        _baseline(value);
      }
      error = null;
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
      fresh = false;
      error = null;
      _publish();
      unawaited(refresh());
    }
  }

  void _readFailure(Object failure) {
    if (_disposed) return;
    fresh = false;
    error = '无法确认计划模式状态：$failure';
    _publish();
  }

  void _baseline(Object? value) {
    if (value is! Map ||
        value['kind'] != 'sequenced' ||
        value['values'] is! Map ||
        value['asOfSeq'] is! int) {
      throw const FormatException('会话尚未提供可用的状态快照');
    }
    final values = value['values'] as Map;
    _acceptPlan(values['plan'], value['asOfSeq'] as int);
    fresh = true;
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
        if (baseline != null) _baseline(baseline);
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
    final control = _control;
    _control = null;
    if (control != null) unawaited(control.cancel());
    super.dispose();
  }
}
