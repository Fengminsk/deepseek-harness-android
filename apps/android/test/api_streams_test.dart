import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/api_streams.dart';

void main() {
  test('page cancellation retires stream after readiness was cleared', () async {
    final calls = <String>[];
    final streams = AppApiStreams((method, params) async {
      calls.add(method);
      if (method == 'api.subscribe') return {'generation': 'first'};
      return {'closed': true};
    })..setReady(true);
    final listener = streams.watch('session', 'follow').listen((_) {});
    await pumpEventQueue();
    streams.setReady(false);
    await listener.cancel();
    expect(calls.where((method) => method == 'api.unsubscribe'), hasLength(1));
    await streams.close();
  });

  test('late stream admission is retired after the page cancels', () async {
    final admitted = Completer<ApiJson>();
    final subscribed = Completer<ApiJson>();
    final calls = <({String method, ApiJson params})>[];
    final streams = AppApiStreams((method, params) async {
      calls.add((method: method, params: params));
      if (method == 'api.subscribe') {
        subscribed.complete(params);
        return admitted.future;
      }
      return {'closed': true};
    })..setReady(true);
    final listener = streams.watch('session', 'control').listen((_) {});
    final request = await subscribed.future;
    await listener.cancel();
    admitted.complete({'generation': 'late-generation'});
    await pumpEventQueue();
    final retired = calls.where((call) => call.method == 'api.unsubscribe');
    expect(retired, hasLength(2));
    expect(retired.last.params['streamId'], request['streamId']);
    expect(retired.last.params['generation'], 'late-generation');
    await streams.close();
  });

  test(
    'late admission on reconnect retires old stream and opens a replacement',
    () async {
      final firstAdmission = Completer<ApiJson>();
      final calls = <({String method, ApiJson params})>[];
      final streams = AppApiStreams((method, params) async {
        calls.add((method: method, params: params));
        if (method == 'api.subscribe') {
          if (calls.where((call) => call.method == method).length == 1) {
            return firstAdmission.future;
          }
          return {'generation': 'replacement'};
        }
        return {'closed': true};
      })..setReady(true);
      final listener = streams.watch('session', 'control').listen((_) {});
      await pumpEventQueue();
      final original = calls.first.params['streamId'];
      streams.setReady(false);
      streams.setReady(true);
      firstAdmission.complete({'generation': 'original'});
      await pumpEventQueue();
      final subscriptions = calls
          .where((call) => call.method == 'api.subscribe')
          .toList();
      expect(subscriptions, hasLength(2));
      expect(subscriptions.last.params['streamId'], isNot(original));
      expect(
        calls.where(
          (call) =>
              call.method == 'api.unsubscribe' &&
              call.params['generation'] == 'original',
        ),
        hasLength(1),
      );
      await listener.cancel();
      await streams.close();
    },
  );

  testWidgets(
    'foreground unsubscribe failure retains identity and recovers the same observer',
    (tester) async {
      final calls = <({String method, ApiJson params})>[];
      final requests = <ApiJson>[];
      final firstAck = Completer<dynamic>();
      var failUnsubscribe = true;
      final streams = AppApiStreams((method, params) async {
        calls.add((method: method, params: params));
        if (method == 'api.subscribe') {
          requests.add(params);
          return {'generation': 'generation-${requests.length}'};
        }
        if (method == 'api.unsubscribe' && failUnsubscribe) {
          failUnsubscribe = false;
          throw StateError('temporary Binder failure');
        }
        if (method == 'api.ack' && params['generation'] == 'generation-1') {
          return firstAck.future;
        }
        return {'accepted': true};
      })..setReady(true);
      final frames = <ApiJson>[], errors = <Object>[];
      final subscription = streams
          .watch('session', 'control')
          .listen(frames.add, onError: errors.add);
      await tester.pump();
      streams.receive({
        'subscriptionId': requests.first['subscriptionId'],
        'generation': 'generation-1',
        'sequence': 1,
        'type': 'item',
        'value': 'initial',
      });
      await streams.reconnect();
      expect(errors, hasLength(1));
      expect(
        requests,
        hasLength(1),
      ); // No replacement until the old source closed.
      await tester.pump(const Duration(seconds: 1));
      expect(requests, hasLength(2));
      final closed = calls
          .where((call) => call.method == 'api.unsubscribe')
          .toList();
      expect(closed, hasLength(2));
      expect(closed[1].params, closed[0].params);
      firstAck.completeError(StateError('late old ack'));
      await tester.pump();
      streams.receive({
        'subscriptionId': requests.first['subscriptionId'],
        'generation': 'generation-1',
        'sequence': 2,
        'type': 'item',
        'value': 'obsolete',
      });
      streams.receive({
        'subscriptionId': requests.last['subscriptionId'],
        'generation': 'generation-2',
        'sequence': 1,
        'type': 'item',
        'value': 'recovered',
      });
      expect(errors, hasLength(1));
      expect(frames.last['value'], 'recovered');
      expect(frames.where((frame) => frame['value'] == 'obsolete'), isEmpty);
      await subscription.cancel();
      await streams.close();
      await tester.pump(const Duration(seconds: 40));
      expect(requests, hasLength(2));
    },
  );

  test('paused observers hold acknowledgement and cancellation releases the source', () async {
    final calls = <({String method, ApiJson params})>[];
    final subscribed = Completer<ApiJson>();
    final streams = AppApiStreams((method, params) async {
      calls.add((method: method, params: params));
      if (method == 'api.subscribe') {
        subscribed.complete(params);
        return {'generation': 'first'};
      }
      return {'accepted': true};
    })..setReady(true);
    final received = <ApiJson>[];
    final subscription = streams.watch('fixture', 'watch').listen(received.add);
    final request = await subscribed.future;
    subscription.pause();
    streams.receive({
      'subscriptionId': request['subscriptionId'],
      'generation': 'first',
      'sequence': 1,
      'type': 'item',
      'value': {'baseline': true},
    });
    expect(calls.where((item) => item.method == 'api.ack'), isEmpty);
    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(received.last['value'], {'baseline': true});
    expect(calls.where((item) => item.method == 'api.ack'), hasLength(1));
    await subscription.cancel();
    expect(calls.last.method, 'api.unsubscribe');
    await streams.close();
  });

  test(
    'reconnection uses the latest domain cursor and ignores old deliveries',
    () async {
      final requests = <ApiJson>[];
      final ready = [Completer<void>(), Completer<void>()];
      var cursor = 4;
      final streams = AppApiStreams((method, params) async {
        if (method == 'api.subscribe') {
          requests.add(params);
          ready[requests.length - 1].complete();
          return {'generation': 'generation-${requests.length}'};
        }
        return {'accepted': true};
      })..setReady(true);
      final frames = <ApiJson>[];
      final subscription = streams
          .watch(
            'job',
            'follow',
            resumeArgs: () => {
              'request': {'from': cursor},
            },
          )
          .listen(frames.add);
      await ready[0].future;
      streams.receive({
        'subscriptionId': requests[0]['subscriptionId'],
        'generation': 'generation-1',
        'sequence': 1,
        'type': 'item',
        'value': 'baseline-one',
      });
      cursor = 8;
      streams.setReady(false);
      streams.setReady(true);
      await ready[1].future;
      streams.receive({
        'subscriptionId': requests[0]['subscriptionId'],
        'generation': 'generation-1',
        'sequence': 2,
        'type': 'item',
        'value': 'stale',
      });
      streams.receive({
        'subscriptionId': requests[1]['subscriptionId'],
        'generation': 'generation-2',
        'sequence': 1,
        'type': 'item',
        'value': 'baseline-two',
      });
      expect(requests[1]['args']['request']['from'], 8);
      expect(frames.where((frame) => frame['value'] == 'stale'), isEmpty);
      expect(frames.last['value'], 'baseline-two');
      await subscription.cancel();
      await streams.close();
    },
  );

  test(
    'a late failed acknowledgement cannot close a replacement stream',
    () async {
      final firstAck = Completer<dynamic>();
      final requests = <ApiJson>[];
      final admitted = [Completer<void>(), Completer<void>()];
      final streams = AppApiStreams((method, params) async {
        if (method == 'api.subscribe') {
          requests.add(params);
          admitted[requests.length - 1].complete();
          return {'generation': 'generation-${requests.length}'};
        }
        if (method == 'api.ack' && params['generation'] == 'generation-1') {
          return firstAck.future;
        }
        return {'accepted': true};
      })..setReady(true);
      final frames = <ApiJson>[];
      final errors = <Object>[];
      final subscription = streams
          .watch('job', 'list')
          .listen(frames.add, onError: errors.add);
      await admitted[0].future;
      streams.receive({
        'subscriptionId': requests[0]['subscriptionId'],
        'generation': 'generation-1',
        'sequence': 1,
        'type': 'item',
        'value': 'before disconnect',
      });
      streams.setReady(false);
      streams.setReady(true);
      await admitted[1].future;
      firstAck.completeError(StateError('Old Binder disconnected'));
      await Future<void>.delayed(Duration.zero);
      streams.receive({
        'subscriptionId': requests[1]['subscriptionId'],
        'generation': 'generation-2',
        'sequence': 1,
        'type': 'item',
        'value': 'replacement baseline',
      });
      expect(errors, isEmpty);
      expect(frames.last['value'], 'replacement baseline');
      await subscription.cancel();
      await streams.close();
    },
  );

  test('close() 向宿主退订每一条在途观察，关闭后不再订阅', () async {
    final calls = <({String method, ApiJson params})>[];
    final streams = AppApiStreams((method, params) async {
      calls.add((method: method, params: params));
      if (method == 'api.subscribe') {
        return {'generation': 'generation-${params['streamId']}'};
      }
      return {'accepted': true};
    })..setReady(true);
    final events = <ApiJson>[];
    final first = streams
        .watch('session', 'follow')
        .listen(events.add, onError: events.add);
    final second = streams
        .watch('session', 'control')
        .listen(events.add, onError: events.add);
    await Future<void>.delayed(Duration.zero);
    final subscribed = calls
        .where((call) => call.method == 'api.subscribe')
        .toList();
    expect(subscribed, hasLength(2));
    expect(streams.diagnostics, hasLength(2));

    await streams.close();

    final unsubscribed = calls
        .where((call) => call.method == 'api.unsubscribe')
        .toList();
    expect(
      unsubscribed.map((call) => call.params['streamId']),
      unorderedEquals(subscribed.map((call) => call.params['streamId'])),
      reason: '关闭时必须向宿主退订每一条在途流，不能把 streamId 留在宿主上',
    );
    expect(streams.diagnostics, isEmpty, reason: '关闭后不应再持有观察记录');

    final errors = <Object>[];
    final late = streams
        .watch('session', 'follow')
        .listen((_) {}, onError: errors.add);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls.where((call) => call.method == 'api.subscribe'),
      hasLength(2),
      reason: '关闭后不允许再发起订阅',
    );
    expect(errors, hasLength(1));
    await late.cancel();
    await first.cancel();
    await second.cancel();
  });
}
