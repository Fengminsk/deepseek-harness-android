import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/flclash/daylight.dart';
import 'package:dsh_android/appearance.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/read_only_presets.dart';

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  bool glass = true,
  bool capture = true,
  bool black = false,
  bool reduceMotion = true,
  double scale = 1,
  String? font,
}) {
  var theme = pocketTheme(brightness, pureBlack: black);
  if (font != null) {
    theme = theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: font));
  }
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(scale),
        padding: const EdgeInsets.only(top: 24, bottom: 20),
      ),
      child: child!,
    ),
    home: LiquidGlassScope(
      enabled: glass,
      quality: LiquidGlassQuality.standard,
      child: LiquidGlassHost(enabled: glass && capture, child: child),
    ),
  );
}

void _phone(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<List<int>> _pixels(
  WidgetTester tester,
  GlobalKey key,
) async => (await tester.runAsync(() async {
  final image =
      await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
          .toImage();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return data.buffer.asUint8List().toList();
  } finally {
    image.dispose();
  }
}))!;

Color _pixel(List<int> pixels, int x, int y, {int width = 390}) {
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    pixels[offset + 3],
    pixels[offset],
    pixels[offset + 1],
    pixels[offset + 2],
  );
}

class _PreviewRuntime extends RuntimeController {
  _PreviewRuntime() {
    phase = 'ready';
    info = {'workspace': '/private/workspace'};
  }
  final presets = ReadOnlyPresets();
  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    if (presets.observes(namespace, method)) {
      return presets.watch(args: args, resumeArgs: resumeArgs);
    }
    throw StateError('Unexpected observation: $namespace.$method');
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (presets.handles(method, params)) return presets.reply(params);
    throw StateError('Unavailable in visual fixture: $method');
  }

  @override
  String newSession() => 'daylight-preview';
  @override
  void dispose() {
    presets.dispose();
    super.dispose();
  }
}

Widget _components() => PocketScaffold(
  title: const Text('外观与主题'),
  body: PocketList(
    children: [
      PocketSection(
        title: '显示',
        children: [
          PocketRow(
            icon: Icons.contrast_rounded,
            title: '显示模式',
            trailing: const Text('跟随系统'),
            onTap: () {},
          ),
          PocketSwitchRow(
            title: const Text('液态玻璃'),
            value: true,
            onChanged: (_) {},
          ),
          PocketRow(
            icon: Icons.palette_outlined,
            title: '主题配色',
            trailing: const Icon(Icons.circle, color: Color(0xff556f63)),
            onTap: () {},
          ),
        ],
      ),
    ],
  ),
  bottom: GlassSurface(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          GlassButton(icon: Icons.add_rounded, label: '添加', onPressed: () {}),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Text('输入消息'),
            ),
          ),
          GlassButton(
            icon: Icons.arrow_upward_rounded,
            label: '发送',
            solid: true,
            onPressed: () {},
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('open drawer freezes underlying light until it closes', (
    tester,
  ) async {
    _phone(tester);
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      _host(
        PocketScaffold(
          scaffoldKey: scaffold,
          title: const Text('对话'),
          body: const SizedBox.expand(),
          drawer: const Drawer(child: Text('侧栏')),
        ),
        reduceMotion: false,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    scaffold.currentState!.openDrawer();
    await tester.pump();
    await tester.pumpAndSettle();
    final light = tester.widget<DaylightBackdrop>(
      find.byType(DaylightBackdrop),
    );
    expect(light.suspendMotion!.value, isTrue);
    expect(tester.binding.transientCallbackCount, 0);
    scaffold.currentState!.closeDrawer();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(light.suspendMotion!.value, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('ambient motion yields to scrolling without rebuilding rows', (
    tester,
  ) async {
    _phone(tester);
    var builds = 0;
    await tester.pumpWidget(
      _host(
        PocketScaffold(
          title: const Text('测试'),
          body: Builder(
            builder: (context) {
              builds++;
              return ListView(children: const [SizedBox(height: 2000)]);
            },
          ),
        ),
        reduceMotion: false,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final backdrop = tester.widget<DaylightBackdrop>(
      find.byType(DaylightBackdrop),
    );
    final before = builds;
    final gesture = await tester.startGesture(const Offset(150, 500));
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    expect(backdrop.suspendMotion!.value, isTrue);
    expect(builds, before);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await gesture.cancel();
    await tester.pump(const Duration(seconds: 2));
    expect(backdrop.suspendMotion!.value, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'diffuse light moves across the page and respects reduced motion',
    (tester) async {
      _phone(tester);
      for (final brightness in Brightness.values) {
        final key = GlobalKey();
        Widget scene(bool reduce) => RepaintBoundary(
          key: key,
          child: _host(
            const PocketScaffold(title: Text('外观'), body: SizedBox.expand()),
            brightness: brightness,
            reduceMotion: reduce,
          ),
        );
        await tester.pumpWidget(scene(false));
        await tester.pump(const Duration(milliseconds: 500));
        final before = await _pixels(tester, key);
        await tester.pump(const Duration(seconds: 4));
        final after = await _pixels(tester, key);
        var biggestChange = 0, movingPixels = 0, sampledPixels = 0;
        for (var y = 130; y < 780; y++) {
          for (var x = 20; x < 370; x++) {
            final offset = (y * 390 + x) * 4;
            var change = 0;
            for (var channel = 0; channel < 3; channel++) {
              final delta = (before[offset + channel] - after[offset + channel])
                  .abs();
              if (delta > change) change = delta;
            }
            if (change > biggestChange) biggestChange = change;
            if (change >= 2) movingPixels++;
            sampledPixels++;
          }
        }
        expect(
          movingPixels / sampledPixels,
          greaterThan(.2),
          reason: '$brightness must move a broad field, not just a thin line.',
        );
        expect(
          biggestChange,
          inInclusiveRange(2, brightness == Brightness.dark ? 12 : 18),
        );
        await tester.pumpWidget(scene(true));
        await tester.pumpAndSettle();
        final still = await _pixels(tester, key);
        await tester.pump(const Duration(seconds: 4));
        expect(await _pixels(tester, key), orderedEquals(still));
        expect(tester.binding.hasScheduledFrame, isFalse);
      }
    },
  );
  testWidgets(
    'daylight is stable at rest, and respects glass-off and pure black',
    (tester) async {
      _phone(tester);
      for (final mode in [
        (glass: true, black: false),
        (glass: false, black: false),
        (glass: true, black: true),
      ]) {
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: _host(
              const PocketScaffold(title: Text('外观'), body: SizedBox.expand()),
              brightness: Brightness.dark,
              glass: mode.glass,
              black: mode.black,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = await _pixels(tester, key);
        await tester.pump(const Duration(seconds: 1));
        expect(
          await _pixels(tester, key),
          orderedEquals(before),
          reason: 'Grain must not shimmer or start an idle animation.',
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(
          find.byType(DaylightBackdrop),
          mode.glass ? findsOneWidget : findsNothing,
        );
        final color = _pixel(before, 195, 300);
        if (mode.black) {
          expect(color, Colors.black);
        } else if (!mode.glass) {
          expect(color, pocketTheme(Brightness.dark).scaffoldBackgroundColor);
        } else {
          expect(
            color,
            isNot(_pixel(before, 30, 700)),
            reason: 'Directional light should differ from the shaded region.',
          );
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'software fallback lights the glass face and restores it without motion',
    (tester) async {
      _phone(tester);
      final key = GlobalKey();
      var calls = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _host(
            Scaffold(
              body: Center(
                child: GlassButton(
                  icon: Icons.arrow_upward_rounded,
                  label: '发送',
                  solid: true,
                  onPressed: () => calls++,
                ),
              ),
            ),
            brightness: Brightness.dark,
            capture: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = await _pixels(tester, key);
      final button = find.byTooltip('发送');
      final center = tester.getCenter(button);
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
      expect(
        tester.widget<LiquidGlass>(find.byType(LiquidGlass)).pressed,
        isTrue,
      );
      final pressed = await _pixels(tester, key);
      // Sample the glass outside the 24 dp icon, including its test-font box.
      final sample = center + const Offset(-16, 0);
      expect(
        _pixel(
          pressed,
          sample.dx.floor(),
          sample.dy.floor(),
        ).computeLuminance(),
        greaterThan(
          _pixel(
                before,
                sample.dx.floor(),
                sample.dy.floor(),
              ).computeLuminance() +
              .01,
        ),
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(await _pixels(tester, key), orderedEquals(before));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(calls, 1);
    },
  );

  testWidgets(
    'chat and grouped surfaces remain usable at narrow width and large text',
    (tester) async {
      _phone(tester, const Size(320, 740));
      final runtime = _PreviewRuntime();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        runtime.dispose();
        await runtime.presets.control.done;
      });
      await tester.pumpWidget(_host(ChatPage(runtime: runtime), scale: 1.7));
      await tester.pumpAndSettle();
      expect(find.text('新对话'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_host(_components(), scale: 1.7));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('主题配色').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('optional local chat and component previews', (tester) async {
    final directory = Platform.environment['DSH_DAYLIGHT_CAPTURE_DIR'];
    if (directory == null) return;
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousShadows);
    _phone(tester);
    final font = Platform.environment['DSH_DAYLIGHT_CAPTURE_FONT'];
    if (font != null) {
      await tester.runAsync(() async {
        final bytes = await File(font).readAsBytes();
        await (FontLoader(
          'DaylightPreview',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    try {
      for (final brightness in Brightness.values) {
        final runtime = _PreviewRuntime();
        final appearance = AppearanceController();
        try {
          for (final scene in [
            ('chat', ChatPage(runtime: runtime)),
            ('components', _components()),
            (
              'appearance',
              AppearanceScope(
                controller: appearance,
                child: const AppearancePage(),
              ),
            ),
          ]) {
            final key = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: key,
                child: _host(
                  scene.$2,
                  brightness: brightness,
                  font: font == null ? null : 'DaylightPreview',
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            Future<void> capture(String state) async =>
                tester.runAsync(() async {
                  final image =
                      await (key.currentContext!.findRenderObject()!
                              as RenderRepaintBoundary)
                          .toImage(pixelRatio: 2);
                  try {
                    final data = (await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    ))!;
                    await Directory(directory).create(recursive: true);
                    await File(
                      '$directory/${scene.$1}-${brightness.name}-$state.png',
                    ).writeAsBytes(data.buffer.asUint8List());
                  } finally {
                    image.dispose();
                  }
                });
            await capture('idle');
            if (scene.$1 == 'components') {
              final gesture = await tester.startGesture(
                tester.getCenter(find.byTooltip('发送')),
              );
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 180));
              await tester.pumpAndSettle();
              await capture('pressed');
              await gesture.cancel();
              await tester.pumpAndSettle();
            }
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          runtime.dispose();
          await runtime.presets.control.done;
          appearance.dispose();
        }
      }
    } finally {
      debugDisableShadows = previousShadows;
    }
  });
}
