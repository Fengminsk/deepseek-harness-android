import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

typedef ApiJson = Map<String, dynamic>;
typedef ApiCall = Future<dynamic> Function(String method, ApiJson params);

/// Activity-owned observations. Each new connection asks the original service
/// for its baseline, or for the caller's latest committed resume cursor.
class AppApiStreams {
  AppApiStreams(this.call);

  final ApiCall call;
  final Map<String, _Observation> _active = {};
  bool _ready = false;
  bool _closed = false;

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
    for (final observation in _active.values.toList()) {
      if (observation.deliveryId == frame['subscriptionId']) {
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
        unawaited(observation.open());
      } else {
        observation.disconnected();
      }
    }
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
        _ack();
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
  ApiJson? pendingAck;
  bool paused = false;
  bool cancelled = false;
  bool opening = false;

  Future<void> open() async {
    if (cancelled || opening || generation != null) return;
    opening = true;
    final attempt = ++epoch;
    final subscriptionId = '$id-$attempt';
    deliveryId = subscriptionId;
    sequence = 0;
    controller.add({'type': 'opening'});
    try {
      final response = await owner.call('api.subscribe', {
        'subscriptionId': subscriptionId,
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
      controller.addError(const FormatException('Stream notification gap'));
      unawaited(cancel());
      unawaited(controller.close());
      return;
    }
    sequence = next;
    if (frame['type'] == 'error') {
      final error = frame['error'] as ApiJson;
      controller.addError(
        PlatformException(
          code: error['code'] as String,
          message: error['message'] as String,
        ),
      );
      unawaited(cancel());
      unawaited(controller.close());
      return;
    }
    controller.add(frame);
    if (frame['type'] == 'end') {
      unawaited(cancel());
      unawaited(controller.close());
    } else {
      pendingAck = {
        'subscriptionId': deliveryId,
        'generation': incoming,
        'sequence': sequence,
      };
      _ack();
    }
  }

  void _ack() {
    final ack = pendingAck;
    if (cancelled || paused || ack == null) return;
    pendingAck = null;
    final attempt = epoch;
    unawaited(
      owner.call('api.ack', ack).catchError((Object error) {
        if (!cancelled && owner._ready && epoch == attempt) {
          controller.addError(error);
          unawaited(cancel());
          unawaited(controller.close());
        }
        return null;
      }),
    );
  }

  void disconnected() {
    epoch++;
    opening = false;
    generation = null;
    deliveryId = null;
    pendingAck = null;
    sequence = 0;
    if (!cancelled) controller.add({'type': 'disconnected'});
  }

  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    owner._active.remove(id);
    epoch++;
    if (!owner._ready || deliveryId == null) return;
    try {
      await owner.call('api.unsubscribe', {
        'subscriptionId': deliveryId,
        if (generation != null) 'generation': generation,
      });
    } catch (error) {
      // Binder teardown also releases every stream of this Activity.
    }
  }
}
