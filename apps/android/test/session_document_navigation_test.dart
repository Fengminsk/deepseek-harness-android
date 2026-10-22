import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_document.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _DocumentRuntime extends RuntimeController {
  _DocumentRuntime() {
    phase = 'ready';
  }
  int generation = 1;
  @override
  int get connectionGeneration => generation;
}

void main() {
  const codec = StandardMethodCodec();
  final created = <Map<dynamic, dynamic>>[];
  final disposed = <int>[];
  late _DocumentRuntime runtime;

  Future<dynamic> navigate(
    WidgetTester tester,
    int id,
    Map<String, dynamic> target,
  ) async {
    final response = Completer<ByteData?>();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'dsh/document-preview/$id',
      codec.encodeMethodCall(MethodCall('openDocument', target)),
      response.complete,
    );
    final bytes = await response.future;
    return bytes == null ? null : codec.decodeEnvelope(bytes);
  }

  Future<void> start(WidgetTester tester) async {
    runtime = _DocumentRuntime();
    addTearDown(runtime.dispose);
    created.clear();
    disposed.clear();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        final args = call.arguments as Map;
        if (call.method == 'create') {
          created.add(Map.of(args));
          return args['id'];
        }
        if (call.method == 'dispose') disposed.add(args['id'] as int);
        if (call.method == 'resize') {
          return {'width': args['width'], 'height': args['height']};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: SessionDocumentPage(
          runtime: runtime,
          sessionId: 'bound',
          path: 'guides/readme.md',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(created, hasLength(1));
  }

  testWidgets(
    'document toolbar sends the bound Session path to Android system open',
    (tester) async {
      await start(tester);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '在其他应用中打开',
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls.first.method, 'file.openSession');
      final arguments = calls.first.arguments as Map;
      expect(arguments['sessionId'], 'bound');
      expect(arguments['path'], 'guides/readme.md');
      expect(arguments['requestId'], isA<String>());
      expect(calls.last.method, 'file.launchPrepared');
      expect(calls.last.arguments, {'requestId': arguments['requestId']});
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'local links push the target title and line, then return to the retained reader',
    (tester) async {
      await start(tester);
      final first = created.single['id'] as int;
      final firstState = tester.state(find.byType(SessionDocumentPage));
      expect(
        await navigate(tester, first, {
          'sessionId': 'bound',
          'path': 'src/example one.txt',
          'line': 240,
        }),
        {'opened': true},
      );
      await tester.pumpAndSettle();
      expect(find.text('example one.txt'), findsOneWidget);
      expect(created, hasLength(2));
      final options = const StandardMessageCodec().decodeMessage(
        ByteData.sublistView(created.last['params'] as Uint8List),
      ) as Map;
      expect(options['sessionId'], 'bound');
      expect(options['path'], 'src/example one.txt');
      expect(options['line'], 240);
      expect(
        disposed,
        isNot(contains(first)),
        reason: 'back keeps the original renderer and its scroll state',
      );
      await expectLater(
        navigate(tester, first, {'sessionId': 'bound', 'path': 'stale.txt'}),
        throwsA(isA<PlatformException>()),
      );
      final childContext = tester.element(
        find.byType(SessionDocumentPage).last,
      );
      Navigator.of(childContext).pop();
      await tester.pumpAndSettle();
      expect(find.text('readme.md'), findsOneWidget);
      expect(tester.state(find.byType(SessionDocumentPage)), same(firstState));
      expect(
        created,
        hasLength(2),
        reason: 'return must not recreate source WebView',
      );
      expect(disposed, contains(created.last['id']));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'same-document line updates keep the view and refresh uses the latest line',
    (tester) async {
      await start(tester);
      final first = created.single['id'] as int;
      await navigate(tester, first, {
        'sessionId': 'bound',
        'path': 'guides/readme.md',
        'line': 27,
      });
      await tester.pumpAndSettle();
      expect(created, hasLength(1));
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '重新打开文档',
        ),
      );
      await tester.pumpAndSettle();
      expect(created, hasLength(2));
      final options = const StandardMessageCodec().decodeMessage(
        ByteData.sublistView(created.last['params'] as Uint8List),
      ) as Map;
      expect(options['line'], 27);
      expect(
        await navigate(tester, first, {
          'sessionId': 'bound',
          'path': 'stale.txt',
        }),
        isNull,
        reason: 'replaced platform view loses its navigation handler',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'cross-session, malformed and stale-generation navigation never pushes a reader',
    (tester) async {
      await start(tester);
      final first = created.single['id'] as int;
      for (final target in [
        {'sessionId': 'other', 'path': 'secret.txt'},
        {'sessionId': 'bound', 'path': ''},
        {'sessionId': 'bound', 'path': 'a\u0000b'},
        {'sessionId': 'bound', 'path': 'source.ts', 'line': 0},
        {'sessionId': 'bound', 'path': 'source.ts', 'line': 1.5},
      ]) {
        await expectLater(
          navigate(tester, first, target),
          throwsA(isA<PlatformException>()),
        );
      }
      runtime.generation++;
      await expectLater(
        navigate(tester, first, {'sessionId': 'bound', 'path': 'stale.txt'}),
        throwsA(isA<PlatformException>()),
      );
      expect(created, hasLength(1));
      expect(find.text('readme.md'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
