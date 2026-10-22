import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/image_preview.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

class _Runtime extends RuntimeController {
  final calls = <(String, Json)>[];
  Future<dynamic> Function(String, Json)? response;
  int generation = 0;

  @override
  int get connectionGeneration => generation;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Json.from(params)));
    if (response != null) return response!(method, params);
    return {
      'sessionId': params['sessionId'],
      'path': params['path'],
      'mediaType': 'image/png',
      'bytes': base64Decode(png).length,
      'data': png,
    };
  }
}

Widget app(Widget body) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: PocketScaffold(title: const Text('会话'), body: body),
);

Future<void> settleImage(WidgetTester tester) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (find.byType(Image).evaluate().isEmpty &&
        find.text('图片暂时无法预览').evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Inline image did not settle');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'workspace image request binds original Session and exact authored path',
    () async {
      final runtime = _Runtime();
      final source = PocketImageSource.workspaceFile(
        runtime,
        'viewed',
        '../chart.png',
      );
      final loaded = await source.load();
      expect(loaded.bytes, base64Decode(png));
      expect(runtime.calls.single.$1, 'chat.image.preview');
      expect(runtime.calls.single.$2['sessionId'], 'viewed');
      expect(runtime.calls.single.$2['path'], '../chart.png');
    },
  );

  test(
    'wrong Session response and lost runtime generation never publish image',
    () async {
      final runtime = _Runtime()
        ..response = (_, _) async => {
          'sessionId': 'other',
          'path': 'chart.png',
          'mediaType': 'image/png',
          'bytes': base64Decode(png).length,
          'data': png,
        };
      await expectLater(
        PocketImageSource.workspaceFile(runtime, 'viewed', 'chart.png').load(),
        throwsFormatException,
      );
      final barrier = Completer<Json>();
      runtime.response = (_, _) => barrier.future;
      final old = PocketImageSource.workspaceFile(
        runtime,
        'viewed',
        'chart.png',
      ).load();
      runtime.generation++;
      barrier.complete({
        'sessionId': 'viewed',
        'path': 'chart.png',
        'mediaType': 'image/png',
        'bytes': base64Decode(png).length,
        'data': png,
      });
      await expectLater(old, throwsStateError);
    },
  );

  testWidgets(
    'settled Markdown image shows bounded local preview and opens viewer',
    (tester) async {
      final runtime = _Runtime();
      Widget view() => app(
        PocketMarkdown(
          data: '![图表](../chart.png)',
          runtime: runtime,
          sessionId: 'viewed',
          onOpenFile: (_) async {},
        ),
      );
      await tester.pumpWidget(view());
      await settleImage(tester);
      expect(find.byType(PocketInlineImage), findsOneWidget);
      expect(runtime.calls.single.$1, 'chat.image.preview');
      expect(runtime.calls.single.$2['sessionId'], 'viewed');
      expect(runtime.calls.single.$2['path'], '../chart.png');
      await tester.pumpWidget(view());
      await tester.pump();
      expect(
        runtime.calls.length,
        1,
        reason: 'stable source does not refetch on unrelated rebuild',
      );
      await tester.tap(find.byType(PocketInlineImage));
      await tester.pumpAndSettle();
      expect(find.byType(PocketImagePreview), findsOneWidget);
    },
  );

  testWidgets('failed preview offers retry and original file route', (
    tester,
  ) async {
    final runtime = _Runtime()
      ..response = (_, _) async => throw StateError('unavailable');
    final files = <ChatFileLink>[];
    await tester.pumpWidget(
      app(
        PocketMarkdown(
          data: '![图表](chart.png)',
          runtime: runtime,
          sessionId: 'viewed',
          onOpenFile: (file) async => files.add(file),
        ),
      ),
    );
    await settleImage(tester);
    expect(find.text('图片暂时无法预览'), findsOneWidget);
    await tester.tap(find.byTooltip('打开原文件'));
    await tester.pump();
    expect(files.single.path, 'chart.png');
    runtime.response = null;
    await tester.tap(find.text('chart.png'));
    await tester.pump();
    await settleImage(tester);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets(
    'HTTP image remains explicit external link with no silent file read',
    (tester) async {
      final runtime = _Runtime();
      final links = <Uri>[];
      await tester.pumpWidget(
        app(
          PocketMarkdown(
            data: '![在线图](https://example.org/image.png)',
            runtime: runtime,
            sessionId: 'viewed',
            onOpenLink: (uri) async => links.add(uri),
          ),
        ),
      );
      expect(find.byType(PocketInlineImage), findsNothing);
      expect(runtime.calls, isEmpty);
      await tester.tap(find.text('在线图'));
      await tester.pump();
      expect(links.single.toString(), 'https://example.org/image.png');
    },
  );
}
