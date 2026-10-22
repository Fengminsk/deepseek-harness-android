import 'dart:async';

import 'package:dsh_android/chat_feedback.dart';
import 'package:dsh_android/chat_feedback_widgets.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json item(String message, String version, {String rating = 'positive'}) => {
  'messageId': message,
  'version': version,
  'rating': rating,
  'createdAt': 1,
  'updatedAt': 2,
};
Json ok(dynamic value) => {'ok': true, 'value': value};

class FeedbackRuntime extends RuntimeController {
  FeedbackRuntime() {
    phase = 'ready';
  }
  int generation = 0;
  @override
  int get connectionGeneration => generation;
  final requests = <(String, Json)>[];
  Future<dynamic> Function(String, Json)? respond;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'api.call');
    expect(params['namespace'], 'messageFeedback');
    final name = params['method'] as String, args = params['args'] as Json;
    requests.add((name, args));
    return respond == null ? ok({'items': []}) : respond!(name, args);
  }

  void reconnect() {
    generation++;
    notifyListeners();
  }
}

Widget host(Widget child, {double scale = 1}) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: child,
  ),
);

void main() {
  test('one list seeds serialized puts, preserving Session and committed CAS versions', () async {
    final runtime = FeedbackRuntime();
    final first = Completer<dynamic>();
    var writes = 0;
    runtime.respond = (method, args) async {
      if (method == 'list') return first.future;
      return ok(item('answer', 'v${++writes}', rating: args['rating']));
    };
    final controller = ChatFeedbackController(
      runtime: runtime,
      sessionId: 'session-a',
    );
    final a = controller.rate(
      'answer',
      ChatFeedbackRating.positive,
      text: '  有帮助  ',
      category: 'task-result',
    );
    final b = controller.rate('answer', ChatFeedbackRating.negative);
    await Future<void>.delayed(Duration.zero);
    expect(runtime.requests.length, 1);
    first.complete(ok({'items': []}));
    expect((await a).ok, isTrue);
    expect((await b).ok, isTrue);
    expect(runtime.requests.map((r) => r.$1), ['list', 'put', 'put']);
    expect(runtime.requests[1].$2, {
      'sessionId': 'session-a',
      'messageId': 'answer',
      'rating': 'positive',
      'note': '有帮助',
      'category': 'task-result',
      'ifVersion': null,
    });
    expect(runtime.requests[2].$2, {
      'sessionId': 'session-a',
      'messageId': 'answer',
      'rating': 'negative',
      'ifVersion': 'v1',
    });
    controller.dispose();
    runtime.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('retraction only deletes matching rating and reconciles conflict without replay', () async {
    final runtime = FeedbackRuntime();
    runtime.respond = (method, args) async => method == 'list'
        ? ok({
            'items': [item('answer', 'old')],
          })
        : {
            'ok': false,
            'error': {
              'code': 'version-conflict',
              'current': item('answer', 'new', rating: 'negative'),
            },
          };
    final controller = ChatFeedbackController(runtime: runtime, sessionId: 's');
    expect(
      (await controller.retract('answer', ChatFeedbackRating.negative)).ok,
      isTrue,
    );
    expect(runtime.requests.length, 1);
    final result = await controller.retract(
      'answer',
      ChatFeedbackRating.positive,
    );
    expect(result.code, 'version-conflict');
    expect(controller.current('answer')?.version, 'new');
    expect(controller.current('answer')?.rating, ChatFeedbackRating.negative);
    expect(runtime.requests[1].$2['ifVersion'], 'old');
    expect(runtime.requests.length, 2);
    controller.dispose();
    runtime.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'connection replacement during seed cannot issue a queued mutation',
    () async {
      final runtime = FeedbackRuntime();
      final seed = Completer<dynamic>();
      var lists = 0;
      runtime.respond = (method, args) async {
        if (method == 'list' && lists++ == 0) return seed.future;
        return ok({
          'items': [item('answer', 'fresh')],
        });
      };
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      final put = controller.rate('answer', ChatFeedbackRating.negative);
      await Future<void>.delayed(Duration.zero);
      runtime.reconnect();
      seed.complete(
        ok({
          'items': [item('answer', 'stale')],
        }),
      );
      expect((await put).code, 'connection-changed');
      await Future<void>.delayed(Duration.zero);
      expect(runtime.requests.every((r) => r.$1 == 'list'), isTrue);
      expect(controller.current('answer')?.version, 'fresh');
      controller.dispose();
      expect(
        (await controller.rate('answer', ChatFeedbackRating.positive)).code,
        'disposed',
      );
      runtime.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'disposal during seed prevents a queued put and ignores late state',
    () async {
      final runtime = FeedbackRuntime();
      final seed = Completer<dynamic>();
      runtime.respond = (_, _) => seed.future;
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      final pending = controller.rate('answer', ChatFeedbackRating.positive);
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      seed.complete(
        ok({
          'items': [item('answer', 'late')],
        }),
      );
      expect((await pending).ok, isFalse);
      expect(runtime.requests.map((r) => r.$1), ['list']);
      expect(controller.items, isEmpty);
      runtime.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('uncertain write is not replayed and next explicit action reads current state', () async {
    final runtime = FeedbackRuntime();
    var lists = 0, puts = 0;
    runtime.respond = (method, args) async {
      if (method == 'list') {
        return ok({
          'items': lists++ == 0 ? [] : [item('answer', 'committed')],
        });
      }
      if (puts++ == 0) throw StateError('transport disconnected');
      return ok(item('answer', 'new', rating: args['rating']));
    };
    final controller = ChatFeedbackController(runtime: runtime, sessionId: 's');
    expect(
      (await controller.rate('answer', ChatFeedbackRating.positive)).ok,
      isFalse,
    );
    expect(runtime.requests.map((r) => r.$1), ['list', 'put']);
    expect(
      (await controller.rate('answer', ChatFeedbackRating.negative)).ok,
      isTrue,
    );
    expect(runtime.requests.map((r) => r.$1), ['list', 'put', 'list', 'put']);
    expect(runtime.requests.last.$2['ifVersion'], 'committed');
    controller.dispose();
    runtime.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets(
    'choosing either judgment opens a draft; dismiss records nothing',
    (tester) async {
      final runtime = FeedbackRuntime();
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      await tester.pumpWidget(
        host(
          Scaffold(
            body: ChatFeedbackActions(
              controller: controller,
              messageId: 'answer',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('好的回答'));
      await tester.pumpAndSettle();
      expect(find.text('提交反馈'), findsOneWidget);
      expect(runtime.requests.map((r) => r.$1), ['list']);
      await tester.tap(find.byTooltip('关闭反馈'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('有问题的回答'));
      await tester.pumpAndSettle();
      expect(find.text('提交反馈'), findsOneWidget);
      expect(runtime.requests.length, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'feedback page keeps note and category on conflict, then explicitly uses latest version',
    (tester) async {
      final runtime = FeedbackRuntime();
      var puts = 0;
      runtime.respond = (method, args) async {
        if (method == 'list') return ok({'items': []});
        if (puts++ == 0) {
          return {
            'ok': false,
            'error': {
              'code': 'version-conflict',
              'current': item('answer', 'web'),
            },
          };
        }
        return ok(item('answer', 'saved', rating: args['rating']));
      };
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      await tester.pumpWidget(
        host(
          ChatFeedbackPage(
            controller: controller,
            messageId: 'answer',
            rating: ChatFeedbackRating.negative,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('任务结果'));
      await tester.enterText(find.byType(TextField), '  请保留这段意见  ');
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已在别处改动'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '  请保留这段意见  ',
      );
      expect(controller.current('answer')?.version, 'web');
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(runtime.requests.last.$2['ifVersion'], 'web');
      expect(runtime.requests.last.$2['note'], '请保留这段意见');
      expect(runtime.requests.last.$2['category'], 'task-result');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'successful feedback closes only its own route under a newer page',
    (tester) async {
      final pending = Completer<dynamic>();
      final runtime = FeedbackRuntime()
        ..respond = ((method, args) async {
          if (method == 'list') return ok({'items': []});
          return await pending.future;
        });
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: pocketTheme(Brightness.dark),
          home: const Scaffold(body: Text('root')),
        ),
      );
      bool? pageResult;
      unawaited(
        navigator.currentState!
            .push<bool>(
              PocketRoute(
                builder: (_) => ChatFeedbackPage(
                  controller: controller,
                  messageId: 'answer',
                  rating: ChatFeedbackRating.positive,
                ),
              ),
            )
            .then((value) => pageResult = value),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交'));
      await tester.pump();
      expect(runtime.requests.map((request) => request.$1), ['list', 'put']);
      unawaited(
        navigator.currentState!.push<void>(
          PocketRoute(builder: (_) => const Scaffold(body: Text('newer'))),
        ),
      );
      await tester.pumpAndSettle();
      pending.complete(ok(item('answer', 'saved')));
      await tester.pumpAndSettle();
      expect(find.text('newer'), findsOneWidget);
      expect(pageResult, isTrue);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('root'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      runtime.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'narrow large text and keyboard keep submission reachable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = FeedbackRuntime();
      final controller = ChatFeedbackController(
        runtime: runtime,
        sessionId: 's',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              textScaler: TextScaler.linear(1.8),
              viewInsets: EdgeInsets.only(bottom: 300),
            ),
            child: ChatFeedbackPage(
              controller: controller,
              messageId: 'answer',
              rating: ChatFeedbackRating.positive,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('提交').hitTestable(), findsOneWidget);
      final button = tester.getRect(find.byTooltip('关闭反馈'));
      expect(button.width, button.height);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      runtime.dispose();
      await tester.pump();
    },
  );
}
