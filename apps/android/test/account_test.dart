import 'dart:async';

import 'package:dsh_android/account.dart';
import 'package:dsh_android/account_state.dart';
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
  bool deferProfile = false, failProfile = false, failImpact = false;
  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    expect([namespace, method], ['account', 'watch']);
    final feed = StreamController<Json>(sync: true, onCancel: () async {});
    feeds.add(feed);
    return feed.stream;
  }

  void publish(Json view) => feeds.last.add({'type': 'item', 'value': view});

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add({'rpc': method, ...params});
    if (method == 'account.signIn') {
      return _view(attempt: {'id': 'attempt-a', 'phase': 'initializing'});
    }
    if (method != 'api.call' || params['namespace'] != 'account') {
      throw StateError('Unexpected RPC');
    }
    switch (params['method']) {
      case 'getProfile':
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
  TestWidgetsFlutterBinding.ensureInitialized();
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
