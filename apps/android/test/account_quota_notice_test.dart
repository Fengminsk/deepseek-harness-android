import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/account_quota_notice.dart';
import 'package:dsh_android/account_state.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  late final AccountState account = AccountState(this, const {});

  @override
  AccountState? get accountSnapshot => account;

  void signedIn() {
    account.connected = true;
    account.view = {
      'status': 'credential-stored',
      'links': {'topUpUrl': 'https://platform.deepseek.com/top_up?source=app'},
    };
    notifyListeners();
  }

  void signedOut() {
    account.connected = true;
    account.view = {'status': 'signed-out'};
    notifyListeners();
  }

  void malformedTopUp() {
    account.view = {
      'status': 'credential-stored',
      'links': {'topUpUrl': 42},
    };
    notifyListeners();
  }

  @override
  void dispose() {
    account.dispose();
    super.dispose();
  }
}

Json _event(int seq, String code) => {
  'sessionId': 'owner-session',
  'event': {
    'seq': seq,
    'type': 'turn/end',
    'data': {
      'reason': {
        'kind': 'error',
        'error': {'code': code},
      },
    },
  },
};

void main() {
  test('invalid top-up URL is rejected before invoking Android', () async {
    await expectLater(
      openAccountQuotaTopUp(
        'http://platform.deepseek.com/top_up',
        Brightness.dark,
      ),
      throwsFormatException,
    );
    await expectLater(
      openAccountQuotaTopUp(
        'https://user@platform.deepseek.com/top_up',
        Brightness.dark,
      ),
      throwsFormatException,
    );
  });

  test(
    'keyless original turn-end oracle publishes only live quota failures',
    () async {
      final rows = (jsonDecode(
        File('test/fixtures/quota_notice_live_session.json').readAsStringSync(),
      ) as List).cast<Json>();
      final events = StreamController<Json>.broadcast(sync: true);
      final controller = AccountQuotaNoticeController(events.stream);
      addTearDown(() async {
        controller.dispose();
        await events.close();
      });

      events.add(rows[0]);
      events.add(rows[1]);
      expect(controller.current, isNull);
      events.add(rows[2]);
      expect(controller.current?.sessionId, 'owner-session');
      expect(controller.current?.sequence, 12);
      expect(controller.current?.code, 'ACCOUNT_QUOTA');
      events.add(rows[3]);
      expect(
        controller.current?.sequence,
        12,
        reason: 'An open notice is not replaced',
      );
      controller.dismiss();
      events.add(rows[3]);
      expect(controller.current?.code, 'QUOTA');
      controller.dismiss();
      events.add(_event(14, 'NOT_QUOTA'));
      expect(controller.current, isNull);
    },
  );

  testWidgets(
    'signed-in quota notice opens only the official URL and closes after receipt',
    (tester) async {
      final runtime = _Runtime()..signedIn();
      final events = StreamController<Json>.broadcast(sync: true);
      final controller = AccountQuotaNoticeController(events.stream);
      addTearDown(() async {
        controller.dispose();
        runtime.dispose();
        await events.close();
      });
      final opened = <(String, Brightness)>[];
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: pocketTheme(Brightness.dark),
          builder: (context, child) => AccountQuotaNoticeHost(
            runtime: runtime,
            notices: controller,
            openTopUp: (url, brightness) async {
              opened.add((url, brightness));
            },
            child: child!,
          ),
          home: const Scaffold(body: Text('Underlying conversation')),
        ),
      );
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Secondary page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      events.add(_event(12, 'ACCOUNT_QUOTA'));
      await tester.pump();
      expect(find.text('Secondary page'), findsOneWidget);
      expect(find.text('当前无可用额度'), findsOneWidget);
      expect(find.text('去充值'), findsOneWidget);
      await tester.tap(find.text('去充值'));
      await tester.pump();
      expect(opened, [
        ('https://platform.deepseek.com/top_up?source=app', Brightness.dark),
      ]);
      expect(controller.current, isNull);
    },
  );

  testWidgets(
    'failed opener keeps notice for retry and sign-out withdraws the action',
    (tester) async {
      final runtime = _Runtime()..signedIn();
      final events = StreamController<Json>.broadcast(sync: true);
      final controller = AccountQuotaNoticeController(events.stream);
      addTearDown(() async {
        controller.dispose();
        runtime.dispose();
        await events.close();
      });
      var attempts = 0;
      var accountOpened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountQuotaNoticeHost(
            runtime: runtime,
            notices: controller,
            openTopUp: (url, brightness) async {
              attempts++;
              throw StateError('private native failure');
            },
            openAccount: () => accountOpened++,
            child: const Scaffold(body: Text('Conversation')),
          ),
        ),
      );
      events.add(_event(17, 'ACCOUNT_QUOTA'));
      await tester.pump();
      await tester.tap(find.text('去充值'));
      await tester.pump();
      expect(attempts, 1);
      expect(controller.current, isNotNull);
      expect(find.byKey(const Key('quota-open-error')), findsOneWidget);
      expect(find.textContaining('private native failure'), findsNothing);
      runtime.malformedTopUp();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('去充值'), findsNothing);
      expect(find.text('账号与余额'), findsOneWidget);
      runtime.signedOut();
      await tester.pump();
      expect(find.text('去充值'), findsNothing);
      expect(find.text('账号与余额'), findsOneWidget);
      await tester.tap(find.text('账号与余额'));
      await tester.pump();
      expect(accountOpened, 1);
      expect(controller.current, isNull);
    },
  );

  testWidgets('quota actions remain reachable on a narrow enlarged screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final runtime = _Runtime()..signedOut();
    final events = StreamController<Json>.broadcast(sync: true);
    final controller = AccountQuotaNoticeController(events.stream);
    addTearDown(() async {
      controller.dispose();
      runtime.dispose();
      await events.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: AccountQuotaNoticeHost(
            runtime: runtime,
            notices: controller,
            openAccount: () {},
            child: child!,
          ),
        ),
        home: const Scaffold(body: Text('Conversation')),
      ),
    );
    events.add(_event(18, 'ACCOUNT_QUOTA'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('账号与余额'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('稍后处理'), findsOneWidget);
    expect(find.text('账号与余额'), findsOneWidget);
  });

  testWidgets('generic quota is a short toast without an account action', (
    tester,
  ) async {
    final runtime = _Runtime()..signedIn();
    final events = StreamController<Json>.broadcast(sync: true);
    final controller = AccountQuotaNoticeController(events.stream);
    addTearDown(() async {
      controller.dispose();
      runtime.dispose();
      await events.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AccountQuotaNoticeHost(
          runtime: runtime,
          notices: controller,
          child: const Scaffold(body: Text('Conversation')),
        ),
      ),
    );
    events.add(_event(19, 'QUOTA'));
    await tester.pump();
    expect(find.text('当前模型额度不足'), findsOneWidget);
    expect(find.text('去充值'), findsNothing);
    expect(find.text('Conversation'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.current, isNull);
  });
}
