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
final bytes = base64Decode(png);
Json reference([String id = 'durable-image']) => {
  'attachmentId': id,
  'mediaType': 'image/png',
  'bytes': bytes.length,
  'width': 1,
  'height': 1,
  'name': 'picture.png',
};
Json reply() => {'attachment': reference(), 'data': png};
PocketImagePayload payload() => PocketImagePayload(
  bytes: bytes,
  mediaType: 'image/png',
  name: 'picture.png',
);

class _Runtime extends RuntimeController {
  final calls = <({String method, Json params})>[];
  Future<dynamic> Function()? respond;
  int generation = 0;
  @override
  int get connectionGeneration => generation;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: Json.from(params)));
    return respond == null ? reply() : await respond!();
  }
}

Widget app(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: child,
);

Future<void> settleImage(WidgetTester tester) async {
  await tester.pump();
  // Engine header decoding is outside the fake clock; wait for its observable
  // widget state, with a bounded deadline rather than a fixed settling sleep.
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null) &&
        find.text('图片未能打开').evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Image preview did not settle');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('history loader uses original session-authorized attachment endpoint exclusively', () async {
    final runtime = _Runtime();
    final value = await PocketImageSource.session(runtime, 'chat-one', {
      ...reference(),
      'path': '/private/arbitrary.png',
      'url': 'file:///private/arbitrary.png',
    }).load();
    expect(value.bytes, bytes);
    expect(runtime.calls.single.method, 'api.call');
    expect(runtime.calls.single.params, {
      'namespace': 'session',
      'method': 'attachment',
      'args': {
        'request': {'sessionId': 'chat-one', 'attachmentId': 'durable-image'},
      },
    });
  });

  test(
    'missing reference never falls back to a path or attachment draft',
    () async {
      final runtime = _Runtime();
      await expectLater(
        PocketImageSource.session(runtime, 'chat-one', {
          'id': 'draft',
          'path': '/tmp/p.png',
        }).load(),
        throwsFormatException,
      );
      expect(runtime.calls, isEmpty);
    },
  );

  test('history reply cannot substitute another image', () async {
    final runtime = _Runtime()
      ..respond = () async => {'attachment': reference('another'), 'data': png};
    await expectLater(
      PocketImageSource.session(runtime, 'chat-one', reference()).load(),
      throwsFormatException,
    );
  });

  test('draft preview stays scoped to its conversation and ID', () async {
    final runtime = _Runtime()
      ..respond = () async => {
        'id': 'selected',
        'kind': 'image',
        'name': 'selected.png',
        'mediaType': 'image/png',
        'bytes': bytes.length,
        'data': png,
      };
    final value = await PocketImageSource.draft(
      runtime,
      'chat-one',
      'selected',
      'selected.png',
    ).load();
    expect(value.bytes, bytes);
    expect(runtime.calls.single.method, 'attachments.preview');
    expect(runtime.calls.single.params, {
      'sessionId': 'chat-one',
      'id': 'selected',
    });
  });

  test(
    'preview rejects a response from a previous runtime generation',
    () async {
      final barrier = Completer<Json>();
      final runtime = _Runtime()..respond = () => barrier.future;
      final loading = PocketImageSource.session(
        runtime,
        'chat-one',
        reference(),
      ).load();
      runtime.generation++;
      barrier.complete(reply());
      await expectLater(loading, throwsStateError);
    },
  );

  for (final invalid in <Json>[
    {'bytes': pocketPreviewMaxBytes + 1},
    {'bytes': 0},
    {'bytes': 1.5},
    {'mediaType': 'image/svg+xml'},
    {'width': 8193},
    {'height': 0},
    {'width': 8192, 'height': 8192},
  ]) {
    test(
      'preview refuses invalid or oversized metadata before decode: $invalid',
      () async {
        final runtime = _Runtime()
          ..respond = () async => {
            'attachment': {...reference(), ...invalid},
            'data': png,
          };
        await expectLater(
          PocketImageSource.session(runtime, 'chat-one', reference()).load(),
          throwsFormatException,
        );
      },
    );
  }

  for (final invalid in [
    png.substring(1),
    'file:///private/p.png',
    'data:image/png;base64,$png',
  ]) {
    test('preview rejects malformed encoded data: $invalid', () async {
      final runtime = _Runtime()
        ..respond = () async => {'attachment': reference(), 'data': invalid};
      await expectLater(
        PocketImageSource.session(runtime, 'chat-one', reference()).load(),
        throwsFormatException,
      );
    });
  }

  testWidgets(
    'loading preview can close immediately and ignores a late response',
    (tester) async {
      final waiting = Completer<PocketImagePayload>();
      final source = PocketImageSource(
        name: 'waiting.png',
        load: () => waiting.future,
      );
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => PocketButton(
              onPressed: () => Navigator.of(context).push<void>(
                PocketRoute<void>(
                  builder: (_) => PocketImagePreview(source: source),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('正在加载图片…'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭图片'));
      await tester.pumpAndSettle();
      waiting.complete(payload());
      await tester.pumpAndSettle();
      expect(find.byType(PocketImagePreview), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failure offers retry and then displays a real zoomable raster', (
    tester,
  ) async {
    var requests = 0;
    final source = PocketImageSource(
      name: 'picture.png',
      load: () async {
        if (++requests == 1) throw StateError('fixture unavailable');
        return payload();
      },
    );
    await tester.pumpWidget(app(PocketImagePreview(source: source)));
    await tester.pumpAndSettle();
    expect(find.text('图片未能打开'), findsOneWidget);
    expect(find.byTooltip('关闭图片'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await settleImage(tester);
    expect(requests, 2);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('图片未能打开'), findsNothing);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null),
      isTrue,
    );
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final gesture = tester.widget<GestureDetector>(
      find
          .ancestor(
            of: find.byType(InteractiveViewer),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    gesture.onDoubleTap!();
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 2.5);
    await tester.tap(find.byTooltip('还原图片大小'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source replacement ignores an older loading result', (
    tester,
  ) async {
    final old = Completer<PocketImagePayload>();
    await tester.pumpWidget(
      app(
        PocketImagePreview(
          source: PocketImageSource(name: 'old', load: () => old.future),
        ),
      ),
    );
    await tester.pumpWidget(
      app(
        PocketImagePreview(
          source: PocketImageSource(
            name: 'new',
            load: () async => throw const FormatException('new source failed'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    old.complete(payload());
    await tester.pumpAndSettle();
    expect(find.text('new source failed'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'corrupt bytes produce a retryable error instead of an empty canvas',
    (tester) async {
      await tester.pumpWidget(
        app(
          PocketImagePreview(
            source: PocketImageSource(
              name: 'broken.png',
              load: () async => PocketImagePayload(
                bytes: base64Decode('aW52YWxpZA=='),
                mediaType: 'image/png',
                name: 'broken.png',
              ),
            ),
          ),
        ),
      );
      await settleImage(tester);
      expect(find.text('图片未能打开'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'intrinsic dimensions must match the authorized reference before pixel decode',
    (tester) async {
      await tester.pumpWidget(
        app(
          PocketImagePreview(
            source: PocketImageSource(
              name: 'mismatch.png',
              load: () async => PocketImagePayload(
                bytes: bytes,
                mediaType: 'image/png',
                name: 'mismatch.png',
                width: 2,
                height: 1,
              ),
            ),
          ),
        ),
      );
      await settleImage(tester);
      expect(find.text('图片实际尺寸与附件信息不匹配。'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image-only callback does not enable an unsupported file action',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: ChatContent(
              content: [
                {'type': 'image', 'attachment': reference()},
                {
                  'type': 'file',
                  'attachment': {
                    'attachmentId': 'plain',
                    'name': 'plain.txt',
                    'bytes': 1,
                  },
                },
              ],
              storageId: 'mixed',
              onOpenImage: (_) async {
                opened++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看附件'), findsOneWidget);
      expect(find.text('附件已随会话保存'), findsOneWidget);
      await tester.tap(find.text('picture.png'));
      await tester.pump();
      await tester.tap(find.text('plain.txt'));
      await tester.pump();
      expect(opened, 1);
    },
  );
}
