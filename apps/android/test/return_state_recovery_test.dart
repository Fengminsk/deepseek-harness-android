import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  final calls = <({String method, Json params})>[];
  final subscriptions = <Json>[];
  Json status = {'phase': 'ready', 'generation': 'service-a', 'mode': 'active'};
  Completer<Json>? statusRead, catalogRead;
  String catalogModel = 'one';
  bool failCatalog = false;
  int catalogReads = 0;
  int failUnsubscribes = 0;

  // Other domains have their own baseline tests. Keep these tests focused on
  // lifecycle status and original account/catalog API traffic.
  @override
  Future<void> refresh() async {}

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    if (method == 'runtime.status') return statusRead?.future ?? status;
    if (method == 'settings.describe') return <Json>[];
    if (method == 'api.subscribe') {
      final subscription = {
        ...params,
        'generation': 'stream-${subscriptions.length}',
      };
      subscriptions.add(subscription);
      return {'generation': subscription['generation']};
    }
    if (method == 'api.unsubscribe' || method == 'api.ack') {
      if (method == 'api.unsubscribe' && failUnsubscribes > 0) {
        failUnsubscribes--;
        throw StateError('temporary unsubscribe failure');
      }
      return {'accepted': true};
    }
    if (method != 'api.call') throw StateError('Unexpected RPC $method');
    switch (params['method']) {
      case 'listProviders':
        return <Json>[];
      case 'listConfigurableProviders':
        return <Json>[];
      case 'modelCatalog':
        catalogReads++;
        if (failCatalog) throw StateError('catalog unavailable');
        return catalogRead?.future ??
            {
              'default': {'provider': 'fixture', 'model': catalogModel},
              'groups': [],
            };
      case 'getProfile':
        return {
          'status': 'ready',
          'value': {'name': 'original account'},
        };
      case 'getBalance':
        return {'status': 'ready', 'value': [], 'bonusWallets': []};
      case 'getUnnotifiedBonuses':
        return {'accountId': 'fixture', 'bonuses': []};
      default:
        throw StateError(
          'Unexpected API ${params['namespace']}.${params['method']}',
        );
    }
  }
}

void main() {
  test(
    'directory retains last success and reloads when the service returns',
    () async {
      final runtime = _Runtime()..phase = 'ready';
      final directory = runtime.models;
      await directory.refresh();
      final known = directory.snapshot;
      expect(directory.fresh, isTrue);
      runtime.failCatalog = true;
      await directory.refresh();
      expect(directory.snapshot, same(known));
      expect(directory.fresh, isFalse);
      expect(directory.error, isNotNull);
      runtime.phase = 'starting';
      runtime.notifyListeners();
      final reads = runtime.catalogReads;
      await directory.refresh();
      expect(runtime.catalogReads, reads);
      runtime.failCatalog = false;
      runtime.catalogModel = 'two';
      runtime.phase = 'ready';
      runtime.notifyListeners();
      await directory.refresh();
      expect(directory.snapshot?.catalog['default']['model'], 'two');
      expect(directory.fresh, isTrue);
      expect(directory.error, isNull);
      runtime.dispose();
    },
  );

  test(
    'directory coalesces reads and rejects a previous service response',
    () async {
      final pending = Completer<Json>();
      final runtime = _Runtime()
        ..phase = 'ready'
        ..catalogRead = pending;
      final directory = runtime.models;
      final old = directory.refresh();
      expect(directory.refresh(), same(old));
      runtime.fail(StateError('service replaced'));
      runtime.catalogRead = null;
      runtime.catalogModel = 'replacement';
      runtime.phase = 'ready';
      runtime.notifyListeners();
      await directory.refresh();
      pending.complete({
        'default': {'model': 'obsolete'},
      });
      await old;
      expect(directory.snapshot?.catalog['default']['model'], 'replacement');
      expect(directory.fresh, isTrue);
      runtime.dispose();
    },
  );

  testWidgets(
    'foreground recovery replaces observations and preserves account until a real baseline',
    (tester) async {
      final runtime = _Runtime();
      final messenger = tester.binding.defaultBinaryMessenger;
      late MockStreamHandlerEventSink events;
      messenger.setMockStreamHandler(
        RuntimeController.events,
        MockStreamHandler.inline(
          onListen: (_, sink) {
            events = sink;
          },
        ),
      );
      messenger.setMockMethodCallHandler(RuntimeController.channel, (
        call,
      ) async {
        if (call.method == 'start') return null;
        if (call.method == 'app.metadata') {
          return '{"version":"0.1.0","build":18}';
        }
        throw StateError('Unexpected native method');
      });
      addTearDown(() {
        messenger.setMockStreamHandler(RuntimeController.events, null);
        messenger.setMockMethodCallHandler(RuntimeController.channel, null);
      });
      void emit(String method, Json params) =>
          events.success(jsonEncode({'method': method, 'params': params}));
      await runtime.start();
      await tester.pump();
      emit('runtime.status', runtime.status);
      await tester.pump();
      final first = runtime.subscriptions.single;
      void baseline(Json subscription, bool signed, {int sequence = 1}) =>
          emit('api.stream', {
            'subscriptionId': subscription['subscriptionId'],
            'generation': subscription['generation'],
            'sequence': sequence,
            'type': 'item',
            'value': {'status': signed ? 'credential-stored' : 'signed-out'},
          });
      baseline(first, true);
      await tester.pump();
      final account = runtime.accountSnapshot!;
      expect(account.connected, isTrue);
      expect(account.profile?['value']['name'], 'original account');
      runtime.failUnsubscribes = 2;
      await runtime.resume();
      expect(runtime.subscriptions, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      expect(runtime.subscriptions, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(runtime.subscriptions, hasLength(2));
      final closes = runtime.calls
          .where((call) => call.method == 'api.unsubscribe')
          .toList();
      expect(closes, hasLength(3));
      expect(closes.map((call) => call.params['subscriptionId']).toSet(), {
        first['subscriptionId'],
      });
      expect(runtime.accountSnapshot, same(account));
      expect(account.connected, isFalse);
      expect(account.profile?['value']['name'], 'original account');
      expect(await account.signOut(), isFalse);
      baseline(first, false, sequence: 2);
      await tester.pump();
      expect(
        account.signedIn,
        isTrue,
      ); // Last observation, not fresh authentication.
      expect(account.connected, isFalse);
      baseline(runtime.subscriptions.last, false);
      await tester.pump();
      expect(account.signedIn, isFalse);
      expect(account.connected, isTrue);
      expect(account.profile, isNull);
      expect(
        runtime.calls.where((call) => call.method == 'account.signIn'),
        isEmpty,
      );
      expect(
        runtime.calls.where(
          (call) => call.params['method'] == 'initializeDefaultModel',
        ),
        isEmpty,
      );

      // A process replacement can report ready -> ready without an intermediate
      // disconnect. Both the native generation and stream generation must change.
      final previous = runtime.connectionGeneration;
      emit('runtime.status', {...runtime.status, 'generation': 'service-b'});
      await tester.pump();
      expect(runtime.connectionGeneration, greaterThan(previous));
      expect(runtime.subscriptions, hasLength(3));
      expect(account.connected, isFalse);

      final staleProbe = Completer<Json>();
      runtime.statusRead = staleProbe;
      final resume = runtime.resume();
      emit('runtime.status', {...runtime.status, 'generation': 'service-c'});
      await tester.pump();
      staleProbe.complete(runtime.status);
      await resume;
      expect(runtime.nativeGeneration, 'service-c');
      runtime.dispose();
      await tester.pump();
    },
  );
}
