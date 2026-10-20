import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/api_streams.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'diagnostics distinguish delivery stages without initiating work',
    () async {
      final calls = <String>[];
      final admitted = Completer<ApiJson>();
      late ApiJson request;
      var cursorReads = 0;
      final streams = AppApiStreams((method, params) async {
        calls.add(method);
        if (method == 'api.subscribe') {
          request = params;
          return admitted.future;
        }
        return {'accepted': true};
      });
      final subscription = streams
          .watch(
            'account',
            'watch',
            resumeArgs: () {
              cursorReads++;
              return {'token': 'private-request-value'};
            },
          )
          .listen((_) {});

      expect(streams.diagnostics, [
        {
          'namespace': 'account',
          'method': 'watch',
          'state': 'waiting-service',
          'sequence': 0,
        },
      ]);
      expect(calls, isEmpty);
      expect(cursorReads, 0);

      streams.setReady(true);
      final pending = streams.diagnostics;
      expect(pending.single['state'], 'subscribing');
      expect(calls, ['api.subscribe']);
      expect(cursorReads, 1);
      admitted.complete({'generation': 'private-generation'});
      await Future<void>.delayed(Duration.zero);
      expect(streams.diagnostics.single['state'], 'waiting-first-frame');
      expect(pending.single['state'], 'subscribing');
      expect(() => pending.single['state'] = 'changed', throwsUnsupportedError);
      expect(() => pending.clear(), throwsUnsupportedError);

      streams.receive({
        'subscriptionId': request['subscriptionId'],
        'generation': 'private-generation',
        'sequence': 1,
        'type': 'item',
        'value': {
          'credential': 'private-frame-value',
          'url': 'https://example.invalid/?token=private-token',
        },
      });
      expect(streams.diagnostics.single['state'], 'received');
      expect(streams.diagnostics.single['sequence'], 1);
      expect(
        jsonEncode(streams.diagnostics),
        jsonEncode([
          {
            'namespace': 'account',
            'method': 'watch',
            'state': 'received',
            'sequence': 1,
          },
        ]),
      );
      expect(calls, ['api.subscribe', 'api.ack']);
      expect(cursorReads, 1);

      streams.setReady(false);
      expect(streams.diagnostics.single['state'], 'disconnected');
      expect(streams.diagnostics.single['sequence'], 0);
      await subscription.cancel();
      expect(streams.diagnostics, isEmpty);
      expect(calls, ['api.subscribe', 'api.ack']);
      await streams.close();
    },
  );

  test(
    'an early first frame is reported while admission is still pending',
    () async {
      final admitted = Completer<ApiJson>();
      final subscribed = Completer<ApiJson>();
      final streams = AppApiStreams((method, params) async {
        if (method == 'api.subscribe') {
          subscribed.complete(params);
          return admitted.future;
        }
        return {'accepted': true};
      })..setReady(true);
      final subscription = streams.watch('job', 'follow').listen((_) {});
      final request = await subscribed.future;
      streams.receive({
        'subscriptionId': request['subscriptionId'],
        'generation': 'early-generation',
        'sequence': 1,
        'type': 'item',
        'value': 'not part of diagnostics',
      });
      expect(streams.diagnostics.single['state'], 'received');
      expect(streams.diagnostics.single['sequence'], 1);
      admitted.complete({'generation': 'early-generation'});
      await Future<void>.delayed(Duration.zero);
      expect(streams.diagnostics.single['state'], 'received');
      await subscription.cancel();
      expect(streams.diagnostics, isEmpty);
      await streams.close();
    },
  );

  test(
    'runtime exposes only the allowlisted active observation snapshot',
    () async {
      final runtime = RuntimeController();
      final subscription = runtime
          .watchApi(
            'account',
            'watch',
            args: {'credential': 'must-not-be-exported'},
          )
          .listen((_) {});
      expect(runtime.observationDiagnostics, [
        {
          'namespace': 'account',
          'method': 'watch',
          'state': 'waiting-service',
          'sequence': 0,
        },
      ]);
      await subscription.cancel();
      expect(runtime.observationDiagnostics, isEmpty);
      runtime.dispose();
    },
  );
}
