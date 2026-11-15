import 'dart:async';

import 'package:dsh_android/api_streams.dart';
import 'package:flutter_test/flutter_test.dart';

/// 建一个已经订阅成功的观察者，返回它的 `streamId` 与回执记录。
Future<
  ({
    AppApiStreams streams,
    StreamSubscription<ApiJson> subscription,
    String streamId,
    List<ApiJson> acks,
  })
>
_observe({required bool windowAck}) async {
  final acks = <ApiJson>[];
  final subscribed = Completer<ApiJson>();
  final streams = AppApiStreams((String method, ApiJson params) async {
    if (method == 'api.subscribe') {
      subscribed.complete(params);
      return <String, dynamic>{'generation': 'generation-1'};
    }
    if (method == 'api.ack') {
      acks.add(params);
      return <String, dynamic>{'accepted': true, 'upTo': params['upTo']};
    }
    return <String, dynamic>{'accepted': true};
  })
    ..setWindowAck(windowAck)
    ..setReady(true);
  final subscription = streams
      .watch('session', 'follow')
      .listen((ApiJson _) {});
  final request = await subscribed.future;
  // 让 open() 继续跑完（设置 generation），再开始收流帧。
  await Future<void>.delayed(Duration.zero);
  return (
    streams: streams,
    subscription: subscription,
    streamId: request['streamId']! as String,
    acks: acks,
  );
}

ApiJson _frame(String streamId, int sequence) => <String, dynamic>{
  'streamId': streamId,
  'generation': 'generation-1',
  'sequence': sequence,
  'type': 'item',
  'value': sequence,
};

void main() {
  test('窗口模式：每 32 条累计确认一次（协议 §6.2 的 min(W, 32)）', () async {
    final observed = await _observe(windowAck: true);
    addTearDown(() async {
      await observed.subscription.cancel();
      await observed.streams.close();
    });

    // 同步推入 33 帧：第 1 帧之后还没有「上一次回执」，第 33 帧攒满 32 条。
    for (var sequence = 1; sequence <= 33; sequence++) {
      observed.streams.receive(_frame(observed.streamId, sequence));
    }

    expect(observed.acks.map((ack) => ack['upTo']), <int>[1, 33]);
    for (final ack in observed.acks) {
      expect(ack.containsKey('sequence'), isFalse);
      expect(ack['streamId'], observed.streamId);
    }
  });

  test('窗口模式：40 条帧不会每帧都回执（确认不能退化成逐条）', () async {
    final observed = await _observe(windowAck: true);
    addTearDown(() async {
      await observed.subscription.cancel();
      await observed.streams.close();
    });

    for (var sequence = 1; sequence <= 40; sequence++) {
      observed.streams.receive(_frame(observed.streamId, sequence));
    }

    // 1（首帧）+ 33（第 33 帧攒满 32）两次；40 帧不足以再攒满一次。
    expect(observed.acks, hasLength(2));
  });

  test('逐条模式（宿主未声明 window-ack）：每帧回执，字段是 sequence', () async {
    final observed = await _observe(windowAck: false);
    addTearDown(() async {
      await observed.subscription.cancel();
      await observed.streams.close();
    });

    for (var sequence = 1; sequence <= 3; sequence++) {
      observed.streams.receive(_frame(observed.streamId, sequence));
    }

    expect(observed.acks, hasLength(3));
    expect(
      observed.acks.map((ack) => ack['sequence']),
      <int>[1, 2, 3],
    );
    for (final ack in observed.acks) {
      expect(ack.containsKey('upTo'), isFalse);
      // 本地 loopback 仍按旧字段名识别订阅，逐条模式的帧要保持原样。
      expect(ack['subscriptionId'], observed.streamId);
      expect(ack['generation'], 'generation-1');
    }
  });

  test('切回逐条模式后退回 sequence 字段', () async {
    final observed = await _observe(windowAck: true);
    addTearDown(() async {
      await observed.subscription.cancel();
      await observed.streams.close();
    });

    observed.streams.receive(_frame(observed.streamId, 1));
    expect(observed.acks.single['upTo'], 1);

    observed.streams.setWindowAck(false);
    observed.streams.receive(_frame(observed.streamId, 2));

    expect(observed.acks, hasLength(2));
    expect(observed.acks.last['sequence'], 2);
    expect(observed.acks.last.containsKey('upTo'), isFalse);
  });
}
