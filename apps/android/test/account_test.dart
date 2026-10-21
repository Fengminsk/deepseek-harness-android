import 'dart:async';

import 'package:dsh_android/account.dart';
import 'package:dsh_android/account_state.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json _view({bool signed = false, Json? attempt}) => {
  'status': signed ? 'credential-stored' : 'signed-out',
  'attempt': attempt,
  'links': {
    'usageUrl': 'https://platform.deepseek.com/usage',
    'topUpUrl': 'https://platform.deepseek.com/top_up',
  },
};

const _client = {
  'version': '0.1.0',
  'locale': 'zh-CN',
  'timezoneOffsetSeconds': 28800,
};

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  final feeds = <StreamController<Json>>[];
  final calls = <Json>[];
  final pendingProfiles = <Completer<Json?>>[];
  void Function()? onWatch;
  bool deferProfile = false, failProfile = false, failImpact = false;
  bool returnFailedDetails = false;
  bool failInitialization = false, failForms = false;
  Completer<void>? pendingInitialization;
  Json defaultSelection = {
    'provider': 'deepseek-account',
    'model': 'account-model',
  };
  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    expectSync([namespace, method], ['account', 'watch']);
    final feed = StreamController<Json>(sync: true, onCancel: () async {});
    feeds.add(feed);
    onWatch?.call();
    return feed.stream;
  }

  void publish(Json view) => feeds.last.add({'type': 'item', 'value': view});

  void returnToAccount() {
    navigationRequest = {'route': 'account'};
    notifyListeners();
  }

  void serviceReady() {
    phase = 'ready';
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add({'rpc': method, ...params});
    if (method == 'account.signIn') {
      return _view(attempt: {'id': 'attempt-a', 'phase': 'initializing'});
    }
    if (method == 'settings.describe') {
      if (failForms) throw StateError('configuration unavailable');
      return [
        {'ns': 'agent-default-model', 'value': Json.of(defaultSelection)},
      ];
    }
    if (method == 'api.call' &&
        params['namespace'] == 'session' &&
        params['method'] == 'initializeDefaultModel') {
      await pendingInitialization?.future;
      if (failInitialization) {
        throw StateError('private initialization failure');
      }
      return null; // Original initializeDefaultModel is Promise<void>.
    }
    if (method != 'api.call' || params['namespace'] != 'account') {
      throw StateError('Unexpected RPC');
    }
    switch (params['method']) {
      case 'getProfile':
        if (returnFailedDetails) return {'status': 'failed'};
        if (failProfile) throw StateError('private upstream response');
        if (deferProfile) {
          final result = Completer<Json?>();
          pendingProfiles.add(result);
          return result.future;
        }
        return {
          'status': 'ready',
          'value': {'id': 'account-a', 'name': '测试账号', 'contact': '1**'},
        };
      case 'getBalance':
        if (returnFailedDetails) return {'status': 'failed'};
        return {
          'status': 'ready',
          'value': [
            {'currency': 'CNY', 'balance': '0.0001'},
          ],
          'bonusWallets': [],
        };
      case 'getUnnotifiedBonuses':
        return {
          'accountId': 'account-a',
          'bonuses': [
            {'orderId': 'order-a', 'message': '平台赠送通知', 'expiresAt': ''},
          ],
        };
      case 'hasRunningAccountTasks':
        if (failImpact) throw StateError('offline');
        return true;
      case 'ackBonusNotified':
        return true;
      case 'cancelSignIn':
        return _view(
          attempt: {'id': params['args']['attemptId'], 'phase': 'cancelled'},
        );
      case 'signOut':
        return _view();
      default:
        throw StateError('Unknown method');
    }
  }

  Future<void> closeFeeds() async {
    for (final feed in feeds) {
      await feed.close();
    }
  }
}

void main() {
  testWidgets(
    'shared account survives page disposal and transient profile failure',
    (tester) async {
      final runtime = _Runtime();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => '{"version":"0.1.0","build":18}',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      final account = await runtime.ensureAccount();
      runtime.publish(_view(signed: true));
      await tester.pump();
      final knownProfile = account.profile;
      expect(knownProfile?['value']['name'], '测试账号');
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AccountPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(await runtime.ensureAccount(), same(account));
      expect(runtime.feeds, hasLength(1));
      runtime.failProfile = true;
      await account.refreshDetails();
      expect(account.profile, same(knownProfile));
      expect(account.detailsError, isNotNull);
      runtime.returnFailedDetails = true;
      await account.refreshDetails();
      expect(account.profile, same(knownProfile));
      expect(account.profileFresh, isFalse);
      expect(account.balanceFresh, isFalse);
      expect(account.detailsError, isNotNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AccountPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本机凭据已保存 · 账号资料待刷新'), findsOneWidget);
      expect(find.text('上次读取，本次尚未更新'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      runtime.fail(StateError('connection lost'));
      expect(account.connected, isFalse);
      expect(account.profile, same(knownProfile));
      expect(await account.signOut(), isFalse);
      runtime.serviceReady();
      runtime.publish(_view());
      expect(account.signedIn, isFalse);
      expect(account.profile, isNull);
      expect(
        runtime.calls.where(
          (call) => ['signOut', 'signIn'].contains(call['method']),
        ),
        isEmpty,
      );
      runtime.dispose();
      await tester.runAsync(runtime.closeFeeds);
    },
  );

  test(
    'reopened baseline starts new details before obsolete reads finish',
    () async {
      final runtime = _Runtime()..deferProfile = true;
      final account = AccountState(runtime, _client);
      await account.watch();
      runtime.publish(_view(signed: true));
      expect(runtime.pendingProfiles, hasLength(1));
      runtime.feeds.last.add({'type': 'disconnected'});
      runtime.feeds.last.add({'type': 'opening'});
      runtime.publish(_view(signed: true));
      expect(runtime.pendingProfiles, hasLength(2));
      runtime.pendingProfiles[1].complete({
        'status': 'ready',
        'value': {'name': 'fresh'},
      });
      await Future<void>.delayed(Duration.zero);
      runtime.pendingProfiles[0].complete({
        'status': 'ready',
        'value': {'name': 'obsolete'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(account.profile?['value']['name'], 'fresh');
      expect(account.loadingDetails, isFalse);
      account.dispose();
      await runtime.closeFeeds();
      runtime.dispose();
    },
  );

  test('synchronous signed-out then restored baseline cannot reuse the empty detail read', () async {
    final runtime = _Runtime();
    final account = AccountState(runtime, _client);
    await account.watch();
    runtime.publish(_view());
    runtime.publish(_view(signed: true));
    await Future<void>.delayed(Duration.zero);
    expect(account.profile?['value']['name'], '测试账号');
    expect(account.connected, isTrue);
    account.dispose();
    await runtime.closeFeeds();
    runtime.dispose();
  });

  test('ended account observation retries without replaying login or default writes', () async {
    final runtime = _Runtime();
    final account = AccountState(runtime, _client);
    await account.watch();
    final view = _view(
      signed: true,
      attempt: {'id': 'accepted', 'phase': 'succeeded'},
    );
    runtime.publish(view);
    await Future<void>.delayed(Duration.zero);
    final reopened = Completer<void>();
    runtime.onWatch = reopened.complete;
    await runtime.feeds.first.close();
    expect(account.connected, isFalse);
    await reopened.future.timeout(const Duration(seconds: 5));
    expect(runtime.feeds, hasLength(2));
    runtime.publish(view);
    await Future<void>.delayed(Duration.zero);
    expect(account.connected, isTrue);
    expect(
      runtime.calls.where((call) => call['method'] == 'initializeDefaultModel'),
      hasLength(1),
    );
    expect(
      runtime.calls.where((call) => call['rpc'] == 'account.signIn'),
      isEmpty,
    );
    account.dispose();
    await runtime.closeFeeds();
    runtime.dispose();
  });

  for (final phase in ['starting', 'failed']) {
    testWidgets('cold account return opens while the service is $phase', (
      tester,
    ) async {
      final runtime = _Runtime()
        ..phase = phase
        ..returnToAccount();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => '{"version":"0.1.0","build":8}',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: ChatPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage), findsOneWidget);
      expect(runtime.navigationRequest, isNull);
      expect(
        find.text(phase == 'failed' ? '本地服务需要处理' : '正在等待本地服务'),
        findsOneWidget,
      );
      expect(find.text('登录 DeepSeek'), findsNothing);
      expect(runtime.calls, isEmpty);
      runtime.serviceReady();
      runtime.publish(_view());
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage), findsOneWidget);
      expect(find.text('登录 DeepSeek'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.closeFeeds);
      runtime.dispose();
    });
  }

  testWidgets(
    'return link queries account state without signing in or duplicating the account page',
    (tester) async {
      final runtime = _Runtime();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => '{"version":"0.1.0","build":8}',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: ChatPage(runtime: runtime),
        ),
      );
      await tester.enterText(find.byType(TextField), '未发送的内容');
      runtime.returnToAccount();
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage), findsOneWidget);
      expect(find.text('登录 DeepSeek'), findsNothing);
      expect(runtime.feeds, hasLength(1));
      runtime.publish(_view(signed: true));
      await tester.pumpAndSettle();
      runtime.returnToAccount();
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage), findsOneWidget);
      expect(runtime.feeds, hasLength(1));
      expect(
        runtime.calls.where((item) => item['method'] == 'getProfile'),
        hasLength(2),
      );
      expect(
        runtime.calls.where(
          (item) =>
              item['rpc'] == 'account.signIn' ||
              item['method'] == 'initializeDefaultModel',
        ),
        isEmpty,
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('未发送的内容'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.closeFeeds);
      runtime.dispose();
    },
  );

  testWidgets('an unavailable runtime is distinct from a signed-out account', (
    tester,
  ) async {
    final runtime = _Runtime()
      ..phase = 'failed'
      ..error = '运行时连接中断';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      (call) async => '{"version":"0.1.0","build":8}',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: AccountPage(runtime: runtime),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本地服务需要处理'), findsOneWidget);
    expect(find.text('登录 DeepSeek'), findsNothing);
    runtime.serviceReady();
    runtime.publish(_view());
    await tester.pumpAndSettle();
    expect(find.text('本地服务需要处理'), findsNothing);
    expect(find.text('登录 DeepSeek'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(runtime.closeFeeds);
    runtime.dispose();
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  test('first succeeded snapshot initializes through the core and refreshes the actual default once', () async {
    final runtime = _Runtime();
    final model = AccountState(runtime, _client);
    addTearDown(() async {
      model.dispose();
      await runtime.closeFeeds();
      runtime.dispose();
    });
    runtime.timelines['existing'] = [
      {
        'type': 'model/selection',
        'data': {'provider': 'existing', 'model': 'chosen'},
      },
    ];
    await model.watch();
    final signed = _view(
      signed: true,
      attempt: {'id': 'saved-attempt', 'phase': 'succeeded'},
    );
    runtime.publish(signed);
    // Join the automatically started request instead of relying on a timer.
    await model.initializeDefaultModel();
    runtime.publish(signed);
    expect(
      runtime.calls
          .where((item) => item['method'] == 'initializeDefaultModel')
          .single,
      {
        'rpc': 'api.call',
        'namespace': 'session',
        'method': 'initializeDefaultModel',
        'args': <String, dynamic>{},
      },
    );
    expect(
      runtime.calls.where((item) => item['rpc'] == 'settings.describe'),
      hasLength(1),
    );
    expect(runtime.provider, 'deepseek-account');
    expect(runtime.model, 'account-model');
    expect(runtime.timelines['existing']!.single['data'], {
      'provider': 'existing',
      'model': 'chosen',
    });
    expect(model.signedIn, isTrue);
    expect(model.error, isNull);
    expect(model.modelInitializationError, isNull);
    expect(model.modelInitializationNotice, contains('deepseek-account'));
  });

  test('stored login without an attempt needs explicit initialization and keeps the core chosen default', () async {
    final runtime = _Runtime()
      ..defaultSelection = {
        'provider': 'api-key-provider',
        'model': 'explicit',
      };
    final model = AccountState(runtime, _client);
    addTearDown(() async {
      model.dispose();
      await runtime.closeFeeds();
      runtime.dispose();
    });
    await model.watch();
    runtime.publish(_view(signed: true));
    expect(
      runtime.calls.where((item) => item['method'] == 'initializeDefaultModel'),
      isEmpty,
    );
    await model.initializeDefaultModel();
    expect(runtime.provider, 'api-key-provider');
    expect(runtime.model, 'explicit');
    expect(
      model.modelInitializationNotice,
      contains('api-key-provider / explicit'),
    );
    expect(
      runtime.calls.any(
        (item) =>
            item['rpc'] == 'settings.mutate' || item['method'] == 'selectModel',
      ),
      isFalse,
    );
  });

  test(
    'initialization failure stays separate from login and can be retried',
    () async {
      final runtime = _Runtime()..failInitialization = true;
      final model = AccountState(runtime, _client);
      addTearDown(() async {
        model.dispose();
        await runtime.closeFeeds();
        runtime.dispose();
      });
      await model.watch();
      runtime.publish(
        _view(signed: true, attempt: {'id': 'attempt-a', 'phase': 'succeeded'}),
      );
      await model.initializeDefaultModel();
      expect(model.signedIn, isTrue);
      expect(model.connected, isTrue);
      expect(model.error, isNull);
      expect(model.modelInitializationError, contains('登录已成功'));
      expect(model.modelInitializationError, isNot(contains('private')));
      await model.refreshDetails();
      expect(model.profile?['status'], 'ready');
      runtime.failInitialization = false;
      await model.initializeDefaultModel();
      expect(model.modelInitializationError, isNull);
      expect(runtime.provider, 'deepseek-account');
      expect(
        runtime.calls.where(
          (item) => item['method'] == 'initializeDefaultModel',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'a failed configuration refresh retries the read without reinitializing',
    () async {
      final runtime = _Runtime()..failForms = true;
      final model = AccountState(runtime, _client);
      addTearDown(() async {
        model.dispose();
        await runtime.closeFeeds();
        runtime.dispose();
      });
      await model.watch();
      runtime.publish(
        _view(signed: true, attempt: {'id': 'attempt-a', 'phase': 'succeeded'}),
      );
      await model.initializeDefaultModel();
      expect(model.modelInitializationError, contains('尚未同步'));
      runtime
        ..failForms = false
        ..defaultSelection = {'provider': 'later-choice', 'model': 'keep-this'};
      await model.initializeDefaultModel();
      expect(
        runtime.calls.where(
          (item) => item['method'] == 'initializeDefaultModel',
        ),
        hasLength(1),
      );
      expect(
        runtime.calls.where((item) => item['rpc'] == 'settings.describe'),
        hasLength(2),
      );
      expect(runtime.provider, 'later-choice');
      expect(model.modelInitializationError, isNull);
      expect(model.signedIn, isTrue);
    },
  );

  test('a pending initialization does not block sign-out snapshots or publish a late error', () async {
    final runtime = _Runtime()
      ..pendingInitialization = Completer<void>()
      ..failInitialization = true;
    final model = AccountState(runtime, _client);
    addTearDown(() async {
      model.dispose();
      await runtime.closeFeeds();
      runtime.dispose();
    });
    await model.watch();
    final signed = _view(
      signed: true,
      attempt: {'id': 'attempt-a', 'phase': 'succeeded'},
    );
    runtime.publish(signed);
    final finishing = model.initializeDefaultModel();
    runtime.publish(signed);
    expect(model.initializingModel, isTrue);
    expect(
      runtime.calls.where((item) => item['method'] == 'initializeDefaultModel'),
      hasLength(1),
    );
    runtime.publish(_view());
    expect(model.signedIn, isFalse);
    expect(model.initializingModel, isFalse);
    runtime.pendingInitialization!.complete();
    await finishing;
    expect(model.modelInitializationError, isNull);
    expect(model.error, isNull);
    expect(
      runtime.calls.where((item) => item['rpc'] == 'settings.describe'),
      isEmpty,
    );
  });

  testWidgets(
    'signed-in legacy accounts can initialize and retry without repeating login',
    (tester) async {
      final runtime = _Runtime()..failInitialization = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => '{"version":"0.1.0","build":7}',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AccountPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      runtime.publish(_view(signed: true));
      await tester.pumpAndSettle();
      expect(
        runtime.calls.where(
          (item) => item['method'] == 'initializeDefaultModel',
        ),
        isEmpty,
      );
      await tester.ensureVisible(find.text('初始化账号模型'));
      await tester.tap(find.text('初始化账号模型'));
      await tester.pumpAndSettle();
      expect(find.text('本机已保存登录凭据'), findsOneWidget);
      expect(find.text('登录 DeepSeek'), findsNothing);
      expect(find.textContaining('登录已成功，但默认模型初始化未完成'), findsOneWidget);
      runtime.failInitialization = false;
      await tester.ensureVisible(find.text('重试准备模型'));
      await tester.tap(find.text('重试准备模型'));
      await tester.pumpAndSettle();
      expect(find.text('重试准备模型'), findsNothing);
      expect(
        find.textContaining('当前默认模型：deepseek-account / account-model'),
        findsOneWidget,
      );
      expect(
        runtime.calls.where((item) => item['rpc'] == 'account.signIn'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(runtime.closeFeeds);
      runtime.dispose();
    },
  );

  test('late account details never repopulate a signed-out account', () async {
    final runtime = _Runtime()..deferProfile = true;
    final model = AccountState(runtime, _client);
    await model.watch();
    runtime.publish(_view(signed: true));
    expect(runtime.pendingProfiles, hasLength(1));
    runtime.publish(_view());
    runtime.pendingProfiles.single.complete({
      'status': 'ready',
      'value': {'name': 'old account'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(model.signedIn, isFalse);
    expect([model.profile, model.balance, model.bonuses], [null, null, null]);
    model.dispose();
    await runtime.closeFeeds();
    runtime.dispose();
  });

  test(
    'independent balance survives profile failure and preserves decimal text',
    () async {
      final runtime = _Runtime()..failProfile = true;
      final model = AccountState(runtime, _client);
      await model.watch();
      runtime.publish(_view(signed: true));
      await Future<void>.delayed(Duration.zero);
      expect(model.profile, isNull);
      expect(model.balance!['value'][0]['balance'], '0.0001');
      expect(model.detailsError, isNotNull);
      expect(model.detailsError, isNot(contains('private')));
      expect(runtime.calls.first['args'], {'client': _client});
      model.dispose();
      await runtime.closeFeeds();
      runtime.dispose();
    },
  );

  test('sign-in admission is not credential success and cancel uses original attempt id', () async {
    final runtime = _Runtime();
    final model = AccountState(runtime, _client);
    await model.watch();
    runtime.publish(_view());
    expect(await model.signIn(), isTrue);
    expect(model.signedIn, isFalse);
    expect(runtime.calls.single, {'rpc': 'account.signIn', 'client': _client});
    runtime.publish(
      _view(attempt: {'id': 'original-attempt', 'phase': 'waiting-browser'}),
    );
    await model.cancel();
    expect(runtime.calls.last['args'], {'attemptId': 'original-attempt'});
    expect(model.attempt!['phase'], 'waiting-browser');
    model.dispose();
    await runtime.closeFeeds();
    runtime.dispose();
  });

  test('bonus reads do not mark unseen notices and acknowledgements retain account identity', () async {
    final runtime = _Runtime();
    final model = AccountState(runtime, _client);
    await model.watch();
    runtime.publish(_view(signed: true));
    await Future<void>.delayed(Duration.zero);
    expect(
      runtime.calls.where((item) => item['method'] == 'ackBonusNotified'),
      isEmpty,
    );
    expect(await model.acknowledge('other-account', 'order-a'), isFalse);
    expect(await model.acknowledge('account-a', 'order-a'), isTrue);
    expect(await model.acknowledge('account-a', 'order-a'), isTrue);
    expect(
      runtime.calls
          .where((item) => item['method'] == 'ackBonusNotified')
          .single['args'],
      {'accountId': 'account-a', 'orderId': 'order-a', 'client': _client},
    );
    model.dispose();
    await runtime.closeFeeds();
    runtime.dispose();
  });

  testWidgets(
    'App opens only the current official authorization URL after explicit sign-in',
    (tester) async {
      final runtime = _Runtime();
      final opened = <Json>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          if (call.method == 'app.metadata') {
            return '{"version":"0.1.0","build":6}';
          }
          if (call.method == 'account.openPage') {
            opened.add(Json.from(call.arguments as Map));
            return null;
          }
          throw MissingPluginException();
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AccountPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      runtime.publish(_view());
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录 DeepSeek'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      runtime.publish(
        _view(
          attempt: {
            'id': 'attempt-a',
            'phase': 'waiting-browser',
            'authorizeUrl':
                'https://platform.deepseek.com/dsh/authorize?opaque=fixture',
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(opened.single['url'], contains('/dsh/authorize'));
      expect(find.text('本机已保存登录凭据'), findsNothing);
      expect(
        runtime.calls.any((item) => '${item['rpc']}'.startsWith('web.')),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(runtime.closeFeeds);
      runtime.dispose();
    },
  );

  testWidgets(
    'unknown sign-out impact is explicit and only confirmation revokes',
    (tester) async {
      final runtime = _Runtime()..failImpact = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => '{"version":"0.1.0","build":6}',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: AccountPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      runtime.publish(_view(signed: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法确认任务状态'), findsOneWidget);
      expect(
        runtime.calls.where((item) => item['method'] == 'signOut'),
        isEmpty,
      );
      await tester.tap(find.text('确认退出登录'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls.where((item) => item['method'] == 'signOut'),
        hasLength(1),
      );
      expect(find.text('本机已保存登录凭据'), findsOneWidget);
      runtime.publish(_view());
      await tester.pumpAndSettle();
      expect(find.text('尚未登录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(runtime.closeFeeds);
      runtime.dispose();
    },
  );
}
