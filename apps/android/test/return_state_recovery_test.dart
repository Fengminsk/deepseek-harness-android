import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runtime extends RuntimeController {
  final calls = <({String method, Json params})>[];
  final subscriptions = <Json>[];
  Json status = {'phase': 'ready', 'generation': 'service-a', 'mode': 'active'};
  Completer<Json>? statusRead, catalogRead;
  Completer<Json>? interactionRead;
  Completer<Json>? webRead;
  Json interactionValue = {'revision': 1, 'requests': <Json>[]};
  String catalogModel = 'one';
  bool failCatalog = false;
  int catalogReads = 0;
  int failUnsubscribes = 0;
  final statusFailures = <Object>[];

  // Other domains have their own baseline tests. Keep these tests focused on
  // lifecycle status and original account/catalog API traffic.
  @override
  Future<void> refresh() async {}

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    if (method == 'runtime.status') {
      if (statusFailures.isNotEmpty) throw statusFailures.removeAt(0);
      return statusRead?.future ?? status;
    }
    if (method == 'settings.describe') return <Json>[];
    if (method == 'web.status') return webRead!.future;
    if (method == 'interactions.list') {
      return interactionRead?.future ?? interactionValue;
    }
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

class _NativeRecovery {
  _NativeRecovery(this.tester, this.runtime);
  final WidgetTester tester;
  final _Runtime runtime;
  late MockStreamHandlerEventSink events;
  final methods = <String>[];
  Future<void> Function()? ensure;

  Future<void> open() async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      RuntimeController.events,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          events = sink;
        },
      ),
    );
    messenger.setMockMethodCallHandler(RuntimeController.channel, (call) async {
      methods.add(call.method);
      if (call.method == 'start' || call.method == 'restart') return null;
      if (call.method == 'runtime.ensureBound') {
        await ensure?.call();
        return null;
      }
      if (call.method == 'app.metadata') {
        return '{"version":"0.1.0","build":20}';
      }
      throw StateError('Unexpected native method ${call.method}');
    });
    addTearDown(() {
      messenger.setMockStreamHandler(RuntimeController.events, null);
      messenger.setMockMethodCallHandler(RuntimeController.channel, null);
    });
    await runtime.start();
    await tester.pump();
  }

  void status(Json value) =>
      events.success(jsonEncode({'method': 'runtime.status', 'params': value}));

  int get probes =>
      runtime.calls.where((call) => call.method == 'runtime.status').length;
  int get handshakes =>
      methods.where((method) => method == 'runtime.ensureBound').length;

  void expectNoBusinessReplay() {
    expect(methods.where((method) => method == 'restart'), isEmpty);
    expect(
      runtime.calls.where(
        (call) =>
            call.method == 'session.send' ||
            call.method == 'account.signIn' ||
            call.method == 'session.ensure',
      ),
      isEmpty,
    );
    expect(
      runtime.calls.where(
        (call) => call.params['method'] == 'initializeDefaultModel',
      ),
      isEmpty,
    );
  }
}

void main() {
  final webListening = <String, dynamic>{
    'enabled': true,
    'scope': 'local',
    'port': 3080,
    'phase': 'listening',
    'host': '127.0.0.1',
    'url': 'http://127.0.0.1:3080/?token=synthetic',
  };
  testWidgets(
    'native lifecycle withdraws Web addresses until a new observation',
    (tester) async {
      final runtime = _Runtime();
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      native.status(runtime.status);
      await tester.pump();
      native.events.success(
        jsonEncode({'method': 'web.changed', 'params': webListening}),
      );
      await tester.pump();
      expect(runtime.web['phase'], 'listening');
      native.status({'phase': 'failed', 'connection': 'disconnected'});
      await tester.pump();
      expect(runtime.web['enabled'], true);
      expect(runtime.web['url'], isNull);
      expect(runtime.web['phase'], 'unknown');
      native.events.success(
        jsonEncode({'method': 'web.changed', 'params': webListening}),
      );
      await tester.pump();
      expect(runtime.web['phase'], 'unknown');
      native.status({...runtime.status, 'generation': 'service-b'});
      await tester.pump();
      expect(runtime.ready, true);
      expect(runtime.web['phase'], 'unknown');
      native.events.success(
        jsonEncode({
          'method': 'web.changed',
          'params': {
            ...webListening,
            'url': 'http://127.0.0.1:3080/?token=new',
          },
        }),
      );
      await tester.pump();
      expect(runtime.web['url'], endsWith('token=new'));
      native.expectNoBusinessReplay();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'pushed network state supersedes an in-flight Web status baseline',
    (tester) async {
      final runtime = _Runtime();
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      native.status(runtime.status);
      await tester.pump();
      runtime.webRead = Completer<Json>();
      final read = runtime.refreshWeb();
      native.events.success(
        jsonEncode({
          'method': 'web.changed',
          'params': {
            ...webListening,
            'scope': 'lan',
            'phase': 'waiting-network',
            'host': null,
            'url': null,
          },
        }),
      );
      await tester.pump();
      runtime.webRead!.complete(webListening);
      await read;
      expect(runtime.web['phase'], 'waiting-network');
      expect(runtime.web['url'], isNull);
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets('old Web read cannot restore a replacement service access link', (
    tester,
  ) async {
    final runtime = _Runtime();
    final native = _NativeRecovery(tester, runtime);
    await native.open();
    native.status(runtime.status);
    await tester.pump();
    runtime.web = Map.of(webListening);
    runtime.webRead = Completer<Json>();
    final read = runtime.refreshWeb();
    native.status({...runtime.status, 'generation': 'service-b'});
    await tester.pump();
    runtime.webRead!.complete(webListening);
    await read;
    expect(runtime.web['phase'], 'unknown');
    expect(runtime.web['url'], isNull);
    runtime.dispose();
    await tester.pump();
  });

  for (final eventFirst in [true, false]) {
    testWidgets(
      'binding death recovers in the same foreground turn with ${eventFirst ? 'status' : 'error'} first',
      (tester) async {
        final runtime = _Runtime();
        final native = _NativeRecovery(tester, runtime);
        await native.open();
        native.status(runtime.status);
        await tester.pump();
        final pending = Completer<void>();
        native.ensure = () =>
            native.handshakes == 1 ? pending.future : Future.value();
        final resumed = runtime.resume();
        await tester.pump();
        runtime.status = {...runtime.status, 'generation': 'service-b'};
        void disconnected() => native.status({
          'phase': 'failed',
          'connection': 'disconnected',
          'error': '运行时连接中断',
        });
        if (eventFirst) {
          disconnected();
          await tester.pump();
          pending.completeError(PlatformException(code: 'disconnected'));
          await tester.pump();
        } else {
          pending.completeError(PlatformException(code: 'disconnected'));
          await tester.pump();
          disconnected();
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 250));
        await resumed;
        expect(native.handshakes, 2);
        expect(runtime.ready, isTrue);
        expect(runtime.nativeGeneration, 'service-b');
        expect(runtime.error, isNull);
        native.expectNoBusinessReplay();
        runtime.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets(
    'retired interaction snapshots and errors cannot replace a new service baseline',
    (tester) async {
      final runtime = _Runtime();
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      native.status(runtime.status);
      await tester.pump();
      final oldSnapshot = Completer<Json>();
      runtime.interactionRead = oldSnapshot;
      final oldRead = runtime.refreshInteractions();
      native.status({...runtime.status, 'generation': 'service-b'});
      await tester.pump();
      runtime.interactionRead = null;
      runtime.interactionValue = {
        'revision': 1,
        'requests': <Json>[
          {'id': 'current'},
        ],
      };
      await runtime.refreshInteractions();
      oldSnapshot.complete({
        'revision': 100,
        'requests': <Json>[
          {'id': 'retired'},
        ],
      });
      await oldRead;
      expect(runtime.interactions.single['id'], 'current');
      runtime.interactionValue = {
        'revision': 2,
        'requests': <Json>[
          {'id': 'next'},
        ],
      };
      await runtime.refreshInteractions();
      expect(runtime.interactions.single['id'], 'next');

      final oldError = Completer<Json>();
      runtime.interactionRead = oldError;
      final failedRead = expectLater(
        runtime.refreshInteractions(),
        throwsStateError,
      );
      native.status({...runtime.status, 'generation': 'service-c'});
      await tester.pump();
      runtime.interactionRead = null;
      await runtime.refreshInteractions();
      var notifications = 0;
      runtime.addListener(() => notifications++);
      oldError.completeError(StateError('retired service failure'));
      await failedRead;
      expect(runtime.interactionsError, isNull);
      expect(notifications, 0);
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'foreground waits for native binding and actual ready before observations',
    (tester) async {
      final runtime = _Runtime();
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      final bound = Completer<void>();
      native.ensure = () => bound.future;
      final resumed = runtime.resume();
      expect(runtime.resume(), same(resumed));
      await tester.pump();
      expect(native.handshakes, 1);
      expect(native.probes, 0);
      expect(runtime.subscriptions, isEmpty);
      bound.complete();
      await tester.pump();
      await resumed;
      expect(native.probes, 1);
      expect(runtime.ready, isTrue);
      expect(runtime.subscriptions, hasLength(1));
      expect(
        runtime.accountSnapshot!.connected,
        isFalse,
        reason: 'ready is not an account baseline',
      );
      native.expectNoBusinessReplay();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'transient starting invalidates trust then retries only binding and reads',
    (tester) async {
      final runtime = _Runtime();
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      native.status(runtime.status);
      await tester.pump();
      await runtime.models.refresh();
      final known = runtime.models.snapshot;
      runtime.statusFailures.add(
        PlatformException(code: 'starting', message: '正在连接本地服务'),
      );
      final resumed = runtime.resume();
      await tester.pump();
      expect(runtime.phase, 'starting');
      expect(runtime.error, isNull);
      expect(runtime.models.fresh, isFalse);
      expect(runtime.models.snapshot, same(known));
      expect(runtime.accountSnapshot!.connected, isFalse);
      expect(native.handshakes, 1);
      await tester.pump(const Duration(milliseconds: 250));
      await resumed;
      expect(native.handshakes, 2);
      expect(native.probes, 2);
      expect(runtime.ready, isTrue);
      expect(runtime.models.fresh, isTrue);
      native.expectNoBusinessReplay();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'native starting status keeps observations closed until a ready event',
    (tester) async {
      final runtime = _Runtime()
        ..status = {
          'phase': 'starting',
          'generation': 'service-b',
          'mode': 'active',
        };
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      final resumed = runtime.resume();
      await tester.pump();
      expect(native.probes, 1);
      expect(runtime.subscriptions, isEmpty);
      expect(runtime.ready, isFalse);
      runtime.status = {...runtime.status, 'phase': 'ready'};
      native.status(runtime.status);
      await tester.pump();
      await resumed;
      expect(runtime.ready, isTrue);
      expect(runtime.nativeGeneration, 'service-b');
      expect(runtime.subscriptions, hasLength(1));
      native.expectNoBusinessReplay();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'a late starting error cannot overwrite a newer ready generation',
    (tester) async {
      final runtime = _Runtime();
      final native = _NativeRecovery(tester, runtime);
      await native.open();
      native.status(runtime.status);
      await tester.pump();
      final old = Completer<Json>();
      runtime.statusRead = old;
      final resumed = runtime.resume();
      await tester.pump();
      native.status({...runtime.status, 'generation': 'service-b'});
      await tester.pump();
      old.completeError(PlatformException(code: 'starting'));
      await resumed;
      expect(runtime.nativeGeneration, 'service-b');
      expect(runtime.ready, isTrue);
      expect(runtime.error, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(native.handshakes, 1);
      native.expectNoBusinessReplay();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets('persistent binding loss is bounded and never invents ready', (
    tester,
  ) async {
    final runtime = _Runtime();
    final native = _NativeRecovery(tester, runtime);
    await native.open();
    native.ensure = () async => throw PlatformException(code: 'disconnected');
    final resumed = runtime.resume();
    await tester.pump();
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.pump(Duration(milliseconds: 250 * (1 << attempt)));
    }
    await resumed;
    expect(native.handshakes, 7);
    expect(native.probes, 0);
    expect(runtime.ready, isFalse);
    expect(runtime.error, contains('尚未连接本地服务'));
    expect(runtime.subscriptions, isEmpty);
    native.expectNoBusinessReplay();
    runtime.dispose();
    await tester.pump();
  });

  testWidgets('dispose cancels pending connection retries', (tester) async {
    final runtime = _Runtime();
    final native = _NativeRecovery(tester, runtime);
    await native.open();
    native.ensure = () async => throw PlatformException(code: 'starting');
    final resumed = runtime.resume();
    await tester.pump();
    runtime.dispose();
    await tester.pump();
    await resumed;
    await tester.pump(const Duration(seconds: 30));
    expect(native.handshakes, 1);
    expect(native.probes, 0);
  });

  testWidgets(
    'real failed and maintenance states do not restart or subscribe',
    (tester) async {
      for (final phase in ['failed', 'maintenance']) {
        final runtime = _Runtime()
          ..status = {
            'phase': phase,
            'generation': 'service-b',
            'mode': phase == 'maintenance' ? 'maintenance' : 'active',
          };
        final native = _NativeRecovery(tester, runtime);
        await native.open();
        await runtime.resume();
        expect(runtime.phase, phase);
        expect(native.handshakes, 1);
        expect(runtime.subscriptions, isEmpty);
        native.expectNoBusinessReplay();
        runtime.dispose();
        await tester.pump();
      }
    },
  );

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
        if (call.method == 'start' || call.method == 'runtime.ensureBound') {
          return null;
        }
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
