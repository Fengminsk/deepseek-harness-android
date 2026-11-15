import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

typedef ApiJson = Map<String, dynamic>;
typedef ApiCall = Future<dynamic> Function(String method, ApiJson params);

/// Activity-owned observations. Each new connection asks the original service
/// for its baseline, or for the caller's latest committed resume cursor.
class AppApiStreams {
  AppApiStreams(this.call);

  /// 窗口化回执节奏（`docs/remote-dsh/protocol.md` §6.2）：累计收到这么多条，
  /// 或距上次回执超过这么久，就发一次 `api.ack`，只报最新的连续序号。
  ///
  /// §6.2 要求 `min(W, 32)`；服务端窗口宽度 `W = 64`，因此客户端每 32 条确认一次。
  static const _ackWindowFrames = 32;
  static const _ackWindowDelay = Duration(milliseconds: 200);

  /// 序号缺口在这个时间内仍未补齐，就重新订阅一次拿自洽基线。
  static const _gapRecoveryDelay = Duration(seconds: 5);

  /// 缺口缓冲上限。超过它说明缺口不是短暂乱序，直接走重订阅。
  static const _maxBufferedFrames = 256;

  final ApiCall call;
  final Map<String, _Observation> _active = {};
  bool _ready = false;
  bool _closed = false;
  bool _windowAck = false;

  /// 是否与服务端协商出了窗口化回执（`docs/remote-dsh/protocol.md` §6.4）。
  ///
  /// 默认 `false`：本地 loopback 与没有在 `protocol.hello` 里声明 `window-ack` 的
  /// 宿主都按逐条模式回执——每帧一次 `api.ack`，字段名是 `sequence`。只有握手结果
  /// 两侧都声明 `window-ack` 时调用方才用 [setWindowAck] 打开：此后回执按累计
  /// `upTo` 上报，节奏见 [_ackWindowFrames]。
  bool get windowAck => _windowAck;

  /// 切换回执模式（协议 §6.4）。
  ///
  /// 切换不清空进行中的观察：两种模式的确认序号都是累计值，下一次回执按新模式发送
  /// 即可。关闭后（[close] 返回之后）调用它不会有任何效果。
  void setWindowAck(bool enabled) {
    if (_closed || _windowAck == enabled) return;
    _windowAck = enabled;
  }

  /// A read-only snapshot of active delivery stages. Keep this allowlist
  /// separate from request arguments, frames and transport identifiers.
  List<ApiJson> get diagnostics => List<ApiJson>.unmodifiable(
    _active.values.map(
      (observation) => Map<String, dynamic>.unmodifiable({
        'namespace': observation.namespace,
        'method': observation.method,
        'state': _diagnosticState(observation),
        'sequence': observation.sequence,
      }),
    ),
  );

  String _diagnosticState(_Observation observation) {
    if (!_ready) {
      return observation.epoch == 0 ? 'waiting-service' : 'disconnected';
    }
    if (observation.sequence > 0) return 'received';
    if (observation.opening || observation.generation == null) {
      return 'subscribing';
    }
    return 'waiting-first-frame';
  }

  Stream<ApiJson> watch(
    String namespace,
    String method, {
    ApiJson args = const {},
    ApiJson Function()? resumeArgs,
  }) {
    final id =
        'stream-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    final observation = _Observation(
      this,
      id,
      namespace,
      method,
      resumeArgs ?? () => args,
    );
    return observation.controller.stream;
  }

  void receive(ApiJson frame) {
    // 远程连接按协议发 `streamId`，本地 loopback 仍用 `subscriptionId`。
    final id = frame['subscriptionId'] ?? frame['streamId'];
    for (final observation in _active.values.toList()) {
      if (observation.deliveryId == id) {
        observation.receive(frame);
        return;
      }
    }
  }

  void setReady(bool ready) {
    if (_closed || _ready == ready) return;
    _ready = ready;
    for (final observation in _active.values.toList()) {
      if (ready) {
        unawaited(observation.reconnect());
      } else {
        observation.disconnected();
      }
    }
  }

  /// Reattach foreground observers to their service baseline even when Binder
  /// stayed connected while Flutter stopped delivering frames.
  Future<void> reconnect() async {
    if (_closed || !_ready) return;
    await Future.wait(_active.values.toList().map((item) => item.reconnect()));
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(_active.values.toList().map((item) => item.cancel()));
  }
}

class _Observation {
  _Observation(
    this.owner,
    this.id,
    this.namespace,
    this.method,
    this.resumeArgs,
  ) {
    controller = StreamController<ApiJson>(
      sync: true,
      onListen: () {
        if (owner._closed) {
          scheduleMicrotask(() {
            controller.addError(StateError('Runtime observations are closed'));
            unawaited(controller.close());
          });
          return;
        }
        owner._active[id] = this;
        scheduleMicrotask(() {
          if (owner._ready && !cancelled) unawaited(open());
        });
      },
      onCancel: cancel,
      onPause: () => paused = true,
      onResume: () {
        paused = false;
        _flushAck();
      },
    );
  }

  final AppApiStreams owner;
  final String id;
  final String namespace;
  final String method;
  final ApiJson Function() resumeArgs;
  late final StreamController<ApiJson> controller;
  String? generation;
  String? deliveryId;
  int sequence = 0;
  int epoch = 0;

  /// 已发回执的连续序号；`sequence` 是已收到（连续）的最大序号。
  int _acked = 0;
  int _unacked = 0;
  DateTime? _lastAck;
  Timer? _ackTimer;
  Timer? _gapTimer;

  /// 缺口之后先到的帧。只有补齐后才按序交付，并继续保持确认停在缺口前。
  final Map<int, ApiJson> _buffered = {};
  bool paused = false;
  bool cancelled = false;
  bool opening = false;
  ApiJson? _closingSubscription;
  bool _reconnecting = false;
  Timer? _reconnectRetry;
  int _reconnectFailures = 0;

  Future<void> open() async {
    if (cancelled || opening || generation != null) return;
    if (_closingSubscription != null) {
      unawaited(reconnect());
      return;
    }
    opening = true;
    final attempt = ++epoch;
    final subscriptionId = '$id-$attempt';
    deliveryId = subscriptionId;
    sequence = 0;
    _resetAcks();
    controller.add({'type': 'opening'});
    try {
      final response = await owner.call('api.subscribe', {
        // 远程连接按协议用 `streamId`，本地 loopback 与原生文档预览用
        // `subscriptionId`；两者同值携带，两侧都不必在别处再映射字段名。
        'subscriptionId': subscriptionId,
        'streamId': subscriptionId,
        'namespace': namespace,
        'method': method,
        'args': resumeArgs(),
      }) as ApiJson;
      if (cancelled || attempt != epoch) return;
      final admitted = response['generation'] as String;
      if (generation != null && generation != admitted) {
        throw const FormatException('Stream admission changed its generation');
      }
      generation = admitted;
    } catch (error, stack) {
      if (!cancelled && attempt == epoch) {
        controller.addError(error, stack);
        await cancel();
        unawaited(controller.close());
      }
    } finally {
      if (attempt == epoch) opening = false;
    }
  }

  void receive(ApiJson frame) {
    if (cancelled || !owner._ready) return;
    final incoming = frame['generation'] as String;
    if (generation != null && incoming != generation) return;
    generation ??= incoming;
    final next = frame['sequence'] as int;
    if (next <= sequence) return;
    if (next != sequence + 1) {
      _hold(next, frame);
      return;
    }
    if (!_deliver(frame)) return;
    _drainBuffered();
  }

  /// 序号不连续不再判致命：保留缓冲等补齐，同时确认停在缺口之前，
  /// 服务端因此不会越过缺口继续推进窗口。
  void _hold(int next, ApiJson frame) {
    if (_buffered.length >= AppApiStreams._maxBufferedFrames) {
      _recoverGap();
      return;
    }
    _buffered[next] = frame;
    _gapTimer ??= Timer(AppApiStreams._gapRecoveryDelay, () {
      _gapTimer = null;
      _recoverGap();
    });
  }

  void _drainBuffered() {
    while (_buffered.isNotEmpty) {
      final frame = _buffered.remove(sequence + 1);
      if (frame == null) break;
      if (!_deliver(frame)) return;
    }
    if (_buffered.isEmpty) {
      _gapTimer?.cancel();
      _gapTimer = null;
    }
  }

  /// 缺口在重试窗口内没有补齐时重新订阅：新 generation 给出自洽基线，
  /// 已交付的帧保持不动，不会被静默改写。
  void _recoverGap() {
    if (cancelled || !owner._ready || _buffered.isEmpty) return;
    if (opening || _reconnecting) {
      _gapTimer ??= Timer(AppApiStreams._gapRecoveryDelay, () {
        _gapTimer = null;
        _recoverGap();
      });
      return;
    }
    unawaited(reconnect());
  }

  /// 按序号交付一帧；返回 false 表示这不是一条可继续的流。
  bool _deliver(ApiJson frame) {
    if (cancelled || !owner._ready) return false;
    final next = frame['sequence'] as int;
    if (next <= sequence) return true;
    sequence = next;
    if (frame['type'] == 'error') {
      // 终止帧：先把已收到的连续序号确认掉，再按既有行为失败并关闭。
      _flushAck(force: true);
      final error = frame['error'] as ApiJson;
      controller.addError(
        PlatformException(
          code: error['code'] as String,
          message: error['message'] as String,
        ),
      );
      unawaited(cancel());
      unawaited(controller.close());
      return false;
    }
    controller.add(frame);
    if (frame['type'] == 'end') {
      _flushAck(force: true);
      unawaited(cancel());
      unawaited(controller.close());
      return false;
    }
    _unacked++;
    _scheduleAck();
    return true;
  }

  bool get _ackDue => sequence > _acked;

  void _scheduleAck() {
    if (cancelled || paused || !_ackDue) return;
    if (!owner._windowAck) {
      // 逐条模式（协议 §6.4）：服务端推一条就等这一条的确认，回执不能攒——
      // 攒着会让服务端永远等不到窗口推进。
      _flushAck();
      return;
    }
    if (_unacked >= AppApiStreams._ackWindowFrames || _lastAck == null) {
      _flushAck();
      return;
    }
    final elapsed = DateTime.now().difference(_lastAck!);
    if (elapsed >= AppApiStreams._ackWindowDelay) {
      _flushAck();
      return;
    }
    _ackTimer ??= Timer(AppApiStreams._ackWindowDelay - elapsed, () {
      _ackTimer = null;
      _flushAck();
    });
  }

  void _flushAck({bool force = false}) {
    if (cancelled || (!force && paused) || !_ackDue) return;
    _ackTimer?.cancel();
    _ackTimer = null;
    final upTo = sequence;
    final id = deliveryId;
    final observedGeneration = generation;
    _acked = upTo;
    _unacked = 0;
    _lastAck = DateTime.now();
    if (id == null) return;
    final attempt = epoch;
    unawaited(
      owner
          .call('api.ack', {
            // 远程连接按协议取 streamId/upTo；本地 loopback 与原生文档预览仍按
            // 旧字段名识别订阅，两种名字同帧携带，映射不落第二处。
            'streamId': id,
            'subscriptionId': id,
            // 协议 §6.4：只有双方都声明 window-ack 才用累计 `upTo`；否则退回逐条
            // 模式，字段名用本地既有的 `sequence`（老宿主只认它）。
            if (owner._windowAck) 'upTo': upTo else 'sequence': upTo,
            'generation': ?observedGeneration,
          })
          .catchError((Object error) {
            if (!cancelled && owner._ready && epoch == attempt) {
              controller.addError(error);
              unawaited(cancel());
              unawaited(controller.close());
            }
            return null;
          }),
    );
  }

  void _resetAcks() {
    _acked = 0;
    _unacked = 0;
    _lastAck = null;
    _ackTimer?.cancel();
    _ackTimer = null;
    _gapTimer?.cancel();
    _gapTimer = null;
    _buffered.clear();
  }

  void disconnected() {
    // Retain the exact old identity until unsubscribe is confirmed. A transient
    // Binder error must not strand an unacknowledged producer on the service.
    final closingId = deliveryId;
    if (closingId != null) {
      _closingSubscription ??= {
        'subscriptionId': closingId,
        'streamId': closingId,
        if (generation != null) 'generation': generation,
      };
    }
    _reconnectRetry?.cancel();
    _reconnectRetry = null;
    epoch++;
    opening = false;
    generation = null;
    deliveryId = null;
    sequence = 0;
    _resetAcks();
    if (!cancelled) controller.add({'type': 'disconnected'});
  }

  Future<void> reconnect() async {
    if (cancelled || opening || _reconnecting || !owner._ready) return;
    _reconnecting = true;
    disconnected();
    final attempt = epoch;
    try {
      await _closeRetiredSubscription();
      if (!cancelled && owner._ready && attempt == epoch) {
        _reconnectFailures = 0;
        await open();
      }
    } catch (error, stack) {
      if (!cancelled && attempt == epoch) {
        controller.addError(error, stack);
        final delay = 1 << (_reconnectFailures > 5 ? 5 : _reconnectFailures++);
        _reconnectRetry = Timer(Duration(seconds: delay), () {
          _reconnectRetry = null;
          if (!cancelled && owner._ready) unawaited(reconnect());
        });
      }
    } finally {
      _reconnecting = false;
      // The service may have changed while unsubscribe was in flight. Its
      // readiness event cannot be lost merely because this attempt was busy.
      if (!cancelled &&
          owner._ready &&
          attempt != epoch &&
          !opening &&
          generation == null) {
        scheduleMicrotask(() => unawaited(reconnect()));
      }
    }
  }

  Future<void> _closeRetiredSubscription() async {
    final closing = _closingSubscription;
    if (closing == null) return;
    await owner.call('api.unsubscribe', closing);
    if (identical(closing, _closingSubscription)) _closingSubscription = null;
  }

  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    owner._active.remove(id);
    disconnected();
    if (!owner._ready) return;
    try {
      await _closeRetiredSubscription();
    } catch (error) {
      // Binder teardown also releases every stream of this Activity.
    }
  }
}
