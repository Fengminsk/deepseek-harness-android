import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/metadata_artwork.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

String svgSource(String source) =>
    'data:image/svg+xml;base64,${base64Encode(utf8.encode(source))}';

const simpleSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<path d="M2 2h20v20H2z" fill="currentColor"/></svg>';

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Material(child: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'original package SVG artwork is displayed at the requested size',
    (tester) async {
      final bytes = File(
        '../../packages/experimental/agent-team-profile/icon.svg',
      ).readAsBytesSync();
      await mount(
        tester,
        pluginArtwork({
          'meta': {'icon': 'data:image/svg+xml;base64,${base64Encode(bytes)}'},
        }, size: 36),
      );
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.getSize(find.byType(MetadataArtwork)), const Size(36, 36));
      expect(find.byIcon(Icons.extension_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing, malformed and URL artwork retain their semantic fallback',
    (tester) async {
      for (final source in [
        null,
        '',
        'https://example.invalid/icon.svg',
        'data:image/svg+xml;base64,!',
        'data:text/html;base64,PHN2Zy8+',
      ]) {
        await mount(
          tester,
          MetadataArtwork(
            source: source,
            fallback: Icons.phone_android_rounded,
          ),
        );
        expect(find.byIcon(Icons.phone_android_rounded), findsOneWidget);
        expect(
          tester.getSize(find.byType(MetadataArtwork)),
          const Size(36, 36),
        );
        expect(find.byType(Image), findsNothing);
        expect(find.byType(SvgPicture), findsNothing);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('oversized metadata is rejected before decoding', (tester) async {
    await mount(
      tester,
      MetadataArtwork(source: svgSource('x' * (256 * 1024 + 1))),
    );
    expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('raster metadata displays without changing its layout or tint', (
    tester,
  ) async {
    final source = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xff407cff), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 4);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return 'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}';
    });
    await mount(tester, MetadataArtwork(source: source));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.extension_outlined), findsNothing);
    expect(tester.widget<Image>(find.byType(Image)).color, isNull);
    expect(tester.getSize(find.byType(MetadataArtwork)), const Size(36, 36));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an invalid raster decodes to fallback and an updated SVG can recover',
    (tester) async {
      await mount(
        tester,
        const MetadataArtwork(source: 'data:image/png;base64,bm90LWFuLWltYWdl'),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
      await mount(tester, MetadataArtwork(source: svgSource(simpleSvg)));
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.extension_outlined), findsNothing);
    },
  );

  testWidgets(
    'an invalid SVG shows its fallback and can be replaced by valid artwork',
    (tester) async {
      await mount(tester, MetadataArtwork(source: svgSource('<svg><broken')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
      await mount(tester, MetadataArtwork(source: svgSource(simpleSvg)));
      expect(find.byIcon(Icons.extension_outlined), findsNothing);
    },
  );

  testWidgets(
    'currentColor follows the surrounding icon theme without recoloring SVG artwork',
    (tester) async {
      for (final color in [Colors.black, Colors.white]) {
        await mount(
          tester,
          IconTheme(
            data: IconThemeData(color: color),
            child: MetadataArtwork(source: svgSource(simpleSvg)),
          ),
        );
        final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
        final loader = picture.bytesLoader as SvgBytesLoader;
        expect(loader.theme?.currentColor, color);
        expect(picture.colorFilter, isNull);
      }
    },
  );

  testWidgets(
    'settings categories differ and package metadata takes priority',
    (tester) async {
      await mount(
        tester,
        Row(
          children: [
            configurationArtwork({'ns': 'web-search-deepseek'}),
            configurationArtwork({'ns': 'ui-theme'}),
            configurationArtwork({
              'ns': 'android-runtime',
              'display': {'icon': svgSource(simpleSvg)},
            }),
            configurationArtwork({'ns': 'third-party'}),
          ],
        ),
      );
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.phone_android_rounded), findsNothing);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    },
  );
}
