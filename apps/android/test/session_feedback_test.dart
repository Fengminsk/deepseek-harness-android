import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_feedback.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }

  final requests = <Json>[];
  Future<dynamic> Function(Json args)? respond;
  Future<Json> Function(String id)? ensure;
  int generation = 0;

  @override
  int get connectionGeneration => generation;

  @override
  Future<Json> ensureSession(String id) =>
      ensure?.call(id) ?? Future.value({'sessionId': id, 'created': false});

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'api.call');
    expect(params['namespace'], 'sessionFeedback');
    expect(params['method'], 'record');
    final args = params['args'] as Json;
    requests.add(args);
    return respond?.call(args) ??
        {
          'ok': true,
          'value': {'recorded': true},
        };
  }
}

Widget _host(Widget home) =>
    MaterialApp(theme: pocketTheme(Brightness.dark), home: home);

void main() {
  test(
    'session remark uses the original remote and omits absent fields',
    () async {
      final runtime = _Runtime();
      final blank = await recordSessionFeedback(
        runtime,
        'session-a',
        text: '   ',
      );
      expect(blank.recorded, isTrue);
      expect(runtime.requests.single, {'sessionId': 'session-a'});
      final detailed = await recordSessionFeedback(
        runtime,
        'session-a',
        text: '  任务中断  ',
        category: 'service-stability',
      );
      expect(detailed.recorded, isTrue);
      expect(runtime.requests.last, {
        'sessionId': 'session-a',
        'text': '任务中断',
        'category': 'service-stability',
      });
      runtime.dispose();
    },
  );

  test(
    'no write occurs if the Session cannot be opened or connection changed',
    () async {
      final runtime = _Runtime();
      runtime.ensure = (_) => Future.error(StateError('unavailable'));
      expect(
        (await recordSessionFeedback(runtime, 's', text: 'keep')).recorded,
        isFalse,
      );
      expect(runtime.requests, isEmpty);
      final opening = Completer<Json>();
      runtime.ensure = (_) => opening.future;
      final pending = recordSessionFeedback(runtime, 's', text: 'keep');
      runtime.generation++;
      opening.complete({'sessionId': 's'});
      expect((await pending).recorded, isFalse);
      expect(runtime.requests, isEmpty);
      runtime.dispose();
    },
  );

  test(
    'an unacknowledged write remains uncertain and is not retried',
    () async {
      final runtime = _Runtime();
      runtime.respond = (_) => Future.error(StateError('link lost'));
      final outcome = await recordSessionFeedback(runtime, 's', text: 'report');
      expect(outcome.uncertain, isTrue);
      expect(runtime.requests, hasLength(1));
      runtime.dispose();
    },
  );

  testWidgets(
    'bare feedback opens an editable form and submits one log remark',
    (tester) async {
      final runtime = _Runtime();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: pocketTheme(Brightness.dark),
          home: const Scaffold(body: Text('chat')),
        ),
      );
      bool? result;
      unawaited(
        navigator.currentState!
            .push<bool>(
              PocketRoute(
                builder: (_) => SessionFeedbackPage(
                  runtime: runtime,
                  sessionId: 'session-a',
                ),
              ),
            )
            .then((value) => result = value),
      );
      await tester.pumpAndSettle();
      expect(runtime.requests, isEmpty);
      await tester.tap(find.text('稳定性和速度'));
      await tester.enterText(find.byType(TextField), '  后台任务停止了  ');
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(runtime.requests.single, {
        'sessionId': 'session-a',
        'text': '后台任务停止了',
        'category': 'service-stability',
      });
      expect(result, isTrue);
      expect(find.text('chat'), findsOneWidget);
      runtime.dispose();
    },
  );

  testWidgets('uncertain submission retains draft and blocks duplicate tap', (
    tester,
  ) async {
    final runtime = _Runtime()
      ..respond = (_) => Future.error(StateError('lost acknowledgement'));
    await tester.pumpWidget(
      _host(SessionFeedbackPage(runtime: runtime, sessionId: 'session-a')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  原文保留  ');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.textContaining('提交结果未确认'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '  原文保留  ',
    );
    expect(runtime.requests, hasLength(1));
    expect(
      tester.widget<PocketButton>(find.byType(PocketButton)).onPressed,
      isNull,
    );
    runtime.dispose();
  });

  testWidgets('known rejection retains draft and allows explicit retry', (
    tester,
  ) async {
    final runtime = _Runtime();
    var attempts = 0;
    runtime.respond = (_) async => attempts++ == 0
        ? {
            'ok': false,
            'error': {'code': 'session-not-found', 'sessionId': 'session-a'},
          }
        : {
            'ok': true,
            'value': {'recorded': true},
          };
    await tester.pumpWidget(
      _host(SessionFeedbackPage(runtime: runtime, sessionId: 'session-a')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已不可用'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留',
    );
    expect(runtime.requests, hasLength(1));
    expect(
      tester.widget<PocketButton>(find.byType(PocketButton)).onPressed,
      isNotNull,
    );
    runtime.dispose();
  });
}
