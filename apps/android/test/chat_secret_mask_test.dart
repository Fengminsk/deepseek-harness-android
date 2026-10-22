import 'dart:async';

import 'package:dsh_android/chat_secret_mask.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class MaskRuntime extends RuntimeController {
  MaskRuntime() {
    phase = 'ready';
  }
  int generation = 0;
  @override
  int get connectionGeneration => generation;
  final texts = <String>[];
  Future<dynamic> Function(String)? respond;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'userText.mask');
    final text = params['text'] as String;
    texts.add(text);
    return respond == null ? {'ranges': []} : respond!(text);
  }

  void reconnect() {
    generation++;
    notifyListeners();
  }
}

Widget host(Widget child) => MaterialApp(
  theme: pocketTheme(Brightness.dark),
  home: Scaffold(body: child),
);

void main() {
  test('UTF16 ranges remain on original text, independently of shorter code-point masks', () {
    final raw = '😀 redis://u:p😀x@host';
    final start = raw.indexOf('p😀x');
    final ranges = ChatSecretRange.parse({
      'ranges': [
        {'start': start, 'end': start + 4, 'masked': '***'},
      ],
    }, raw);
    expect(raw.substring(ranges.single.start, ranges.single.end), 'p😀x');
    expect(ranges.single.masked.length, 3);
    expect(
      () => ChatSecretRange.parse({
        'ranges': [
          {'start': start, 'end': start + 4, 'masked': '***'},
          {'start': start + 2, 'end': start + 5, 'masked': '***'},
        ],
      }, raw),
      throwsFormatException,
    );
    expect(
      () => ChatSecretRange.parse({
        'ranges': [
          {'start': -1, 'end': 3, 'masked': '*'},
        ],
      }, raw),
      throwsFormatException,
    );
  });

  test('same text read coalesces and reconnect discards late ranges', () async {
    final runtime = MaskRuntime();
    final first = Completer<dynamic>();
    var reads = 0;
    runtime.respond = (_) async => reads++ == 0 ? first.future : {'ranges': []};
    final controller = ChatSecretMaskController(
      runtime: runtime,
      text: 'plain',
    );
    final a = controller.load(), b = controller.load();
    expect(identical(a, b), isTrue);
    runtime.reconnect();
    await Future<void>.delayed(Duration.zero);
    first.complete({
      'ranges': [
        {'start': 0, 'end': 5, 'masked': '*****'},
      ],
    });
    await a;
    expect(controller.phase, ChatSecretMaskPhase.ready);
    expect(controller.ranges, isEmpty);
    controller.dispose();
    runtime.dispose();
  });

  test(
    'oversized text and failed matching do not report unmasked success',
    () async {
      final runtime = MaskRuntime();
      final oversized = ChatSecretMaskController(
        runtime: runtime,
        text: List.filled(180000, '中').join(),
      );
      await oversized.load();
      expect(oversized.phase, ChatSecretMaskPhase.unavailable);
      expect(runtime.texts, isEmpty);
      final failure = ChatSecretMaskController(
        runtime: runtime,
        text: 'secret',
      );
      runtime.respond = (_) async => throw StateError('no scan');
      await failure.load();
      expect(failure.phase, ChatSecretMaskPhase.unavailable);
      oversized.dispose();
      failure.dispose();
      runtime.dispose();
    },
  );

  testWidgets(
    'pending or failed display never builds raw text and retry is explicit',
    (tester) async {
      final runtime = MaskRuntime();
      final pending = Completer<dynamic>();
      runtime.respond = (_) => pending.future;
      const text = 'raw sample that must not appear while scan is pending';
      await tester.pumpWidget(
        host(
          ChatSecretMask(
            runtime: runtime,
            text: text,
            builder: (_, ranges) => Text(text),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(text), findsNothing);
      pending.completeError(StateError('scanner unavailable'));
      await tester.pumpAndSettle();
      expect(find.text(text), findsNothing);
      expect(find.byTooltip('重新生成消息遮罩'), findsOneWidget);
      runtime.respond = (_) async => {'ranges': []};
      await tester.tap(find.byTooltip('重新生成消息遮罩'));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      runtime.dispose();
    },
  );

  testWidgets(
    'per-value reveal remasks replacement text and noninteractive preview',
    (tester) async {
      const raw = 'sample-original', mask = 'sample-********';
      Widget content(String value, {bool interactive = true}) => host(
        ChatSecretValue(
          key: const ValueKey('same-position'),
          raw: value,
          masked: mask,
          interactive: interactive,
        ),
      );
      await tester.pumpWidget(content(raw));
      await tester.pumpAndSettle();
      expect(find.textContaining(raw, findRichText: true), findsNothing);
      await tester.tap(find.byTooltip('显示凭据'));
      await tester.pumpAndSettle();
      expect(find.textContaining(raw, findRichText: true), findsOneWidget);
      final button = tester.getRect(find.byTooltip('隐藏凭据'));
      expect(button.width, button.height);
      await tester.pumpWidget(content('different-original'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('different-original', findRichText: true),
        findsNothing,
      );
      await tester.pumpWidget(
        content('different-original', interactive: false),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GlassButton), findsNothing);
      expect(find.textContaining(mask, findRichText: true), findsOneWidget);
    },
  );
}
