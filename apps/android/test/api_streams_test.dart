import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/api_streams.dart';

void main() {
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
}
